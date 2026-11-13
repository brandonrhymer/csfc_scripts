import { execFileSync } from "node:child_process";
import { existsSync, lstatSync, mkdirSync, readFileSync, readdirSync, realpathSync, writeFileSync } from "node:fs";
import path from "node:path";
import { compare, createZip, readZip, safePath, sha256, uniquePaths, type ZipFile } from "./zip";

export type Product = { id: string; name: string; version: string; entrypoint: string; runbook: string; files: string[]; preservedPackage?: string };
export type Catalog = { schemaVersion: 1; bundleVersion: string; sharedFiles: string[]; products: Product[] };
export type ProductSummary = Pick<Product, "id" | "name" | "version" | "entrypoint" | "runbook">;
export type Asset = { kind: "product" | "bundle"; id: string; version: string; tag: string; file: string; sha256: string; size: number; products: { id: string; version: string }[] };
export type ReleaseManifest = {
  schemaVersion: 1; sourceCommit: string;
  selection: { product: string; bundleProducts: string[]; bundleVersion: string | null };
  products: ProductSummary[]; assets: Asset[];
};
export type BuildOptions = { output: string; product: string; bundleProducts?: string[]; bundleVersion?: string; ref?: string; repo?: string };
type SourceFile = ZipFile & { oid: string };
type PayloadFile = { path: string; sha256: string; mode: number };
type ProductManifest = ProductSummary & { schemaVersion: 1; releaseTag: string; sourceContentSha256: string; preservedPackage?: string; files: PayloadFile[] };
export type VersionChanges = {
  baseCommit: string; headCommit: string; catalogIntroduced: boolean; engineChanged: boolean;
  products: { id: string; baseVersion: string | null; version: string; contentChanged: boolean; versionChanged: boolean }[];
};

function assert(condition: unknown, message: string): asserts condition { if (!condition) throw new Error(message); }
function json(value: unknown) { return Buffer.from(JSON.stringify(value, null, 2) + "\n"); }
function parseJson(bytes: Buffer, name: string): any {
  try { return JSON.parse(bytes.toString("utf8")); } catch { throw new Error(`Invalid JSON: ${name}`); }
}
export function validateId(id: unknown): asserts id is string {
  assert(typeof id === "string" && id.length <= 80 && /^[a-z][a-z0-9]*(?:-[a-z0-9]+)*$/.test(id), `Invalid product ID: ${String(id)}`);
}
export function validateVersion(version: unknown): asserts version is string {
  assert(typeof version === "string" && version.length <= 80 && /^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-((?:0|[1-9]\d*|\d*[A-Za-z-][0-9A-Za-z-]*)(?:\.(?:0|[1-9]\d*|\d*[A-Za-z-][0-9A-Za-z-]*))*))?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$/.test(version), `Invalid semantic version: ${String(version)}`);
}
function validateCommit(commit: unknown): asserts commit is string {
  assert(typeof commit === "string" && /^(?:[0-9a-f]{40}|[0-9a-f]{64})$/.test(commit), "Source ref must be an exact full commit ID");
}
function validateSummary(product: any): asserts product is ProductSummary {
  assert(product && typeof product === "object", "Invalid product record");
  validateId(product.id); validateVersion(product.version);
  assert(!["all", "bundle"].includes(product.id), `Reserved product ID: ${product.id}`);
  assert(typeof product.name === "string" && product.name.trim().length > 0 && !/[\x00-\x1f]/.test(product.name), "Invalid product name");
  safePath(product.entrypoint); safePath(product.runbook);
  assert(/\.(ps1|py|sh)$/.test(product.entrypoint) && product.runbook.endsWith(".md"), "Product needs an operational entrypoint and Markdown runbook");
}
export function validateCatalog(value: unknown): Catalog {
  const catalog = value as Catalog;
  assert(catalog && catalog.schemaVersion === 1 && Array.isArray(catalog.products) && catalog.products.length > 0, "Invalid catalog schema");
  validateVersion(catalog.bundleVersion);
  assert(Array.isArray(catalog.sharedFiles), "Missing sharedFiles"); uniquePaths(catalog.sharedFiles);
  const ids = new Set<string>(), entrypoints = new Set<string>();
  for (const product of catalog.products) {
    validateSummary(product);
    assert(!ids.has(product.id), `Duplicate product ID: ${product.id}`); ids.add(product.id);
    assert(!entrypoints.has(product.entrypoint.toLowerCase()), `Duplicate entrypoint: ${product.entrypoint}`); entrypoints.add(product.entrypoint.toLowerCase());
    assert(Array.isArray(product.files), `Missing dependencies: ${product.id}`); uniquePaths(product.files);
    if (product.preservedPackage !== undefined) safePath(product.preservedPackage);
  }
  return catalog;
}

