import Base
import ./links.bend as L
import ./paths.bend as P
import ../engine/src/ast.bend as Ast

# Publication-owned, typed AST target rewriting (docs/v0-spec.md §5.3).
#
# This is deliberately a transformation of bendown's Ast.Document before
# Html.render_document: pubend never scans markdown source or rendered HTML,
# and bendown never learns about publication graphs.  Only the target fields
# named by the spec change — ILink.href, IAutolink.href, and IImage.src — and
# only when L.resolve_one succeeds.  Every span, title, attribute, child,
# block, and list/table cell is otherwise preserved.

# The target rewrite itself.  Resolution errors are impossible in a successful
# compile, but the transformation is total: error and passthrough outcomes
# leave the original target byte-for-byte unchanged.
def rw_target_fin(+source: String, +target: String, o: L.LinkOutcome) -> String:
  match o:
    case L.LinkOk{+id}:
      P.path_relative_html(source, id, P.path_fragment_suffix(target))
    case L.LinkErr{e}:
      target
    case L.LinkPass{}:
      target

def rewrite_target(+source: String, +ids: List<&2, String>, +target: String) -> String:
  rw_target_fin(source, target, L.resolve_one(source, target, ids))

# Bend does not admit mutual recursion.  As in bendown's renderer, one fueled
# dispatcher carries every mutually recursive AST contour.  Unlike rendering,
# each contour has a different result type, so the recursive result is a
# tagged sum and the call sites unwrap the tag that their input work item
# necessarily produced.
type RewriteWork is Data:
  RwInline{one: Ast.Inline}
  RwInlines{xs: List<&2, Ast.Inline>}
  RwBlock{one: Ast.Block}
  RwBlocks{xs: List<&2, Ast.Block>}
  RwItems{xs: List<&2, Ast.ListItem>}
  RwRows{xs: List<&2, Ast.TableRow>}
  RwCells{xs: List<&2, Ast.TableCell>}

type RewriteResult is Data:
  RwOutInline{one: Ast.Inline}
  RwOutInlines{xs: List<&2, Ast.Inline>}
  RwOutBlock{one: Ast.Block}
  RwOutBlocks{xs: List<&2, Ast.Block>}
  RwOutItems{xs: List<&2, Ast.ListItem>}
  RwOutRows{xs: List<&2, Ast.TableRow>}
  RwOutCells{xs: List<&2, Ast.TableCell>}

# --- tiny constructors and total unwrappers ---------------------------------

def rw_out_inline(one: Ast.Inline) -> RewriteResult:
  RwOutInline{one}

def rw_out_inlines(xs: List<&2, Ast.Inline>) -> RewriteResult:
  RwOutInlines{xs}

def rw_out_block(one: Ast.Block) -> RewriteResult:
  RwOutBlock{one}

def rw_out_blocks(xs: List<&2, Ast.Block>) -> RewriteResult:
  RwOutBlocks{xs}

def rw_out_items(xs: List<&2, Ast.ListItem>) -> RewriteResult:
  RwOutItems{xs}

def rw_out_rows(xs: List<&2, Ast.TableRow>) -> RewriteResult:
  RwOutRows{xs}

def rw_out_cells(xs: List<&2, Ast.TableCell>) -> RewriteResult:
  RwOutCells{xs}

def rw_dummy_inline() -> Ast.Inline:
  Ast.IText{"", Ast.span_empty()}

def rw_dummy_block() -> Ast.Block:
  Ast.BParagraph{Nil{}, Nil{}, Ast.span_empty()}

def rw_uninline(r: RewriteResult) -> Ast.Inline:
  match r:
    case RwOutInline{+one}:
      one
    case u:
      rw_dummy_inline()

def rw_uninlines(r: RewriteResult) -> List<&2, Ast.Inline>:
  match r:
    case RwOutInlines{+xs}:
      xs
    case u:
      Nil{}

def rw_unblock(r: RewriteResult) -> Ast.Block:
  match r:
    case RwOutBlock{+one}:
      one
    case u:
      rw_dummy_block()

def rw_unblocks(r: RewriteResult) -> List<&2, Ast.Block>:
  match r:
    case RwOutBlocks{+xs}:
      xs
    case u:
      Nil{}

def rw_unitems(r: RewriteResult) -> List<&2, Ast.ListItem>:
  match r:
    case RwOutItems{+xs}:
      xs
    case u:
      Nil{}

def rw_unrows(r: RewriteResult) -> List<&2, Ast.TableRow>:
  match r:
    case RwOutRows{+xs}:
      xs
    case u:
      Nil{}

def rw_uncells(r: RewriteResult) -> List<&2, Ast.TableCell>:
  match r:
    case RwOutCells{+xs}:
      xs
    case u:
      Nil{}

# --- the fueled dispatcher ----------------------------------------------------

