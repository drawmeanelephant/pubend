import Base
import ./HostCommon.bend as HC

def Bytes() -> Data:
  List<&2, U32>

# Byte-preserving CLI parsing for exactly:
#   build DIR [--out OUT]
# The command and option tokens are ASCII bytes; values remain raw POSIX path
# bytes until filesystem resolution.  Error text displays bytes as UTF-8 when
# possible, matching the reference host for every valid UTF-8 invocation.

type CliConfig is Data:
  CliConfig{dir_arg: Bytes(), out_arg: Maybe<&2, List<&2, U32>>}

type CliResult is Data:
  CliParsed{config: CliConfig}
  CliInvalid{failure: HC.HostFailure}

type CliArgKind is Data:
  CliArgDashDash{}
  CliArgOut{}
  CliArgUnknown{}
  CliArgPositional{}

type CliScan is Data:
  CliScan{positional: List<&2, List<&2, U32>>, out_arg: Maybe<&2, List<&2, U32>>,
    saw_out: Bool, end_options: Bool}

type CliTransition is Data:
  CliTEnd{scan: CliScan}
  CliTNext{args: List<&2, List<&2, U32>>, scan: CliScan}
  CliTError{failure: HC.HostFailure}

type CliWork is Data:
  CliWArgs{args: List<&2, List<&2, U32>>, scan: CliScan}
  CliWTransition{transition: CliTransition}

def cli_config(+dir_arg: Bytes(), out_arg: Maybe<&2, List<&2, U32>>) -> CliConfig:
  CliConfig{dir_arg, out_arg}

def cli_parsed(+config: CliConfig) -> CliResult:
  CliParsed{config}

def cli_invalid(+failure: HC.HostFailure) -> CliResult:
  CliInvalid{failure}

def cli_dashdash() -> CliArgKind:
  CliArgDashDash{}

def cli_out() -> CliArgKind:
  CliArgOut{}

def cli_unknown() -> CliArgKind:
  CliArgUnknown{}

def cli_positional() -> CliArgKind:
  CliArgPositional{}

def cli_scan(positional: List<&2, List<&2, U32>>, out_arg: Maybe<&2, List<&2, U32>>,
  saw_out: Bool, end_options: Bool) -> CliScan:
  CliScan{positional, out_arg, saw_out, end_options}

def cli_tend(scan: CliScan) -> CliTransition:
  CliTEnd{scan}

def cli_tnext(args: List<&2, List<&2, U32>>, scan: CliScan) -> CliTransition:
  CliTNext{args, scan}

def cli_terror(+failure: HC.HostFailure) -> CliTransition:
  CliTError{failure}

def cli_wargs(args: List<&2, List<&2, U32>>, scan: CliScan) -> CliWork:
  CliWArgs{args, scan}

def cli_wtransition(transition: CliTransition) -> CliWork:
  CliWTransition{transition}

def cli_bytes_some(+x: Bytes()) -> Maybe<&2, List<&2, U32>>:
  Some{x}

def cli_bytes_none() -> Maybe<&2, List<&2, U32>>:
  None{}

def usage_suffix() -> String:
  "; usage: ./pubend build DIR [--out OUT]"

def cli_usage_failure(+message: String) -> HC.HostFailure:
  HC.host_failure_one(2, HC.host_diag_simple(HC.DUsageError{}, message ++ usage_suffix()))

def cli_invalid_result(+message: String) -> CliResult:
  cli_invalid(cli_usage_failure(message))

def cli_error_transition(+message: String) -> CliTransition:
  cli_terror(cli_usage_failure(message))

def cli_token_build() -> Bytes():
  HC.ascii_bytes("build")

def cli_token_dashdash() -> Bytes():
  HC.ascii_bytes("--")

def cli_token_out() -> Bytes():
  HC.ascii_bytes("--out")

def cli_token_dashprefix() -> Bytes():
  HC.ascii_bytes("--")

def cli_classify_open(+arg: Bytes()) -> CliArgKind:
  Bool.pick(CliArgKind, HC.bytes_eq(arg, cli_token_dashdash()), cli_dashdash(),
    Bool.pick(CliArgKind, HC.bytes_eq(arg, cli_token_out()), cli_out(),
      Bool.pick(CliArgKind, HC.bytes_starts_with(arg, cli_token_dashprefix()), cli_unknown(), cli_positional())))

def cli_classify(+arg: Bytes(), end_options: Bool) -> CliArgKind:
  match end_options:
    case True{}:
      cli_positional()
    case False{}:
      cli_classify_open(arg)

def cli_scan_end(scan: CliScan) -> Bool:
  match scan:
    case CliScan{positional, out_arg, saw_out, +end_options}:
      end_options

