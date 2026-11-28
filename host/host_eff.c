// pubend native host filesystem effects.
//
// ABI pinned to Bend 2.0.40.  This file is textually spliced into the
// generated program and deliberately uses that runtime's internal effect
// interface; review and rebuild it with every Bend upgrade.
//
// Paths are byte lists at the Bend boundary.  A byte above 255 is EINVAL;
// a NUL in a path is EILSEQ.  All errno values returned to Bend are positive
// host errno numbers.  Kind codes are 1=file, 2=directory, 3=symlink,
// 0=other, 255=unknown.

#include <dirent.h>
#include <fcntl.h>
#include <stdint.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

#define HF_KIND_OTHER 0u
#define HF_KIND_FILE 1u
#define HF_KIND_DIR 2u
#define HF_KIND_SYMLINK 3u
#define HF_KIND_UNKNOWN 255u

static u32 hf_kind_of_mode(mode_t mode) {
  return S_ISREG(mode) ? HF_KIND_FILE
    : S_ISDIR(mode) ? HF_KIND_DIR
    : S_ISLNK(mode) ? HF_KIND_SYMLINK
    : HF_KIND_OTHER;
}

static int hf_path_bad(char* path, u64 len) {
  return path == NULL ? EINVAL : io_nul(path, len) ? EILSEQ : 0;
}

static Term hf_unit_pack_free(Env e, IoWork* w, char* path) {
  free(path);
  return io_res(e, w, term_pak(CID(Unit), 0));
}

// stat/lstat ---------------------------------------------------------------

typedef struct HFStatReq {
  char* path;
  u32 kind;
  u64 size;
  u64 dev;
  u64 ino;
} HFStatReq;

static void hf_stat_fill(HFStatReq* q, struct stat* st) {
  q->kind = hf_kind_of_mode(st->st_mode);
  q->size = (u64)st->st_size;
  q->dev  = (u64)st->st_dev;
  q->ino  = (u64)st->st_ino;
}

static void hf_lstat_call(IoWork* w) {
  HFStatReq* q = (HFStatReq*)w->data;
  struct stat st;
  int n;
  do {
    n = lstat(q->path, &st);
  } while (n < 0 && errno == EINTR);
  io_sys_end(w, n);
  if (n == 0) {
    hf_stat_fill(q, &st);
  }
}

static void hf_stat_call(IoWork* w) {
  HFStatReq* q = (HFStatReq*)w->data;
  struct stat st;
  int n;
  do {
    n = stat(q->path, &st);
  } while (n < 0 && errno == EINTR);
  io_sys_end(w, n);
  if (n == 0) {
    hf_stat_fill(q, &st);
  }
}

static Term hf_u64_pair(Env e, u64 x) {
  return io_tup(e, (Term)(u32)(x >> 32), (Term)(u32)x);
}

static Term hf_stat_value(Env e, HFStatReq* q) {
  Term size = hf_u64_pair(e, q->size);
  Term dev  = hf_u64_pair(e, q->dev);
  Term ino  = hf_u64_pair(e, q->ino);
  return io_tup(e, (Term)q->kind, io_tup(e, size, io_tup(e, dev, ino)));
}

static Term hf_stat_pack(Env e, IoWork* w) {
  HFStatReq* q = (HFStatReq*)w->data;
  Term r = io_res(e, w, hf_stat_value(e, q));
  free(q->path);
  free(q);
  return r;
}

static Term hf_stat_start(Env e, Term* f, IoWork* w, int follow) {
  HFStatReq* q = io_mem(calloc(1, sizeof(HFStatReq)));
  q->path = io_cbuf(e, f[0], &w->size, CID(Con));
  w->code = hf_path_bad(q->path, w->size);
  if (w->code != 0) {
    free(q->path);
    free(q);
    return io_fail(e, w->code, NULL);
  }
  w->data = (char*)q;
  return io_work(w, follow ? hf_stat_call : hf_lstat_call, hf_stat_pack);
}

#ifdef CID(lstat_path)

Term hf_lstat_run(Env e, Term* f, IoWork* w) {
  return hf_stat_start(e, f, w, 0);
}

