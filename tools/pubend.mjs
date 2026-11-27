#!/usr/bin/env node

// pubend v0 product CLI host shell.
//
// Interface:
//   node tools/pubend.mjs build DIR [--out OUT]
//
// Output-path rule: the default output is DIR/dist. A relative --out resolves
// against DIR; an absolute --out is accepted only when its canonical form
// remains inside the canonical site root. The output must not be the canonical
// site root, content, or a descendant of content.
//
// Compiler artifact: every invocation rebuilds src/compile.bend without a
// shell as
//   BEND_NO_TELEMETRY=1 ~/.bend/bin/bend src/compile.bend -o ARTIFACT
// The default ARTIFACT is a unique per-invocation file in os.tmpdir() and is removed
// after loading. A non-empty PUBEND_COMPILE_MJS selects the artifact path
// instead; that path is still rebuilt on every invocation, never silently
// reused as a stale cache.
//
// Failure diagnostics: failures write one UTF-8 JSON object plus one newline
// to stderr. Top-level key order is version,status,diagnostics; version is 1
// and status is "error". Every diagnostic uses key order
// class,path,page,line,column,target,span,message. Unavailable scalar fields
// are null. span is null or {start,end} containing engine-normalized UTF-8
// offsets. Content entry paths are content-root-relative forward-slash paths;
// host filesystem paths in usage/host diagnostics are absolute. target is the
// engine-normalized link target for link diagnostics and the other involved
// page id for graph diagnostics. Successful builds write nothing to stdout or
// stderr.
//
// Additional diagnostic classes not present in the corpus oracle are usage-error,
// output-outside-site, output-forbidden, input-io, compiler-artifact-build,
// compiler-artifact-invalid, compiler-invocation, output-symlink,
// output-not-directory, output-parent-not-directory, output-containment,
// output-path-collision, output-lock-exists, output-stage-invalid,
// output-backup-conflict, output-backup-invalid, output-io,
// output-publication, and host-error.

import { spawnSync } from 'node:child_process';
import crypto from 'node:crypto';
import fsp from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { TextDecoder } from 'node:util';

const SCRIPT_DIR = path.dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = path.resolve(SCRIPT_DIR, '..');
const MAX_PAGE_BYTES = 1024 * 1024;
const UTF8_DECODER = new TextDecoder('utf-8', { fatal: true });
const USAGE = 'usage: node tools/pubend.mjs build DIR [--out OUT]';
const PUBLICATION_SUFFIXES = Object.freeze([
  '.pubend-lock',
  '.pubend-stage',
  '.pubend-previous',
]);
const STAGE_OWNER_MARKER = '.pubend-incomplete-stage';
const BACKUP_OWNER_MARKER = '.pubend-backup-owner';
const STAGE_OWNER_MARKER_BYTES = Buffer.from('pubend incomplete stage owner v1\n', 'utf8');
const BACKUP_OWNER_MARKER_BYTES = Buffer.from('pubend backup owner v1\n', 'utf8');
const HOST_FIXED_OUTPUT_FILES = Object.freeze([
  '_pubend/manifest.json',
  STAGE_OWNER_MARKER,
  BACKUP_OWNER_MARKER,
]);

class CliFailure extends Error {
  constructor(exitCode, diagnostics) {
    super(diagnostics[0]?.message || 'pubend failure');
    this.name = 'CliFailure';
    this.exitCode = exitCode;
    this.diagnostics = diagnostics;
  }
}

function diagnostic(cls, {
  path: diagPath = null,
  page = null,
  line = null,
  column = null,
  target = null,
  span = null,
  message = '',
} = {}) {
  return {
    class: cls,
    path: diagPath,
    page,
    line,
    column,
    target,
    span,
    message,
  };
}

function oneFailure(exitCode, cls, fields) {
  return new CliFailure(exitCode, [diagnostic(cls, fields)]);
}

function errorMessage(error) {
  return String(error && error.message ? error.message : error);
}

function errorCode(error) {
  return error && typeof error === 'object' ? error.code : undefined;
}

function isCliFailure(error) {
  return error instanceof CliFailure;
}

function usageFailure(message) {
  throw oneFailure(2, 'usage-error', {
    message: `${message}; ${USAGE}`,
  });
}

function hostFailure(cls, pathValue, message) {
  throw oneFailure(3, cls, {
    path: pathValue,
    message,
  });
}

function outputFailure(cls, pathValue, message) {
  hostFailure(cls, pathValue, message);
}

function artifactInvalid(message, artifact = null) {
  throw oneFailure(3, 'compiler-artifact-invalid', {
    path: artifact,
    message,
  });
}

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

function pathEscape(relativePath) {
  return relativePath === '..'
    || relativePath.startsWith(`..${path.sep}`)
    || path.isAbsolute(relativePath);
}

function isStrictlyInside(child, parent) {
  const rel = path.relative(parent, child);
  return rel !== '' && !pathEscape(rel);
}

function isInsideOrEqual(child, parent) {
  const rel = path.relative(parent, child);
  return rel === '' || !pathEscape(rel);
}

async function canonicalizeNearestExisting(pathValue) {
  const resolved = path.resolve(pathValue);
  const missing = [];
  let cur = resolved;

  for (;;) {
    try {
      const realAncestor = await fsp.realpath(cur);
      return {
        path: missing.length === 0 ? realAncestor : path.join(realAncestor, ...missing),
      };
    } catch (error) {
      if (errorCode(error) !== 'ENOENT' && errorCode(error) !== 'ENOTDIR') throw error;
      const parent = path.dirname(cur);
      if (parent === cur) throw error;
      missing.unshift(path.basename(cur));
      cur = parent;
    }
  }
}

async function canonicalizeNearestForOutput(pathValue) {
  try {
    return await canonicalizeNearestExisting(pathValue);
  } catch (error) {
    outputFailure('output-io', pathValue, `cannot canonicalize output path: ${errorMessage(error)}`);
  }
  return null;
}

