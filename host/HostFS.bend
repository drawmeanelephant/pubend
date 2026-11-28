import Base

# Native host filesystem boundary for pubend.
#
# ABI pinned to Bend 2.0.40: custom effects use compiler/runtime internals
# and must be reviewed and rebuilt with every Bend upgrade.  Paths and file
# bytes cross the boundary as List U32 byte lists, not String, because POSIX
# names are bytes rather than necessarily UTF-8 text.  Entry kinds cross as
# numeric codes and are converted to EntryKind only in pure Bend here; no
# nested enum is marshalled through the foreign ABI.
#
# Raw stat tuple layout:
#   kind & (size & (dev & ino))
# where kind is U32 and size/dev/ino are each (hi & lo) U32 pairs containing
# the exact unsigned 64-bit host value, most-significant word first.
#
# Kind codes:
#   1 regular file, 2 directory, 3 symlink, 0 other, 255 unknown.
# lstat_path/stat_path never intentionally produce 255.  readdir uses host
# kind bits when available, attempts an lstat fallback for unknown kinds in
# the effect implementation, and uses 255 if classification still failed.

def BytePath() -> Data:
  List<&2, U32>

def U64Tuple() -> Type:
  U32 & U32

def StatTuple() -> Type:
  U32 & (U64Tuple() & (U64Tuple() & U64Tuple()))

type EntryKind is Data:
  EntryFile{}
  EntryDirectory{}
  EntrySymlink{}
  EntryOther{}
  EntryUnknown{}

type U64Parts is Data:
  U64Parts{hi: U32, lo: U32}

type StatInfo is Data:
  StatInfo{kind: EntryKind, size: U64Parts, dev: U64Parts, ino: U64Parts}

type DirEntry is Data:
  DirEntry{name: BytePath(), kind: U32}

type DirInfo is Data:
  DirInfo{name: BytePath(), kind: EntryKind}

# Foreign effects.  Every failure is Base-style
# Fail{(errno: U32, message: String)} with the positive host errno.

def lstat_path(path: BytePath()) ->
  IO(Result<&1, &1, U32 & String, StatTuple()>):
  import "./host_eff.c"
  import "./host_eff.js"

def stat_path(path: BytePath()) ->
  IO(Result<&1, &1, U32 & String, StatTuple()>):
  import "./host_eff.c"
  import "./host_eff.js"

def readdir(path: BytePath()) ->
  IO(Result<&1, &1, U32 & String, List<&2, DirEntry>>):
  import "./host_eff.c"
  import "./host_eff.js"

def realpath(path: BytePath()) ->
  IO(Result<&1, &1, U32 & String, BytePath()>):
  import "./host_eff.c"
  import "./host_eff.js"

def mkdir_one(path: BytePath()) ->
  IO(Result<&1, &1, U32 & String, Unit>):
  import "./host_eff.c"
  import "./host_eff.js"

def rmdir(path: BytePath()) ->
  IO(Result<&1, &1, U32 & String, Unit>):
  import "./host_eff.c"
  import "./host_eff.js"

def unlink(path: BytePath()) ->
  IO(Result<&1, &1, U32 & String, Unit>):
  import "./host_eff.c"
  import "./host_eff.js"

def rename(from: BytePath(), to: BytePath()) ->
  IO(Result<&1, &1, U32 & String, Unit>):
  import "./host_eff.c"
  import "./host_eff.js"

# Creates or truncates when exclusive is 0; uses O_EXCL when exclusive is
# nonzero.  Writes every byte and reports the first write error.  The file is
# always closed; if there was no earlier error, a close error is reported
# rather than discarded.
def write_file_bytes(path: BytePath(), data: BytePath(), exclusive: U32) ->
  IO(Result<&1, &1, U32 & String, Unit>):
  import "./host_eff.c"
  import "./host_eff.js"

# Writes exactly data to stderr and adds no newline.
def write_stderr_bytes(data: BytePath()) ->
  IO(Result<&1, &1, U32 & String, Unit>):
  import "./host_eff.c"
  import "./host_eff.js"

