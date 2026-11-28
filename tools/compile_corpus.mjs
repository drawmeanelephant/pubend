#!/usr/bin/env node

import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import fsp from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { performance } from 'node:perf_hooks';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { TextDecoder } from 'node:util';

const SCRIPT_DIR = path.dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = path.resolve(SCRIPT_DIR, '..');
const DEFAULT_ARTIFACT = '/tmp/pubend-compile.mjs';
const MAX_PAGE_BYTES = 1024 * 1024;
const PAR_SEQ = 'not-implemented';
const UTF8_DECODER = new TextDecoder('utf-8', { fatal: true });
const INPUT_TREE_ERROR_CLASSES = new Set([
  'missing-content-dir',
  'non-md-file',
  'oversized-page',
  'invalid-utf8',
  'symlinked-entry',
]);

const USAGE = `Usage:
  node tools/compile_corpus.mjs build
  node tools/compile_corpus.mjs scan SITE_ROOT
  node tools/compile_corpus.mjs site SITE_ROOT [--rebuild]
  node tools/compile_corpus.mjs corpus [CORPUS_DIR] [--rebuild]
  node tools/compile_corpus.mjs negative [NEGATIVE_DIR] [--rebuild]
  node tools/compile_corpus.mjs all [CORPUS_DIR] [NEGATIVE_DIR] [--rebuild]

Artifact behavior:
  The generated compiler artifact is PUBEND_COMPILE_MJS when that environment
  variable is non-empty, otherwise /tmp/pubend-compile.mjs. A relative
  PUBEND_COMPILE_MJS is resolved against the current working directory.
  Run modes reuse the artifact when it exists and build it when it is missing.
  --rebuild forces a rebuild before running. The build command always rebuilds.
  Builds execute, without a shell and with cwd at the repository root:
    BEND_NO_TELEMETRY=1 ~/.bend/bin/bend src/compile.bend -o ARTIFACT

Input-tree behavior:
  Only SITE_ROOT/content is scanned. Files outside content/ are not part of
  compile and are ignored, so corpus manifests such as GRAPH-SHAPE.md,
  EXPECTED, and FIXTURE.synthetic.json do not contaminate inputs.
  Scanning is deterministic and oracle-compatible: in each directory, sorted
  file names are processed first, then sorted child directories are descended.
  Names are ordered by Unicode code point. Every symlinked entry under
  content/ is an input-tree error and is never followed, including symlinks
  naming files, symlinks naming directories, and dangling symlinks. Regular
  .md files become SourcePage ids by removing the final .md. Non-.md file
  entries under content/ are input-tree errors. Pages larger than 1 MiB are
  input-tree errors and are not read into the compile input. Page bytes must
  decode as UTF-8; invalid bytes are invalid-utf8 input-tree errors rather
  than lossy replacement text.

Output:
  Run modes print newline-delimited JSON objects with stable key order.
  compile_ms measures only the pure generated compile(config, pages) call.
  par_seq is always "not-implemented": pubend does not currently have separate
  parallel and sequential implementations to compare.

Commands:
  build     Build or rebuild the compiler artifact.
  scan      Scan one site and print input-tree facts; does not call compile.
  site      Scan one site, call pure compile when the input tree is valid,
            and print one site result. Exit 0 for valid, 1 for invalid content,
            2 for harness/compiler invocation errors.
  corpus    Run every direct child directory of CORPUS_DIR (default corpus),
            invoke python3 tools/check_corpus.py for each as a subprocess
            (with PYTHONDONTWRITEBYTECODE=1 so verification does not leave
            __pycache__ files in the repository), and report verdict agreement
            per positive site.
  negative  Run every fixture under NEGATIVE_DIR (default corpus-negative)
            that has an EXPECTED file. Compare coarse valid/invalid verdicts
            with direct physical-tree oracle runs. Exact diagnostic classes
            cannot be recovered from compile's None, but for fixtures whose
            EXPECTED names only input-tree classes, scanner-visible classes are
            also compared exactly. Fixtures
            with FIXTURE.synthetic.json are marked skipped-synthetic-injection:
            their physical trees are valid and their injected duplicates are
            oracle-self-test-only.
  all       Run corpus mode followed by negative mode.
`;

