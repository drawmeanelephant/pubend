import Base
import ./HostCommon.bend as HC
import ./HostFS.bend as HFS
import ../src/hostpath.bend as HP

def Bytes() -> Data:
  List<&2, U32>

# Site and output path resolution.  Paths remain raw byte strings here; only
# diagnostic rendering converts them to UTF-8 text.  The ordering exactly
# follows tools/pubend.mjs: reserved final component, final symlink precheck,
# longest-existing-prefix canonicalization of output and content, then the
# three containment refusals.

type CanonContext is Data:
  CanonInput{}
  CanonOutput{}

type SitePaths is Data:
  SitePaths{root: Bytes(), real_root: Bytes()}

type OutputPaths is Data:
  OutputPaths{out: Bytes(), content_dir: Bytes(), containment_root: Bytes()}

@unsafe def canon_input() -> CanonContext:
  CanonInput{}

@unsafe def canon_output() -> CanonContext:
  CanonOutput{}

@unsafe def site_paths(+root: Bytes(), +real_root: Bytes()) -> SitePaths:
  SitePaths{root, real_root}

@unsafe def output_paths(+out: Bytes(), +content_dir: Bytes(), +containment_root: Bytes()) -> OutputPaths:
  OutputPaths{out, content_dir, containment_root}

@unsafe def canon_action(ctx: CanonContext) -> String:
  match ctx:
    case CanonInput{}:
      "cannot canonicalize input path"
    case CanonOutput{}:
      "cannot canonicalize output path"

@unsafe def canon_class(ctx: CanonContext) -> HC.DiagClass:
  match ctx:
    case CanonInput{}:
      HC.DInputIo{}
    case CanonOutput{}:
      HC.DOutputIo{}

@unsafe def canon_diag(+ctx: CanonContext, +original: Bytes(), e: HC.HostIOError()) -> HC.HostDiag:
  HC.host_diag_path(canon_class(ctx), HC.bytes_display(original),
    canon_action(ctx) ++ ": " ++ HC.io_error_text(e))

type CanonWork is Data:
  CanonWStart{cur: Bytes(), missing: List<&2, List<&2, U32>>}
  CanonWSuccess{path: Bytes()}
  CanonWFailure{code: U32, message: String}
  CanonWMissing{cur: Bytes(), missing: List<&2, List<&2, U32>>, code: U32, message: String, ismissing: Bool}
  CanonWParent{cur: Bytes(), missing: List<&2, List<&2, U32>>, parent: Bytes(), code: U32, message: String, same: Bool}

@unsafe def canon_wstart(+cur: Bytes(), missing: List<&2, List<&2, U32>>) -> CanonWork:
  CanonWStart{cur, missing}

@unsafe def canon_wsuccess(+path: Bytes()) -> CanonWork:
  CanonWSuccess{path}

@unsafe def canon_wfailure(+code: U32, +message: String) -> CanonWork:
  CanonWFailure{code, message}

@unsafe def canon_wmissing(+cur: Bytes(), missing: List<&2, List<&2, U32>>, +code: U32, +message: String, ismissing: Bool) -> CanonWork:
  CanonWMissing{cur, missing, code, message, ismissing}

@unsafe def canon_wparent(+cur: Bytes(), missing: List<&2, List<&2, U32>>, +parent: Bytes(), +code: U32, +message: String, same: Bool) -> CanonWork:
  CanonWParent{cur, missing, parent, code, message, same}

@unsafe def canon_join_missing(+real: Bytes(), missing: List<&2, List<&2, U32>>) -> Bytes():
  match missing:
    case Nil{}:
      real
    case h <> t:
      HP.hostpath_join(real <> missing)

@unsafe def canon_after_io(+cur: Bytes(), missing: List<&2, List<&2, U32>>, r: HC.HBytesResult()) -> CanonWork:
  match r:
    case Done{+value}:
      canon_wsuccess(canon_join_missing(value, missing))
    case Fail{error}:
      (+code, +message) = error
      canon_wmissing(cur, missing, code, message,
        Bool.or(U32.is_eq(code, HC.errno_enoent()), U32.is_eq(code, HC.errno_enotdir())))