async function canonicalizeNearestForInput(pathValue) {
  try {
    return await canonicalizeNearestExisting(pathValue);
  } catch (error) {
    throw oneFailure(3, 'input-io', {
      path: pathValue,
      message: `cannot canonicalize input path: ${errorMessage(error)}`,
    });
  }
  return null;
}

function hasReservedPublicationFinalComponent(out) {
  const base = path.basename(out);
  return PUBLICATION_SUFFIXES.some((suffix) => (
    base.length >= suffix.length
    && base.slice(base.length - suffix.length).toLowerCase() === suffix
  ));
}

function parseCli(argv) {
  if (argv.length === 0) usageFailure('missing command');
  if (argv[0] !== 'build') usageFailure(`unknown command: ${argv[0]}`);

  const positional = [];
  let outArg = null;
  let sawOut = false;
  let endOfOptions = false;

  for (let i = 1; i < argv.length; i += 1) {
    const arg = argv[i];
    if (!endOfOptions && arg === '--') {
      endOfOptions = true;
    } else if (!endOfOptions && arg === '--out') {
      if (sawOut) usageFailure('duplicate --out option');
      if (i + 1 >= argv.length) usageFailure('--out requires a value');
      sawOut = true;
      outArg = argv[i + 1];
      i += 1;
    } else if (!endOfOptions && arg.startsWith('--')) {
      usageFailure(`unknown option: ${arg}`);
    } else {
      positional.push(arg);
    }
  }

  if (positional.length !== 1) {
    usageFailure(`build requires exactly one DIR, got ${positional.length}`);
  }
  return { dirArg: positional[0], outArg };
}

async function resolveSitePaths(dirArg) {
  const root = path.resolve(dirArg);
  try {
    const realRoot = await fsp.realpath(root);
    return { root, realRoot };
  } catch (error) {
    if (errorCode(error) === 'ENOENT' || errorCode(error) === 'ENOTDIR') {
      const canonical = await canonicalizeNearestForInput(root);
      return { root, realRoot: canonical.path };
    }
    throw oneFailure(3, 'input-io', {
      path: root,
      message: `cannot resolve site root: ${errorMessage(error)}`,
    });
  }
}

async function rejectSymlinkedOutputPath(out) {
  let st = null;
  try {
    st = await fsp.lstat(out);
  } catch (error) {
    if (errorCode(error) === 'ENOENT' || errorCode(error) === 'ENOTDIR') return;
    outputFailure('output-io', out, `cannot inspect output path: ${errorMessage(error)}`);
  }
  if (st && st.isSymbolicLink()) {
    outputFailure('output-symlink', out, 'symlinked pre-existing output path is a host failure');
  }
}

async function resolveOutputPath(siteRoot, siteRealRoot, outArg) {
  const requestedOut = outArg === null
    ? path.join(siteRoot, 'dist')
    : path.isAbsolute(outArg)
      ? path.resolve(outArg)
      : path.resolve(siteRoot, outArg);
  const contentDir = path.join(siteRoot, 'content');
  const canonicalRoot = path.resolve(siteRealRoot);

  if (hasReservedPublicationFinalComponent(requestedOut)) {
    throw oneFailure(2, 'output-forbidden', {
      path: requestedOut,
      message: 'output directory final component is reserved publication namespace',
    });
  }

  await rejectSymlinkedOutputPath(requestedOut);
  const canonicalOutInfo = await canonicalizeNearestForOutput(requestedOut);
  const canonicalContentInfo = await canonicalizeNearestForInput(contentDir);
  const canonicalOut = canonicalOutInfo.path;
  const canonicalContent = canonicalContentInfo.path;

  if (canonicalOut === canonicalRoot) {
    throw oneFailure(2, 'output-forbidden', {
      path: canonicalOut,
      message: 'output directory must not be the site root',
    });
  }
  if (!isStrictlyInside(canonicalOut, canonicalRoot)) {
    throw oneFailure(2, 'output-outside-site', {
      path: canonicalOut,
      message: 'output directory must remain inside the canonical site root',
    });
  }
  if (canonicalOut === canonicalContent || isStrictlyInside(canonicalOut, canonicalContent)) {
    throw oneFailure(2, 'output-forbidden', {
      path: canonicalOut,
      message: 'output directory must not be content/ or a descendant of content/',
    });
  }
  return {
    out: canonicalOut,
    contentDir,
    containmentRoot: canonicalRoot,
  };
}

function inputDiagnostic(cls, rel, message) {
  return diagnostic(cls, { path: rel, message });
}

function hostInputDiagnostic(fullPath, error, action) {
  return diagnostic('input-io', {
    path: fullPath,
    message: `${action}: ${errorMessage(error)}`,
  });
}