function compareNames(a, b) {
  const aa = Array.from(a);
  const bb = Array.from(b);
  const n = Math.min(aa.length, bb.length);
  for (let i = 0; i < n; i += 1) {
    const ac = aa[i].codePointAt(0);
    const bc = bb[i].codePointAt(0);
    if (ac !== bc) return ac - bc;
  }
  return aa.length - bb.length;
}

function uniqueSorted(values) {
  return [...new Set(values)].sort(compareNames);
}

function roundMs(ms) {
  return Math.round(ms * 1000) / 1000;
}

function artifactPath() {
  const configured = process.env.PUBEND_COMPILE_MJS;
  if (configured && configured.trim() !== '') return path.resolve(configured);
  return DEFAULT_ARTIFACT;
}

function displayPath(p) {
  const rel = path.relative(REPO_ROOT, p);
  if (rel !== '' && !rel.startsWith('..') && !path.isAbsolute(rel)) return rel;
  return p;
}

function jsonLine(obj) {
  process.stdout.write(`${JSON.stringify(obj)}\n`);
}

function parseCli(argv) {
  const positional = [];
  let rebuild = false;
  let help = false;
  for (const arg of argv) {
    if (arg === '--rebuild') rebuild = true;
    else if (arg === '--help' || arg === '-h') help = true;
    else if (arg.startsWith('--')) throw new Error(`unknown option: ${arg}`);
    else positional.push(arg);
  }
  return { positional, rebuild, help };
}

function buildArtifact(artifact) {
  const bend = path.join(os.homedir(), '.bend', 'bin', 'bend');
  const started = performance.now();
  const result = spawnSync(
    bend,
    ['src/compile.bend', '-o', artifact],
    {
      cwd: REPO_ROOT,
      env: { ...process.env, BEND_NO_TELEMETRY: '1' },
      encoding: 'utf8',
    },
  );
  const build_ms = roundMs(performance.now() - started);
  const base = {
    type: 'build',
    artifact,
    command: `BEND_NO_TELEMETRY=1 ${bend} src/compile.bend -o ${artifact}`,
    cwd: REPO_ROOT,
    build_ms,
  };
  if (result.error) {
    return {
      ...base,
      ok: false,
      error: String(result.error.message || result.error),
      stdout: result.stdout || '',
      stderr: result.stderr || '',
    };
  }
  return {
    ...base,
    ok: result.status === 0,
    exit: result.status,
    stdout: result.stdout || '',
    stderr: result.stderr || '',
  };
}

function ensureArtifact(artifact, rebuild) {
  if (!rebuild && fs.existsSync(artifact)) {
    return { type: 'artifact', artifact, built: false, ok: true };
  }
  const built = buildArtifact(artifact);
  return { type: 'artifact', artifact, built: true, ok: built.ok, build: built };
}

async function loadCompile(artifact) {
  const mod = await import(pathToFileURL(artifact).href);
  if (!mod.default || typeof mod.default.compile !== 'function') {
    throw new Error(`artifact ${artifact} does not default-export compile`);
  }
  return mod.default.compile;
}

function inputError(cls, rel, message) {
  return { class: cls, path: rel, message };
}

