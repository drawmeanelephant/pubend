import Base
import ./model.bend as Model
import ./paths.bend as P

# Link classification and resolution (docs/v0-spec.md §5).
#
# The engine extracts raw link targets from each parsed page; this module
# classifies each target and resolves the internal ones as pure path
# algebra.  Nothing here touches the filesystem.
#
# Classification (§5.1):
#   external    — contains "://" or starts with "mailto:" — untouched,
#                 outside all guarantees;
#   internal    — relative reference ending in ".md" before any "#fragment"
#                 or "?query" — resolved and checked;
#   passthrough — everything else (anchor-only "#x", absolute "/..." paths,
#                 non-md files) — unchecked in v0, documented as unverified.
#
# Resolution (§5.2), for internal targets T in page F:
#   strip "#fragment" (fragments pass through unvalidated);
#   reject "?" queries as content errors (the spec's proposed resolution);
#   join T onto dirname(F); normalize dot segments lexically;
#   reject escapes above the content root;
#   the result minus ".md" must name an existing page id.
#
# The provability-relevant fact: resolve_page_links conses a resolved id
# into its output ONLY through the str_member check — that is what the
# link_integrity law quantifies over, so the emitted link list is
# membership-verified by construction.

type LinkClass is Data:
  LExternal{}
  LInternal{}
  LPassthrough{}

type LinkErrKind is Data:
  LErrQuery{}
  LErrEscape{}
  LErrDangling{}

# One content error, spanned by the page it occurred in and the raw target.
type LinkError is Data:
  LinkError{source: String, target: String, kind: LinkErrKind}

# The outcome of resolving one raw target: a verified page id, a content
# error, or a pass-through that contributes nothing to the emitted link
# list.
type LinkOutcome is Data:
  LinkOk{id: String}
  LinkErr{e: LinkError}
  LinkPass{}

# Per-page result: verified resolved ids paired with the errors found.
# Emission uses the ids only when the error half is empty.
type LinkResolution is Data:
  LinkResolution{ids: List<&2, String>, errors: List<&2, LinkError>}

# --- small factories --------------------------------------------------------

def l_ok(+id: String) -> LinkOutcome:
  LinkOk{id}

def l_pass() -> LinkOutcome:
  LinkPass{}

def l_err(+src: String, +t: String, k: LinkErrKind) -> LinkOutcome:
  LinkErr{LinkError{src, t, k}}

def l_res(ids: List<&2, String>, errors: List<&2, LinkError>) -> LinkResolution:
  LinkResolution{ids, errors}

# --- helpers ---------------------------------------------------------------

def head_str(xs: List<&2, String>) -> String:
  match xs:
    case Nil{}:
      ""
    case +h <> t:
      h

# The classification base: target minus any "#fragment", then minus any
# "?query".  Queries are stripped HERE so that "x.md?y=1" classifies as
# internal and is then rejected by the resolution stage's query rule —
# silently passing it through would hide what was clearly meant to be a
# page link.
def class_base(+t: String) -> String:
  head_str(String.split(head_str(String.split(t, '#')), '?'))

def is_internal_base(+cb: String) -> Bool:
  Bool.and(String.ends_with(cb, ".md"),
    Bool.not(String.starts_with(cb, "/")))

def classify_link(+t: String) -> LinkClass:
  Model.ifs(LinkClass,
    Bool.or(String.contains(t, "://"), String.starts_with(t, "mailto:")),
    u => LExternal{},
    u => Model.ifs(LinkClass, is_internal_base(class_base(t)),
      u2 => LInternal{},
      u2 => LPassthrough{}))

# Membership over a plain id list — the gate every resolved id passes
# through.  This is the check the flagship law eventually quantifies over.
def str_member(+id: String, xs: List<&2, String>) -> Bool:
  match xs:
    case Nil{}:
      False{}
    case +h <> t:
      Bool.or(String.eq(id, h), str_member(id, t))

