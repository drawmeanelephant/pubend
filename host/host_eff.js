// pubend host filesystem effects, JavaScript lane.
//
// ABI pinned to Bend 2.0.40.  This file is textually spliced into the
// generated JavaScript and interpreter lanes; review and rebuild it with
// every Bend upgrade.  Paths and file bytes are List U32 byte lists at the
// Bend boundary.  Kind codes are 1=file, 2=directory, 3=symlink, 0=other,
// 255=unknown.  Errnos are positive host errno numbers.
//
// Node/Bun expose Dirent names as Unicode strings, so readdir performs a
// separate raw-buffer name scan on platforms that support it.  Dirent kind
// bits are used only when their UTF-8 encoding exactly identifies a raw name;
// otherwise the entry is classified with lstat on the raw byte path.

const HF_KIND_OTHER = 0;
const HF_KIND_FILE = 1;
const HF_KIND_DIR = 2;
const HF_KIND_SYMLINK = 3;
const HF_KIND_UNKNOWN = 255;
const HF_EIO = 5;
const HF_EINVAL = 22;

function hf_unit() {
  return { $: CID(Unit) };
}

function hf_errno(e) {
  return Math.abs(e && e.errno !== undefined ? e.errno : HF_EIO);
}

function hf_eilseq() {
  return process.platform === "darwin" ? 92 : 84;
}

function hf_path(bytes) {
  if (bytes === null) {
    return { error: HF_EINVAL };
  }
  if (bytes.includes(0)) {
    return { error: hf_eilseq() };
  }
  return { path: Buffer.from(bytes) };
}

function hf_read_path(input) {
  return hf_path(io_unlist(input));
}

function hf_path_error(input) {
  const p = hf_read_path(input);
  return p.error !== undefined ? p : null;
}

function hf_split_u64(x) {
  const v = BigInt.asUintN(64, BigInt(x));
  return io_tup(Number((v >> 32n) & 0xffffffffn) >>> 0,
    Number(v & 0xffffffffn) >>> 0);
}

function hf_kind(st) {
  return st.isFile() ? HF_KIND_FILE
    : st.isDirectory() ? HF_KIND_DIR
    : st.isSymbolicLink() ? HF_KIND_SYMLINK
    : HF_KIND_OTHER;
}

function hf_stat_value(st) {
  return io_tup(hf_kind(st),
    io_tup(hf_split_u64(st.size),
      io_tup(hf_split_u64(st.dev), hf_split_u64(st.ino))));
}

function hf_stat_with(input, follow) {
  const bad = hf_path_error(input);
  if (bad) {
    return io_fail(bad.error);
  }
  try {
    const fs = require("fs");
    const path = Buffer.from(io_unlist(input));
    const st = follow ? fs.statSync(path, { bigint: true })
      : fs.lstatSync(path, { bigint: true });
    return io_done(hf_stat_value(st));
  } catch (e) {
    return io_fail(hf_errno(e));
  }
}

function hf_lstat_path(path, k) {
  io_park_on(undefined, 0, k, () => hf_stat_with(path, false), 0);
}

function hf_stat_path(path, k) {
  io_park_on(undefined, 0, k, () => hf_stat_with(path, true), 0);
}

function hf_join_bytes(dir, name) {
  const need = dir.length === 0 || dir[dir.length - 1] !== 47;
  const out = new Uint8Array(dir.length + (need ? 1 : 0) + name.length);
  out.set(dir, 0);
  if (need) {
    out[dir.length] = 47;
  }
  out.set(name, dir.length + (need ? 1 : 0));
  return out;
}

function hf_dirent_kind(ent) {
  if (ent.isFile()) {
    return HF_KIND_FILE;
  }
  if (ent.isDirectory()) {
    return HF_KIND_DIR;
  }
  if (ent.isSymbolicLink()) {
    return HF_KIND_SYMLINK;
  }
  return HF_KIND_UNKNOWN;
}

