import { appendFileSync, readFileSync, lstatSync } from 'node:fs';
import { resolve } from 'node:path';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { verifyOutput, validateVersion } from './package';

type Catalog = { bundleVersion: string; products: { id: string; version: string }[] };
type Inputs = { event: string; ref: string; product?: string; bundleProducts?: string; bundleVersion?: string };
export type Plan = { product: string; bundle_products: string; bundle_version: string; tag: string; version: string };

export function makePlan(catalog: Catalog, inputs: Inputs, now = new Date()): Plan {
  if (inputs.ref !== 'refs/heads/main') throw new Error('Release preparation must run from main.');
  if (!['schedule', 'workflow_dispatch'].includes(inputs.event)) throw new Error('Unsupported release event.');
  const scheduled = inputs.event === 'schedule';
  const product = scheduled ? 'bundle' : inputs.product || 'bundle';
  const item = catalog.products.find(p => p.id === product);
  if (product !== 'bundle' && !item) throw new Error('Unknown release product.');
  const members = scheduled || !inputs.bundleProducts ? [] : inputs.bundleProducts.split(',').map(x => x.trim());
  if (product !== 'bundle' && (members.length || inputs.bundleVersion)) throw new Error('Bundle options require the bundle product.');
  if (new Set(members).size !== members.length || members.some(id => !catalog.products.some(p => p.id === id))) throw new Error('Unknown or duplicate bundle product.');
  const version = product === 'bundle'
    ? scheduled ? `${now.getUTCFullYear()}.${Math.floor(now.getUTCMonth() / 3) + 1}.0` : inputs.bundleVersion || catalog.bundleVersion
    : item!.version;
  validateVersion(version);
  return { product, bundle_products: members.join(','), bundle_version: product === 'bundle' ? version : '', version, tag: `${product}/v${version}` };
}

type Request = (url: string, init: RequestInit) => Promise<Response>;
type Asset = { id: string; version: string; tag: string; file: string; sha256: string; size: number };
type Manifest = { sourceCommit: string; selection: { product: string }; assets: Asset[] };

export function checkReleaseIdentity(manifest: Manifest, sha: string, tag: string): Asset {
  if (!/^[a-f0-9]{40}$|^[a-f0-9]{64}$/.test(sha) || manifest.sourceCommit !== sha) throw new Error('Artifact source commit does not match the validated run.');
  if (manifest.selection.product === 'all' || manifest.assets.length !== 1) throw new Error('Release preparation requires one product or one bundle.');
  const asset = manifest.assets[0];
  if (asset.tag !== tag || asset.id !== manifest.selection.product || tag !== `${asset.id}/v${asset.version}`) throw new Error('Artifact release identity does not match the release plan.');
  return asset;
}