async function scanSite(contentDir) {
  const pages = [];
  const inputErrors = [];
  const hostErrors = [];

  let contentStat = null;
  try {
    contentStat = await fsp.lstat(contentDir);
  } catch (error) {
    if (errorCode(error) === 'ENOENT' || errorCode(error) === 'ENOTDIR') {
      inputErrors.push(inputDiagnostic('missing-content-dir', 'content', 'site root has no content/ directory'));
    } else {
      hostErrors.push(hostInputDiagnostic(contentDir, error, 'cannot inspect content directory'));
    }
    return { pages, inputErrors, hostErrors };
  }

  if (contentStat.isSymbolicLink()) {
    inputErrors.push(inputDiagnostic('symlinked-entry', 'content', 'content/ is symlinked; symlinks are never followed'));
    return { pages, inputErrors, hostErrors };
  }
  if (!contentStat.isDirectory()) {
    inputErrors.push(inputDiagnostic('missing-content-dir', 'content', 'site root has no content/ directory'));
    return { pages, inputErrors, hostErrors };
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
    } catch (error) {
      hostErrors.push(hostInputDiagnostic(full, error, 'cannot inspect content entry'));
      return;
    }
    if (st.isSymbolicLink()) {
      inputErrors.push(inputDiagnostic('symlinked-entry', rel, 'symlinked entry under content/ is an input-tree error'));
      return;
    }
    if (!rel.endsWith('.md')) {
      inputErrors.push(inputDiagnostic('non-md-file', rel, 'file entry under content/ does not end in .md'));
      return;
    }
    if (!st.isFile()) {
      inputErrors.push(inputDiagnostic('non-md-file', rel, '.md-named entry is not a regular file'));
      return;
    }
    if (st.size > MAX_PAGE_BYTES) {
      inputErrors.push(inputDiagnostic('oversized-page', rel, `${st.size} bytes exceeds 1 MiB ceiling`));
      return;
    }

    let raw;
    try {
      raw = await fsp.readFile(full);
    } catch (error) {
      hostErrors.push(hostInputDiagnostic(full, error, 'cannot read page'));
      return;
    }
    if (raw.byteLength > MAX_PAGE_BYTES) {
      inputErrors.push(inputDiagnostic('oversized-page', rel, `${raw.byteLength} bytes exceeds 1 MiB ceiling`));
      return;
    }

    let body;
    try {
      body = UTF8_DECODER.decode(raw);
    } catch {
      inputErrors.push(inputDiagnostic('invalid-utf8', rel, 'page bytes are not valid UTF-8'));
      return;
    }
    pages.push({ id: rel.slice(0, -3), path: rel, bytes: raw.byteLength, body });
  }

  async function walk(dirFs, relDir) {
    let dirents;
    try {
      dirents = await fsp.readdir(dirFs, { withFileTypes: true });
    } catch (error) {
      hostErrors.push(hostInputDiagnostic(dirFs, error, 'cannot read content directory'));
      return;
    }

    const names = dirents.map((d) => d.name).sort(compareNames);
    const byName = new Map(dirents.map((d) => [d.name, d]));
    const fileNames = [];
    const dirNames = [];

    for (const name of names) {
      const dirent = byName.get(name);
      const kind = classifyEntry(dirent);
      const rel = relDir ? `${relDir}/${name}` : name;
      if (kind === 'directory') {
        dirNames.push(name);
      } else if (kind === 'symlink') {
        inputErrors.push(inputDiagnostic('symlinked-entry', rel, 'symlinked entry under content/ is an input-tree error'));
      } else {
        fileNames.push(name);
      }
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
  return { pages, inputErrors, hostErrors };
}

function artifactPath() {
  const configured = process.env.PUBEND_COMPILE_MJS;
  if (configured && configured.trim() !== '') return path.resolve(configured);
  return path.join(os.tmpdir(), `pubend-compile-${process.pid}-${crypto.randomUUID()}.mjs`);
}

function usingDefaultArtifact() {
  const configured = process.env.PUBEND_COMPILE_MJS;
  return !configured || configured.trim() === '';
}

function processOutputSummary(result) {
  const stderr = (result.stderr || '').trim();
  const stdout = (result.stdout || '').trim();
  if (stderr && stdout) return `stderr: ${stderr}; stdout: ${stdout}`;
  if (stderr) return `stderr: ${stderr}`;
  if (stdout) return `stdout: ${stdout}`;
  return 'no compiler output';
}

async function buildArtifact(artifact) {
  const bend = path.join(os.homedir(), '.bend', 'bin', 'bend');
  const result = spawnSync(
    bend,
    ['src/compile.bend', '-o', artifact],
    {
      cwd: REPO_ROOT,
      env: { ...process.env, BEND_NO_TELEMETRY: '1' },
      encoding: 'utf8',
      shell: false,
    },
  );
  if (result.error) {
    throw oneFailure(3, 'compiler-artifact-build', {
      path: artifact,
      message: `compiler artifact build could not start: ${errorMessage(result.error)}`,
    });
  }
  if (result.status !== 0) {
    const status = result.status === null ? `signal ${result.signal}` : `exit ${result.status}`;
    throw oneFailure(3, 'compiler-artifact-build', {
      path: artifact,
      message: `compiler artifact build failed with ${status}: ${processOutputSummary(result)}`,
    });
  }

  try {
    const st = await fsp.lstat(artifact);
    if (!st.isFile()) artifactInvalid('compiler artifact path is not a regular file', artifact);
  } catch (error) {
    if (isCliFailure(error)) throw error;
    throw oneFailure(3, 'compiler-artifact-build', {
      path: artifact,
      message: `compiler artifact was not written: ${errorMessage(error)}`,
    });
  }
}

async function loadCompileReport(artifact) {
  let mod;
  try {
    mod = await import(pathToFileURL(artifact).href);
  } catch (error) {
    artifactInvalid(`compiler artifact could not be imported: ${errorMessage(error)}`, artifact);
  }
  if (!mod.default || typeof mod.default.compile_report !== 'function') {
    artifactInvalid('compiler artifact does not default-export compile_report', artifact);
  }
  return mod.default.compile_report;
}

async function prepareCompileReport() {
  const artifact = artifactPath();
  const cleanup = usingDefaultArtifact();
  try {
    await buildArtifact(artifact);
    const compileReport = await loadCompileReport(artifact);
    return { artifact, compileReport };
  } finally {
    if (cleanup) {
      try {
        await fsp.rm(artifact, { force: true });
      } catch {
        // Artifact cleanup is best-effort host glue and must not hide diagnostics.
      }
    }
  }
}

function bendList(items) {
  let out = { $: 'Nil' };
  for (let i = items.length - 1; i >= 0; i -= 1) {
    out = { $: 'Con', head: items[i], tail: out };
  }
  return out;
}

function decodeList(node, context, artifact = null) {
  const out = [];
  let cur = node;
  while (cur && cur.$ === 'Con') {
    out.push(cur.head);
    cur = cur.tail;
  }
  if (!cur || cur.$ !== 'Nil') artifactInvalid(`${context} is a malformed List`, artifact);
  return out;
}

function decodeMaybe(node, context, artifact = null) {
  if (node && node.$ === 'None') return null;
  if (node && node.$ === 'Some') return node.value;
  artifactInvalid(`${context} is a malformed Maybe`, artifact);
  return null;
}

function expectString(value, context, artifact = null) {
  if (typeof value !== 'string') artifactInvalid(`${context} is not a String`, artifact);
  return value;
}

function expectOffset(value, context, artifact = null) {
  if (!Number.isInteger(value) || value < 0) artifactInvalid(`${context} is not a non-negative integer`, artifact);
  return value;
}

function decodePublication(publication, artifact) {
  if (!publication || publication.$ !== 'Publication') {
    artifactInvalid('CompileOk does not contain a Publication constructor', artifact);
  }
  const pageNodes = decodeList(publication.pages, 'Publication.pages', artifact);
  return pageNodes.map((page, index) => {
    if (!page || page.$ !== 'EmittedPage') {
      artifactInvalid(`Publication page ${index} is not an EmittedPage constructor`, artifact);
    }
    const id = expectString(page.id, `Publication page ${index} id`, artifact);
    const html = expectString(page.html, `Publication page ${index} html`, artifact);
    const links = decodeList(page.links, `Publication page ${index} links`, artifact)
      .map((link, linkIndex) => expectString(link, `Publication page ${index} link ${linkIndex}`, artifact));
    return { id, html, links };
  });
}

function pageSourcePath(page) {
  return `${page}.md`;
}

function decodeFrontmatterDiagnostic(node, artifact) {
  const page = expectString(node.page, 'CDFrontmatter.page', artifact);
  const error = node.error;
  if (!error || error.$ !== 'FmError') artifactInvalid('CDFrontmatter.error is not an FmError constructor', artifact);
  const kind = error.kind && error.kind.$;
  const classes = {
    FmMalformed: 'malformed-frontmatter',
    FmUnknownKey: 'unknown-frontmatter-key',
    FmDupKey: 'duplicate-frontmatter-key',
    FmBadStatus: 'malformed-frontmatter',
    FmEmptyValue: 'malformed-frontmatter',
  };
  if (!classes[kind]) artifactInvalid(`unknown frontmatter diagnostic constructor ${kind}`, artifact);
  const line = expectOffset(error.line, 'FmError.line', artifact);
  const column = expectOffset(error.col, 'FmError.col', artifact);
  const detail = expectString(error.detail, 'FmError.detail', artifact);
  return diagnostic(classes[kind], {
    path: pageSourcePath(page),
    page,
    line,
    column,
    message: `frontmatter diagnostic ${kind}: ${detail}`,
  });
}

function decodeGraphDiagnostic(node, artifact) {
  const error = node.error;
  if (!error || error.$ !== 'Diag') artifactInvalid('CDGraph.error is not a Diag constructor', artifact);
  const kind = error.kind && error.kind.$;
  const classes = {
    DDupId: 'duplicate-id',
    DDupIdCase: 'duplicate-id-case',
    DDangling: 'dangling-parent',
    DSelfParent: 'self-parent',
    DCycle: 'parent-cycle',
  };
  if (!classes[kind]) artifactInvalid(`unknown graph diagnostic constructor ${kind}`, artifact);
  const page = expectString(error.id, 'Diag.id', artifact);
  const other = decodeMaybe(error.other, 'Diag.other', artifact);
  if (other !== null) expectString(other, 'Diag.other value', artifact);
  const suffix = other === null ? '' : `; other page id: ${other}`;
  return diagnostic(classes[kind], {
    path: pageSourcePath(page),
    page,
    target: other,
    message: `graph diagnostic ${kind}${suffix}`,
  });
}

function decodeSpan(spanNode, artifact) {
  if (!spanNode || spanNode.$ !== 'Span') artifactInvalid('LinkError.span value is not a Span constructor', artifact);
  return {
    start: expectOffset(spanNode.start, 'Span.start', artifact),
    end: expectOffset(spanNode.end, 'Span.end', artifact),
  };
}

function decodeLinkDiagnostic(node, artifact) {
  const error = node.error;
  if (!error || error.$ !== 'LinkError') artifactInvalid('CDLink.error is not a LinkError constructor', artifact);
  const kind = error.kind && error.kind.$;
  const classes = {
    LErrQuery: 'link-query',
    LErrEscape: 'link-root-escape',
    LErrDangling: 'link-nonexistent-page',
    LErrMalformedPercent: 'link-malformed-percent',
    LErrInvalidPercentUtf8: 'link-invalid-percent-utf8',
  };
  if (!classes[kind]) artifactInvalid(`unknown link diagnostic constructor ${kind}`, artifact);
  const page = expectString(error.source, 'LinkError.source', artifact);
  const target = expectString(error.target, 'LinkError.target', artifact);
  const spanValue = decodeMaybe(error.span, 'LinkError.span', artifact);
  const span = spanValue === null ? null : decodeSpan(spanValue, artifact);
  const linkKindValue = decodeMaybe(error.link_kind, 'LinkError.link_kind', artifact);
  let linkKind = 'unavailable';
  if (linkKindValue !== null) {
    const kinds = new Set(['DocumentLinkInline', 'DocumentLinkAutolink', 'DocumentLinkImage']);
    if (!linkKindValue || !kinds.has(linkKindValue.$)) {
      artifactInvalid('LinkError.link_kind value is not a DocumentLinkKind constructor', artifact);
    }
    linkKind = linkKindValue.$;
  }
  return diagnostic(classes[kind], {
    path: pageSourcePath(page),
    page,
    target,
    span,
    message: `link diagnostic ${kind}; target-bearing node kind ${linkKind}`,
  });
}

function decodeCompileDiagnostic(node, artifact) {
  if (!node || typeof node !== 'object') artifactInvalid('CompileErr contains a non-object diagnostic', artifact);
  if (node.$ === 'CDFrontmatter') return decodeFrontmatterDiagnostic(node, artifact);
  if (node.$ === 'CDGraph') return decodeGraphDiagnostic(node, artifact);
  if (node.$ === 'CDLink') return decodeLinkDiagnostic(node, artifact);
  artifactInvalid(`unknown CompileDiagnostic constructor ${node.$}`, artifact);
  return null;
}

function decodeCompileResult(result, artifact) {
  if (!result || typeof result !== 'object') {
    artifactInvalid('compile_report did not return a constructor object', artifact);
  }
  if (result.$ === 'CompileErr') {
    const diagnostics = decodeList(result.diagnostics, 'CompileErr.diagnostics', artifact)
      .map((node) => decodeCompileDiagnostic(node, artifact));
    if (diagnostics.length === 0) {
      artifactInvalid('compile_report returned CompileErr with no diagnostics', artifact);
    }
    return { ok: false, diagnostics };
  }
  if (result.$ === 'CompileOk') {
    return { ok: true, pages: decodePublication(result.publication, artifact) };
  }
  artifactInvalid(`compile_report returned unknown constructor ${result.$}`, artifact);
  return null;
}

function invokeCompileReport(compileReport, pages, artifact) {
  const bendPages = bendList(pages.map((p) => ({ $: 'SourcePage', id: p.id, body: p.body })));
  let result;
  try {
    result = compileReport({ $: 'Config' }, bendPages);
  } catch (error) {
    throw oneFailure(3, 'compiler-invocation', {
      path: artifact,
      message: `compile_report invocation threw: ${errorMessage(error)}`,
    });
  }
  return decodeCompileResult(result, artifact);
}

async function lstatOrNull(fullPath) {
  try {
    return await fsp.lstat(fullPath);
  } catch (error) {
    if (errorCode(error) === 'ENOENT' || errorCode(error) === 'ENOTDIR') return null;
    throw error;
  }
}

async function lstatForPublication(fullPath) {
  try {
    return await lstatOrNull(fullPath);
  } catch (error) {
    outputFailure('output-io', fullPath, `cannot inspect publication path: ${errorMessage(error)}`);
  }
}

async function validateOutputComponents(siteRoot, out) {
  const rel = path.relative(siteRoot, out);
  if (rel === '' || pathEscape(rel)) {
    outputFailure('output-containment', out, 'output path escaped its validated containment boundary');
  }
  const segments = rel.split(path.sep);
  let cur = siteRoot;
  for (let i = 0; i < segments.length; i += 1) {
    cur = path.join(cur, segments[i]);
    const last = i === segments.length - 1;
    let st;
    try {
      st = await fsp.lstat(cur);
    } catch (error) {
      if (errorCode(error) === 'ENOENT' || errorCode(error) === 'ENOTDIR') break;
      outputFailure('output-io', cur, `cannot inspect output path component: ${errorMessage(error)}`);
    }
    if (st.isSymbolicLink()) {
      outputFailure('output-symlink', cur, 'symlinked output path component is a host failure');
    }
    if (last && !st.isDirectory()) {
      outputFailure('output-not-directory', cur, 'pre-existing output path is not a directory');
    }
    if (!last && !st.isDirectory()) {
      outputFailure('output-parent-not-directory', cur, 'output path parent component is not a directory');
    }
  }
}

async function prepareOutputParent(containmentRoot, canonicalRoot, out) {
  await validateOutputComponents(containmentRoot, out);
  const parent = path.dirname(out);
  try {
    await fsp.mkdir(parent, { recursive: true });
  } catch (error) {
    outputFailure('output-io', parent, `cannot create output parent directory: ${errorMessage(error)}`);
  }

  let realParent;
  try {
    realParent = await fsp.realpath(parent);
  } catch (error) {
    outputFailure('output-io', parent, `cannot resolve output parent directory: ${errorMessage(error)}`);
  }
  if (!isInsideOrEqual(realParent, canonicalRoot)) {
    outputFailure('output-containment', realParent, 'output parent escapes the site root');
  }
  await validateOutputComponents(containmentRoot, out);
}

async function acquireLock(lockPath) {
  try {
    await fsp.mkdir(lockPath);
  } catch (error) {
    if (errorCode(error) === 'EEXIST') {
      outputFailure('output-lock-exists', lockPath, 'publication lock already exists; it is never silently removed');
    }
    outputFailure('output-io', lockPath, `cannot acquire publication lock: ${errorMessage(error)}`);
  }
}

async function removePathForPublication(fullPath, description) {
  try {
    await fsp.rm(fullPath, { recursive: true, force: true });
  } catch (error) {
    outputFailure('output-io', fullPath, `cannot remove ${description}: ${errorMessage(error)}`);
  }
}

function ownershipMarkerPath(treePath, markerName) {
  return path.join(treePath, markerName);
}

async function requireOwnershipMarker(treePath, markerName, expectedBytes, cls, description) {
  const markerPath = ownershipMarkerPath(treePath, markerName);
  let st;
  try {
    st = await fsp.lstat(markerPath);
  } catch (error) {
    if (errorCode(error) === 'ENOENT' || errorCode(error) === 'ENOTDIR') {
      outputFailure(cls, markerPath, `${description} ownership marker is missing`);
    }
    outputFailure(cls, markerPath, `cannot inspect ${description} ownership marker: ${errorMessage(error)}`);
  }
  if (!st.isFile() || st.size !== expectedBytes.length) {
    outputFailure(cls, markerPath, `${description} ownership marker is missing or invalid`);
  }

  let bytes;
  try {
    bytes = await fsp.readFile(markerPath);
  } catch (error) {
    outputFailure(cls, markerPath, `cannot read ${description} ownership marker: ${errorMessage(error)}`);
  }
  if (!bytes.equals(expectedBytes)) {
    outputFailure(cls, markerPath, `${description} ownership marker is missing or invalid`);
  }
  return markerPath;
}

async function writeOwnershipMarker(treePath, markerName, markerBytes, cls, description) {
  const markerPath = ownershipMarkerPath(treePath, markerName);
  try {
    await fsp.writeFile(markerPath, markerBytes, { flag: 'wx' });
  } catch (error) {
    outputFailure(cls, markerPath, `cannot write ${description} ownership marker: ${errorMessage(error)}`);
  }
  return markerPath;
}

async function removeOwnershipMarker(markerPath, cls, description) {
  try {
    await fsp.unlink(markerPath);
  } catch (error) {
    outputFailure(cls, markerPath, `cannot remove ${description} ownership marker: ${errorMessage(error)}`);
  }
}

async function restoreOwnedBackup(out, backup) {
  const outStat = await lstatForPublication(out);
  if (outStat) {
    outputFailure('output-backup-conflict', backup, 'both output and fixed backup exist; refusing to choose between them');
  }
  const backupStat = await lstatForPublication(backup);
  if (!backupStat || backupStat.isSymbolicLink() || !backupStat.isDirectory()) {
    outputFailure('output-backup-invalid', backup, 'fixed backup is not a plain directory and cannot be restored');
  }
  const markerPath = await requireOwnershipMarker(
    backup,
    BACKUP_OWNER_MARKER,
    BACKUP_OWNER_MARKER_BYTES,
    'output-backup-invalid',
    'fixed backup',
  );
  await removeOwnershipMarker(markerPath, 'output-backup-invalid', 'fixed backup');
  try {
    await fsp.rename(backup, out);
  } catch (error) {
    outputFailure('output-io', backup, `cannot restore fixed backup before building: ${errorMessage(error)}`);
  }
}

async function recoverPublicationState(out, stage, backup) {
  let outStat = await lstatForPublication(out);
  const backupStat = await lstatForPublication(backup);

  if (outStat && outStat.isSymbolicLink()) {
    outputFailure('output-symlink', out, 'symlinked pre-existing output path is a host failure');
  }
  if (outStat && !outStat.isDirectory()) {
    outputFailure('output-not-directory', out, 'pre-existing output path is not a directory');
  }
  if (outStat && backupStat) {
    outputFailure('output-backup-conflict', backup, 'both output and fixed backup exist; refusing to choose between them');
  }
  if (!outStat && backupStat) {
    await restoreOwnedBackup(out, backup);
    outStat = await lstatForPublication(out);
    if (!outStat || !outStat.isDirectory() || outStat.isSymbolicLink()) {
      outputFailure('output-io', out, 'fixed backup restoration did not produce a plain output directory');
    }
  }

  const stageStat = await lstatForPublication(stage);
  if (stageStat) {
    if (stageStat.isSymbolicLink() || !stageStat.isDirectory()) {
      outputFailure('output-stage-invalid', stage, 'fixed stage is not a plain directory and cannot be removed safely');
    }
    await requireOwnershipMarker(
      stage,
      STAGE_OWNER_MARKER,
      STAGE_OWNER_MARKER_BYTES,
      'output-stage-invalid',
      'incomplete stage',
    );
    await removePathForPublication(stage, 'marker-owned incomplete stage tree');
  }
}

function compareCollision(a, b) {
  const byAncestor = compareNames(a.ancestorRel, b.ancestorRel);
  if (byAncestor !== 0) return byAncestor;
  const byDescendant = compareNames(a.descendantRel, b.descendantRel);
  if (byDescendant !== 0) return byDescendant;
  return compareNames(a.descendantPage, b.descendantPage);
}

function findOutputPathCollision(pages) {
  const owners = new Map(HOST_FIXED_OUTPUT_FILES.map((rel) => [rel, null]));
  const entries = [];
  const collisions = [];

  for (const page of pages) {
    const rel = `${page.id}.html`;
    if (owners.has(rel)) {
      collisions.push({
        ancestorRel: rel,
        descendantRel: rel,
        ancestorPage: owners.get(rel),
        descendantPage: page.id,
        exact: true,
      });
    } else {
      owners.set(rel, page.id);
    }
    entries.push({ id: page.id, rel });
  }

  for (const entry of entries) {
    const segments = entry.rel.split('/');
    for (let i = 1; i < segments.length; i += 1) {
      const ancestorRel = segments.slice(0, i).join('/');
      if (owners.has(ancestorRel)) {
        collisions.push({
          ancestorRel,
          descendantRel: entry.rel,
          ancestorPage: owners.get(ancestorRel),
          descendantPage: entry.id,
          exact: false,
        });
      }
    }
  }

  if (collisions.length === 0) return null;
  collisions.sort(compareCollision);
  return collisions[0];
}

function outputPathCollisionFailure(out, collision) {
  const hostPath = path.join(out, ...collision.ancestorRel.split('/'));
  const detail = collision.exact
    ? `${collision.ancestorRel} is emitted more than once`
    : collision.ancestorPage === null
      ? `${collision.descendantRel} requires fixed host publication file ${collision.ancestorRel} to be a directory`
      : `${collision.ancestorRel} cannot be both a file and a directory required by ${collision.descendantRel}`;
  throw oneFailure(3, 'output-path-collision', {
    path: hostPath,
    page: collision.descendantPage,
    target: collision.ancestorPage,
    message: `unrepresentable output path collision: ${detail}`,
  });
}

function assertNoOutputPathCollisions(out, pages) {
  const collision = findOutputPathCollision(pages);
  if (collision) outputPathCollisionFailure(out, collision);
}

function sha256Hex(bytes) {
  return crypto.createHash('sha256').update(bytes).digest('hex');
}

function stageFilePath(stage, rel, out) {
  if (path.isAbsolute(rel) || rel.includes('\0')) {
    outputFailure('output-containment', out, 'emitted page path is absolute or contains NUL');
  }
  const full = path.resolve(stage, rel);
  if (!isStrictlyInside(full, stage)) {
    outputFailure('output-containment', out, 'emitted page path escapes the stage tree');
  }
  return full;
}

async function writeStageTree(stage, pages, out) {
  try {
    await fsp.mkdir(stage);
  } catch (error) {
    outputFailure('output-io', stage, `cannot create fresh stage tree: ${errorMessage(error)}`);
  }
  await writeOwnershipMarker(
    stage,
    STAGE_OWNER_MARKER,
    STAGE_OWNER_MARKER_BYTES,
    'output-io',
    'incomplete stage',
  );

  const expectedFiles = new Map();
  const manifestPages = [];
  for (const page of pages) {
    const rel = `${page.id}.html`;
    const bytes = Buffer.from(page.html, 'utf8');
    const full = stageFilePath(stage, rel, out);
    try {
      await fsp.mkdir(path.dirname(full), { recursive: true });
      await fsp.writeFile(full, bytes);
    } catch (error) {
      outputFailure('output-io', full, `cannot write staged page: ${errorMessage(error)}`);
    }
    if (expectedFiles.has(rel)) {
      outputFailure('output-path-collision', full, `unrepresentable output path collision: ${rel} is emitted more than once`);
    }
    expectedFiles.set(rel, bytes);
    manifestPages.push({ id: page.id, path: rel, sha256: sha256Hex(bytes) });
  }

  const manifest = { version: 1, pages: manifestPages };
  const manifestBytes = Buffer.from(`${JSON.stringify(manifest, null, 2)}\n`, 'utf8');
  const manifestRel = '_pubend/manifest.json';
  const manifestPath = path.join(stage, '_pubend', 'manifest.json');
  try {
    await fsp.mkdir(path.dirname(manifestPath), { recursive: true });
    await fsp.writeFile(manifestPath, manifestBytes);
  } catch (error) {
    outputFailure('output-io', manifestPath, `cannot write staged manifest: ${errorMessage(error)}`);
  }
  expectedFiles.set(manifestRel, manifestBytes);

  const markerPath = await requireOwnershipMarker(
    stage,
    STAGE_OWNER_MARKER,
    STAGE_OWNER_MARKER_BYTES,
    'output-stage-invalid',
    'incomplete stage',
  );
  await removeOwnershipMarker(markerPath, 'output-io', 'incomplete stage');
  return { files: expectedFiles };
}

function expectedStageDirectories(expectedFiles) {
  const directories = new Set();
  for (const rel of expectedFiles.keys()) {
    const segments = rel.split('/');
    for (let i = 1; i < segments.length; i += 1) {
      directories.add(segments.slice(0, i).join('/'));
    }
  }
  return directories;
}

function invalidStage(pathValue, message) {
  outputFailure('output-stage-invalid', pathValue, message);
}

async function lstatStageEntry(fullPath) {
  try {
    return await fsp.lstat(fullPath);
  } catch (error) {
    if (errorCode(error) === 'ENOENT' || errorCode(error) === 'ENOTDIR') {
      invalidStage(fullPath, 'stage entry disappeared during validation');
    }
    outputFailure('output-io', fullPath, `cannot inspect stage entry: ${errorMessage(error)}`);
  }
  return null;
}

async function validateCompletedStage(stage, expectedFiles) {
  const rootStat = await lstatStageEntry(stage);
  if (rootStat.isSymbolicLink() || !rootStat.isDirectory()) {
    invalidStage(stage, 'completed stage root is not a plain directory');
  }

  const expectedDirectories = expectedStageDirectories(expectedFiles);
  const seenFiles = new Set();
  const seenDirectories = new Set();

  async function walk(dir, relDir) {
    let names;
    try {
      names = (await fsp.readdir(dir)).sort(compareNames);
    } catch (error) {
      outputFailure('output-io', dir, `cannot read stage directory during validation: ${errorMessage(error)}`);
    }

    for (const name of names) {
      const rel = relDir ? `${relDir}/${name}` : name;
      const full = path.join(dir, name);
      const st = await lstatStageEntry(full);
      if (st.isSymbolicLink()) {
        invalidStage(full, `stage entry ${rel} is a symlink`);
      }
      if (st.isDirectory()) {
        if (!expectedDirectories.has(rel)) {
          invalidStage(full, `stage contains unexpected directory ${rel}`);
        }
        seenDirectories.add(rel);
        await walk(full, rel);
      } else if (st.isFile()) {
        if (!expectedFiles.has(rel)) {
          invalidStage(full, `stage contains unexpected file ${rel}`);
        }
        seenFiles.add(rel);
        let actual;
        try {
          actual = await fsp.readFile(full);
        } catch (error) {
          outputFailure('output-io', full, `cannot read staged file during validation: ${errorMessage(error)}`);
        }
        if (!actual.equals(expectedFiles.get(rel))) {
          invalidStage(full, `staged file bytes differ for ${rel}`);
        }
      } else {
        invalidStage(full, `stage entry ${rel} is neither a regular file nor a directory`);
      }
    }
  }

  await walk(stage, '');

  for (const rel of [...expectedFiles.keys()].sort(compareNames)) {
    if (!seenFiles.has(rel)) {
      invalidStage(path.join(stage, ...rel.split('/')), `expected staged file ${rel} is missing`);
    }
  }
  for (const rel of [...expectedDirectories].sort(compareNames)) {
    if (!seenDirectories.has(rel)) {
      invalidStage(path.join(stage, ...rel.split('/')), `expected stage directory ${rel} is missing`);
    }
  }
}

async function renameForPublication(from, to, description) {
  try {
    await fsp.rename(from, to);
  } catch (error) {
    outputFailure('output-publication', from, `cannot ${description}: ${errorMessage(error)}`);
  }
}

async function tryRestoreOwnedBackup(out, backup) {
  try {
    await restoreOwnedBackup(out, backup);
  } catch {
    // Recovery is best-effort and must not hide the original swap diagnostic.
  }
}

async function ensureBackupMarkerSlotAvailable(out) {
  const markerPath = ownershipMarkerPath(out, BACKUP_OWNER_MARKER);
  const markerStat = await lstatForPublication(markerPath);
  if (markerStat) {
    outputFailure('output-backup-invalid', markerPath, 'output already contains the fixed backup ownership marker path');
  }
}

async function removeOwnedBackup(backup) {
  const backupStat = await lstatForPublication(backup);
  if (!backupStat || backupStat.isSymbolicLink() || !backupStat.isDirectory()) {
    outputFailure('output-backup-invalid', backup, 'fixed backup is not a plain marker-owned directory and cannot be removed safely');
  }
  await requireOwnershipMarker(
    backup,
    BACKUP_OWNER_MARKER,
    BACKUP_OWNER_MARKER_BYTES,
    'output-backup-invalid',
    'fixed backup',
  );
  await removePathForPublication(backup, 'marker-owned fixed backup');
}

async function swapStageIntoPlace(out, stage, backup) {
  const outStat = await lstatForPublication(out);
  if (outStat && outStat.isSymbolicLink()) {
    outputFailure('output-symlink', out, 'symlinked pre-existing output path is a host failure');
  }
  if (outStat && !outStat.isDirectory()) {
    outputFailure('output-not-directory', out, 'pre-existing output path is not a directory');
  }
  const backupStat = await lstatForPublication(backup);
  if (backupStat) {
    outputFailure('output-backup-conflict', backup, 'fixed backup already exists before the publication swap');
  }

  let movedOut = false;
  if (outStat) {
    await ensureBackupMarkerSlotAvailable(out);
    await renameForPublication(out, backup, 'move existing output to fixed backup');
    movedOut = true;
    await writeOwnershipMarker(
      backup,
      BACKUP_OWNER_MARKER,
      BACKUP_OWNER_MARKER_BYTES,
      'output-publication',
      'fixed backup',
    );
  }

  try {
    await fsp.rename(stage, out);
  } catch (error) {
    if (movedOut) await tryRestoreOwnedBackup(out, backup);
    outputFailure('output-publication', stage, `cannot move completed stage tree into place: ${errorMessage(error)}`);
  }

  if (movedOut) {
    await removeOwnedBackup(backup);
  }
}

function normalizeOutputError(error, out) {
  if (isCliFailure(error)) return error;
  return oneFailure(3, 'output-publication', {
    path: out,
    message: `unexpected output publication failure: ${errorMessage(error)}`,
  });
}

async function bestEffortRemoveStage(stage) {
  try {
    const st = await lstatOrNull(stage);
    if (!st || st.isSymbolicLink() || !st.isDirectory()) return;
    await requireOwnershipMarker(
      stage,
      STAGE_OWNER_MARKER,
      STAGE_OWNER_MARKER_BYTES,
      'output-stage-invalid',
      'incomplete stage',
    );
    await fsp.rm(stage, { recursive: true, force: true });
  } catch {
    // Stage cleanup is best-effort and must not hide the original diagnostic.
  }
}

async function publishOutput(containmentRoot, canonicalRoot, out, pages) {
  const lock = `${out}.pubend-lock`;
  const stage = `${out}.pubend-stage`;
  const backup = `${out}.pubend-previous`;

  assertNoOutputPathCollisions(out, pages);
  await prepareOutputParent(containmentRoot, canonicalRoot, out);

  let lockAcquired = false;
  let primaryError = null;
  try {
    await acquireLock(lock);
    lockAcquired = true;

    await recoverPublicationState(out, stage, backup);
    await validateOutputComponents(containmentRoot, out);
    const staged = await writeStageTree(stage, pages, out);
    await validateCompletedStage(stage, staged.files);
    await swapStageIntoPlace(out, stage, backup);
  } catch (error) {
    primaryError = error;
    if (lockAcquired) await bestEffortRemoveStage(stage);
  }

  let unlockError = null;
  if (lockAcquired) {
    try {
      await fsp.rmdir(lock);
    } catch (error) {
      unlockError = error;
    }
  }

  if (primaryError) throw normalizeOutputError(primaryError, out);
  if (unlockError) {
    outputFailure('output-io', lock, `cannot release publication lock: ${errorMessage(unlockError)}`);
  }
}

async function run(argv) {
  const cli = parseCli(argv);
  const site = await resolveSitePaths(cli.dirArg);
  const { out, contentDir, containmentRoot } = await resolveOutputPath(site.root, site.realRoot, cli.outArg);

  const scan = await scanSite(contentDir);
  if (scan.hostErrors.length !== 0) throw new CliFailure(3, scan.hostErrors);
  if (scan.inputErrors.length !== 0) throw new CliFailure(1, scan.inputErrors);

  const prepared = await prepareCompileReport();
  const compiled = invokeCompileReport(prepared.compileReport, scan.pages, prepared.artifact);
  if (!compiled.ok) throw new CliFailure(1, compiled.diagnostics);

  await publishOutput(containmentRoot, site.realRoot, out, compiled.pages);
  return 0;
}

function normalizeFailure(error) {
  if (isCliFailure(error)) return error;
  return oneFailure(3, 'host-error', {
    message: `unexpected host failure: ${errorMessage(error)}`,
  });
}

function writeFailure(failure) {
  const payload = {
    version: 1,
    status: 'error',
    diagnostics: failure.diagnostics,
  };
  process.stderr.write(`${JSON.stringify(payload, null, 0)}\n`);
}

run(process.argv.slice(2)).then((code) => {
  process.exitCode = code;
}).catch((error) => {
  const failure = normalizeFailure(error);
  writeFailure(failure);
  process.exitCode = failure.exitCode;
});
