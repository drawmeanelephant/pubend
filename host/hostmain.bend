import Base
import ./HostCommon.bend as HC
import ./HostFS.bend as HFS
import ./HostCli.bend as CLI
import ./HostResolve.bend as HR
import ./HostScan.bend as HS
import ./HostPublish.bend as HPub
import ./HostCompileDiag.bend as HD
import ../src/compile.bend as C
import ../src/model.bend as Model

# Native publication host entrypoint.  This module owns only orchestration:
# command-line bytes → site/output resolution → input scan → in-process pure
# compile_report → publication.  Publication preflight, including the dynamic
# output-filesystem case probe and collision refusal, lives in HostPublish.
# @unsafe is intentional accepted orchestration glue for Bend 2.0.40's affine
# and match checker; the pure compiler remains pure and all syscalls remain in
# the HostFS effect layer.

def Bytes() -> Data:
  List<&2, U32>

@unsafe def host_env_failure(+message: String) -> HC.HostFailure:
  HC.host_failure_one(3, HC.host_diag_simple(HC.DHostError{}, message))

@unsafe def fail_now(+failure: HC.HostFailure) -> IO(Unit):
  HC.write_failure(failure)

@unsafe def finish_publish_result(r: HC.HRes(Unit)) -> IO(Unit):
  match r:
    case Done{value}:
      IO.pure(Unit, Unit{})
    case Fail{+failure}:
      HC.write_failure(failure)

@unsafe def publish_compiled(+containment_root: Bytes(), +out: Bytes(), +publication: Model.Publication) -> IO(Unit):
  IO.bind(HC.HRes(Unit), Unit,
    HPub.publish_publication(containment_root, containment_root, out, publication),
    finish_publish_result)

@unsafe def compile_finish(+containment_root: Bytes(), +out: Bytes(), r: C.CompileResult) -> IO(Unit):
  match r:
    case C.CompileErr{+diagnostics}:
      HC.write_failure(HD.compile_failure(diagnostics))
    case C.CompileOk{+publication}:
      publish_compiled(containment_root, out, publication)

@unsafe def scan_failure_with_errors(+containment_root: Bytes(), +out: Bytes(), st: HS.ScanState,
  errs: List<&2, HC.HostDiag> & List<&2, HC.HostDiag>) -> IO(Unit):
  (+input_errors, +host_errors) = errs
  scan_error_gate(containment_root, out, st, input_errors, host_errors,
    List.is_empty(&2, HC.HostDiag, host_errors),
    List.is_empty(&2, HC.HostDiag, input_errors))

@unsafe def scan_failure_or_compile(+containment_root: Bytes(), +out: Bytes(), +st: HS.ScanState) -> IO(Unit):
  scan_failure_with_errors(containment_root, out, st, HS.state_errors(st))

@unsafe def scan_error_gate(+containment_root: Bytes(), +out: Bytes(), st: HS.ScanState,
  +input_errors: List<&2, HC.HostDiag>, +host_errors: List<&2, HC.HostDiag>,
  nohost: Bool, noinput: Bool) -> IO(Unit):
  match nohost:
    case False{}:
      HC.write_failure(HC.host_failure(3, host_errors))
    case True{}:
      scan_input_gate(containment_root, out, st, input_errors, noinput)

@unsafe def scan_input_gate(+containment_root: Bytes(), +out: Bytes(), st: HS.ScanState,
  +input_errors: List<&2, HC.HostDiag>, noinput: Bool) -> IO(Unit):
  match noinput:
    case False{}:
      HC.write_failure(HC.host_failure(1, input_errors))
    case True{}:
      compile_finish(containment_root, out, C.compile_report(Model.Config{}, HS.state_pages(st)))

@unsafe def after_output_resolution(+content: Bytes(), r: HC.HRes(HR.OutputPaths)) -> IO(Unit):
  match r:
    case Done{+opaths}:
      match opaths:
        case HR.OutputPaths{+canonical_out, +content_dir, +containment_root}:
          IO.bind(HS.ScanState, Unit, HS.scan_site(content_dir),
            st => scan_failure_or_compile(containment_root, canonical_out, st))
    case Fail{+failure}:
      HC.write_failure(failure)

@unsafe def after_site_resolution(+cwd: Bytes(), out_arg: Maybe<&2, List<&2, U32>>, r: HC.HRes(HR.SitePaths)) -> IO(Unit):
  match r:
    case Done{+sp}:
      match sp:
        case HR.SitePaths{+root, +real_root}:
          IO.bind(HC.HRes(HR.OutputPaths), Unit,
            HR.resolve_output_path(cwd, root, real_root, out_arg),
            r2 => after_output_resolution(root, r2))
    case Fail{+failure}:
      HC.write_failure(failure)

@unsafe def start_valid_cli(+cwd: Bytes(), cli: CLI.CliConfig) -> IO(Unit):
  match cli:
    case CLI.CliConfig{+dir_arg, +out_arg}:
      IO.bind(HC.HRes(HR.SitePaths), Unit, HR.resolve_site_paths(cwd, dir_arg),
        r => after_site_resolution(cwd, out_arg, r))

@unsafe def cwd_finish(cli: CLI.CliConfig, r: HC.HBytesResult()) -> IO(Unit):
  match r:
    case Done{+cwd}:
      start_valid_cli(cwd, cli)
    case Fail{error}:
      (+code, +message) = error
      HC.write_failure(host_env_failure("cannot determine current working directory: " ++ HC.io_error_text((code, message))))

@unsafe def run_cli(cli: CLI.CliConfig) -> IO(Unit):
  IO.bind(HC.HBytesResult(), Unit, HFS.realpath(HC.ascii_bytes(".")), r => cwd_finish(cli, r))

@unsafe def cli_finish(r: CLI.CliResult) -> IO(Unit):
  match r:
    case CLI.CliInvalid{+failure}:
      HC.write_failure(failure)
    case CLI.CliParsed{+config}:
      run_cli(config)

@unsafe def main() -> IO(Unit):
  IO.bind(List<List<&2, U32>>, Unit, IO.args_bytes(),
    args => cli_finish(CLI.cli_parse_process_args(CLI.cli_copy_process_args(args))))