function git(repo: string, args: string[], input?: Buffer | string): Buffer {
  return execFileSync("git", ["--no-replace-objects", "-C", repo, ...args], {
    input, maxBuffer: 128 * 1024 * 1024, windowsHide: true, stdio: ["pipe", "pipe", "pipe"],
  });
}
function snapshot(repo: string, ref?: string) {
  if (ref !== undefined) validateCommit(ref);
  const commit = git(repo, ["rev-parse", "--verify", `${ref ?? "HEAD"}^{commit}`]).toString().trim();
  validateCommit(commit);
  assert(ref === undefined || ref === commit, "Explicit ref must identify a commit object, not a tag object");
  const treeBytes = git(repo, ["ls-tree", "-r", "-z", "--full-tree", commit]);
  assert(Buffer.from(treeBytes.toString("utf8")).equals(treeBytes), "Non-UTF-8 tracked paths are unsupported");
  const records = treeBytes.toString("utf8").split("\0").filter(Boolean);
  const index = new Map<string, { oid: string; mode: number }>();
  for (const record of records) {
    const match = /^(\d+) (\w+) ([0-9a-f]+)\t([\s\S]+)$/.exec(record);
    assert(match, "Invalid git tree record");
    const [, mode, kind, oid, name] = match;
    safePath(name);
    // Reject submodules and links even when they are outside the selected product.
    assert(kind === "blob" && ["100644", "100755"].includes(mode), `Unsupported tracked file mode: ${name}`);
    index.set(name, { oid, mode: Number.parseInt(mode, 8) });
  }
  uniquePaths([...index.keys()]);
  const cache = new Map<string, SourceFile>();
  const get = (name: string): SourceFile => {
    safePath(name);
    const entry = index.get(name);
    assert(entry, `Missing committed dependency: ${name}`);
    if (!cache.has(name)) cache.set(name, { ...entry, data: git(repo, ["cat-file", "blob", entry.oid]) });
    return cache.get(name)!;
  };
  return { commit, index, get };
}

export function selectProducts(catalog: Catalog, product: string, requested?: string[]): Product[] {
  assert(product === "all" || product === "bundle" || catalog.products.some(item => item.id === product), `Unknown product ID: ${product}`);
  assert(requested === undefined || product === "bundle", "--bundle-products requires --product bundle");
  const ids = requested ?? (product === "all" || product === "bundle" ? catalog.products.map(item => item.id) : [product]);
  assert(ids.length > 0 && new Set(ids).size === ids.length, "Empty or duplicate product selection");
  for (const id of ids) { validateId(id); assert(catalog.products.some(item => item.id === id), `Unknown product ID: ${id}`); }
  return catalog.products.filter(item => ids.includes(item.id)).sort((a, b) => compare(a.id, b.id));
}
const summary = ({ id, name, version, entrypoint, runbook }: ProductSummary): ProductSummary => ({ id, name, version, entrypoint, runbook });