# --- resolution --------------------------------------------------------------
#
# Every branch point in this path is a named helper that MATCHES ON A
# PARAMETER (resolve_mem on the membership Bool, resolve_query on the
# query Bool, resolve_norm on the PathResult, resolve_cls on the class).
# That is deliberate: lemmas in PROOF.bend quantify over those parameters
# and discharge each branch by case analysis — an inline Boolean
# eliminator would leave the scrutinee stuck inside the def where no
# proof can match it.

# The final gate: the stripped id must name a page.  LinkOk is reachable
# ONLY through str_member — by construction, not by audit.
def resolve_mem(+src: String, +t: String, +ids: List<&2, String>, +id: String, mem: Bool) -> LinkOutcome:
  match mem:
    case False{}:
      l_err(src, t, LErrDangling{})
    case True{}:
      l_ok(id)

def resolve_member(+src: String, +t: String, +ids: List<&2, String>, +id: String) -> LinkOutcome:
  resolve_mem(src, t, ids, id, str_member(id, ids))

# The normalized path must not have escaped the content root; then the
# ".md" suffix comes off (classification guaranteed it ends in ".md") and
# membership decides.
def resolve_norm(+src: String, +t: String, +ids: List<&2, String>, n: P.PathResult) -> LinkOutcome:
  match n:
    case P.PathEscape{}:
      l_err(src, t, LErrEscape{})
    case P.PathOk{+path}:
      resolve_member(src, t, ids, P.path_strip_md(path))

def resolve_query(+src: String, +t: String, +ids: List<&2, String>, q: Bool) -> LinkOutcome:
  match q:
    case True{}:
      l_err(src, t, LErrQuery{})
    case False{}:
      resolve_norm(src, t, ids,
        P.path_normalize(P.path_join(P.path_dirname(src), P.path_strip_fragment(t))))

def resolve_internal(+src: String, +t: String, +ids: List<&2, String>) -> LinkOutcome:
  resolve_query(src, t, ids, P.path_has_query(P.path_strip_fragment(t)))

def resolve_cls(+src: String, +t: String, +ids: List<&2, String>, c: LinkClass) -> LinkOutcome:
  match c:
    case LExternal{}:
      l_pass()
    case LPassthrough{}:
      l_pass()
    case LInternal{}:
      resolve_internal(src, t, ids)

# Resolve one raw target found in page `src`.
def resolve_one(+src: String, +t: String, +ids: List<&2, String>) -> LinkOutcome:
  resolve_cls(src, t, ids, classify_link(t))

# --- per-page collection --------------------------------------------------------

def res_rid(+ids: List<&2, String>, +errors: List<&2, LinkError>) -> LinkResolution:
  LinkResolution{ids, errors}

# The cons-step: verified ids accumulate into `ids`, errors into `errors`,
# passthroughs contribute nothing.
def res_cons(+src: String, +ids: List<&2, String>, o: LinkOutcome, rest: LinkResolution) -> LinkResolution:
  match o:
    case LinkPass{}:
      rest
    case LinkOk{+id}:
      match rest:
        case LinkResolution{+rs, +es}:
          res_rid(id <> rs, es)
    case LinkErr{+e}:
      match rest:
        case LinkResolution{+rs2, +es2}:
          res_rid(rs2, e <> es2)

def res_go(+src: String, ts: List<&2, String>, +ids: List<&2, String>) -> LinkResolution:
  match ts:
    case Nil{}:
      res_rid(Nil{}, Nil{})
    case +h <> t:
      res_cons(src, ids, resolve_one(src, h, ids), res_go(src, t, ids))

# Resolve every raw link target found in page `src` against the page id
# set.  Verified ids and errors both aggregate — emission fails the page
# (and the build) when errors is non-empty.
def resolve_page_links(+src: String, ts: List<&2, String>, +ids: List<&2, String>) -> LinkResolution:
  res_go(src, ts, ids)

def resolution_ids(+r: LinkResolution) -> List<&2, String>:
  match r:
    case LinkResolution{+ids, errors}:
      ids

def resolution_errors(+r: LinkResolution) -> List<&2, LinkError>:
  match r:
    case LinkResolution{ids, +errors}:
      errors

def resolution_clean(+r: LinkResolution) -> Bool:
  List.is_empty(&2, LinkError, resolution_errors(r))