def rewrite_work(+fuel: Nat, +source: String, +ids: List<&2, String>, work: RewriteWork) -> RewriteResult:
  match fuel:
    case 0n:
      rw_out_inlines(Nil{})
    case 1n++f:
      match work:
        case RwInlines{xs}:
          match xs:
            case Nil{}:
              rw_out_inlines(Nil{})
            case h <> t:
              rw_out_inlines(
                rw_uninline(rewrite_work(f, source, ids, RwInline{h})) <>
                rw_uninlines(rewrite_work(f, source, ids, RwInlines{t})))
        case RwInline{one}:
          match one:
            case Ast.IEmph{children, span}:
              rw_out_inline(Ast.IEmph{
                rw_uninlines(rewrite_work(f, source, ids, RwInlines{children})), span})
            case Ast.IStrong{children, span}:
              rw_out_inline(Ast.IStrong{
                rw_uninlines(rewrite_work(f, source, ids, RwInlines{children})), span})
            case Ast.IBold{children, span}:
              rw_out_inline(Ast.IBold{
                rw_uninlines(rewrite_work(f, source, ids, RwInlines{children})), span})
            case Ast.IItalic{children, span}:
              rw_out_inline(Ast.IItalic{
                rw_uninlines(rewrite_work(f, source, ids, RwInlines{children})), span})
            case Ast.IDeleted{children, span}:
              rw_out_inline(Ast.IDeleted{
                rw_uninlines(rewrite_work(f, source, ids, RwInlines{children})), span})
            case Ast.IInserted{children, span}:
              rw_out_inline(Ast.IInserted{
                rw_uninlines(rewrite_work(f, source, ids, RwInlines{children})), span})
            case Ast.ISuperscript{children, span}:
              rw_out_inline(Ast.ISuperscript{
                rw_uninlines(rewrite_work(f, source, ids, RwInlines{children})), span})
            case Ast.ISubscript{children, span}:
              rw_out_inline(Ast.ISubscript{
                rw_uninlines(rewrite_work(f, source, ids, RwInlines{children})), span})
            case Ast.ISpan{children, attrs, span}:
              rw_out_inline(Ast.ISpan{
                rw_uninlines(rewrite_work(f, source, ids, RwInlines{children})), attrs, span})
            case Ast.ILink{children, +href, title, span}:
              rw_out_inline(Ast.ILink{
                rw_uninlines(rewrite_work(f, source, ids, RwInlines{children})),
                rewrite_target(source, ids, href), title, span})
            case Ast.IImage{+src, alt, title, span}:
              rw_out_inline(Ast.IImage{rewrite_target(source, ids, src), alt, title, span})
            case Ast.IAutolink{+href, label, span}:
              rw_out_inline(Ast.IAutolink{rewrite_target(source, ids, href), label, span})
            case u:
              rw_out_inline(u)
        case RwBlocks{xs}:
          match xs:
            case Nil{}:
              rw_out_blocks(Nil{})
            case h <> t:
              rw_out_blocks(
                rw_unblock(rewrite_work(f, source, ids, RwBlock{h})) <>
                rw_unblocks(rewrite_work(f, source, ids, RwBlocks{t})))
        case RwBlock{one}:
          match one:
            case Ast.BParagraph{children, attrs, span}:
              rw_out_block(Ast.BParagraph{
                rw_uninlines(rewrite_work(f, source, ids, RwInlines{children})), attrs, span})
            case Ast.BHeading{level, children, attrs, span}:
              rw_out_block(Ast.BHeading{level,
                rw_uninlines(rewrite_work(f, source, ids, RwInlines{children})), attrs, span})
            case Ast.BBlockQuote{blocks, attrs, cite, span}:
              rw_out_block(Ast.BBlockQuote{
                rw_unblocks(rewrite_work(f, source, ids, RwBlocks{blocks})), attrs, cite, span})
            case Ast.BList{ordered, start, tight, items, span}:
              rw_out_block(Ast.BList{ordered, start, tight,
                rw_unitems(rewrite_work(f, source, ids, RwItems{items})), span})
            case Ast.BTable{alignments, rows, span}:
              rw_out_block(Ast.BTable{alignments,
                rw_unrows(rewrite_work(f, source, ids, RwRows{rows})), span})
            case u:
              rw_out_block(u)
        case RwItems{xs}:
          match xs:
            case Nil{}:
              rw_out_items(Nil{})
            case Ast.ListItem{blocks, span} <> t:
              rw_out_items(
                Ast.ListItem{rw_unblocks(rewrite_work(f, source, ids, RwBlocks{blocks})), span} <>
                rw_unitems(rewrite_work(f, source, ids, RwItems{t})))
        case RwRows{xs}:
          match xs:
            case Nil{}:
              rw_out_rows(Nil{})
            case Ast.TableRow{cells, attrs, span} <> t:
              rw_out_rows(
                Ast.TableRow{rw_uncells(rewrite_work(f, source, ids, RwCells{cells})), attrs, span} <>
                rw_unrows(rewrite_work(f, source, ids, RwRows{t})))
        case RwCells{xs}:
          match xs:
            case Nil{}:
              rw_out_cells(Nil{})
            case Ast.TableCell{header, align, colspan, rowspan, children, attrs, span} <> t:
              rw_out_cells(
                Ast.TableCell{header, align, colspan, rowspan,
                  rw_uninlines(rewrite_work(f, source, ids, RwInlines{children})), attrs, span} <>
                rw_uncells(rewrite_work(f, source, ids, RwCells{t})))

def rewrite_fuel() -> Nat:
  4294967295n

# Rewrite every resolvable internal target in a parsed document.  The document
# shape and traversal order are unchanged; only successful internal targets
# become relative .html paths.
def rewrite_document(+source: String, +ids: List<&2, String>, doc: Ast.Document) -> Ast.Document:
  match doc:
    case Ast.Document{blocks}:
      Ast.Document{rw_unblocks(rewrite_work(rewrite_fuel(), source, ids, RwBlocks{blocks}))}
