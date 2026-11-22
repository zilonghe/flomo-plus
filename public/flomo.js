const maxHTMLBytes = 32 * 1024 * 1024;
const maxDirectoryBytes = 24 * 1024 * 1024;
const zipEndSignature = 0x06054b50;
const zipDirectorySignature = 0x02014b50;
const zipFileSignature = 0x04034b50;
const utf8 = new TextDecoder("utf-8", { fatal: true });
import { sha256 } from "./crypto.js";

const encoder = new TextEncoder();

function unsupportedArchive() {
  return new Error("无法读取这个 ZIP。请先解压，再选择里面的 HTML 文件。");
}

function oversizedHTML() {
  return new Error("笔记 HTML 超过 32 MB。请在 flomo 按标签或搜索结果分批导出。");
}

function decodeHTML(bytes) {
  if (bytes.byteLength > maxHTMLBytes) throw oversizedHTML();
  try {
    if (bytes[0] === 0xff && bytes[1] === 0xfe) {
      return new TextDecoder("utf-16le", { fatal: true }).decode(bytes);
    }
    if (bytes[0] === 0xfe && bytes[1] === 0xff) {
      return new TextDecoder("utf-16be", { fatal: true }).decode(bytes);
    }
    return utf8.decode(bytes);
  } catch {
    try {
      return new TextDecoder("gb18030", { fatal: true }).decode(bytes);
    } catch {
      throw new Error("无法识别笔记文件的编码，请重新从 flomo 导出。");
    }
  }
}

async function zipDirectory(file) {
  // A ZIP comment has a two-byte length. Read only the end and directory first.
  const tailStart = Math.max(0, file.size - 65_557);
  const tail = new DataView(await file.slice(tailStart).arrayBuffer());
  for (let end = tail.byteLength - 22; end >= 0; end--) {
    if (tail.getUint32(end, true) !== zipEndSignature) continue;
    if (end + 22 + tail.getUint16(end + 20, true) !== tail.byteLength) continue;
    const entries = tail.getUint16(end + 10, true);
    const size = tail.getUint32(end + 12, true);
    const start = tail.getUint32(end + 16, true);
    if (
      tail.getUint16(end + 4, true) !== 0 || tail.getUint16(end + 6, true) !== 0 ||
      tail.getUint16(end + 8, true) !== entries || entries === 0xffff ||
      size > maxDirectoryBytes || start + size > tailStart + end
    ) throw unsupportedArchive();
    return { entries, start, bytes: await file.slice(start, start + size).arrayBuffer() };
  }
  throw unsupportedArchive();
}

function decodeName(bytes, flags) {
  try {
    return utf8.decode(bytes);
  } catch {
    if (flags & 0x800) return "";
    return new TextDecoder("gb18030").decode(bytes);
  }
}

async function htmlEntry(file) {
  const directory = await zipDirectory(file);
  const view = new DataView(directory.bytes);
  const matches = [];
  let offset = 0;
  for (let index = 0; index < directory.entries; index++) {
    if (offset + 46 > view.byteLength || view.getUint32(offset, true) !== zipDirectorySignature) {
      throw unsupportedArchive();
    }
    const nameLength = view.getUint16(offset + 28, true);
    const end = offset + 46 + nameLength + view.getUint16(offset + 30, true) + view.getUint16(offset + 32, true);
    if (end > view.byteLength) throw unsupportedArchive();
    const flags = view.getUint16(offset + 8, true);
    const name = decodeName(new Uint8Array(directory.bytes, offset + 46, nameLength), flags);
    const parts = name.split(/[\\/]/);
    const baseName = parts.at(-1);
    if (
      /\.html?$/i.test(baseName) && !parts.some(part => part.startsWith(".") || part === "__MACOSX") &&
      !parts.slice(0, -1).some(part => /^files?$/i.test(part))
    ) {
      matches.push({
        priority: /笔记\.html?$/i.test(baseName) ? 2 : /^index\.html?$/i.test(baseName) ? 1 : 0,
        flags,
        method: view.getUint16(offset + 10, true),
        checksum: view.getUint32(offset + 16, true),
        compressed: view.getUint32(offset + 20, true),
        uncompressed: view.getUint32(offset + 24, true),
        fileOffset: view.getUint32(offset + 42, true),
      });
    }
    offset = end;
  }
  if (!matches.length) throw new Error("ZIP 里没有找到 flomo 的笔记 HTML，请检查导出文件。");
  matches.sort((a, b) => b.priority - a.priority);
  if (matches.length > 1 && matches[0].priority === matches[1].priority) {
    throw new Error("ZIP 里有多份 HTML。请先解压，再选择 flomo 的笔记 HTML。");
  }
  return { ...matches[0], directoryStart: directory.start };
}