static void __attribute__((constructor)) hf_lstat_use(void) {
  io_eff(CID(lstat_path), hf_lstat_run);
}

#endif

#ifdef CID(stat_path)

Term hf_stat_run(Env e, Term* f, IoWork* w) {
  return hf_stat_start(e, f, w, 1);
}

static void __attribute__((constructor)) hf_stat_use(void) {
  io_eff(CID(stat_path), hf_stat_run);
}

#endif

// readdir ------------------------------------------------------------------

typedef struct HFEnt {
  char* name;
  u64 len;
  u32 kind;
} HFEnt;

typedef struct HFReadDirReq {
  char* path;
  u64 path_len;
  HFEnt* rows;
  u64 count;
  u64 cap;
} HFReadDirReq;

static int hf_ent_push(HFReadDirReq* q, const char* name, u64 len, u32 kind) {
  if (q->count == q->cap) {
    u64 cap = q->cap == 0 ? 16 : q->cap * 2;
    HFEnt* rows = realloc(q->rows, cap * sizeof(HFEnt));
    if (rows == NULL) {
      return -1;
    }
    q->rows = rows;
    q->cap = cap;
  }
  char* copy = malloc(len + 1);
  if (copy == NULL) {
    return -1;
  }
  memcpy(copy, name, len);
  copy[len] = 0;
  q->rows[q->count].name = copy;
  q->rows[q->count].len = len;
  q->rows[q->count].kind = kind;
  q->count += 1;
  return 0;
}

static char* hf_join_path(const char* dir, u64 dlen, const char* name, u64 nlen) {
  int slash = dlen == 0 || dir[dlen - 1] != '/';
  char* out = malloc(dlen + (u64)slash + nlen + 1);
  if (out == NULL) {
    return NULL;
  }
  memcpy(out, dir, dlen);
  if (slash) {
    out[dlen] = '/';
  }
  memcpy(out + dlen + (u64)slash, name, nlen);
  out[dlen + (u64)slash + nlen] = 0;
  return out;
}

#if defined(DT_UNKNOWN) && defined(DT_REG) && defined(DT_DIR) && defined(DT_LNK)
static u32 hf_kind_from_dtype(unsigned int dt) {
  return dt == DT_REG ? HF_KIND_FILE
    : dt == DT_DIR ? HF_KIND_DIR
    : dt == DT_LNK ? HF_KIND_SYMLINK
    : dt == DT_UNKNOWN ? HF_KIND_UNKNOWN
    : HF_KIND_OTHER;
}
#else
static u32 hf_kind_from_dtype(unsigned int dt) {
  (void)dt;
  return HF_KIND_UNKNOWN;
}
#endif

static u32 hf_entry_kind(HFReadDirReq* q, struct dirent* ent) {
#if defined(DT_UNKNOWN) && defined(DT_REG) && defined(DT_DIR) && defined(DT_LNK)
  u32 kind = hf_kind_from_dtype(ent->d_type);
#else
  u32 kind = HF_KIND_UNKNOWN;
#endif
  if (kind != HF_KIND_UNKNOWN) {
    return kind;
  }
  u64 nlen = strlen(ent->d_name);
  char* full = hf_join_path(q->path, q->path_len, ent->d_name, nlen);
  if (full == NULL) {
    return HF_KIND_UNKNOWN;
  }
  struct stat st;
  int n;
  do {
    n = lstat(full, &st);
  } while (n < 0 && errno == EINTR);
  free(full);
  return n == 0 ? hf_kind_of_mode(st.st_mode) : HF_KIND_UNKNOWN;
}

static int hf_ent_cmp(const void* av, const void* bv) {
  const HFEnt* a = (const HFEnt*)av;
  const HFEnt* b = (const HFEnt*)bv;
  u64 n = a->len < b->len ? a->len : b->len;
  int c = n == 0 ? 0 : memcmp(a->name, b->name, n);
  if (c != 0) {
    return c;
  }
  return a->len < b->len ? -1 : a->len > b->len ? 1 : 0;
}

