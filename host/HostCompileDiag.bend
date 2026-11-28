import Base
import ./HostCommon.bend as HC
import ../src/compile.bend as C
import ../src/frontmatter.bend as Fm
import ../src/graph.bend as G
import ../src/links.bend as L
import ../engine/src/ast.bend as Ast
import ../engine/src/document_links.bend as DocumentLinks

# Pure conversion from the in-process compile_report diagnostic model to the
# exact v0 wire diagnostic classes, field population, ordering, and message
# spellings used by the reference host.  There is no JavaScript artifact shape
# here: the constructors are consumed directly and cannot be malformed.

def fm_kind_name(k: Fm.FmErrKind) -> String:
  match k:
    case Fm.FmMalformed{}:
      "FmMalformed"
    case Fm.FmUnknownKey{}:
      "FmUnknownKey"
    case Fm.FmDupKey{}:
      "FmDupKey"
    case Fm.FmBadStatus{}:
      "FmBadStatus"
    case Fm.FmEmptyValue{}:
      "FmEmptyValue"

def fm_diag_class(k: Fm.FmErrKind) -> HC.DiagClass:
  match k:
    case Fm.FmMalformed{}:
      HC.DMalformedFrontmatter{}
    case Fm.FmUnknownKey{}:
      HC.DUnknownFrontmatterKey{}
    case Fm.FmDupKey{}:
      HC.DDuplicateFrontmatterKey{}
    case Fm.FmBadStatus{}:
      HC.DMalformedFrontmatter{}
    case Fm.FmEmptyValue{}:
      HC.DMalformedFrontmatter{}

def page_source_path(+page: String) -> String:
  page ++ ".md"

def frontmatter_diag(+page: String, e: Fm.FmError) -> HC.HostDiag:
  match e:
    case Fm.FmError{+kind, +line, +col, +detail}:
      HC.host_diag(fm_diag_class(kind), HC.maybe_string_some(page_source_path(page)),
        HC.maybe_string_some(page), HC.maybe_nat_some(line), HC.maybe_nat_some(col),
        HC.maybe_string_none(), HC.maybe_span_none(),
        "frontmatter diagnostic " ++ fm_kind_name(kind) ++ ": " ++ detail)

def graph_kind_name(k: G.DiagKind) -> String:
  match k:
    case G.DDupId{}:
      "DDupId"
    case G.DDupIdCase{}:
      "DDupIdCase"
    case G.DDangling{}:
      "DDangling"
    case G.DSelfParent{}:
      "DSelfParent"
    case G.DCycle{}:
      "DCycle"

def graph_diag_class(k: G.DiagKind) -> HC.DiagClass:
  match k:
    case G.DDupId{}:
      HC.DDuplicateId{}
    case G.DDupIdCase{}:
      HC.DDuplicateIdCase{}
    case G.DDangling{}:
      HC.DDanglingParent{}
    case G.DSelfParent{}:
      HC.DSelfParent{}
    case G.DCycle{}:
      HC.DParentCycle{}

def graph_other_suffix(m: Maybe<&2, String>) -> String:
  match m:
    case None{}:
      ""
    case Some{+other}:
      "; other page id: " ++ other

def graph_diag(e: G.Diag) -> HC.HostDiag:
  match e:
    case G.Diag{+kind, +id, +other}:
      HC.host_diag(graph_diag_class(kind), HC.maybe_string_some(page_source_path(id)),
        HC.maybe_string_some(id), HC.maybe_nat_none(), HC.maybe_nat_none(),
        other, HC.maybe_span_none(),
        "graph diagnostic " ++ graph_kind_name(kind) ++ graph_other_suffix(other))

def link_kind_name(k: L.LinkErrKind) -> String:
  match k:
    case L.LErrQuery{}:
      "LErrQuery"
    case L.LErrEscape{}:
      "LErrEscape"
    case L.LErrDangling{}:
      "LErrDangling"
    case L.LErrMalformedPercent{}:
      "LErrMalformedPercent"
    case L.LErrInvalidPercentUtf8{}:
      "LErrInvalidPercentUtf8"

def link_diag_class(k: L.LinkErrKind) -> HC.DiagClass:
  match k:
    case L.LErrQuery{}:
      HC.DLinkQuery{}
    case L.LErrEscape{}:
      HC.DLinkRootEscape{}
    case L.LErrDangling{}:
      HC.DLinkNonexistentPage{}
    case L.LErrMalformedPercent{}:
      HC.DLinkMalformedPercent{}
    case L.LErrInvalidPercentUtf8{}:
      HC.DLinkInvalidPercentUtf8{}

def document_link_kind_name(k: DocumentLinks.DocumentLinkKind) -> String:
  match k:
    case DocumentLinks.DocumentLinkInline{}:
      "DocumentLinkInline"
    case DocumentLinks.DocumentLinkAutolink{}:
      "DocumentLinkAutolink"
    case DocumentLinks.DocumentLinkImage{}:
      "DocumentLinkImage"

def document_link_kind_text(m: Maybe<&2, DocumentLinks.DocumentLinkKind>) -> String:
  match m:
    case None{}:
      "unavailable"
    case Some{+k}:
      document_link_kind_name(k)

def host_span_of_ast(s: Ast.Span) -> HC.HostSpan:
  match s:
    case Ast.Span{+start, +end}:
      HC.hs_span(start, end)

def host_span_maybe(m: Maybe<&2, Ast.Span>) -> Maybe<&2, HC.HostSpan>:
  match m:
    case None{}:
      HC.maybe_span_none()
    case Some{+s}:
      HC.maybe_span_some(host_span_of_ast(s))

def link_diag(e: L.LinkError) -> HC.HostDiag:
  match e:
    case L.LinkError{+source, +target, +kind, span, link_kind}:
      HC.host_diag(link_diag_class(kind), HC.maybe_string_some(page_source_path(source)),
        HC.maybe_string_some(source), HC.maybe_nat_none(), HC.maybe_nat_none(),
        HC.maybe_string_some(target), host_span_maybe(span),
        "link diagnostic " ++ link_kind_name(kind) ++
          "; target-bearing node kind " ++ document_link_kind_text(link_kind))

def compile_diag(d: C.CompileDiagnostic) -> HC.HostDiag:
  match d:
    case C.CDFrontmatter{+page, +error}:
      frontmatter_diag(page, error)
    case C.CDGraph{+error}:
      graph_diag(error)
    case C.CDLink{+error}:
      link_diag(error)

def compile_diags_go(xs: List<&2, C.CompileDiagnostic>) -> List<&2, HC.HostDiag>:
  match xs:
    case Nil{}:
      Nil{}
    case +h <> t:
      compile_diag(h) <> compile_diags_go(t)

def compile_failure_gate(+diagnostics: List<&2, HC.HostDiag>, empty: Bool) -> HC.HostFailure:
  match empty:
    case True{}:
      HC.host_failure_one(3, HC.host_diag_simple(HC.DHostError{},
        "compile_report returned CompileErr with no diagnostics"))
    case False{}:
      HC.host_failure(1, diagnostics)

# A nonempty CompileErr is a content failure (exit 1).  The empty case is not
# producible by the pure pipeline's failure stages, but keeping it explicit
# preserves the reference host's refusal to accept a vacuous error result.
def compile_failure(xs: List<&2, C.CompileDiagnostic>) -> HC.HostFailure:
  +ds = compile_diags_go(xs)
  compile_failure_gate(ds, List.is_empty(&2, HC.HostDiag, ds))
