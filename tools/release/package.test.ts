import { afterAll, describe, expect, test } from "bun:test";
import { execFileSync } from "node:child_process";
import { existsSync, lstatSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, realpathSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { buildRelease, checkVersionChanges, parseArgs, selectProducts, validateCatalog, validateVersion, verifyOutput, verifyPreservedPackage, verifyProductArchive, type Catalog } from "./package";
import { crc32, createZip, readZip, safePath, sha256, type ZipFile } from "./zip";

const temporaryRoots: string[] = [];
const sourceRepo = path.resolve(import.meta.dir, "../..");
// These cases create Git repositories/worktrees and spawn several processes.
// Hosted Windows timings exceed Bun's 5-second unit-test default.
const gitIntegrationTimeoutMs = 30_000;
function temporary() {
  const root = mkdtempSync(path.join(os.tmpdir(), "csfc-package-test-"));
  temporaryRoots.push(root); return root;
}
afterAll(() => {
  for (const root of temporaryRoots) {
    const relative = path.relative(os.tmpdir(), root);
    if (!relative.startsWith("csfc-package-test-") || relative.includes(path.sep)) throw new Error("Refusing unsafe fixture cleanup");
    rmSync(root, { recursive: true, force: true });
  }
});
function git(repo: string, args: string[], input?: Buffer | string) {
  return execFileSync("git", ["-C", repo, ...args], { input, windowsHide: true, maxBuffer: 32 * 1024 * 1024, stdio: ["pipe", "pipe", "pipe"] });
}
function write(repo: string, name: string, data: Buffer | string) {
  safePath(name); const target = path.join(repo, name);
  mkdirSync(path.dirname(target), { recursive: true }); writeFileSync(target, data);
}
function commit(repo: string) {
  git(repo, ["add", "--all"]); git(repo, ["-c", "user.name=Packaging fixture", "-c", "user.email=fixture@example.invalid", "commit", "-qm", "fixture"]);
  return git(repo, ["rev-parse", "HEAD"]).toString().trim();
}
function fixture(root = temporary()) {
  const repo = path.join(root, "repo"); mkdirSync(repo);
  git(repo, ["init", "-q"]); git(repo, ["config", "core.autocrlf", "false"]);
  const catalog: Catalog = {
    schemaVersion: 1, bundleVersion: "0.1.0", sharedFiles: ["docs/safety.md", "docs/context.md"], products: [
      { id: "alpha", name: "Alpha inspection", version: "1.2.3", entrypoint: "alpha/inspect.ps1", runbook: "alpha/README.md", files: ["alpha/helper.psm1"] },
      { id: "beta", name: "Beta inspection", version: "2.0.1", entrypoint: "beta/inspect.py", runbook: "beta/README.md", files: [] },
    ],
  };
  write(repo, "tools/release/catalog.json", JSON.stringify(catalog));
  write(repo, "docs/safety.md", "# Safety\nRead [additional context](context.md).\n");
  write(repo, "docs/context.md", "# Offline supporting context\n[Other product documentation](../beta/README.md).\n");
  write(repo, "alpha/README.md", "# Alpha\nUse the locally supplied helper.\n");
  write(repo, "alpha/inspect.ps1", "# $Format:%H$\nthrow 'An operational entrypoint must never run during packaging.'\n");
  write(repo, "alpha/helper.psm1", "function Get-Example { 'fixture' }\n");
  write(repo, "beta/README.md", "# Beta\n");
  write(repo, "beta/inspect.py", "raise RuntimeError('Do not execute during packaging')\n");
  write(repo, ".gitattributes", "alpha/helper.psm1 export-ignore\nalpha/inspect.ps1 export-subst\n");
  const sha = commit(repo);
  return { root, repo, catalog, sha, output: (name = "out") => path.join(root, name) };
}
function outputBytes(directory: string) {
  return Object.fromEntries(readdirSync(directory).sort().map(name => [name, sha256(readFileSync(path.join(directory, name)))]));
}
function zipFiles(output: string, file: string) { return readZip(readFileSync(path.join(output, file))); }
function replaceZip(output: string, file: string, transform: (files: Map<string, ZipFile>) => void) {
  const files = zipFiles(output, file); transform(files); writeFileSync(path.join(output, file), createZip(files));
}
// Re-sign only the outer integrity metadata, so deeper validators must detect the fault.
function refreshOuterHashes(output: string) {
  const manifest = JSON.parse(readFileSync(path.join(output, "release.json"), "utf8"));
  for (const asset of manifest.assets) {
    const bytes = readFileSync(path.join(output, asset.file)); asset.sha256 = sha256(bytes); asset.size = bytes.length;
  }
  writeFileSync(path.join(output, "release.json"), JSON.stringify(manifest));
  writeFileSync(path.join(output, "SHA256SUMS.txt"), readdirSync(output).filter(name => name !== "SHA256SUMS.txt").sort().map(name => `${sha256(readFileSync(path.join(output, name)))}  ${name}\n`).join(""));
}

describe("catalog and CLI boundaries", () => {
  test("rejects unsafe paths, versions, unknown/duplicate products and malformed options", () => {
    const { catalog } = fixture();
    for (const value of ["../secret", "/etc/passwd", "C:/secret", "a\\b", "a/../b", "a//b", "a/.git/config", "a/NUL.txt", "a/trailing."]) expect(() => safePath(value)).toThrow();
    for (const version of ["01.0.0", "v1.0.0", "1.0", "1.0.0-01", "1.0.0/../x", "1.0.0\n"]) expect(() => validateVersion(version)).toThrow();
    for (const version of ["0.1.0", "2027.1.0", "1.0.0-rc.1+build.3"]) expect(() => validateVersion(version)).not.toThrow();
    expect(() => selectProducts(catalog, "missing")).toThrow("Unknown product");
    expect(() => selectProducts(catalog, "bundle", ["alpha", "alpha"])).toThrow("duplicate");
    expect(() => selectProducts(catalog, "bundle", ["../alpha"])).toThrow();
    expect(() => selectProducts(catalog, "alpha", ["alpha"])).toThrow();
    expect(() => validateCatalog({ ...catalog, products: [...catalog.products, catalog.products[0]] })).toThrow("Duplicate");
    for (const args of [["--output"], ["--output", "a", "--product", "alpha", "--product", "beta"], ["--verify", "a", "--product", "all"], ["--unknown", "x"]]) expect(() => parseArgs(args)).toThrow();
    expect(parseArgs(["--verify", "candidate"])).toEqual({ verify: "candidate" });
  });
});

describe("committed source packaging", () => {
  test("includes dependencies/runbooks; excludes untracked and dirty data; ignores archive transformations", () => {
    const f = fixture();
    write(f.repo, "alpha/private-input.txt", "DO-NOT-PACKAGE-PRIVATE-INPUT");
    write(f.repo, "alpha/inspect.ps1", "DO-NOT-PACKAGE-WORKTREE-EDIT");
    write(f.repo, "tools/release/catalog.json", "invalid working catalog must not be read");
    const result = buildRelease({ repo: f.repo, output: f.output(), product: "alpha", ref: f.sha });
    expect(result.sourceCommit).toBe(f.sha); expect(result.assets).toHaveLength(1);
    const files = zipFiles(f.output(), "alpha-1.2.3.zip");
    expect(files.has("alpha-1.2.3/alpha/helper.psm1")).toBe(true);
    expect(files.has("alpha-1.2.3/docs/context.md")).toBe(true);
    expect(files.has("alpha-1.2.3/beta/README.md")).toBe(false);
    expect([...files.keys()].some(name => name.includes("private-input") || name.includes("beta/inspect.py"))).toBe(false);
    expect(files.get("alpha-1.2.3/alpha/inspect.ps1")!.data.toString()).toContain("must never run");
    expect(files.get("alpha-1.2.3/alpha/inspect.ps1")!.data.toString()).toContain("$Format:%H$");
    expect(readFileSync(path.join(f.output(), "alpha-1.2.3.zip")).includes(Buffer.from("DO-NOT-PACKAGE"))).toBe(false);
    expect(verifyOutput(f.output())).toEqual(result);
  });
  test("repeat builds are byte-identical; selected bundles retain independent versions", () => {
    const f = fixture();
    const all = buildRelease({ repo: f.repo, output: f.output("one"), product: "all" });
    buildRelease({ repo: f.repo, output: f.output("two"), product: "all", ref: f.sha });
    expect(outputBytes(f.output("one"))).toEqual(outputBytes(f.output("two")));
    expect(all.assets.map(asset => asset.id)).toEqual(["alpha", "beta", "bundle"]);
    const bundle = buildRelease({ repo: f.repo, output: f.output("subset"), product: "bundle", bundleProducts: ["beta"], bundleVersion: "2027.1.0" });
    expect(bundle.assets).toHaveLength(1); expect(bundle.assets[0].tag).toBe("bundle/v2027.1.0");
    expect(bundle.products.map(product => [product.id, product.version])).toEqual([["beta", "2.0.1"]]);
    const files = zipFiles(f.output("subset"), "bundle-2027.1.0.zip");
    expect(files.has("bundle-2027.1.0/beta-2.0.1.zip")).toBe(true);
    expect([...files.keys()].some(name => name.includes("alpha"))).toBe(false);
  });
  test("fails on missing dependency, explicit branch ref, nonempty/unsafe output, or wrong bundle flags", () => {
    const f = fixture();
    expect(() => buildRelease({ repo: f.repo, output: f.repo, product: "all" })).toThrow("repository");
    expect(() => buildRelease({ repo: f.repo, output: path.join(f.repo, ".git", "out"), product: "all" })).toThrow("Git metadata");
    expect(() => buildRelease({ repo: f.repo, output: f.output(), product: "all", ref: "HEAD" })).toThrow("exact full commit");
    expect(() => buildRelease({ repo: f.repo, output: f.output(), product: "alpha", bundleVersion: "2027.1.0" })).toThrow("requires");
    mkdirSync(f.output()); writeFileSync(path.join(f.output(), "keep.txt"), "keep");
    expect(() => buildRelease({ repo: f.repo, output: f.output(), product: "alpha" })).toThrow("new or empty");
    expect(readFileSync(path.join(f.output(), "keep.txt"), "utf8")).toBe("keep");
    f.catalog.products[0].files.push("alpha/missing.psm1"); write(f.repo, "tools/release/catalog.json", JSON.stringify(f.catalog)); commit(f.repo);
    expect(() => buildRelease({ repo: f.repo, output: f.output("missing"), product: "alpha" })).toThrow("Missing committed dependency");
    expect(existsSync(f.output("missing"))).toBe(false);
  });
  test("rejects a committed symlink without following its target", () => {
    const f = fixture();
    const blob = git(f.repo, ["hash-object", "-w", "--stdin"], "../../outside-private-file").toString().trim();
    git(f.repo, ["update-index", "--add", "--cacheinfo", `120000,${blob},alpha/link`]);
    git(f.repo, ["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-qm", "link"]);
    expect(() => buildRelease({ repo: f.repo, output: f.output(), product: "alpha" })).toThrow("Unsupported tracked file mode");
  });
  test("fixed refs retain earlier committed content; output junctions are refused", () => {
    const f = fixture();
    write(f.repo, "alpha/helper.psm1", "a newer committed helper\n"); commit(f.repo);
    buildRelease({ repo: f.repo, output: f.output(), product: "alpha", ref: f.sha });
    expect(zipFiles(f.output(), "alpha-1.2.3.zip").get("alpha-1.2.3/alpha/helper.psm1")!.data.toString()).toContain("Get-Example");
    mkdirSync(f.output("target")); symlinkSync(f.output("target"), f.output("junction"), "junction");
    expect(() => buildRelease({ repo: f.repo, output: path.join(f.output("junction"), "new"), product: "alpha" })).toThrow("Symlink/junction");
    expect(readdirSync(f.output("target"))).toEqual([]);
  });
  test("linked worktrees cannot write release output into neighboring Git metadata", () => {
    const f = fixture(), worktree = path.join(f.repo, ".git", "managed", "worktree");
    git(f.repo, ["worktree", "add", "--detach", worktree, f.sha]);
    expect(() => buildRelease({ repo: worktree, output: path.join(f.repo, ".git", "objects", "release"), product: "alpha" })).toThrow("Git metadata");
    expect(buildRelease({ repo: worktree, output: path.join(worktree, "candidate"), product: "alpha" }).products[0].id).toBe("alpha");
  }, gitIntegrationTimeoutMs);
  if (process.platform === "win32") {
    const aliasRoot = temporary();
    const shortRoot = execFileSync("pwsh", ["-NoProfile", "-NonInteractive", "-Command", "$fso = New-Object -ComObject Scripting.FileSystemObject; [Console]::Write($fso.GetFolder($env:CSFC_TEST_ROOT).ShortPath)"], {
      env: { ...process.env, CSFC_TEST_ROOT: aliasRoot }, windowsHide: true, timeout: 10_000, stdio: ["ignore", "pipe", "pipe"],
    }).toString();
    const aliasAvailable = shortRoot.toLowerCase() !== realpathSync.native(aliasRoot).toLowerCase();
    const name = "Windows directory aliases cannot bypass linked-worktree Git metadata protection";
    test.skipIf(!aliasAvailable)(name + (aliasAvailable ? "" : " (volume exposes no 8.3 alias)"), () => {
      const f = fixture(aliasRoot), worktree = path.join(f.repo, ".git", "managed", "worktree");
      git(f.repo, ["worktree", "add", "--detach", worktree, f.sha]);
      expect(shortRoot.toLowerCase()).not.toBe(realpathSync.native(f.root).toLowerCase());
      const metadata = path.join(f.repo, ".git", "objects"), alias = path.join(shortRoot, "repo", ".git", "objects");
      expect(realpathSync.native(alias)).toBe(realpathSync.native(metadata));
      const output = path.join(alias, "not-yet-created", "release");
      const aliasWorktree = path.join(shortRoot, "repo", ".git", "managed", "worktree");
      expect(() => buildRelease({ repo: aliasWorktree, output, product: "alpha" })).toThrow("Git metadata");
      expect(existsSync(path.join(metadata, "not-yet-created"))).toBe(false);
      expect(() => buildRelease({ repo: worktree, output: aliasWorktree, product: "alpha" })).toThrow("repository");
      expect(buildRelease({ repo: aliasWorktree, output: path.join(aliasWorktree, "candidate", "nested"), product: "alpha" }).products[0].id).toBe("alpha");
      expect(existsSync(path.join(worktree, "candidate", "nested", "alpha-1.2.3.zip"))).toBe(true);
    }, gitIntegrationTimeoutMs);
  }
});

describe("independent product versions", () => {
  test("unrelated committed scripts and runbooks do not change a product ZIP", () => {
    const f = fixture();
    const before = buildRelease({ repo: f.repo, output: f.output("before"), product: "all", ref: f.sha });
    write(f.repo, "beta/inspect.py", "raise RuntimeError('new beta implementation')\n");
    write(f.repo, "beta/README.md", "# Updated beta runbook\n");
    f.catalog.products[1].version = "2.0.2"; write(f.repo, "tools/release/catalog.json", JSON.stringify(f.catalog));
    const head = commit(f.repo), after = buildRelease({ repo: f.repo, output: f.output("after"), product: "all", ref: head });
    const original = readFileSync(path.join(f.output("before"), "alpha-1.2.3.zip"));
    const current = readFileSync(path.join(f.output("after"), "alpha-1.2.3.zip"));
    expect(current.equals(original)).toBe(true);
    expect(after.sourceCommit).toBe(head); expect(before.sourceCommit).not.toBe(after.sourceCommit);
    expect(before.assets.find(asset => asset.id === "bundle")!.sha256).not.toBe(after.assets.find(asset => asset.id === "bundle")!.sha256);
    const metadata = verifyProductArchive(current, after.products.find(product => product.id === "alpha")!);
    expect(metadata.releaseTag).toBe("alpha/v1.2.3"); expect(metadata.sourceContentSha256).toMatch(/^[a-f0-9]{64}$/);
    expect("sourceCommit" in metadata).toBe(false);
    const report = checkVersionChanges(f.repo, f.sha, head);
    expect(report.engineChanged).toBe(false);
    expect(report.products.find(product => product.id === "alpha")).toEqual({ id: "alpha", baseVersion: "1.2.3", version: "1.2.3", contentChanged: false, versionChanged: false });
    expect(report.products.find(product => product.id === "beta")!.contentChanged).toBe(true);
  }, gitIntegrationTimeoutMs);
  test("runtime and runbook edits each require a product version increase", () => {
    const f = fixture();
    write(f.repo, "alpha/inspect.ps1", "throw 'changed runtime'\n");
    const runtime = commit(f.repo);
    expect(() => checkVersionChanges(f.repo, f.sha, runtime)).toThrow("payload changed without a version increase: alpha");
    f.catalog.products[0].version = "1.2.4"; write(f.repo, "tools/release/catalog.json", JSON.stringify(f.catalog));
    const bumpedRuntime = commit(f.repo);
    expect(checkVersionChanges(f.repo, f.sha, bumpedRuntime).products[0].contentChanged).toBe(true);
    write(f.repo, "alpha/README.md", "# Corrected alpha instructions\n");
    const runbook = commit(f.repo);
    expect(() => checkVersionChanges(f.repo, bumpedRuntime, runbook)).toThrow("payload changed without a version increase: alpha");
    f.catalog.products[0].version = "1.2.5"; write(f.repo, "tools/release/catalog.json", JSON.stringify(f.catalog));
    expect(checkVersionChanges(f.repo, bumpedRuntime, commit(f.repo)).products[0].version).toBe("1.2.5");
  }, gitIntegrationTimeoutMs);
  test("semantic precedence rejects downgrades and build-only bumps for changed inputs", () => {
    expect(Bun.semver.order("1.10.0", "1.2.0")).toBeGreaterThan(0);
    expect(Bun.semver.order("1.0.0-alpha.1", "1.0.0-alpha.beta")).toBeLessThan(0);
    expect(Bun.semver.order("1.0.0-rc.1", "1.0.0")).toBeLessThan(0);
    expect(Bun.semver.order("1.0.0+first", "1.0.0+second")).toBe(0);
    const f = fixture();
    f.catalog.products[0].version = "1.2.2"; write(f.repo, "tools/release/catalog.json", JSON.stringify(f.catalog));
    expect(() => checkVersionChanges(f.repo, f.sha, commit(f.repo))).toThrow("went backwards: alpha");
    f.catalog.products[0].version = "1.2.3+changed"; write(f.repo, "tools/release/catalog.json", JSON.stringify(f.catalog));
    write(f.repo, "alpha/helper.psm1", "changed helper\n");
    expect(() => checkVersionChanges(f.repo, f.sha, commit(f.repo))).toThrow("payload changed without a version increase");
  }, gitIntegrationTimeoutMs);
  test("first catalog introduction is allowed and metadata/shared dependency changes are checked", () => {
    const f = fixture();
    git(f.repo, ["update-index", "--force-remove", "tools/release/catalog.json"]);
    git(f.repo, ["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-qm", "before catalog"]);
    const base = git(f.repo, ["rev-parse", "HEAD"]).toString().trim();
    write(f.repo, "tools/release/package.ts", "// First packaging engine\n");
    const introduced = commit(f.repo), introduction = checkVersionChanges(f.repo, base, introduced);
    expect(introduction.catalogIntroduced).toBe(true); expect(introduction.engineChanged).toBe(true);
    f.catalog.products[0].name = "Renamed alpha"; write(f.repo, "tools/release/catalog.json", JSON.stringify(f.catalog));
    expect(() => checkVersionChanges(f.repo, introduced, commit(f.repo))).toThrow("payload changed without a version increase: alpha");
    f.catalog.products[0].name = "Alpha inspection"; write(f.repo, "tools/release/catalog.json", JSON.stringify(f.catalog));
    write(f.repo, "docs/safety.md", "# Updated shared safety instructions\n");
    expect(() => checkVersionChanges(f.repo, introduced, commit(f.repo))).toThrow("payload changed without a version increase");
  }, gitIntegrationTimeoutMs);
  test("changed, added or removed build-engine files require every existing product version to advance", () => {
    const f = fixture();
    write(f.repo, "tools/release/package.ts", "// Original package template\n");
    write(f.repo, "tools/release/zip.ts", "// Original ZIP engine\n");
    const engineBase = commit(f.repo);
    expect(() => checkVersionChanges(f.repo, f.sha, engineBase)).toThrow("Packaging engine changed without a version increase");
    write(f.repo, "tools/release/package.ts", "// Changed package template\n");
    expect(() => checkVersionChanges(f.repo, engineBase, commit(f.repo))).toThrow("Packaging engine changed without a version increase: alpha");
    f.catalog.products[0].version = "1.2.4"; write(f.repo, "tools/release/catalog.json", JSON.stringify(f.catalog));
    expect(() => checkVersionChanges(f.repo, engineBase, commit(f.repo))).toThrow("Packaging engine changed without a version increase: beta");
    f.catalog.products[1].version = "2.0.2"; write(f.repo, "tools/release/catalog.json", JSON.stringify(f.catalog));
    const allBumped = commit(f.repo), report = checkVersionChanges(f.repo, engineBase, allBumped);
    expect(report.engineChanged).toBe(true);
    expect(report.products.every(product => product.versionChanged && !product.contentChanged)).toBe(true);
    git(f.repo, ["update-index", "--force-remove", "tools/release/zip.ts"]);
    git(f.repo, ["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-qm", "remove ZIP engine"]);
    const removed = git(f.repo, ["rev-parse", "HEAD"]).toString().trim();
    expect(() => checkVersionChanges(f.repo, allBumped, removed)).toThrow("Packaging engine changed without a version increase");
  }, gitIntegrationTimeoutMs);
});

describe("untrusted artifact verification", () => {
  test("detects ZIP data damage, checksums changed, unexpected files and duplicate assets", () => {
    const f = fixture(); buildRelease({ repo: f.repo, output: f.output(), product: "alpha" });
    const filename = path.join(f.output(), "alpha-1.2.3.zip"), original = readFileSync(filename), damaged = Buffer.from(original);
    const offset = damaged.indexOf(Buffer.from("must never run")); expect(offset).toBeGreaterThan(0); damaged[offset] ^= 1;
    expect(() => readZip(damaged)).toThrow("CRC");
    writeFileSync(filename, damaged); expect(() => verifyOutput(f.output())).toThrow("SHA-256"); writeFileSync(filename, original);
    writeFileSync(path.join(f.output(), "unexpected.txt"), "unexpected"); expect(() => verifyOutput(f.output())).toThrow("inventory");
    const second = f.output("duplicate"); buildRelease({ repo: f.repo, output: second, product: "all" });
    const manifest = JSON.parse(readFileSync(path.join(second, "release.json"), "utf8")); manifest.assets[1] = manifest.assets[0];
    writeFileSync(path.join(second, "release.json"), JSON.stringify(manifest)); refreshOuterHashes(second);
    expect(() => verifyOutput(second)).toThrow("Duplicate release asset");
  });
  test("detects payload tampering even when outer ZIP hashes and CRCs are recalculated", () => {
    const f = fixture(); buildRelease({ repo: f.repo, output: f.output(), product: "alpha" });
    replaceZip(f.output(), "alpha-1.2.3.zip", files => files.set("alpha-1.2.3/alpha/helper.psm1", { data: Buffer.from("tampered") }));
    refreshOuterHashes(f.output());
    expect(() => verifyOutput(f.output())).toThrow("SHA-256 mismatch: alpha/helper.psm1");
  });
  test("validates nested bundle ZIPs after outer checksums are recalculated", () => {
    const f = fixture(); buildRelease({ repo: f.repo, output: f.output(), product: "bundle", bundleProducts: ["alpha"] });
    replaceZip(f.output(), "bundle-0.1.0.zip", files => {
      const nested = files.get("bundle-0.1.0/alpha-1.2.3.zip")!.data;
      const inner = readZip(nested);
      inner.set("alpha-1.2.3/alpha/helper.psm1", { data: Buffer.from("tampered nested helper") });
      const changed = createZip(inner);
      files.set("bundle-0.1.0/alpha-1.2.3.zip", { data: changed });
      const manifest = JSON.parse(files.get("bundle-0.1.0/BUNDLE.json")!.data.toString());
      manifest.products[0].sha256 = sha256(changed); manifest.products[0].size = changed.length;
      files.set("bundle-0.1.0/BUNDLE.json", { data: Buffer.from(JSON.stringify(manifest)) });
      const sums = [...files].filter(([name]) => !name.endsWith("/SHA256SUMS.txt")).sort(([a], [b]) => a < b ? -1 : 1).map(([name, file]) => `${sha256(file.data)}  ${name.slice("bundle-0.1.0/".length)}\n`).join("");
      files.set("bundle-0.1.0/SHA256SUMS.txt", { data: Buffer.from(sums) });
    });
    refreshOuterHashes(f.output());
    expect(() => verifyOutput(f.output())).toThrow("SHA-256 mismatch: alpha/helper.psm1");
  });
  test("rejects malformed and duplicate checksum entries", () => {
    const f = fixture(); buildRelease({ repo: f.repo, output: f.output(), product: "alpha" });
    const checksumPath = path.join(f.output(), "SHA256SUMS.txt"), sums = readFileSync(checksumPath, "utf8");
    writeFileSync(checksumPath, sums + sums.split("\n")[0] + "\n");
    expect(() => verifyOutput(f.output())).toThrow("Duplicate checksum path");
    writeFileSync(checksumPath, sums.replace(/^[0-9a-f]/, "z"));
    expect(() => verifyOutput(f.output())).toThrow("Invalid checksum manifest line");
  });
  test("rejects unsafe ZIP entries, unsupported symlink modes and truncated structures", () => {
    const valid = createZip(new Map([["root/file.txt", { data: Buffer.from("fixture") }]]));
    expect(crc32(Buffer.from("123456789"))).toBe(0xcbf43926);
    expect(() => createZip(new Map([["../escape", { data: Buffer.from("bad") }]]))).toThrow();
    expect(() => createZip(new Map([["safe", { data: Buffer.from("bad"), mode: 0o120000 }]]))).toThrow();
    expect(() => createZip(new Map([["Root/file", { data: Buffer.alloc(0) }], ["root/FILE", { data: Buffer.alloc(0) }]]))).toThrow("colliding");
    expect(() => readZip(valid.subarray(0, valid.length - 1))).toThrow();
    const traversal = Buffer.from(valid);
    for (let offset = traversal.indexOf("root/file.txt"); offset >= 0; offset = traversal.indexOf("root/file.txt", offset + 1)) traversal.write("../x/file.txt", offset);
    expect(() => readZip(traversal)).toThrow("Unsafe");
    const symlink = Buffer.from(valid), central = symlink.indexOf(Buffer.from([0x50, 0x4b, 0x01, 0x02]));
    symlink.writeUInt32LE((0o120777 * 65536) >>> 0, central + 38); expect(() => readZip(symlink)).toThrow();
  });
});

test("all 18 real entrypoints package; KRBTGT bytes and original hashes survive independent extraction", () => {
  const root = temporary(), repo = path.join(root, "repo"), output = path.join(root, "release"), extracted = path.join(root, "extracted");
  mkdirSync(repo); git(repo, ["init", "-q"]); git(repo, ["config", "core.autocrlf", "false"]);
  const records = git(sourceRepo, ["ls-tree", "-r", "-z", "HEAD"]).toString().split("\0").filter(Boolean);
  for (const record of records) {
    const match = /^(\d+) blob ([0-9a-f]+)\t(.+)$/.exec(record)!;
    if (match) write(repo, match[3], git(sourceRepo, ["cat-file", "blob", match[2]]));
  }
  // This test seeds an isolated committed fixture with the catalog under test.
  // The production builder still reads both catalog and all payloads only from Git.
  write(repo, "tools/release/catalog.json", readFileSync(path.join(import.meta.dir, "catalog.json"))); commit(repo);
  const result = buildRelease({ repo, output, product: "all" });
  expect(result.products).toHaveLength(18); expect(result.assets).toHaveLength(19);
  for (const product of result.products) {
    const bytes = readFileSync(path.join(output, `${product.id}-${product.version}.zip`));
    const manifest = verifyProductArchive(bytes, product);
    expect(manifest.files.some(file => file.path === product.entrypoint)).toBe(true);
  }
  const zip = path.join(output, "krbtgt-reset-0.1.1.zip");
  // Independent, standard ZIP extraction validates the writer beyond its own reader.
  execFileSync("pwsh", ["-NoProfile", "-NonInteractive", "-Command", "Expand-Archive -LiteralPath $env:CSFC_TEST_ZIP -DestinationPath $env:CSFC_TEST_EXTRACT -ErrorAction Stop"], {
    env: { ...process.env, CSFC_TEST_ZIP: zip, CSFC_TEST_EXTRACT: extracted }, windowsHide: true, stdio: ["ignore", "pipe", "pipe"],
  });
  const payload = path.join(extracted, "krbtgt-reset-0.1.1", "windows", "reset-krbtgt");
  const preserved = new Map<string, ZipFile>();
  for (const name of readFileSync(path.join(payload, "release-manifest.txt"), "utf8").split(/\r?\n/).filter(Boolean)) {
    const full = path.join(payload, name); expect(lstatSync(full).isFile()).toBe(true);
    const data = readFileSync(full); preserved.set(`windows/reset-krbtgt/${name}`, { data });
    expect(data.equals(readFileSync(path.join(repo, "windows", "reset-krbtgt", name)))).toBe(true);
  }
  expect(verifyPreservedPackage(preserved, "windows/reset-krbtgt").length).toBeGreaterThan(20);
  // Only the imported integrity verifier executes; operational entrypoints do not.
  const verification = execFileSync("pwsh", ["-NoProfile", "-NonInteractive", "-File", path.join(payload, "tools", "Test-ReleaseHashes.ps1"), "-RootPath", payload], { windowsHide: true, stdio: ["ignore", "pipe", "pipe"] }).toString();
  expect(verification).toContain("Succeeded");
  preserved.get("windows/reset-krbtgt/KrbtgtRotation/KrbtgtRotation.psm1")!.data = Buffer.from("tampered module");
  expect(() => verifyPreservedPackage(preserved, "windows/reset-krbtgt")).toThrow("hash mismatch");
}, 120_000);
