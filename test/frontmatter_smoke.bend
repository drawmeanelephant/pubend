import Base
import ./harness.bend as H
import ../src/frontmatter.bend as Fm

# Smoke tests for the closed frontmatter grammar (docs/v0-spec.md §3).
# Cases render parse_frontmatter results as one-line strings and compare
# against goldens; the last line is `FAILURES=<n>` and the process exits
# nonzero when any case fails.

def show_status(s: Fm.FmStatus) -> String:
  match s:
    case Fm.FmPublished{}:
      "published"
    case Fm.FmDraft{}:
      "draft"

def show_maybe_str(m: Maybe<&2, String>) -> String:
  match m:
    case None{}:
      "-"
    case Some{+x}:
      H.q(x)

def show_meta(m: Maybe<&2, Fm.FmMeta>) -> String:
  match m:
    case None{}:
      "-"
    case Some{+meta}:
      match meta:
        case Fm.FmMeta{+title, +parent, +status}:
          "{" ++ show_maybe_str(title) ++ "," ++ show_maybe_str(parent) ++
            "," ++ show_status(status) ++ "}"

def show_kind(k: Fm.FmErrKind) -> String:
  match k:
    case Fm.FmMalformed{}:
      "malformed"
    case Fm.FmUnknownKey{}:
      "unknown"
    case Fm.FmDupKey{}:
      "dup"
    case Fm.FmBadStatus{}:
      "badstatus"
    case Fm.FmEmptyValue{}:
      "emptyval"

def show_err(e: Fm.FmError) -> String:
  match e:
    case Fm.FmError{+kind, +line, +col, +detail}:
      show_kind(kind) ++ "@" ++ Nat.show(line) ++ ":" ++ Nat.show(col) ++ " " ++ H.q(detail)

def show_errs(es: List<&2, Fm.FmError>) -> String:
  match es:
    case Nil{}:
      ""
    case h <> Nil{}:
      show_err(h)
    case h <> t:
      show_err(h) ++ ";" ++ show_errs(t)

def show_result(r: Fm.FmResult) -> String:
  match r:
    case Fm.FmResult{+meta, +body, +errors}:
      "meta=" ++ show_meta(meta) ++ " body=" ++ H.q(body) ++
        " errs=[" ++ show_errs(errors) ++ "]"

def case_s(+name: String, +src: String, +want: String) -> H.Check:
  H.chk(name, show_result(Fm.parse_frontmatter(src)), want)

