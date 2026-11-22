const TAG_RE = /(?<![\p{L}\p{N}_])#([\p{L}\p{N}_]+(?:\/[\p{L}\p{N}_]+)*)/gu;
const HAS_NON_DIGIT_RE = /[^\p{N}]/u;

export function tagsFor(body) {
  const seen = new Map();
  for (const [, tag] of (body || '').matchAll(TAG_RE)) {
    if (!HAS_NON_DIGIT_RE.test(tag)) continue;
    const key = tag.toLowerCase();
    if (!seen.has(key)) seen.set(key, tag);
  }
  return [...seen.values()];
}

export function buildTagTree(notes, sortMode = 'count') {
  const roots = new Map();

  for (let idx = 0; idx < notes.length; idx++) {
    const note = notes[idx];
    const noteId = note.id ?? idx;
    const tags = Array.isArray(note.tags) ? note.tags : tagsFor(note.body);
    const seenPaths = new Set();

    for (const rawTag of tags) {
      if (!rawTag || !HAS_NON_DIGIT_RE.test(rawTag)) continue;
      const parts = rawTag.split('/').filter(Boolean);
      let map = roots;
      let path = '';
      for (const seg of parts) {
        const key = seg.toLowerCase();
        path = path ? `${path}/${key}` : key;
        let node = map.get(key);
        if (!node) {
          node = { key, name: seg, path, noteIds: new Set(), childrenMap: new Map() };
          map.set(key, node);
        }
        if (!seenPaths.has(path)) {
          seenPaths.add(path);
          node.noteIds.add(noteId);
        }
        map = node.childrenMap;
      }
    }
  }

  const compare = sortMode === 'alpha'
    ? (a, b) => a.name.localeCompare(b.name, 'zh-CN')
    : (a, b) => b.count - a.count || a.name.localeCompare(b.name, 'zh-CN');

  function finalize(map) {
    const list = [];
    for (const node of map.values()) {
      list.push({
        key: node.key,
        name: node.name,
        path: node.path,
        count: node.noteIds.size,
        children: finalize(node.childrenMap),
      });
    }
    list.sort(compare);
    return list;
  }

  return finalize(roots);
}

export function tokenizeBody(body) {
  const str = body || '';
  if (!str) return [];
  const tokens = [];
  let lastIndex = 0;
  for (const match of str.matchAll(TAG_RE)) {
    const tag = match[1];
    if (!HAS_NON_DIGIT_RE.test(tag)) continue;
    const index = match.index;
    if (index > lastIndex) {
      tokens.push({ type: 'text', text: str.slice(lastIndex, index) });
    }
    tokens.push({ type: 'tag', text: match[0], tag });
    lastIndex = index + match[0].length;
  }
  if (lastIndex < str.length) {
    tokens.push({ type: 'text', text: str.slice(lastIndex) });
  }
  return tokens;
}

export function sampleRandomNotes(notes, count = 10, rng = Math.random) {
  const copy = [...notes];
  const limit = Math.min(Math.max(0, count), copy.length);
  for (let i = 0; i < limit; i++) {
    const span = copy.length - i;
    const offset = Math.min(span - 1, Math.max(0, Math.floor(rng() * span)));
    const j = i + offset;
    if (j !== i) {
      const tmp = copy[i];
      copy[i] = copy[j];
      copy[j] = tmp;
    }
  }
  return copy.slice(0, limit);
}
