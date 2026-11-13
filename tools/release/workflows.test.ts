import { describe, expect, test } from 'bun:test';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';

const root = resolve(import.meta.dir, '../..');
const yaml = (name: string): any => Bun.YAML.parse(readFileSync(resolve(root, '.github/workflows', name), 'utf8'));
describe('delivery workflow boundaries', () => {
  test('pull requests have read-only permissions and preserve existing functional gates', () => {
    const ci = yaml('ci.yml');
    expect(ci.permissions).toEqual({ contents: 'read' });
    expect(Object.hasOwn(ci.on, 'pull_request')).toBe(true);
    expect(Object.hasOwn(ci.on, 'pull_request_target')).toBe(false);
    expect(ci.jobs.packages.needs.sort()).toEqual(['krbtgt', 'linux', 'windows']);
    for (const job of Object.values(ci.jobs) as any[]) expect(job.permissions).toBeUndefined();
  });
  test('bundle releases are scheduled quarterly, never on script pushes', () => {
    const release = yaml('release.yml');
    expect(Object.keys(release.on).sort()).toEqual(['schedule', 'workflow_dispatch']);
    expect(release.on.schedule).toEqual([{ cron: '0 14 1 1,4,7,10 *' }]);
    expect(release.jobs.validate.uses).toBe('./.github/workflows/ci.yml');
    expect(release.jobs.draft.needs.sort()).toEqual(['plan', 'validate']);
    expect(release.jobs.plan.steps[0].run).toBe('test "$SELECTED_REF" = refs/heads/main');
    expect(release.permissions).toEqual({ contents: 'read' });
    expect(release.jobs.draft.permissions).toEqual({ contents: 'write', 'id-token': 'write', attestations: 'write' });
  });
  test('third-party actions stay pinned and shell bodies do not interpolate input expressions', () => {
    for (const name of ['ci.yml', 'release.yml']) for (const job of Object.values(yaml(name).jobs) as any[]) for (const step of job.steps || []) {
      if (step.uses) expect(step.uses).toMatch(/^[\w-]+\/[\w-]+@[0-9a-f]{40}$/);
      if (step.uses?.startsWith('actions/checkout@')) expect(step.with['persist-credentials']).toBe(false);
      if (step.run) expect(step.run).not.toMatch(/\$\{\{/);
    }
  });
});
