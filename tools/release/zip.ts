// A deliberately small ZIP profile: stored files, UTF-8 names, no extras, comments,
// directories or ZIP64. Fixed dates and sorted paths make bytes platform independent.
// Keeping the format bounded also makes validation independent of an unzip program.
import { createHash } from "node:crypto";

export type ZipFile = { data: Buffer; mode?: number };
export const compare = (a: string, b: string) => a < b ? -1 : a > b ? 1 : 0;
export const sha256 = (data: Buffer | string) => createHash("sha256").update(data).digest("hex");

export function safePath(value: unknown): asserts value is string {
  if (typeof value !== "string" || !value || /[\\\x00-\x1f\x7f:<>"|?*]/.test(value) || value.length > 1024) {
    throw new Error(`Unsafe relative path: ${String(value)}`);
  }
  for (const part of value.split("/")) {
    if (!part || part === "." || part === ".." || /[. ]$/.test(part) ||
        /^(con|prn|aux|nul|com[0-9]|lpt[0-9])(?:\.|$)/i.test(part) || part.toLowerCase() === ".git") {
      throw new Error(`Unsafe relative path: ${value}`);
    }
  }
}

export function uniquePaths(paths: string[]) {
  const seen = new Set<string>();
  for (const name of paths) {
    safePath(name);
    const key = name.toLowerCase();
    if (seen.has(key)) throw new Error(`Duplicate/case-colliding path: ${name}`);
    seen.add(key);
  }
  for (const name of seen) {
    const parts = name.split("/");
    while (parts.length > 1) {
      parts.pop();
      if (seen.has(parts.join("/"))) throw new Error(`File/directory collision: ${name}`);
    }
  }
}

const crcTable = Uint32Array.from({ length: 256 }, (_, index) => {
  let crc = index;
  for (let bit = 0; bit < 8; bit++) crc = (crc >>> 1) ^ ((crc & 1) ? 0xedb88320 : 0);
  return crc >>> 0;
});
export function crc32(data: Buffer) {
  let crc = 0xffffffff;
  for (const byte of data) crc = crcTable[(crc ^ byte) & 0xff] ^ (crc >>> 8);
  return (crc ^ 0xffffffff) >>> 0;
}

export function createZip(files: Map<string, ZipFile>): Buffer {
  const names = [...files.keys()].sort(compare);
  uniquePaths(names);
  if (!names.length || names.length >= 65535) throw new Error("Unsupported ZIP entry count");
  const local: Buffer[] = [], central: Buffer[] = [];
  let offset = 0;
  for (const name of names) {
    const { data, mode = 0o100644 } = files.get(name)!;
    if (![0o100644, 0o100755].includes(mode)) throw new Error(`Unsupported file mode: ${name}`);
    const encoded = Buffer.from(name, "utf8"), crc = crc32(data);
    if (encoded.length > 65535 || data.length >= 0xffffffff) throw new Error("ZIP64 is unsupported");
    const header = Buffer.alloc(30);
    header.writeUInt32LE(0x04034b50, 0);
    header.writeUInt16LE(20, 4);
    header.writeUInt16LE(0x800, 6);
    header.writeUInt16LE(33, 12); // 1980-01-01 00:00:00, independent of local timezone.
    header.writeUInt32LE(crc, 14);
    header.writeUInt32LE(data.length, 18);
    header.writeUInt32LE(data.length, 22);
    header.writeUInt16LE(encoded.length, 26);
    local.push(header, encoded, data);
    const record = Buffer.alloc(46);
    record.writeUInt32LE(0x02014b50, 0);
    record.writeUInt16LE(0x314, 4); // Unix creator, ZIP 2.0.
    record.writeUInt16LE(20, 6);
    record.writeUInt16LE(0x800, 8);
    record.writeUInt16LE(33, 14);
    record.writeUInt32LE(crc, 16);
    record.writeUInt32LE(data.length, 20);
    record.writeUInt32LE(data.length, 24);
    record.writeUInt16LE(encoded.length, 28);
    record.writeUInt32LE((mode * 65536) >>> 0, 38);
    record.writeUInt32LE(offset, 42);
    central.push(record, encoded);
    offset += header.length + encoded.length + data.length;
    if (offset >= 0xffffffff) throw new Error("ZIP64 is unsupported");
  }
  const directory = Buffer.concat(central), end = Buffer.alloc(22);
  end.writeUInt32LE(0x06054b50, 0);
  end.writeUInt16LE(names.length, 8);
  end.writeUInt16LE(names.length, 10);
  end.writeUInt32LE(directory.length, 12);
  end.writeUInt32LE(offset, 16);
  return Buffer.concat([...local, directory, end]);
}

export function readZip(bytes: Buffer): Map<string, ZipFile> {
  const fail = () => { throw new Error("Invalid or corrupt ZIP structure"); };
  if (bytes.length < 22) fail();
  const end = bytes.length - 22;
  if (bytes.readUInt32LE(end) !== 0x06054b50 || bytes.readUInt32LE(end + 4) !== 0 || bytes.readUInt16LE(end + 20)) fail();
  const count = bytes.readUInt16LE(end + 8), size = bytes.readUInt32LE(end + 12), start = bytes.readUInt32LE(end + 16);
  if (!count || count === 65535 || count !== bytes.readUInt16LE(end + 10) || start + size !== end) fail();
  const result = new Map<string, ZipFile>();
  let cursor = start, localOffset = 0;
  for (let index = 0; index < count; index++) {
    if (cursor + 46 > end || bytes.readUInt32LE(cursor) !== 0x02014b50) fail();
    const nameLength = bytes.readUInt16LE(cursor + 28), length = bytes.readUInt32LE(cursor + 24);
    if (cursor + 46 + nameLength > end || bytes.readUInt16LE(cursor + 4) !== 0x314 ||
        bytes.readUInt16LE(cursor + 6) !== 20 || bytes.readUInt16LE(cursor + 8) !== 0x800 ||
        bytes.readUInt16LE(cursor + 10) !== 0 || bytes.readUInt16LE(cursor + 12) !== 0 ||
        bytes.readUInt16LE(cursor + 14) !== 33 || bytes.readUInt32LE(cursor + 20) !== length ||
        bytes.readUInt32LE(cursor + 30) !== 0 || bytes.readUInt32LE(cursor + 34) !== 0 ||
        bytes.readUInt32LE(cursor + 42) !== localOffset) fail();
    const nameBytes = bytes.subarray(cursor + 46, cursor + 46 + nameLength);
    const name = nameBytes.toString("utf8"), mode = bytes.readUInt32LE(cursor + 38) >>> 16;
    safePath(name);
    if (!Buffer.from(name).equals(nameBytes) || ![0o100644, 0o100755].includes(mode) || result.has(name)) fail();
    if (localOffset + 30 + nameLength + length > start || bytes.readUInt32LE(localOffset) !== 0x04034b50 ||
        bytes.readUInt16LE(localOffset + 4) !== 20 || bytes.readUInt16LE(localOffset + 6) !== 0x800 ||
        bytes.readUInt16LE(localOffset + 8) !== 0 || bytes.readUInt16LE(localOffset + 10) !== 0 ||
        bytes.readUInt16LE(localOffset + 12) !== 33 || bytes.readUInt32LE(localOffset + 14) !== bytes.readUInt32LE(cursor + 16) ||
        bytes.readUInt32LE(localOffset + 18) !== length || bytes.readUInt32LE(localOffset + 22) !== length ||
        bytes.readUInt16LE(localOffset + 26) !== nameLength || bytes.readUInt16LE(localOffset + 28) !== 0 ||
        !bytes.subarray(localOffset + 30, localOffset + 30 + nameLength).equals(nameBytes)) fail();
    const data = bytes.subarray(localOffset + 30 + nameLength, localOffset + 30 + nameLength + length);
    if (crc32(data) !== bytes.readUInt32LE(cursor + 16)) throw new Error(`ZIP CRC mismatch: ${name}`);
    result.set(name, { data, mode });
    localOffset += 30 + nameLength + length;
    cursor += 46 + nameLength;
  }
  if (cursor !== end || localOffset !== start) fail();
  uniquePaths([...result.keys()]);
  return result;
}
