import Base
import ./HostFS.bend as HFS
import ../test/harness.bend as H

# Self-verifying HostFS effect harness.  It creates a unique fixture tree in
# /tmp on every run, checks exact effect outcomes, prints the shared PASS/FAIL
# harness lines, and exits nonzero on any failure.  /bin/ln and /bin/realpath
# are used only as fixture/oracle helpers because symlink creation and an
# independent canonical-path oracle are intentionally not HostFS effects.

def Bytes() -> Data:
  List<&2, U32>

def RUnit() -> Type:
  Result<&1, &1, U32 & String, Unit>

def RBytes() -> Type:
  Result<&1, &1, U32 & String, Bytes()>

def RStatInfo() -> Type:
  Result<&1, &1, U32 & String, HFS.StatInfo>

def RDirInfo() -> Type:
  Result<&1, &1, U32 & String, List<&2, HFS.DirInfo>>

def byte_cons(b: U32, xs: Bytes()) -> Bytes():
  b <> xs

def ascii_bytes(s: String) -> Bytes():
  match s:
    case SNil{}:
      Nil{}
    case SCon{h, t}:
      byte_cons(Char.to_u32(h), ascii_bytes(t))

def ascii_string(xs: Bytes()) -> String:
  match xs:
    case Nil{}:
      ""
    case h <> t:
      SCon{Char.from_u32(h), ascii_string(t)}

def slash_bytes() -> Bytes():
  byte_cons(47, Nil{})

def path_join(+base: Bytes(), +name: String) -> Bytes():
  List.append(&2, U32, base, List.append(&2, U32, slash_bytes(), ascii_bytes(name)))

def path_join_bytes(+base: Bytes(), +name: Bytes()) -> Bytes():
  List.append(&2, U32, base, List.append(&2, U32, slash_bytes(), name))

def text_join(+base: String, +name: String) -> String:
  base ++ "/" ++ name

def bytes_eq(xs: Bytes(), ys: Bytes()) -> Bool:
  match xs ys:
    case Nil{} Nil{}:
      True{}
    case Nil{} b:
      False{}
    case a Nil{}:
      False{}
    case xh <> xt yh <> yt:
      Bool.pick(Bool, U32.is_eq(xh, yh), bytes_eq(xt, yt), False{})

def err_text(+code: U32) -> String:
  "err:" ++ U32.show(code)

def unit_text(r: RUnit()) -> String:
  match r:
    case Done{value}:
      "ok"
    case Fail{error}:
      (code, message) = error
      err_text(code)

def unit_failed_nonzero(r: RUnit()) -> Bool:
  match r:
    case Done{value}:
      False{}
    case Fail{error}:
      (code, message) = error
      U32.is_ne(code, 0)

def kind_name(k: HFS.EntryKind) -> String:
  match k:
    case HFS.EntryFile{}:
      "file"
    case HFS.EntryDirectory{}:
      "directory"
    case HFS.EntrySymlink{}:
      "symlink"
    case HFS.EntryOther{}:
      "other"
    case HFS.EntryUnknown{}:
      "unknown"

def u64_shape(x: HFS.U64Parts) -> String:
  match x:
    case HFS.U64Parts{hi, lo}:
      U32.show(hi) ++ ":" ++ U32.show(lo)

def stat_shape(st: HFS.StatInfo) -> String:
  match st:
    case HFS.StatInfo{kind, size, dev, ino}:
      kind_name(kind) ++ ":" ++ u64_shape(size)

def stat_result_shape(r: RStatInfo()) -> String:
  match r:
    case Done{value}:
      stat_shape(value)
    case Fail{error}:
      (code, message) = error
      err_text(code)

def u64_eq(a: HFS.U64Parts, b: HFS.U64Parts) -> Bool:
  match a b:
    case HFS.U64Parts{ahi, alo} HFS.U64Parts{bhi, blo}:
      Bool.and(U32.is_eq(ahi, bhi), U32.is_eq(alo, blo))

