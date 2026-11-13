import { describe, expect, test } from 'bun:test';
import { checkReleaseIdentity, makePlan } from './release';

const catalog = { bundleVersion: '0.1.0', products: [{ id: 'first', version: '1.2.3' }, { id: 'second', version: '2.0.0' }] };
const manual = { event: 'workflow_dispatch', ref: 'refs/heads/main' };
describe('release planning', () => {
  test('products retain independent versions and namespaced tags', () => {
    expect(makePlan(catalog, { ...manual, product: 'first' }).tag).toBe('first/v1.2.3');
    expect(makePlan(catalog, { ...manual, product: 'second' }).tag).toBe('second/v2.0.0');
  });
  test('quarterly bundles use their own calendar versions', () => {
    for (const [date, version] of [['2027-01-01', '2027.1.0'], ['2027-04-01', '2027.2.0'], ['2027-07-01', '2027.3.0'], ['2027-10-01', '2027.4.0']]) {
      expect(makePlan(catalog, { event: 'schedule', ref: manual.ref }, new Date(`${date}T14:00:00Z`)).tag).toBe(`bundle/v${version}`);
    }
  });
  test('selected bundles support explicit versions without changing product versions', () => {
    const plan = makePlan(catalog, { ...manual, product: 'bundle', bundleProducts: 'second,first', bundleVersion: '2026.4.1' });
    expect(plan.bundle_products).toBe('second,first');
    expect(plan.tag).toBe('bundle/v2026.4.1');
    expect(catalog.products[0].version).toBe('1.2.3');
  });
  test('rejects non-main, unknown/duplicate/injected selections and invalid versions', () => {
    for (const input of [{ ...manual, ref: 'refs/heads/topic' }, { ...manual, event: 'pull_request' }, { ...manual, product: 'all' }, { ...manual, product: 'first\nattack=x' }, { ...manual, product: 'bundle', bundleProducts: 'first,first' }, { ...manual, product: 'bundle', bundleProducts: 'missing' }, { ...manual, product: 'first', bundleVersion: '1.0.0' }, { ...manual, bundleVersion: '01.2.3' }, { ...manual, bundleVersion: '1.2.3\nattack=x' }, { ...manual, bundleVersion: '1.2.3-01' }]) expect(() => makePlan(catalog, input)).toThrow();
  });
});
describe('release identity', () => {
  const sha = 'a'.repeat(40);
  const asset = { id: 'first', version: '1.2.3', tag: 'first/v1.2.3', file: 'first-1.2.3.zip', sha256: 'b'.repeat(64), size: 1 };
  const manifest = { sourceCommit: sha, selection: { product: 'first' }, assets: [asset] };
  test('accepts only the selected tested commit and version', () => expect(checkReleaseIdentity(manifest, sha, asset.tag)).toEqual(asset));
  test('rejects a foreign commit, tag, product or unselected all-build', () => {
    expect(() => checkReleaseIdentity(manifest, 'c'.repeat(40), asset.tag)).toThrow();
    expect(() => checkReleaseIdentity(manifest, sha, 'first/v2.0.0')).toThrow();
    expect(() => checkReleaseIdentity({ ...manifest, selection: { product: 'all' } }, sha, asset.tag)).toThrow();
    expect(() => checkReleaseIdentity({ ...manifest, selection: { product: 'second' } }, sha, asset.tag)).toThrow();
    expect(() => checkReleaseIdentity({ ...manifest, assets: [asset, asset] }, sha, asset.tag)).toThrow();
  });
});
