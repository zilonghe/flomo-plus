import { sha256 } from './crypto.js';
import { tagsFor } from './ux-helpers.js';

const decoder = new TextDecoder();
const encoder = new TextEncoder();
const MiB = 1024 * 1024;
const maxMetaHeaderBytes = 64 * 1024;
const markdown = /\.m(?:d|arkdown)$/i;
const jex = /\.jex$/i;
const resourceId = /^[a-f0-9]{32}$/i;
const newResult = () => ({
  notes: [], skippedAttachments: 0, skippedEmpty: 0, skippedInvalidDate: 0, skippedEncrypted: 0,
});
const normalizeLines = text => text.replace(/\r\n?/g, '\n');
const privatePart = part => part.startsWith('.') || /^(?:_?resources|__MACOSX)$/i.test(part);
const hiddenPath = path => path.replace(/^(?:\.\/)+/, '').split('/').some(privatePart);

async function memoUUID(identity) {
  const bytes = await sha256(encoder.encode(identity));
  bytes[6] = (bytes[6] & 15) | 128;
  bytes[8] = (bytes[8] & 63) | 128;
  const hex = Array.from(bytes.subarray(0, 16), byte => byte.toString(16).padStart(2, '0')).join('');
  return hex.replace(/^(........)(....)(....)(....)(............)$/, '$1-$2-$3-$4-$5');
}

const formatterFor = timeZone => new Intl.DateTimeFormat('en-GB', {
  timeZone, calendar: 'gregory', numberingSystem: 'latn', hourCycle: 'h23',
  year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit', second: '2-digit',
});

function timestamp(value, formatter) {
  const match = /^(\d{4}-\d{2}-\d{2})(?:[ T](\d{2}:\d{2})(?::(\d{2}))?(?:\.(\d+))?(?:\s*(Z|[+-]\d{2}:?\d{2}))?)?$/i.exec(value?.trim() ?? '');
  if (!match) return null;
  const [, date, hm = '00:00', seconds = '00', fraction = '', offset] = match;
  const clock = date + 'T' + hm + ':' + seconds;
  const epoch = Date.parse(clock + 'Z');
  if (!Number.isFinite(epoch) || new Date(epoch).toISOString().slice(0, 19) !== clock) return null;
  const ms = Number(fraction.slice(0, 3).padEnd(3, '0'));
  if (offset) {
    const explicit = Date.parse(clock + offset.toUpperCase());
    return Number.isFinite(explicit) ? new Date(explicit + ms).toISOString() : null;
  }
  const localClock = instant => {
    const fields = Object.fromEntries(formatter.formatToParts(instant).map(({ type, value }) => [type, value]));
    return fields.year.padStart(4, '0') + '-' + fields.month + '-' + fields.day
      + 'T' + fields.hour + ':' + fields.minute + ':' + fields.second;
  };
  // Both sides of a DST transition may have different offsets.
  const candidates = [epoch - 86_400_000, epoch, epoch + 86_400_000].map(probe =>
    epoch - (Date.parse(localClock(probe) + 'Z') - probe)
  ).filter(instant => localClock(instant) === clock);
  return candidates.length ? new Date(Math.min(...candidates) + ms).toISOString() : null;
}

function assemble(title, source, sourceTags) {
  const first = /^(?:[^\S\n]*\n)*([^\n]*\S[^\n]*)/.exec(source)?.[1];
  if (!title.trim()) title = '';
  if (!first && !title) return '';
  const heading = first && /^ {0,3}#[ \t]+(.+?)(?:[ \t]+#+)?[ \t]*$/.exec(first)?.[1];
  let body = !first ? title : !title || heading === title ? source : '# ' + title + '\n\n' + source;
  const seen = new Set(tagsFor(body).map(tag => tag.toLowerCase()));
  const tags = [];
  for (const value of sourceTags) {
    const parts = Array.isArray(value) ? value : String(value || '').split('/');
    let tag = parts.map(part => String(part).replace(/[^\p{L}\p{N}_]+/gu, '_').replace(/^_+|_+$/g, ''))
      .filter(Boolean).join('/');
    if (!tag) continue;
    if (/^\p{N}+$/u.test(tag)) tag = 'joplin/' + tag;
    const key = tag.toLowerCase();
    if (seen.has(key)) continue;
    seen.add(key);
    tags.push('#' + tag);
  }
  if (tags.length) body += '\n\n' + tags.join(' ');
  return body;
}