function parseChecksums(bytes: Buffer) {
  const entries = new Map<string, string>();
  const lines = bytes.toString("utf8").split(/\r?\n/);
  if (lines.at(-1) === "") lines.pop();
  assert(lines.length > 0, "Empty checksum manifest");
  for (const line of lines) {
    const match = /^([0-9a-fA-F]{64})  (.+)$/.exec(line);
    assert(match, "Invalid checksum manifest line"); safePath(match[2]);
    assert(!entries.has(match[2]), `Duplicate checksum path: ${match[2]}`);
    entries.set(match[2], match[1].toLowerCase());
  }
  uniquePaths([...entries.keys()]);
  return entries;
}
function checksums(files: Map<string, ZipFile>) {
  return Buffer.from([...files.keys()].sort(compare).map(name => `${sha256(files.get(name)!.data)}  ${name}\n`).join(""));
}
function verifyChecksums(files: Map<string, ZipFile>, checksumPath = "SHA256SUMS.txt") {
  assert(files.has(checksumPath), `Missing checksum manifest: ${checksumPath}`);
  const expected = parseChecksums(files.get(checksumPath)!.data);
  const actualNames = [...files.keys()].filter(name => name !== checksumPath).sort(compare);
  assert(JSON.stringify([...expected.keys()].sort(compare)) === JSON.stringify(actualNames), "Checksum inventory does not match files");
  for (const [name, hash] of expected) assert(sha256(files.get(name)!.data) === hash, `SHA-256 mismatch: ${name}`);
}

export function verifyPreservedPackage(files: Map<string, ZipFile>, root: string): string[] {
  safePath(root);
  const manifest = files.get(`${root}/release-manifest.txt`), hashes = files.get(`${root}/SHA256SUMS.txt`);
  assert(manifest && hashes, `Missing preserved manifest/checksums: ${root}`);
  const paths = manifest.data.toString("utf8").split(/\r?\n/).filter(Boolean);
  uniquePaths(paths);
  assert(paths.includes("release-manifest.txt") && paths.includes("SHA256SUMS.txt"), "Preserved manifest must include itself and checksums");
  const expected = parseChecksums(hashes.data);
  assert(JSON.stringify([...expected.keys()].sort(compare)) === JSON.stringify(paths.filter(name => name !== "SHA256SUMS.txt").sort(compare)), "Preserved manifest/checksum inventory mismatch");
  for (const name of paths) {
    const file = files.get(`${root}/${name}`);
    assert(file, `Missing preserved dependency: ${root}/${name}`);
    if (name !== "SHA256SUMS.txt") assert(sha256(file.data) === expected.get(name), `Preserved package hash mismatch: ${name}`);
  }
  return paths.map(name => `${root}/${name}`);
}

function productFiles(source: ReturnType<typeof snapshot>, catalog: Catalog, product: Product) {
  const names = new Set([...catalog.sharedFiles, product.entrypoint, product.runbook, ...product.files]);
  if (product.preservedPackage) {
    const root = product.preservedPackage;
    const manifest = source.get(`${root}/release-manifest.txt`).data.toString("utf8").split(/\r?\n/).filter(Boolean);
    uniquePaths(manifest);
    for (const name of manifest) names.add(`${root}/${name}`);
  }
  // Dependencies are explicit: cross-product links in a runbook must not silently
  // add unrelated files or couple every product's version to the whole repository.
  const files = new Map([...names].sort(compare).map(name => [name, source.get(name)]));
  if (product.preservedPackage) verifyPreservedPackage(files, product.preservedPackage);
  return files;
}
function payloadInventory(files: Map<string, ZipFile>): PayloadFile[] {
  return [...files].sort(([a], [b]) => compare(a, b)).map(([name, file]) => ({ path: name, sha256: sha256(file.data), mode: file.mode! }));
}
function contentDigest(product: ProductSummary & { preservedPackage?: string }, files: PayloadFile[]): string {
  const { id, name, entrypoint, runbook, preservedPackage } = product;
  return sha256(json({
    schemaVersion: 1, id, name, entrypoint, runbook,
    ...(preservedPackage ? { preservedPackage } : {}),
    files: [...files].sort((a, b) => compare(a.path, b.path)).map(({ path, sha256, mode }) => ({ path, sha256, mode })),
  }));
}

