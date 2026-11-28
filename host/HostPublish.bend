import Base
import ./HostCommon.bend as HC
import ./HostFS.bend as HFS
import ./HostCollision.bend as HCol
import ../src/hostpath.bend as HP
import ../src/model.bend as Model
import ../src/sha256.bend as Sha
import ../src/hostjson.bend as HJ

# Native publication staging, validation, recovery, and swapping.  This module
# follows the reference host's syscall ordering: probe the output filesystem,
# refuse collisions before mutation, validate/create the output parent, take
# the fixed lock, recover marker-owned publication state, write a marked stage,
# recursively validate the completed stage, swap through the fixed backup, and
# release the lock while preserving the primary diagnostic.
# @unsafe is intentional, accepted host-orchestration architecture: Bend 2.0.40
# cannot yet type these effect continuations and affine matches without it.  It
# is used only to sequence the documented HostFS boundary operations, not to
# bypass publication ordering, validation, ownership, or cleanup discipline.

def Bytes() -> Data:
  List<&2, U32>

type FileRead is Data:
  FileReadOk{bytes: Bytes()}
  FileReadErr{code: U32, message: String}

type StageFile is Data:
  StageFile{rel: Bytes(), bytes: Bytes()}

type PageWrite is Data:
  PageWrite{manifest: HJ.HostManifestPage, file: StageFile}

type WriteAccum is Data:
  WriteAccum{manifests: List<&2, HJ.HostManifestPage>, files: List<&2, StageFile>}

type StageWrite is Data:
  StageWrite{files: List<&2, StageFile>}

# --- diagnostic and small data constructors -----------------------------------------

@unsafe def file_read_ok(+bytes: Bytes()) -> FileRead:
  FileReadOk{bytes}

@unsafe def file_read_err(+code: U32, +message: String) -> FileRead:
  FileReadErr{code, message}

@unsafe def stage_file(+rel: Bytes(), +bytes: Bytes()) -> StageFile:
  StageFile{rel, bytes}

@unsafe def page_write(+manifest: HJ.HostManifestPage, +file: StageFile) -> PageWrite:
  PageWrite{manifest, file}

@unsafe def write_accum(manifests: List<&2, HJ.HostManifestPage>, files: List<&2, StageFile>) -> WriteAccum:
  WriteAccum{manifests, files}

@unsafe def write_accum_empty() -> WriteAccum:
  write_accum(Nil{}, Nil{})

@unsafe def stage_write(files: List<&2, StageFile>) -> StageWrite:
  StageWrite{files}

@unsafe def maybe_stat_none() -> Maybe<&2, HFS.StatInfo>:
  None{}

@unsafe def maybe_stat_some(+st: HFS.StatInfo) -> Maybe<&2, HFS.StatInfo>:
  Some{st}

@unsafe def maybe_stage_file_none() -> Maybe<&2, StageFile>:
  None{}

@unsafe def maybe_stage_file_some(+x: StageFile) -> Maybe<&2, StageFile>:
  Some{x}

@unsafe def out_io_diag(+path: Bytes(), +action: String, e: HC.HostIOError()) -> HC.HostDiag:
  HC.host_diag_path(HC.DOutputIo{}, HC.bytes_display(path), action ++ ": " ++ HC.io_error_text(e))

@unsafe def out_io_failure(-A: Type, +path: Bytes(), +action: String, e: HC.HostIOError()) -> IO(HC.HRes(A)):
  HC.io_fail_one(A, 3, out_io_diag(path, action, e))

@unsafe def out_effect(-A: Type, +path: Bytes(), +action: String,
  act: IO(Result<&1, &1, HC.HostIOError(), A>)) -> IO(HC.HRes(A)):
  HC.flow_effect(A, act, e => out_io_diag(path, action, e))

@unsafe def publication_diag(+path: Bytes(), +action: String, e: HC.HostIOError()) -> HC.HostDiag:
  HC.host_diag_path(HC.DOutputPublication{}, HC.bytes_display(path), action ++ ": " ++ HC.io_error_text(e))

@unsafe def publication_effect(-A: Type, +path: Bytes(), +action: String,
  act: IO(Result<&1, &1, HC.HostIOError(), A>)) -> IO(HC.HRes(A)):
  HC.flow_effect(A, act, e => publication_diag(path, action, e))

@unsafe def class_diag(+cls: HC.DiagClass, +path: Bytes(), +message: String) -> HC.HostDiag:
  HC.host_diag_path(cls, HC.bytes_display(path), message)

@unsafe def io_fail_class(-A: Type, +cls: HC.DiagClass, +path: Bytes(), +message: String) -> IO(HC.HRes(A)):
  HC.io_fail_one(A, 3, class_diag(cls, path, message))

@unsafe def class_effect(-A: Type, +cls: HC.DiagClass, +path: Bytes(), +action: String,
  act: IO(Result<&1, &1, HC.HostIOError(), A>)) -> IO(HC.HRes(A)):
  HC.flow_effect(A, act, e => class_diag(cls, path, action ++ ": " ++ HC.io_error_text(e)))

@unsafe def invalid_stage_io(-A: Type, +path: Bytes(), +message: String) -> IO(HC.HRes(A)):
  io_fail_class(A, HC.DOutputStageInvalid{}, path, message)

@unsafe def backup_invalid_io(-A: Type, +path: Bytes(), +message: String) -> IO(HC.HRes(A)):
  io_fail_class(A, HC.DOutputBackupInvalid{}, path, message)

@unsafe def backup_conflict_io(-A: Type, +path: Bytes(), +message: String) -> IO(HC.HRes(A)):
  io_fail_class(A, HC.DOutputBackupConflict{}, path, message)

@unsafe def marker_stage_bytes() -> Bytes():
  HC.ascii_bytes("pubend incomplete stage owner v1\n")

@unsafe def marker_backup_bytes() -> Bytes():
  HC.ascii_bytes("pubend backup owner v1\n")

@unsafe def stage_marker_name() -> Bytes():
  HC.ascii_bytes(".pubend-incomplete-stage")

@unsafe def backup_marker_name() -> Bytes():
  HC.ascii_bytes(".pubend-backup-owner")

# --- byte-list path algebra -----------------------------------------------------------

@unsafe def split_step(xs: Bytes(), cur: Bytes(), acc: List<&2, List<&2, U32>>, +b: U32) -> Bytes() & List<&2, List<&2, U32>>:
  split_step_gate(xs, cur, acc, b, U32.is_eq(b, 47))

@unsafe def split_step_gate(xs: Bytes(), cur: Bytes(), acc: List<&2, List<&2, U32>>, +b: U32, issep: Bool) -> Bytes() & List<&2, List<&2, U32>>:
  match issep:
    case True{}:
      (Nil{}, List.append(&2, Bytes(), acc, List.reverse(&2, U32, cur) <> Nil{}))
    case False{}:
      (b <> cur, acc)

