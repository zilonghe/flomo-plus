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

export function appendCitedText(node, text, citations = []) {
  const refs = new Map(citations.map(citation => [citation.ref, citation]));
  let start = 0;
  for (const match of text.matchAll(/\[(N\d+)\]/g)) {
    const citation = refs.get(match[1]);
    if (!citation) continue;
    const button = node.ownerDocument.createElement('button');
    button.type = 'button';
    button.className = 'citation-chip';
    button.dataset.citeNoteId = citation.noteId;
    button.textContent = match[0];
    button.title = citation.bookTitle || '查看原笔记';
    node.append(text.slice(start, match.index), button);
    start = match.index + match[0].length;
  }
  node.append(text.slice(start));
}

export function renderSafeMarkdown(container, markdown, citations = []) {
  const doc = container.ownerDocument;
  const blocks = [];
  const inline = (node, text) => {
    let start = 0;
    for (const match of text.matchAll(/\*\*([^*\n]+)\*\*/g)) {
      appendCitedText(node, text.slice(start, match.index), citations);
      const strong = doc.createElement('strong');
      appendCitedText(strong, match[1], citations);
      node.append(strong);
      start = match.index + match[0].length;
    }
    appendCitedText(node, text.slice(start), citations);
  };
  let list, listType;
  let paragraph = [];
  const flush = () => {
    if (!paragraph.length) return;
    const node = doc.createElement('p');
    inline(node, paragraph.join('\n'));
    blocks.push(node);
    paragraph = [];
  };
  for (const raw of markdown.split(/\r?\n/)) {
    const line = raw.trim();
    const heading = line.match(/^(#{2,3})\s+(.+)$/);
    const item = line.match(/^([-+*]|\d+\.)\s+(.+)$/);
    if (item) {
      flush();
      const type = /^\d/.test(item[1]) ? 'ol' : 'ul';
      if (!list || listType !== type) {
        list = doc.createElement(type);
        listType = type;
        blocks.push(list);
      }
      const li = doc.createElement('li');
      inline(li, item[2]);
      list.append(li);
      continue;
    }
    list = null;
    if (heading) {
      flush();
      const node = doc.createElement('h' + heading[1].length);
      inline(node, heading[2]);
      blocks.push(node);
    } else if (line) paragraph.push(line);
    else flush();
  }
  flush();
  container.textContent = '';
  container.append(...blocks);
}
