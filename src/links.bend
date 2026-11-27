import Base
import ./model.bend as Model
import ./paths.bend as P
import ./percent.bend as Pct
import ../engine/src/ast.bend as Ast
import ../engine/src/document_links.bend as DocumentLinks

# Link classification and resolution (docs/v0-spec.md §5).
#
# The engine extracts raw link targets from each parsed page; this module
# classifies each target and resolves the internal ones as pure path
# algebra.  Nothing here touches the filesystem.
#
# Classification (§5.1):
#   external    — has an RFC3986-style scheme — untouched, outside all
#                 guarantees;
#   internal    — relative reference ending in ".md" before any "#fragment"
#                 or "?query" — resolved and checked;
#   passthrough — everything else (anchor-only "#x", absolute "/..." paths,
#                 non-md files) — unchecked in v0, documented as unverified.
#
# Resolution (§5.2), for internal targets T in page F:
#   split literal "#fragment" and "?query" delimiters before decoding;
#   reject literal "?" queries as content errors;
#   percent-decode the path portion exactly once as strict UTF-8;
#   join the decoded path onto dirname(F); normalize dot segments lexically;
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
  LErrMalformedPercent{}
  LErrInvalidPercentUtf8{}

# One content error, spanned by the page it occurred in and the
# engine-normalized AST target.  When the target came from bendown's typed
# DocumentLink API, the engine span and target-bearing node kind ride along as
# best-available provenance; string-only callers use None for both.
type LinkError is Data:
  LinkError{source: String, target: String, kind: LinkErrKind,
    span: Maybe<&2, Ast.Span>, link_kind: Maybe<&2, DocumentLinks.DocumentLinkKind>}

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

def l_error(+src: String, +t: String, k: LinkErrKind,
  span: Maybe<&2, Ast.Span>, link_kind: Maybe<&2, DocumentLinks.DocumentLinkKind>) -> LinkError:
  LinkError{src, t, k, span, link_kind}

def l_no_span() -> Maybe<&2, Ast.Span>:
  None{}

def l_no_link_kind() -> Maybe<&2, DocumentLinks.DocumentLinkKind>:
  None{}

def l_some_span(+span: Ast.Span) -> Maybe<&2, Ast.Span>:
  Some{span}

def l_some_link_kind(+kind: DocumentLinks.DocumentLinkKind) -> Maybe<&2, DocumentLinks.DocumentLinkKind>:
  Some{kind}

def l_err(+src: String, +t: String, k: LinkErrKind) -> LinkOutcome:
  LinkErr{l_error(src, t, k, l_no_span(), l_no_link_kind())}

def l_annotate_error(e: LinkError, +span: Ast.Span, +kind: DocumentLinks.DocumentLinkKind) -> LinkError:
  match e:
    case LinkError{+source, +target, +k, span0, kind0}:
      l_error(source, target, k, l_some_span(span), l_some_link_kind(kind))

def l_annotate_outcome(o: LinkOutcome, +span: Ast.Span, +kind: DocumentLinks.DocumentLinkKind) -> LinkOutcome:
  match o:
    case LinkPass{}:
      l_pass()
    case LinkOk{+id}:
      l_ok(id)
    case LinkErr{+e}:
      LinkErr{l_annotate_error(e, span, kind)}

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

def uri_scheme_char(+c: Char) -> Bool:
  Bool.or(Char.is_alpha(c), Bool.or(Char.is_digit(c),
    Bool.or(Char.is_eq(c, '+'), Bool.or(Char.is_eq(c, '-'), Char.is_eq(c, '.')))))

def uri_scheme_tail(s: String) -> Bool:
  match s:
    case SNil{}:
      False{}
    case SCon{':', t}:
      True{}
    case SCon{+h, t}:
      Model.ifs(Bool, uri_scheme_char(h),
        u => uri_scheme_tail(t),
        u => False{})

def uri_has_scheme(+t: String) -> Bool:
  match t:
    case SNil{}:
      False{}
    case SCon{+h, tail}:
      Bool.and(Char.is_alpha(h), uri_scheme_tail(tail))

def classify_link(+t: String) -> LinkClass:
  Model.ifs(LinkClass, uri_has_scheme(t),
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

# Literal `#` and `?` delimiters are split before decoding.  Only the path
# portion reaches this gate; malformed percent triplets and percent bytes that
# are not well-formed UTF-8 are independent content errors.  Encoded `#`, `?`,
# and dot segments are ordinary decoded path text here, so `%2E%2E` traverses
# exactly like literal `..` while `%23`/`%3F` do not become delimiters.
def resolve_decode(+src: String, +t: String, +ids: List<&2, String>, d: Pct.PercentResult) -> LinkOutcome:
  match d:
    case Pct.PercentMalformed{}:
      l_err(src, t, LErrMalformedPercent{})
    case Pct.PercentInvalidUtf8{}:
      l_err(src, t, LErrInvalidPercentUtf8{})
    case Pct.PercentOk{+decoded}:
      resolve_norm(src, t, ids,
        P.path_normalize(P.path_join(P.path_dirname(src), decoded)))

def resolve_query(+src: String, +t: String, +ids: List<&2, String>, q: Bool) -> LinkOutcome:
  match q:
    case True{}:
      l_err(src, t, LErrQuery{})
    case False{}:
      resolve_decode(src, t, ids, Pct.percent_decode(P.path_strip_fragment(t)))

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

# Resolve one engine-extracted target, preserving the engine span and the
# target-bearing node kind on any error.  Resolution itself still uses only
# the engine-normalized target string; the metadata is diagnostic provenance,
# never publication semantics.
def resolve_one_document_link(+src: String, +ids: List<&2, String>, x: DocumentLinks.DocumentLink) -> LinkOutcome:
  match x:
    case DocumentLinks.DocumentLink{+target, +span, +kind}:
      l_annotate_outcome(resolve_one(src, target, ids), span, kind)

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

def res_doc_go(+src: String, xs: List<&2, DocumentLinks.DocumentLink>, +ids: List<&2, String>) -> LinkResolution:
  match xs:
    case Nil{}:
      res_rid(Nil{}, Nil{})
    case +h <> t:
      res_cons(src, ids, resolve_one_document_link(src, ids, h), res_doc_go(src, t, ids))

# Detailed per-page resolution over bendown's DocumentLink values.  The ids
# are the same membership-verified ids produced by resolve_page_links over the
# targets; errors additionally carry span/kind provenance.
def resolve_page_document_links(+src: String, xs: List<&2, DocumentLinks.DocumentLink>,
  +ids: List<&2, String>) -> LinkResolution:
  res_doc_go(src, xs, ids)

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