def stat_info_ids_eq(a: HFS.StatInfo, b: HFS.StatInfo) -> Bool:
  match a b:
    case HFS.StatInfo{ak, asz, adev, aino} HFS.StatInfo{bk, bsz, bdev, bino}:
      Bool.and(u64_eq(adev, bdev), u64_eq(aino, bino))

def stat_ids_right(a: HFS.StatInfo, rb: RStatInfo()) -> Bool:
  match rb:
    case Done{value}:
      stat_info_ids_eq(a, value)
    case Fail{error}:
      False{}

def stat_results_same_ids(ra: RStatInfo(), rb: RStatInfo()) -> Bool:
  match ra:
    case Done{value}:
      stat_ids_right(value, rb)
    case Fail{error}:
      False{}

def dir_text(e: HFS.DirInfo) -> String:
  match e:
    case HFS.DirInfo{name, kind}:
      ascii_string(name) ++ ":" ++ kind_name(kind) ++ ";"

def dirs_text(xs: List<&2, HFS.DirInfo>) -> String:
  match xs:
    case Nil{}:
      ""
    case h <> t:
      dir_text(h) ++ dirs_text(t)

def readdir_text(r: RDirInfo()) -> String:
  match r:
    case Done{value}:
      dirs_text(value)
    case Fail{error}:
      (code, message) = error
      err_text(code)

def realpath_text_nl(r: RBytes()) -> String:
  match r:
    case Done{value}:
      ascii_string(value) ++ "\n"
    case Fail{error}:
      (code, message) = error
      err_text(code)

def realpath_err_text(r: RBytes()) -> String:
  match r:
    case Done{value}:
      "ok:" ++ ascii_string(value)
    case Fail{error}:
      (code, message) = error
      err_text(code)

# Process fixture helpers.  They die only when fixture creation/oracle execution
# itself is impossible; effect probes never use fatal process status as a pass.

def process_code_gate(+stdout: String, ok: Bool) -> IO(String):
  match ok:
    case True{}:
      IO.pure(String, stdout)
    case False{}:
      IO.die(String, 1, "fixture helper process failed")

def process_done(value: U32 & (String & String)) -> IO(String):
  (code, (stdout, stderr)) = value
  process_code_gate(stdout, U32.is_eq(code, 0))

def process_fail(error: U32 & String) -> IO(String):
  (code, message) = error
  IO.die(String, 1, message)

def process_finish(r: Result<&1, &1, U32 & String, U32 & (String & String)>) -> IO(String):
  match r:
    case Done{value}:
      process_done(value)
    case Fail{error}:
      process_fail(error)

def run_stdout(+program: String, args: List<String>) -> IO(String):
  do IO<String>:
    r : Result<&1, &1, U32 & String, U32 & (String & String)> <-
      Process.run(program, args, "", 4096, 10000)
    process_finish(r)

# Exact byte readback helper, built on Base because HostFS deliberately does
# not duplicate Base's byte-file read effects.

def read_close_fail(file: File, +message: String) -> IO(Bytes()):
  do IO<Bytes()>:
    File.close(file)
    IO.die(Bytes(), 1, message)

def read_result(file: File, r: Result<&1, &1, U32 & String, Bytes()>) -> IO(Bytes()):
  match r:
    case Done{value}:
      do IO<Bytes()>:
        File.close(file)
        return value
    case Fail{error}:
      (code, message) = error
      read_close_fail(file, message)

def read_pair(p: File & Result<&1, &1, U32 & String, Bytes()>) -> IO(Bytes()):
  (file, result) = p
  read_result(file, result)

def read_open_finish(r: Result<&1, &1, U32 & String, File>) -> IO(Bytes()):
  match r:
    case Done{file}:
      do IO<Bytes()>:
        p : File & Result<&1, &1, U32 & String, Bytes()> <- File.read_bytes(file, 8192)
        read_pair(p)
    case Fail{error}:
      (code, message) = error
      IO.die(Bytes(), 1, message)

def read_file_bytes(+path: Bytes()) -> IO(Bytes()):
  do IO<Bytes()>:
    r : Result<&1, &1, U32 & String, File> <- File.open_bytes(path, "r")
    read_open_finish(r)