def checks() -> List<&2, H.Check>:
  case_s("empty", "",
    "meta=- body=\"\" errs=[]") <>
  case_s("no-fm", "# Hi\nbody",
    "meta=- body=\"# Hi\\nbody\" errs=[]") <>
  case_s("simple", "---\ntitle: Hi\n---\nbody",
    "meta={\"Hi\",-,published} body=\"body\" errs=[]") <>
  case_s("empty-block", "---\n---\nbody\n",
    "meta={-,-,published} body=\"body\\n\" errs=[]") <>
  case_s("all-keys", "---\ntitle: A\nparent: p\nstatus: draft\n---\nx",
    "meta={\"A\",\"p\",draft} body=\"x\" errs=[]") <>
  case_s("unknown-key", "---\nfoo: 1\n---\nb",
    "meta=- body=\"---\\nfoo: 1\\n---\\nb\" errs=[unknown@2:1 \"foo\"]") <>
  case_s("dup-key", "---\ntitle: a\ntitle: b\n---\nb",
    "meta=- body=\"---\\ntitle: a\\ntitle: b\\n---\\nb\" errs=[dup@3:1 \"title\"]") <>
  case_s("bad-status", "---\nstatus: bogus\n---\nb",
    "meta=- body=\"---\\nstatus: bogus\\n---\\nb\" errs=[badstatus@2:1 \"status\"]") <>
  case_s("status-case", "---\nstatus: Draft\n---\nb",
    "meta=- body=\"---\\nstatus: Draft\\n---\\nb\" errs=[badstatus@2:1 \"status\"]") <>
  case_s("unclosed", "---\ntitle: x",
    "meta=- body=\"---\\ntitle: x\" errs=[malformed@2:1 \"unclosed frontmatter block\"]") <>
  case_s("bad-line", "---\nbad line\n---\nb",
    "meta=- body=\"---\\nbad line\\n---\\nb\" errs=[malformed@2:4 \"bad line\"]") <>
  case_s("empty-title", "---\ntitle:\n---\nb",
    "meta=- body=\"---\\ntitle:\\n---\\nb\" errs=[emptyval@2:1 \"empty value\"]") <>
  case_s("open-trailing-space", "--- \nx",
    "meta=- body=\"--- \\nx\" errs=[]") <>
  case_s("crlf", "---\r\ntitle: x\r\n---\r\nb",
    "meta={\"x\",-,published} body=\"b\" errs=[]") <>
  case_s("value-trim", "---\ntitle:   spaced   \n---\nb",
    "meta={\"spaced\",-,published} body=\"b\" errs=[]") <>
  case_s("dash-key", "---\nmy-key: v\n---\nb",
    "meta=- body=\"---\\nmy-key: v\\n---\\nb\" errs=[unknown@2:1 \"my-key\"]") <>
  case_s("no-space-colon", "---\ntitle:x\n---\nb",
    "meta={\"x\",-,published} body=\"b\" errs=[]") <>
  case_s("upper-key", "---\nTitle: x\n---\nb",
    "meta=- body=\"---\\nTitle: x\\n---\\nb\" errs=[malformed@2:1 \"Title: x\"]") <>
  case_s("lead-space", "---\n title: x\n---\nb",
    "meta=- body=\"---\\n title: x\\n---\\nb\" errs=[malformed@2:1 \" title: x\"]") <>
  case_s("empty-key", "---\n: x\n---\nb",
    "meta=- body=\"---\\n: x\\n---\\nb\" errs=[malformed@2:1 \"\"]") <>
  case_s("colon-value", "---\ntitle: a: b\n---\nb",
    "meta={\"a: b\",-,published} body=\"b\" errs=[]") <>
  case_s("empty-parent", "---\nparent:\n---\nb",
    "meta=- body=\"---\\nparent:\\n---\\nb\" errs=[emptyval@2:1 \"empty value\"]") <>
  case_s("dup-status", "---\nparent: p\nstatus: draft\nstatus: x\n---\nb",
    "meta=- body=\"---\\nparent: p\\nstatus: draft\\nstatus: x\\n---\\nb\" errs=[dup@4:1 \"status\"]") <>
  case_s("body-lines", "---\ntitle: ok\n---\nbody1\nbody2\n",
    "meta={\"ok\",-,published} body=\"body1\\nbody2\\n\" errs=[]") <>
  case_s("close-eof", "---\n---",
    "meta={-,-,published} body=\"\" errs=[]") <>
  case_s("aggregate", "---\nfoo: 1\nbadline\nbar: 2\n---\nb",
    "meta=- body=\"---\\nfoo: 1\\nbadline\\nbar: 2\\n---\\nb\" errs=[unknown@2:1 \"foo\";malformed@3:8 \"badline\";unknown@4:1 \"bar\"]") <>
  case_s("fm-not-first", "x\n---\ntitle: a\n---\nb",
    "meta=- body=\"x\\n---\\ntitle: a\\n---\\nb\" errs=[]") <>
  case_s("underscore-key", "---\nkey_only: v\n---\nb",
    "meta=- body=\"---\\nkey_only: v\\n---\\nb\" errs=[malformed@2:4 \"key_only: v\"]") <>
  case_s("dashes-key", "---\n---key: x\n---\nb",
    "meta=- body=\"---\\n---key: x\\n---\\nb\" errs=[unknown@2:1 \"---key\"]") <>
  case_s("draft-only", "---\nstatus: draft\n---\nb",
    "meta={-,-,draft} body=\"b\" errs=[]") <>
  case_s("empty-then-dup", "---\ntitle:\ntitle: x\n---\nb",
    "meta=- body=\"---\\ntitle:\\ntitle: x\\n---\\nb\" errs=[emptyval@2:1 \"empty value\";dup@3:1 \"title\"]") <>
  Nil{}

def main() -> IO(Unit):
  H.run(checks())