/** Enforce independent product versions using only fixed committed catalog inputs. */
export function checkVersionChanges(repo: string, baseSha: string, headSha: string): VersionChanges {
  const base = snapshot(path.resolve(repo), baseSha), head = snapshot(path.resolve(repo), headSha);
  const catalogPath = "tools/release/catalog.json";
  const headCatalog = validateCatalog(parseJson(head.get(catalogPath).data, catalogPath));
  const baseCatalog = base.index.has(catalogPath) ? validateCatalog(parseJson(base.get(catalogPath).data, catalogPath)) : undefined;
  // These files are the complete product-build engine dependency set. Comparing
  // their committed blobs/modes also detects additions and removals. Conservatively
  // require all existing versions to advance rather than execute historical code
  // to discover whether a template or ZIP-engine edit changes emitted bytes.
  const engineChanged = ["tools/release/package.ts", "tools/release/zip.ts"].some(name => {
    const before = base.index.get(name), after = head.index.get(name);
    return before?.oid !== after?.oid || before?.mode !== after?.mode;
  });
  const products = [...headCatalog.products].sort((a, b) => compare(a.id, b.id)).map(product => {
    const headDigest = contentDigest(product, payloadInventory(productFiles(head, headCatalog, product)));
    const previous = baseCatalog?.products.find(item => item.id === product.id);
    if (!previous) return { id: product.id, baseVersion: null, version: product.version, contentChanged: true, versionChanged: true };
    const baseDigest = contentDigest(previous, payloadInventory(productFiles(base, baseCatalog!, previous)));
    const order = Bun.semver.order(product.version, previous.version);
    assert(order >= 0, `Product version went backwards: ${product.id} ${previous.version} -> ${product.version}`);
    assert(!engineChanged || order > 0, `Packaging engine changed without a version increase: ${product.id} (${previous.version} -> ${product.version})`);
    const contentChanged = baseDigest !== headDigest;
    assert(!contentChanged || order > 0, `Product payload changed without a version increase: ${product.id} (${previous.version} -> ${product.version})`);
    return { id: product.id, baseVersion: previous.version, version: product.version, contentChanged, versionChanged: product.version !== previous.version };
  });
  return { baseCommit: base.commit, headCommit: head.commit, catalogIntroduced: !baseCatalog, engineChanged, products };
}

function productArchive(source: ReturnType<typeof snapshot>, catalog: Catalog, product: Product) {
  const files: Map<string, ZipFile> = productFiles(source, catalog, product);
  const inventory = payloadInventory(files);
  const metadata: ProductManifest = {
    schemaVersion: 1, ...summary(product), releaseTag: `${product.id}/v${product.version}`,
    sourceContentSha256: contentDigest(product, inventory),
    ...(product.preservedPackage ? { preservedPackage: product.preservedPackage } : {}),
    files: inventory,
  };
  for (const reserved of ["PRODUCT.json", "START-HERE.md", "SHA256SUMS.txt"]) assert(!files.has(reserved), `Reserved package path: ${reserved}`);
  files.set("PRODUCT.json", { data: json(metadata) });
  files.set("START-HERE.md", { data: Buffer.from(
    `# ${product.name} ${product.version}\n\n` +
    `Read [the product runbook](${product.runbook}) before using [${product.entrypoint}](${product.entrypoint}).\n\n` +
    `Release identity: \`${metadata.releaseTag}\`. Source-content SHA-256: \`${metadata.sourceContentSha256}\`.\n\n` +
    `The exact build commit and archive checksums are recorded in the accompanying release.json and release provenance; retain them with this download. A bundle also records its build commit in BUNDLE.json. Product bytes are stable when their version and explicit contents are unchanged.\n\n` +
    `Extract the entire ZIP and preserve its directories. Follow the runbook's working-directory and prerequisite instructions. Bun, Git and a source checkout are not needed to operate this download. Operating-system dependencies, approved vendor packages and private inputs described in the runbook are supplied separately.\n\n` +
    `Only the named product and its explicitly declared dependencies and supporting documentation are included. Links in source documentation to other products or development material may require the [full source repository](https://github.com/brandonrhymer/csfc_scripts); they are not additional files in this download. The product's own runbook and required runtime dependencies are included for offline use. KRBTGT products include the complete shared rotation workflow because its entrypoints, module, verification tools and original hashes belong together. No scripts run automatically.\n\n` +
    `PRODUCT.json records the committed payload paths, SHA-256 hashes and modes. SHA256SUMS.txt covers every file except itself. Verify the downloaded ZIP against independently obtained release checksums before extraction; checksums detect changed bytes but do not establish publisher trust or approval.\n\n` +
    `This package build verifies packaging and integrity only. Read the included validation records and known limitations; a successful build is not operational or lab validation.\n`
  ) });
  files.set("SHA256SUMS.txt", { data: checksums(files) });
  const prefix = `${product.id}-${product.version}/`;
  return createZip(new Map([...files].map(([name, file]) => [prefix + name, file])));
}

