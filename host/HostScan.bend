import Base
import ./HostCommon.bend as HC
import ./HostFS.bend as HFS
import ../src/hostpath.bend as HP
import ../src/model.bend as Model

# Input discovery and loading.  The traversal is byte-preserving at the
# filesystem boundary and follows the reference ordering exactly: byte-sorted
# entries (equivalent to code-point order for valid UTF-8 names), symlink
# diagnostics during classification, then files before recursive child
# directories.  Errors are values in ScanState; scanning continues across the
# tree so independent input and host IO errors aggregate.

type ScanState is Data:
  ScanState{pages: List<&2, Model.SourcePage>, input_errors: List<&2, HC.HostDiag>,
    host_errors: List<&2, HC.HostDiag>}

type ScanPartition is Data:
  ScanPartition{files: List<&2, HFS.DirInfo>, dirs: List<&2, HFS.DirInfo>,
    symlink_errors: List<&2, HC.HostDiag>}

type PageRead is Data:
  PageReadOk{bytes: HC.Bytes()}
  PageReadErr{code: U32, message: String}


@unsafe def u64_to_nat(x: HFS.U64Parts) -> Nat:
  match x:
    case HFS.U64Parts{+hi, +lo}:
      Nat.add(Nat.mul(U32.to_nat(hi), Nat.mul(65536n, 65536n)), U32.to_nat(lo))

@unsafe def scan_state(pages: List<&2, Model.SourcePage>, input_errors: List<&2, HC.HostDiag>,
  host_errors: List<&2, HC.HostDiag>) -> ScanState:
  ScanState{pages, input_errors, host_errors}

@unsafe def scan_empty() -> ScanState:
  scan_state(Nil{}, Nil{}, Nil{})

@unsafe def scan_partition(files: List<&2, HFS.DirInfo>, dirs: List<&2, HFS.DirInfo>,
  symlink_errors: List<&2, HC.HostDiag>) -> ScanPartition:
  ScanPartition{files, dirs, symlink_errors}

@unsafe def page_read_ok(+bytes: HC.Bytes()) -> PageRead:
  PageReadOk{bytes}

@unsafe def page_read_err(+code: U32, +message: String) -> PageRead:
  PageReadErr{code, message}

@unsafe def input_diag(cls: HC.DiagClass, +rel: String, +message: String) -> HC.HostDiag:
  HC.host_diag_path(cls, rel, message)

@unsafe def host_input_diag(+full: HC.Bytes(), +action: String, +code: U32, +message: String) -> HC.HostDiag:
  HC.host_diag_path(HC.DInputIo{}, HC.bytes_display(full),
    action ++ ": " ++ Bool.pick(String, String.is_empty(message), "errno " ++ U32.show(code), message))

@unsafe def state_add_input(st: ScanState, d: HC.HostDiag) -> ScanState:
  match st:
    case ScanState{pages, +input_errors, host_errors}:
      scan_state(pages, List.append(&2, HC.HostDiag, input_errors, d <> Nil{}), host_errors)

@unsafe def state_add_host(st: ScanState, d: HC.HostDiag) -> ScanState:
  match st:
    case ScanState{pages, input_errors, +host_errors}:
      scan_state(pages, input_errors, List.append(&2, HC.HostDiag, host_errors, d <> Nil{}))

@unsafe def state_add_page(st: ScanState, p: Model.SourcePage) -> ScanState:
  match st:
    case ScanState{+pages, input_errors, host_errors}:
      scan_state(List.append(&2, Model.SourcePage, pages, p <> Nil{}), input_errors, host_errors)

@unsafe def state_add_input_list(st: ScanState, ds: List<&2, HC.HostDiag>) -> ScanState:
  match st:
    case ScanState{pages, +input_errors, host_errors}:
      scan_state(pages, List.append(&2, HC.HostDiag, input_errors, ds), host_errors)

@unsafe def state_errors(st: ScanState) -> List<&2, HC.HostDiag> & List<&2, HC.HostDiag>:
  match st:
    case ScanState{pages, +input_errors, +host_errors}:
      (input_errors, host_errors)

@unsafe def state_pages(st: ScanState) -> List<&2, Model.SourcePage>:
  match st:
    case ScanState{+pages, input_errors, host_errors}:
      pages

@unsafe def rel_join(+base: HC.Bytes(), +name: HC.Bytes()) -> HC.Bytes():
  match base:
    case Nil{}:
      name
    case h <> t:
      HC.bytes_append(base, HC.bytes_append(HC.ascii_bytes("/"), name))