def main() -> IO(Unit):
  do IO<Unit>:
    +now : Nat <- IO.now()
    +rand : U32 <- IO.try(U32, IO.random_u32())
    +root_s : String = "/tmp/pubend-hostfs-" ++ Nat.show(now) ++ "-" ++ U32.show(rand)
    +scan_s : String = text_join(root_s, "scan")
    +empty_s : String = text_join(root_s, "empty-dir")
    +root : Bytes() = ascii_bytes(root_s)
    +scan : Bytes() = ascii_bytes(scan_s)
    +empty_dir : Bytes() = ascii_bytes(empty_s)
    +alpha : Bytes() = path_join(scan, "alpha.txt")
    +zeta : Bytes() = path_join(scan, "zeta.txt")
    +sub : Bytes() = path_join(scan, "sub")
    +nested : Bytes() = path_join(sub, "nested.txt")
    +fifo : Bytes() = path_join(scan, "fifo")
    +link_alpha : Bytes() = path_join(scan, "link-alpha")
    +link_dir : Bytes() = path_join(scan, "link-dir")
    +missing : Bytes() = path_join(scan, "missing")
    +no_parent_file : Bytes() = path_join(root, "no-such-dir/file")
    +data_path : Bytes() = path_join(root, "data.bin")
    +truncate_path : Bytes() = path_join(root, "truncate.txt")
    +marker_path : Bytes() = path_join(root, "marker.txt")
    +rename_src : Bytes() = path_join(root, "rename-src.txt")
    +rename_dst : Bytes() = path_join(root, "rename-dst.txt")
    +odd_name : Bytes() = byte_cons(195, byte_cons(191, Nil{}))
    +odd_path : Bytes() = path_join_bytes(scan, odd_name)

    r_mkroot : RUnit() <- HFS.mkdir_one(root)
    +c_mkroot : H.Check = H.chk("mkdir-root", unit_text(r_mkroot), "ok")
    r_mkscan : RUnit() <- HFS.mkdir_one(scan)
    +c_mkscan : H.Check = H.chk("mkdir-scan", unit_text(r_mkscan), "ok")
    r_mkexist : RUnit() <- HFS.mkdir_one(root)
    +c_mkexist : H.Check = H.chk("mkdir-existing-eexist", unit_text(r_mkexist), "err:17")

    r_wzeta : RUnit() <- HFS.write_file_bytes(zeta, ascii_bytes("zeta\n"), 0)
    +c_wzeta : H.Check = H.chk("write-zeta", unit_text(r_wzeta), "ok")
    r_walpha : RUnit() <- HFS.write_file_bytes(alpha, ascii_bytes("alpha\n"), 0)
    +c_walpha : H.Check = H.chk("write-alpha", unit_text(r_walpha), "ok")
    r_mksub : RUnit() <- HFS.mkdir_one(sub)
    +c_mksub : H.Check = H.chk("mkdir-sub", unit_text(r_mksub), "ok")
    r_wnested : RUnit() <- HFS.write_file_bytes(nested, ascii_bytes("nested\n"), 0)
    +c_wnested : H.Check = H.chk("write-nested", unit_text(r_wnested), "ok")

    r_wodd : RUnit() <- HFS.write_file_bytes(odd_path, odd_name, 0)
    +c_wodd : H.Check = H.chk("write-multibyte-path", unit_text(r_wodd), "ok")

    fifo_out : String <- run_stdout("/usr/bin/mkfifo", [text_join(scan_s, "fifo")])
    ln_alpha_out : String <- run_stdout("/bin/ln", ["-s", "alpha.txt", text_join(scan_s, "link-alpha")])
    ln_dir_out : String <- run_stdout("/bin/ln", ["-s", "sub", text_join(scan_s, "link-dir")])

    +data_bytes : Bytes() = [0, 65, 10, 255]
    r_wdata : RUnit() <- HFS.write_file_bytes(data_path, data_bytes, 0)
    +c_wdata : H.Check = H.chk("write-data-bytes", unit_text(r_wdata), "ok")
    got_data : Bytes() <- read_file_bytes(data_path)
    +c_data_exact : H.Check = H.chkb("write-data-exact-bytes", bytes_eq(got_data, data_bytes), True{})

    r_wlong : RUnit() <- HFS.write_file_bytes(truncate_path, ascii_bytes("long-truncate-contents\n"), 0)
    +c_wlong : H.Check = H.chk("write-truncate-setup", unit_text(r_wlong), "ok")
    r_wshort : RUnit() <- HFS.write_file_bytes(truncate_path, ascii_bytes("short\n"), 0)
    +c_wshort : H.Check = H.chk("write-truncate", unit_text(r_wshort), "ok")
    got_truncate : Bytes() <- read_file_bytes(truncate_path)
    +c_truncate_exact : H.Check = H.chkb("write-truncate-exact", bytes_eq(got_truncate, ascii_bytes("short\n")), True{})

    r_excl_first : RUnit() <- HFS.write_file_bytes(marker_path, ascii_bytes("owner\n"), 1)
    +c_excl_first : H.Check = H.chk("write-exclusive-first", unit_text(r_excl_first), "ok")
    r_excl_second : RUnit() <- HFS.write_file_bytes(marker_path, ascii_bytes("other\n"), 1)
    +c_excl_second : H.Check = H.chk("write-exclusive-eexist", unit_text(r_excl_second), "err:17")
    r_write_missing : RUnit() <- HFS.write_file_bytes(no_parent_file, ascii_bytes("x"), 0)
    +c_write_missing : H.Check = H.chk("write-missing-parent-enoent", unit_text(r_write_missing), "err:2")

    r_lstat_file : RStatInfo() <- HFS.lstat_info(alpha)
    +c_lstat_file : H.Check = H.chk("lstat-file-kind-size", stat_result_shape(r_lstat_file), "file:0:6")
    r_lstat_fifo : RStatInfo() <- HFS.lstat_info(fifo)
    +c_lstat_fifo : H.Check = H.chk("lstat-fifo-other", stat_result_shape(r_lstat_fifo), "other:0:0")
    r_lstat_link : RStatInfo() <- HFS.lstat_info(link_alpha)
    +c_lstat_link : H.Check = H.chk("lstat-symlink-kind-size", stat_result_shape(r_lstat_link), "symlink:0:9")
    r_stat_link : RStatInfo() <- HFS.stat_info(link_alpha)
    +c_stat_link : H.Check = H.chk("stat-follows-symlink", stat_result_shape(r_stat_link), "file:0:6")
    r_lstat_odd : RStatInfo() <- HFS.lstat_info(odd_path)
    +c_lstat_odd : H.Check = H.chk("lstat-multibyte-path", stat_result_shape(r_lstat_odd), "file:0:2")
    r_lstat_missing : RStatInfo() <- HFS.lstat_info(missing)
    +c_lstat_missing : H.Check = H.chk("lstat-missing-enoent", stat_result_shape(r_lstat_missing), "err:2")
    r_stat_missing : RStatInfo() <- HFS.stat_info(missing)
    +c_stat_missing : H.Check = H.chk("stat-missing-enoent", stat_result_shape(r_stat_missing), "err:2")

    r_id_file : RStatInfo() <- HFS.lstat_info(alpha)
    r_id_link : RStatInfo() <- HFS.stat_info(link_alpha)
    +c_same_ids : H.Check = H.chkb("stat-dev-ino-same-file", stat_results_same_ids(r_id_file, r_id_link), True{})
    r_id_alpha : RStatInfo() <- HFS.lstat_info(alpha)
    r_id_zeta : RStatInfo() <- HFS.lstat_info(zeta)
    +c_distinct_ids : H.Check = H.chkb("stat-ino-distinct-files", Bool.not(stat_results_same_ids(r_id_alpha, r_id_zeta)), True{})

    r_readdir : RDirInfo() <- HFS.readdir_info(scan)
    +readdir_expected : String = "alpha.txt:file;fifo:other;link-alpha:symlink;link-dir:symlink;sub:directory;zeta.txt:file;"
      ++ ascii_string(odd_name) ++ ":file;"
    +c_readdir : H.Check = H.chk("readdir-sorted-entries", readdir_text(r_readdir), readdir_expected)

    oracle_real : String <- run_stdout("/bin/realpath", [scan_s])
    r_real : RBytes() <- HFS.realpath(scan)
    +c_real : H.Check = H.chk("realpath-matches-oracle", realpath_text_nl(r_real), oracle_real)
    r_real_missing : RBytes() <- HFS.realpath(missing)
    +c_real_missing : H.Check = H.chk("realpath-missing-enoent", realpath_err_text(r_real_missing), "err:2")

    r_wrename : RUnit() <- HFS.write_file_bytes(rename_src, ascii_bytes("renamed\n"), 0)
    +c_wrename : H.Check = H.chk("write-rename-source", unit_text(r_wrename), "ok")
    r_rename : RUnit() <- HFS.rename(rename_src, rename_dst)
    +c_rename : H.Check = H.chk("rename-same-directory", unit_text(r_rename), "ok")
    r_rename_old : RStatInfo() <- HFS.lstat_info(rename_src)
    +c_rename_old : H.Check = H.chk("rename-old-missing", stat_result_shape(r_rename_old), "err:2")
    r_rename_new : RStatInfo() <- HFS.lstat_info(rename_dst)
    +c_rename_new : H.Check = H.chk("rename-new-file", stat_result_shape(r_rename_new), "file:0:8")
    got_renamed : Bytes() <- read_file_bytes(rename_dst)
    +c_renamed_bytes : H.Check = H.chkb("rename-preserves-bytes", bytes_eq(got_renamed, ascii_bytes("renamed\n")), True{})

    r_unlink : RUnit() <- HFS.unlink(rename_dst)
    +c_unlink : H.Check = H.chk("unlink-file", unit_text(r_unlink), "ok")
    r_unlink_missing : RUnit() <- HFS.unlink(rename_dst)
    +c_unlink_missing : H.Check = H.chk("unlink-missing-enoent", unit_text(r_unlink_missing), "err:2")
    r_unlink_gone : RStatInfo() <- HFS.lstat_info(rename_dst)
    +c_unlink_gone : H.Check = H.chk("unlink-path-gone", stat_result_shape(r_unlink_gone), "err:2")

    r_mkempty : RUnit() <- HFS.mkdir_one(empty_dir)
    +c_mkempty : H.Check = H.chk("mkdir-empty", unit_text(r_mkempty), "ok")
    r_rmdir_nonempty : RUnit() <- HFS.rmdir(scan)
    +c_rmdir_nonempty : H.Check = H.chkb("rmdir-nonempty-fails", unit_failed_nonzero(r_rmdir_nonempty), True{})
    r_rmdir : RUnit() <- HFS.rmdir(empty_dir)
    +c_rmdir : H.Check = H.chk("rmdir-empty", unit_text(r_rmdir), "ok")
    r_rmdir_gone : RStatInfo() <- HFS.lstat_info(empty_dir)
    +c_rmdir_gone : H.Check = H.chk("rmdir-path-gone", stat_result_shape(r_rmdir_gone), "err:2")

    r_stderr : RUnit() <- HFS.write_stderr_bytes(ascii_bytes("HOSTFS_STDERR_PROBE"))
    +c_stderr : H.Check = H.chk("write-stderr-exact-result", unit_text(r_stderr), "ok")

    +checks : List<&2, H.Check> = [
      c_mkroot, c_mkscan, c_mkexist,
      c_wzeta, c_walpha, c_mksub, c_wnested, c_wodd,
      c_wdata, c_data_exact, c_wlong, c_wshort, c_truncate_exact,
      c_excl_first, c_excl_second, c_write_missing,
      c_lstat_file, c_lstat_fifo, c_lstat_link, c_stat_link, c_lstat_odd, c_lstat_missing, c_stat_missing, c_same_ids, c_distinct_ids,
      c_readdir, c_real, c_real_missing,
      c_wrename, c_rename, c_rename_old, c_rename_new, c_renamed_bytes,
      c_unlink, c_unlink_missing, c_unlink_gone,
      c_mkempty, c_rmdir_nonempty, c_rmdir, c_rmdir_gone,
      c_stderr
    ]
    H.run(checks)