function unpack(bytes: Buffer, prefix: string) {
  const files = readZip(bytes), result = new Map<string, ZipFile>();
  for (const [name, file] of files) {
    assert(name.startsWith(prefix + "/"), `Unexpected archive root: ${name}`);
    result.set(name.slice(prefix.length + 1), file);
  }
  uniquePaths([...result.keys()]); verifyChecksums(result);
  return result;
}
export function verifyProductArchive(bytes: Buffer, expected: ProductSummary): ProductManifest {
  validateSummary(expected);
  const files = unpack(bytes, `${expected.id}-${expected.version}`);
  assert(files.has("PRODUCT.json") && files.has("START-HERE.md"), "Missing product metadata/start guide");
  const metadata = parseJson(files.get("PRODUCT.json")!.data, "PRODUCT.json") as ProductManifest;
  assert(metadata.schemaVersion === 1 && metadata.releaseTag === `${expected.id}/v${expected.version}` && !("sourceCommit" in metadata) && JSON.stringify(summary(metadata)) === JSON.stringify(summary(expected)), "Product metadata mismatch");
  assert(Array.isArray(metadata.files) && metadata.files.length > 0, "Empty product file inventory");
  uniquePaths(metadata.files.map(file => file.path));
  const actualNames = [...files.keys()].filter(name => !["PRODUCT.json", "START-HERE.md", "SHA256SUMS.txt"].includes(name)).sort(compare);
  assert(JSON.stringify(metadata.files.map(file => file.path).sort(compare)) === JSON.stringify(actualNames), "Product payload inventory mismatch");
  for (const item of metadata.files) {
    const file = files.get(item.path)!;
    assert(file.mode === item.mode && sha256(file.data) === item.sha256, `Product payload mismatch: ${item.path}`);
  }
  assert(metadata.sourceContentSha256 === contentDigest(metadata, metadata.files), "Product source-content digest mismatch");
  assert(files.has(expected.entrypoint) && files.has(expected.runbook), "Missing product entrypoint/runbook");
  if (metadata.preservedPackage) verifyPreservedPackage(files, metadata.preservedPackage);
  return metadata;
}