async function scanSite(siteRoot) {
  const root = path.resolve(siteRoot);
  const contentDir = path.join(root, 'content');
  const pages = [];
  const errors = [];
  const symlinkedEntries = [];

  let contentStat = null;
  try {
    contentStat = await fsp.stat(contentDir);
  } catch {
    contentStat = null;
  }
  if (!contentStat || !contentStat.isDirectory()) {
    errors.push(inputError('missing-content-dir', displayPath(root), 'site root has no content/ directory'));
    return { root, contentDir, inputValid: false, errors, pages, symlinkedEntries };
  }

  function classifyEntry(dirent) {
    if (dirent.isSymbolicLink()) return 'symlink';
    if (dirent.isDirectory()) return 'directory';
    return 'file-entry';
  }

  async function processFileEntry(full, rel) {
    let st = null;
    try {
      st = await fsp.lstat(full);
    } catch {
      st = null;
    }
    if (st && st.isSymbolicLink()) {
      symlinkedEntries.push(rel);
      errors.push(inputError('symlinked-entry', rel, 'symlinked entry under content/ is an input-tree error'));
      return;
    }
    if (!rel.endsWith('.md')) {
      errors.push(inputError('non-md-file', rel, 'file entry under content/ does not end in .md'));
      return;
    }
    if (!st || !st.isFile()) {
      errors.push(inputError('non-md-file', rel, '.md-named entry is not a regular file'));
      return;
    }
    if (st.size > MAX_PAGE_BYTES) {
      errors.push(inputError('oversized-page', rel, `${st.size} bytes exceeds 1 MiB ceiling`));
      return;
    }
    let raw;
    try {
      raw = await fsp.readFile(full);
    } catch (error) {
      errors.push(inputError('unreadable-file', rel, String(error.message || error)));
      return;
    }
    let body;
    try {
      body = UTF8_DECODER.decode(raw);
    } catch {
      errors.push(inputError('invalid-utf8', rel, 'page bytes are not valid UTF-8'));
      return;
    }
    pages.push({ id: rel.slice(0, -3), path: rel, bytes: st.size, body });
  }

  async function walk(dirFs, relDir) {
    let dirents;
    try {
      dirents = await fsp.readdir(dirFs, { withFileTypes: true });
    } catch (error) {
      errors.push(inputError('unreadable-directory', relDir || '.', String(error.message || error)));
      return;
    }

    const names = dirents.map((d) => d.name).sort(compareNames);
    const byName = new Map(dirents.map((d) => [d.name, d]));
    const fileNames = [];
    const dirNames = [];

    for (const name of names) {
      const dirent = byName.get(name);
      const kind = classifyEntry(dirent);
      if (kind === 'directory') dirNames.push(name);
      else if (kind === 'symlink') {
        const rel = relDir ? `${relDir}/${name}` : name;
        symlinkedEntries.push(rel);
        errors.push(inputError('symlinked-entry', rel, 'symlinked entry under content/ is an input-tree error'));
      } else fileNames.push(name);
    }

    for (const name of fileNames) {
      const rel = relDir ? `${relDir}/${name}` : name;
      await processFileEntry(path.join(dirFs, name), rel);
    }
    for (const name of dirNames) {
      const childRel = relDir ? `${relDir}/${name}` : name;
      await walk(path.join(dirFs, name), childRel);
    }
  }

  await walk(contentDir, '');
  return { root, contentDir, inputValid: errors.length === 0, errors, pages, symlinkedEntries };
}

function inputErrorClasses(scan) {
  return uniqueSorted(scan.errors.map((e) => e.class));
}

function sameClassList(a, b) {
  return a.length === b.length && a.every((value, index) => value === b[index]);
}

function scanSummary(siteRoot, scan) {
  return {
    type: 'scan',
    site: displayPath(path.resolve(siteRoot)),
    input_valid: scan.inputValid,
    input_error_classes: inputErrorClasses(scan),
    input_errors: scan.errors,
    page_count: scan.pages.length,
    page_ids: scan.pages.map((p) => p.id),
    symlinked_entries: scan.symlinkedEntries,
    par_seq: PAR_SEQ,
  };
}

function bendList(items) {
  let out = { $: 'Nil' };
  for (let i = items.length - 1; i >= 0; i -= 1) {
    out = { $: 'Con', head: items[i], tail: out };
  }
  return out;
}

function listLength(node) {
  let n = 0;
  let cur = node;
  while (cur && cur.$ === 'Con') {
    n += 1;
    cur = cur.tail;
  }
  if (!cur || cur.$ !== 'Nil') throw new Error('generated output contains a malformed List');
  return n;
}

function emittedStats(publication) {
  if (!publication || publication.$ !== 'Publication') {
    throw new Error('generated output is not a Publication constructor');
  }
  const pages = [];
  let cur = publication.pages;
  while (cur && cur.$ === 'Con') {
    pages.push(cur.head);
    cur = cur.tail;
  }
  if (!cur || cur.$ !== 'Nil') throw new Error('publication pages are a malformed List');
  let linkCount = 0;
  for (const page of pages) {
    if (!page || page.$ !== 'EmittedPage') throw new Error('publication contains a non-EmittedPage');
    linkCount += listLength(page.links);
  }
  return { emittedPageCount: pages.length, linkCount };
}

