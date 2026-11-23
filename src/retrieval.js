export function tokenizeForFts(text) {
  const tokens = new Set();
  for (const [word] of String(text ?? '').toLowerCase().matchAll(/[a-z0-9]{2,}|[\p{Script=Han}\p{Script=Hiragana}\p{Script=Katakana}\p{Script=Hangul}]+/gu)) {
    if (/^[a-z0-9]/.test(word)) tokens.add(word);
    else {
      const chars = [...word];
      if (chars.length === 1) tokens.add(chars[0]);
      for (let i = 1; i < chars.length && tokens.size < 400; i++) tokens.add(chars[i - 1] + chars[i]);
    }
    if (tokens.size >= 400) break;
  }
  return [...tokens];
}

export function buildFtsQuery(query) {
  return ftsQueryForTokens(tokenizeForFts(query));
}

export function ftsQueryForTokens(tokens) {
  return tokens.map(token => '"' + token + '"').join(' OR ');
}

export function normalizeVector(arr) {
  const norm = Math.sqrt(arr.reduce((sum, value) => sum + value * value, 0));
  return Float32Array.from(arr, value => norm ? value / norm : 0);
}

export function cosineSimilarity(a, b) {
  if (!a || !b || a.length !== b.length) return 0;
  let dot = 0, aa = 0, bb = 0;
  for (let i = 0; i < a.length; i++) {
    dot += a[i] * b[i];
    aa += a[i] * a[i];
    bb += b[i] * b[i];
  }
  return aa && bb ? Math.max(-1, Math.min(1, dot / Math.sqrt(aa * bb))) : 0;
}

export function vectorToBlob(vec) {
  return new Uint8Array(vec.buffer.slice(vec.byteOffset, vec.byteOffset + vec.byteLength));
}

export function blobToVector(blob) {
  return new Float32Array(Uint8Array.from(blob).buffer);
}

export function noteIndexText(note) {
  return [note.reading?.bookTitle, note.reading?.chapter, note.reading?.author, note.body].filter(Boolean).join('\n');
}

// Two independent 32-bit accumulators keep hashing fast during synchronous reconciliation.
export function contentHashHex(text) {
  let a = 2166136261, b = 0x9e3779b9;
  for (let i = 0; i < text.length; i++) {
    const ch = text.charCodeAt(i);
    a = Math.imul(a ^ ch, 16777619);
    b = Math.imul(b ^ ch, 0x85ebca6b);
    b ^= b >>> 13;
  }
  return [a, b].map(x => (x >>> 0).toString(16).padStart(8, '0')).join('');
}