function* references(source) {
  for (const match of source.matchAll(/(!?)\[[^\]\n]*\]\(\s*(<[^>\n]+>|[^)\n]+)\)|<([a-z][\w:-]*)\b[^<>]*>/gi)) {
    if (!match[3]) {
      const target = match[2].trim();
      if (!target) continue;
      yield [target.startsWith('<') ? target.slice(1, -1) : target.replace(/\s+["'][^]*["']$/, ''), !!match[1]];
      continue;
    }
    for (const [, name, quoted, single, bare] of match[0].matchAll(/\s(src|href)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))/gi)) {
      yield [quoted ?? single ?? bare, match[3].toLowerCase() === 'img' && name.toLowerCase() === 'src'];
    }
  }
}

function tarError() {
  return new Error('JEX 归档格式无效或已截断。');
}

function tarText(bytes) {
  const end = bytes.indexOf(0);
  return decoder.decode(end === -1 ? bytes : bytes.subarray(0, end));
}

function tarSize(bytes) {
  if (bytes[0] & 128) {
    if (bytes[0] & 64) throw tarError();
    let size = bytes[0] & 127;
    for (const byte of bytes.subarray(1)) size = size * 256 + byte;
    if (Number.isSafeInteger(size)) return size;
  } else {
    const octal = decoder.decode(bytes).replace(/[\0 ]+$/, '').replace(/^ +/, '');
    if (/^[0-7]+$/.test(octal)) return Number.parseInt(octal, 8);
  }
  throw tarError();
}

function validChecksum(header) {
  const expected = tarSize(header.subarray(148, 156));
  let unsigned = 0;
  let signed = 0;
  for (let i = 0; i < header.length; i++) {
    const byte = i >= 148 && i < 156 ? 32 : header[i];
    unsigned += byte;
    signed += byte > 127 ? byte - 256 : byte;
  }
  return expected === unsigned || expected === signed;
}

function paxFields(bytes) {
  const fields = {};
  for (let pos = 0; pos < bytes.length;) {
    const space = bytes.indexOf(32, pos);
    if (space < 0) throw tarError();
    const len = decoder.decode(bytes.subarray(pos, space));
    const end = pos + Number(len);
    if (!/^\d+$/.test(len) || end <= space + 2 || end > bytes.length || bytes[end - 1] !== 10) throw tarError();
    const equal = bytes.indexOf(61, space + 1);
    if (equal <= space + 1 || equal >= end - 1) throw tarError();
    const key = decoder.decode(bytes.subarray(space + 1, equal));
    if (key === 'path' || key === 'size') fields[key] = decoder.decode(bytes.subarray(equal + 1, end - 1));
    pos = end;
  }
  if ('size' in fields) {
    if (!/^\d+$/.test(fields.size) || !Number.isSafeInteger(Number(fields.size))) throw tarError();
    fields.size = Number(fields.size);
  }
  return fields;
}

async function* tarMarkdown(file) {
  let extensions = {};
  let total = 0;
  for (let offset = 0; offset < file.size;) {
    if (file.size - offset < 512) throw tarError();
    const header = new Uint8Array(await file.slice(offset, offset + 512).arrayBuffer());
    if (header.every(byte => byte === 0)) {
      if (Object.keys(extensions).length) throw tarError();
      return;
    }
    const type = header[156];
    const meta = type === 76 || type === 120;
    const headerSize = tarSize(header.subarray(124, 136));
    const size = meta ? headerSize : extensions.size ?? headerSize;
    if (meta && size > maxMetaHeaderBytes) throw new Error('JEX 扩展头超过 64 KB 限制。');
    const start = offset + 512;
    const next = start + Math.ceil(size / 512) * 512;
    if (next > file.size || !validChecksum(header)) throw tarError();
    const read = () => file.slice(start, start + size).arrayBuffer();
    if (meta) {
      const bytes = new Uint8Array(await read());
      Object.assign(extensions, type === 76 ? { path: tarText(bytes) } : paxFields(bytes));
    } else {
      const prefix = tarText(header.subarray(257, 263)) === 'ustar'
        ? tarText(header.subarray(345, 500)) : '';
      const path = extensions.path ?? [prefix, tarText(header.subarray(0, 100))].filter(Boolean).join('/');
      extensions = {};
      if ((type === 0 || type === 48) && /\.md$/i.test(path) && !hiddenPath(path)) {
        total += size;
        if (total > 64 * MiB) throw new Error('JEX 内的 Markdown 文本超过 64 MB 限制。');
        yield normalizeLines(decoder.decode(await read()));
      }
    }
    offset = next;
  }
  if (Object.keys(extensions).length) throw tarError();
}