def cli_finish(scan: CliScan) -> CliResult:
  match scan:
    case CliScan{+positional, out_arg, saw_out, end_options}:
      match positional:
        case +dir <> Nil{}:
          cli_parsed(cli_config(dir, out_arg))
        case other:
          cli_invalid_result("build requires exactly one DIR, got " ++
            Nat.show(List.length(&2, List<&2, U32>, positional)))

def cli_out_error(+saw_out: Bool) -> CliTransition:
  match saw_out:
    case True{}:
      cli_error_transition("duplicate --out option")
    case False{}:
      cli_error_transition("--out requires a value")

def cli_out_transition(positional: List<&2, List<&2, U32>>, end_options: Bool,
  saw_out: Bool, rest: List<&2, List<&2, U32>>) -> CliTransition:
  match saw_out:
    case True{}:
      cli_error_transition("duplicate --out option")
    case False{}:
      match rest:
        case Nil{}:
          cli_error_transition("--out requires a value")
        case +value <> tail:
          cli_tnext(tail, cli_scan(positional, cli_bytes_some(value), True{}, end_options))

def cli_transition_kind(+arg: Bytes(), rest: List<&2, List<&2, U32>>, scan: CliScan,
  kind: CliArgKind) -> CliTransition:
  match scan:
    case CliScan{positional, out_arg, saw_out, end_options}:
      match kind:
        case CliArgDashDash{}:
          cli_tnext(rest, cli_scan(positional, out_arg, True{}, True{}))
        case CliArgUnknown{}:
          cli_error_transition("unknown option: " ++ HC.bytes_display(arg))
        case CliArgPositional{}:
          cli_tnext(rest, cli_scan(List.append(&2, List<&2, U32>, positional, arg <> Nil{}),
            out_arg, saw_out, end_options))
        case CliArgOut{}:
          cli_out_transition(positional, end_options, saw_out, rest)

def cli_transition(args: List<&2, List<&2, U32>>, +scan: CliScan) -> CliTransition:
  match args:
    case Nil{}:
      cli_tend(scan)
    case +h <> t:
      cli_transition_kind(h, t, scan, cli_classify(h, cli_scan_end(scan)))

def cli_fuel_go(args: List<&2, List<&2, U32>>, acc: Nat) -> Nat:
  match args:
    case Nil{}:
      acc
    case h <> t:
      cli_fuel_go(t, 2n+acc)

def cli_parse_fuel(+args: List<&2, List<&2, U32>>) -> Nat:
  cli_fuel_go(args, 2n)

# One fueled-by-input work-item loop: Bend has no mutual recursion, so the
# transition computation and the recursive parser driver are different states
# of this one self-recursive function.  Fuel exhaustion is unreachable by
# construction and maps to a defensive usage failure rather than a crash.
def cli_parse_work(fuel: Nat, work: CliWork) -> CliResult:
  match fuel:
    case 0n:
      cli_invalid_result("internal CLI parser fuel exhaustion")
    case 1n++f:
      match work:
        case CliWArgs{args, scan}:
          cli_parse_work(f, cli_wtransition(cli_transition(args, scan)))
        case CliWTransition{transition}:
          match transition:
            case CliTEnd{scan}:
              cli_finish(scan)
            case CliTNext{args, scan}:
              cli_parse_work(f, cli_wargs(args, scan))
            case CliTError{+failure}:
              cli_invalid(failure)

def cli_parse_after_build(+rest: List<&2, List<&2, U32>>) -> CliResult:
  cli_parse_work(cli_parse_fuel(rest), cli_wargs(rest, cli_scan(Nil{}, cli_bytes_none(), False{}, False{})))

def cli_parse_command(rest: List<&2, List<&2, U32>>, +command: Bytes(), is_build: Bool) -> CliResult:
  match is_build:
    case True{}:
      cli_parse_after_build(rest)
    case False{}:
      cli_invalid_result("unknown command: " ++ HC.bytes_display(command))

def cli_parse_args(args: List<&2, List<&2, U32>>) -> CliResult:
  match args:
    case Nil{}:
      cli_invalid_result("missing command")
    case +command <> rest:
      cli_parse_command(rest, command, HC.bytes_eq(command, cli_token_build()))

# IO.args_bytes includes the invoked program as entry zero.  The product CLI
# grammar starts after it.
def cli_parse_process_args(args: List<&2, List<&2, U32>>) -> CliResult:
  match args:
    case Nil{}:
      cli_parse_args(Nil{})
    case program <> rest:
      cli_parse_args(rest)

def cli_copy_process_args(xs: List<&1, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  match xs:
    case Nil{}:
      Nil{}
    case +h <> t:
      h <> cli_copy_process_args(t)
