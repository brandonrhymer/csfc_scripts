import { afterAll, beforeAll, describe, expect, test } from 'bun:test';
import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { buildRelease, type ReleaseManifest } from './package';
import { createDraft } from './release';

let root: string, output: string, manifest: ReleaseManifest;
beforeAll(() => {
  root = mkdtempSync(join(tmpdir(), 'csfc-release-api-'));
  mkdirSync(join(root, 'tools/release'), { recursive: true });
  mkdirSync(join(root, 'scripts'));
  writeFileSync(join(root, 'scripts/sample.py'), 'print("synthetic fixture")\n');
  writeFileSync(join(root, 'scripts/README.md'), '# Synthetic runbook\n');
  writeFileSync(join(root, 'tools/release/catalog.json'), JSON.stringify({ schemaVersion: 1, bundleVersion: '0.1.0', sharedFiles: [], products: [{ id: 'sample', name: 'Synthetic sample', version: '1.0.0', entrypoint: 'scripts/sample.py', runbook: 'scripts/README.md', files: [] }] }));
  const git = (...args: string[]) => execFileSync('git', ['-C', root, ...args], { stdio: 'pipe', windowsHide: true });
  git('init'); git('config', 'user.name', 'Synthetic CI'); git('config', 'user.email', 'ci@example.invalid'); git('config', 'commit.gpgsign', 'false'); git('config', 'core.autocrlf', 'false');
  git('add', '--', 'scripts', 'tools'); git('commit', '-m', 'Synthetic fixture');
  output = join(root, 'output'); manifest = buildRelease({ repo: root, output, product: 'sample' });
});
afterAll(() => {
  if (root && resolve(root).startsWith(resolve(tmpdir()) + require('node:path').sep) && root.includes('csfc-release-api-')) rmSync(root, { recursive: true, force: true });
});

function fakeGithub(mode = 'success') {
  const calls: { method: string; url: string; body?: any }[] = [];
  const assets: any[] = [];
  let reserved = false;
  const tag = { ref: 'refs/tags/sample/v1.0.0', object: { type: 'commit', sha: manifest.sourceCommit } };
  const release = { id: 42, draft: true, tag_name: 'sample/v1.0.0', target_commitish: manifest.sourceCommit, assets };
  const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } });
  const request = async (url: string, init: RequestInit) => {
    expect(url).not.toContain('synthetic-token');
    expect(init.redirect).toBe('error');
    expect((init.headers as any).Authorization).toBe('Bearer synthetic-token');
    const method = init.method!;
    calls.push({ method, url, body: typeof init.body === 'string' ? JSON.parse(init.body) : undefined });
    if (url.includes('/git/ref/tags/')) {
      if (reserved) return json(mode === 'moved-tag' ? { ...tag, object: { type: 'commit', sha: '0'.repeat(40) } } : tag);
      return json(mode === 'existing-tag' ? tag : {}, mode === 'existing-tag' ? 200 : 404);
    }
    if (url.endsWith('/git/refs') && method === 'POST') {
      if (mode === 'tag-race') return json({}, 422);
      reserved = true; return json(tag, 201);
    }
    if (url.includes('/releases?')) return json(mode === 'existing-draft' ? [release] : []);
    if (url.endsWith('/releases') && method === 'POST') return json(release, 201);
    if (url.startsWith('https://uploads.github.com/')) {
      if (mode === 'upload-failure') return json({}, 503);
      const bytes = Buffer.from(init.body as any);
      const asset = { name: new URL(url).searchParams.get('name'), size: bytes.length, digest: 'sha256:' + createHash('sha256').update(bytes).digest('hex') };
      if (mode === 'wrong-digest') asset.digest = 'sha256:' + '0'.repeat(64);
      assets.push(asset); return json(asset, 201);
    }
    if (url.endsWith('/releases/42')) return json(release);
    throw new Error(`Unexpected synthetic request: ${method} ${url}`);
  };
  return { calls, assets, request };
}
const options = () => ({ directory: output, repository: 'example/synthetic', sha: manifest.sourceCommit, tag: 'sample/v1.0.0', token: 'synthetic-token', runId: '123' });
describe('draft release transport', () => {
  test('creates only a draft for the verified commit and validates all uploaded digests', async () => {
    const fake = fakeGithub();
    await createDraft({ ...options(), request: fake.request });
    expect(fake.assets.map(a => a.name).sort()).toEqual(['RELEASE-NOTES.md', 'SHA256SUMS.txt', 'release.json', 'sample-1.0.0.zip']);
    const creation = fake.calls.find(c => c.method === 'POST' && c.url.endsWith('/releases'))!;
    expect(creation.body.draft).toBe(true);
    expect(creation.body.target_commitish).toBe(manifest.sourceCommit);
    expect(fake.calls.some(c => ['PATCH', 'DELETE'].includes(c.method))).toBe(false);
  });
  test.each(['existing-tag', 'existing-draft'])('refuses %s without writes', async mode => {
    const fake = fakeGithub(mode);
    await expect(createDraft({ ...options(), request: fake.request })).rejects.toThrow(/already exists/);
    expect(fake.calls.every(c => c.method === 'GET')).toBe(true);
  });
  test.each(['upload-failure', 'wrong-digest'])('fails on %s without publishing or overwriting', async mode => {
    const fake = fakeGithub(mode);
    await expect(createDraft({ ...options(), request: fake.request })).rejects.toThrow(/incomplete/);
    expect(fake.calls.some(c => ['PATCH', 'DELETE'].includes(c.method))).toBe(false);
  });
  test('a concurrent tag creation cannot redirect the release', async () => {
    const fake = fakeGithub('tag-race');
    await expect(createDraft({ ...options(), request: fake.request })).rejects.toThrow('HTTP 422');
    expect(fake.calls.some(c => c.url.endsWith('/releases') && c.method === 'POST')).toBe(false);
  });
  test('detects a tag moved externally during asset upload', async () => {
    const fake = fakeGithub('moved-tag');
    await expect(createDraft({ ...options(), request: fake.request })).rejects.toThrow('no longer points');
  });
  test('rejects altered downloaded artifacts before contacting GitHub', async () => {
    const original = readFileSync(join(output, 'sample-1.0.0.zip'));
    try {
      writeFileSync(join(output, 'sample-1.0.0.zip'), Buffer.concat([original, Buffer.from('tamper')]));
      const fake = fakeGithub();
      await expect(createDraft({ ...options(), request: fake.request })).rejects.toThrow();
      expect(fake.calls).toHaveLength(0);
    } finally { writeFileSync(join(output, 'sample-1.0.0.zip'), original); }
  });
});
