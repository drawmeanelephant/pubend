import Base

# Shared smoke-test harness for pubend's test/ files.
#
# Each test file builds a List<Check> of named expected/actual string
# comparisons, runs them through `run` from main, and prints one
# `name=PASS` or `name=FAIL got=... want=...` line per case, then a
# `FAILURES=<n>` summary.  The process exits nonzero when any case fails.
# esc/q escape strings so every rendering occupies exactly one line.

def esc(s: String) -> String:
  match s:
    case SNil{}:
      SNil{}
    case SCon{'\\', t}:
      "\\\\" ++ esc(t)
    case SCon{'\n', t}:
      "\\n" ++ esc(t)
    case SCon{'"', t}:
      "\\\"" ++ esc(t)
    case SCon{'\t', t}:
      "\\t" ++ esc(t)
    case SCon{h, t}:
      SCon{h, esc(t)}

def q(s: String) -> String:
  "\"" ++ esc(s) ++ "\""

type Check is Data:
  Check{name: String, ok: Bool, got: String, want: String}

def chk(+name: String, +got: String, +want: String) -> Check:
  Check{name, String.eq(got, want), got, want}

def bool_eq(a: Bool, b: Bool) -> Bool:
  match a b:
    case True{} True{}:
      True{}
    case False{} False{}:
      True{}
    case x y:
      False{}

def chkb(+name: String, +got: Bool, +want: Bool) -> Check:
  Check{name, bool_eq(got, want), Bool.show(got), Bool.show(want)}

def show_check(c: Check) -> String:
  match c:
    case Check{+name, ok, +got, +want}:
      match ok:
        case True{}:
          name ++ "=PASS"
        case False{}:
          name ++ "=FAIL got=" ++ q(got) ++ " want=" ++ q(want)

def count_fails(cs: List<&2, Check>) -> Nat:
  match cs:
    case Nil{}:
      0n
    case Check{name, ok, got, want} <> t:
      match ok:
        case True{}:
          count_fails(t)
        case False{}:
          1n+count_fails(t)

def print_checks(cs: List<&2, Check>) -> IO(Unit):
  match cs:
    case Nil{}:
      IO.pure(Unit, Unit{})
    case h <> t:
      do IO<Unit>:
        Unit <- IO.print(show_check(h))
        print_checks(t)

def finish(+fails: Nat, zero: Bool) -> IO(Unit):
  match zero:
    case True{}:
      IO.exit(0)
    case False{}:
      IO.exit(1)

# The standard main body: print every check, the failure count, and exit
# nonzero on any failure.
def run(+cs: List<&2, Check>) -> IO(Unit):
  do IO<Unit>:
    Unit <- print_checks(cs)
    +fails : Nat = count_fails(cs)
    Unit <- IO.print("FAILURES=" ++ Nat.show(fails))
    finish(fails, Nat.is_eq(fails, 0n))
