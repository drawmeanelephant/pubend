import Base

# Canonical JSON serialization for the v0 `_pubend/manifest.json` schema
# (docs/v0-spec.md §7).  This module is pure string surgery: the filesystem
# host supplies page ids, output-relative paths, and lowercase SHA-256 hex
# digests, and receives exactly the bytes that Node's
# `JSON.stringify(manifest, null, 2) + "\n"` produced in the reference host.
#
# String escaping follows ECMAScript's well-formed JSON.stringify:
#   * the six JSON short escapes are used for backspace, tab, LF, FF, CR,
#     quote, and backslash;
#   * every other C0 control is `\u00xx` with lowercase hexadecimal digits;
#   * non-ASCII scalar characters are emitted literally (so a UTF-8 output
#     writer emits their UTF-8 bytes, not `\u` escapes);
#   * surrogate-valued Chars are emitted as lowercase `\udXXX` escapes.
#
# Bend String is a sequence of Unicode scalar values, not UTF-16 code units.
# Page ids reaching the host have already been validated as UTF-8, so surrogate
# values cannot occur in real input.  The escape rule above is the total,
# lossless policy for otherwise-unrepresentable Bend Char values.  It matches
# JSON.stringify's lone-surrogate behavior.  Unlike a UTF-16 JavaScript string,
# adjacent surrogate-valued Chars do not combine into an astral scalar here;
# astral characters are already single Bend Chars and are emitted literally.

def ifs(-A: Type, z: Bool, yes: Unit -> A, no: Unit -> A) -> A:
  match z:
    case True{}:
      yes(Unit{})
    case False{}:
      no(Unit{})

type HostManifestPage is Data:
  HostManifestPage{id: String, path: String, sha256: String}

def host_manifest_page(+id: String, +path: String, +sha256: String) -> HostManifestPage:
  HostManifestPage{id, path, sha256}

type HostJsonEscape is Data:
  HjPlain{}
  HjShort{escape: String}
  HjUnicode{code: U32}

def hj_plain() -> HostJsonEscape:
  HjPlain{}

def hj_short(+escape: String) -> HostJsonEscape:
  HjShort{escape}

def hj_unicode(+code: U32) -> HostJsonEscape:
  HjUnicode{code}

def hostjson_is_surrogate(+x: U32) -> Bool:
  Bool.and(U32.is_ge(x, 55296), U32.is_le(x, 57343))

# Classification is deliberately nested through `ifs`: Bend matches cannot
# scrutinize computed numeric comparisons directly.  The order is unimportant
# except that the short escapes are more specific than the C0-control rule.
def hostjson_classify(+c: Char) -> HostJsonEscape:
  +x = Char.to_u32(c)
  ifs(HostJsonEscape, U32.is_eq(x, 8),
    u => hj_short("\\b"),
    u => ifs(HostJsonEscape, U32.is_eq(x, 9),
      v => hj_short("\\t"),
      v => ifs(HostJsonEscape, U32.is_eq(x, 10),
        w => hj_short("\\n"),
        w => ifs(HostJsonEscape, U32.is_eq(x, 12),
          a => hj_short("\\f"),
          a => ifs(HostJsonEscape, U32.is_eq(x, 13),
            b => hj_short("\\r"),
            b => ifs(HostJsonEscape, U32.is_eq(x, 34),
              d => hj_short("\\\""),
              d => ifs(HostJsonEscape, U32.is_eq(x, 92),
                e => hj_short("\\\\"),
                e => ifs(HostJsonEscape, U32.is_le(x, 31),
                  f => hj_unicode(x),
                  f => ifs(HostJsonEscape, hostjson_is_surrogate(x),
                    g => hj_unicode(x),
                    g => hj_plain())))))))))

def hostjson_hex_digit(+x: U32) -> String:
  ifs(String, U32.is_le(x, 9),
    u => SCon{Char.from_u32(U32.add(x, 48)), SNil{}},
    u => SCon{Char.from_u32(U32.add(x, 87)), SNil{}})

# Exactly four lowercase hexadecimal digits after `\u`.  This width is right
# for both C0 controls and UTF-16 surrogate escape compatibility.
def hostjson_unicode_escape(+x: U32) -> String:
  "\\u" ++
    hostjson_hex_digit(U32.and(U32.shrn(x, 12n), 15)) ++
    hostjson_hex_digit(U32.and(U32.shrn(x, 8n), 15)) ++
    hostjson_hex_digit(U32.and(U32.shrn(x, 4n), 15)) ++
    hostjson_hex_digit(U32.and(x, 15))

def hostjson_escape_step(+c: Char, +tail: String, esc: HostJsonEscape) -> String:
  match esc:
    case HjPlain{}:
      SCon{c, tail}
    case HjShort{+escape}:
      escape ++ tail
    case HjUnicode{+code}:
      hostjson_unicode_escape(code) ++ tail

# Escape the inside of one JSON string literal, without its surrounding quotes.
def hostjson_escape_body(s: String) -> String:
  match s:
    case SNil{}:
      SNil{}
    case SCon{+h, +t}:
      hostjson_escape_step(h, hostjson_escape_body(t), hostjson_classify(h))

# One complete JSON string literal, including quotes.
def hostjson_string(+s: String) -> String:
  "\"" ++ hostjson_escape_body(s) ++ "\""

def hostjson_page_object(p: HostManifestPage) -> String:
  match p:
    case HostManifestPage{+id, +path, +sha256}:
      "    {\n" ++
        "      \"id\": " ++ hostjson_string(id) ++ ",\n" ++
        "      \"path\": " ++ hostjson_string(path) ++ ",\n" ++
        "      \"sha256\": " ++ hostjson_string(sha256) ++ "\n" ++
        "    }"

def hostjson_page_objects_join(xs: List<&2, HostManifestPage>) -> String:
  match xs:
    case Nil{}:
      ""
    case +h <> Nil{}:
      hostjson_page_object(h)
    case +h <> t:
      hostjson_page_object(h) ++ ",\n" ++ hostjson_page_objects_join(t)

def hostjson_pages_field(+pages: List<&2, HostManifestPage>, empty: Bool) -> String:
  match empty:
    case True{}:
      "  \"pages\": []\n"
    case False{}:
      "  \"pages\": [\n" ++ hostjson_page_objects_join(pages) ++ "\n  ]\n"

# The v0 schema has exactly one version, integer 1.  Fixing it here keeps the
# serializer total for the only schema the native host is allowed to write;
# there is deliberately no general-purpose JSON number/object writer.
def hostjson_manifest(+pages: List<&2, HostManifestPage>) -> String:
  "{\n" ++
    "  \"version\": 1,\n" ++
    hostjson_pages_field(pages, List.is_empty(&2, HostManifestPage, pages)) ++
    "}\n"