function bundleArchive(products: ProductSummary[], archives: Map<string, Buffer>, version: string, commit: string) {
  const files = new Map<string, ZipFile>();
  const entries = products.map(product => {
    const file = `${product.id}-${product.version}.zip`, data = archives.get(product.id)!;
    files.set(file, { data });
    return { ...product, file, sha256: sha256(data), size: data.length };
  });
  files.set("BUNDLE.json", { data: json({ schemaVersion: 1, id: "bundle", version, sourceCommit: commit, products: entries }) });
  files.set("START-HERE.md", { data: Buffer.from(`# Administration script bundle ${version}\n\nSource commit: \`${commit}\`.\n\nThis bundle is a collection of independent product ZIPs. Select and extract only the product you need, then read its START-HERE.md and runbook. Do not execute every script as a batch. No Bun, Git or source checkout is required.\n\nBUNDLE.json lists the exact included product versions, ZIP sizes and SHA-256 hashes. SHA256SUMS.txt covers the bundle contents. Product ZIPs carry their own payload manifests and checksums. These integrity checks do not establish deployment readiness.\n\n${entries.map(item => `- ${item.name}: \`${item.id}\` version \`${item.version}\` (${item.file})`).join("\n")}\n`) });
  files.set("SHA256SUMS.txt", { data: checksums(files) });
  return createZip(new Map([...files].map(([name, file]) => [`bundle-${version}/${name}`, file])));
}
function verifyBundleArchive(bytes: Buffer, expected: ProductSummary[], version: string, commit: string) {
  const files = unpack(bytes, `bundle-${version}`);
  assert(files.has("BUNDLE.json") && files.has("START-HERE.md"), "Missing bundle metadata/start guide");
  const metadata = parseJson(files.get("BUNDLE.json")!.data, "BUNDLE.json");
  assert(metadata.schemaVersion === 1 && metadata.id === "bundle" && metadata.version === version && metadata.sourceCommit === commit && Array.isArray(metadata.products), "Bundle metadata mismatch");
  assert(metadata.products.length === expected.length && files.size === expected.length + 3, "Bundle inventory mismatch");
  for (let index = 0; index < expected.length; index++) {
    const product = expected[index], item = metadata.products[index];
    assert(JSON.stringify(summary(item)) === JSON.stringify(product) && item.file === `${product.id}-${product.version}.zip`, "Bundle product mismatch");
    const data = files.get(item.file)?.data;
    assert(data && data.length === item.size && sha256(data) === item.sha256, `Bundle product checksum mismatch: ${item.file}`);
    verifyProductArchive(data, product);
  }
}

function assertNoSymlinkAncestors(target: string) {
  let current = path.resolve(target);
  while (true) {
    if (existsSync(current)) assert(!lstatSync(current).isSymbolicLink(), `Symlink/junction path refused: ${current}`);
    const parent = path.dirname(current); if (parent === current) break; current = parent;
  }
}
function canonicalPath(target: string) {
  let ancestor = path.resolve(target);
  const missing: string[] = [];
  while (!existsSync(ancestor)) {
    const parent = path.dirname(ancestor);
    assert(parent !== ancestor, "Path has no existing filesystem ancestor");
    missing.unshift(path.basename(ancestor));
    ancestor = parent;
  }
  // native realpath expands Windows 8.3 aliases; ordinary realpath preserves
  // those spellings. Resolve the existing ancestor even for a new output tree.
  return path.join(realpathSync.native(ancestor), ...missing);
}
function validateOutput(output: string, repo?: string, requireEmpty = true) {
  assert(typeof output === "string" && output.trim().length > 0, "Output directory is required");
  const requested = path.resolve(output);
  assertNoSymlinkAncestors(requested);
  const resolved = canonicalPath(requested);
  assert(resolved !== path.parse(resolved).root, "Filesystem root is not an output directory");
  if (repo) {
    const root = canonicalPath(repo), relation = path.relative(resolved, root);
    assert(relation.startsWith(".." + path.sep) || relation === ".." || path.isAbsolute(relation), "Output cannot be the repository or its ancestor");
    const relative = path.relative(root, resolved);
    assert(!relative.split(path.sep).some(part => part.toLowerCase() === ".git"), "Output cannot be Git metadata");
    const gitDir = canonicalPath(path.resolve(root, git(root, ["rev-parse", "--git-dir"]).toString().trim()));
    const insideGit = path.relative(gitDir, resolved);
    assert(insideGit.startsWith(".." + path.sep) || insideGit === ".." || path.isAbsolute(insideGit), "Output cannot be Git metadata");
    const commonDir = canonicalPath(path.resolve(root, git(root, ["rev-parse", "--git-common-dir"]).toString().trim()));
    const isWithin = (parent: string, child: string) => {
      const relativePath = path.relative(parent, child);
      return !path.isAbsolute(relativePath) && relativePath !== ".." && !relativePath.startsWith(".." + path.sep);
    };
    // A linked worktree can itself live under the common Git directory. Its own
    // output children are allowed; neighboring object/ref/worktree metadata is not.
    assert(!isWithin(commonDir, resolved) || isWithin(root, resolved), "Output cannot be common Git metadata");
  }
  if (existsSync(resolved)) {
    assert(lstatSync(resolved).isDirectory(), "Output must be a directory");
    if (requireEmpty) assert(readdirSync(resolved).length === 0, "Output directory must be new or empty");
  } else assert(requireEmpty, "Verification directory does not exist");
  return resolved;
}

export function buildRelease(options: BuildOptions): ReleaseManifest {
  const repo = path.resolve(options.repo ?? process.cwd());
  const output = validateOutput(options.output, repo);
  const source = snapshot(repo, options.ref);
  const catalog = validateCatalog(parseJson(source.get("tools/release/catalog.json").data, "catalog.json"));
  const products = selectProducts(catalog, options.product, options.bundleProducts);
  const hasBundle = options.product === "bundle" || options.product === "all";
  assert(options.bundleVersion === undefined || hasBundle, "--bundle-version requires --product bundle or all");
  const bundleVersion = hasBundle ? options.bundleVersion ?? catalog.bundleVersion : null;
  if (bundleVersion !== null) validateVersion(bundleVersion);
  const archives = new Map(products.map(product => [product.id, productArchive(source, catalog, product)]));
  const files = new Map<string, ZipFile>(), assets: Asset[] = [];
  const add = (id: string, version: string, kind: Asset["kind"], data: Buffer, included: ProductSummary[]) => {
    const file = `${id}-${version}.zip`;
    files.set(file, { data });
    assets.push({ kind, id, version, tag: `${id}/v${version}`, file, sha256: sha256(data), size: data.length, products: included.map(({ id, version }) => ({ id, version })) });
  };
  if (options.product !== "bundle") for (const product of products) add(product.id, product.version, "product", archives.get(product.id)!, [product]);
  if (hasBundle) add("bundle", bundleVersion!, "bundle", bundleArchive(products.map(summary), archives, bundleVersion!, source.commit), products);
  const manifest: ReleaseManifest = {
    schemaVersion: 1, sourceCommit: source.commit,
    selection: { product: options.product, bundleProducts: hasBundle ? products.map(product => product.id) : [], bundleVersion },
    products: products.map(summary), assets,
  };
  files.set("release.json", { data: json(manifest) });
  files.set("RELEASE-NOTES.md", { data: Buffer.from(`# Administration script release candidate\n\nSource commit: \`${source.commit}\`.\n\n${assets.map(asset => `- \`${asset.tag}\`: ${asset.file} (SHA-256 \`${asset.sha256}\`)`).join("\n")}\n\nIndividual products have independent versions. Bundles are separately versioned snapshots and may contain selected products. Building a candidate does not create a Git tag, publish a release or execute an operational script.\n\nExtract the selected product and read START-HERE.md and its runbook. Packaging verification covers the committed file inventory, archive structure and integrity; operational and environment validation remain as documented in the included runbooks.\n`) });
  files.set("SHA256SUMS.txt", { data: checksums(files) });
  verifyReleaseFiles(files);
  mkdirSync(output, { recursive: true });
  for (const [name, file] of files) writeFileSync(path.join(output, name), file.data, { flag: "wx" });
  return verifyOutput(output);
}

function verifyReleaseFiles(files: Map<string, ZipFile>): ReleaseManifest {
  verifyChecksums(files);
  assert(files.has("release.json") && files.has("RELEASE-NOTES.md"), "Missing release metadata/notes");
  const manifest = parseJson(files.get("release.json")!.data, "release.json") as ReleaseManifest;
  assert(manifest.schemaVersion === 1 && Array.isArray(manifest.products) && Array.isArray(manifest.assets), "Invalid release schema");
  validateCommit(manifest.sourceCommit);
  assert(manifest.products.length > 0 && new Set(manifest.products.map(product => product.id)).size === manifest.products.length, "Empty/duplicate product records");
  for (const product of manifest.products) validateSummary(product);
  assert(manifest.selection && Array.isArray(manifest.selection.bundleProducts), "Invalid release selection");
  const selector = manifest.selection.product;
  assert(selector === "all" || selector === "bundle" || manifest.products.length === 1 && selector === manifest.products[0].id, "Invalid product selection");
  const hasBundle = selector === "all" || selector === "bundle";
  if (hasBundle) validateVersion(manifest.selection.bundleVersion);
  else assert(manifest.selection.bundleVersion === null, "Unexpected bundle version");
  assert(JSON.stringify(manifest.selection.bundleProducts) === JSON.stringify(hasBundle ? manifest.products.map(product => product.id) : []), "Bundle selection mismatch");
  const expectedAssets = selector === "all" ? manifest.products.length + 1 : 1;
  assert(manifest.assets.length === expectedAssets && files.size === expectedAssets + 3, "Release asset inventory mismatch");
  const seen = new Set<string>();
  for (const asset of manifest.assets) {
    validateId(asset.id); validateVersion(asset.version); safePath(asset.file);
    assert(!seen.has(asset.id), `Duplicate release asset: ${asset.id}`); seen.add(asset.id);
    assert(asset.file === `${asset.id}-${asset.version}.zip` && asset.tag === `${asset.id}/v${asset.version}`, "Asset name/tag mismatch");
    const data = files.get(asset.file)?.data;
    assert(data && data.length === asset.size && sha256(data) === asset.sha256, `Release asset checksum mismatch: ${asset.file}`);
    if (asset.kind === "bundle") {
      assert(hasBundle && asset.id === "bundle" && asset.version === manifest.selection.bundleVersion, "Unexpected bundle asset");
      assert(JSON.stringify(asset.products) === JSON.stringify(manifest.products.map(({ id, version }) => ({ id, version }))), "Bundle asset products mismatch");
      verifyBundleArchive(data, manifest.products, asset.version, manifest.sourceCommit);
    } else {
      assert(asset.kind === "product" && selector !== "bundle", "Unexpected asset kind");
      const product = manifest.products.find(product => product.id === asset.id);
      assert(product && product.version === asset.version && JSON.stringify(asset.products) === JSON.stringify([{ id: product.id, version: product.version }]), "Product asset metadata mismatch");
      verifyProductArchive(data, product);
    }
  }
  assert(!hasBundle || seen.has("bundle"), "Missing bundle asset");
  return manifest;
}

/** Verify a downloaded artifact before release preparation. Integrity is not authentication. */
export function verifyOutput(directory: string): ReleaseManifest {
  const output = validateOutput(directory, undefined, false);
  const files = new Map<string, ZipFile>();
  for (const name of readdirSync(output)) {
    safePath(name);
    const full = path.join(output, name), stat = lstatSync(full);
    assert(stat.isFile() && !stat.isSymbolicLink(), `Unexpected output entry: ${name}`);
    files.set(name, { data: readFileSync(full) });
  }
  uniquePaths([...files.keys()]);
  return verifyReleaseFiles(files);
}

export function parseArgs(args: string[]): BuildOptions | { verify: string } | { help: true } {
  if (args.length === 1 && ["--help", "-h"].includes(args[0])) return { help: true };
  const values = new Map<string, string>();
  for (let index = 0; index < args.length; index += 2) {
    const key = args[index], value = args[index + 1];
    assert(["--output", "--product", "--bundle-products", "--bundle-version", "--ref", "--verify"].includes(key) && value && !value.startsWith("--"), `Invalid/missing argument: ${key}`);
    assert(!values.has(key), `Duplicate option: ${key}`); values.set(key, value);
  }
  if (values.has("--verify")) { assert(values.size === 1, "--verify must be used alone"); return { verify: values.get("--verify")! }; }
  assert(values.has("--output") && values.has("--product"), "--output and --product are required");
  return { output: values.get("--output")!, product: values.get("--product")!, ...(values.has("--ref") ? { ref: values.get("--ref")! } : {}), ...(values.has("--bundle-products") ? { bundleProducts: values.get("--bundle-products")!.split(",") } : {}), ...(values.has("--bundle-version") ? { bundleVersion: values.get("--bundle-version")! } : {}) };
}

if (import.meta.main) {
  try {
    const options = parseArgs(process.argv.slice(2));
    if ("help" in options) console.log("bun tools/release/package.ts --output <new-or-empty-dir> --product all|bundle|<id> [--bundle-products id,id] [--bundle-version semver] [--ref full-commit-id]\nbun tools/release/package.ts --verify <output-dir>");
    else {
      const result = "verify" in options ? verifyOutput(options.verify) : buildRelease(options);
      console.log(JSON.stringify({ sourceCommit: result.sourceCommit, assets: result.assets.map(asset => asset.file), status: "verified" }));
    }
  } catch (error) { console.error(`Packaging failed: ${(error as Error).message}`); process.exitCode = 1; }
}