function hf_lstat_entry_kind(fs, dir, name) {
  try {
    const full = hf_join_bytes(dir, name);
    const st = fs.lstatSync(Buffer.from(full), { bigint: true });
    return hf_kind(st);
  } catch (_) {
    return HF_KIND_UNKNOWN;
  }
}

function hf_compare_bytes(a, b) {
  const n = Math.min(a.length, b.length);
  for (let i = 0; i < n; i += 1) {
    if (a[i] !== b[i]) {
      return a[i] - b[i];
    }
  }
  return a.length - b.length;
}

function hf_readdir_impl(input) {
  const bad = hf_path_error(input);
  if (bad) {
    return io_fail(bad.error);
  }
  const fs = require("fs");
  const dir = io_unlist(input);
  const dirbuf = Buffer.from(dir);
  try {
    // The buffer scan preserves raw POSIX name bytes.  Dirent kind bits come
    // from a separate scan keyed by exact UTF-8 bytes; collisions or names
    // that do not round-trip (including invalid UTF-8 on platforms that allow
    // them) fall back to an exact-path lstat.
    const names = fs.readdirSync(dirbuf, { encoding: "buffer" });
    // The typed scan is a kind-bit optimization only.  Real Node rejects
    // Buffer paths with withFileTypes (ERR_INVALID_ARG_TYPE despite the type
    // union), so any typed-scan failure degrades to per-entry lstat on exact
    // byte paths rather than failing the whole directory scan.
    let typed = [];
    try {
      typed = fs.readdirSync(dirbuf, { withFileTypes: true });
    } catch (e) {
      typed = [];
    }
    const kinds = new Map();
    const collisions = new Set();
    for (const ent of typed) {
      const key = Buffer.from(ent.name, "utf8").toString("hex");
      if (kinds.has(key)) {
        collisions.add(key);
      } else {
        kinds.set(key, hf_dirent_kind(ent));
      }
    }
    const rows = names.map((raw) => {
      const name = Buffer.from(raw);
      const key = name.toString("hex");
      let kind = collisions.has(key) ? HF_KIND_UNKNOWN : kinds.get(key);
      if (kind === undefined) {
        kind = HF_KIND_UNKNOWN;
      }
      if (kind === HF_KIND_UNKNOWN) {
        kind = hf_lstat_entry_kind(fs, dir, name);
      }
      return { name, kind };
    });
    rows.sort((a, b) => hf_compare_bytes(a.name, b.name));
    let xs = { $: CID(Nil) };
    for (let i = rows.length - 1; i >= 0; i -= 1) {
      const row = { $: CID(DirEntry),
        name: io_list(rows[i].name, rows[i].name.length), kind: rows[i].kind };
      xs = { $: CID(Con), head: row, tail: xs };
    }
    return io_done(xs);
  } catch (e) {
    return io_fail(hf_errno(e));
  }
}

function hf_readdir(path, k) {
  io_park_on(undefined, 0, k, () => hf_readdir_impl(path), 0);
}

function hf_realpath_impl(input) {
  const bad = hf_path_error(input);
  if (bad) {
    return io_fail(bad.error);
  }
  const bytes = io_unlist(input);
  if (bytes.length === 0) {
    // POSIX realpath("") is ENOENT; Node's realpathSync(Buffer.alloc(0))
    // silently canonicalizes the process cwd instead, which must never
    // be treated as a successful canonicalization.
    return io_fail(2);
  }
  try {
    const out = require("fs").realpathSync(Buffer.from(bytes),
      { encoding: "buffer" });
    return io_done(io_list(out, out.length));
  } catch (e) {
    return io_fail(hf_errno(e));
  }
}

function hf_realpath(path, k) {
  io_park_on(undefined, 0, k, () => hf_realpath_impl(path), 0);
}