async function compileSite(siteRoot, compile) {
  const scan = await scanSite(siteRoot);
  const base = {
    type: 'site',
    site: displayPath(path.resolve(siteRoot)),
    valid: false,
    verdict: 'invalid-input-tree',
    input_valid: scan.inputValid,
    input_error_classes: inputErrorClasses(scan),
    page_count: scan.pages.length,
    emitted_page_count: null,
    link_count: null,
    compile_ms: null,
    symlinked_entry_count: scan.symlinkedEntries.length,
    par_seq: PAR_SEQ,
  };
  if (!scan.inputValid) {
    return { ...base, invalid_reason: 'input-tree-errors', input_errors: scan.errors };
  }

  const bendPages = bendList(scan.pages.map((p) => ({ $: 'SourcePage', id: p.id, body: p.body })));
  const started = performance.now();
  let result;
  try {
    result = compile({ $: 'Config' }, bendPages);
  } catch (error) {
    return {
      ...base,
      verdict: 'harness-error',
      invalid_reason: 'compile-invocation-threw',
      error: String(error && error.message ? error.message : error),
      compile_ms: roundMs(performance.now() - started),
    };
  }
  const compileMs = roundMs(performance.now() - started);

  if (!result || result.$ !== 'Some') {
    return {
      ...base,
      verdict: 'invalid-pure-compile',
      invalid_reason: 'pure-compile-returned-none',
      compile_ms: compileMs,
    };
  }

  try {
    const stats = emittedStats(result.value);
    return {
      ...base,
      valid: true,
      verdict: 'valid',
      emitted_page_count: stats.emittedPageCount,
      link_count: stats.linkCount,
      compile_ms: compileMs,
    };
  } catch (error) {
    return {
      ...base,
      verdict: 'harness-error',
      invalid_reason: 'malformed-compile-output',
      error: String(error && error.message ? error.message : error),
      compile_ms: compileMs,
    };
  }
}

function compactSiteResult(result) {
  const out = {
    valid: result.valid,
    verdict: result.verdict,
    input_error_classes: result.input_error_classes,
    page_count: result.page_count,
    emitted_page_count: result.emitted_page_count,
    link_count: result.link_count,
    compile_ms: result.compile_ms,
  };
  if (result.invalid_reason) out.invalid_reason = result.invalid_reason;
  if (result.error) out.error = result.error;
  return out;
}

function parseOracleStdout(stdout) {
  const valid = stdout.match(/^valid: .* — (\d+) pages, (\d+) internal links checked$/m);
  const invalid = stdout.match(/^invalid: .* — (\d+) violation\(s\), (\d+) class\(es\)$/m);
  const diagnosticClasses = uniqueSorted(stdout
    .split('\n')
    .map((line) => line.match(/^([a-z][a-z-]*) /))
    .filter(Boolean)
    .map((m) => m[1]));
  return {
    pages: valid ? Number(valid[1]) : null,
    internal_links: valid ? Number(valid[2]) : null,
    violations: invalid ? Number(invalid[1]) : null,
    class_count: invalid ? Number(invalid[2]) : null,
    diagnostic_classes: diagnosticClasses,
  };
}

function runOracle(siteRoot) {
  const display = displayPath(path.resolve(siteRoot));
  const result = spawnSync(
    'python3',
    ['tools/check_corpus.py', display],
    {
      cwd: REPO_ROOT,
      env: { ...process.env, PYTHONDONTWRITEBYTECODE: '1' },
      encoding: 'utf8',
    },
  );
  if (result.error) {
    return {
      command: `PYTHONDONTWRITEBYTECODE=1 python3 tools/check_corpus.py ${display}`,
      spawn_error: String(result.error.message || result.error),
      valid: false,
      exit: null,
      stdout: result.stdout || '',
      stderr: result.stderr || '',
      pages: null,
      internal_links: null,
      violations: null,
      class_count: null,
      diagnostic_classes: [],
    };
  }
  return {
    command: `PYTHONDONTWRITEBYTECODE=1 python3 tools/check_corpus.py ${display}`,
    valid: result.status === 0,
    exit: result.status,
    stdout: result.stdout || '',
    stderr: result.stderr || '',
    ...parseOracleStdout(result.stdout || ''),
  };
}

async function listChildDirectories(dir) {
  const abs = path.resolve(dir);
  const dirents = await fsp.readdir(abs, { withFileTypes: true });
  return dirents
    .filter((d) => d.isDirectory())
    .map((d) => d.name)
    .sort(compareNames)
    .map((name) => path.join(abs, name));
}

async function listNegativeFixtures(dir) {
  const children = await listChildDirectories(dir);
  const fixtures = [];
  for (const child of children) {
    if (fs.existsSync(path.join(child, 'EXPECTED'))) fixtures.push(child);
  }
  return fixtures;
}