@unsafe def entry_rel(+rel_dir: HC.Bytes(), e: HFS.DirInfo) -> HC.Bytes():
  match e:
    case HFS.DirInfo{+name, kind}:
      rel_join(rel_dir, name)

@unsafe def symlink_diag(+rel: HC.Bytes()) -> HC.HostDiag:
  input_diag(HC.DSymlinkedEntry{}, HC.bytes_display(rel),
    "symlinked entry under content/ is an input-tree error")

@unsafe def partition_entry(+rel_dir: HC.Bytes(), e: HFS.DirInfo, acc: ScanPartition) -> ScanPartition:
  match e:
    case HFS.DirInfo{+name, kind}:
      match kind:
        case HFS.EntryDirectory{}:
          match acc:
            case ScanPartition{files, +dirs, symlink_errors}:
              scan_partition(files, List.append(&2, HFS.DirInfo, dirs, e <> Nil{}), symlink_errors)
        case HFS.EntrySymlink{}:
          match acc:
            case ScanPartition{files, dirs, +symlink_errors}:
              scan_partition(files, dirs,
                List.append(&2, HC.HostDiag, symlink_errors, symlink_diag(rel_join(rel_dir, name)) <> Nil{}))
        case other:
          match acc:
            case ScanPartition{+files, dirs, symlink_errors}:
              scan_partition(List.append(&2, HFS.DirInfo, files, e <> Nil{}), dirs, symlink_errors)

@unsafe def partition_entries_go(+rel_dir: HC.Bytes(), xs: List<&2, HFS.DirInfo>, acc: ScanPartition) -> ScanPartition:
  match xs:
    case Nil{}:
      acc
    case +h <> t:
      partition_entries_go(rel_dir, t, partition_entry(rel_dir, h, acc))

@unsafe def partition_entries(+rel_dir: HC.Bytes(), xs: List<&2, HFS.DirInfo>) -> ScanPartition:
  partition_entries_go(rel_dir, xs, scan_partition(Nil{}, Nil{}, Nil{}))

# --- exact-byte file reading ----------------------------------------------------

@unsafe def read_result_finish(+code: U32, +message: String) -> PageRead:
  page_read_err(code, message)

@unsafe def read_bytes_finish(r: Result<&1, &1, HC.HostIOError(), HC.Bytes()>) -> PageRead:
  match r:
    case Done{+bytes}:
      page_read_ok(bytes)
    case Fail{error}:
      (+code, +message) = error
      page_read_err(code, message)

@unsafe def read_after_read(p: File & Result<&1, &1, HC.HostIOError(), HC.Bytes()>) -> IO(PageRead):
  (file2, result) = p
  IO.bind(Unit, PageRead, File.close(file2), u => IO.pure(PageRead, read_bytes_finish(result)))

@unsafe def read_open_finish(r: Result<&1, &1, HC.HostIOError(), File>) -> IO(PageRead):
  match r:
    case Done{file}:
      IO.bind(File & Result<&1, &1, HC.HostIOError(), HC.Bytes()>, PageRead,
        File.read_bytes(file, 1048577), p => read_after_read(p))
    case Fail{error}:
      (+code, +message) = error
      IO.pure(PageRead, page_read_err(code, message))

# Read at most 1 MiB + 1 bytes.  The extra byte is enough to implement the
# reference host's post-read over-limit check without unbounded memory use;
# both checks still accept exactly 1 MiB.
@unsafe def read_page_bytes(+path: HC.Bytes()) -> IO(PageRead):
  IO.bind(Result<&1, &1, HC.HostIOError(), File>, PageRead,
    File.open_bytes(path, "r"), read_open_finish)

# --- per-entry validation and loading ------------------------------------------

@unsafe def md_suffix() -> HC.Bytes():
  HC.ascii_bytes(".md")

@unsafe def drop_md_suffix(+rel: HC.Bytes()) -> HC.Bytes():
  List.take(&2, U32, rel, Nat.sub(HC.bytes_length(rel), 3n))

@unsafe def add_oversized(st: ScanState, +rel: HC.Bytes(), size: Nat) -> ScanState:
  state_add_input(st, input_diag(HC.DOversizedPage{}, HC.bytes_display(rel),
    Nat.show(size) ++ " bytes exceeds 1 MiB ceiling"))

@unsafe def decode_page_finish(st: ScanState, +rel: HC.Bytes(), r: HC.ByteText) -> ScanState:
  match r:
    case HC.ByteTextInvalid{}:
      state_add_input(st, input_diag(HC.DInvalidUtf8{}, HC.bytes_display(rel),
        "page bytes are not valid UTF-8"))
    case HC.ByteTextOk{+body}:
      +id_bytes = drop_md_suffix(rel)
      state_add_page(st, Model.SourcePage{HC.bytes_display(id_bytes), body})