function hf_pathop_impl(input, op) {
  const bad = hf_path_error(input);
  if (bad) {
    return io_fail(bad.error);
  }
  try {
    const fs = require("fs");
    const path = Buffer.from(io_unlist(input));
    if (op === "mkdir") {
      fs.mkdirSync(path);
    } else if (op === "rmdir") {
      fs.rmdirSync(path);
    } else {
      fs.unlinkSync(path);
    }
    return io_done(hf_unit());
  } catch (e) {
    return io_fail(hf_errno(e));
  }
}

function hf_mkdir_one(path, k) {
  io_park_on(undefined, 0, k, () => hf_pathop_impl(path, "mkdir"), 0);
}

function hf_rmdir(path, k) {
  io_park_on(undefined, 0, k, () => hf_pathop_impl(path, "rmdir"), 0);
}

function hf_unlink(path, k) {
  io_park_on(undefined, 0, k, () => hf_pathop_impl(path, "unlink"), 0);
}

function hf_rename_impl(from, to) {
  const bad_from = hf_path_error(from);
  if (bad_from) {
    return io_fail(bad_from.error);
  }
  const bad_to = hf_path_error(to);
  if (bad_to) {
    return io_fail(bad_to.error);
  }
  try {
    require("fs").renameSync(Buffer.from(io_unlist(from)),
      Buffer.from(io_unlist(to)));
    return io_done(hf_unit());
  } catch (e) {
    return io_fail(hf_errno(e));
  }
}

function hf_rename(from, to, k) {
  io_park_on(undefined, 0, k, () => hf_rename_impl(from, to), 0);
}

function hf_write_file_impl(path_input, data_input, exclusive) {
  const bad = hf_path_error(path_input);
  if (bad) {
    return io_fail(bad.error);
  }
  const data = io_unlist(data_input);
  if (data === null) {
    return io_fail(HF_EINVAL);
  }
  const fs = require("fs");
  let fd;
  try {
    fd = fs.openSync(Buffer.from(io_unlist(path_input)),
      exclusive !== 0 ? "wx" : "w", 0o666);
  } catch (e) {
    return io_fail(hf_errno(e));
  }

  let failure = 0;
  let at = 0;
  while (at < data.length) {
    try {
      const n = fs.writeSync(fd, data, at, data.length - at, null);
      if (n === 0) {
        failure = HF_EIO;
        break;
      }
      at += n;
    } catch (e) {
      failure = hf_errno(e);
      break;
    }
  }

  // Always close.  A close error is reported when no write/open error was
  // already first; an earlier error remains the first error.
  try {
    fs.closeSync(fd);
  } catch (e) {
    if (failure === 0) {
      failure = hf_errno(e);
    }
  }
  return failure === 0 ? io_done(hf_unit()) : io_fail(failure);
}

function hf_write_file_bytes(path, data, exclusive, k) {
  io_park_on(undefined, 0, k,
    () => hf_write_file_impl(path, data, exclusive), 0);
}

function hf_write_stderr_impl(data_input) {
  const data = io_unlist(data_input);
  if (data === null) {
    return io_fail(HF_EINVAL);
  }
  const fs = require("fs");
  let at = 0;
  try {
    while (at < data.length) {
      const n = fs.writeSync(2, data, at, data.length - at, null);
      if (n === 0) {
        return io_fail(HF_EIO);
      }
      at += n;
    }
    return io_done(hf_unit());
  } catch (e) {
    return io_fail(hf_errno(e));
  }
}

function hf_write_stderr_bytes(data, k) {
  io_park_on(undefined, 0, k, () => hf_write_stderr_impl(data), 0);
}

io_eff(CID(lstat_path), hf_lstat_path);
io_eff(CID(stat_path), hf_stat_path);
io_eff(CID(readdir), hf_readdir);
io_eff(CID(realpath), hf_realpath);
io_eff(CID(mkdir_one), hf_mkdir_one);
io_eff(CID(rmdir), hf_rmdir);
io_eff(CID(unlink), hf_unlink);
io_eff(CID(rename), hf_rename);
io_eff(CID(write_file_bytes), hf_write_file_bytes);
io_eff(CID(write_stderr_bytes), hf_write_stderr_bytes);
