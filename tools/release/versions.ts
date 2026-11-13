import { execFileSync } from 'node:child_process';
import { checkVersionChanges } from './package';

if (import.meta.main) {
  try {
    const git = (...args: string[]) => execFileSync('git', args, { encoding: 'utf8', windowsHide: true }).trim();
    const head = git('rev-parse', 'HEAD');
    const base = process.env.BASE_SHA || git('rev-parse', 'HEAD^');
    console.log(JSON.stringify(checkVersionChanges(process.cwd(), base, head), null, 2));
  } catch (error) { console.error(error instanceof Error ? error.message : 'Product version validation failed.'); process.exitCode = 1; }
}