@unsafe def canon_error_pair(+code: U32, +message: String) -> HC.HostIOError():
  (code, message)

@unsafe def canon_io_failure(ctx: CanonContext, +original: Bytes(), +code: U32, +message: String) -> IO(HC.HRes(Bytes())):
  HC.io_fail_one(Bytes(), 3, canon_diag(ctx, original, canon_error_pair(code, message)))

@unsafe def canon_work_after(r: HC.HBytesResult(), +cur: Bytes(), missing: List<&2, List<&2, U32>>) -> CanonWork:
  canon_after_io(cur, missing, r)

# A fueled work-item driver.  Each ENOENT/ENOTDIR ascent strictly shortens
# the lexical path in reality; the generous byte-count fuel merely makes that
# termination argument visible to Bend without changing product behavior.
@unsafe def canonicalize_drive(+ctx: CanonContext, +original: Bytes(), fuel: Nat, work: CanonWork) -> IO(HC.HRes(Bytes())):
  match fuel:
    case 0n:
      canon_io_failure(ctx, original, 5, "canonicalization fuel exhausted")
    case 1n++f:
      match work:
        case CanonWStart{+cur, missing}:
          IO.bind(HC.HBytesResult(), HC.HRes(Bytes()), HFS.realpath(cur),
            r => IO.bind(CanonWork, HC.HRes(Bytes()),
              IO.pure(CanonWork, canon_work_after(r, cur, missing)),
              w => canonicalize_drive(ctx, original, f, w)))
        case CanonWSuccess{+path}:
          HC.io_hres_done(Bytes(), path)
        case CanonWFailure{+code, +message}:
          canon_io_failure(ctx, original, code, message)
        case CanonWMissing{+cur, missing, +code, +message, ismissing}:
          match ismissing:
            case False{}:
              canon_io_failure(ctx, original, code, message)
            case True{}:
              +parent = HP.hostpath_dirname(cur)
              canonicalize_drive(ctx, original, f,
                canon_wparent(cur, missing, parent, code, message, HC.bytes_eq(parent, cur)))
        case CanonWParent{+cur, missing, +parent, +code, +message, same}:
          match same:
            case True{}:
              canon_io_failure(ctx, original, code, message)
            case False{}:
              canonicalize_drive(ctx, original, f,
                canon_wstart(parent, HP.hostpath_basename(cur) <> missing))

@unsafe def canon_fuel(+path: Bytes()) -> Nat:
  Nat.add(Nat.mul(HC.bytes_length(path), 8n), 16n)

@unsafe def canonicalize_go(ctx: CanonContext, +original: Bytes(), +cur: Bytes(),
  missing: List<&2, List<&2, U32>>) -> IO(HC.HRes(Bytes())):
  canonicalize_drive(ctx, original, canon_fuel(cur), canon_wstart(cur, missing))

@unsafe def canonicalize_nearest(+cwd: Bytes(), ctx: CanonContext, +path: Bytes()) -> IO(HC.HRes(Bytes())):
  +resolved = HP.hostpath_resolve1(cwd, path)
  canonicalize_go(ctx, resolved, resolved, Nil{})

# --- site root ---------------------------------------------------------------

@unsafe def input_io_diag(+path: Bytes(), +action: String, e: HC.HostIOError()) -> HC.HostDiag:
  HC.host_diag_path(HC.DInputIo{}, HC.bytes_display(path), action ++ ": " ++ HC.io_error_text(e))

@unsafe def resolve_site_canonical_done(+root: Bytes(), +real_root: Bytes()) -> IO(HC.HRes(SitePaths)):
  HC.io_hres_done(SitePaths, site_paths(root, real_root))