function rawItem(source) {
  const lines = source.split('\n');
  const metadata = Object.create(null);
  let end = lines.length;
  while (end && !lines[end - 1].trim()) end--;
  while (end) {
    const field = /^([a-z0-9_]+):\s*(.*)$/.exec(lines[end - 1]);
    if (!field) break;
    metadata[field[1]] ??= field[2].trim();
    end--;
  }
  if (!resourceId.test(metadata.id ?? '') || !/^\d+$/.test(metadata.type_ ?? '')) return null;
  if (end && !lines[end - 1].trim()) end--;
  const title = end ? lines[0] : '';
  const start = end > 1 && !lines[1].trim() ? 2 : 1;
  return { metadata, title, source: lines.slice(start, end).join('\n') };
}

function folderPath(folders, id) {
  const path = [];
  const visited = new Set();
  for (let depth = 0; depth < 32 && folders.has(id) && !visited.has(id); depth++) {
    visited.add(id);
    const folder = folders.get(id);
    path.unshift(folder.title);
    id = folder.metadata.parent_id;
  }
  return path;
}

export async function parseJoplinJex(file) {
  const result = newResult();
  const items = [];
  const folders = new Map();
  const tags = new Map();
  const noteTags = new Map();
  const resourceIds = new Set();
  let valid = false;
  for await (const source of tarMarkdown(file)) {
    const item = rawItem(source);
    if (!item) continue;
    valid = true;
    const { id, type_, note_id, tag_id, encryption_applied, is_locked } = item.metadata;
    switch (type_) {
      case '1':
        if (encryption_applied === '1' || is_locked === '1') result.skippedEncrypted++;
        else items.push(item);
        break;
      case '2': folders.set(id, item); break;
      case '4': resourceIds.add(id.toLowerCase()); break;
      case '5': tags.set(id, item.title); break;
      case '6':
        if (!noteTags.has(note_id)) noteTags.set(note_id, new Set());
        noteTags.get(note_id).add(tag_id);
        break;
    }
  }
  if (!valid) throw new Error('JEX 归档中没有有效的 Joplin Markdown 条目。');
  const utc = formatterFor('UTC');
  for (const { metadata, title, source } of items) {
    const { id, parent_id, user_created_time, created_time, user_updated_time, updated_time } = metadata;
    for (const [target] of references(source)) {
      const match = /^:\/([a-f0-9]{32})(?![a-f0-9])/i.exec(target);
      if (match && resourceIds.has(match[1].toLowerCase())) result.skippedAttachments++;
    }
    const customTags = [...(noteTags.get(id) ?? [])].map(tagId => tags.get(tagId)).filter(Boolean);
    const body = assemble(title, source, [folderPath(folders, parent_id), ...customTags]);
    if (!body) { result.skippedEmpty++; continue; }
    const createdAt = [user_created_time, created_time, user_updated_time, updated_time]
      .map(value => timestamp(value, utc)).find(Boolean);
    if (!createdAt) { result.skippedInvalidDate++; continue; }
    result.notes.push({ id: await memoUUID('joplin:jex:' + id), body, createdAt, reading: null, turns: [] });
  }
  return result;
}

const metadataKeys = new Set(('title created updated date tags notebook folder author latitude longitude altitude '
  + 'source is_todo todo_completed completed').split(' '));