static void hf_readdir_call(IoWork* w) {
  HFReadDirReq* q = (HFReadDirReq*)w->data;
  DIR* dir;
  do {
    dir = opendir(q->path);
  } while (dir == NULL && errno == EINTR);
  if (dir == NULL) {
    io_sys_end(w, -1);
    return;
  }

  w->code = 0;
  for (;;) {
    errno = 0;
    struct dirent* ent = readdir(dir);
    if (ent == NULL) {
      if (errno == EINTR) {
        continue;
      }
      if (errno != 0) {
        w->code = (u32)errno;
      }
      break;
    }
    if (strcmp(ent->d_name, ".") == 0 || strcmp(ent->d_name, "..") == 0) {
      continue;
    }
    u64 len = strlen(ent->d_name);
    if (hf_ent_push(q, ent->d_name, len, hf_entry_kind(q, ent)) != 0) {
      w->code = errno != 0 ? (u32)errno : ENOMEM;
      break;
    }
  }

  if (closedir(dir) != 0 && w->code == 0) {
    w->code = (u32)errno;
  }
  if (w->code == 0 && q->count > 1) {
    qsort(q->rows, q->count, sizeof(HFEnt), hf_ent_cmp);
  }
}

static void hf_readdir_free(HFReadDirReq* q) {
  for (u64 i = 0; i < q->count; i += 1) {
    free(q->rows[i].name);
  }
  free(q->rows);
  free(q->path);
  free(q);
}

static Term hf_readdir_pack(Env e, IoWork* w) {
  HFReadDirReq* q = (HFReadDirReq*)w->data;
  Term r;
  if (w->code != 0) {
    r = io_fail(e, w->code, NULL);
  } else {
    Term xs = term_pak(CID(Nil), 0);
    for (u64 i = q->count; i > 0; i -= 1) {
      Term name = io_list(e, q->rows[i - 1].name, q->rows[i - 1].len);
      Term row = io_node(e, CID(DirEntry), name, (Term)q->rows[i - 1].kind);
      xs = io_node(e, CID(Con), row, xs);
    }
    r = io_done(e, xs);
  }
  hf_readdir_free(q);
  return r;
}

#ifdef CID(readdir)

Term hf_readdir_run(Env e, Term* f, IoWork* w) {
  HFReadDirReq* q = io_mem(calloc(1, sizeof(HFReadDirReq)));
  q->path = io_cbuf(e, f[0], &q->path_len, CID(Con));
  w->code = hf_path_bad(q->path, q->path_len);
  if (w->code != 0) {
    free(q->path);
    free(q);
    return io_fail(e, w->code, NULL);
  }
  w->data = (char*)q;
  return io_work(w, hf_readdir_call, hf_readdir_pack);
}

static void __attribute__((constructor)) hf_readdir_use(void) {
  io_eff(CID(readdir), hf_readdir_run);
}

#endif

// realpath -----------------------------------------------------------------

typedef struct HFRealReq {
  char* path;
  char* out;
} HFRealReq;

static void hf_realpath_call(IoWork* w) {
  HFRealReq* q = (HFRealReq*)w->data;
  errno = 0;
  q->out = realpath(q->path, NULL);
  w->code = q->out == NULL ? (u32)errno : 0;
}

static Term hf_realpath_pack(Env e, IoWork* w) {
  HFRealReq* q = (HFRealReq*)w->data;
  Term r = w->code != 0 ? io_fail(e, w->code, NULL)
    : io_done(e, io_list(e, q->out, strlen(q->out)));
  free(q->out);
  free(q->path);
  free(q);
  return r;
}

#ifdef CID(realpath)

Term hf_realpath_run(Env e, Term* f, IoWork* w) {
  HFRealReq* q = io_mem(calloc(1, sizeof(HFRealReq)));
  q->path = io_cbuf(e, f[0], &w->size, CID(Con));
  w->code = hf_path_bad(q->path, w->size);
  if (w->code != 0) {
    free(q->path);
    free(q);
    return io_fail(e, w->code, NULL);
  }
  w->data = (char*)q;
  return io_work(w, hf_realpath_call, hf_realpath_pack);
}