@unsafe def resolve_site_canonical_map(+root: Bytes(), +real_root: Bytes()) -> IO(HC.HRes(SitePaths)):
  resolve_site_canonical_done(root, real_root)

@unsafe def flow_site_canonical_result(+root: Bytes(), r: HC.HRes(Bytes())) -> IO(HC.HRes(SitePaths)):
  match r:
    case Done{+canonical}:
      resolve_site_canonical_done(root, canonical)
    case Fail{+failure}:
      HC.io_hres_fail(SitePaths, failure)

@unsafe def flow_site_canonical(+cwd: Bytes(), +root: Bytes()) -> IO(HC.HRes(SitePaths)):
  IO.bind(HC.HRes(Bytes()), HC.HRes(SitePaths), canonicalize_nearest(cwd, canon_input(), root),
    r => flow_site_canonical_result(root, r))

@unsafe def resolve_site_real_fail(+cwd: Bytes(), +root: Bytes(), missingness: Bool, e: HC.HostIOError()) -> IO(HC.HRes(SitePaths)):
  match missingness:
    case True{}:
      flow_site_canonical(cwd, root)
    case False{}:
      HC.io_fail_one(SitePaths, 3, input_io_diag(root, "cannot resolve site root", e))

@unsafe def resolve_site_real_finish(+cwd: Bytes(), +root: Bytes(), r: HC.HBytesResult()) -> IO(HC.HRes(SitePaths)):
  match r:
    case Done{+real_root}:
      resolve_site_canonical_done(root, real_root)
    case Fail{error}:
      (+code, +message) = error
      resolve_site_real_fail(cwd, root,
        Bool.or(U32.is_eq(code, HC.errno_enoent()), U32.is_eq(code, HC.errno_enotdir())),
        (code, message))

# path.resolve(DIR), then realpath(DIR), falling back to longest-existing
# canonicalization only for ENOENT/ENOTDIR exactly like the reference host.
@unsafe def resolve_site_paths(+cwd: Bytes(), +dir_arg: Bytes()) -> IO(HC.HRes(SitePaths)):
  +root = HP.hostpath_resolve1(cwd, dir_arg)
  IO.bind(HC.HBytesResult(), HC.HRes(SitePaths), HFS.realpath(root),
    r => resolve_site_real_finish(cwd, root, r))

# --- output path ---------------------------------------------------------------

@unsafe def suffix_lock() -> Bytes():
  HC.ascii_bytes(".pubend-lock")

@unsafe def suffix_stage() -> Bytes():
  HC.ascii_bytes(".pubend-stage")

@unsafe def suffix_previous() -> Bytes():
  HC.ascii_bytes(".pubend-previous")

@unsafe def reserved_publication_final(+out: Bytes()) -> Bool:
  +base = HC.ascii_lower_bytes(HP.hostpath_basename(out))
  Bool.or(HC.bytes_ends_with(base, suffix_lock()),
    Bool.or(HC.bytes_ends_with(base, suffix_stage()),
      HC.bytes_ends_with(base, suffix_previous())))

@unsafe def requested_output(+cwd: Bytes(), +site_root: Bytes(), m: Maybe<&2, List<&2, U32>>) -> Bytes():
  match m:
    case None{}:
      HP.hostpath_join2(site_root, HC.ascii_bytes("dist"))
    case Some{+out_arg}:
      Bool.pick(Bytes(), HP.hostpath_is_absolute(out_arg),
        HP.hostpath_resolve1(cwd, out_arg),
        HP.hostpath_resolve(cwd, site_root <> out_arg <> Nil{}))

@unsafe def output_io_diag(+path: Bytes(), +action: String, e: HC.HostIOError()) -> HC.HostDiag:
  HC.host_diag_path(HC.DOutputIo{}, HC.bytes_display(path), action ++ ": " ++ HC.io_error_text(e))