@unsafe def process_loaded_bytes(st: ScanState, +rel: HC.Bytes(), +bytes: HC.Bytes()) -> ScanState:
  process_size_gate(st, rel, bytes, HC.bytes_len_gt_1mib(bytes))

@unsafe def process_size_gate(st: ScanState, +rel: HC.Bytes(), +bytes: HC.Bytes(), oversized: Bool) -> ScanState:
  match oversized:
    case True{}:
      add_oversized(st, rel, HC.bytes_length(bytes))
    case False{}:
      decode_page_finish(st, rel, HC.decode_bytes_strict(bytes))

@unsafe def process_read_result(st: ScanState, +rel: HC.Bytes(), +full: HC.Bytes(), pr: PageRead) -> ScanState:
  match pr:
    case PageReadErr{+code, +message}:
      state_add_host(st, host_input_diag(full, "cannot read page", code, message))
    case PageReadOk{+bytes}:
      process_loaded_bytes(st, rel, bytes)

@unsafe def process_stat_kind(st: ScanState, +rel: HC.Bytes(), +full: HC.Bytes(), stinfo: HFS.StatInfo) -> IO(ScanState):
  match stinfo:
    case HFS.StatInfo{kind, size, dev, ino}:
      process_kind_gate(st, rel, full, kind, size)

@unsafe def process_kind_gate(st: ScanState, +rel: HC.Bytes(), +full: HC.Bytes(),
  kind: HFS.EntryKind, +size: HFS.U64Parts) -> IO(ScanState):
  match kind:
    case HFS.EntrySymlink{}:
      IO.pure(ScanState, state_add_input(st, symlink_diag(rel)))
    case other:
      process_file_type_gate(st, rel, full, kind, size, HC.bytes_ends_with(rel, md_suffix()))

@unsafe def process_file_type_gate(st: ScanState, +rel: HC.Bytes(), +full: HC.Bytes(),
  kind: HFS.EntryKind, size: HFS.U64Parts, ismd: Bool) -> IO(ScanState):
  match ismd:
    case False{}:
      IO.pure(ScanState, state_add_input(st, input_diag(HC.DNonMdFile{}, HC.bytes_display(rel),
        "file entry under content/ does not end in .md")))
    case True{}:
      process_regular_gate(st, rel, full, kind, size)

@unsafe def process_regular_gate(st: ScanState, +rel: HC.Bytes(), +full: HC.Bytes(),
  kind: HFS.EntryKind, +size: HFS.U64Parts) -> IO(ScanState):
  match kind:
    case HFS.EntryFile{}:
      process_size_pre_gate(st, rel, full, size, HC.u64_gt_1mib(size))
    case other:
      IO.pure(ScanState, state_add_input(st, input_diag(HC.DNonMdFile{}, HC.bytes_display(rel),
        ".md-named entry is not a regular file")))

@unsafe def process_size_pre_gate(st: ScanState, +rel: HC.Bytes(), +full: HC.Bytes(),
  size: HFS.U64Parts, oversized: Bool) -> IO(ScanState):
  match oversized:
    case True{}:
      IO.pure(ScanState, add_oversized(st, rel, u64_to_nat(size)))
    case False{}:
      IO.bind(PageRead, ScanState, read_page_bytes(full),
        pr => IO.pure(ScanState, process_read_result(st, rel, full, pr)))

@unsafe def process_lstat_result(st: ScanState, +rel: HC.Bytes(), +full: HC.Bytes(), r: HC.HStatResult()) -> IO(ScanState):
  match r:
    case Fail{error}:
      (+code, +message) = error
      IO.pure(ScanState, state_add_host(st, host_input_diag(full, "cannot inspect content entry", code, message)))
    case Done{+stinfo}:
      process_stat_kind(st, rel, full, stinfo)

@unsafe def process_file_entry(st: ScanState, +dirfs: HC.Bytes(), +rel_dir: HC.Bytes(), e: HFS.DirInfo) -> IO(ScanState):
  match e:
    case HFS.DirInfo{+name, kind}:
      +rel = rel_join(rel_dir, name)
      +full = HP.hostpath_join2(dirfs, name)
      IO.bind(HC.HStatResult(), ScanState, HFS.lstat_info(full),
        r => process_lstat_result(st, rel, full, r))