const crcTable = Uint32Array.from({ length: 256 }, (_, index) => {
  let value = index;
  for (let bit = 0; bit < 8; bit++) value = (value >>> 1) ^ ((value & 1) ? 0xedb88320 : 0);
  return value;
});

function crc32(bytes) {
  let crc = 0xffffffff;
  for (const byte of bytes) crc = (crc >>> 8) ^ crcTable[(crc ^ byte) & 0xff];
  return (crc ^ 0xffffffff) >>> 0;
}

async function inflate(blob, length) {
  let stream;
  try {
    stream = blob.stream().pipeThrough(new DecompressionStream("deflate-raw"));
  } catch {
    throw new Error("当前浏览器无法直接解压 ZIP。请先解压，再选择里面的 HTML 文件。");
  }
  const bytes = new Uint8Array(length);
  const reader = stream.getReader();
  let written = 0;
  try {
    while (true) {
      const { value, done } = await reader.read();
      if (done) break;
      if (value.byteLength > length - written) {
        await reader.cancel();
        throw unsupportedArchive();
      }
      bytes.set(value, written);
      written += value.byteLength;
    }
  } catch {
    throw unsupportedArchive();
  } finally {
    reader.releaseLock();
  }
  if (written !== length) throw unsupportedArchive();
  return bytes;
}

async function readZip(file) {
  const entry = await htmlEntry(file);
  if (entry.uncompressed > maxHTMLBytes) throw oversizedHTML();
  if (
    entry.flags & 1 || (entry.method !== 0 && entry.method !== 8) ||
    entry.compressed > maxHTMLBytes + 1024 * 1024 ||
    entry.fileOffset + 30 > entry.directoryStart
  ) throw unsupportedArchive();
  const view = new DataView(await file.slice(entry.fileOffset, entry.fileOffset + 30).arrayBuffer());
  if (
    view.getUint32(0, true) !== zipFileSignature || view.getUint16(8, true) !== entry.method ||
    (view.getUint16(6, true) & 1)
  ) throw unsupportedArchive();
  const start = entry.fileOffset + 30 + view.getUint16(26, true) + view.getUint16(28, true);
  if (start + entry.compressed > entry.directoryStart) throw unsupportedArchive();
  const compressed = file.slice(start, start + entry.compressed);
  const bytes = entry.method === 0
    ? new Uint8Array(await compressed.arrayBuffer())
    : await inflate(compressed, entry.uncompressed);
  if (bytes.byteLength !== entry.uncompressed || crc32(bytes) !== entry.checksum) throw unsupportedArchive();
  return decodeHTML(bytes);
}

const blockTags = new Set("ADDRESS ARTICLE ASIDE BLOCKQUOTE DD DIV DL DT FIGCAPTION FIGURE H1 H2 H3 H4 H5 H6 HR LI OL P PRE SECTION TABLE TD TH TR UL".split(" "));
const discardTags = new Set("AUDIO CANVAS EMBED IFRAME IMG LINK META NOSCRIPT OBJECT PICTURE SCRIPT SOURCE STYLE SVG TEMPLATE VIDEO".split(" "));
const tagPattern = /#[\p{L}\p{N}_]+(?:\/[\p{L}\p{N}_]+)*/gu;

function urlText(element) {
  try {
    const url = new URL(element.getAttribute("href"));
    return (url.protocol === "http:" || url.protocol === "https:") && !url.username && !url.password
      ? url.href : "";
  } catch {
    return "";
  }
}