static void __attribute__((constructor)) hf_realpath_use(void) {
  io_eff(CID(realpath), hf_realpath_run);
}

#endif

// one-path namespace operations ---------------------------------------------

typedef struct HFPathReq {
  char* path;
  int op;
} HFPathReq;

#define HF_OP_MKDIR 1
#define HF_OP_RMDIR 2
#define HF_OP_UNLINK 3

static void hf_pathop_call(IoWork* w) {
  HFPathReq* q = (HFPathReq*)w->data;
  int n;
  if (q->op == HF_OP_MKDIR) {
    do {
      n = mkdir(q->path, 0777);
    } while (n != 0 && errno == EINTR);
  } else if (q->op == HF_OP_RMDIR) {
    do {
      n = rmdir(q->path);
    } while (n != 0 && errno == EINTR);
  } else {
    do {
      n = unlink(q->path);
    } while (n != 0 && errno == EINTR);
  }
  io_sys_end(w, n);
}

static Term hf_pathop_pack(Env e, IoWork* w) {
  HFPathReq* q = (HFPathReq*)w->data;
  Term r = io_res(e, w, term_pak(CID(Unit), 0));
  free(q->path);
  free(q);
  return r;
}

static Term hf_pathop_start(Env e, Term* f, IoWork* w, int op) {
  HFPathReq* q = io_mem(calloc(1, sizeof(HFPathReq)));
  q->op = op;
  q->path = io_cbuf(e, f[0], &w->size, CID(Con));
  w->code = hf_path_bad(q->path, w->size);
  if (w->code != 0) {
    free(q->path);
    free(q);
    return io_fail(e, w->code, NULL);
  }
  w->data = (char*)q;
  return io_work(w, hf_pathop_call, hf_pathop_pack);
}

#ifdef CID(mkdir_one)

Term hf_mkdir_run(Env e, Term* f, IoWork* w) {
  return hf_pathop_start(e, f, w, HF_OP_MKDIR);
}

static void __attribute__((constructor)) hf_mkdir_use(void) {
  io_eff(CID(mkdir_one), hf_mkdir_run);
}

#endif

#ifdef CID(rmdir)

Term hf_rmdir_run(Env e, Term* f, IoWork* w) {
  return hf_pathop_start(e, f, w, HF_OP_RMDIR);
}

static void __attribute__((constructor)) hf_rmdir_use(void) {
  io_eff(CID(rmdir), hf_rmdir_run);
}

#endif

#ifdef CID(unlink)

Term hf_unlink_run(Env e, Term* f, IoWork* w) {
  return hf_pathop_start(e, f, w, HF_OP_UNLINK);
}

static void __attribute__((constructor)) hf_unlink_use(void) {
  io_eff(CID(unlink), hf_unlink_run);
}

#endif

// rename --------------------------------------------------------------------

typedef struct HFRenameReq {
  char* from;
  char* to;
} HFRenameReq;

static void hf_rename_call(IoWork* w) {
  HFRenameReq* q = (HFRenameReq*)w->data;
  int n;
  do {
    n = rename(q->from, q->to);
  } while (n != 0 && errno == EINTR);
  io_sys_end(w, n);
}

static Term hf_rename_pack(Env e, IoWork* w) {
  HFRenameReq* q = (HFRenameReq*)w->data;
  Term r = io_res(e, w, term_pak(CID(Unit), 0));
  free(q->from);
  free(q->to);
  free(q);
  return r;
}

#ifdef CID(rename)

Term hf_rename_run(Env e, Term* f, IoWork* w) {
  HFRenameReq* q = io_mem(calloc(1, sizeof(HFRenameReq)));
  u64 a = 0;
  u64 b = 0;
  q->from = io_cbuf(e, f[0], &a, CID(Con));
  q->to = io_cbuf(e, f[1], &b, CID(Con));
  w->code = hf_path_bad(q->from, a);
  if (w->code == 0) {
    w->code = hf_path_bad(q->to, b);
  }
  if (w->code != 0) {
    free(q->from);
    free(q->to);
    free(q);
    return io_fail(e, w->code, NULL);
  }
  w->data = (char*)q;
  return io_work(w, hf_rename_call, hf_rename_pack);
}