export async function createDraft(options: {
  directory: string; repository: string; sha: string; tag: string; token: string;
  runId: string; attestation?: string; request?: Request;
}): Promise<string> {
  if (!/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/.test(options.repository) || !/^\d+$/.test(options.runId)) throw new Error('Invalid repository/run identity.');
  if (!options.token) throw new Error('A release job token is required.');
  const manifest = verifyOutput(options.directory);
  const asset = checkReleaseIdentity(manifest, options.sha, options.tag);
  const request = options.request || fetch;
  const base = `https://api.github.com/repos/${options.repository}`;
  const headers = { Authorization: `Bearer ${options.token}`, Accept: 'application/vnd.github+json', 'X-GitHub-Api-Version': '2022-11-28' };
  async function api(method: string, path: string, body?: unknown, allow404 = false): Promise<any> {
    const response = await request(base + path, { method, headers: { ...headers, 'Content-Type': 'application/json' }, body: body === undefined ? undefined : JSON.stringify(body), redirect: 'error' });
    if (allow404 && response.status === 404) return null;
    if (!response.ok) throw new Error(`GitHub ${method} request failed (HTTP ${response.status}).`);
    return response.status === 204 ? null : response.json();
  }
  if (await api('GET', `/git/ref/tags/${encodeURIComponent(options.tag)}`, undefined, true)) throw new Error('This version tag already exists; versions are never overwritten.');
  for (let page = 1; ; page++) {
    if (page > 100) throw new Error('Release inventory exceeded the safe lookup limit.');
    const releases = await api('GET', `/releases?per_page=100&page=${page}`);
    if (!Array.isArray(releases)) throw new Error('Invalid release inventory.');
    if (releases.some(r => r.tag_name === options.tag)) throw new Error('This release version already exists, including drafts. Reconcile it or choose a new version.');
    if (releases.length < 100) break;
  }
  const files = [...manifest.assets.map(a => ({ name: a.file, path: resolve(options.directory, a.file) })), ...['release.json', 'SHA256SUMS.txt', 'RELEASE-NOTES.md'].map(name => ({ name, path: resolve(options.directory, name) }))];
  if (options.attestation) files.push({ name: 'provenance.jsonl', path: resolve(options.attestation) });
  const uploads = files.map(file => {
    if (!lstatSync(file.path).isFile()) throw new Error('Release assets must be regular files.');
    const bytes = readFileSync(file.path);
    return { ...file, bytes, sha256: createHash('sha256').update(bytes).digest('hex') };
  });
  const notes = readFileSync(resolve(options.directory, 'RELEASE-NOTES.md'), 'utf8');
  // Creating a ref is atomic: an external actor winning this race causes a
  // conflict, never a release silently attached to a different commit.
  const reserved = await api('POST', '/git/refs', { ref: `refs/tags/${options.tag}`, sha: options.sha });
  if (reserved.ref !== `refs/tags/${options.tag}` || reserved.object?.type !== 'commit' || reserved.object?.sha !== options.sha) throw new Error('Tag reservation did not identify the validated commit.');
  const draft = await api('POST', '/releases', {
    tag_name: options.tag, target_commitish: options.sha, name: `${asset.id} v${asset.version}`,
    draft: true, prerelease: asset.version.split('+')[0].includes('-'),
    body: `${notes}\n\nValidation: https://github.com/${options.repository}/actions/runs/${options.runId}\n\nPrepared as a draft. Review assets and validation limits before publishing; this does not authorize operational deployment.`,
  });
  if (!Number.isSafeInteger(draft.id) || draft.draft !== true || draft.tag_name !== options.tag || draft.target_commitish !== options.sha) throw new Error('Unexpected release identity returned by GitHub.');
  const uploadBase = `https://uploads.github.com/repos/${options.repository}/releases/${draft.id}/assets`;
  for (const file of uploads) {
    const response = await request(`${uploadBase}?name=${encodeURIComponent(file.name)}`, { method: 'POST', headers: { ...headers, 'Content-Type': 'application/octet-stream' }, body: file.bytes, redirect: 'error' });
    if (!response.ok) throw new Error(`Upload failed (HTTP ${response.status}); draft ${draft.id} remains incomplete and must be reconciled before retrying.`);
    const saved = await response.json() as any;
    if (saved.name !== file.name || saved.size !== file.bytes.length || saved.digest !== `sha256:${file.sha256}`) throw new Error(`Uploaded asset verification failed; draft ${draft.id} remains incomplete.`);
  }
  const saved = await api('GET', `/releases/${draft.id}`);
  if (saved.draft !== true || saved.tag_name !== options.tag || saved.target_commitish !== options.sha || saved.assets.length !== uploads.length || uploads.some(f => !saved.assets.some((a: any) => a.name === f.name && a.size === f.bytes.length && a.digest === `sha256:${f.sha256}`))) throw new Error('Final draft verification failed.');
  const tag = await api('GET', `/git/ref/tags/${encodeURIComponent(options.tag)}`);
  if (tag.ref !== `refs/tags/${options.tag}` || tag.object?.type !== 'commit' || tag.object?.sha !== options.sha) throw new Error('Release tag no longer points to the validated commit.');
  return `https://github.com/${options.repository}/releases`;
}

if (import.meta.main) {
  try {
    if (process.argv[2] === 'plan') {
      const catalog = JSON.parse(execFileSync('git', ['show', 'HEAD:tools/release/catalog.json'], { encoding: 'utf8' }));
      const plan = makePlan(catalog, { event: process.env.GITHUB_EVENT_NAME || '', ref: process.env.GITHUB_REF || '', product: process.env.RELEASE_PRODUCT, bundleProducts: process.env.BUNDLE_PRODUCTS, bundleVersion: process.env.BUNDLE_VERSION });
      if (!process.env.GITHUB_OUTPUT) throw new Error('GitHub output path is required.');
      appendFileSync(process.env.GITHUB_OUTPUT, Object.entries(plan).map(([key, value]) => `${key}=${value}\n`).join(''));
      console.log(JSON.stringify(plan));
    } else if (process.argv[2] === 'draft' && process.argv.length === 4) {
      console.log(await createDraft({ directory: process.argv[3], repository: process.env.GITHUB_REPOSITORY || '', sha: process.env.GITHUB_SHA || '', tag: process.env.RELEASE_TAG || '', token: process.env.GH_TOKEN || '', runId: process.env.GITHUB_RUN_ID || '', attestation: process.env.ATTESTATION_BUNDLE }));
    } else throw new Error('Usage: bun tools/release/release.ts plan | draft <verified-output-directory>');
  } catch (error) { console.error(error instanceof Error ? error.message : 'Release preparation failed.'); process.exitCode = 1; }
}