function readExpectedClasses(fixture) {
  return fs.readFileSync(path.join(fixture, 'EXPECTED'), 'utf8')
    .split('\n')
    .map((line) => line.trim())
    .filter(Boolean)
    .sort(compareNames);
}

async function runCorpus(corpusDir, compile) {
  const sites = await listChildDirectories(corpusDir || path.join(REPO_ROOT, 'corpus'));
  let agreements = 0;
  let disagreements = 0;
  let countAgreements = 0;
  let countDisagreements = 0;

  for (const site of sites) {
    const harness = await compileSite(site, compile);
    const oracle = runOracle(site);
    const verdictAgreement = harness.valid === oracle.valid;
    const countsComparable = harness.valid && oracle.valid
      && harness.emitted_page_count !== null && harness.link_count !== null
      && oracle.pages !== null && oracle.internal_links !== null;
    const countAgreement = countsComparable
      ? harness.page_count === oracle.pages
        && harness.emitted_page_count === oracle.pages
        && harness.link_count === oracle.internal_links
      : null;
    if (verdictAgreement) agreements += 1;
    else disagreements += 1;
    if (countAgreement === true) countAgreements += 1;
    if (countAgreement === false) countDisagreements += 1;
    jsonLine({
      type: 'positive-site',
      site: displayPath(site),
      harness: compactSiteResult(harness),
      oracle,
      verdict_agreement: verdictAgreement,
      count_agreement: countAgreement,
      par_seq: PAR_SEQ,
    });
  }

  const summary = {
    type: 'positive-summary',
    corpus: displayPath(path.resolve(corpusDir || path.join(REPO_ROOT, 'corpus'))),
    total: sites.length,
    verdict_agreements: agreements,
    verdict_disagreements: disagreements,
    count_agreements: countAgreements,
    count_disagreements: countDisagreements,
    par_seq: PAR_SEQ,
  };
  jsonLine(summary);
  return { ok: disagreements === 0, summary };
}

async function runNegative(negativeDir, compile) {
  const root = negativeDir || path.join(REPO_ROOT, 'corpus-negative');
  const fixtures = await listNegativeFixtures(root);
  let compared = 0;
  let agreements = 0;
  let disagreements = 0;
  let syntheticSkipped = 0;
  let oracleExpectedMismatches = 0;
  let inputClassComparisons = 0;
  let inputClassAgreements = 0;
  let inputClassDisagreements = 0;

  for (const fixture of fixtures) {
    const expectedClasses = readExpectedClasses(fixture);
    const expectedCoarse = expectedClasses.length === 1 && expectedClasses[0] === 'valid' ? 'valid' : 'invalid';
    const synthetic = fs.existsSync(path.join(fixture, 'FIXTURE.synthetic.json'));
    const harness = await compileSite(fixture, compile);
    const oracle = runOracle(fixture);
    const oracleCoarse = oracle.valid ? 'valid' : 'invalid';
    const physicalAgreement = harness.valid === oracle.valid;
    const oracleExpectedAgreement = oracleCoarse === expectedCoarse;
    const expectedOnlyInputTree = expectedClasses.every((cls) => INPUT_TREE_ERROR_CLASSES.has(cls));
    const inputClassAgreement = !synthetic && expectedOnlyInputTree
      ? sameClassList(harness.input_error_classes, expectedClasses)
      : null;

    let comparison = 'compared-physical-oracle';
    let verdictAgreement = physicalAgreement;
    if (synthetic) {
      syntheticSkipped += 1;
      comparison = 'skipped-synthetic-injection';
      verdictAgreement = null;
    } else {
      compared += 1;
      if (physicalAgreement) agreements += 1;
      else disagreements += 1;
      if (!oracleExpectedAgreement) oracleExpectedMismatches += 1;
      if (inputClassAgreement !== null) {
        inputClassComparisons += 1;
        if (inputClassAgreement) inputClassAgreements += 1;
        else inputClassDisagreements += 1;
      }
    }

    jsonLine({
      type: 'negative-site',
      site: displayPath(fixture),
      expected_classes: expectedClasses,
      expected_coarse: expectedCoarse,
      synthetic,
      comparison,
      harness: compactSiteResult(harness),
      oracle_physical: oracle,
      oracle_coarse: oracleCoarse,
      physical_verdict_agreement: physicalAgreement,
      verdict_agreement: verdictAgreement,
      oracle_expected_agreement: oracleExpectedAgreement,
      input_class_agreement: inputClassAgreement,
      note: synthetic
        ? 'FIXTURE.synthetic.json is consumed only by oracle self-test injection; this physical-tree run cannot express the duplicate-id fixture.'
        : null,
      par_seq: PAR_SEQ,
    });
  }

  const summary = {
    type: 'negative-summary',
    fixtures_dir: displayPath(path.resolve(root)),
    total: fixtures.length,
    compared_physical: compared,
    synthetic_skipped: syntheticSkipped,
    verdict_agreements: agreements,
    verdict_disagreements: disagreements,
    oracle_expected_mismatches_nonsynthetic: oracleExpectedMismatches,
    input_class_comparisons: inputClassComparisons,
    input_class_agreements: inputClassAgreements,
    input_class_disagreements: inputClassDisagreements,
    comparison_level: 'coarse-valid-invalid-plus-exact-input-tree-classes-when-scanner-visible',
    par_seq: PAR_SEQ,
  };
  jsonLine(summary);
  return {
    ok: disagreements === 0 && oracleExpectedMismatches === 0 && inputClassDisagreements === 0,
    summary,
  };
}