static void __attribute__((constructor)) hf_rename_use(void) {
  io_eff(CID(rename), hf_rename_run);
}

#endif

// exact-byte writes -----------------------------------------------------------

typedef struct HFWriteReq {
  char* path;
  char* bytes;
  u64 len;
  u32 exclusive;
} HFWriteReq;

static void hf_write_file_call(IoWork* w) {
  HFWriteReq* q = (HFWriteReq*)w->data;
  int flags = O_WRONLY | O_CREAT | (q->exclusive != 0 ? O_EXCL : O_TRUNC);
  int fd;
  do {
    fd = open(q->path, flags, 0666);
  } while (fd < 0 && errno == EINTR);
  if (fd < 0) {
    w->code = (u32)errno;
    return;
  }

  w->code = 0;
  u64 at = 0;
  while (at < q->len) {
    ssize_t n;
    do {
      n = write(fd, q->bytes + at, q->len - at);
    } while (n < 0 && errno == EINTR);
    if (n < 0) {
      w->code = (u32)errno;
      break;
    }
    if (n == 0) {
      w->code = EIO;
      break;
    }
    at += (u64)n;
  }

  // close is deliberately not retried after EINTR: POSIX does not specify
  // whether the descriptor remains open, and retrying can close a reused fd.
  if (close(fd) != 0 && w->code == 0) {
    w->code = (u32)errno;
  }
}

static Term hf_write_file_pack(Env e, IoWork* w) {
  HFWriteReq* q = (HFWriteReq*)w->data;
  Term r = io_res(e, w, term_pak(CID(Unit), 0));
  free(q->path);
  free(q->bytes);
  free(q);
  return r;
}

#ifdef CID(write_file_bytes)

Term hf_write_file_run(Env e, Term* f, IoWork* w) {
  HFWriteReq* q = io_mem(calloc(1, sizeof(HFWriteReq)));
  u64 plen = 0;
  q->path = io_cbuf(e, f[0], &plen, CID(Con));
  q->bytes = io_cbuf(e, f[1], &q->len, CID(Con));
  q->exclusive = (u32)f[2];
  w->code = hf_path_bad(q->path, plen);
  if (w->code == 0 && q->bytes == NULL) {
    w->code = EINVAL;
  }
  if (w->code != 0) {
    free(q->path);
    free(q->bytes);
    free(q);
    return io_fail(e, w->code, NULL);
  }
  w->data = (char*)q;
  return io_work(w, hf_write_file_call, hf_write_file_pack);
}

static void __attribute__((constructor)) hf_write_file_use(void) {
  io_eff(CID(write_file_bytes), hf_write_file_run);
}

#endif

// stderr ---------------------------------------------------------------------

static void hf_stderr_call(IoWork* w) {
  u64 at = 0;
  w->code = 0;
  while (at < w->size) {
    ssize_t n;
    do {
      n = write(STDERR_FILENO, w->data + at, w->size - at);
    } while (n < 0 && errno == EINTR);
    if (n < 0) {
      w->code = (u32)errno;
      return;
    }
    if (n == 0) {
      w->code = EIO;
      return;
    }
    at += (u64)n;
  }
}

static Term hf_stderr_pack(Env e, IoWork* w) {
  Term r = io_res(e, w, term_pak(CID(Unit), 0));
  free(w->data);
  return r;
}

#ifdef CID(write_stderr_bytes)

Term hf_stderr_run(Env e, Term* f, IoWork* w) {
  w->data = io_cbuf(e, f[0], &w->size, CID(Con));
  w->code = w->data == NULL ? EINVAL : 0;
  return w->code != 0 ? hf_stderr_pack(e, w)
    : io_work(w, hf_stderr_call, hf_stderr_pack);
}

static void __attribute__((constructor)) hf_stderr_use(void) {
  io_eff(CID(write_stderr_bytes), hf_stderr_run);
}

#endif