@unsafe def output_forbidden(+path: Bytes(), +message: String) -> IO(HC.HRes(OutputPaths)):
  HC.io_fail_path(OutputPaths, 2, HC.DOutputForbidden{}, HC.bytes_display(path), message)

@unsafe def output_outside(+path: Bytes()) -> IO(HC.HRes(OutputPaths)):
  HC.io_fail_path(OutputPaths, 2, HC.DOutputOutsideSite{}, HC.bytes_display(path),
    "output directory must remain inside the canonical site root")

@unsafe def reject_symlink_kind(+out: Bytes(), st: HFS.StatInfo) -> IO(HC.HRes(Unit)):
  match st:
    case HFS.StatInfo{kind, size, dev, ino}:
      reject_symlink_kind_gate(out, kind)

@unsafe def reject_symlink_kind_gate(+out: Bytes(), kind: HFS.EntryKind) -> IO(HC.HRes(Unit)):
  match kind:
    case HFS.EntrySymlink{}:
      HC.io_fail_path(Unit, 3, HC.DOutputSymlink{}, HC.bytes_display(out),
        "symlinked pre-existing output path is a host failure")
    case other:
      HC.io_hres_done(Unit, Unit{})

@unsafe def reject_symlink_finish(+out: Bytes(), r: HC.HStatResult()) -> IO(HC.HRes(Unit)):
  match r:
    case Done{+st}:
      reject_symlink_kind(out, st)
    case Fail{error}:
      (+code, +message) = error
      reject_symlink_error(out,
        Bool.or(U32.is_eq(code, HC.errno_enoent()), U32.is_eq(code, HC.errno_enotdir())),
        (code, message))

@unsafe def reject_symlink_error(+out: Bytes(), missingness: Bool, e: HC.HostIOError()) -> IO(HC.HRes(Unit)):
  match missingness:
    case True{}:
      HC.io_hres_done(Unit, Unit{})
    case False{}:
      HC.io_fail_one(Unit, 3, output_io_diag(out, "cannot inspect output path", e))

# lstat the requested final output spelling before canonicalization; absent is
# success, symlink is a host failure, every other inspection error is output-io.
@unsafe def reject_symlinked_output_path(+out: Bytes()) -> IO(HC.HRes(Unit)):
  IO.bind(HC.HStatResult(), HC.HRes(Unit), HFS.lstat_info(out),
    r => reject_symlink_finish(out, r))

@unsafe def output_success(+out: Bytes(), +content_dir: Bytes(), +containment_root: Bytes()) -> IO(HC.HRes(OutputPaths)):
  HC.io_hres_done(OutputPaths, output_paths(out, content_dir, containment_root))

@unsafe def output_containment_checks(+out: Bytes(), +content_dir: Bytes(), +canonical_root: Bytes(),
  +canonical_content: Bytes()) -> IO(HC.HRes(OutputPaths)):
  output_content_gate(out, content_dir, canonical_root, canonical_content,
    HC.bytes_eq(out, canonical_root),
    HP.hostpath_is_strictly_inside_resolved(out, canonical_root),
    Bool.or(HC.bytes_eq(out, canonical_content),
      HP.hostpath_is_strictly_inside_resolved(out, canonical_content)))

@unsafe def output_content_gate(+out: Bytes(), +content_dir: Bytes(), +canonical_root: Bytes(),
  +canonical_content: Bytes(), isroot: Bool, inside: Bool, iscontent: Bool) -> IO(HC.HRes(OutputPaths)):
  match isroot:
    case True{}:
      output_forbidden(out, "output directory must not be the site root")
    case False{}:
      output_outside_gate(out, content_dir, canonical_root, canonical_content, inside, iscontent)

@unsafe def output_outside_gate(+out: Bytes(), +content_dir: Bytes(), +canonical_root: Bytes(),
  +canonical_content: Bytes(), inside: Bool, iscontent: Bool) -> IO(HC.HRes(OutputPaths)):
  match inside:
    case False{}:
      output_outside(out)
    case True{}:
      output_content_final_gate(out, content_dir, canonical_root, iscontent)