function yamlScalar(raw) {
  const text = raw.trim();
  if (text.startsWith("'")) {
    const match = /^'((?:[^']|'')*)'(?:\s+#.*)?$/.exec(text);
    return match ? match[1].replace(/''/g, "'") : null;
  }
  if (text.startsWith('"')) {
    const match = /^"((?:[^"\\]|\\.)*)"(?:\s+#.*)?$/.exec(text);
    if (!match || !/^(?:[^\\]|\\(?:["\\/0abtnvfre N_LP]|x[\da-fA-F]{2}|u[\da-fA-F]{4}|U[\da-fA-F]{8}))*$/.test(match[1])) return null;
    const escapes = { '0': '\0', a: '\x07', b: '\b', t: '\t', n: '\n', v: '\v', f: '\f', r: '\r',
      e: '\x1b', N: '\u0085', _: '\u00a0', L: '\u2028', P: '\u2029' };
    return match[1].replace(/\\(?:x([\da-fA-F]{2})|u([\da-fA-F]{4})|U([\da-fA-F]{8})|(.))/g,
      (_, x, u, U, char) => {
        const code = Number.parseInt(x ?? u ?? U, 16);
        return char ? escapes[char] ?? char : code <= 0x10ffff ? String.fromCodePoint(code) : '\ufffd';
      });
  }
  if (text.startsWith('#')) return '';
  const plain = text.replace(/\s+#.*$/, '');
  if (!plain) return '';
  if (/^[\[\]{},&*!%@`|>]/.test(plain) || /^[-?:](?:\s|$)/.test(plain)) return null;
  return /:\s|:$/.test(plain) ? null : plain;
}

function parseFlowArray(scalar) {
  if (!scalar.startsWith('[')) return null;
  const values = [];
  let i = 1;
  const skipSpaces = () => { while (i < scalar.length && /\s/.test(scalar[i])) i++; };
  const validTail = () => /^\s*(?:#.*)?$/.test(scalar.slice(i + 1));
  skipSpaces();
  if (i < scalar.length && scalar[i] === ']') return validTail() ? values : null;
  while (i < scalar.length) {
    skipSpaces();
    if (i >= scalar.length) return null;
    if (scalar[i] === ']') return validTail() ? values : null;
    let rawItem = '';
    const ch = scalar[i];
    if (ch === "'") {
      let end = i + 1;
      let closed = false;
      while (end < scalar.length) {
        if (scalar[end] === "'") {
          if (scalar[end + 1] === "'") { end += 2; continue; }
          end++;
          closed = true;
          break;
        }
        end++;
      }
      if (!closed) return null;
      rawItem = scalar.slice(i, end);
      i = end;
      skipSpaces();
    } else if (ch === '"') {
      let end = i + 1;
      let closed = false;
      while (end < scalar.length) {
        if (scalar[end] === '\\') { end += 2; continue; }
        if (scalar[end] === '"') { end++; closed = true; break; }
        end++;
      }
      if (!closed) return null;
      rawItem = scalar.slice(i, end);
      i = end;
      skipSpaces();
    } else {
      if (ch === '#') return null;
      const start = i;
      while (i < scalar.length && scalar[i] !== ',' && scalar[i] !== ']') {
        if (scalar[i] === '#' && /\s/.test(scalar[i - 1])) return null;
        if ('[{}'.includes(scalar[i])) return null;
        i++;
      }
      rawItem = scalar.slice(start, i).trim();
      if (!rawItem) return null;
    }
    const parsed = yamlScalar(rawItem);
    if (parsed === null) return null;
    values.push(parsed);
    if (i >= scalar.length) return null;
    if (scalar[i] === ']') return validTail() ? values : null;
    if (scalar[i] !== ',') return null;
    i++;
    skipSpaces();
    if (i < scalar.length && scalar[i] === ']') return validTail() ? values : null;
  }
  return null;
}

function yamlValue(key, raw, lines, listIndent) {
  if (/^[>|](?:[1-9][+-]?|[+-][1-9]?)?(?:\s+#.*)?$/.test(raw)) {
    const indicator = raw.split(/\s/)[0];
    const minIndent = lines.reduce((min, line) => line.trim() ? Math.min(min, /^ */.exec(line)[0].length) : min, Infinity);
    if (!Number.isFinite(minIndent)) return '';
    const explicitIndent = /[1-9]/.exec(indicator);
    const indent = explicitIndent ? (listIndent ?? 0) + Number(explicitIndent[0]) : minIndent;
    if (!indent || minIndent < indent) return null;
    const block = lines.map(line => line.slice(indent));
    let value = block.join('\n');
    if (raw[0] === '>') {
      let lastNonempty;
      value = block.map((line, i) => {
        const previous = block[i - 1];
        const plain = line && !/^\s/.test(line);
        const separator = !i ? '' : plain && previous && !/^\s/.test(previous) ? ' '
          : plain && !previous && lastNonempty && !/^\s/.test(lastNonempty) ? '' : '\n';
        if (line) lastNonempty = line;
        return separator + line;
      }).join('');
    }
    if (indicator.includes('+')) return value + '\n';
    return value.replace(/\n+$/, '') + (indicator.includes('-') ? '' : '\n');
  }
  const meaningful = lines.filter(line => line.trim() && !/^\s*#/.test(line));
  const listStart = /^( *)-\s+(.*)$/.exec(meaningful[0] ?? '');
  if (listIndent === undefined && listStart) {
    if (raw && !raw.startsWith('#')) return null;
    const items = [];
    for (const line of lines) {
      const item = /^( *)-\s+(.*)$/.exec(line);
      if (item?.[1] === listStart[1]) items.push({ raw: item[2].trim(), lines: [] });
      else if (items.length && (!line.trim() || /^\s*#/.test(line) || /^ */.exec(line)[0].length > listStart[1].length)) {
        items.at(-1).lines.push(line);
      } else if (line.trim() && !/^\s*#/.test(line)) return null;
    }
    const values = items.map(item => yamlValue('', item.raw, item.lines, listStart[1].length + 2));
    return values.includes(null) ? null : values;
  }
  const parts = raw && !raw.startsWith('#')
    ? [raw, ...meaningful.map(line => line.trim())]
    : meaningful.map(line => line.trim());
  if (parts.length > 1) {
    if (/^[\['"]/.test(parts[0])) {
      const parsePrefix = parts[0].startsWith('[') ? parseFlowArray : yamlScalar;
      for (let k = 1; k < parts.length; k++) {
        if (parsePrefix(parts.slice(0, k).join(' ')) !== null) return null;
      }
    } else if (parts.slice(0, -1).some(part => /\s#/.test(part))) return null;
  }
  const scalar = parts.join(' ').trim();
  if (scalar.startsWith('[')) return parseFlowArray(scalar);
  return yamlScalar(scalar);
}

function frontMatter(source) {
  if (!source.startsWith('---\n')) return { metadata: {}, source };
  const close = /^(?:---|\.\.\.)[ \t]*$/gm;
  close.lastIndex = 4;
  const delimiter = close.exec(source);
  if (!delimiter) return { metadata: {}, source };
  const metadata = Object.create(null);
  let current;
  const save = () => {
    if (!current) return true;
    const { key, raw, lines } = current;
    const value = yamlValue(key, raw, lines);
    if (value === null) return false;
    metadata[key] = value;
    return true;
  };
  for (const line of source.slice(4, delimiter.index - 1).split('\n')) {
    const field = /^([a-zA-Z_][\w-]*\??):(?:[ \t]+(.*)|[ \t]*)$/.exec(line);
    if (field) {
      if (!save()) return { metadata: {}, source };
      current = { key: field[1], raw: field[2]?.trim() ?? '', lines: [] };
    } else if (current && (!line.trim() || /^ +|^-\s+/.test(line))) {
      current.lines.push(line);
    } else if (line.trim() && !/^\s*#/.test(line)) {
      return { metadata: {}, source };
    }
  }
  if (!save() || !Object.keys(metadata).some(key => metadataKeys.has(key))) return { metadata: {}, source };
  return { metadata, source: source.slice(close.lastIndex).replace(/^\n(?:[ \t]*\n)?/, '') };
}

function markdownCandidates(files) {
  return Array.from(files).flatMap(file => {
    const relative = file.webkitRelativePath?.includes('/') ? file.webkitRelativePath : '';
    const path = relative ? relative.slice(relative.indexOf('/') + 1) : file.name;
    return markdown.test(file.name) && !hiddenPath(path) ? [{ file, path, relative }] : [];
  });
}

function decodeMarkdown(buffer) {
  const bytes = new Uint8Array(buffer);
  const encoding = bytes[0] === 255 && bytes[1] === 254 ? 'utf-16le'
    : bytes[0] === 254 && bytes[1] === 255 ? 'utf-16be' : 'utf-8';
  return normalizeLines(new TextDecoder(encoding).decode(bytes));
}

const stringField = (metadata, key) => typeof metadata[key] === 'string' ? metadata[key] : '';
export async function parseJoplinMarkdownFiles(files, timeZone = 'Asia/Shanghai') {
  const candidates = markdownCandidates(files);
  if (!candidates.length) throw new Error('没有可导入的 .md 或 .markdown 文件。');
  let total = 0;
  for (const { file } of candidates) {
    if (file.size > 32 * MiB) throw new Error('单个 Markdown 文件超过 32 MB 限制。');
    total += file.size;
    if (total > 64 * MiB) throw new Error('Markdown 文件合计超过 64 MB 限制。');
  }

  const result = newResult();
  const occurrences = new Map();
  const formatter = formatterFor(timeZone);
  for (const { file, path, relative } of candidates) {
    const { metadata, source } = frontMatter(decodeMarkdown(await file.arrayBuffer()));
    for (const [target, image] of references(source)) {
      if (!target || /^(?:[a-z][\w+.-]*:|\/\/|#)/i.test(target)) continue;
      const localPath = target.split(/[?#]/, 1)[0];
      if (!markdown.test(localPath) && (image || /(?:^|\/)_?resources\//i.test(localPath))) result.skippedAttachments++;
    }
    const explicitTitle = stringField(metadata, 'title');
    const title = explicitTitle.trim() ? explicitTitle : file.name.replace(markdown, '').trim();
    const notebook = stringField(metadata, 'notebook').trim() || stringField(metadata, 'folder').trim()
      || (relative ? path.split('/').slice(0, -1).join('/') : '');
    const tags = Array.isArray(metadata.tags) ? metadata.tags : stringField(metadata, 'tags').split(/[,\s]+/);
    const body = assemble(title, source, [notebook, ...tags]);
    if (!body) { result.skippedEmpty++; continue; }
    const dates = ['created', 'date', 'updated'].map(key => stringField(metadata, key));
    const identityDate = dates.find(Boolean) || '';
    let createdAt = dates.map(value => timestamp(value, formatter)).find(Boolean);
    if (!createdAt && file.lastModified > 0) {
      const modified = new Date(file.lastModified);
      if (Number.isFinite(modified.getTime())) createdAt = modified.toISOString();
    }
    if (!createdAt) { result.skippedInvalidDate++; continue; }
    const key = JSON.stringify([path, identityDate, body]);
    const occurrence = occurrences.get(key) ?? 0;
    occurrences.set(key, occurrence + 1);
    result.notes.push({ id: await memoUUID('joplin:md:' + key + ':' + occurrence), body, createdAt, reading: null, turns: [] });
  }
  return result;
}

export async function parseJoplinFiles(files, timeZone = 'Asia/Shanghai') {
  const selected = Array.from(files ?? []);
  if (!selected.length) throw new Error('请选择 JEX 文件、Markdown 文件或导出目录。');
  const archives = selected.filter(file => !file.webkitRelativePath && jex.test(file.name));
  if (archives.length > 1) throw new Error('一次只能导入一个 JEX 文件。');
  if (archives.length && selected.some(file => markdown.test(file.name))) {
    throw new Error('不能混选 JEX 和 Markdown 文件。');
  }
  if (archives.length && selected.length === 1) return parseJoplinJex(archives[0]);
  if (archives.length) throw new Error('请单独选择一个 JEX 文件。');
  return parseJoplinMarkdownFiles(selected, timeZone);
}