@unsafe def scan_files_go(st: ScanState, +dirfs: HC.Bytes(), +rel_dir: HC.Bytes(), xs: List<&2, HFS.DirInfo>) -> IO(ScanState):
  match xs:
    case Nil{}:
      IO.pure(ScanState, st)
    case +h <> t:
      IO.bind(ScanState, ScanState, process_file_entry(st, dirfs, rel_dir, h),
        st2 => scan_files_go(st2, dirfs, rel_dir, t))

# --- recursive deterministic traversal -------------------------------------------

@unsafe def scan_readdir_result(st: ScanState, +dirfs: HC.Bytes(), +rel_dir: HC.Bytes(), r: HC.HEntriesResult()) -> IO(ScanState):
  match r:
    case Fail{error}:
      (+code, +message) = error
      IO.pure(ScanState, state_add_host(st, host_input_diag(dirfs, "cannot read content directory", code, message)))
    case Done{+entries}:
      scan_partitioned(st, dirfs, rel_dir, partition_entries(rel_dir, entries))

@unsafe def scan_partitioned(st: ScanState, +dirfs: HC.Bytes(), +rel_dir: HC.Bytes(), part: ScanPartition) -> IO(ScanState):
  match part:
    case ScanPartition{+files, +dirs, +symlink_errors}:
      IO.bind(ScanState, ScanState,
        scan_files_go(state_add_input_list(st, symlink_errors), dirfs, rel_dir, files),
        st2 => scan_dirs_go(st2, dirfs, rel_dir, dirs))

@unsafe def scan_dirs_go(st: ScanState, +parentfs: HC.Bytes(), +rel_dir: HC.Bytes(), xs: List<&2, HFS.DirInfo>) -> IO(ScanState):
  match xs:
    case Nil{}:
      IO.pure(ScanState, st)
    case +h <> t:
      match h:
        case HFS.DirInfo{+name, kind}:
          +childfs = HP.hostpath_join2(parentfs, name)
          +childrel = rel_join(rel_dir, name)
          IO.bind(ScanState, ScanState, scan_dir(st, childfs, childrel),
            st2 => scan_dirs_go(st2, parentfs, rel_dir, t))

@unsafe def scan_dir(st: ScanState, +dirfs: HC.Bytes(), +rel_dir: HC.Bytes()) -> IO(ScanState):
  IO.bind(HC.HEntriesResult(), ScanState, HFS.readdir_info(dirfs),
    r => scan_readdir_result(st, dirfs, rel_dir, r))

# --- content root preflight ---------------------------------------------------------

@unsafe def scan_content_stat(st: ScanState, +content: HC.Bytes(), stinfo: HFS.StatInfo) -> IO(ScanState):
  match stinfo:
    case HFS.StatInfo{kind, size, dev, ino}:
      scan_content_kind(st, content, kind)

@unsafe def scan_content_kind(st: ScanState, +content: HC.Bytes(), kind: HFS.EntryKind) -> IO(ScanState):
  match kind:
    case HFS.EntrySymlink{}:
      IO.pure(ScanState, state_add_input(st, input_diag(HC.DSymlinkedEntry{}, "content",
        "content/ is symlinked; symlinks are never followed")))
    case HFS.EntryDirectory{}:
      scan_dir(st, content, Nil{})
    case other:
      IO.pure(ScanState, state_add_input(st, input_diag(HC.DMissingContentDir{}, "content",
        "site root has no content/ directory")))

@unsafe def scan_content_result(st: ScanState, +content: HC.Bytes(), r: HC.HStatResult()) -> IO(ScanState):
  match r:
    case Fail{error}:
      (+code, +message) = error
      scan_content_error(st, content, code, message,
        Bool.or(U32.is_eq(code, HC.errno_enoent()), U32.is_eq(code, HC.errno_enotdir())))
    case Done{+stinfo}:
      scan_content_stat(st, content, stinfo)

@unsafe def scan_content_error(st: ScanState, +content: HC.Bytes(), +code: U32, +message: String, missingness: Bool) -> IO(ScanState):
  match missingness:
    case True{}:
      IO.pure(ScanState, state_add_input(st, input_diag(HC.DMissingContentDir{}, "content",
        "site root has no content/ directory")))
    case False{}:
      IO.pure(ScanState, state_add_host(st, host_input_diag(content, "cannot inspect content directory", code, message)))

@unsafe def scan_site(+content: HC.Bytes()) -> IO(ScanState):
  IO.bind(HC.HStatResult(), ScanState, HFS.lstat_info(content),
    r => scan_content_result(scan_empty(), content, r))