# Pure boundary conveniences.

def kind_file() -> EntryKind:
  EntryFile{}

def kind_directory() -> EntryKind:
  EntryDirectory{}

def kind_symlink() -> EntryKind:
  EntrySymlink{}

def kind_other() -> EntryKind:
  EntryOther{}

def kind_unknown() -> EntryKind:
  EntryUnknown{}

def kind_of_unknown(+code: U32) -> EntryKind:
  kind_other()

def kind_of_symlink(+code: U32) -> EntryKind:
  Bool.pick(EntryKind, U32.is_eq(code, 255), kind_unknown(), kind_of_unknown(code))

def kind_of_directory(+code: U32) -> EntryKind:
  Bool.pick(EntryKind, U32.is_eq(code, 3), kind_symlink(), kind_of_symlink(code))

def kind_of_file(+code: U32) -> EntryKind:
  Bool.pick(EntryKind, U32.is_eq(code, 2), kind_directory(), kind_of_directory(code))

def kind_of(+code: U32) -> EntryKind:
  Bool.pick(EntryKind, U32.is_eq(code, 1), kind_file(), kind_of_file(code))

def stat_info_of(raw: StatTuple()) -> StatInfo:
  (kind, ((shi, slo), ((dhi, dlo), (ihi, ilo)))) = raw
  StatInfo{kind_of(kind), U64Parts{shi, slo}, U64Parts{dhi, dlo}, U64Parts{ihi, ilo}}

def stat_result_info(r: Result<&1, &1, U32 & String, StatTuple()>) ->
  Result<&1, &1, U32 & String, StatInfo>:
  match r:
    case Done{value}:
      Done{stat_info_of(value)}
    case Fail{error}:
      Fail{error}

def entry_info(e: DirEntry) -> DirInfo:
  match e:
    case DirEntry{name, kind}:
      DirInfo{name, kind_of(kind)}

def dir_info_cons(x: DirInfo, xs: List<&2, DirInfo>) -> List<&2, DirInfo>:
  x <> xs

def entries_info(xs: List<&2, DirEntry>) -> List<&2, DirInfo>:
  match xs:
    case Nil{}:
      Nil{}
    case h <> t:
      dir_info_cons(entry_info(h), entries_info(t))

def entries_result_info(r: Result<&1, &1, U32 & String, List<&2, DirEntry>>) ->
  Result<&1, &1, U32 & String, List<&2, DirInfo>>:
  match r:
    case Done{value}:
      Done{entries_info(value)}
    case Fail{error}:
      Fail{error}

def stat_result_io(r: Result<&1, &1, U32 & String, StatTuple()>) ->
  IO(Result<&1, &1, U32 & String, StatInfo>):
  IO.pure(Result<&1, &1, U32 & String, StatInfo>, stat_result_info(r))

def entries_result_io(r: Result<&1, &1, U32 & String, List<&2, DirEntry>>) ->
  IO(Result<&1, &1, U32 & String, List<&2, DirInfo>>):
  IO.pure(Result<&1, &1, U32 & String, List<&2, DirInfo>>, entries_result_info(r))

def lstat_info(path: BytePath()) ->
  IO(Result<&1, &1, U32 & String, StatInfo>):
  IO.bind(Result<&1, &1, U32 & String, StatTuple()>,
    Result<&1, &1, U32 & String, StatInfo>,
    lstat_path(path), stat_result_io)

def stat_info(path: BytePath()) ->
  IO(Result<&1, &1, U32 & String, StatInfo>):
  IO.bind(Result<&1, &1, U32 & String, StatTuple()>,
    Result<&1, &1, U32 & String, StatInfo>,
    stat_path(path), stat_result_io)

def readdir_info(path: BytePath()) ->
  IO(Result<&1, &1, U32 & String, List<&2, DirInfo>>):
  IO.bind(Result<&1, &1, U32 & String, List<&2, DirEntry>>,
    Result<&1, &1, U32 & String, List<&2, DirInfo>>,
    readdir(path), entries_result_io)