function renderText(node, depth = 0, isPre = false) {
  if (depth > 150) throw new Error("这份笔记 HTML 的排版结构过深，请重新导出。");
  if (node.nodeType === 3) return isPre ? node.data : node.data.replace(/[\t\r\n]+/g, " ");
  if (node.nodeType !== 1 || discardTags.has(node.tagName)) return "";
  if (node.tagName === "BR") return "\n";

  const isList = node.tagName === "OL" || node.tagName === "UL";
  let itemNumber = Number.parseInt(node.getAttribute("start"), 10) || 1;
  const text = Array.from(node.childNodes, child => {
    const value = renderText(child, depth + 1, isPre || node.tagName === "PRE");
    if (!isList || child.tagName !== "LI" || !value.trim()) return value;
    const prefix = node.tagName === "OL" ? `${itemNumber++}. ` : "• ";
    return "\n" + prefix + value.trim() + "\n";
  }).join("");
  if (node.tagName === "A") {
    const url = urlText(node);
    return url && text.trim() !== url && text.trim() !== node.getAttribute("href")
      ? (text.trim() ? text + " (" + url + ")" : url) : text;
  }
  if (node.tagName === "P" && !text.trim()) return "\n";
  return blockTags.has(node.tagName) ? "\n" + text.replace(/^\n+|\n+$/g, "") + "\n" : text;
}

function cleanText(value) {
  return value.replace(/\r\n?/g, "\n").replace(/[ \t\u00a0]+\n/g, "\n")
    .replace(/\n[ \t\u00a0]+/g, "\n").replace(/\n{3,}/g, "\n\n").trim().normalize("NFC");
}

function directChild(memo, className) {
  return Array.from(memo.children).find(child => child.classList.contains(className));
}

function memoContent(memo) {
  const content = directChild(memo, "content");
  const body = content ? cleanText(renderText(content)) : "";
  const tagGroup = directChild(memo, "tags");
  const tags = tagGroup ? Array.from(new Set(tagGroup.textContent.match(tagPattern) ?? [])) : [];
  const existingTags = new Set(body.match(tagPattern) ?? []);
  const additional = tags.filter(tag => !existingTags.has(tag));
  return [body, additional.join(" ")].filter(Boolean).join("\n\n");
}

function countAttachments(memo) {
  const files = directChild(memo, "files");
  const content = directChild(memo, "content");
  return (files?.querySelectorAll("img, audio, video, iframe, object, embed, a[href]").length ?? 0) +
    (content?.querySelectorAll("img, audio, video, iframe, object, embed").length ?? 0);
}

const localTimestamp = /^(\d{4})-(\d{1,2})-(\d{1,2})[ T](\d{1,2}):(\d{2})(?::(\d{2}))?(?:\.(\d{1,3}))?(Z|[+-]\d{2}:?\d{2})?$/i;

function unixTime(parts) {
  const [year, month, day, hour, minute, second] = parts;
  const date = new Date(0);
  date.setUTCFullYear(year, month - 1, day);
  date.setUTCHours(hour, minute, second, 0);
  if (
    year < 1900 || date.getUTCFullYear() !== year || date.getUTCMonth() !== month - 1 ||
    date.getUTCDate() !== day || date.getUTCHours() !== hour ||
    date.getUTCMinutes() !== minute || date.getUTCSeconds() !== second
  ) return NaN;
  return date.getTime();
}

function localDateFields(formatter, epoch) {
  const byType = Object.fromEntries(formatter.formatToParts(epoch).map(({ type, value }) => [type, value]));
  return [byType.year, byType.month, byType.day, byType.hour, byType.minute, byType.second].map(Number);
}

function parseTimestamp(value, formatter) {
  const match = localTimestamp.exec(value.trim());
  if (!match) return null;
  const fields = match.slice(1, 7).map(part => Number(part ?? 0));
  const epoch = unixTime(fields);
  if (!Number.isFinite(epoch)) return null;
  const milliseconds = Number((match[7] ?? "").padEnd(3, "0"));
  const declaredOffset = match[8];
  if (declaredOffset) {
    if (declaredOffset.toUpperCase() === "Z") return new Date(epoch + milliseconds).toISOString();
    const digits = declaredOffset.slice(1).replace(":", "");
    const hours = Number(digits.slice(0, 2));
    const minutes = Number(digits.slice(2));
    if (hours > 23 || minutes > 59) return null;
    const direction = declaredOffset[0] === "+" ? 1 : -1;
    return new Date(epoch + milliseconds - direction * (hours * 60 + minutes) * 60_000).toISOString();
  }

  // Test the nearby offsets independently, taking the earlier time if a DST clock repeats.
  const candidates = new Set([epoch - 86_400_000, epoch, epoch + 86_400_000].map(probe =>
    epoch - (unixTime(localDateFields(formatter, probe)) - probe)
  ));
  const valid = [...candidates].filter(candidate =>
    localDateFields(formatter, candidate).every((field, index) => field === fields[index])
  );
  return valid.length ? new Date(Math.min(...valid) + milliseconds).toISOString() : null;
}