@unsafe def output_content_final_gate(+out: Bytes(), +content_dir: Bytes(), +canonical_root: Bytes(),
  iscontent: Bool) -> IO(HC.HRes(OutputPaths)):
  match iscontent:
    case True{}:
      output_forbidden(out, "output directory must not be content/ or a descendant of content/")
    case False{}:
      output_success(out, content_dir, canonical_root)

@unsafe def resolve_output_after_content(+content_dir: Bytes(), +canonical_root: Bytes(), +canonical_out: Bytes(),
  r: HC.HRes(Bytes())) -> IO(HC.HRes(OutputPaths)):
  match r:
    case Done{+canonical_content}:
      output_containment_checks(canonical_out, content_dir, canonical_root, canonical_content)
    case Fail{+failure}:
      HC.io_hres_fail(OutputPaths, failure)

@unsafe def resolve_output_after_canonical(+cwd: Bytes(), +content_dir: Bytes(), +canonical_root: Bytes(),
  r: HC.HRes(Bytes())) -> IO(HC.HRes(OutputPaths)):
  match r:
    case Done{+canonical_out}:
      IO.bind(HC.HRes(Bytes()), HC.HRes(OutputPaths),
        canonicalize_nearest(cwd, canon_input(), content_dir),
        r2 => resolve_output_after_content(content_dir, canonical_root, canonical_out, r2))
    case Fail{+failure}:
      HC.io_hres_fail(OutputPaths, failure)

@unsafe def resolve_output_after_symlink(+cwd: Bytes(), +content_dir: Bytes(), +canonical_root: Bytes(),
  +requested: Bytes(), r: HC.HRes(Unit)) -> IO(HC.HRes(OutputPaths)):
  match r:
    case Done{value}:
      IO.bind(HC.HRes(Bytes()), HC.HRes(OutputPaths),
        canonicalize_nearest(cwd, canon_output(), requested),
        r2 => resolve_output_after_canonical(cwd, content_dir, canonical_root, r2))
    case Fail{+failure}:
      HC.io_hres_fail(OutputPaths, failure)

@unsafe def resolve_output_not_reserved(+cwd: Bytes(), +site_root: Bytes(), +canonical_root: Bytes(),
  +requested: Bytes(), +content_dir: Bytes()) -> IO(HC.HRes(OutputPaths)):
  IO.bind(HC.HRes(Unit), HC.HRes(OutputPaths), reject_symlinked_output_path(requested),
    r => resolve_output_after_symlink(cwd, content_dir, canonical_root, requested, r))

@unsafe def resolve_output_reserved_gate(+cwd: Bytes(), +site_root: Bytes(), +canonical_root: Bytes(),
  +requested: Bytes(), +content_dir: Bytes(), reserved: Bool) -> IO(HC.HRes(OutputPaths)):
  match reserved:
    case True{}:
      output_forbidden(requested, "output directory final component is reserved publication namespace")
    case False{}:
      resolve_output_not_reserved(cwd, site_root, canonical_root, requested, content_dir)

# Exact output-resolution ordering: requested spelling, reserved-name refusal,
# final symlink precheck, output/content longest-prefix canonicalization, then
# root/outside/content containment checks.  The returned output is the
# canonical spelling, not necessarily the user-supplied spelling.
@unsafe def resolve_output_path(+cwd: Bytes(), +site_root: Bytes(), +site_real_root: Bytes(),
  out_arg: Maybe<&2, List<&2, U32>>) -> IO(HC.HRes(OutputPaths)):
  +requested = requested_output(cwd, site_root, out_arg)
  +content_dir = HP.hostpath_join2(site_root, HC.ascii_bytes("content"))
  +canonical_root = HP.hostpath_resolve1(cwd, site_real_root)
  resolve_output_reserved_gate(cwd, site_root, canonical_root, requested, content_dir,
    reserved_publication_final(requested))