export function extractNoteTags(body) {
  return [...new Set([...String(body ?? '').matchAll(/(?<![\p{L}\p{N}_])#([\p{L}\p{N}_]+(?:\/[\p{L}\p{N}_]+)*)/gu)]
    .map(([, tag]) => tag.toLowerCase()).filter(tag => /[^\p{N}]/u.test(tag)))];
}

export function noteMetadata(note) {
  return { tags: extractNoteTags(note.body), bookTitle: note.reading?.bookTitle?.trim().toLowerCase(), createdAt: note.createdAt };
}

function metaScore(a, b, sharedTags) {
  const sameBook = a.bookTitle && a.bookTitle === b.bookTitle;
  return Math.min(1, (sameBook ? 0.7 : 0) + sharedTags.length * 0.35);
}

export function metaOverlapScore(a, b) {
  const left = noteMetadata(a), right = noteMetadata(b);
  return metaScore(left, right, left.tags.filter(tag => right.tags.includes(tag)));
}

export function fuseHybridScore({ cosine = 0, ftsNorm = 0, metaOverlap = 0, hasVectors, isQuery }) {
  const lexical = isQuery ? ftsNorm : 0.72 * ftsNorm + 0.28 * metaOverlap;
  return hasVectors ? 0.65 * Math.max(0, cosine) + 0.35 * lexical : lexical;
}

export function tokenOverlap(queryTokens, noteTokens, isQuery) {
  const matches = noteTokens.reduce((count, token) => count + Number(queryTokens.has(token)), 0);
  return matches / (isQuery ? queryTokens.size || 1 : Math.sqrt(queryTokens.size * noteTokens.length) || 1);
}

export function rankNoteIds(metadata, { focusId, queryTokens, limit = 10, excludeIds = [], includeIds, vector, vectors, matches }) {
  const isQuery = focusId === undefined;
  const focus = metadata.get(focusId);
  const excluded = new Set(excludeIds);
  const included = includeIds == null || includeIds instanceof Set ? includeIds : new Set(includeIds);
  if (!isQuery) excluded.add(focusId);
  const tokens = new Set(queryTokens);
  if (isQuery && !tokens.size) return [];
  const ranked = [];
  for (const [id, note] of metadata) {
    if (excluded.has(id) || (included && !included.has(id))) continue;
    const candidateVector = vectors?.get(id)?.vector;
    const hasVectors = Boolean(vector && candidateVector && vector.length === candidateVector.length);
    const noteTokens = matches.get(id);
    const sharedTags = focus?.tags.length && note.tags.length ? focus.tags.filter(tag => note.tags.includes(tag)) : [];
    const score = fuseHybridScore({
      cosine: hasVectors ? cosineSimilarity(vector, candidateVector) : 0,
      ftsNorm: noteTokens ? tokenOverlap(tokens, noteTokens, isQuery) : 0,
      metaOverlap: focus ? metaScore(focus, note, sharedTags) : 0,
      hasVectors, isQuery,
    });
    if (score > 0) ranked.push({ id, score, relevancePercent: Math.round(score * 100), sharedTags });
  }
  return ranked.sort((a, b) => b.score - a.score || String(metadata.get(b.id).createdAt).localeCompare(String(metadata.get(a.id).createdAt)) || a.id.localeCompare(b.id))
    .slice(0, limit);
}

function rankLexicalNotes(notes, queryTokens, opts, focus) {
  const byId = new Map(), metadata = new Map(), matches = new Map();
  for (const note of notes) {
    byId.set(note.id, note);
    metadata.set(note.id, noteMetadata(note));
    matches.set(note.id, tokenizeForFts(noteIndexText(note)));
  }
  if (focus) metadata.set(focus.id, noteMetadata(focus));
  return rankNoteIds(metadata, { ...opts, queryTokens, matches, focusId: focus?.id })
    .map(item => ({ ...item, note: byId.get(item.id) }));
}

export function lexicalFallbackRelated(focusNote, allNotes, limit) {
  return rankLexicalNotes(allNotes, tokenizeForFts(noteIndexText(focusNote)), { limit }, focusNote);
}

export function lexicalFallbackSearch(query, allNotes, opts) {
  const tokens = tokenizeForFts(query);
  return tokens.length ? rankLexicalNotes(allNotes, tokens, opts) : [];
}

export function escapeContextTags(text) {
  return text.replace(/<(\/?(?:当前笔记|长期个人画像|相关历史笔记|画像生成任务|洞察笔记资料|洞察视角任务))>/g, '‹$1›');
}

export function buildNoteContextBlock(entries, { maxTotalChars = 12000, pinnedMaxChars = 2000, retrievedMaxChars = 1000 } = {}) {
  const lines = [];
  const citations = [];
  const seen = new Set();
  let remaining = maxTotalChars;
  for (const entry of entries) {
    const note = entry.note ?? entry;
    const { id, body, createdAt, reading } = note;
    if (!body?.trim() || (id && seen.has(id))) continue;
    if (id) seen.add(id);
    const ref = 'N' + (lines.length + 1);
    const date = createdAt?.slice(0, 10) ?? '';
    const bookTitle = reading?.bookTitle;
    const prefix = '[' + ref + '] (' + (date ? date + ' | ' : '') + escapeContextTags(bookTitle || '日志').replace(/\s+/g, ' ') + ') ';
    const excerpt = body.trim().replace(/\r?\n(?=\[N\d+\])/g, '\n ')
      .slice(0, Math.min(entry.pinned ? pinnedMaxChars : retrievedMaxChars, Math.max(0, remaining - prefix.length)));
    if (!excerpt.trim()) break;
    lines.push(prefix + escapeContextTags(excerpt));
    remaining -= prefix.length + excerpt.length + 2;
    if (id) citations.push({ ref, noteId: id, createdAt, excerpt, ...(bookTitle ? { bookTitle } : {}) });
    if (lines.length >= 20) break;
  }
  return { text: lines.join('\n\n'), citations };
}

export function extractCitedRefs(replyText, citations) {
  const refs = new Set([...replyText.matchAll(/\[(N\d+)\]/g)].map(([, ref]) => ref));
  return { citations: citations.filter(citation => refs.has(citation.ref)), allCitations: citations };
}

export function packNoteContext({ currentNote = '', profileText = '', pinnedNotes = [], retrievedNotes = [], maxChars = 12000 }) {
  const current = currentNote.trim() ? ['<当前笔记>\n', '\n</当前笔记>'] : null;
  const profile = profileText.trim() ? ['<长期个人画像>\n', '\n</长期个人画像>'] : null;
  const entries = [...pinnedNotes.map(note => ({ note, pinned: true })), ...retrievedNotes];
  const wrapper = (tags, body) => tags && body ? tags[0] + body + tags[1] : '';
  const wrapperSize = tags => tags ? tags[0].length + tags[1].length + 2 : 0;
  const noteTags = entries.length ? ['<相关历史笔记>\n', '\n</相关历史笔记>'] : null;
  const budget = Math.max(0, maxChars - wrapperSize(current) - wrapperSize(profile) - wrapperSize(noteTags));
  // Keep room for each explicit source before allocating the rest to retrieved notes.
  const currentBody = currentNote.trim().slice(0, entries.length || profile ? Math.min(6000, Math.floor(budget * 0.5)) : budget);
  const available = budget - currentBody.length;
  const pins = buildNoteContextBlock(entries.slice(0, pinnedNotes.length), { maxTotalChars: available });
  const profileBody = profileText.trim().slice(0, Math.max(0, available - pins.text.length - (pins.text ? 2 : 0)));
  const notes = buildNoteContextBlock(entries, { maxTotalChars: available - profileBody.length });
  return {
    text: [wrapper(current, escapeContextTags(currentBody)), wrapper(profile, escapeContextTags(profileBody)), wrapper(noteTags, notes.text)].filter(Boolean).join('\n\n'),
    citations: notes.citations,
  };
}

export function packRelayNoteContext(options) {
  return packNoteContext(options).text;
}
