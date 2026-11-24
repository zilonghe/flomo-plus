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
    for (const match of text.matchAll(/\*\*([^*\n]+)\*\*|`([^`\n]+)`/g)) {
      appendCitedText(node, text.slice(start, match.index), citations);
      if (match[1] !== undefined) {
        const strong = doc.createElement('strong');
        appendCitedText(strong, match[1], citations);
        node.append(strong);
      } else if (/^(?:\[N\d+\](?:[\s,，、]*))+$/.test(match[2]) &&
          citations.some(({ ref }) => match[2].includes('[' + ref + ']'))) {
        appendCitedText(node, match[2], citations);
      } else {
        const code = doc.createElement('code');
        code.textContent = match[2];
        node.append(code);
      }
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
  let fence = 0, codeLines = [];
  const flushCode = () => {
    const pre = doc.createElement('pre');
    const code = doc.createElement('code');
    code.textContent = codeLines.join('\n');
    pre.append(code);
    blocks.push(pre);
    codeLines = [];
  };
  for (const raw of markdown.split(/\r?\n/)) {
    const marker = codeFence(raw);
    if (fence) {
      if (marker && marker[1].length >= fence && !marker[2].trim()) {
        flushCode();
        fence = 0;
      } else codeLines.push(raw);
      continue;
    }
    if (marker) {
      flush();
      list = null;
      fence = marker[1].length;
      continue;
    }
    const line = raw.trim();
    const heading = line.match(/^(#{1,4})\s+(.+)$/);
    const item = line.match(/^([-+*]|\d+\.)\s+(.+)$/);
    const quote = line.match(/^>\s?(.*)$/);
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
      const node = doc.createElement('h' + Math.min(4, Math.max(2, heading[1].length)));
      inline(node, heading[2]);
      blocks.push(node);
    } else if (/^(-{3,}|\*{3,})$/.test(line)) {
      flush();
      blocks.push(doc.createElement('hr'));
    } else if (quote) {
      flush();
      const node = doc.createElement('blockquote');
      inline(node, quote[1]);
      blocks.push(node);
    } else if (line) paragraph.push(line);
    else flush();
  }
  flush();
  if (fence) flushCode();
  container.replaceChildren(...blocks);
}

function codeFence(line) {
  return /^ {0,3}(`{3,})([^`]*)$/.exec(line);
}

export function splitStreamingMarkdown(markdown) {
  const stableBlocks = [];
  let fence = 0, start = 0;
  for (const line of markdown.matchAll(/([^\r\n]*)\r?\n/g)) {
    const marker = codeFence(line[1]);
    if (marker) {
      if (!fence) fence = marker[1].length;
      else if (marker[1].length >= fence && !marker[2].trim()) fence = 0;
    }
    const end = line.index + line[0].length;
    if (!fence && !line[1].trim()) {
      const block = markdown.slice(start, end).trimEnd();
      if (block.trim()) stableBlocks.push(block);
      start = end;
    }
  }
  return { stableBlocks, tail: markdown.slice(start) };
}

// Only the tail is replaced. A paragraph joins the frozen prefix once its blank line arrives.
const renderedStreams = new WeakMap();
const noCitations = [];
export function updateStreamingMarkdown(container, markdown, citations = noCitations) {
  let stream = renderedStreams.get(container);
  if (!stream || !markdown.startsWith(stream.prefix) || stream.citations !== citations) {
    container.replaceChildren();
    stream = { prefix: '', citations, tail: container.ownerDocument.createElement('div'), text: null };
    stream.tail.className = 'ai-stream-tail';
    container.append(stream.tail);
    renderedStreams.set(container, stream);
  }
  const rest = markdown.slice(stream.prefix.length);
  const { stableBlocks, tail } = splitStreamingMarkdown(rest);
  if (stableBlocks.length) {
    const fragment = container.ownerDocument.createElement('div');
    for (const block of stableBlocks) {
      renderSafeMarkdown(fragment, block, citations);
      stream.tail.before(...fragment.childNodes);
    }
  }
  stream.prefix += rest.slice(0, rest.length - tail.length);
  if (tail !== stream.text) {
    renderSafeMarkdown(stream.tail, tail, citations);
    stream.text = tail;
  }
  return stream.tail;
}

export async function notesCacheTransaction(mode, operation, isCurrent = () => true, win = globalThis) {
  const db = await new Promise((resolve, reject) => {
    const open = win.indexedDB.open('weiji-notes-cache', 1);
    open.onupgradeneeded = () => open.result.createObjectStore('accounts', { keyPath: 'userId' });
    open.onsuccess = () => resolve(open.result);
    open.onerror = () => reject(open.error);
  });
  try {
    if (!isCurrent()) return;
    return await new Promise((resolve, reject) => {
      const tx = db.transaction('accounts', mode);
      const request = operation(tx.objectStore('accounts'));
      tx.oncomplete = () => resolve(request.result);
      tx.onabort = () => reject(tx.error);
    });
  } finally {
    db.close();
  }
}

export function clearWeijiCacheDB(userId, win = globalThis) {
  return notesCacheTransaction('readwrite', store => userId ? store.delete(userId) : store.clear(), undefined, win)
    .catch(() => {});
}

export const weijiAuthEvent = 'weiji_auth_event';
export function publishWeijiAuthEvent(win = globalThis.window) {
  try { win.localStorage.setItem(weijiAuthEvent, JSON.stringify({ type: 'logout', at: Date.now() })); } catch {}
}

export function bindConnectLogout(doc = globalThis.document, win = globalThis.window) {
  const control = doc?.querySelector('[data-connect-logout]');
  if (!control || control.dataset.logoutBound) return;
  control.dataset.logoutBound = 'true';
  const oauth = control.dataset.connectLogout === 'oauth';
  const button = oauth ? control.querySelector('button[type="submit"]') : null;
  const signoutHref = control.dataset.signoutHref;
  let pending = false;
  const logout = async event => {
    event.preventDefault();
    if (pending) return;
    pending = true;
    if (button) button.disabled = true;
    publishWeijiAuthEvent(win);
    await clearWeijiCacheDB(undefined, win);
    if (oauth) control.submit();
    else (win.top ?? win).location.href = signoutHref;
  };
  control.addEventListener(oauth ? 'submit' : 'click', logout);
  if (button) button.disabled = false;
  else {
    control.addEventListener('auxclick', event => { if (event.button === 1) void logout(event); });
    control.addEventListener('contextmenu', event => event.preventDefault());
    control.href = signoutHref;
    control.removeAttribute('aria-disabled');
    control.removeAttribute('tabindex');
  }
}

bindConnectLogout();
