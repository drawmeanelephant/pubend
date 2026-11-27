import Base

# pubend core model, v0 scaffold.
#
# These types are the altitude at which the flagship theorem is stated:
# resolution is decidable over the emitted publication artifact itself, so the
# theorem "compile produces only internally-consistent publications" is a
# proposition about pure data, never about the filesystem.

# Boolean eliminator. Bend cannot match on a computed value, so branching on a
# computed Bool routes through this helper whose parameter is matched.
def ifs(-A: Type, z: Bool, yes: Unit -> A, no: Unit -> A) -> A:
  match z:
    case True{}:
      yes(Unit{})
    case False{}:
      no(Unit{})

# A page id is its path relative to the content root, without extension,
# forward slashes. It is carried as a plain String; the path algebra that
# constrains it lives in the resolution spec (docs/v0-spec.md), not the type.

type SourcePage is Data:
  SourcePage{id: String, body: String}

# An emitted page carries the resolved internal link targets (as page ids)
# alongside its HTML. The links field is what the flagship law quantifies
# over: it is part of the compile artifact model, before and independent of
# however the HTML rendering happens to encode hrefs.
type EmittedPage is Data:
  EmittedPage{id: String, links: List<&2, String>, html: String}

type Publication is Data:
  Publication{pages: List<&2, EmittedPage>}

# v0 has no configuration surface. The type exists so the pipeline signature
# is stable when configuration arrives.
type Config is Data:
  Config{}

# --- The meaning of link integrity, as executable predicates ---------------
# These are real, testable definitions, not stubs: they define exactly what
# the flagship theorem claims compile always establishes.

def id_in_pages(+id: String, pages: List<&2, EmittedPage>) -> Bool:
  match pages:
    case Nil{}:
      False{}
    case +h <> +t:
      match h:
        case EmittedPage{+hid, links, html}:
          ifs(Bool, String.eq(id, hid),
            u => True{},
            u => id_in_pages(id, t))

def links_all_resolve(+pages: List<&2, EmittedPage>, links: List<&2, String>) -> Bool:
  match links:
    case Nil{}:
      True{}
    case +h <> +t:
      ifs(Bool, id_in_pages(h, pages),
        u => links_all_resolve(pages, t),
        u => False{})

def pages_all_resolve(pages: List<&2, EmittedPage>, +all: List<&2, EmittedPage>) -> Bool:
  match pages:
    case Nil{}:
      True{}
    case +h <> +t:
      match h:
        case EmittedPage{id, +links, html}:
          ifs(Bool, links_all_resolve(all, links),
            u => pages_all_resolve(t, all),
            u => False{})

def publication_links_resolve(pub: Publication) -> Bool:
  match pub:
    case Publication{+pages}:
      pages_all_resolve(pages, pages)