async function memoUUID(identity) {
  const bytes = await sha256(encoder.encode(identity));
  bytes[6] = (bytes[6] & 0x0f) | 0x80;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  const hex = Array.from(bytes.slice(0, 16), value => value.toString(16).padStart(2, "0")).join("");
  return [hex.slice(0, 8), hex.slice(8, 12), hex.slice(12, 16), hex.slice(16, 20), hex.slice(20, 32)].join("-");
}

export async function parseFlomoHTML(source, timeZone = "Asia/Shanghai") {
  let formatter;
  try {
    formatter = new Intl.DateTimeFormat("en-CA", {
      timeZone, calendar: "gregory", numberingSystem: "latn", hourCycle: "h23",
      year: "numeric", month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit", second: "2-digit",
    });
  } catch {
    throw new Error("时区无效，请输入例如 Asia/Shanghai。");
  }

  // Template contents stay inert. Read text and safe URL strings only, never append this markup to the page.
  const template = document.createElement("template");
  template.innerHTML = source;
  const memos = [...template.content.querySelectorAll(".memo")].filter(memo => !memo.parentElement?.closest(".memo"));
  if (!memos.length) throw new Error("这份 HTML 里没有找到 flomo 笔记。请选取从 flomo 导出的文件。");

  const pending = [];
  const occurrences = new Map();
  let skippedAttachments = 0;
  let skippedEmpty = 0;
  let skippedInvalidDate = 0;

  for (const memo of memos) {
    skippedAttachments += countAttachments(memo);
    const body = memoContent(memo);
    if (!body) {
      skippedEmpty++;
      continue;
    }
    const time = directChild(memo, "time");
    const originalTime = time?.getAttribute("datetime") ?? time?.textContent?.trim() ?? "";
    const createdAt = parseTimestamp(originalTime, formatter);
    if (!createdAt) {
      skippedInvalidDate++;
      continue;
    }
    const suppliedID = memo.getAttribute("data-memo-id") || memo.getAttribute("data-id") || memo.id;
    const timestamp = localTimestamp.exec(originalTime.trim());
    const wallClock = timestamp.slice(1, 7).map(part => Number(part ?? 0));
    const fraction = (timestamp[7] ?? "").padEnd(3, "0");
    const offset = (timestamp[8] ?? "").toUpperCase().replace(":", "");
    const key = JSON.stringify(suppliedID ? ["id", suppliedID] : ["content", wallClock, fraction, offset, body]);
    const occurrence = occurrences.get(key) ?? 0;
    occurrences.set(key, occurrence + 1);
    pending.push({ identity: "flomo:" + key + ":" + occurrence, body, createdAt });
  }

  const notes = [];
  for (let index = 0; index < pending.length; index += 256) {
    notes.push(...await Promise.all(pending.slice(index, index + 256).map(async ({ identity, body, createdAt }) => ({
      id: await memoUUID(identity), body, createdAt, reading: null, turns: [],
    }))));
  }
  return { notes, skippedAttachments, skippedEmpty, skippedInvalidDate };
}

export async function parseFlomoFile(file, timeZone) {
  if (!file?.size) throw new Error("所选文件是空的，请选择 flomo 导出的 HTML 或 ZIP 文件。");
  if (/\.zip$/i.test(file.name)) return parseFlomoHTML(await readZip(file), timeZone);
  if (/\.html?$/i.test(file.name)) {
    if (file.size > maxHTMLBytes) throw oversizedHTML();
    return parseFlomoHTML(decodeHTML(new Uint8Array(await file.arrayBuffer())), timeZone);
  }
  throw new Error("请选择 flomo 导出的 .zip、.html 或 .htm 文件。");
}