async function prepareCompile(rebuild) {
  const artifact = artifactPath();
  const artifactResult = ensureArtifact(artifact, rebuild);
  if (!artifactResult.ok) {
    if (artifactResult.build) jsonLine(artifactResult.build);
    return { ok: false, artifact, artifactResult };
  }
  try {
    const compile = await loadCompile(artifact);
    return { ok: true, artifact, artifactResult, compile };
  } catch (error) {
    return {
      ok: false,
      artifact,
      artifactResult,
      error: String(error && error.message ? error.message : error),
    };
  }
}

async function main() {
  const cli = parseCli(process.argv.slice(2));
  const [command, ...args] = cli.positional;
  if (cli.help || !command) {
    process.stdout.write(USAGE);
    return 0;
  }

  if (command === 'build') {
    if (args.length !== 0) throw new Error('build takes no positional arguments');
    const result = buildArtifact(artifactPath());
    jsonLine(result);
    return result.ok ? 0 : 2;
  }

  if (command === 'scan') {
    if (args.length !== 1) throw new Error('scan requires exactly one SITE_ROOT');
    const scan = await scanSite(args[0]);
    jsonLine(scanSummary(args[0], scan));
    return scan.inputValid ? 0 : 1;
  }

  if (command === 'site') {
    if (args.length !== 1) throw new Error('site requires exactly one SITE_ROOT');
    const prepared = await prepareCompile(cli.rebuild);
    if (!prepared.ok) {
      jsonLine({ type: 'harness-error', artifact: prepared.artifact, error: prepared.error || 'artifact build failed' });
      return 2;
    }
    const result = await compileSite(args[0], prepared.compile);
    jsonLine(result);
    if (result.verdict === 'harness-error') return 2;
    return result.valid ? 0 : 1;
  }

  if (command === 'corpus' || command === 'negative' || command === 'all') {
    const maxArgs = command === 'all' ? 2 : 1;
    if (args.length > maxArgs) throw new Error(`${command} takes at most ${maxArgs} positional argument(s)`);
    const prepared = await prepareCompile(cli.rebuild);
    if (!prepared.ok) {
      jsonLine({ type: 'harness-error', artifact: prepared.artifact, error: prepared.error || 'artifact build failed' });
      return 2;
    }
    if (command === 'corpus') {
      const result = await runCorpus(args[0], prepared.compile);
      return result.ok ? 0 : 1;
    }
    if (command === 'negative') {
      const result = await runNegative(args[0], prepared.compile);
      return result.ok ? 0 : 1;
    }
    const positive = await runCorpus(args[0], prepared.compile);
    const negative = await runNegative(args[1], prepared.compile);
    return positive.ok && negative.ok ? 0 : 1;
  }

  throw new Error(`unknown command: ${command}`);
}

main().then((code) => {
  process.exitCode = code;
}).catch((error) => {
  jsonLine({ type: 'harness-error', error: String(error && error.message ? error.message : error) });
  process.stderr.write(`${USAGE}\n`);
  process.exitCode = 2;
});