@unsafe def split_bytes_go(xs: Bytes(), cur: Bytes(), acc: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  match xs:
    case Nil{}:
      List.append(&2, Bytes(), acc, List.reverse(&2, U32, cur) <> Nil{})
    case +h <> +t:
      split_bytes_after_step(t, split_step(t, cur, acc, h))

@unsafe def split_bytes_after_step(xs: Bytes(), p: Bytes() & List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  (cur, acc) = p
  split_bytes_go(xs, cur, acc)

@unsafe def split_bytes(+xs: Bytes()) -> List<&2, List<&2, U32>>:
  split_bytes_go(xs, Nil{}, Nil{})

@unsafe def drop_last(xs: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  match xs:
    case Nil{}:
      Nil{}
    case h <> Nil{}:
      Nil{}
    case +h <> t:
      h <> drop_last(t)

@unsafe def prefix_dirs_go(+cur: Bytes(), comps: List<&2, List<&2, U32>>, acc: List<&2, Bytes()>) -> List<&2, Bytes()>:
  match comps:
    case Nil{}:
      acc
    case +h <> t:
      +next = HP.hostpath_join2(cur, h)
      prefix_dirs_go(next, t, List.append(&2, Bytes(), acc, next <> Nil{}))

# Every proper parent directory of rel under base, shallowest first.  rel itself
# is a file path and is excluded.
@unsafe def parent_prefixes(+base: Bytes(), +rel: Bytes()) -> List<&2, Bytes()>:
  prefix_dirs_go(base, drop_last(split_bytes(rel)), Nil{})

# Every proper directory prefix of a relative file path, relative rather than
# host-rooted and shallowest first.
@unsafe def rel_prefixes(+rel: Bytes()) -> List<&2, Bytes()>:
  prefix_dirs_go(Nil{}, drop_last(split_bytes(rel)), Nil{})

@unsafe def inclusive_prefixes_go(+cur: Bytes(), comps: List<&2, List<&2, U32>>, acc: List<&2, Bytes()>) -> List<&2, Bytes()>:
  match comps:
    case Nil{}:
      acc
    case +h <> t:
      +next = HP.hostpath_join2(cur, h)
      inclusive_prefixes_go(next, t, List.append(&2, Bytes(), acc, next <> Nil{}))

@unsafe def inclusive_prefixes(+base: Bytes(), +rel: Bytes()) -> List<&2, Bytes()>:
  inclusive_prefixes_go(base, split_bytes(rel), Nil{})

@unsafe def rel_join(+base: Bytes(), +name: Bytes()) -> Bytes():
  match base:
    case Nil{}:
      name
    case h <> t:
      HC.bytes_append(base, HC.bytes_append(HC.ascii_bytes("/"), name))

@unsafe def contains_nul(xs: Bytes()) -> Bool:
  match xs:
    case Nil{}:
      False{}
    case +h <> t:
      contains_nul_gate(t, U32.is_eq(h, 0))

@unsafe def contains_nul_gate(rest: Bytes(), iszero: Bool) -> Bool:
  match iszero:
    case True{}:
      True{}
    case False{}:
      contains_nul(rest)

# --- recursive removal ----------------------------------------------------------------

@unsafe def remove_missing_result(+path: Bytes(), r: HC.HStatResult()) -> IO(HC.HRes(HFS.StatInfo)):
  match r:
    case Done{+st}:
      HC.io_hres_done(HFS.StatInfo, st)
    case Fail{error}:
      (+code, +message) = error
      remove_missing_gate(path, code, message,
        Bool.or(U32.is_eq(code, HC.errno_enoent()), U32.is_eq(code, HC.errno_enotdir())))

@unsafe def remove_missing_gate(+path: Bytes(), +code: U32, +message: String, missing: Bool) -> IO(HC.HRes(HFS.StatInfo)):
  match missing:
    case True{}:
      HC.io_hres_done(HFS.StatInfo, HFS.StatInfo{HFS.EntryUnknown{}, HFS.U64Parts{0,0}, HFS.U64Parts{0,0}, HFS.U64Parts{0,0}})
    case False{}:
      out_io_failure(HFS.StatInfo, path, "cannot inspect path during removal", (code, message))

@unsafe def stat_or_missing(+path: Bytes()) -> IO(HC.HRes(HFS.StatInfo)):
  IO.bind(HC.HStatResult(), HC.HRes(HFS.StatInfo), HFS.lstat_info(path),
    r => remove_missing_result(path, r))

@unsafe def stat_exists_kind(kind: HFS.EntryKind) -> Bool:
  match kind:
    case HFS.EntryUnknown{}:
      False{}
    case other:
      True{}

@unsafe def remove_children(+parent: Bytes(), xs: List<&2, HFS.DirInfo>) -> IO(HC.HRes(Unit)):
  match xs:
    case Nil{}:
      HC.io_hres_done(Unit, Unit{})
    case +h <> t:
      match h:
        case HFS.DirInfo{+name, kind}:
          HC.flow_bind(Unit, Unit, remove_tree(HP.hostpath_join2(parent, name)),
            u => remove_children(parent, t))

@unsafe def remove_dir_contents(+path: Bytes(), r: HC.HRes(List<&2, HFS.DirInfo>)) -> IO(HC.HRes(Unit)):
  match r:
    case Done{+entries}:
      HC.flow_bind(Unit, Unit, remove_children(path, entries),
        u => out_effect(Unit, path, "cannot remove directory", HFS.rmdir(path)))
    case Fail{+failure}:
      HC.io_hres_fail(Unit, failure)

@unsafe def remove_directory(+path: Bytes()) -> IO(HC.HRes(Unit)):
  IO.bind(HC.HRes(List<&2, HFS.DirInfo>), HC.HRes(Unit),
    out_effect(List<&2, HFS.DirInfo>, path, "cannot read directory during removal", HFS.readdir_info(path)),
    r => remove_dir_contents(path, r))

@unsafe def remove_by_kind(+path: Bytes(), st: HFS.StatInfo) -> IO(HC.HRes(Unit)):
  match st:
    case HFS.StatInfo{kind, size, dev, ino}:
      remove_kind_gate(path, kind)

@unsafe def remove_kind_gate(+path: Bytes(), kind: HFS.EntryKind) -> IO(HC.HRes(Unit)):
  match kind:
    case HFS.EntryUnknown{}:
      HC.io_hres_done(Unit, Unit{})
    case HFS.EntryDirectory{}:
      remove_directory(path)
    case other:
      out_effect(Unit, path, "cannot remove entry", HFS.unlink(path))

# Removal never follows symlinks because every decision uses lstat.  Missing
# paths are success; directory contents are removed before the directory itself.
@unsafe def remove_tree(+path: Bytes()) -> IO(HC.HRes(Unit)):
  HC.flow_bind(HFS.StatInfo, Unit, stat_or_missing(path), st => remove_by_kind(path, st))

@unsafe def best_effort_result(r: HC.HRes(Unit)) -> IO(HC.HRes(Unit)):
  match r:
    case Done{x}:
      HC.io_hres_done(Unit, Unit{})
    case Fail{failure}:
      HC.io_hres_done(Unit, Unit{})

@unsafe def best_effort_remove(+path: Bytes()) -> IO(HC.HRes(Unit)):
  IO.bind(HC.HRes(Unit), HC.HRes(Unit), remove_tree(path), best_effort_result)

@unsafe def remove_path_for_publication(+path: Bytes(), +description: String) -> IO(HC.HRes(Unit)):
  remove_tree(path)

# --- recursive mkdir ------------------------------------------------------------------

@unsafe def mkdir_ignore_exists_result(rest: List<&2, Bytes()>, +errpath: Bytes(), +action: String, r: HC.HUnitResult()) -> IO(HC.HRes(Unit)):
  match r:
    case Done{value}:
      mkdirs_go_report(rest, errpath, action)
    case Fail{error}:
      (+code, +message) = error
      mkdir_exists_gate(rest, errpath, action, code, message, U32.is_eq(code, HC.errno_eexist()))

@unsafe def mkdir_exists_gate(rest: List<&2, Bytes()>, +errpath: Bytes(), +action: String,
  +code: U32, +message: String, exists: Bool) -> IO(HC.HRes(Unit)):
  match exists:
    case True{}:
      mkdirs_go_report(rest, errpath, action)
    case False{}:
      out_io_failure(Unit, errpath, action, (code, message))

# Create each prefix in order.  EEXIST is mkdir-p success here; output component
# validation is responsible for the reference host's file-versus-directory
# classification before and after creation.
@unsafe def mkdirs_go_report(xs: List<&2, Bytes()>, +errpath: Bytes(), +action: String) -> IO(HC.HRes(Unit)):
  match xs:
    case Nil{}:
      HC.io_hres_done(Unit, Unit{})
    case +h <> t:
      IO.bind(HC.HUnitResult(), HC.HRes(Unit), HFS.mkdir_one(h),
        r => mkdir_ignore_exists_result(t, errpath, action, r))

@unsafe def mkdirs_go(xs: List<&2, Bytes()>) -> IO(HC.HRes(Unit)):
  mkdirs_go_report(xs, Nil{}, "cannot create parent directory")

# --- exact-byte file reading -----------------------------------------------------------

@unsafe def fread_close_error(file: File, +code: U32, +message: String) -> IO(FileRead):
  IO.bind(Unit, FileRead, File.close(file), u => IO.pure(FileRead, file_read_err(code, message)))

@unsafe def fread_close_ok(file: File, +bytes: Bytes()) -> IO(FileRead):
  IO.bind(Unit, FileRead, File.close(file), u => IO.pure(FileRead, file_read_ok(bytes)))

@unsafe def fread_chunk_gate(file: File, +acc: Bytes(), +chunk: Bytes(), short: Bool) -> IO(FileRead):
  match short:
    case True{}:
      fread_close_ok(file, HC.bytes_append(acc, chunk))
    case False{}:
      read_all_file_go(file, HC.bytes_append(acc, chunk))

@unsafe def fread_chunk_result(file: File, +acc: Bytes(), r: Result<&1, &1, HC.HostIOError(), Bytes()>) -> IO(FileRead):
  match r:
    case Done{+bytes}:
      fread_chunk_gate(file, acc, bytes, Nat.is_lt(HC.bytes_length(bytes), 65536n))
    case Fail{error}:
      (+code, +message) = error
      fread_close_error(file, code, message)

@unsafe def fread_chunk_pair(p: File & Result<&1, &1, HC.HostIOError(), Bytes()>, +acc: Bytes()) -> IO(FileRead):
  (file, result) = p
  fread_chunk_result(file, acc, result)

@unsafe def read_all_file_go(file: File, +acc: Bytes()) -> IO(FileRead):
  IO.bind(File & Result<&1, &1, HC.HostIOError(), Bytes()>, FileRead,
    File.read_bytes(file, 65536), p => fread_chunk_pair(p, acc))

@unsafe def read_open_finish(r: Result<&1, &1, HC.HostIOError(), File>) -> IO(FileRead):
  match r:
    case Done{file}:
      read_all_file_go(file, Nil{})
    case Fail{error}:
      (+code, +message) = error
      IO.pure(FileRead, file_read_err(code, message))

@unsafe def read_file_bytes(+path: Bytes()) -> IO(FileRead):
  IO.bind(Result<&1, &1, HC.HostIOError(), File>, FileRead,
    File.open_bytes(path, "r"), read_open_finish)

# --- lstat-or-absent and ownership markers --------------------------------------------

@unsafe def lstat_maybe_error(+path: Bytes(), +code: U32, +message: String, missing: Bool) -> IO(HC.HRes(Maybe<&2, HFS.StatInfo>)):
  match missing:
    case True{}:
      HC.io_hres_done(Maybe<&2, HFS.StatInfo>, maybe_stat_none())
    case False{}:
      out_io_failure(Maybe<&2, HFS.StatInfo>, path, "cannot inspect publication path", (code, message))

@unsafe def lstat_maybe_finish(+path: Bytes(), r: HC.HStatResult()) -> IO(HC.HRes(Maybe<&2, HFS.StatInfo>)):
  match r:
    case Done{+st}:
      HC.io_hres_done(Maybe<&2, HFS.StatInfo>, maybe_stat_some(st))
    case Fail{error}:
      (+code, +message) = error
      lstat_maybe_error(path, code, message,
        Bool.or(U32.is_eq(code, HC.errno_enoent()), U32.is_eq(code, HC.errno_enotdir())))

# The publication host's lstatOrNull: ENOENT/ENOTDIR mean absent; every other
# inspection error is output-io at the inspected path.
@unsafe def lstat_maybe(+path: Bytes()) -> IO(HC.HRes(Maybe<&2, HFS.StatInfo>)):
  IO.bind(HC.HStatResult(), HC.HRes(Maybe<&2, HFS.StatInfo>), HFS.lstat_info(path),
    r => lstat_maybe_finish(path, r))

@unsafe def u64_size_is(+size: HFS.U64Parts, +expected: Bytes()) -> Bool:
  match size:
    case HFS.U64Parts{+hi, +lo}:
      Bool.and(U32.is_eq(hi, 0), U32.is_eq(lo, U32.from_nat(HC.bytes_length(expected))))

@unsafe def marker_invalid(+cls: HC.DiagClass, +mpath: Bytes(), +description: String) -> IO(HC.HRes(Unit)):
  io_fail_class(Unit, cls, mpath, description ++ " ownership marker is missing or invalid")

@unsafe def marker_missing(+cls: HC.DiagClass, +mpath: Bytes(), +description: String) -> IO(HC.HRes(Unit)):
  io_fail_class(Unit, cls, mpath, description ++ " ownership marker is missing")

@unsafe def marker_read_finish(+cls: HC.DiagClass, +mpath: Bytes(), +expected: Bytes(), +description: String, fr: FileRead) -> IO(HC.HRes(Unit)):
  match fr:
    case FileReadErr{+code, +message}:
      io_fail_class(Unit, cls, mpath, "cannot read " ++ description ++ " ownership marker: " ++ HC.io_error_text((code, message)))
    case FileReadOk{+bytes}:
      marker_bytes_gate(cls, mpath, description, HC.bytes_eq(bytes, expected))

@unsafe def marker_bytes_gate(+cls: HC.DiagClass, +mpath: Bytes(), +description: String, same: Bool) -> IO(HC.HRes(Unit)):
  match same:
    case True{}:
      HC.io_hres_done(Unit, Unit{})
    case False{}:
      marker_invalid(cls, mpath, description)

@unsafe def marker_read_validate(+cls: HC.DiagClass, +mpath: Bytes(), +expected: Bytes(), +description: String) -> IO(HC.HRes(Unit)):
  IO.bind(FileRead, HC.HRes(Unit), read_file_bytes(mpath),
    fr => marker_read_finish(cls, mpath, expected, description, fr))

@unsafe def marker_stat_kind_gate(+cls: HC.DiagClass, +mpath: Bytes(), +expected: Bytes(), +description: String,
  kind: HFS.EntryKind, +size: HFS.U64Parts) -> IO(HC.HRes(Unit)):
  match kind:
    case HFS.EntryFile{}:
      marker_size_gate(cls, mpath, expected, description, u64_size_is(size, expected))
    case other:
      marker_invalid(cls, mpath, description)

@unsafe def marker_size_gate(+cls: HC.DiagClass, +mpath: Bytes(), +expected: Bytes(), +description: String, exact: Bool) -> IO(HC.HRes(Unit)):
  match exact:
    case True{}:
      marker_read_validate(cls, mpath, expected, description)
    case False{}:
      marker_invalid(cls, mpath, description)

@unsafe def marker_stat_finish(+cls: HC.DiagClass, +mpath: Bytes(), +expected: Bytes(), +description: String, r: HC.HStatResult()) -> IO(HC.HRes(Unit)):
  match r:
    case Done{+st}:
      match st:
        case HFS.StatInfo{kind, size, dev, ino}:
          marker_stat_kind_gate(cls, mpath, expected, description, kind, size)
    case Fail{error}:
      (+code, +message) = error
      marker_stat_error(cls, mpath, description, code, message,
        Bool.or(U32.is_eq(code, HC.errno_enoent()), U32.is_eq(code, HC.errno_enotdir())))

@unsafe def marker_stat_error(+cls: HC.DiagClass, +mpath: Bytes(), +description: String,
  +code: U32, +message: String, missing: Bool) -> IO(HC.HRes(Unit)):
  match missing:
    case True{}:
      marker_missing(cls, mpath, description)
    case False{}:
      io_fail_class(Unit, cls, mpath, "cannot inspect " ++ description ++ " ownership marker: " ++ HC.io_error_text((code, message)))

@unsafe def require_ownership_marker(+tree: Bytes(), +marker_name: Bytes(), +expected: Bytes(),
  +cls: HC.DiagClass, +description: String) -> IO(HC.HRes(Unit)):
  +mpath = HP.hostpath_join2(tree, marker_name)
  IO.bind(HC.HStatResult(), HC.HRes(Unit), HFS.lstat_info(mpath),
    r => marker_stat_finish(cls, mpath, expected, description, r))

@unsafe def write_ownership_marker(+tree: Bytes(), +marker_name: Bytes(), +marker_bytes: Bytes(),
  +cls: HC.DiagClass, +description: String) -> IO(HC.HRes(Unit)):
  +mpath = HP.hostpath_join2(tree, marker_name)
  class_effect(Unit, cls, mpath, "cannot write " ++ description ++ " ownership marker",
    HFS.write_file_bytes(mpath, marker_bytes, 1))

@unsafe def remove_ownership_marker(+tree: Bytes(), +marker_name: Bytes(),
  +cls: HC.DiagClass, +description: String) -> IO(HC.HRes(Unit)):
  +mpath = HP.hostpath_join2(tree, marker_name)
  class_effect(Unit, cls, mpath, "cannot remove " ++ description ++ " ownership marker", HFS.unlink(mpath))

# --- output component validation and parent preparation --------------------------------

@unsafe def output_containment_failure(-A: Type, +path: Bytes(), +message: String) -> IO(HC.HRes(A)):
  io_fail_class(A, HC.DOutputContainment{}, path, message)

@unsafe def validate_component_missing(+cur: Bytes(), +code: U32, +message: String, missing: Bool) -> IO(HC.HRes(Unit)):
  match missing:
    case True{}:
      HC.io_hres_done(Unit, Unit{})
    case False{}:
      out_io_failure(Unit, cur, "cannot inspect output path component", (code, message))

@unsafe def validate_component_nonlast(+root: Bytes(), +cur: Bytes(), rest: List<&2, Bytes()>, kind: HFS.EntryKind, last: Bool) -> IO(HC.HRes(Unit)):
  match last:
    case True{}:
      io_fail_class(Unit, HC.DOutputNotDirectory{}, cur, "pre-existing output path is not a directory")
    case False{}:
      io_fail_class(Unit, HC.DOutputParentNotDirectory{}, cur, "output path parent component is not a directory")

@unsafe def validate_component_kind(+root: Bytes(), +cur: Bytes(), rest: List<&2, Bytes()>, kind: HFS.EntryKind, last: Bool) -> IO(HC.HRes(Unit)):
  match kind:
    case HFS.EntrySymlink{}:
      io_fail_class(Unit, HC.DOutputSymlink{}, cur, "symlinked output path component is a host failure")
    case HFS.EntryDirectory{}:
      validate_component_dir_gate(root, cur, rest, last)
    case other:
      validate_component_nonlast(root, cur, rest, kind, last)

@unsafe def validate_component_dir_gate(+root: Bytes(), +cur: Bytes(), rest: List<&2, Bytes()>, last: Bool) -> IO(HC.HRes(Unit)):
  match last:
    case True{}:
      HC.io_hres_done(Unit, Unit{})
    case False{}:
      validate_components_go(root, cur, rest)

@unsafe def validate_component_stat(+root: Bytes(), +cur: Bytes(), rest: List<&2, Bytes()>, last: Bool, r: HC.HStatResult()) -> IO(HC.HRes(Unit)):
  match r:
    case Done{+st}:
      match st:
        case HFS.StatInfo{kind, size, dev, ino}:
          validate_component_kind(root, cur, rest, kind, last)
    case Fail{error}:
      (+code, +message) = error
      validate_component_missing(cur, code, message,
        Bool.or(U32.is_eq(code, HC.errno_enoent()), U32.is_eq(code, HC.errno_enotdir())))

@unsafe def validate_components_go(+root: Bytes(), +cur: Bytes(), xs: List<&2, Bytes()>) -> IO(HC.HRes(Unit)):
  match xs:
    case Nil{}:
      HC.io_hres_done(Unit, Unit{})
    case +h <> +t:
      +next = HP.hostpath_join2(cur, h)
      IO.bind(HC.HStatResult(), HC.HRes(Unit), HFS.lstat_info(next),
        r => validate_component_stat(root, next, t, List.is_empty(&2, Bytes(), t), r))

@unsafe def validate_components_start(+root: Bytes(), +out: Bytes(), +rel: Bytes(), escaped: Bool) -> IO(HC.HRes(Unit)):
  match escaped:
    case True{}:
      output_containment_failure(Unit, out, "output path escaped its validated containment boundary")
    case False{}:
      validate_components_go(root, root, split_bytes(rel))

# Exact reference behavior: inspect each existing component from the validated
# containment root; the first ENOENT/ENOTDIR stops inspection successfully.
@unsafe def validate_output_components(+root: Bytes(), +out: Bytes()) -> IO(HC.HRes(Unit)):
  +rel = HP.hostpath_relative_resolved(root, out)
  validate_components_start(root, out, rel,
    Bool.or(HP.hostpath_bytes_empty(rel), HP.hostpath_escape(rel)))

@unsafe def output_parent_prefixes(+root: Bytes(), +parent: Bytes()) -> List<&2, Bytes()>:
  +rel = HP.hostpath_relative_resolved(root, parent)
  output_parent_prefixes_gate(root, rel, Bool.or(HP.hostpath_bytes_empty(rel), HP.hostpath_escape(rel)))

@unsafe def output_parent_prefixes_gate(+root: Bytes(), +rel: Bytes(), empty_or_escape: Bool) -> List<&2, Bytes()>:
  match empty_or_escape:
    case True{}:
      Nil{}
    case False{}:
      inclusive_prefixes(root, rel)

@unsafe def parent_real_containment_gate(+containment_root: Bytes(), +canonical_root: Bytes(), +out: Bytes(),
  +real_parent: Bytes()) -> IO(HC.HRes(Unit)):
  parent_real_containment_bool(containment_root, canonical_root, out, real_parent,
    HP.hostpath_is_inside_or_equal_resolved(real_parent, canonical_root))

@unsafe def parent_real_containment_bool(+containment_root: Bytes(), +canonical_root: Bytes(), +out: Bytes(),
  +real_parent: Bytes(), inside: Bool) -> IO(HC.HRes(Unit)):
  match inside:
    case True{}:
      validate_output_components(containment_root, out)
    case False{}:
      io_fail_class(Unit, HC.DOutputContainment{}, real_parent, "output parent escapes the site root")

@unsafe def parent_real_finish(+containment_root: Bytes(), +canonical_root: Bytes(), +out: Bytes(),
  +parent: Bytes(), r: HC.HBytesResult()) -> IO(HC.HRes(Unit)):
  match r:
    case Done{+real_parent}:
      parent_real_containment_gate(containment_root, canonical_root, out, real_parent)
    case Fail{error}:
      (+code, +message) = error
      out_io_failure(Unit, parent, "cannot resolve output parent directory", (code, message))

@unsafe def prepare_output_parent_after_mkdir(+containment_root: Bytes(), +canonical_root: Bytes(), +out: Bytes(),
  +parent: Bytes(), r: HC.HRes(Unit)) -> IO(HC.HRes(Unit)):
  match r:
    case Done{value}:
      IO.bind(HC.HBytesResult(), HC.HRes(Unit), HFS.realpath(parent),
        rr => parent_real_finish(containment_root, canonical_root, out, parent, rr))
    case Fail{+failure}:
      HC.io_hres_fail(Unit, failure)

@unsafe def prepare_output_parent_after_validate(+containment_root: Bytes(), +canonical_root: Bytes(), +out: Bytes(), r: HC.HRes(Unit)) -> IO(HC.HRes(Unit)):
  match r:
    case Done{value}:
      +parent = HP.hostpath_dirname(out)
      IO.bind(HC.HRes(Unit), HC.HRes(Unit),
        mkdirs_go_report(output_parent_prefixes(containment_root, parent), parent, "cannot create output parent directory"),
        rr => prepare_output_parent_after_mkdir(containment_root, canonical_root, out, parent, rr))
    case Fail{+failure}:
      HC.io_hres_fail(Unit, failure)

# validate → mkdir -p parent → realpath parent containment → validate again.
@unsafe def prepare_output_parent(+containment_root: Bytes(), +canonical_root: Bytes(), +out: Bytes()) -> IO(HC.HRes(Unit)):
  IO.bind(HC.HRes(Unit), HC.HRes(Unit), validate_output_components(containment_root, out),
    r => prepare_output_parent_after_validate(containment_root, canonical_root, out, r))

# --- output-filesystem ASCII case probing ----------------------------------------------

@unsafe def nearest_fuel(+path: Bytes()) -> Nat:
  Nat.add(Nat.mul(HC.bytes_length(path), 8n), 16n)

@unsafe def nearest_ascend_gate(+cur: Bytes(), +parent: Bytes(), fuel: Nat, same: Bool) -> IO(HC.HRes(Bytes())):
  match same:
    case True{}:
      HC.io_hres_done(Bytes(), cur)
    case False{}:
      nearest_drive(parent, fuel)

@unsafe def nearest_ascend(+cur: Bytes(), fuel: Nat) -> IO(HC.HRes(Bytes())):
  +parent = HP.hostpath_dirname(cur)
  nearest_ascend_gate(cur, parent, fuel, HC.bytes_eq(parent, cur))

@unsafe def nearest_stat_kind_gate(+cur: Bytes(), fuel: Nat, kind: HFS.EntryKind) -> IO(HC.HRes(Bytes())):
  match kind:
    case HFS.EntryDirectory{}:
      HC.io_hres_done(Bytes(), cur)
    case other:
      nearest_ascend(cur, fuel)

@unsafe def nearest_stat_finish(+cur: Bytes(), fuel: Nat, r: HC.HStatResult()) -> IO(HC.HRes(Bytes())):
  match r:
    case Done{+st}:
      match st:
        case HFS.StatInfo{kind, size, dev, ino}:
          nearest_stat_kind_gate(cur, fuel, kind)
    case Fail{error}:
      (+code, +message) = error
      nearest_error_gate(cur, fuel, code, message,
        Bool.or(U32.is_eq(code, HC.errno_enoent()), U32.is_eq(code, HC.errno_enotdir())))

@unsafe def nearest_error_gate(+cur: Bytes(), fuel: Nat, +code: U32, +message: String, missing: Bool) -> IO(HC.HRes(Bytes())):
  match missing:
    case True{}:
      nearest_ascend(cur, fuel)
    case False{}:
      out_io_failure(Bytes(), cur, "cannot inspect output filesystem probe parent", (code, message))

@unsafe def nearest_drive(+cur: Bytes(), fuel: Nat) -> IO(HC.HRes(Bytes())):
  match fuel:
    case 0n:
      out_io_failure(Bytes(), cur, "cannot inspect output filesystem probe parent", (5, "probe parent search fuel exhausted"))
    case 1n++f:
      IO.bind(HC.HStatResult(), HC.HRes(Bytes()), HFS.lstat_info(cur),
        r => nearest_stat_finish(cur, f, r))

@unsafe def nearest_existing_output_directory(+out: Bytes()) -> IO(HC.HRes(Bytes())):
  +start = HP.hostpath_dirname(out)
  nearest_drive(start, nearest_fuel(start))

@unsafe def stat_same_ids(a: HFS.StatInfo, b: HFS.StatInfo) -> Bool:
  match a b:
    case HFS.StatInfo{ak, asz, +adev, +aino} HFS.StatInfo{bk, bsz, +bdev, +bino}:
      Bool.and(HC.u64_parts_eq(adev, bdev), HC.u64_parts_eq(aino, bino))

@unsafe def probe_stat_b_finish(+probe: Bytes(), a: HFS.StatInfo, rb: HC.HStatResult()) -> IO(HC.HRes(Bool)):
  match rb:
    case Done{+b}:
      HC.io_hres_done(Bool, stat_same_ids(a, b))
    case Fail{error}:
      (+code, +message) = error
      out_io_failure(Bool, probe, "cannot inspect output filesystem case probe", (code, message))

@unsafe def probe_stat_a_finish(+probe: Bytes(), +alias: Bytes(), ra: HC.HStatResult()) -> IO(HC.HRes(Bool)):
  match ra:
    case Done{+a}:
      IO.bind(HC.HStatResult(), HC.HRes(Bool), HFS.stat_info(alias),
        rb => probe_stat_b_finish(probe, a, rb))
    case Fail{error}:
      (+code, +message) = error
      out_io_failure(Bool, probe, "cannot inspect output filesystem case probe", (code, message))

@unsafe def probe_alias_kind_gate(+probe: Bytes(), +alias: Bytes(), kind: HFS.EntryKind) -> IO(HC.HRes(Bool)):
  match kind:
    case HFS.EntryDirectory{}:
      IO.bind(HC.HStatResult(), HC.HRes(Bool), HFS.stat_info(probe),
        ra => probe_stat_a_finish(probe, alias, ra))
    case other:
      HC.io_hres_done(Bool, False{})

@unsafe def probe_alias_stat_finish(+probe: Bytes(), +alias: Bytes(), r: HC.HStatResult()) -> IO(HC.HRes(Bool)):
  match r:
    case Done{+st}:
      match st:
        case HFS.StatInfo{kind, size, dev, ino}:
          probe_alias_kind_gate(probe, alias, kind)
    case Fail{error}:
      (+code, +message) = error
      probe_alias_error_gate(probe, alias, code, message,
        Bool.or(U32.is_eq(code, HC.errno_enoent()), U32.is_eq(code, HC.errno_enotdir())))

@unsafe def probe_alias_error_gate(+probe: Bytes(), +alias: Bytes(), +code: U32, +message: String, missing: Bool) -> IO(HC.HRes(Bool)):
  match missing:
    case True{}:
      HC.io_hres_done(Bool, False{})
    case False{}:
      out_io_failure(Bool, alias, "cannot inspect output filesystem case probe alias", (code, message))

@unsafe def probe_compute(+probe: Bytes(), +alias: Bytes()) -> IO(HC.HRes(Bool)):
  IO.bind(HC.HStatResult(), HC.HRes(Bool), HFS.lstat_info(alias),
    r => probe_alias_stat_finish(probe, alias, r))

@unsafe def probe_cleanup_finish(+probe: Bytes(), r: HC.HRes(Bool)) -> IO(HC.HRes(Bool)):
  IO.bind(HC.HRes(Unit), HC.HRes(Bool), best_effort_remove(probe),
    u => IO.pure(HC.HRes(Bool), r))

@unsafe def probe_after_mkdir(+probe: Bytes(), +alias: Bytes(), r: HC.HRes(Unit)) -> IO(HC.HRes(Bool)):
  match r:
    case Done{value}:
      IO.bind(HC.HRes(Bool), HC.HRes(Bool), probe_compute(probe, alias),
        rr => probe_cleanup_finish(probe, rr))
    case Fail{+failure}:
      HC.io_hres_fail(Bool, failure)

@unsafe def ascii_case_probe_named(+parent: Bytes(), +name: Bytes()) -> IO(HC.HRes(Bool)):
  +probe = HP.hostpath_join2(parent, name)
  +alias = HP.hostpath_join2(parent, HC.ascii_upper_bytes(name))
  IO.bind(HC.HRes(Unit), HC.HRes(Bool),
    out_effect(Unit, probe, "cannot create output filesystem case probe", HFS.mkdir_one(probe)),
    r => probe_after_mkdir(probe, alias, r))

@unsafe def probe_name_random_finish(+parent: Bytes(), +now: Nat, r: Result<&1, &1, HC.HostIOError(), U32>) -> IO(HC.HRes(Bool)):
  match r:
    case Done{+rand}:
      ascii_case_probe_named(parent,
        HC.ascii_bytes(".pubend-case-probe-" ++ Nat.show(now) ++ "-" ++ U32.show(rand)))
    case Fail{error}:
      ascii_case_probe_named(parent,
        HC.ascii_bytes(".pubend-case-probe-" ++ Nat.show(now) ++ "-0"))

@unsafe def filesystem_ascii_case_aliases(+parent: Bytes()) -> IO(HC.HRes(Bool)):
  IO.bind(Nat, HC.HRes(Bool), IO.now(),
    now => IO.bind(Result<&1, &1, HC.HostIOError(), U32>, HC.HRes(Bool), IO.random_u32(),
      r => probe_name_random_finish(parent, now, r)))

# --- staged page and manifest writing ----------------------------------------------------

@unsafe def page_rel_text(+id: String) -> String:
  id ++ ".html"

@unsafe def manifest_rel() -> Bytes():
  HC.ascii_bytes("_pubend/manifest.json")

@unsafe def manifest_one(+id: String, +htmlbytes: Bytes()) -> HJ.HostManifestPage:
  HJ.host_manifest_page(id, page_rel_text(id), Sha.sha256_hex(htmlbytes))

@unsafe def stage_file_path_gate(+stage: Bytes(), +rel: Bytes(), +out: Bytes(), bad: Bool) -> IO(HC.HRes(Bytes())):
  match bad:
    case True{}:
      output_containment_failure(Bytes(), out, "emitted page path is absolute or contains NUL")
    case False{}:
      +full = HP.hostpath_resolve1(stage, rel)
      stage_file_path_inside_gate(full, stage, out, HP.hostpath_is_strictly_inside_resolved(full, stage))

@unsafe def stage_file_path_inside_gate(+full: Bytes(), +stage: Bytes(), +out: Bytes(), inside: Bool) -> IO(HC.HRes(Bytes())):
  match inside:
    case True{}:
      HC.io_hres_done(Bytes(), full)
    case False{}:
      output_containment_failure(Bytes(), out, "emitted page path escapes the stage tree")

@unsafe def stage_file_path_io(+stage: Bytes(), +rel: Bytes(), +out: Bytes()) -> IO(HC.HRes(Bytes())):
  stage_file_path_gate(stage, rel, out, Bool.or(HP.hostpath_is_absolute(rel), contains_nul(rel)))

@unsafe def write_one_page_after_path(+stage: Bytes(), +rel: Bytes(), +bytes: Bytes(), +id: String, r: HC.HRes(Bytes())) -> IO(HC.HRes(PageWrite)):
  match r:
    case Done{+full}:
      HC.flow_bind(Unit, PageWrite,
        mkdirs_go_report(parent_prefixes(stage, rel), full, "cannot write staged page"),
        u => HC.flow_bind(Unit, PageWrite,
          out_effect(Unit, full, "cannot write staged page", HFS.write_file_bytes(full, bytes, 0)),
          u2 => HC.io_hres_done(PageWrite, page_write(manifest_one(id, bytes), stage_file(rel, bytes)))))
    case Fail{+failure}:
      HC.io_hres_fail(PageWrite, failure)

@unsafe def write_one_page(+stage: Bytes(), +out: Bytes(), p: Model.EmittedPage) -> IO(HC.HRes(PageWrite)):
  match p:
    case Model.EmittedPage{+id, links, +html}:
      +rel = HC.utf8_bytes_or_empty(page_rel_text(id))
      +bytes = HC.utf8_bytes_or_empty(html)
      IO.bind(HC.HRes(Bytes()), HC.HRes(PageWrite), stage_file_path_io(stage, rel, out),
        r => write_one_page_after_path(stage, rel, bytes, id, r))

@unsafe def stage_file_rel_exists(+rel: Bytes(), xs: List<&2, StageFile>) -> Bool:
  match xs:
    case Nil{}:
      False{}
    case h <> t:
      match h:
        case StageFile{+r, bytes}:
          stage_file_rel_exists_gate(rel, t, HC.bytes_eq(r, rel))

@unsafe def stage_file_rel_exists_gate(+rel: Bytes(), rest: List<&2, StageFile>, eq: Bool) -> Bool:
  match eq:
    case True{}:
      True{}
    case False{}:
      stage_file_rel_exists(rel, rest)

@unsafe def stage_file_lookup_gate(+rel: Bytes(), rest: List<&2, StageFile>, +x: StageFile, eq: Bool) -> Maybe<&2, StageFile>:
  match eq:
    case True{}:
      maybe_stage_file_some(x)
    case False{}:
      stage_file_lookup_go(rel, rest)

@unsafe def stage_file_lookup_go(+rel: Bytes(), xs: List<&2, StageFile>) -> Maybe<&2, StageFile>:
  match xs:
    case Nil{}:
      maybe_stage_file_none()
    case h <> t:
      match h:
        case StageFile{+r, +bytes}:
          stage_file_lookup_gate(rel, t, stage_file(r, bytes), HC.bytes_eq(r, rel))

@unsafe def stage_file_lookup(+rel: Bytes(), +xs: List<&2, StageFile>) -> Maybe<&2, StageFile>:
  stage_file_lookup_go(rel, xs)

@unsafe def duplicate_stage_write(+stage: Bytes(), +rel: Bytes()) -> IO(HC.HRes(WriteAccum)):
  +full = HP.hostpath_join2(stage, rel)
  io_fail_class(WriteAccum, HC.DOutputPathCollision{}, full,
    "unrepresentable output path collision: " ++ HC.bytes_display(rel) ++ " is emitted more than once")

@unsafe def append_page_write(+stage: Bytes(), acc: WriteAccum, +pw: PageWrite) -> IO(HC.HRes(WriteAccum)):
  match acc:
    case WriteAccum{+manifests, +files}:
      match pw:
        case PageWrite{+manifest, +file}:
          match file:
            case StageFile{+rel, +bytes}:
              append_page_write_gate(stage, rel, manifests, files, manifest, file,
                stage_file_rel_exists(rel, files))

@unsafe def append_page_write_gate(+stage: Bytes(), +rel: Bytes(), +manifests: List<&2, HJ.HostManifestPage>,
  +files: List<&2, StageFile>, +manifest: HJ.HostManifestPage, +file: StageFile, duplicate: Bool) -> IO(HC.HRes(WriteAccum)):
  match duplicate:
    case True{}:
      duplicate_stage_write(stage, rel)
    case False{}:
      HC.io_hres_done(WriteAccum, write_accum(
        List.append(&2, HJ.HostManifestPage, manifests, manifest <> Nil{}),
        List.append(&2, StageFile, files, file <> Nil{})))

@unsafe def write_pages_after_one(+stage: Bytes(), +out: Bytes(), rest: List<&2, Model.EmittedPage>, acc: WriteAccum,
  r: HC.HRes(PageWrite)) -> IO(HC.HRes(WriteAccum)):
  match r:
    case Done{+pw}:
      IO.bind(HC.HRes(WriteAccum), HC.HRes(WriteAccum), append_page_write(stage, acc, pw),
        ar => write_pages_accum_finish(stage, out, rest, ar))
    case Fail{+failure}:
      HC.io_hres_fail(WriteAccum, failure)

@unsafe def write_pages_accum_finish(+stage: Bytes(), +out: Bytes(), rest: List<&2, Model.EmittedPage>, r: HC.HRes(WriteAccum)) -> IO(HC.HRes(WriteAccum)):
  match r:
    case Done{+acc}:
      write_pages_go(stage, out, rest, acc)
    case Fail{+failure}:
      HC.io_hres_fail(WriteAccum, failure)

@unsafe def write_pages_go(+stage: Bytes(), +out: Bytes(), xs: List<&2, Model.EmittedPage>, acc: WriteAccum) -> IO(HC.HRes(WriteAccum)):
  match xs:
    case Nil{}:
      HC.io_hres_done(WriteAccum, acc)
    case +h <> t:
      IO.bind(HC.HRes(PageWrite), HC.HRes(WriteAccum), write_one_page(stage, out, h),
        r => write_pages_after_one(stage, out, t, acc, r))

@unsafe def manifest_bytes(+pages: List<&2, HJ.HostManifestPage>) -> Bytes():
  HC.utf8_bytes_or_empty(HJ.hostjson_manifest(pages))

@unsafe def write_manifest_finish(+mpath: Bytes(), +rel: Bytes(), +bytes: Bytes(), r: HC.HRes(Unit)) -> IO(HC.HRes(StageFile)):
  match r:
    case Done{value}:
      HC.io_hres_done(StageFile, stage_file(rel, bytes))
    case Fail{+failure}:
      HC.io_hres_fail(StageFile, failure)

@unsafe def write_manifest_file(+stage: Bytes(), +pages: List<&2, HJ.HostManifestPage>) -> IO(HC.HRes(StageFile)):
  +rel = manifest_rel()
  +mdir = HP.hostpath_join2(stage, HC.ascii_bytes("_pubend"))
  +mpath = HP.hostpath_join2(mdir, HC.ascii_bytes("manifest.json"))
  +bytes = manifest_bytes(pages)
  HC.flow_bind(Unit, StageFile,
    mkdirs_go_report(mdir <> Nil{}, mpath, "cannot write staged manifest"),
    u => IO.bind(HC.HRes(Unit), HC.HRes(StageFile),
      out_effect(Unit, mpath, "cannot write staged manifest", HFS.write_file_bytes(mpath, bytes, 0)),
      r => write_manifest_finish(mpath, rel, bytes, r)))

@unsafe def append_manifest_file(+files: List<&2, StageFile>, +mf: StageFile) -> List<&2, StageFile>:
  List.append(&2, StageFile, files, mf <> Nil{})

@unsafe def write_stage_finish(+files: List<&2, StageFile>, r: HC.HRes(Unit)) -> IO(HC.HRes(StageWrite)):
  match r:
    case Done{value}:
      HC.io_hres_done(StageWrite, stage_write(files))
    case Fail{+failure}:
      HC.io_hres_fail(StageWrite, failure)

@unsafe def write_stage_after_marker_validation(+stage: Bytes(), files: List<&2, StageFile>, r: HC.HRes(Unit)) -> IO(HC.HRes(StageWrite)):
  match r:
    case Done{value}:
      IO.bind(HC.HRes(Unit), HC.HRes(StageWrite),
        remove_ownership_marker(stage, stage_marker_name(), HC.DOutputIo{}, "incomplete stage"),
        rr => write_stage_finish(files, rr))
    case Fail{+failure}:
      HC.io_hres_fail(StageWrite, failure)

@unsafe def write_stage_after_manifest(+stage: Bytes(), acc: WriteAccum, r: HC.HRes(StageFile)) -> IO(HC.HRes(StageWrite)):
  match acc:
    case WriteAccum{manifests, +files}:
      match r:
        case Done{+mf}:
          +allfiles = append_manifest_file(files, mf)
          IO.bind(HC.HRes(Unit), HC.HRes(StageWrite),
            require_ownership_marker(stage, stage_marker_name(), marker_stage_bytes(), HC.DOutputStageInvalid{}, "incomplete stage"),
            rr => write_stage_after_marker_validation(stage, allfiles, rr))
        case Fail{+failure}:
          HC.io_hres_fail(StageWrite, failure)

@unsafe def write_stage_after_pages(+stage: Bytes(), r: HC.HRes(WriteAccum)) -> IO(HC.HRes(StageWrite)):
  match r:
    case Done{+acc}:
      match acc:
        case WriteAccum{+manifests, files}:
          IO.bind(HC.HRes(StageFile), HC.HRes(StageWrite), write_manifest_file(stage, manifests),
            mr => write_stage_after_manifest(stage, acc, mr))
    case Fail{+failure}:
      HC.io_hres_fail(StageWrite, failure)

@unsafe def write_stage_after_marker(+stage: Bytes(), +out: Bytes(), +pages: List<&2, Model.EmittedPage>, r: HC.HRes(Unit)) -> IO(HC.HRes(StageWrite)):
  match r:
    case Done{value}:
      IO.bind(HC.HRes(WriteAccum), HC.HRes(StageWrite), write_pages_go(stage, out, pages, write_accum_empty()),
        rr => write_stage_after_pages(stage, rr))
    case Fail{+failure}:
      HC.io_hres_fail(StageWrite, failure)

@unsafe def write_stage_after_mkdir(+stage: Bytes(), +out: Bytes(), +pages: List<&2, Model.EmittedPage>, r: HC.HRes(Unit)) -> IO(HC.HRes(StageWrite)):
  match r:
    case Done{value}:
      IO.bind(HC.HRes(Unit), HC.HRes(StageWrite),
        write_ownership_marker(stage, stage_marker_name(), marker_stage_bytes(), HC.DOutputIo{}, "incomplete stage"),
        rr => write_stage_after_marker(stage, out, pages, rr))
    case Fail{+failure}:
      HC.io_hres_fail(StageWrite, failure)

# mkdir stage → immediate exclusive incomplete-stage marker → pages → manifest →
# revalidate marker → remove marker.  Failures before marker removal leave the
# marker in place so cleanup can recognize an owned incomplete stage.
@unsafe def write_stage_tree(+stage: Bytes(), +pages: List<&2, Model.EmittedPage>, +out: Bytes()) -> IO(HC.HRes(StageWrite)):
  IO.bind(HC.HRes(Unit), HC.HRes(StageWrite),
    out_effect(Unit, stage, "cannot create fresh stage tree", HFS.mkdir_one(stage)),
    r => write_stage_after_mkdir(stage, out, pages, r))

# --- completed-stage recursive validation -------------------------------------------------

@unsafe def bytes_list_contains(+x: Bytes(), xs: List<&2, Bytes()>) -> Bool:
  match xs:
    case Nil{}:
      False{}
    case +h <> t:
      bytes_list_contains_gate(x, t, HC.bytes_eq(h, x))

@unsafe def bytes_list_contains_gate(+x: Bytes(), rest: List<&2, Bytes()>, eq: Bool) -> Bool:
  match eq:
    case True{}:
      True{}
    case False{}:
      bytes_list_contains(x, rest)

@unsafe def add_unique_bytes(+x: Bytes(), +xs: List<&2, Bytes()>) -> List<&2, Bytes()>:
  add_unique_bytes_gate(x, xs, bytes_list_contains(x, xs))

@unsafe def add_unique_bytes_gate(+x: Bytes(), +xs: List<&2, Bytes()>, present: Bool) -> List<&2, Bytes()>:
  match present:
    case True{}:
      xs
    case False{}:
      x <> xs

@unsafe def expected_dirs_file(+rel: Bytes(), acc: List<&2, Bytes()>) -> List<&2, Bytes()>:
  expected_dirs_prefixes(rel_prefixes(rel), acc)

@unsafe def expected_dirs_prefixes(xs: List<&2, Bytes()>, acc: List<&2, Bytes()>) -> List<&2, Bytes()>:
  match xs:
    case Nil{}:
      acc
    case +h <> t:
      expected_dirs_prefixes(t, add_unique_bytes(h, acc))

@unsafe def expected_dirs_go(xs: List<&2, StageFile>, acc: List<&2, Bytes()>) -> List<&2, Bytes()>:
  match xs:
    case Nil{}:
      acc
    case h <> t:
      match h:
        case StageFile{+rel, bytes}:
          expected_dirs_go(t, expected_dirs_file(rel, acc))

@unsafe def expected_dirs(+files: List<&2, StageFile>) -> List<&2, Bytes()>:
  expected_dirs_go(files, Nil{})

@unsafe def bytes_insert_gate(+x: Bytes(), +h: Bytes(), t: List<&2, Bytes()>, before: Bool) -> List<&2, Bytes()>:
  match before:
    case True{}:
      x <> (h <> t)
    case False{}:
      h <> bytes_insert_sorted(x, t)

@unsafe def bytes_insert_sorted(+x: Bytes(), xs: List<&2, Bytes()>) -> List<&2, Bytes()>:
  match xs:
    case Nil{}:
      x <> Nil{}
    case +h <> t:
      bytes_insert_gate(x, h, t, bytes_list_less(x, h))

@unsafe def bytes_list_less(+x: Bytes(), +y: Bytes()) -> Bool:
  bytes_order_is_less_go(x, y)

@unsafe def bytes_order_is_less_go(xs: Bytes(), ys: Bytes()) -> Bool:
  match xs ys:
    case Nil{} Nil{}:
      False{}
    case Nil{} y:
      True{}
    case x Nil{}:
      False{}
    case +xh <> xt +yh <> yt:
      bytes_less_step(xt, yt, U32.is_eq(xh, yh), U32.is_lt(xh, yh))

@unsafe def bytes_less_step(xs: Bytes(), ys: Bytes(), eq: Bool, lt: Bool) -> Bool:
  match eq:
    case True{}:
      bytes_order_is_less_go(xs, ys)
    case False{}:
      lt

@unsafe def sort_bytes_go(xs: List<&2, Bytes()>, acc: List<&2, Bytes()>) -> List<&2, Bytes()>:
  match xs:
    case Nil{}:
      acc
    case +h <> t:
      sort_bytes_go(t, bytes_insert_sorted(h, acc))

@unsafe def sort_bytes(+xs: List<&2, Bytes()>) -> List<&2, Bytes()>:
  sort_bytes_go(xs, Nil{})

@unsafe def stage_file_insert_gate(+x: StageFile, +h: StageFile, t: List<&2, StageFile>, before: Bool) -> List<&2, StageFile>:
  match before:
    case True{}:
      x <> (h <> t)
    case False{}:
      h <> stage_file_insert_sorted(x, t)

@unsafe def stage_file_insert_sorted(+x: StageFile, xs: List<&2, StageFile>) -> List<&2, StageFile>:
  match x:
    case StageFile{+xr, +xb}:
      match xs:
        case Nil{}:
          stage_file(xr, xb) <> Nil{}
        case +h <> t:
          match h:
            case StageFile{+hr, +hb}:
              stage_file_insert_gate(stage_file(xr, xb), stage_file(hr, hb), t, bytes_list_less(xr, hr))

@unsafe def sort_stage_files_go(xs: List<&2, StageFile>, acc: List<&2, StageFile>) -> List<&2, StageFile>:
  match xs:
    case Nil{}:
      acc
    case +h <> t:
      sort_stage_files_go(t, stage_file_insert_sorted(h, acc))

@unsafe def sort_stage_files(+xs: List<&2, StageFile>) -> List<&2, StageFile>:
  sort_stage_files_go(xs, Nil{})

@unsafe def stage_lstat_error(+path: Bytes(), +code: U32, +message: String, missing: Bool) -> IO(HC.HRes(HFS.StatInfo)):
  match missing:
    case True{}:
      invalid_stage_io(HFS.StatInfo, path, "stage entry disappeared during validation")
    case False{}:
      out_io_failure(HFS.StatInfo, path, "cannot inspect stage entry", (code, message))

@unsafe def stage_lstat_finish(+path: Bytes(), r: HC.HStatResult()) -> IO(HC.HRes(HFS.StatInfo)):
  match r:
    case Done{+st}:
      HC.io_hres_done(HFS.StatInfo, st)
    case Fail{error}:
      (+code, +message) = error
      stage_lstat_error(path, code, message,
        Bool.or(U32.is_eq(code, HC.errno_enoent()), U32.is_eq(code, HC.errno_enotdir())))

@unsafe def lstat_stage_entry(+path: Bytes()) -> IO(HC.HRes(HFS.StatInfo)):
  IO.bind(HC.HStatResult(), HC.HRes(HFS.StatInfo), HFS.lstat_info(path),
    r => stage_lstat_finish(path, r))

@unsafe def validate_read_finish(+full: Bytes(), +rel: Bytes(), +expected: Bytes(), fr: FileRead) -> IO(HC.HRes(Unit)):
  match fr:
    case FileReadErr{+code, +message}:
      out_io_failure(Unit, full, "cannot read staged file during validation", (code, message))
    case FileReadOk{+bytes}:
      validate_bytes_gate(full, rel, HC.bytes_eq(bytes, expected))

@unsafe def validate_bytes_gate(+full: Bytes(), +rel: Bytes(), same: Bool) -> IO(HC.HRes(Unit)):
  match same:
    case True{}:
      HC.io_hres_done(Unit, Unit{})
    case False{}:
      invalid_stage_io(Unit, full, "staged file bytes differ for " ++ HC.bytes_display(rel))

@unsafe def validate_file_expected(+full: Bytes(), +rel: Bytes(), found: Maybe<&2, StageFile>) -> IO(HC.HRes(Unit)):
  match found:
    case None{}:
      invalid_stage_io(Unit, full, "stage contains unexpected file " ++ HC.bytes_display(rel))
    case Some{+sf}:
      match sf:
        case StageFile{+srel, +expected}:
          IO.bind(FileRead, HC.HRes(Unit), read_file_bytes(full),
            fr => validate_read_finish(full, rel, expected, fr))

@unsafe def validate_entry_kind(+stage: Bytes(), +dirfull: Bytes(), +reldir: Bytes(), +rel: Bytes(), +full: Bytes(),
  kind: HFS.EntryKind, +files: List<&2, StageFile>, +dirs: List<&2, Bytes()>) -> IO(HC.HRes(Unit)):
  match kind:
    case HFS.EntrySymlink{}:
      invalid_stage_io(Unit, full, "stage entry " ++ HC.bytes_display(rel) ++ " is a symlink")
    case HFS.EntryDirectory{}:
      validate_entry_directory(stage, rel, full, files, dirs, bytes_list_contains(rel, dirs))
    case HFS.EntryFile{}:
      validate_file_expected(full, rel, stage_file_lookup(rel, files))
    case other:
      invalid_stage_io(Unit, full, "stage entry " ++ HC.bytes_display(rel) ++ " is neither a regular file nor a directory")

@unsafe def validate_entry_directory(+stage: Bytes(), +rel: Bytes(), +full: Bytes(),
  +files: List<&2, StageFile>, +dirs: List<&2, Bytes()>, expected: Bool) -> IO(HC.HRes(Unit)):
  match expected:
    case True{}:
      validate_stage_directory(stage, full, rel, files, dirs)
    case False{}:
      invalid_stage_io(Unit, full, "stage contains unexpected directory " ++ HC.bytes_display(rel))

@unsafe def validate_entry_stat(+stage: Bytes(), +dirfull: Bytes(), +reldir: Bytes(), +rel: Bytes(), +full: Bytes(),
  +files: List<&2, StageFile>, +dirs: List<&2, Bytes()>, r: HC.HRes(HFS.StatInfo)) -> IO(HC.HRes(Unit)):
  match r:
    case Done{+st}:
      match st:
        case HFS.StatInfo{kind, size, dev, ino}:
          validate_entry_kind(stage, dirfull, reldir, rel, full, kind, files, dirs)
    case Fail{+failure}:
      HC.io_hres_fail(Unit, failure)

@unsafe def validate_stage_entry(+stage: Bytes(), +dirfull: Bytes(), +reldir: Bytes(), e: HFS.DirInfo,
  +files: List<&2, StageFile>, +dirs: List<&2, Bytes()>) -> IO(HC.HRes(Unit)):
  match e:
    case HFS.DirInfo{+name, kind}:
      +rel = rel_join(reldir, name)
      +full = HP.hostpath_join2(dirfull, name)
      IO.bind(HC.HRes(HFS.StatInfo), HC.HRes(Unit), lstat_stage_entry(full),
        r => validate_entry_stat(stage, dirfull, reldir, rel, full, files, dirs, r))

@unsafe def validate_stage_entries_go(+stage: Bytes(), +dirfull: Bytes(), +reldir: Bytes(), xs: List<&2, HFS.DirInfo>,
  +files: List<&2, StageFile>, +dirs: List<&2, Bytes()>) -> IO(HC.HRes(Unit)):
  match xs:
    case Nil{}:
      HC.io_hres_done(Unit, Unit{})
    case +h <> t:
      HC.flow_bind(Unit, Unit, validate_stage_entry(stage, dirfull, reldir, h, files, dirs),
        u => validate_stage_entries_go(stage, dirfull, reldir, t, files, dirs))

@unsafe def validate_stage_readdir_finish(+stage: Bytes(), +dirfull: Bytes(), +reldir: Bytes(),
  +files: List<&2, StageFile>, +dirs: List<&2, Bytes()>, r: HC.HEntriesResult()) -> IO(HC.HRes(Unit)):
  match r:
    case Done{+entries}:
      validate_stage_entries_go(stage, dirfull, reldir, entries, files, dirs)
    case Fail{error}:
      (+code, +message) = error
      out_io_failure(Unit, dirfull, "cannot read stage directory during validation", (code, message))

@unsafe def validate_stage_directory(+stage: Bytes(), +dirfull: Bytes(), +reldir: Bytes(),
  +files: List<&2, StageFile>, +dirs: List<&2, Bytes()>) -> IO(HC.HRes(Unit)):
  IO.bind(HC.HEntriesResult(), HC.HRes(Unit), HFS.readdir_info(dirfull),
    r => validate_stage_readdir_finish(stage, dirfull, reldir, files, dirs, r))

@unsafe def expected_file_stat_gate(+full: Bytes(), +rel: Bytes(), kind: HFS.EntryKind) -> IO(HC.HRes(Unit)):
  match kind:
    case HFS.EntryFile{}:
      HC.io_hres_done(Unit, Unit{})
    case other:
      invalid_stage_io(Unit, full, "expected staged file " ++ HC.bytes_display(rel) ++ " is missing")

@unsafe def expected_file_stat_finish(+full: Bytes(), +rel: Bytes(), r: HC.HStatResult()) -> IO(HC.HRes(Unit)):
  match r:
    case Done{+st}:
      match st:
        case HFS.StatInfo{kind, size, dev, ino}:
          expected_file_stat_gate(full, rel, kind)
    case Fail{error}:
      (+code, +message) = error
      expected_file_error_gate(full, rel, code, message,
        Bool.or(U32.is_eq(code, HC.errno_enoent()), U32.is_eq(code, HC.errno_enotdir())))

@unsafe def expected_file_error_gate(+full: Bytes(), +rel: Bytes(), +code: U32, +message: String, missing: Bool) -> IO(HC.HRes(Unit)):
  match missing:
    case True{}:
      invalid_stage_io(Unit, full, "expected staged file " ++ HC.bytes_display(rel) ++ " is missing")
    case False{}:
      out_io_failure(Unit, full, "cannot inspect stage entry", (code, message))

@unsafe def validate_expected_file(+stage: Bytes(), sf: StageFile) -> IO(HC.HRes(Unit)):
  match sf:
    case StageFile{+rel, bytes}:
      +full = HP.hostpath_join2(stage, rel)
      IO.bind(HC.HStatResult(), HC.HRes(Unit), HFS.lstat_info(full),
        r => expected_file_stat_finish(full, rel, r))

@unsafe def validate_expected_files_go(+stage: Bytes(), xs: List<&2, StageFile>) -> IO(HC.HRes(Unit)):
  match xs:
    case Nil{}:
      HC.io_hres_done(Unit, Unit{})
    case +h <> t:
      HC.flow_bind(Unit, Unit, validate_expected_file(stage, h),
        u => validate_expected_files_go(stage, t))

@unsafe def expected_dir_stat_gate(+full: Bytes(), +rel: Bytes(), kind: HFS.EntryKind) -> IO(HC.HRes(Unit)):
  match kind:
    case HFS.EntryDirectory{}:
      HC.io_hres_done(Unit, Unit{})
    case other:
      invalid_stage_io(Unit, full, "expected stage directory " ++ HC.bytes_display(rel) ++ " is missing")

@unsafe def expected_dir_stat_finish(+full: Bytes(), +rel: Bytes(), r: HC.HStatResult()) -> IO(HC.HRes(Unit)):
  match r:
    case Done{+st}:
      match st:
        case HFS.StatInfo{kind, size, dev, ino}:
          expected_dir_stat_gate(full, rel, kind)
    case Fail{error}:
      (+code, +message) = error
      expected_dir_error_gate(full, rel, code, message,
        Bool.or(U32.is_eq(code, HC.errno_enoent()), U32.is_eq(code, HC.errno_enotdir())))

@unsafe def expected_dir_error_gate(+full: Bytes(), +rel: Bytes(), +code: U32, +message: String, missing: Bool) -> IO(HC.HRes(Unit)):
  match missing:
    case True{}:
      invalid_stage_io(Unit, full, "expected stage directory " ++ HC.bytes_display(rel) ++ " is missing")
    case False{}:
      out_io_failure(Unit, full, "cannot inspect stage entry", (code, message))

@unsafe def validate_expected_dir(+stage: Bytes(), +rel: Bytes()) -> IO(HC.HRes(Unit)):
  +full = HP.hostpath_join2(stage, rel)
  IO.bind(HC.HStatResult(), HC.HRes(Unit), HFS.lstat_info(full),
    r => expected_dir_stat_finish(full, rel, r))

@unsafe def validate_expected_dirs_go(+stage: Bytes(), xs: List<&2, Bytes()>) -> IO(HC.HRes(Unit)):
  match xs:
    case Nil{}:
      HC.io_hres_done(Unit, Unit{})
    case +h <> t:
      HC.flow_bind(Unit, Unit, validate_expected_dir(stage, h),
        u => validate_expected_dirs_go(stage, t))

@unsafe def validate_expected_after_walk(+stage: Bytes(), +files: List<&2, StageFile>, +dirs: List<&2, Bytes()>, r: HC.HRes(Unit)) -> IO(HC.HRes(Unit)):
  match r:
    case Done{value}:
      HC.flow_bind(Unit, Unit, validate_expected_files_go(stage, sort_stage_files(files)),
        u => validate_expected_dirs_go(stage, sort_bytes(dirs)))
    case Fail{+failure}:
      HC.io_hres_fail(Unit, failure)

@unsafe def validate_root_kind(+stage: Bytes(), kind: HFS.EntryKind,
  +files: List<&2, StageFile>, +dirs: List<&2, Bytes()>) -> IO(HC.HRes(Unit)):
  match kind:
    case HFS.EntryDirectory{}:
      IO.bind(HC.HRes(Unit), HC.HRes(Unit),
        validate_stage_directory(stage, stage, Nil{}, files, dirs),
        r => validate_expected_after_walk(stage, files, dirs, r))
    case other:
      invalid_stage_io(Unit, stage, "completed stage root is not a plain directory")

@unsafe def validate_root_stat(+stage: Bytes(), +files: List<&2, StageFile>, +dirs: List<&2, Bytes()>, r: HC.HRes(HFS.StatInfo)) -> IO(HC.HRes(Unit)):
  match r:
    case Done{+st}:
      match st:
        case HFS.StatInfo{kind, size, dev, ino}:
          validate_root_kind(stage, kind, files, dirs)
    case Fail{+failure}:
      HC.io_hres_fail(Unit, failure)

# Recursive exact-tree validation: no symlinks or special entries, no extra
# files/directories, every expected file present with exact bytes, and every
# expected directory present.  The stage marker has already been removed, so it
# is correctly absent from the expected tree.
@unsafe def validate_completed_stage(+stage: Bytes(), +files: List<&2, StageFile>) -> IO(HC.HRes(Unit)):
  +dirs = expected_dirs(files)
  IO.bind(HC.HRes(HFS.StatInfo), HC.HRes(Unit), lstat_stage_entry(stage),
    r => validate_root_stat(stage, files, dirs, r))

# --- ownership-aware recovery --------------------------------------------------------------

@unsafe def plain_directory_kind(kind: HFS.EntryKind) -> Bool:
  match kind:
    case HFS.EntryDirectory{}:
      True{}
    case other:
      False{}

@unsafe def validate_existing_output(+out: Bytes(), st: HFS.StatInfo) -> IO(HC.HRes(Unit)):
  match st:
    case HFS.StatInfo{kind, size, dev, ino}:
      validate_existing_output_kind(out, kind)

@unsafe def validate_existing_output_kind(+out: Bytes(), kind: HFS.EntryKind) -> IO(HC.HRes(Unit)):
  match kind:
    case HFS.EntrySymlink{}:
      io_fail_class(Unit, HC.DOutputSymlink{}, out, "symlinked pre-existing output path is a host failure")
    case HFS.EntryDirectory{}:
      HC.io_hres_done(Unit, Unit{})
    case other:
      io_fail_class(Unit, HC.DOutputNotDirectory{}, out, "pre-existing output path is not a directory")

@unsafe def restore_rename_backup(+out: Bytes(), +backup: Bytes()) -> IO(HC.HRes(Unit)):
  out_effect(Unit, backup, "cannot restore fixed backup before building", HFS.rename(backup, out))

@unsafe def restore_after_marker(+out: Bytes(), +backup: Bytes(), r: HC.HRes(Unit)) -> IO(HC.HRes(Unit)):
  match r:
    case Done{value}:
      restore_rename_backup(out, backup)
    case Fail{+failure}:
      HC.io_hres_fail(Unit, failure)

@unsafe def restore_after_require(+out: Bytes(), +backup: Bytes(), r: HC.HRes(Unit)) -> IO(HC.HRes(Unit)):
  match r:
    case Done{value}:
      IO.bind(HC.HRes(Unit), HC.HRes(Unit),
        remove_ownership_marker(backup, backup_marker_name(), HC.DOutputBackupInvalid{}, "fixed backup"),
        rr => restore_after_marker(out, backup, rr))
    case Fail{+failure}:
      HC.io_hres_fail(Unit, failure)

@unsafe def restore_backup_stat_gate(+out: Bytes(), +backup: Bytes(), m: Maybe<&2, HFS.StatInfo>) -> IO(HC.HRes(Unit)):
  match m:
    case None{}:
      backup_invalid_io(Unit, backup, "fixed backup is not a plain directory and cannot be restored")
    case Some{+st}:
      match st:
        case HFS.StatInfo{kind, size, dev, ino}:
          restore_backup_kind_gate(out, backup, kind)

@unsafe def restore_backup_kind_gate(+out: Bytes(), +backup: Bytes(), kind: HFS.EntryKind) -> IO(HC.HRes(Unit)):
  match kind:
    case HFS.EntryDirectory{}:
      IO.bind(HC.HRes(Unit), HC.HRes(Unit),
        require_ownership_marker(backup, backup_marker_name(), marker_backup_bytes(), HC.DOutputBackupInvalid{}, "fixed backup"),
        r => restore_after_require(out, backup, r))
    case other:
      backup_invalid_io(Unit, backup, "fixed backup is not a plain directory and cannot be restored")

@unsafe def restore_after_backup_lstat(+out: Bytes(), +backup: Bytes(), r: HC.HRes(Maybe<&2, HFS.StatInfo>)) -> IO(HC.HRes(Unit)):
  match r:
    case Done{+m}:
      restore_backup_stat_gate(out, backup, m)
    case Fail{+failure}:
      HC.io_hres_fail(Unit, failure)

@unsafe def restore_out_stat_gate(+out: Bytes(), +backup: Bytes(), m: Maybe<&2, HFS.StatInfo>) -> IO(HC.HRes(Unit)):
  match m:
    case Some{st}:
      backup_conflict_io(Unit, backup, "both output and fixed backup exist; refusing to choose between them")
    case None{}:
      IO.bind(HC.HRes(Maybe<&2, HFS.StatInfo>), HC.HRes(Unit), lstat_maybe(backup),
        r => restore_after_backup_lstat(out, backup, r))

@unsafe def restore_after_out_lstat(+out: Bytes(), +backup: Bytes(), r: HC.HRes(Maybe<&2, HFS.StatInfo>)) -> IO(HC.HRes(Unit)):
  match r:
    case Done{+m}:
      restore_out_stat_gate(out, backup, m)
    case Fail{+failure}:
      HC.io_hres_fail(Unit, failure)

# Restore an owned fixed backup only when output is absent, the backup is a
# plain directory, and its exact ownership marker validates.  The marker is
# unlinked before the rename, exactly as in the reference host.
@unsafe def restore_owned_backup(+out: Bytes(), +backup: Bytes()) -> IO(HC.HRes(Unit)):
  IO.bind(HC.HRes(Maybe<&2, HFS.StatInfo>), HC.HRes(Unit), lstat_maybe(out),
    r => restore_after_out_lstat(out, backup, r))

@unsafe def recover_stage_after_marker(+stage: Bytes(), r: HC.HRes(Unit)) -> IO(HC.HRes(Unit)):
  match r:
    case Done{value}:
      remove_path_for_publication(stage, "marker-owned incomplete stage tree")
    case Fail{+failure}:
      HC.io_hres_fail(Unit, failure)

@unsafe def recover_stage_kind_gate(+stage: Bytes(), kind: HFS.EntryKind) -> IO(HC.HRes(Unit)):
  match kind:
    case HFS.EntryDirectory{}:
      IO.bind(HC.HRes(Unit), HC.HRes(Unit),
        require_ownership_marker(stage, stage_marker_name(), marker_stage_bytes(), HC.DOutputStageInvalid{}, "incomplete stage"),
        r => recover_stage_after_marker(stage, r))
    case other:
      invalid_stage_io(Unit, stage, "fixed stage is not a plain directory and cannot be removed safely")

@unsafe def recover_stage_stat_gate(+stage: Bytes(), m: Maybe<&2, HFS.StatInfo>) -> IO(HC.HRes(Unit)):
  match m:
    case None{}:
      HC.io_hres_done(Unit, Unit{})
    case Some{+st}:
      match st:
        case HFS.StatInfo{kind, size, dev, ino}:
          recover_stage_kind_gate(stage, kind)

@unsafe def recover_stage_finish(+stage: Bytes(), r: HC.HRes(Maybe<&2, HFS.StatInfo>)) -> IO(HC.HRes(Unit)):
  match r:
    case Done{+m}:
      recover_stage_stat_gate(stage, m)
    case Fail{+failure}:
      HC.io_hres_fail(Unit, failure)

@unsafe def recover_stage(+stage: Bytes()) -> IO(HC.HRes(Unit)):
  IO.bind(HC.HRes(Maybe<&2, HFS.StatInfo>), HC.HRes(Unit), lstat_maybe(stage),
    r => recover_stage_finish(stage, r))

@unsafe def recovered_output_gate(+out: Bytes(), +stage: Bytes(), m: Maybe<&2, HFS.StatInfo>) -> IO(HC.HRes(Unit)):
  match m:
    case Some{+st}:
      match st:
        case HFS.StatInfo{kind, size, dev, ino}:
          recovered_output_kind_gate(out, stage, kind)
    case None{}:
      io_fail_class(Unit, HC.DOutputIo{}, out, "fixed backup restoration did not produce a plain output directory")

@unsafe def recovered_output_kind_gate(+out: Bytes(), +stage: Bytes(), kind: HFS.EntryKind) -> IO(HC.HRes(Unit)):
  match kind:
    case HFS.EntryDirectory{}:
      recover_stage(stage)
    case other:
      io_fail_class(Unit, HC.DOutputIo{}, out, "fixed backup restoration did not produce a plain output directory")

@unsafe def recovered_output_finish(+out: Bytes(), +stage: Bytes(), r: HC.HRes(Maybe<&2, HFS.StatInfo>)) -> IO(HC.HRes(Unit)):
  match r:
    case Done{+m}:
      recovered_output_gate(out, stage, m)
    case Fail{+failure}:
      HC.io_hres_fail(Unit, failure)

@unsafe def recover_after_restore(+out: Bytes(), +stage: Bytes(), r: HC.HRes(Unit)) -> IO(HC.HRes(Unit)):
  match r:
    case Done{value}:
      IO.bind(HC.HRes(Maybe<&2, HFS.StatInfo>), HC.HRes(Unit), lstat_maybe(out),
        rr => recovered_output_finish(out, stage, rr))
    case Fail{+failure}:
      HC.io_hres_fail(Unit, failure)

@unsafe def recover_no_out_backup_gate(+out: Bytes(), +stage: Bytes(), +backup: Bytes(), m: Maybe<&2, HFS.StatInfo>) -> IO(HC.HRes(Unit)):
  match m:
    case None{}:
      recover_stage(stage)
    case Some{st}:
      IO.bind(HC.HRes(Unit), HC.HRes(Unit), restore_owned_backup(out, backup),
        r => recover_after_restore(out, stage, r))

@unsafe def recover_existing_out_backup_gate(+out: Bytes(), +stage: Bytes(), +backup: Bytes(), m: Maybe<&2, HFS.StatInfo>) -> IO(HC.HRes(Unit)):
  match m:
    case None{}:
      recover_stage(stage)
    case Some{st}:
      backup_conflict_io(Unit, backup, "both output and fixed backup exist; refusing to choose between them")

@unsafe def recover_after_output_valid(+out: Bytes(), +stage: Bytes(), +backup: Bytes(),
  out_present: Bool, backupm: Maybe<&2, HFS.StatInfo>, r: HC.HRes(Unit)) -> IO(HC.HRes(Unit)):
  match r:
    case Done{value}:
      recover_backup_branch(out, stage, backup, out_present, backupm)
    case Fail{+failure}:
      HC.io_hres_fail(Unit, failure)

@unsafe def recover_backup_branch(+out: Bytes(), +stage: Bytes(), +backup: Bytes(),
  out_present: Bool, backupm: Maybe<&2, HFS.StatInfo>) -> IO(HC.HRes(Unit)):
  match out_present:
    case True{}:
      recover_existing_out_backup_gate(out, stage, backup, backupm)
    case False{}:
      recover_no_out_backup_gate(out, stage, backup, backupm)

@unsafe def recover_out_stat_gate(+out: Bytes(), +stage: Bytes(), +backup: Bytes(),
  outm: Maybe<&2, HFS.StatInfo>, backupm: Maybe<&2, HFS.StatInfo>) -> IO(HC.HRes(Unit)):
  match outm:
    case Some{+outst}:
      IO.bind(HC.HRes(Unit), HC.HRes(Unit), validate_existing_output(out, outst),
        r => recover_after_output_valid(out, stage, backup, True{}, backupm, r))
    case None{}:
      recover_backup_branch(out, stage, backup, False{}, backupm)

@unsafe def recover_stats(+out: Bytes(), +stage: Bytes(), +backup: Bytes(),
  outm: Maybe<&2, HFS.StatInfo>, backupm: Maybe<&2, HFS.StatInfo>) -> IO(HC.HRes(Unit)):
  recover_out_stat_gate(out, stage, backup, outm, backupm)

@unsafe def recover_after_backup_stat(+out: Bytes(), +stage: Bytes(), +backup: Bytes(),
  outm: Maybe<&2, HFS.StatInfo>, rb: HC.HRes(Maybe<&2, HFS.StatInfo>)) -> IO(HC.HRes(Unit)):
  match rb:
    case Done{+backupm}:
      recover_stats(out, stage, backup, outm, backupm)
    case Fail{+failure}:
      HC.io_hres_fail(Unit, failure)

@unsafe def recover_after_out_stat(+out: Bytes(), +stage: Bytes(), +backup: Bytes(), ro: HC.HRes(Maybe<&2, HFS.StatInfo>)) -> IO(HC.HRes(Unit)):
  match ro:
    case Done{+outm}:
      IO.bind(HC.HRes(Maybe<&2, HFS.StatInfo>), HC.HRes(Unit), lstat_maybe(backup),
        rb => recover_after_backup_stat(out, stage, backup, outm, rb))
    case Fail{+failure}:
      HC.io_hres_fail(Unit, failure)

# Recovery order is contractual: output/backup conflict and owned backup
# restoration first; only then inspect and remove a marker-owned incomplete
# stage.  Foreign or invalid stage/backup trees are preserved.
@unsafe def recover_publication_state(+out: Bytes(), +stage: Bytes(), +backup: Bytes()) -> IO(HC.HRes(Unit)):
  IO.bind(HC.HRes(Maybe<&2, HFS.StatInfo>), HC.HRes(Unit), lstat_maybe(out),
    r => recover_after_out_stat(out, stage, backup, r))

# --- backup rotation and stage swap -----------------------------------------------------------

@unsafe def ensure_backup_marker_slot_finish(+marker: Bytes(), r: HC.HRes(Maybe<&2, HFS.StatInfo>)) -> IO(HC.HRes(Unit)):
  match r:
    case Done{+m}:
      ensure_backup_marker_slot_gate(marker, m)
    case Fail{+failure}:
      HC.io_hres_fail(Unit, failure)

@unsafe def ensure_backup_marker_slot_gate(+marker: Bytes(), m: Maybe<&2, HFS.StatInfo>) -> IO(HC.HRes(Unit)):
  match m:
    case None{}:
      HC.io_hres_done(Unit, Unit{})
    case Some{st}:
      backup_invalid_io(Unit, marker, "output already contains the fixed backup ownership marker path")

@unsafe def ensure_backup_marker_slot_available(+out: Bytes()) -> IO(HC.HRes(Unit)):
  +marker = HP.hostpath_join2(out, backup_marker_name())
  IO.bind(HC.HRes(Maybe<&2, HFS.StatInfo>), HC.HRes(Unit), lstat_maybe(marker),
    r => ensure_backup_marker_slot_finish(marker, r))

@unsafe def remove_owned_backup_kind_gate(+backup: Bytes(), kind: HFS.EntryKind) -> IO(HC.HRes(Unit)):
  match kind:
    case HFS.EntryDirectory{}:
      HC.flow_bind(Unit, Unit,
        require_ownership_marker(backup, backup_marker_name(), marker_backup_bytes(), HC.DOutputBackupInvalid{}, "fixed backup"),
        u => remove_path_for_publication(backup, "marker-owned fixed backup"))
    case other:
      backup_invalid_io(Unit, backup, "fixed backup is not a plain marker-owned directory and cannot be removed safely")

@unsafe def remove_owned_backup_stat_gate(+backup: Bytes(), m: Maybe<&2, HFS.StatInfo>) -> IO(HC.HRes(Unit)):
  match m:
    case None{}:
      backup_invalid_io(Unit, backup, "fixed backup is not a plain marker-owned directory and cannot be removed safely")
    case Some{+st}:
      match st:
        case HFS.StatInfo{kind, size, dev, ino}:
          remove_owned_backup_kind_gate(backup, kind)

@unsafe def remove_owned_backup_finish(+backup: Bytes(), r: HC.HRes(Maybe<&2, HFS.StatInfo>)) -> IO(HC.HRes(Unit)):
  match r:
    case Done{+m}:
      remove_owned_backup_stat_gate(backup, m)
    case Fail{+failure}:
      HC.io_hres_fail(Unit, failure)

@unsafe def remove_owned_backup(+backup: Bytes()) -> IO(HC.HRes(Unit)):
  IO.bind(HC.HRes(Maybe<&2, HFS.StatInfo>), HC.HRes(Unit), lstat_maybe(backup),
    r => remove_owned_backup_finish(backup, r))

@unsafe def finish_backup_remove(+backup: Bytes(), moved: Bool) -> IO(HC.HRes(Unit)):
  match moved:
    case False{}:
      HC.io_hres_done(Unit, Unit{})
    case True{}:
      remove_owned_backup(backup)

@unsafe def best_effort_restore_result(r: HC.HRes(Unit)) -> IO(HC.HRes(Unit)):
  best_effort_result(r)

@unsafe def try_restore_owned_backup(+out: Bytes(), +backup: Bytes()) -> IO(HC.HRes(Unit)):
  IO.bind(HC.HRes(Unit), HC.HRes(Unit), restore_owned_backup(out, backup), best_effort_restore_result)

@unsafe def stage_rename_error_finish(+stage: Bytes(), +code: U32, +message: String, r: HC.HRes(Unit)) -> IO(HC.HRes(Unit)):
  HC.io_fail_one(Unit, 3, publication_diag(stage, "cannot move completed stage tree into place", (code, message)))

@unsafe def stage_rename_error_restore(+out: Bytes(), +stage: Bytes(), +backup: Bytes(), +code: U32, +message: String, moved: Bool) -> IO(HC.HRes(Unit)):
  match moved:
    case True{}:
      IO.bind(HC.HRes(Unit), HC.HRes(Unit), try_restore_owned_backup(out, backup),
        r => stage_rename_error_finish(stage, code, message, r))
    case False{}:
      publication_error_direct(stage, code, message)

@unsafe def publication_error_direct(+stage: Bytes(), +code: U32, +message: String) -> IO(HC.HRes(Unit)):
  HC.io_fail_one(Unit, 3, publication_diag(stage, "cannot move completed stage tree into place", (code, message)))

@unsafe def swap_rename_stage_finish(+out: Bytes(), +stage: Bytes(), +backup: Bytes(), moved: Bool, r: HC.HUnitResult()) -> IO(HC.HRes(Unit)):
  match r:
    case Done{value}:
      finish_backup_remove(backup, moved)
    case Fail{error}:
      (+code, +message) = error
      stage_rename_error_restore(out, stage, backup, code, message, moved)

@unsafe def swap_rename_stage(+out: Bytes(), +stage: Bytes(), +backup: Bytes(), moved: Bool) -> IO(HC.HRes(Unit)):
  IO.bind(HC.HUnitResult(), HC.HRes(Unit), HFS.rename(stage, out),
    r => swap_rename_stage_finish(out, stage, backup, moved, r))

@unsafe def swap_after_backup_marker(+out: Bytes(), +stage: Bytes(), +backup: Bytes(), r: HC.HRes(Unit)) -> IO(HC.HRes(Unit)):
  match r:
    case Done{value}:
      swap_rename_stage(out, stage, backup, True{})
    case Fail{+failure}:
      HC.io_hres_fail(Unit, failure)

@unsafe def swap_after_output_rename(+out: Bytes(), +stage: Bytes(), +backup: Bytes(), r: HC.HRes(Unit)) -> IO(HC.HRes(Unit)):
  match r:
    case Done{value}:
      IO.bind(HC.HRes(Unit), HC.HRes(Unit),
        write_ownership_marker(backup, backup_marker_name(), marker_backup_bytes(), HC.DOutputPublication{}, "fixed backup"),
        rr => swap_after_backup_marker(out, stage, backup, rr))
    case Fail{+failure}:
      HC.io_hres_fail(Unit, failure)

@unsafe def swap_after_marker_slot(+out: Bytes(), +stage: Bytes(), +backup: Bytes(), r: HC.HRes(Unit)) -> IO(HC.HRes(Unit)):
  match r:
    case Done{value}:
      IO.bind(HC.HRes(Unit), HC.HRes(Unit),
        publication_effect(Unit, out, "cannot move existing output to fixed backup", HFS.rename(out, backup)),
        rr => swap_after_output_rename(out, stage, backup, rr))
    case Fail{+failure}:
      HC.io_hres_fail(Unit, failure)

@unsafe def swap_move_output(+out: Bytes(), +stage: Bytes(), +backup: Bytes()) -> IO(HC.HRes(Unit)):
  IO.bind(HC.HRes(Unit), HC.HRes(Unit), ensure_backup_marker_slot_available(out),
    r => swap_after_marker_slot(out, stage, backup, r))

@unsafe def swap_decide(+out: Bytes(), +stage: Bytes(), +backup: Bytes(), out_exists: Bool) -> IO(HC.HRes(Unit)):
  match out_exists:
    case True{}:
      swap_move_output(out, stage, backup)
    case False{}:
      swap_rename_stage(out, stage, backup, False{})

@unsafe def swap_backup_gate(+out: Bytes(), +stage: Bytes(), +backup: Bytes(), out_exists: Bool, m: Maybe<&2, HFS.StatInfo>) -> IO(HC.HRes(Unit)):
  match m:
    case None{}:
      swap_decide(out, stage, backup, out_exists)
    case Some{st}:
      backup_conflict_io(Unit, backup, "fixed backup already exists before the publication swap")

@unsafe def swap_after_output_valid(+out: Bytes(), +stage: Bytes(), +backup: Bytes(), out_exists: Bool,
  backupm: Maybe<&2, HFS.StatInfo>, r: HC.HRes(Unit)) -> IO(HC.HRes(Unit)):
  match r:
    case Done{value}:
      swap_backup_gate(out, stage, backup, out_exists, backupm)
    case Fail{+failure}:
      HC.io_hres_fail(Unit, failure)

@unsafe def swap_out_stat_gate(+out: Bytes(), +stage: Bytes(), +backup: Bytes(),
  outm: Maybe<&2, HFS.StatInfo>, backupm: Maybe<&2, HFS.StatInfo>) -> IO(HC.HRes(Unit)):
  match outm:
    case Some{+outst}:
      IO.bind(HC.HRes(Unit), HC.HRes(Unit), validate_existing_output(out, outst),
        r => swap_after_output_valid(out, stage, backup, True{}, backupm, r))
    case None{}:
      swap_backup_gate(out, stage, backup, False{}, backupm)

@unsafe def swap_after_backup_lstat(+out: Bytes(), +stage: Bytes(), +backup: Bytes(),
  outm: Maybe<&2, HFS.StatInfo>, rb: HC.HRes(Maybe<&2, HFS.StatInfo>)) -> IO(HC.HRes(Unit)):
  match rb:
    case Done{+backupm}:
      swap_out_stat_gate(out, stage, backup, outm, backupm)
    case Fail{+failure}:
      HC.io_hres_fail(Unit, failure)

@unsafe def swap_after_out_lstat(+out: Bytes(), +stage: Bytes(), +backup: Bytes(), ro: HC.HRes(Maybe<&2, HFS.StatInfo>)) -> IO(HC.HRes(Unit)):
  match ro:
    case Done{+outm}:
      IO.bind(HC.HRes(Maybe<&2, HFS.StatInfo>), HC.HRes(Unit), lstat_maybe(backup),
        rb => swap_after_backup_lstat(out, stage, backup, outm, rb))
    case Fail{+failure}:
      HC.io_hres_fail(Unit, failure)

@unsafe def swap_stage_into_place(+out: Bytes(), +stage: Bytes(), +backup: Bytes()) -> IO(HC.HRes(Unit)):
  IO.bind(HC.HRes(Maybe<&2, HFS.StatInfo>), HC.HRes(Unit), lstat_maybe(out),
    r => swap_after_out_lstat(out, stage, backup, r))

# --- critical section, cleanup, and lock release ------------------------------------------------

@unsafe def lock_diag(+lock: Bytes()) -> HC.HostDiag:
  HC.host_diag_path(HC.DOutputLockExists{}, HC.bytes_display(lock),
    "publication lock already exists; it is never silently removed")

@unsafe def acquire_lock_finish(+lock: Bytes(), r: HC.HUnitResult()) -> IO(HC.HRes(Unit)):
  match r:
    case Done{value}:
      HC.io_hres_done(Unit, Unit{})
    case Fail{error}:
      (+code, +message) = error
      acquire_lock_gate(lock, code, message, U32.is_eq(code, HC.errno_eexist()))

@unsafe def acquire_lock_gate(+lock: Bytes(), +code: U32, +message: String, exists: Bool) -> IO(HC.HRes(Unit)):
  match exists:
    case True{}:
      HC.io_fail_one(Unit, 3, lock_diag(lock))
    case False{}:
      out_io_failure(Unit, lock, "cannot acquire publication lock", (code, message))

@unsafe def acquire_lock(+lock: Bytes()) -> IO(HC.HRes(Unit)):
  IO.bind(HC.HUnitResult(), HC.HRes(Unit), HFS.mkdir_one(lock),
    r => acquire_lock_finish(lock, r))

@unsafe def release_lock_effect(+lock: Bytes()) -> IO(HC.HRes(Unit)):
  out_effect(Unit, lock, "cannot release publication lock", HFS.rmdir(lock))

@unsafe def attempt_owned_stage_cleanup_kind(+stage: Bytes(), kind: HFS.EntryKind) -> IO(HC.HRes(Unit)):
  match kind:
    case HFS.EntryDirectory{}:
      HC.flow_bind(Unit, Unit,
        require_ownership_marker(stage, stage_marker_name(), marker_stage_bytes(), HC.DOutputStageInvalid{}, "incomplete stage"),
        u => remove_tree(stage))
    case other:
      HC.io_hres_done(Unit, Unit{})

@unsafe def attempt_owned_stage_cleanup_stat(+stage: Bytes(), m: Maybe<&2, HFS.StatInfo>) -> IO(HC.HRes(Unit)):
  match m:
    case None{}:
      HC.io_hres_done(Unit, Unit{})
    case Some{+st}:
      match st:
        case HFS.StatInfo{kind, size, dev, ino}:
          attempt_owned_stage_cleanup_kind(stage, kind)

@unsafe def attempt_owned_stage_cleanup_finish(+stage: Bytes(), r: HC.HRes(Maybe<&2, HFS.StatInfo>)) -> IO(HC.HRes(Unit)):
  match r:
    case Done{+m}:
      attempt_owned_stage_cleanup_stat(stage, m)
    case Fail{+failure}:
      HC.io_hres_fail(Unit, failure)

@unsafe def attempt_owned_stage_cleanup(+stage: Bytes()) -> IO(HC.HRes(Unit)):
  IO.bind(HC.HRes(Maybe<&2, HFS.StatInfo>), HC.HRes(Unit), lstat_maybe(stage),
    r => attempt_owned_stage_cleanup_finish(stage, r))

# Best-effort stage cleanup is ownership-gated.  A foreign, unmarked, corrupt,
# symlinked, or non-directory stage is preserved, and every cleanup error is
# swallowed so the primary diagnostic wins.
@unsafe def best_effort_remove_stage(+stage: Bytes()) -> IO(HC.HRes(Unit)):
  IO.bind(HC.HRes(Unit), HC.HRes(Unit), attempt_owned_stage_cleanup(stage), best_effort_result)

@unsafe def cleanup_original_failure_finish(+failure: HC.HostFailure, rr: HC.HRes(Unit)) -> IO(HC.HRes(Unit)):
  HC.io_hres_fail(Unit, failure)

@unsafe def cleanup_original_failure_after_stage(+lock: Bytes(), +failure: HC.HostFailure, sr: HC.HRes(Unit)) -> IO(HC.HRes(Unit)):
  IO.bind(HC.HRes(Unit), HC.HRes(Unit), release_lock_effect(lock),
    rr => cleanup_original_failure_finish(failure, rr))

@unsafe def cleanup_original_failure(+stage: Bytes(), +lock: Bytes(), +failure: HC.HostFailure) -> IO(HC.HRes(Unit)):
  IO.bind(HC.HRes(Unit), HC.HRes(Unit), best_effort_remove_stage(stage),
    sr => cleanup_original_failure_after_stage(lock, failure, sr))

@unsafe def finish_release_success(r: HC.HRes(Unit)) -> IO(HC.HRes(Unit)):
  match r:
    case Done{value}:
      HC.io_hres_done(Unit, Unit{})
    case Fail{+failure}:
      HC.io_hres_fail(Unit, failure)

@unsafe def finish_critical(+stage: Bytes(), +lock: Bytes(), r: HC.HRes(Unit)) -> IO(HC.HRes(Unit)):
  match r:
    case Done{value}:
      IO.bind(HC.HRes(Unit), HC.HRes(Unit), release_lock_effect(lock), finish_release_success)
    case Fail{+failure}:
      cleanup_original_failure(stage, lock, failure)

@unsafe def critical_after_swap(r: HC.HRes(Unit)) -> IO(HC.HRes(Unit)):
  match r:
    case Done{value}:
      HC.io_hres_done(Unit, Unit{})
    case Fail{+failure}:
      HC.io_hres_fail(Unit, failure)

@unsafe def critical_after_stage_validation(+out: Bytes(), +stage: Bytes(), +backup: Bytes(), r: HC.HRes(Unit)) -> IO(HC.HRes(Unit)):
  match r:
    case Done{value}:
      IO.bind(HC.HRes(Unit), HC.HRes(Unit), swap_stage_into_place(out, stage, backup), critical_after_swap)
    case Fail{+failure}:
      HC.io_hres_fail(Unit, failure)

@unsafe def critical_after_write(+out: Bytes(), +stage: Bytes(), +backup: Bytes(), r: HC.HRes(StageWrite)) -> IO(HC.HRes(Unit)):
  match r:
    case Done{+sw}:
      match sw:
        case StageWrite{+files}:
          IO.bind(HC.HRes(Unit), HC.HRes(Unit), validate_completed_stage(stage, files),
            vr => critical_after_stage_validation(out, stage, backup, vr))
    case Fail{+failure}:
      HC.io_hres_fail(Unit, failure)

@unsafe def critical_after_component_validation(+out: Bytes(), +stage: Bytes(), +backup: Bytes(),
  +pages: List<&2, Model.EmittedPage>, r: HC.HRes(Unit)) -> IO(HC.HRes(Unit)):
  match r:
    case Done{value}:
      IO.bind(HC.HRes(StageWrite), HC.HRes(Unit), write_stage_tree(stage, pages, out),
        wr => critical_after_write(out, stage, backup, wr))
    case Fail{+failure}:
      HC.io_hres_fail(Unit, failure)

@unsafe def critical_after_recovery(+containment_root: Bytes(), +out: Bytes(), +stage: Bytes(), +backup: Bytes(),
  +pages: List<&2, Model.EmittedPage>, r: HC.HRes(Unit)) -> IO(HC.HRes(Unit)):
  match r:
    case Done{value}:
      IO.bind(HC.HRes(Unit), HC.HRes(Unit), validate_output_components(containment_root, out),
        vr => critical_after_component_validation(out, stage, backup, pages, vr))
    case Fail{+failure}:
      HC.io_hres_fail(Unit, failure)

# Critical-section ordering: recover → validate components → write stage →
# recursively validate completed stage → swap.
@unsafe def critical_section(+containment_root: Bytes(), +out: Bytes(), +stage: Bytes(), +backup: Bytes(),
  +pages: List<&2, Model.EmittedPage>) -> IO(HC.HRes(Unit)):
  IO.bind(HC.HRes(Unit), HC.HRes(Unit), recover_publication_state(out, stage, backup),
    r => critical_after_recovery(containment_root, out, stage, backup, pages, r))

@unsafe def publish_after_lock(+containment_root: Bytes(), +out: Bytes(), +stage: Bytes(), +backup: Bytes(), +lock: Bytes(),
  +pages: List<&2, Model.EmittedPage>, r: HC.HRes(Unit)) -> IO(HC.HRes(Unit)):
  match r:
    case Done{value}:
      IO.bind(HC.HRes(Unit), HC.HRes(Unit), critical_section(containment_root, out, stage, backup, pages),
        rr => finish_critical(stage, lock, rr))
    case Fail{+failure}:
      HC.io_hres_fail(Unit, failure)

# --- publication preflight and top-level orchestration --------------------------------------------

@unsafe def collision_preflight(+out: Bytes(), +pages: List<&2, Model.EmittedPage>, aliases: Bool) -> IO(HC.HRes(Unit)):
  collision_preflight_gate(out, HCol.find_collision(pages, aliases))

@unsafe def collision_preflight_gate(+out: Bytes(), m: Maybe<&2, HCol.Collision>) -> IO(HC.HRes(Unit)):
  match m:
    case Some{+c}:
      HC.io_fail_one(Unit, 3, HCol.collision_diag(out, c))
    case None{}:
      HC.io_hres_done(Unit, Unit{})

type PubSiblings is Data:
  PubSiblings{lock: Bytes(), stage: Bytes(), backup: Bytes()}

@unsafe def pub_siblings(+lock: Bytes(), +stage: Bytes(), +backup: Bytes()) -> PubSiblings:
  PubSiblings{lock, stage, backup}

@unsafe def publication_siblings(+out: Bytes()) -> PubSiblings:
  pub_siblings(HC.bytes_append(out, HC.ascii_bytes(".pubend-lock")),
    HC.bytes_append(out, HC.ascii_bytes(".pubend-stage")),
    HC.bytes_append(out, HC.ascii_bytes(".pubend-previous")))

@unsafe def publish_after_parent(+containment_root: Bytes(), +out: Bytes(), +pages: List<&2, Model.EmittedPage>, sibs: PubSiblings, r: HC.HRes(Unit)) -> IO(HC.HRes(Unit)):
  match sibs:
    case PubSiblings{+lock, +stage, +backup}:
      match r:
        case Done{value}:
          IO.bind(HC.HRes(Unit), HC.HRes(Unit), acquire_lock(lock),
            lr => publish_after_lock(containment_root, out, stage, backup, lock, pages, lr))
        case Fail{+failure}:
          HC.io_hres_fail(Unit, failure)

@unsafe def publish_after_collision(+containment_root: Bytes(), +canonical_root: Bytes(), +out: Bytes(),
  +pages: List<&2, Model.EmittedPage>, sibs: PubSiblings, r: HC.HRes(Unit)) -> IO(HC.HRes(Unit)):
  match r:
    case Done{value}:
      IO.bind(HC.HRes(Unit), HC.HRes(Unit), prepare_output_parent(containment_root, canonical_root, out),
        pr => publish_after_parent(containment_root, out, pages, sibs, pr))
    case Fail{+failure}:
      HC.io_hres_fail(Unit, failure)

@unsafe def publish_after_probe(+containment_root: Bytes(), +canonical_root: Bytes(), +out: Bytes(),
  +pages: List<&2, Model.EmittedPage>, sibs: PubSiblings, r: HC.HRes(Bool)) -> IO(HC.HRes(Unit)):
  match r:
    case Done{+aliases}:
      IO.bind(HC.HRes(Unit), HC.HRes(Unit), collision_preflight(out, pages, aliases),
        cr => publish_after_collision(containment_root, canonical_root, out, pages, sibs, cr))
    case Fail{+failure}:
      HC.io_hres_fail(Unit, failure)

@unsafe def publish_after_nearest(+containment_root: Bytes(), +canonical_root: Bytes(), +out: Bytes(),
  +pages: List<&2, Model.EmittedPage>, sibs: PubSiblings, r: HC.HRes(Bytes())) -> IO(HC.HRes(Unit)):
  match r:
    case Done{+probe_parent}:
      IO.bind(HC.HRes(Bool), HC.HRes(Unit), filesystem_ascii_case_aliases(probe_parent),
        pr => publish_after_probe(containment_root, canonical_root, out, pages, sibs, pr))
    case Fail{+failure}:
      HC.io_hres_fail(Unit, failure)

@unsafe def publish_with_siblings(+containment_root: Bytes(), +canonical_root: Bytes(), +out: Bytes(),
  +pages: List<&2, Model.EmittedPage>, sibs: PubSiblings) -> IO(HC.HRes(Unit)):
  IO.bind(HC.HRes(Bytes()), HC.HRes(Unit), nearest_existing_output_directory(out),
    nr => publish_after_nearest(containment_root, canonical_root, out, pages, sibs, nr))

# Full publication preflight ordering: nearest output filesystem probe → dynamic
# ASCII alias decision → pure collision refusal → parent validation/creation →
# lock → critical section.
@unsafe def publish_publication(+containment_root: Bytes(), +canonical_root: Bytes(), +out: Bytes(), pub: Model.Publication) -> IO(HC.HRes(Unit)):
  match pub:
    case Model.Publication{+pages}:
      publish_with_siblings(containment_root, canonical_root, out, pages, publication_siblings(out))
