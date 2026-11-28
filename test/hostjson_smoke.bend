import Base
import ./harness.bend as H
import ../src/hostjson.bend as J

# Golden-byte smoke tests for canonical manifest JSON.  The expected texts in
# this file were generated with JavaScript's JSON.stringify(value, null, 2)
# plus one trailing newline using both the local Bun facade and a temporary
# official Node.js v24.11.1 binary.  The ASCII/control/Unicode cases were cross-checked against
# ECMAScript's well-formed JSON.stringify rule and Python's strict canonical
# auditor logic in tools/check_output.py.

def sha() -> String:
  "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

def expected_empty() -> String:
  "{\n" ++
    "  \"version\": 1,\n" ++
    "  \"pages\": []\n" ++
    "}\n"

def expected_one() -> String:
  "{\n" ++
    "  \"version\": 1,\n" ++
    "  \"pages\": [\n" ++
    "    {\n" ++
    "      \"id\": \"index\",\n" ++
    "      \"path\": \"index.html\",\n" ++
    "      \"sha256\": \"" ++ sha() ++ "\"\n" ++
    "    }\n" ++
    "  ]\n" ++
    "}\n"

def special_pages() -> List<&2, J.HostManifestPage>:
  J.host_manifest_page("quote\"back\\slash", "quote\"back\\slash.html", sha()) <>
  J.host_manifest_page("line\nfeed\ttab\u{1}ctl", "line\nfeed\ttab\u{1}ctl.html", sha()) <>
  J.host_manifest_page("😀/𠀀/é", "😀/𠀀/é.html", sha()) <>
  Nil{}

def expected_special() -> String:
  "{\n" ++
    "  \"version\": 1,\n" ++
    "  \"pages\": [\n" ++
    "    {\n" ++
    "      \"id\": \"quote\\\"back\\\\slash\",\n" ++
    "      \"path\": \"quote\\\"back\\\\slash.html\",\n" ++
    "      \"sha256\": \"" ++ sha() ++ "\"\n" ++
    "    },\n" ++
    "    {\n" ++
    "      \"id\": \"line\\nfeed\\ttab\\u0001ctl\",\n" ++
    "      \"path\": \"line\\nfeed\\ttab\\u0001ctl.html\",\n" ++
    "      \"sha256\": \"" ++ sha() ++ "\"\n" ++
    "    },\n" ++
    "    {\n" ++
    "      \"id\": \"😀/𠀀/é\",\n" ++
    "      \"path\": \"😀/𠀀/é.html\",\n" ++
    "      \"sha256\": \"" ++ sha() ++ "\"\n" ++
    "    }\n" ++
    "  ]\n" ++
    "}\n"

def lone_high() -> String:
  SCon{Char.from_u32(55296), SNil{}}

def lone_low() -> String:
  SCon{Char.from_u32(57343), SNil{}}

def checks() -> List<&2, H.Check>:
  H.chk("manifest-empty", J.hostjson_manifest(Nil{}), expected_empty()) <>
  H.chk("manifest-one", J.hostjson_manifest(J.host_manifest_page("index", "index.html", sha()) <> Nil{}), expected_one()) <>
  H.chk("manifest-special", J.hostjson_manifest(special_pages()), expected_special()) <>
  H.chk("escape-quote", J.hostjson_string("\""), "\"\\\"\"") <>
  H.chk("escape-backslash", J.hostjson_string("\\"), "\"\\\\\"") <>
  H.chk("escape-newline", J.hostjson_string("\n"), "\"\\n\"") <>
  H.chk("escape-tab", J.hostjson_string("\t"), "\"\\t\"") <>
  H.chk("escape-control-01", J.hostjson_string("\u{1}"), "\"\\u0001\"") <>
  H.chk("escape-control-1f", J.hostjson_string("\u{1f}"), "\"\\u001f\"") <>
  H.chk("escape-control-00", J.hostjson_string("\u{0}"), "\"\\u0000\"") <>
  H.chk("escape-control-0b", J.hostjson_string("\u{b}"), "\"\\u000b\"") <>
  H.chk("escape-control-0e", J.hostjson_string("\u{e}"), "\"\\u000e\"") <>
  H.chk("escape-del-literal", J.hostjson_string("\u{7f}"), "\"\u{7f}\"") <>
  H.chk("escape-unicode-literal", J.hostjson_string("é\u{2028}😀"), "\"é\u{2028}😀\"") <>
  H.chk("escape-lone-high", J.hostjson_string(lone_high()), "\"\\ud800\"") <>
  H.chk("escape-lone-low", J.hostjson_string(lone_low()), "\"\\udfff\"") <>
  Nil{}

def main() -> IO(Unit):
  H.run(checks())
