import { parseWeRead, readWeReadFile } from './weread.js';
import { parseFlomoFile } from './flomo.js';
import { parseJoplinFiles } from './joplin.js';
import { randomUUID } from './crypto.js';
import { tagsFor, buildTagTree, tokenizeBody, appendCitedText, renderSafeMarkdown, updateStreamingMarkdown,
  clearWeijiCacheDB, notesCacheTransaction, publishWeijiAuthEvent, weijiAuthEvent } from './ux-helpers.js';

const $ = (id) => document.getElementById(id);
const SVG_NS = 'http://www.w3.org/2000/svg';
const FEED_PAGE_SIZE = 40;
const pageUserId = document.querySelector('meta[name="weiji-user-id"]')?.content || null;
function authEventStamp() {
  try { return localStorage.getItem(weijiAuthEvent); } catch { return null; }
}
let pageAuthStamp = authEventStamp();
function parseAuthEvent(raw) {
  if (!raw) return null;
  try { return JSON.parse(raw); } catch { return { type: 'logout' }; }
}
function authEventRevokesAccount(raw, account = state.user?.id ?? pageUserId) {
  if (!raw || raw === pageAuthStamp) return false;
  const payload = parseAuthEvent(raw);
  if (!payload) return false;
  if (payload.type === 'session') {
    if (!account) return false;
    return payload.userId !== account;
  }
  return true;
}
function syncAuthStampIfCompatible(account = state.user?.id ?? pageUserId) {
  const current = authEventStamp();
  if (current === pageAuthStamp) return true;
  if (authEventRevokesAccount(current, account)) return false;
  pageAuthStamp = current;
  return true;
}
const state = {
  notes: new Map(),
  deletedNotes: new Map(),
  notesETag: null,
  syncEpoch: 0,
  authSuspended: false,
  noteIndex: null,
  filter: 'all',
  tagSort: 'count',
  collapsedTags: new Set(),
  dayFilter: null,
  sortOrder: 'newest',
  feedItems: [],
  feedRendered: 0,
  tagSuggest: { open: false, items: [], activeIndex: 0, start: 0, end: 0 },
  user: null,
  authMode: null,
  loaded: false,
  refreshing: false,
  writeEpoch: 0,
  writeCount: 0,
  noteID: null,
  editRevision: null,
  composeDraft: null,
  importItems: null,
  importWorking: false,
  wereadImport: null,
  flomoImport: null,
  flomoWorking: false,
  joplinImport: null,
  joplinWorking: false,
  detailWorking: false,
  model: 'gpt-4.1-mini',
  chatProvider: 'openai',
  codexAvailable: false,
  codexMode: null,
  gatewayModels: [],
  gatewayModelMeta: [],
  defaultGatewayModel: null,
  reasoningEffort: '',
  gatewayModel: null,
  apiKey: '',
};

const filters = { all: '全部笔记', journal: '随记', reading: '读书' };
const dateLong = new Intl.DateTimeFormat('zh-CN', { year: 'numeric', month: 'long', day: 'numeric' });
const dateTime = new Intl.DateTimeFormat('zh-CN', { hour: '2-digit', minute: '2-digit', hourCycle: 'h23' });
let toastTimer;
let searchTimer = null;
let feedObserver = null;
let suppressNextTagSuggestKeyup = false;

function el(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text != null) node.textContent = text;
  return node;
}

function icon(name) {
  const svg = document.createElementNS(SVG_NS, 'svg');
  const use = document.createElementNS(SVG_NS, 'use');
  use.setAttribute('href', '#i-' + name);
  svg.setAttribute('aria-hidden', 'true');
  svg.append(use);
  return svg;
}

function labeled(node, iconName, text) {
  node.replaceChildren(icon(iconName), text);
  return node;
}

function actionButton(label, action, extra = '') {
  const button = el('button', 'button button-secondary ' + extra, label);
  button.type = 'button';
  button.dataset.action = action;
  return button;
}

function setError(id, message) {
  const node = $(id);
  node.textContent = message || '';
  node.hidden = !message;
}

function notify(message) {
  clearTimeout(toastTimer);
  $('toast').textContent = message;
  $('toast').hidden = false;
  toastTimer = setTimeout(() => { $('toast').hidden = true; }, 3400);
}

function setSync(status, message) {
  const node = $('sync-state');
  if (node.dataset.status === status && node.firstChild?.textContent === message) return;
  node.dataset.status = status;
  node.hidden = status === 'ok';
  node.textContent = message;
  if (status === 'error') node.append(actionButton('重试', 'retry-sync'));
}

function setAuthNotice(message, signIn = false) {
  $('connection-error').hidden = !message;
  $('connection-error-text').textContent = message || '';
  $('sign-in').hidden = !signIn;
}

class ApiError extends Error {
  constructor(status, data, message) {
    super(data?.error || message);
    this.status = status;
    this.current = data?.current;
    this.deleted = data?.deleted;
  }
}

function apiHeaders(hasBody) {
  const headers = { Accept: 'application/json' };
  if (state.user?.id) headers['X-Journal-Account'] = state.user.id;
  if (hasBody) headers['Content-Type'] = 'application/json';
  return headers;
}

function checkRequestContext(epoch, signal) {
  if (epoch !== state.syncEpoch || signal?.aborted) throw new DOMException('请求已取消', 'AbortError');
  if (!syncAuthStampIfCompatible()) {
    if (!state.authSuspended) void invalidateAccount({ broadcast: false });
    throw new DOMException('登录状态已变化', 'AbortError');
  }
}

async function fetchAPI(path, body, signal, method, accept) {
  const headers = apiHeaders(body !== undefined);
  headers.Accept = accept;
  try {
    return await fetch(path, {
      method,
      credentials: 'same-origin',
      cache: 'no-store',
      redirect: 'error',
      signal,
      headers,
      body: body === undefined ? undefined : JSON.stringify(body),
    });
  } catch (error) {
    if (error.name === 'AbortError') throw error;
    throw new Error('网络连接失败，请检查连接后重试。');
  }
}

async function readAPIJSON(response, epoch, signal) {
  checkRequestContext(epoch, signal);
  if (response.status === 401 || response.status === 403) {
    void invalidateAccount();
    void response.body?.cancel().catch(() => {});
    throw new ApiError(response.status, null, response.status === 401
      ? '登录状态已过期，请重新登录。' : '登录账号已变化，请重新连接后同步。');
  }
  const data = await response.json().catch(() => null);
  checkRequestContext(epoch, signal);
  if (!response.ok || !data) {
    throw new ApiError(response.status, data, '服务暂时无法响应，请稍后重试。');
  }
  return data;
}

async function request(path, body, signal, method = body === undefined ? 'GET' : 'POST') {
  const epoch = state.syncEpoch;
  const response = await fetchAPI(path, body, signal, method, 'application/json');
  return readAPIJSON(response, epoch, signal);
}

async function requestStream(path, body, { signal, onEvent }) {
  const epoch = state.syncEpoch;
  const response = await fetchAPI(path, body, signal, 'POST', 'text/event-stream');
  checkRequestContext(epoch, signal);
  if (!response.ok || !response.headers.get('Content-Type')?.startsWith('text/event-stream')) {
    await readAPIJSON(response, epoch, signal);
    throw new Error('服务没有返回报告流，请重试。');
  }
  const reader = response.body.getReader();
  const decoder = new TextDecoder('utf-8');
  let pending = '';
  try {
    while (true) {
      const { done, value } = await reader.read();
      checkRequestContext(epoch, signal);
      pending += done ? decoder.decode() : decoder.decode(value, { stream: true });
      let boundary;
      while ((boundary = /\r?\n\r?\n/.exec(pending))) {
        const lines = pending.slice(0, boundary.index).split(/\r?\n/);
        pending = pending.slice(boundary.index + boundary[0].length);
        const event = lines.find(line => line.startsWith('event:'))?.slice(6).trim();
        const data = lines.filter(line => line.startsWith('data:')).map(line => line.slice(5).trimStart()).join('\n');
        if (event && data) onEvent(event, JSON.parse(data));
      }
      if (done) return;
    }
  } finally {
    void reader.cancel().catch(() => {});
  }
}

function updateProfile() {
  const { name, email } = state.user || {};
  $('sign-out').hidden = !state.user;
  $('settings-account').textContent = email || name || (state.user ? 'ChatGPT 账号' : '未登录');
}

let accountLifecycle = new AbortController();
let pendingProfileSave = null;
let failedProfileSave = null;
let pendingStyleSave = null;
let failedStyleSave = null;
function resetAccount() {
  state.syncEpoch++;
  accountLifecycle.abort();
  accountLifecycle = new AbortController();
  pendingProfileSave = pendingStyleSave = null;
  failedProfileSave = failedStyleSave = null;
  closeAIChat();
  closeProfile();
  closeWritingStyle();
  sidebar(false);
  clearDeleteUndo();
  state.user = null;
  state.authMode = null;
  state.loaded = false;
  state.notesETag = null;
  state.refreshing = false;
  showSyncSkeleton(true);
  state.notes.clear();
  state.deletedNotes.clear();
  state.noteIndex = null;
  state.dayFilter = null;
  closeTagSuggest();
  state.apiKey = '';
  state.chatProvider = 'openai';
  state.codexAvailable = false;
  state.codexMode = null;
  gatewayModelsRevision++;
  state.gatewayModels = [];
  state.gatewayModelMeta = [];
  state.defaultGatewayModel = null;
  state.reasoningEffort = state.defaultEffort = '';
  state.gatewayModel = state.preferredModel = null;
  $('semantic-status').hidden = true;
  $('settings-data-pane').querySelector('[data-action=semantic-reindex]').hidden = true;
  renderGatewayModels();
  state.composeDraft = null;
  $('note-body').value = '';
  clearSearchInput();
  $('edit-body').value = '';
  $('import-text').value = '';
  importMode(null);
  resetWereadImport();
  resetFileImport('flomo', true);
  resetFileImport('joplin', true);
  for (const id of ['settings-dialog', 'import-hub-dialog', 'import-dialog', 'flomo-dialog', 'joplin-dialog', 'insight-lens-dialog']) if ($(id).open) $(id).close();
  if ($('note-dialog').open) closeNote(true);
  reader.cache.clear();
  for (const id of ['detail-body', 'detail-meta', 'detail-source', 'edit-remote', 'reader-related-list']) $(id).replaceChildren();
  setError('detail-error', '');
  $('dialog-note-title').textContent = '笔记';
  $('auth-sessions-list').replaceChildren();
  $('admin-invites-list').replaceChildren();
  $('admin-invite-created').textContent = '';
  $('admin-invite-created').hidden = true;
  state.filter = 'all';
  state.collapsedTags.clear();
  $('openai-key').value = '';
  $('note-body').disabled = true;
  syncComposerUI();
  rebuildNoteIndex();
  renderFeedList({ reset: true });
  updateProfile();
  setAuthNotice('');
  $('toast').hidden = true;
}

function showSyncSkeleton(show) {
  $('sync-skeleton').hidden = !show;
  document.body.classList.toggle('auth-checking', show);
}

async function invalidateAccount({ reload = false, broadcast = true, notice = true, authEvent = null } = {}) {
  const account = state.user?.id ?? pageUserId;
  const oauth = state.authMode === 'oauth';
  suspendedComposeDraft = null;
  state.authSuspended = true;
  resetAccount();
  const epoch = state.syncEpoch;
  if (broadcast) {
    publishWeijiAuthEvent(window, authEvent ?? { type: 'logout', ...(account ? { userId: account } : {}) });
    pageAuthStamp = authEventStamp();
  }
  await clearWeijiCacheDB(account);
  if (epoch !== state.syncEpoch) return;
  if (reload) location.replace('/');
  else if (notice) {
    showSyncSkeleton(false);
    if (oauth) $('sign-in').href = '/';
    setAuthNotice('登录状态已失效，请重新登录。', true);
    setSync('error', '登录状态已失效');
  }
}

function cacheSnapshot() {
  const userId = state.user?.id;
  if (!userId || !state.loaded) return Promise.resolve();
  const epoch = state.syncEpoch;
  const snapshot = {
    userId, etag: state.notesETag, notes: [...state.notes.values()], deleted: [...state.deletedNotes.values()], savedAt: Date.now(),
  };
  return notesCacheTransaction('readwrite', store => store.put(snapshot), () => epoch === state.syncEpoch && syncAuthStampIfCompatible(userId))
    .catch(() => {});
}

function finishLocalWrites(changed) {
  if (!changed) return;
  state.notesETag = null;
  void cacheSnapshot();
}

function applyNotesSnapshot({ notes, deleted, etag }) {
  const previous = state.notes;
  const current = new Map(notes.map(note => [note.id, note]));
  const firstLoad = !state.loaded;
  const validatorChanged = state.notesETag !== etag;
  const changed = validatorChanged || previous.size !== current.size ||
    [...current].some(([id, note]) => previous.get(id)?.revision !== note.revision);
  const openChanged = state.noteID && (validatorChanged || previous.get(state.noteID)?.revision !== current.get(state.noteID)?.revision);
  state.notes = current;
  state.deletedNotes = new Map(deleted.map(item => [item.id, item]));
  state.notesETag = etag;
  state.loaded = true;
  if (firstLoad) void loadGatewayModels();
  setAuthNotice('');
  showSyncSkeleton(false);
  $('note-body').disabled = false;
  updateComposer();
  if (changed || firstLoad) {
    rebuildNoteIndex();
    renderFeedList({ reset: true, preservePage: true });
    syncReaderNotes();
  }
  if (openChanged && $('note-dialog').open) showRemoteDetail();
}

function fetchNotesSnapshot(account, etag, signal) {
  const headers = { Accept: 'application/json', 'X-Journal-Account': account };
  if (etag) headers['If-None-Match'] = etag;
  return fetch('/api/notes', { credentials: 'same-origin', cache: 'no-store', redirect: 'error', headers, signal });
}

let activeRefresh;
function refresh(options) {
  if (state.authSuspended || state.writeCount) return;
  if (state.refreshing) return activeRefresh;
  return activeRefresh = syncNotes(options);
}

async function syncNotes({ silent = false } = {}) {
  state.refreshing = true;
  const epoch = state.syncEpoch;
  const writeEpoch = state.writeEpoch;
  const signal = accountLifecycle.signal;
  const isCurrent = () => epoch === state.syncEpoch;
  if (!silent || !state.loaded) setSync('loading', '正在同步');
  try {
    let notesRequest;
    if (!state.user) {
      const diskRead = pageUserId ? notesCacheTransaction('readonly', store => store.get(pageUserId), isCurrent)
        .then(snapshot => snapshot?.userId === pageUserId ? snapshot : null).catch(() => null) : Promise.resolve(null);
      // A response may finish first; do not consume or install it until the session is verified.
      if (pageUserId) notesRequest = diskRead.then(snapshot => {
        checkRequestContext(epoch, signal);
        return fetchNotesSnapshot(pageUserId, snapshot?.etag, signal);
      });
      notesRequest?.catch(() => {});
      const result = await request('/api/session', undefined, signal);
      if (!result.user?.id || (pageUserId && result.user.id !== pageUserId)) {
        const switched = Boolean(result.user?.id);
        await invalidateAccount({
          reload: switched,
          authEvent: switched ? { type: 'session', userId: result.user.id } : { type: 'logout', ...(pageUserId ? { userId: pageUserId } : {}) },
        });
        return;
      }
      state.user = result.user;
      state.authMode = result.authMode;
      state.codexAvailable = result.codexAvailable === true;
      state.codexMode = result.codexMode;
      state.chatProvider = state.codexAvailable ? 'codex' : 'openai';
      publishWeijiAuthEvent(window, { type: 'session', userId: result.user.id });
      pageAuthStamp = authEventStamp();
      updateProfile();
      if (suspendedComposeDraft) {
        if (suspendedComposeDraft.userId === result.user.id && !$('note-body').value) {
          $('note-body').value = suspendedComposeDraft.text;
          syncComposerUI();
        }
        suspendedComposeDraft = null;
      }
      if ($('settings-dialog').open) void loadAuthSettings();
      const cached = await diskRead;
      checkRequestContext(epoch, signal);
      if (cached) applyNotesSnapshot(cached);
    }
    const response = await (notesRequest ?? fetchNotesSnapshot(state.user.id, state.notesETag, signal));
    checkRequestContext(epoch, signal);
    if (response.status !== 304) {
      const result = await readAPIJSON(response, epoch, signal);
      if (writeEpoch !== state.writeEpoch || state.writeCount) return;
      applyNotesSnapshot({ ...result, etag: response.headers.get('ETag') });
      void cacheSnapshot();
    }
    if (writeEpoch === state.writeEpoch && !state.writeCount) setSync('ok', '已同步');
  } catch (error) {
    if (!isCurrent() || error.name === 'AbortError') return;
    if (!state.loaded) {
      showSyncSkeleton(false);
      setAuthNotice(error.message);
      state.refreshing = false;
      renderFeedList({ reset: true });
    }
    setSync('error', navigator.onLine ? '同步未完成' : '离线 · 无法同步');
  } finally {
    if (isCurrent()) {
      state.refreshing = false;
    }
  }
}

function showRemoteDetail() {
  const note = state.notes.get(state.noteID);
  if (!note) {
    if (state.editRevision === null) {
      readerBack();
      notify('这条笔记已在另一端删除');
      return;
    }
    setError('detail-error', '这条笔记已在另一端删除。你可以复制尚未保存的内容再关闭。');
    $('detail-actions').hidden = true;
    setUtilityMenu('reader-options', false);
    $('reader-related').hidden = true;
    return;
  }
  if (state.editRevision !== null) {
    setError('detail-error', '另一端更新了这条笔记。你的修改仍保留，保存时会检查冲突。');
  }
  renderDetail();
}

function acceptVersion(data) {
  if (data?.note) {
    state.notes.set(data.note.id, data.note);
    state.deletedNotes.delete(data.note.id);
  }
  if (data?.deleted) {
    state.notes.delete(data.deleted.id);
    state.deletedNotes.set(data.deleted.id, data.deleted);
  }
}

async function mutate(change) {
  ++state.writeEpoch;
  ++state.writeCount;
  setSync('loading', '正在同步');
  try {
    const data = await request('/api/notes', change);
    acceptVersion(data);
    finishLocalWrites(true);
    setSync('ok', '已同步');
    rebuildNoteIndex();
    renderFeedList({ reset: true, preservePage: true });
    syncReaderNotes();
    return data;
  } catch (error) {
    if (error.status === 409) {
      acceptVersion(error.current);
      finishLocalWrites(Boolean(error.current?.note || error.current?.deleted));
      rebuildNoteIndex();
      renderFeedList({ reset: true, preservePage: true });
      syncReaderNotes();
      setSync('ok', '已同步');
    } else {
      setSync('error', navigator.onLine ? '同步未完成' : '离线 · 无法同步');
      if (error.status === 401 || error.status === 403) setAuthNotice('登录状态已失效，请重新登录。', true);
    }
    throw error;
  } finally {
    --state.writeCount;
    ++state.writeEpoch;
  }
}

function notePayload(note) {
  return {
    id: note.id,
    body: note.body,
    createdAt: note.createdAt,
    reading: note.reading ?? null,
    turns: note.turns || [],
  };
}

function clearSearchInput() {
  clearTimeout(searchTimer);
  searchTimer = null;
  $('search').value = '';
}

function dayKey(date) {
  return [date.getFullYear(), date.getMonth() + 1, date.getDate()].map((part) => String(part).padStart(2, '0')).join('-');
}

function matchesTagPrefix(noteTags, prefix) {
  return noteTags.some((t) => {
    const l = t.toLowerCase();
    return l === prefix || l.startsWith(prefix + '/');
  });
}

function collectTagNames(nodes, parentDisplay, map) {
  for (const node of nodes) {
    const display = parentDisplay ? parentDisplay + '/' + node.name : node.name;
    map.set(node.path, display);
    if (node.children.length) collectTagNames(node.children, display, map);
  }
}

function rebuildNoteIndex() {
  const all = [...state.notes.values()];
  const counts = { all: all.length, journal: 0, reading: 0 };
  const byNote = new Map();
  const concreteTags = new Map();
  const dayCounts = new Map();
  const treeInput = [];

  for (const note of all) {
    counts[note.reading ? 'reading' : 'journal']++;
    const noteTags = tagsFor(note.body);
    byNote.set(note.id, noteTags);
    treeInput.push({ id: note.id, tags: noteTags });
    for (const tag of noteTags) {
      const key = tag.toLowerCase();
      const entry = concreteTags.get(key) || { tag, key, count: 0 };
      entry.count++;
      concreteTags.set(key, entry);
    }
    if (note.createdAt) {
      const key = dayKey(new Date(note.createdAt));
      dayCounts.set(key, (dayCounts.get(key) || 0) + 1);
    }
  }

  const tagTree = buildTagTree(treeInput, state.tagSort);
  const tagNames = new Map();
  collectTagNames(tagTree, '', tagNames);
  const tagFreq = [...concreteTags.values()].sort((a, b) => b.count - a.count || a.tag.localeCompare(b.tag, 'zh-CN'));

  state.noteIndex = {
    all,
    counts,
    byNote,
    tagTree,
    tagNames,
    tagFreq,
    dayCounts,
  };

  $('tag-section').hidden = tagTree.length === 0;
  renderActivity(counts, dayCounts);
  renderTagList();
  if (ai.lifecycle) renderAISessions();
}

function renderActivity(counts, dayCounts) {
  $('activity-memos').textContent = counts.all;
  $('activity-reading').textContent = counts.reading;
  $('activity-days').textContent = dayCounts.size;
  const date = new Date();
  date.setDate(date.getDate() - 83);
  const squares = [];
  const pulse = [];
  for (let i = 0; i < 84; i++, date.setDate(date.getDate() + 1)) {
    const key = dayKey(date);
    const count = dayCounts.get(key) || 0;
    const level = String(Math.min(count, 4));
    const square = el('button', 'heatmap-square');
    square.type = 'button';
    square.dataset.day = key;
    square.dataset.level = level;
    square.title = key + ' · ' + count + ' 条笔记';
    square.setAttribute('aria-label', square.title);
    squares.push(square);
    if (i >= 77) {
      const dot = el('i');
      dot.dataset.level = level;
      pulse.push(dot);
    }
  }
  $('heatmap').replaceChildren(...squares);
  $('mini-pulse').replaceChildren(...pulse);
}

function syncHeatmapActive() {
  for (const btn of $('heatmap').querySelectorAll('[data-day]')) {
    insPressed(btn, btn.dataset.day === state.dayFilter);
  }
}

function renderTagNode(node) {
  const wrap = el('div', 'tag-tree-node');
  const row = el('div', 'tag-row');
  const hasChildren = node.children.length > 0;
  const collapsed = state.collapsedTags.has(node.path);
  if (hasChildren) {
    const toggle = el('button', 'tag-toggle', collapsed ? '▸' : '▾');
    toggle.type = 'button';
    toggle.dataset.toggleTag = node.path;
    toggle.setAttribute('aria-expanded', String(!collapsed));
    toggle.setAttribute('aria-label', (collapsed ? '展开 ' : '折叠 ') + node.name);
    row.append(toggle);
  } else {
    row.append(el('span', 'tag-toggle-spacer'));
  }
  const button = el('button', 'nav-item tag-item');
  button.type = 'button';
  button.dataset.filter = 'tag:' + node.path;
  const selected = state.filter === 'tag:' + node.path;
  button.classList.toggle('active', selected);
  if (selected) button.setAttribute('aria-current', 'page');
  button.append(icon('hash'), el('span', '', node.name), el('span', 'nav-count', String(node.count)));
  row.append(button);
  wrap.append(row);
  if (hasChildren && !collapsed) {
    const childrenBox = el('div', 'tag-children');
    for (const child of node.children) childrenBox.append(renderTagNode(child));
    wrap.append(childrenBox);
  }
  return wrap;
}

function sortTagTree(nodes, sortMode) {
  const compare = sortMode === 'alpha'
    ? (a, b) => a.name.localeCompare(b.name, 'zh-CN')
    : (a, b) => b.count - a.count || a.name.localeCompare(b.name, 'zh-CN');
  nodes.sort(compare);
  for (const node of nodes) {
    if (node.children.length) sortTagTree(node.children, sortMode);
  }
  return nodes;
}

function renderTagList() {
  const sortBtn = $('tag-sort-btn');
  if (sortBtn) sortBtn.textContent = state.tagSort === 'count' ? '按数量' : '按字母';
  const tree = state.noteIndex?.tagTree || [];
  const fragment = document.createDocumentFragment();
  for (const node of tree) fragment.append(renderTagNode(node));
  $('tag-list').replaceChildren(fragment);
}

function syncNavActive() {
  const activeView = ai.visible ? 'open-ai-chat' : 'open-notes';
  for (const button of document.querySelectorAll('#sidebar [data-filter], .space-nav button')) {
    const selected = button.dataset.action ? button.dataset.action === activeView : button.dataset.filter === state.filter;
    button.classList.toggle('active', selected);
    if (selected) button.setAttribute('aria-current', 'page');
    else button.removeAttribute('aria-current');
  }
  $('mobile-toggle').hidden = $('note-nav-actions').hidden = Boolean(ai.visible);
  for (const item of document.querySelectorAll('[data-ai-nav]')) item.hidden = !ai.visible;
}

function syncSortButton() {
  const btn = $('sort-button');
  if (!btn) return;
  const isNewest = state.sortOrder === 'newest';
  btn.title = isNewest ? '最新优先（点击切换最旧优先）' : '最旧优先（点击切换最新优先）';
  btn.setAttribute('aria-label', isNewest ? '当前最新优先，切换排序' : '当前最旧优先，切换排序');
  btn.textContent = isNewest ? '最新优先' : '最旧优先';
}

function renderActiveFilters() {
  const box = $('active-filters');
  const filtersInUse = [];
  const query = $('search').value.trim();
  if (query) filtersInUse.push('搜索：' + query);
  if (state.filter !== 'all') {
    const tag = state.filter.slice(4);
    filtersInUse.push(filters[state.filter] || '#' + (state.noteIndex?.tagNames.get(tag) ?? tag));
  }
  if (state.dayFilter) filtersInUse.push(state.dayFilter);
  $('date-filter').value = state.dayFilter || '';
  $('sidebar').querySelector('[data-action="clear-day"]').hidden = !state.dayFilter;
  box.replaceChildren(...(filtersInUse.length ? [el('span', '', filtersInUse.join(' · ')), actionButton('清除', 'clear-filters')] : []));
  box.hidden = !filtersInUse.length;
}

function compareFeedByTime(a, b) {
  const order = Date.parse(a.createdAt) - Date.parse(b.createdAt) || a.id.localeCompare(b.id);
  return state.sortOrder === 'oldest' ? order : -order;
}

function disconnectFeedObserver() {
  if (feedObserver) {
    feedObserver.disconnect();
    feedObserver = null;
  }
}

function showEmpty(iconName, title, message, button) {
  const section = el('div', 'empty-state');
  const box = el('div', 'empty-icon');
  box.append(icon(iconName));
  section.append(box, el('strong', '', title));
  if (message) section.append(el('p', '', message));
  if (button) section.append(button);
  $('note-list').replaceChildren(section);
}

function renderFeedList({ reset = true, preservePage = false } = {}) {
  if (!state.noteIndex) rebuildNoteIndex();
  const index = state.noteIndex;
  syncNavActive();
  syncHeatmapActive();
  syncSortButton();
  renderActiveFilters();

  if (!state.loaded) {
    disconnectFeedObserver();
    state.feedItems = [];
    state.feedRendered = 0;
    showEmpty('note', state.refreshing ? '正在打开笔记' : '暂时无法打开笔记', '');
    return;
  }

  const query = $('search').value.trim().toLocaleLowerCase();
  const shown = index.all.filter((note) => {
    const matchesFilter = state.filter === 'all'
      || (state.filter === 'reading' && note.reading)
      || (state.filter === 'journal' && !note.reading)
      || (state.filter.startsWith('tag:') && matchesTagPrefix(index.byNote.get(note.id) || [], state.filter.slice(4)));
    if (!matchesFilter) return false;
    if (state.dayFilter && dayKey(new Date(note.createdAt)) !== state.dayFilter) return false;
    if (!query) return true;
    const fields = [note.body, note.reading?.bookTitle, note.reading?.chapter, note.reading?.author];
    return fields.some((value) => value?.toLocaleLowerCase().includes(query));
  });

  shown.sort(compareFeedByTime);

  state.feedItems = shown;

  if (!shown.length) {
    disconnectFeedObserver();
    state.feedRendered = 0;
    if (query) showEmpty('search', '没有找到相关笔记', '试试其他关键词，或清空搜索。', actionButton('清空搜索', 'clear-search'));
    else if (state.filter === 'reading' && !state.dayFilter) showEmpty('book', '还没有读书', '', actionButton('导入微信读书', 'open-import'));
    else if (state.dayFilter || state.filter !== 'all') showEmpty('search', '当前筛选下没有笔记', '', actionButton('清除筛选', 'clear-filters'));
    else showEmpty('note', '从一条笔记开始', '记下一件今天想留住的事。', actionButton('写第一条笔记', 'focus-compose'));
    return;
  }

  const minVisible = preservePage ? state.feedRendered : 0;
  if (reset) {
    disconnectFeedObserver();
    state.feedRendered = 0;
    $('note-list').replaceChildren();
  }
  appendNextPage(minVisible);
}

function dayHeading(date) {
  const today = new Date();
  if (dayKey(date) === dayKey(today)) return '今天';
  const year = today.getFullYear();
  today.setDate(today.getDate() - 1);
  if (dayKey(date) === dayKey(today)) return '昨天';
  return (date.getFullYear() === year ? '' : date.getFullYear() + '年') + (date.getMonth() + 1) + '月' + date.getDate() + '日';
}

function appendNextPage(minCount = 0) {
  const list = $('note-list');
  const existingMore = list.querySelector('[data-action="load-more"]');
  if (existingMore) existingMore.remove();
  disconnectFeedObserver();

  const start = state.feedRendered;
  const end = Math.min(Math.max(start + FEED_PAGE_SIZE, minCount), state.feedItems.length);
  if (start < end) {
    let group = list.lastElementChild;
    for (let i = start; i < end; i++) {
      const note = state.feedItems[i];
      const date = new Date(note.createdAt);
      const day = dayKey(date);
      if (group?.dataset.day !== day) {
        group = el('section', 'day-group');
        group.dataset.day = day;
        group.append(el('h2', 'day-head', dayHeading(date)));
        list.append(group);
      }
      group.append(renderCard(note));
    }
    state.feedRendered = end;
  }

  if (state.feedRendered < state.feedItems.length) {
    const more = el('button', 'button button-secondary load-more', '加载更多');
    more.type = 'button';
    more.dataset.action = 'load-more';
    list.append(more);
    if (typeof IntersectionObserver !== 'undefined') {
      feedObserver = new IntersectionObserver((entries) => {
        if (entries.some((entry) => entry.isIntersecting)) appendNextPage();
      }, { rootMargin: '200px 0px' });
      feedObserver.observe(more);
    }
  }
}

function noteBody(node, note) {
  node.classList.toggle('note-quote', Boolean(note.reading));
  node.replaceChildren(...tokenizeBody(note.body).map(token => {
    if (token.type !== 'tag') return document.createTextNode(token.text);
    const button = el('button', 'inline-tag', token.text);
    button.type = 'button';
    button.dataset.filter = 'tag:' + token.tag.toLowerCase();
    return button;
  }));
}

function noteSource(note) {
  return note.reading ? '《' + (note.reading.bookTitle || '微信读书') + '》' : '';
}

function renderCard(note, tags = [], interactive = true, dateFormatter) {
  const card = el('article', 'note-card');

  if (!interactive) {
    const meta = el('div', 'card-meta');
    if (note.reading) meta.append(labeled(el('span', 'card-source'), 'book', note.reading.bookTitle || '微信读书'));
    if (note.reading?.chapter) meta.append(el('span', '', note.reading.chapter));
    if (note.createdAt) {
      const date = new Date(note.createdAt);
      meta.append(el('span', '', dateFormatter?.format(date) ?? (dayKey(date) + ' ' + dateTime.format(date))));
    }
    if (meta.childElementCount) card.append(meta);
    card.append(el('div', 'card-body', note.body));
    const bottom = el('div', 'card-bottom');
    for (const tag of tags.slice(0, 3)) bottom.append(el('span', 'card-tag', '#' + tag));
    if (note.turns?.length) bottom.append(labeled(el('span', 'card-chat'), 'chat', Math.floor(note.turns.length / 2) + ' 轮对话'));
    if (bottom.childElementCount) card.append(bottom);
    return card;
  }

  card.dataset.noteId = note.id;
  const body = el('div', 'card-body');
  noteBody(body, note);
  card.append(body);
  if (note.reading) card.append(el('p', 'note-source meta', noteSource(note)));
  const open = el('button', 'card-open', '阅读全文');
  open.type = 'button';
  open.dataset.openNote = note.id;
  open.setAttribute('aria-label', '阅读全文：' + aiNoteTitle(note));
  card.append(open);
  return card;
}

async function copyText(text, modal) {
  let copied = false;
  if (navigator.clipboard?.writeText) {
    try {
      await navigator.clipboard.writeText(text);
      copied = true;
    } catch {}
  }
  if (!copied) {
    const ta = document.createElement('textarea');
    ta.value = text;
    ta.setAttribute('readonly', '');
    ta.style.position = 'fixed';
    ta.style.top = '-9999px';
    ta.style.opacity = '0';
    (modal ?? document.body).append(ta);
    ta.select();
    try {
      copied = document.execCommand('copy') === true;
    } catch {
      copied = false;
    } finally {
      ta.remove();
    }
  }
  const message = copied ? '已复制' : '无法自动复制，请手动划选正文。';
  if (modal?.open) setError('reader-copy-status', message);
  else if (!modal) notify(message);
}

function updateComposer() {
  $('save-note').disabled = !state.loaded || !($('note-body').value.trim()) || $('composer').dataset.saving === 'true';
}

function closeTagSuggest() {
  state.tagSuggest = { open: false, items: [], activeIndex: 0, start: 0, end: 0 };
  const box = $('tag-suggest');
  if (box) {
    box.hidden = true;
    box.replaceChildren();
  }
}

function renderTagSuggest() {
  const box = $('tag-suggest');
  if (!state.tagSuggest.open || !state.tagSuggest.items.length) {
    box.hidden = true;
    box.replaceChildren();
    return;
  }
  const fragment = document.createDocumentFragment();
  state.tagSuggest.items.forEach((item, index) => {
    const btn = el('button', 'tag-suggest-item' + (index === state.tagSuggest.activeIndex ? ' active' : ''));
    btn.type = 'button';
    btn.setAttribute('role', 'option');
    btn.setAttribute('aria-selected', String(index === state.tagSuggest.activeIndex));
    btn.dataset.suggestIndex = String(index);
    btn.append(el('span', '', '#' + item.tag), el('span', 'nav-count', String(item.count)));
    fragment.append(btn);
  });
  box.replaceChildren(fragment);
  box.hidden = false;
}

function updateTagSuggest() {
  const input = $('note-body');
  if (!state.loaded || input.disabled || document.activeElement !== input) {
    closeTagSuggest();
    return;
  }
  const pos = input.selectionStart ?? input.value.length;
  const before = input.value.slice(0, pos);
  const match = before.match(/(?:^|[\s])#([\p{L}\p{N}_\/]*)$/u);
  if (!match) {
    closeTagSuggest();
    return;
  }
  const prefix = match[1].toLowerCase();
  const allTags = state.noteIndex?.tagFreq || [];
  const starts = [];
  const contains = [];
  for (const item of allTags) {
    if (!prefix || item.key.startsWith(prefix)) starts.push(item);
    else if (item.key.includes(prefix)) contains.push(item);
  }
  const items = [...starts, ...contains].slice(0, 8);
  if (!items.length) {
    closeTagSuggest();
    return;
  }
  const hashStart = pos - match[1].length - 1;
  state.tagSuggest = { open: true, items, activeIndex: 0, start: hashStart, end: pos };
  renderTagSuggest();
}

function moveTagSuggest(delta) {
  if (!state.tagSuggest.open || !state.tagSuggest.items.length) return;
  const len = state.tagSuggest.items.length;
  state.tagSuggest.activeIndex = (state.tagSuggest.activeIndex + delta + len) % len;
  renderTagSuggest();
}

function applyTagSuggest(index) {
  const item = state.tagSuggest.items[index];
  if (!item) return;
  const input = $('note-body');
  input.setRangeText('#' + item.tag + ' ', state.tagSuggest.start, state.tagSuggest.end, 'end');
  closeTagSuggest();
  input.focus();
  syncComposerUI();
}

function syncComposerUI() {
  updateComposer();
  const input = $('note-body');
  input.style.height = 'auto';
  const nextHeight = Math.min(320, Math.max(input.matches(':focus') ? 96 : 48, input.scrollHeight));
  input.style.height = nextHeight + 'px';
  updateTagSuggest();
}

async function createNote(event) {
  event.preventDefault();
  if ($('save-note').disabled) return;
  const body = $('note-body').value.trim();
  const draft = state.composeDraft;
  const note = draft?.body === body ? draft : { id: randomUUID(), body, createdAt: new Date().toISOString(), turns: [] };
  state.composeDraft = note;
  $('composer').dataset.saving = 'true';
  updateComposer();
  setError('compose-error', '');
  try {
    await mutate({ id: note.id, expectedRevision: 0, note: notePayload(note) });
    finishCompose(note);
  } catch (error) {
    if (error.status === 409 && error.current?.note?.body === note.body) finishCompose(note);
    else setError('compose-error', error.message);
  } finally {
    $('composer').dataset.saving = 'false';
    syncComposerUI();
  }
}

function finishCompose(note) {
  if ($('note-body').value.trim() === note.body) $('note-body').value = '';
  state.composeDraft = null;
  state.filter = 'all';
  state.dayFilter = null;
  clearSearchInput();
  closeTagSuggest();
  syncComposerUI();
  renderFeedList({ reset: true });
  notify('笔记已保存');
}

const reader = { stack: [], random: false, controller: null, related: [], cache: new Map(), opener: null, scroll: 0, aiScroll: null };

function openNote(id, { random = false, push = true } = {}) {
  if (!state.notes.has(id)) return false;
  const dialog = $('note-dialog');
  if (dialog.open && state.noteID === id) return true;
  if (dialog.open && (state.detailWorking || !mayCloseNote())) return false;
  if (!dialog.open) {
    reader.opener = document.activeElement;
    reader.scroll = window.scrollY;
    reader.aiScroll = ai.visible ? $('ai-chat-thread').scrollTop : null;
    reader.random = random;
  } else if (push && state.noteID) {
    reader.stack.push({ id: state.noteID, scroll: $('note-dialog').querySelector('.reader-scroll').scrollTop });
  }
  state.noteID = id;
  state.editRevision = null;
  $('delete-confirm').hidden = $('edit-conflict').hidden = true;
  setError('reader-copy-status', '');
  setUtilityMenu('reader-options', false);
  setError('detail-error', '');
  renderDetail();
  if (!dialog.open) {
    dialog.showModal();
    document.body.classList.add('reading-note');
  } else if (!matchMedia('(prefers-reduced-motion: reduce)').matches) {
    $('reader-content').animate([{ opacity: .15 }, { opacity: 1 }], { duration: 200, easing: 'ease-out' });
  }
  $('note-dialog').querySelector('.reader-scroll').scrollTop = 0;
  $('note-dialog').querySelector('[data-action="reader-back"]').focus({ preventScroll: true });
  loadReaderRelated(id);
  return true;
}

function mayCloseNote() {
  const differs = state.editRevision !== null && $('edit-body').value.trim() !== (state.notes.get(state.noteID)?.body || '');
  return !differs || confirm('关闭会放弃尚未保存的内容。仍要关闭吗？');
}

function closeNote(force = false) {
  if (!force && (state.detailWorking || !mayCloseNote())) return;
  reader.controller?.abort();
  reader.controller = null;
  reader.related = [];
  reader.stack = [];
  reader.random = false;
  state.noteID = null;
  state.editRevision = null;
  $('note-dialog').close();
  document.body.classList.remove('reading-note');
  reader.opener?.focus({ preventScroll: true });
  reader.opener = null;
  window.scrollTo(0, reader.scroll);
  if (reader.aiScroll !== null) $('ai-chat-thread').scrollTop = reader.aiScroll;
}

function readerBack() {
  if (state.detailWorking) return;
  if (state.editRevision !== null) { if (mayCloseNote()) toggleEdit(false); return; }
  while (reader.stack.length) {
    const previous = reader.stack.pop();
    if (state.notes.has(previous.id) && openNote(previous.id, { push: false })) {
      $('note-dialog').querySelector('.reader-scroll').scrollTop = previous.scroll;
      return;
    }
  }
  closeNote(true);
}

function renderDetail() {
  const note = state.notes.get(state.noteID);
  if (!note) return;
  const editing = state.editRevision !== null;
  const date = new Date(note.createdAt);
  $('detail-meta').textContent = dateLong.format(date) + ' · ' + dateTime.format(date);
  $('dialog-note-title').textContent = note.reading ? noteSource(note) : '笔记';
  $('detail-body').dataset.noteId = note.id;
  noteBody($('detail-body'), note);
  $('detail-source').textContent = [noteSource(note), note.reading?.chapter].filter(Boolean).join(' · ');
  $('reader-content').hidden = $('detail-actions').hidden = editing;
  $('edit-form').hidden = $('reader-save').hidden = !editing;
  const back = $('note-dialog').querySelector('[data-action="reader-back"]');
  back.textContent = editing ? '取消' : '← 返回';
  back.setAttribute('aria-label', editing ? '取消编辑' : '返回');
  $('note-dialog').querySelector('[data-action="reader-shuffle"]').hidden = !reader.random;
}

function toggleEdit(enabled) {
  if (state.detailWorking) return;
  const note = state.notes.get(state.noteID);
  if (!note) {
    if (!enabled) {
      state.editRevision = null;
      readerBack();
    }
    return;
  }
  state.editRevision = enabled ? note.revision : null;
  $('delete-confirm').hidden = $('edit-conflict').hidden = true;
  setUtilityMenu('reader-options', false);
  setError('detail-error', '');
  if (enabled) $('edit-body').value = note.body;
  renderDetail();
  if (enabled) $('edit-body').focus();
}

async function submitEdit(event) {
  event.preventDefault();
  const body = $('edit-body').value.trim();
  const note = state.notes.get(state.noteID);
  if (!note || state.editRevision === null || state.detailWorking) return;
  if (!body) { setError('detail-error', '笔记内容不能为空。'); return; }
  state.detailWorking = $('reader-save').disabled = true;
  try {
    await mutate({ id: note.id, expectedRevision: state.editRevision, note: notePayload({ ...note, body }) });
    state.detailWorking = false;
    toggleEdit(false);
  } catch (error) {
    if (error.status === 409 && error.current?.note) {
      state.editRevision = error.current.note.revision;
      $('edit-remote').textContent = error.current.note.body;
      $('edit-conflict').hidden = false;
      setError('detail-error', '另一端已修改。查看并合并后保存，或直接保存以替换正文。');
    } else setError('detail-error', error.message);
  } finally {
    state.detailWorking = $('reader-save').disabled = false;
  }
}

let undoDelete = null;
let undoTimer;
function clearDeleteUndo() {
  clearTimeout(undoTimer);
  undoDelete = null;
  $('delete-undo').hidden = true;
}

async function restoreDeletedNote(button) {
  const copy = undoDelete;
  if (!copy || button.disabled) return;
  clearTimeout(undoTimer);
  button.disabled = true;
  try {
    await mutate({ id: copy.id, expectedRevision: 0, note: copy });
    if (undoDelete === copy) clearDeleteUndo();
  } catch (error) {
    if (undoDelete === copy) {
      if (error.status === 409 && error.current?.note?.id === copy.id) clearDeleteUndo();
      else {
        notify('撤销失败：' + error.message);
        undoTimer = setTimeout(clearDeleteUndo, 8000);
      }
    }
  } finally {
    button.disabled = false;
  }
}

async function deleteNote() {
  const note = state.notes.get(state.noteID);
  if (!note || state.detailWorking) return;
  state.detailWorking = true;
  try {
    await mutate({ id: note.id, expectedRevision: note.revision, delete: true });
    closeNote(true);
    clearDeleteUndo();
    undoDelete = notePayload({ ...note, id: crypto.randomUUID() });
    $('delete-undo').hidden = false;
    undoTimer = setTimeout(clearDeleteUndo, 8000);
  } catch (error) {
    if (error.status === 409 && error.current?.deleted) closeNote(true);
    else {
      renderDetail();
      $('delete-confirm').hidden = true;
      setError('detail-error', error.status === 409 ? '这条笔记有新修改。查看后可重新确认删除。' : error.message);
    }
  } finally {
    state.detailWorking = false;
  }
}

function updateAISettings() {
  const select = $('chat-provider');
  select.querySelector('option[value=codex]').disabled = !state.codexAvailable;
  $('codex-status').textContent = state.codexMode === 'gateway' ? '已配置 Codex 服务端网关。' : state.codexAvailable
    ? 'Codex 中转已配置。通过主机登录的 ChatGPT 账号使用 Codex。'
    : 'Codex 中转未配置。启动私有中转并在站点中配置后，即可选择。';
  const usingOpenAI = select.value !== 'codex';
  $('openai-fields').hidden = !usingOpenAI;
  $('openai-key').disabled = $('openai-model').disabled = !usingOpenAI;
  syncSettingsModels();
}

function cleanupSettings() {
  closeProfile();
  closeWritingStyle();
  $('openai-key').value = '';
  $('admin-invite-created').textContent = '';
  $('admin-invite-created').hidden = true;
}

function openSettings() {
  if (!$('settings-dialog').open) cleanupSettings();
  $('chat-provider').value = state.chatProvider;
  updateAISettings();
  $('openai-key').value = state.apiKey;
  $('openai-model').value = state.model;
  setError('settings-error', '');
  if (!$('settings-dialog').open) {
    $('settings-root').opener = null;
    $('settings-dialog').showModal();
  }
  showSettingsPane('root');
  if (state.codexMode === 'gateway' && !state.gatewayModels.length) void loadGatewayModels();
}

function showSettingsPane(pane, trigger) {
  const root = $('settings-root');
  if (pane !== 'root') root.opener = trigger;
  root.hidden = pane !== 'root';
  for (const item of ['account', 'ai', 'data']) $('settings-' + item + '-pane').hidden = pane !== item;
  const back = $('settings-dialog').querySelector('[data-pane="root"]');
  back.hidden = pane === 'root';
  $('settings-title').textContent = { root: '设置', account: '账号', ai: 'AI', data: '数据' }[pane];
  if (pane === 'root') (root.opener ?? root.firstElementChild).focus({ preventScroll: true });
  else back.focus({ preventScroll: true });
  if (pane === 'account' || pane === 'data') void loadAuthSettings();
  if (pane === 'ai') {
    profileView.hidden = false;
    initProfile();
  }
}

function syncSettingsEffort() {
  const selected = $('settings-default-model').value;
  const model = state.gatewayModelMeta.find(item => item.id === selected);
  const choices = ['', ...(model?.efforts ?? [])];
  $('settings-default-effort').replaceChildren(...choices.map(value => new Option(effortLabels[value], value)));
  $('settings-default-effort').value = choices.includes(state.defaultEffort) ? state.defaultEffort : '';
  $('settings-default-effort').disabled = choices.length < 2;
}

function syncSettingsModels() {
  const available = $('chat-provider').value === 'codex' && state.gatewayModels.length > 0;
  $('default-gateway-controls').hidden = !available;
  if (!available) return;
  const select = $('settings-default-model');
  select.replaceChildren(...state.gatewayModelMeta.map(item => new Option(item.label, item.id)));
  select.value = state.preferredModel || state.defaultGatewayModel;
  syncSettingsEffort();
}

async function loadSemanticStatus(reindex = false) {
  const button = $('settings-data-pane').querySelector('[data-action="semantic-reindex"]');
  if (button.disabled) return;
  button.disabled = true;
  setError('semantic-status', reindex ? '正在重建…' : '正在读取…');
  const signal = accountLifecycle.signal;
  try {
    const status = reindex ? await request('/api/semantic/reindex', {}, signal) : await request('/api/semantic/status', undefined, signal);
    button.hidden = status.provider === 'disabled';
    setError('semantic-status', status.provider === 'disabled' ? '语义索引未开启' :
      [`已索引 ${status.indexed}/${status.total}`, status.pending ? `${status.pending} 条待处理` : null, status.lastError].filter(Boolean).join(' · '));
  } catch (error) {
    if (!signal.aborted) setError('semantic-status', error.message);
  } finally {
    button.disabled = false;
  }
}

function authRow(label, actionName, action) {
  const row = el('li', '', label);
  if (action) {
    const button = actionButton(actionName, actionName === '作废' ? 'revoke-invite' : 'revoke-session');
    button.addEventListener('click', () => authSettingsAction(button, action));
    row.append(button);
  }
  return row;
}

async function authSettingsAction(button, action) {
  button.disabled = true;
  setError('auth-settings-error', '');
  try { await action(); }
  catch (error) { if (error.name !== 'AbortError') setError('auth-settings-error', error.message); }
  finally { button.disabled = false; }
}

function renderObsidianStatus(status) {
  $('admin-obsidian-section').hidden = status.configured !== true;
  if (!status.configured) return;
  const run = status.lastRun;
  const stats = run?.stats;
  const time = run && new Date(run.at).toLocaleString('zh-CN');
  $('admin-obsidian-status').textContent = status.running ? '正在同步…' : !run ? '尚未同步' :
    run.ok ? `${time} · 新增 ${stats.created} · 更新 ${stats.updated}${stats.conflicts ? ' · 冲突 ' + stats.conflicts : ''}${run.indexWarning ? ' · ' + run.indexWarning : ''}` :
    `${time} · ${run.error || '同步失败'}`;
}

$('admin-obsidian-sync').addEventListener('click', async event => {
  const button = event.currentTarget;
  const epoch = state.syncEpoch;
  button.disabled = true;
  $('admin-obsidian-status').textContent = '正在同步…';
  try {
    const { stats, status } = await request('/api/admin/obsidian/sync', {});
    renderObsidianStatus(status);
    if (stats.created || stats.updated) {
      state.writeEpoch++;
      finishLocalWrites(true);
      if (state.refreshing) await activeRefresh;
      if (epoch === state.syncEpoch) await refresh({ silent: true });
    }
  } catch (error) {
    if (epoch === state.syncEpoch && error.name !== 'AbortError') $('admin-obsidian-status').textContent = error.message;
  } finally {
    button.disabled = false;
  }
});

async function loadAuthSettings() {
  const oauth = state.authMode === 'oauth';
  const admin = oauth && state.user?.role === 'admin';
  $('auth-sessions-section').hidden = !oauth;
  $('admin-invites-section').hidden = !admin;
  $('admin-obsidian-section').hidden = true;
  if (!oauth) return;
  setError('auth-settings-error', '');
  try {
    const { sessions } = await request('/api/auth/sessions');
    $('auth-sessions-list').replaceChildren(...sessions.map(session => {
      const row = authRow((session.label || (session.kind === 'ios' ? 'iOS' : '浏览器')) + (session.current ? ' · 当前设备' : ''), '退出', async () => {
        if (session.current) return logoutAccount();
        await request('/api/auth/sessions/' + encodeURIComponent(session.id), undefined, undefined, 'DELETE');
        await loadAuthSettings();
      });
      row.dataset.sessionId = session.id;
      return row;
    }));
    if (!admin) return;
    const [status, { invites }] = await Promise.all([
      request('/api/admin/obsidian/status'),
      request('/api/admin/invites'),
    ]);
    renderObsidianStatus(status);
    $('admin-invites-list').replaceChildren(...invites.map(invite => {
      const available = !invite.revokedAt && invite.usedCount < invite.maxUses &&
        (!invite.expiresAt || Date.parse(invite.expiresAt) > Date.now());
      return authRow('…' + invite.codeHint + ' · ' + invite.usedCount + '/' + invite.maxUses +
        (invite.revokedAt ? ' · 已作废' : !available ? ' · 已失效' : ''), '作废', available ? async () => {
        await request('/api/admin/invites/' + encodeURIComponent(invite.codeHash), undefined, undefined, 'DELETE');
        await loadAuthSettings();
      } : null);
    }));
  } catch (error) {
    if (error.name !== 'AbortError') setError('auth-settings-error', error.message);
  }
}

$('admin-invite-create').addEventListener('click', event => authSettingsAction(event.currentTarget, async () => {
  const { code } = await request('/api/admin/invites', { maxUses: 1 });
  const output = $('admin-invite-created');
  output.textContent = code;
  output.hidden = false;
  await loadAuthSettings();
}));

function saveSettings(event) {
  event.preventDefault();
  if ($('chat-provider').value === 'codex' && state.codexAvailable) {
    state.chatProvider = 'codex';
    if (!$('default-gateway-controls').hidden) {
      state.defaultEffort = state.reasoningEffort = $('settings-default-effort').value;
      state.preferredModel = state.gatewayModel = $('settings-default-model').value;
      try {
        localStorage.setItem('weiji.defaultModel', state.preferredModel);
        localStorage.setItem('weiji.defaultEffort', state.defaultEffort);
        localStorage.removeItem('weiji.gatewayModel');
        localStorage.removeItem('weiji.reasoningEffort');
      } catch {}
    }
    renderGatewayModels();
    void loadGatewayModels();
    $('settings-dialog').close();
    notify('设置已保存');
    return;
  }
  const apiKey = $('openai-key').value.trim();
  const model = $('openai-model').value.trim();
  if (!/^[A-Za-z0-9_.:-]{1,100}$/.test(model) || (apiKey && !/^[!-~]{10,512}$/.test(apiKey))) {
    setError('settings-error', '请填写有效的模型名称和 OpenAI API Key。');
    return;
  }
  state.chatProvider = 'openai';
  state.apiKey = apiKey;
  state.model = model;
  renderGatewayModels();
  $('openai-key').value = '';
  $('settings-dialog').close();
  notify('设置已保存');
}

function localSourceDate(value) {
  return value ? dayKey(new Date(value)) : '';
}

function importKey(note) {
  const item = note.reading;
  return JSON.stringify([
    item.bookTitle ?? null,
    item.author ?? null,
    item.chapter ?? null,
    localSourceDate(item.sourceDate),
    item.fingerprint || (note.body || '').trim().normalize('NFC'),
  ]);
}

function openImport() {
  if (!state.loaded || !state.user?.id) {
    notify('请先登录并完成同步');
    return;
  }
  $('import-hub-dialog').close();
  resetWereadImport();
  setError('import-error', '');
  sidebar(false);
  $('import-dialog').showModal();
}

function resetWereadImport() {
  state.wereadImport?.controller?.abort();
  state.wereadImport?.batchController?.abort();
  state.wereadImport = {
    account: state.user?.id,
    books: [], selected: new Set(), nextCursor: null, queried: false, controller: null,
    batchController: null, preview: null, saving: false,
  };
  $('weread-key').value = '';
  $('weread-connect-submit').disabled = false;
  $('weread-key').disabled = false;
  $('weread-connect').hidden = false;
  $('weread-books').hidden = true;
  $('weread-books-bar').hidden = true;
  $('weread-select-all').checked = false;
  $('weread-select-all').indeterminate = false;
  $('weread-book-list').replaceChildren();
  $('weread-preview').hidden = true;
  $('weread-samples').replaceChildren();
  $('weread-more').hidden = true;
  $('weread-save').disabled = false;
  $('weread-back').disabled = false;
  $('import-dialog').querySelector('[data-close="import-dialog"]').disabled = false;
  setError('weread-progress', '');
  setError('weread-error', '');
  setWereadMode(false);
}

function setWereadMode(manual) {
  const session = state.wereadImport;
  if (state.importWorking || session?.saving) return;
  if (manual) {
    if (session) {
      session.controller?.abort();
      session.controller = null;
      session.queried = false;
      session.preview = null;
      session.books = [];
      session.nextCursor = null;
    }
    $('weread-key').value = '';
    $('weread-key').disabled = $('weread-connect-submit').disabled = false;
  }
  $('weread-official').hidden = manual;
  $('import-form').hidden = !manual;
  $('weread-mode-official').setAttribute('aria-pressed', String(!manual));
  $('weread-mode-manual').setAttribute('aria-pressed', String(manual));
  renderWereadBooks();
  setError('weread-error', '');
  setError('weread-progress', '');
}

function currentWereadSession(session) {
  return session && state.wereadImport === session && state.user?.id === session.account
    && $('import-dialog').open && !$('weread-official').hidden;
}

function updateWereadBatchControls(session) {
  const total = session.books.length;
  const selected = session.selected.size;
  const busy = session.controller !== null || session.saving;
  $('weread-books-bar').hidden = !total;
  const selectAll = $('weread-select-all');
  selectAll.checked = total > 0 && selected === total;
  selectAll.indeterminate = selected > 0 && selected < total;
  selectAll.disabled = busy;
  const batchButton = $('weread-batch-save');
  if (session.saving) {
    batchButton.textContent = '停止导入';
    batchButton.disabled = !session.batchController || session.batchController.signal.aborted;
  } else {
    batchButton.textContent = selected > 0 && selected < total
      ? '导入所选 (' + selected + ' 本)'
      : '导入全部 (' + total + ' 本)';
    batchButton.disabled = !total || session.controller !== null;
  }
}

function renderWereadBooks() {
  const session = state.wereadImport;
  if (!session) return;
  $('weread-connect').hidden = session.preview !== null;
  $('weread-books').hidden = !session.queried || session.preview !== null;
  $('weread-preview').hidden = session.preview === null;
  if (session.preview) return;
  const busy = session.controller !== null || session.saving;
  $('weread-books-status').textContent = session.books.length
    ? '勾选批量导入，或点击单本书预览（共 ' + session.books.length + ' 本）'
    : '没有找到有笔记的书。';
  $('weread-book-list').replaceChildren(...session.books.map(({ id, title, author, noteCount, reviewCount }) => {
    const check = el('input', 'weread-book-check');
    check.type = 'checkbox';
    check.dataset.bookSelect = id;
    check.checked = session.selected.has(id);
    check.disabled = busy;
    check.setAttribute('aria-label', '选择《' + title + '》');
    const button = el('button', 'weread-book');
    button.type = 'button';
    button.dataset.action = 'weread-book';
    button.dataset.book = id;
    button.disabled = busy;
    const counts = [author, '划线 ' + noteCount, '想法及点评 ' + reviewCount].filter(Boolean).join(' · ');
    button.append(el('strong', '', title), el('span', '', counts));
    const item = el('li', 'weread-book-item');
    item.append(check, button);
    return item;
  }));
  $('weread-more').hidden = session.nextCursor === null;
  $('weread-more').disabled = busy;
  updateWereadBatchControls(session);
}

function renderWereadPreview(session) {
  const { preview } = session;
  $('weread-connect').hidden = true;
  $('weread-books').hidden = true;
  $('weread-preview').hidden = false;
  $('weread-book-title').textContent = preview.book.title;
  const remaining = preview.pending.length;
  $('weread-summary').textContent = remaining
    ? '待导入 ' + remaining + ' 条笔记，确认后保存到当前微记账号。'
    : '这本书没有新的笔记可以导入。';
  const details = [];
  if (preview.duplicated) details.push('已存在或此前删除 ' + preview.duplicated + ' 条');
  if (preview.skipped) details.push('跳过 ' + preview.skipped + ' 条缺少正文或日期的笔记');
  if (preview.skippedLarge) details.push('跳过 ' + preview.skippedLarge + ' 条超出大小限制的笔记');
  setError('weread-skipped', details.length ? details.join('，') + '。' : '');
  const samples = preview.pending.slice(0, bulkPreviewLimit);
  $('weread-samples').replaceChildren(...samples.map(({ note }) => renderCard(note, tagsFor(note.body), false)));
  setError('weread-sample-count', remaining > samples.length ? '仅预览前 ' + samples.length + ' 条。' : '');
  $('weread-save').textContent = '导入 ' + remaining + ' 条';
  $('weread-save').disabled = !remaining || session.saving;
}

async function readWeread(path, parameters, progress, apply) {
  const session = state.wereadImport;
  if (!currentWereadSession(session) || session.controller || session.saving) return;
  const apiKey = $('weread-key').value.trim();
  setError('weread-error', '');
  setError('weread-progress', '');
  if (!/^wrk-\S+$/u.test(apiKey)) {
    setError('weread-error', '请输入从微信读书获取的 API Key，以 wrk- 开头。');
    $('weread-key').focus();
    return;
  }
  const controller = new AbortController();
  session.controller = controller;
  $('weread-key').disabled = $('weread-connect-submit').disabled = true;
  renderWereadBooks();
  setError('weread-progress', progress);
  const timeout = setTimeout(() => controller.abort(), 45000);
  try {
    const result = await request('/api/weread/' + path, { apiKey, ...parameters }, controller.signal);
    if (currentWereadSession(session) && !controller.signal.aborted) apply(session, result);
  } catch (error) {
    if (currentWereadSession(session) && session.controller === controller) {
      const message = controller.signal.aborted ? '读取超时，请重试。' : error.message;
      setError('weread-error', message);
    }
  } finally {
    clearTimeout(timeout);
    if (state.wereadImport === session && session.controller === controller) {
      session.controller = null;
      $('weread-key').disabled = $('weread-connect-submit').disabled = false;
      setError('weread-progress', '');
      renderWereadBooks();
    }
  }
}

function sleepWithSignal(ms, signal) {
  return new Promise((resolve, reject) => {
    if (signal?.aborted) { reject(signal.reason || new DOMException('Aborted', 'AbortError')); return; }
    const timer = setTimeout(() => { signal?.removeEventListener('abort', onAbort); resolve(); }, ms);
    const onAbort = () => { clearTimeout(timer); reject(signal.reason || new DOMException('Aborted', 'AbortError')); };
    signal?.addEventListener('abort', onAbort, { once: true });
  });
}

async function requestWithTimeout(path, body, parentSignal, ms = 45000) {
  const controller = new AbortController();
  const onAbort = () => controller.abort(parentSignal.reason);
  if (parentSignal?.aborted) { controller.abort(parentSignal.reason); }
  else parentSignal?.addEventListener('abort', onAbort, { once: true });
  const timer = setTimeout(() => controller.abort(new DOMException('Timeout', 'TimeoutError')), ms);
  try {
    return await request(path, body, controller.signal);
  } finally {
    clearTimeout(timer);
    parentSignal?.removeEventListener('abort', onAbort);
  }
}

async function loadWereadBooks(more = false) {
  const session = state.wereadImport;
  if (!currentWereadSession(session) || session.controller || session.saving) return;
  const apiKey = $('weread-key').value.trim();
  setError('weread-error', '');
  setError('weread-progress', '');
  if (!/^wrk-\S+$/u.test(apiKey)) {
    setError('weread-error', '请输入从微信读书获取的 API Key，以 wrk- 开头。');
    $('weread-key').focus();
    return;
  }
  let cursor = more ? session.nextCursor : null;
  if (more && !Number.isSafeInteger(cursor)) return;
  const controller = new AbortController();
  session.controller = controller;
  $('weread-key').disabled = $('weread-connect-submit').disabled = true;
  renderWereadBooks();
  const books = new Map((more ? session.books : []).map((book) => [book.id, book]));
  if (!more) session.selected.clear();
  try {
    // Load up to 25 pages (~1000 books) automatically so "Import All" covers the full bookshelf.
    for (let page = 0; page < 25; page++) {
      setError('weread-progress', books.size ? '正在读取书籍列表（已找到 ' + books.size + ' 本）…' : '正在读取有笔记的书籍…');
      const data = await requestWithTimeout('/api/weread/books', cursor == null ? { apiKey } : { apiKey, lastSort: cursor }, controller.signal);
      if (!currentWereadSession(session) || controller.signal.aborted) return;
      if (!Array.isArray(data.books)) throw new Error('无法读取书籍列表，请重试。');
      for (const book of data.books) books.set(book.id, book);
      session.books = [...books.values()];
      session.queried = true;
      const next = Number.isSafeInteger(data.nextCursor) && data.nextCursor !== cursor ? data.nextCursor : null;
      session.nextCursor = next;
      if (next === null) break;
      cursor = next;
      await sleepWithSignal(120, controller.signal);
    }
  } catch (error) {
    if (currentWereadSession(session) && session.controller === controller) {
      const message = error.name === 'AbortError' || error.name === 'TimeoutError' ? '读取超时，请重试。' : error.message;
      setError('weread-error', message);
    }
  } finally {
    if (state.wereadImport === session && session.controller === controller) {
      session.controller = null;
      $('weread-key').disabled = $('weread-connect-submit').disabled = false;
      setError('weread-progress', '');
      renderWereadBooks();
    }
  }
}

async function saveSelectedWereadBooks() {
  const session = state.wereadImport;
  if (!session || !currentWereadSession(session) || session.controller) return;
  if (session.saving) {
    session.batchController?.abort();
    updateWereadBatchControls(session);
    return;
  }
  const targets = session.selected.size
    ? session.books.filter((book) => session.selected.has(book.id))
    : [...session.books];
  if (!targets.length) return;
  const apiKey = $('weread-key').value.trim();
  setError('weread-error', '');
  setError('weread-progress', '');
  if (!/^wrk-\S+$/u.test(apiKey)) {
    setError('weread-error', '请输入从微信读书获取的 API Key，以 wrk- 开头。');
    $('weread-key').focus();
    return;
  }
  const batchController = new AbortController();
  session.saving = true;
  session.batchController = batchController;
  $('weread-key').disabled = $('weread-connect-submit').disabled = true;
  $('weread-mode-manual').disabled = $('weread-mode-official').disabled = true;
  const close = $('import-dialog').querySelector('[data-close="import-dialog"]');
  close.disabled = true;
  renderWereadBooks();

  let doneBooks = 0;
  let totalSaved = 0;
  let totalDuplicated = 0;
  let totalSkipped = 0;
  const failed = [];
  const remainingIds = new Set(targets.map((book) => book.id));
  let stopped = false;

  try {
    for (let index = 0; index < targets.length; index++) {
      if (batchController.signal.aborted || !currentWereadSession(session)) { stopped = true; break; }
      const book = targets[index];
      const prefix = '第 ' + (index + 1) + '/' + targets.length + ' 本《' + book.title + '》：';
      setError('weread-progress', prefix + '正在读取笔记…');
      let data;
      try {
        for (let attempt = 0; attempt < 2; attempt++) {
          try {
            data = await requestWithTimeout('/api/weread/notes', { apiKey, bookId: book.id }, batchController.signal);
            break;
          } catch (error) {
            if (error.status === 429 && attempt === 0 && !batchController.signal.aborted) {
              setError('weread-progress', prefix + '触发限流，稍候重试…');
              await sleepWithSignal(2500, batchController.signal);
              continue;
            }
            throw error;
          }
        }
        if (!Array.isArray(data?.notes)) throw new Error('无法读取该书笔记');
        const existing = new Set([...state.notes.values()].filter((note) => note.reading).map(importKey));
        const { pending, duplicated, skippedLarge } = prepareBulkNotes(data.notes, (note) => existing.has(importKey(note)));
        const preview = {
          account: session.account, book, prefix, pending, duplicated, skippedLarge,
          total: pending.length, saved: 0, skippedDuringSave: 0, skipped: data.skipped || 0,
        };
        if (preview.pending.length) {
          await saveBulkNotes(preview, '/api/import/weread', 'weread-progress');
        }
        doneBooks++;
        totalSaved += preview.saved;
        totalDuplicated += preview.duplicated + preview.skippedDuringSave;
        totalSkipped += preview.skipped + preview.skippedLarge;
        remainingIds.delete(book.id);
      } catch (error) {
        if (batchController.signal.aborted) { stopped = true; break; }
        failed.push('《' + book.title + '》：' + error.message);
        if (error.status === 400 || error.status === 401 || error.status === 403 || error.status === 503) break;
      }
      if (index + 1 < targets.length && !batchController.signal.aborted) {
        try { await sleepWithSignal(250, batchController.signal); } catch { stopped = true; break; }
      }
    }
  } finally {
    session.saving = false;
    session.batchController = null;
    $('weread-key').disabled = $('weread-connect-submit').disabled = false;
    $('weread-mode-manual').disabled = $('weread-mode-official').disabled = close.disabled = false;
    session.selected = remainingIds;
    if (currentWereadSession(session)) {
      renderWereadBooks();
      if (totalSaved > 0) {
        state.filter = 'reading';
        clearSearchInput();
        rebuildNoteIndex();
        renderFeedList({ reset: true });
      }
      const parts = [
        (stopped ? '已停止：完成 ' : '已完成 ') + doneBooks + ' / ' + targets.length + ' 本',
        '导入 ' + totalSaved + ' 条',
      ];
      if (totalDuplicated) parts.push('跳过已存在 ' + totalDuplicated + ' 条');
      if (totalSkipped) parts.push('忽略无效 ' + totalSkipped + ' 条');
      setError('weread-progress', parts.join('，') + '。');
      if (failed.length) {
        setError('weread-error', failed.length + ' 本导入失败（已保留勾选方便重试）：' + failed.slice(0, 3).join('；') + (failed.length > 3 ? '…' : ''));
      }
    }
  }
}

function previewWereadBook(button) {
  const bookId = button.dataset.book;
  const book = state.wereadImport?.books.find(({ id }) => String(id) === bookId);
  if (!book) return;
  readWeread('notes', { bookId }, '正在读取《' + book.title + '》的笔记…', (session, data) => {
    if (!Array.isArray(data.notes)) throw new Error('无法读取该书笔记，请重试。');
    const existing = new Set([...state.notes.values()].filter((note) => note.reading).map(importKey));
    const { pending, duplicated, skippedLarge } = prepareBulkNotes(data.notes, (note) => existing.has(importKey(note)));
    session.preview = {
      account: session.account, book, pending, duplicated, skippedLarge,
      total: pending.length, saved: 0, skippedDuringSave: 0, skipped: data.skipped || 0,
    };
    renderWereadPreview(session);
  });
}

function backToWereadBooks() {
  const session = state.wereadImport;
  if (!session || session.saving) return;
  session.preview = null;
  $('weread-samples').replaceChildren();
  renderWereadBooks();
  setError('weread-progress', '');
  setError('weread-error', '');
}

async function saveWereadNotes() {
  const session = state.wereadImport;
  const preview = session?.preview;
  if (!session || !currentWereadSession(session) || session.saving || !preview?.pending.length) return;
  session.saving = true;
  $('weread-save').disabled = $('weread-back').disabled = true;
  $('weread-mode-manual').disabled = $('weread-mode-official').disabled = true;
  const close = $('import-dialog').querySelector('[data-close="import-dialog"]');
  close.disabled = true;
  setError('weread-error', '');
  try {
    await saveBulkNotes(preview, '/api/import/weread', 'weread-progress');
    if (!currentWereadSession(session)) return;
    session.preview = null;
    $('weread-samples').replaceChildren();
    renderWereadBooks();
    state.filter = 'reading';
    clearSearchInput();
    rebuildNoteIndex();
    renderFeedList({ reset: true });
    const skipped = preview.skippedDuringSave ? '，跳过 ' + preview.skippedDuringSave + ' 条已存在或此前删除的笔记' : '';
    setError('weread-progress', '已导入《' + preview.book.title + '》的 ' + preview.saved + ' 条笔记' + skipped + '。');
  } catch (error) {
    if (currentWereadSession(session)) {
      renderWereadPreview(session);
      $('weread-save').textContent = '重试剩余 ' + preview.pending.length + ' 条';
      setError('weread-error', error.message);
    }
  } finally {
    session.saving = false;
    $('weread-save').disabled = !preview.pending.length;
    $('weread-back').disabled = $('weread-mode-manual').disabled = $('weread-mode-official').disabled = close.disabled = false;
  }
}

function importMode(items) {
  state.importItems = items;
  $('import-edit').hidden = items !== null;
  $('import-preview').hidden = items === null;
  $('import-back').hidden = items === null;
  const button = $('import-submit');
  button.disabled = items?.length === 0;
  button.textContent = items ? '导入 ' + items.length + ' 条' : '预览导入';
  $('import-preview').replaceChildren(...(items ?? []).map(note => renderCard(note, [], false)));
}

async function importNotes(event) {
  event.preventDefault();
  if (!state.loaded || state.importWorking) return;
  setError('import-error', '');
  state.importWorking = true;
  const button = $('import-submit');
  const epoch = state.syncEpoch;
  button.disabled = true;
  try {
    if (state.importItems === null) {
      const raw = $('import-text').value.trim();
      if (!raw) {
        setError('import-error', '请粘贴笔记或选择文本文件。');
        return;
      }
      const parsed = await parseWeRead(raw);
      if (epoch !== state.syncEpoch) return;
      const existing = new Set([...state.notes.values()].filter((note) => note.reading).map(importKey));
      const items = [];
      for (const entry of parsed) {
        const key = importKey(entry);
        if (existing.has(key)) continue;
        existing.add(key);
        items.push({ ...entry, id: randomUUID(), turns: [] });
      }
      importMode(items);
      if (items.length === 0) setError('import-error', '这批笔记已导入，无需重复保存。');
      else if (items.length < parsed.length) setError('import-error', '已跳过 ' + (parsed.length - items.length) + ' 条重复摘录。');
      return;
    }
    const remaining = [...state.importItems];
    const existing = new Set([...state.notes.values()].filter((note) => note.reading).map(importKey));
    let imported = 0;
    for (const item of state.importItems) {
      try {
        const key = importKey(item);
        if (!existing.has(key)) {
          const result = await mutate({ id: item.id, expectedRevision: 0, note: notePayload(item) });
          if (result.note) ++imported;
          existing.add(key);
        }
        remaining.shift();
      } catch (error) {
        if (error.status === 409 && error.current?.note?.reading && importKey(error.current.note) === importKey(item)) {
          remaining.shift();
          continue;
        }
        if (epoch !== state.syncEpoch) return;
        importMode(remaining);
        setError('import-error', (imported ? '已导入 ' + imported + ' 条。' : '') + error.message);
        return;
      }
    }
    importMode(null);
    $('import-text').value = '';
    $('import-dialog').close();
    state.filter = 'reading';
    clearSearchInput();
    rebuildNoteIndex();
    renderFeedList({ reset: true });
    notify(imported ? '已导入 ' + imported + ' 条读书笔记' : '这批笔记已导入');
  } catch (error) {
    setError('import-error', error.message);
  } finally {
    state.importWorking = false;
    button.disabled = state.importItems?.length === 0;
  }
}

async function pickImportFile(event) {
  const file = event.target.files?.[0];
  const epoch = state.syncEpoch;
  event.target.value = '';
  if (!file) return;
  try {
    if (file.size > 2 * 1024 * 1024) throw new Error('文件超过 2 MB，请拆成几个文本文件再导入。');
    const content = await readWeReadFile(file);
    if (epoch !== state.syncEpoch) return;
    if (content.length > 350000) throw new Error('文字太多，请拆成几个文本文件再导入。');
    $('import-text').value = content;
    setError('import-error', '');
  } catch (error) {
    setError('import-error', error.message);
  }
}

const bulkBatchLimit = 20;
const bulkBatchTarget = 560000;
const bulkRequestLimit = 600000;
const bulkPreviewLimit = 12;
const importEncoder = new TextEncoder();
const bulkEnvelopeBytes = importEncoder.encode('{"notes":[]}').length;

function openFileImport(kind) {
  if (!state.loaded || !state.user?.id) {
    notify('请先登录并完成同步');
    return;
  }
  $('import-hub-dialog').close();
  const select = $(`${kind}-zone`);
  const browserZone = Intl.DateTimeFormat().resolvedOptions().timeZone;
  if (browserZone && ![...select.options].some((option) => option.value === browserZone)) {
    select.add(new Option('当前设备（' + browserZone + '）', browserZone), 1);
  }
  sidebar(false);
  resetFileImport(kind, true);
  $(`${kind}-dialog`).showModal();
}

function resetFileImport(kind, clearFile = false) {
  state[kind + 'Import'] = null;
  $(`${kind}-edit`).hidden = false;
  $(`${kind}-preview`).hidden = true;
  $(`${kind}-back`).hidden = true;
  $(`${kind}-samples`).replaceChildren();
  $(`${kind}-submit`).textContent = '预览导入';
  $(`${kind}-submit`).disabled = false;
  setError(`${kind}-progress`, '');
  setError(`${kind}-error`, '');
  if (clearFile) {
    $(`${kind}-file`).value = '';
    if (kind === 'joplin') {
      $('joplin-dir').value = '';
      setError('joplin-dir-status', '');
    }
  }
}

function renderFileImportPreview(kind) {
  const preview = state[kind + 'Import'];
  const remaining = preview.pending.length;
  $(`${kind}-edit`).hidden = true;
  $(`${kind}-preview`).hidden = false;
  $(`${kind}-back`).hidden = false;
  $(`${kind}-summary`).textContent = remaining
    ? '待导入 ' + remaining + ' 条笔记。确认后会保存到当前微记账号。'
    : kind === 'joplin' ? '待导入 0 条笔记。' : '没有新的笔记可以导入。';
  const skipped = [];
  if (preview.duplicated) skipped.push('已存在或此前删除 ' + preview.duplicated + ' 条');
  if (preview.skippedAttachments) skipped.push('跳过 ' + preview.skippedAttachments + ' 个附件');
  if (preview.skippedEncrypted) skipped.push('跳过 ' + preview.skippedEncrypted + ' 条加密或锁定的笔记');
  if (preview.skippedEmpty) skipped.push('跳过 ' + preview.skippedEmpty + ' 条没有文字的笔记');
  if (preview.skippedInvalidDate) skipped.push('跳过 ' + preview.skippedInvalidDate + ' 条日期无法识别的笔记');
  if (preview.skippedLarge) skipped.push('跳过 ' + preview.skippedLarge + ' 条超出大小限制的笔记');
  setError(`${kind}-skipped`, skipped.length ? skipped.join('，') + '。' : '');
  const samples = preview.pending.slice(0, bulkPreviewLimit);
  const dateFormatter = new Intl.DateTimeFormat('zh-CN', {
    year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit', second: '2-digit',
    hourCycle: 'h23', timeZone: preview.timeZone,
  });
  $(`${kind}-samples`).replaceChildren(...samples.map(({ note }) => renderCard(note, tagsFor(note.body), false, dateFormatter)));
  setError(`${kind}-sample-count`, remaining > samples.length ? '仅预览前 ' + samples.length + ' 条。' : '');
  $(`${kind}-submit`).textContent = '导入 ' + remaining + ' 条';
  $(`${kind}-submit`).disabled = remaining === 0;
}

async function previewFileImport(kind) {
  const files = $(`${kind}-file`).files;
  if (kind === 'flomo' && !files.length) throw new Error('请选择 flomo 导出的 ZIP 或 HTML 文件。');
  const timeZone = $(`${kind}-zone`).value;
  const account = state.user.id;
  const result = kind === 'joplin'
    ? await parseJoplinFiles($('joplin-dir').files.length ? $('joplin-dir').files : files, timeZone)
    : await parseFlomoFile(files[0], timeZone);
  if (state.user?.id !== account || !$(`${kind}-dialog`).open) return;

  const { pending, duplicated, skippedLarge } = prepareBulkNotes(result.notes);
  state[kind + 'Import'] = {
    account, timeZone, pending, duplicated, skippedLarge,
    skippedAttachments: result.skippedAttachments, skippedEncrypted: result.skippedEncrypted,
    skippedEmpty: result.skippedEmpty, skippedInvalidDate: result.skippedInvalidDate,
    total: pending.length, saved: 0, skippedDuringSave: 0,
  };
  renderFileImportPreview(kind);
}

function prepareBulkNotes(notes, isDuplicate = () => false) {
  const seen = new Set();
  const pending = [];
  let duplicated = 0;
  let skippedLarge = 0;
  for (const imported of notes) {
    const note = notePayload(imported);
    if (seen.has(note.id) || state.notes.has(note.id) || state.deletedNotes.has(note.id) || isDuplicate(note)) {
      duplicated++;
      continue;
    }
    seen.add(note.id);
    const bytes = importEncoder.encode(JSON.stringify(note)).length;
    if (bytes + bulkEnvelopeBytes > bulkRequestLimit) {
      skippedLarge++;
      continue;
    }
    pending.push({ note, bytes });
  }
  return { pending, duplicated, skippedLarge };
}

function updateBulkProgress(preview, statusId, completed = 0) {
  const processed = preview.total - preview.pending.length + completed;
  setError(statusId, (preview.prefix || '') + '已处理 ' + processed + ' / ' + preview.total + ' 条，已导入 ' + preview.saved + ' 条。');
}

async function saveBulkNotes(preview, path, statusId) {
  if (state.user?.id !== preview.account) throw new Error('账号已变化，请重新打开导入。');
  ++state.writeEpoch;
  ++state.writeCount;
  setSync('loading', '正在同步');
  updateBulkProgress(preview, statusId);
  let completed = 0;
  let changed = false;
  try {
    while (completed < preview.pending.length) {
      if (state.user?.id !== preview.account) throw new Error('账号已变化，请重新打开导入。');
      const batch = [];
      let bytes = bulkEnvelopeBytes;
      for (const { note, bytes: noteBytes } of preview.pending.slice(completed, completed + bulkBatchLimit)) {
        // A single large record can still fit the service limit on its own.
        if (batch.length && bytes + noteBytes + 1 > bulkBatchTarget) break;
        bytes += noteBytes + (batch.length ? 1 : 0);
        batch.push(note);
      }
      const result = await request(path, { notes: batch }, AbortSignal.timeout(45000));
      if (state.user?.id !== preview.account) throw new Error('账号已变化，请重新打开导入。');
      if (!Array.isArray(result.notes) || !Number.isInteger(result.skipped)
        || result.skipped < 0 || result.notes.length + result.skipped !== batch.length) {
        throw new Error('服务返回了无法识别的导入结果，可以重试剩余笔记。');
      }
      for (const note of result.notes) acceptVersion({ note });
      if (result.notes.length) {
        changed = true;
        state.notesETag = null;
      }
      completed += batch.length;
      preview.saved += result.notes.length;
      preview.skippedDuringSave += result.skipped;
      updateBulkProgress(preview, statusId, completed);
    }
    setSync('ok', '已同步');
  } catch (error) {
    preview.pending = preview.pending.slice(completed);
    if (state.user?.id === preview.account) updateBulkProgress(preview, statusId);
    setSync('error', navigator.onLine ? '同步未完成' : '离线 · 无法同步');
    if (error.status === 401 || error.status === 403) setAuthNotice('登录状态已失效，请重新登录。', true);
    rebuildNoteIndex();
    renderFeedList({ reset: true });
    throw error;
  } finally {
    if (state.user?.id === preview.account) finishLocalWrites(changed);
    --state.writeCount;
    ++state.writeEpoch;
  }
}

async function saveFileImport(kind, preview) {
  try {
    await saveBulkNotes(preview, `/api/import/${kind}`, `${kind}-progress`);
  } catch (error) {
    if (state[kind + 'Import'] === preview) {
      renderFileImportPreview(kind);
      $(`${kind}-submit`).textContent = '重试剩余 ' + preview.pending.length + ' 条';
    }
    throw error;
  }
  if (state.user?.id !== preview.account || state[kind + 'Import'] !== preview) return;
  state.filter = 'journal';
  clearSearchInput();
  rebuildNoteIndex();
  renderFeedList({ reset: true });
  const skipped = preview.skippedDuringSave ? '，跳过 ' + preview.skippedDuringSave + ' 条已存在或此前删除的笔记' : '';
  $(`${kind}-dialog`).close();
  notify('已导入 ' + preview.saved + ' 条 ' + (kind === 'joplin' ? 'Joplin' : 'flomo') + ' 笔记' + skipped);
}

async function importFileNotes(event, kind) {
  event.preventDefault();
  if (!state.loaded || !state.user?.id || state[kind + 'Working']) return;
  state[kind + 'Working'] = true;
  const submit = $(`${kind}-submit`);
  const back = $(`${kind}-back`);
  const close = $(`${kind}-dialog`).querySelector(`[data-close="${kind}-dialog"]`);
  const controls = [back, close, $(`${kind}-file`), $(`${kind}-zone`)];
  if (kind === 'joplin') controls.push($('joplin-dir'), document.querySelector('[data-action="pick-joplin-dir"]'));
  for (const control of [submit, ...controls]) control.disabled = true;
  setError(`${kind}-error`, '');
  try {
    if (state[kind + 'Import']) {
      if (state[kind + 'Import'].pending.length) await saveFileImport(kind, state[kind + 'Import']);
    } else {
      setError(`${kind}-progress`, '正在读取导出文件…');
      await previewFileImport(kind);
      setError(`${kind}-progress`, '');
    }
  } catch (error) {
    if (!state[kind + 'Import']) setError(`${kind}-progress`, '');
    setError(`${kind}-error`, error.message);
  } finally {
    state[kind + 'Working'] = false;
    submit.disabled = state[kind + 'Import']?.pending.length === 0;
    for (const control of controls) control.disabled = false;
  }
}

function setDrawer(id, open, trigger) {
  const drawer = $(id);
  if (open === drawer.open) return;
  for (const button of document.querySelectorAll(`[aria-controls="${id}"]`)) button.setAttribute('aria-expanded', String(open));
  if (open) {
    drawer.opener = trigger ?? document.activeElement;
    drawer.classList.add('open');
    drawer.showModal();
  } else {
    drawer.classList.remove('open');
    drawer.close();
    drawer.opener?.focus({ preventScroll: true });
    drawer.opener = null;
  }
}

function sidebar(open, trigger) { setDrawer('sidebar', open, trigger); }

function setUtilityMenu(id, open, restoreFocus = false) {
  const trigger = document.querySelector(`[data-action="${id}"]`);
  $(id).hidden = !open;
  trigger.setAttribute('aria-expanded', String(open));
  if (open) $(id).querySelector('button:not([hidden])')?.focus({ preventScroll: true });
  if (!open && id === 'ai-options') {
    toggleAIUtilityPicker('model', false);
    toggleAIUtilityPicker('effort', false);
  }
  if (restoreFocus) trigger.focus({ preventScroll: true });
}

function focusCompose() {
  if (state.loaded) {
    $('note-body').scrollIntoView({ block: 'nearest' });
    $('note-body').focus();
  } else {
    notify('请先登录并完成同步');
  }
}

function renderReaderRelated() {
  reader.related = reader.related.filter(item => state.notes.has(item.id) && item.id !== state.noteID);
  const cards = reader.related.map(({ id }) => {
    const note = state.notes.get(id);
    const button = el('button', 'related-note');
    button.type = 'button';
    button.dataset.openNote = id;
    button.append(el('span', 'related-snippet', note.body.trim().replace(/\s+/g, ' ')),
      el('span', 'meta', noteSource(note) || dayHeading(new Date(note.createdAt))));
    return button;
  });
  $('reader-related-list').replaceChildren(...cards);
  $('reader-related').hidden = !cards.length;
}

function loadReaderRelated(id) {
  reader.controller?.abort();
  reader.controller = null;
  reader.related = reader.cache.get(id) ?? [];
  renderReaderRelated();
  if (reader.cache.has(id)) return;
  const controller = reader.controller = new AbortController();
  void request('/api/notes/' + encodeURIComponent(id) + '/related?limit=3', undefined, controller.signal).then(result => {
    if (controller.signal.aborted || state.noteID !== id) return;
    reader.related = result.related.slice(0, 3);
    reader.cache.set(id, reader.related);
    renderReaderRelated();
  }).catch(error => {
    if (!controller.signal.aborted && error.name !== 'AbortError') console.warn('暂时无法读取相关笔记。');
  });
}

function syncReaderNotes() {
  reader.cache.clear();
  if (!$('note-dialog').open) return;
  const stack = [];
  for (const entry of reader.stack) {
    if (state.notes.has(entry.id) && stack.at(-1)?.id !== entry.id) stack.push(entry);
  }
  if (stack.at(-1)?.id === state.noteID) stack.pop();
  reader.stack = stack;
  renderReaderRelated();
}

function shuffleReader(random = false) {
  const choices = [...state.notes.keys()].filter(id => id !== state.noteID);
  if (!choices.length) {
    if (!state.noteID) notify('先记录一条笔记');
    return;
  }
  openNote(choices[Math.floor(Math.random() * choices.length)], { random });
}

function emptyAIState() {
  return {
    lifecycle: null, scrollY: 0, session: null, sessions: new Map(), sessionCache: new Map(), selectedSessionId: null, upgradedNoteIds: new Set(),
    visible: false, drafts: new Map(), draftKey: 'new', nextCursor: null, loadingSessions: false, sessionsLoaded: false,
    source: null, fromWalk: false, insightContext: null, pendingTurn: null, followBottom: true, pins: new Set(),
    sending: null, loadingSession: false, sessionLoadFailed: false, sessionLoadSeq: 0, requestKey: null, atIndex: null, useWritingStyle: false,
  };
}
let ai = emptyAIState();

function gatewayMode() {
  return state.chatProvider === 'codex' && state.codexMode === 'gateway';
}

function hasGatewayModels() {
  return gatewayMode() && state.gatewayModels.length > 0;
}

const gatewaySelectIds = ['ins-rerun-model', 'profile-model-select', 'style-model-select'];
const modelVendors = { gemini: 'Gemini', openai: 'OpenAI', claude: 'Claude', other: '其他' };
const effortLabels = { '': '默认', low: '低', medium: '中', high: '高', xhigh: '极高' };
function activeModelMeta() {
  return state.gatewayModelMeta.find(item => item.id === state.gatewayModel);
}

function setGatewayModel(id) {
  state.gatewayModel = id;
  try { localStorage.setItem('weiji.gatewayModel', id); } catch {}
  renderGatewayModels();
}

function toggleAIUtilityPicker(kind, open, restoreFocus = false) {
  const trigger = $('ai-' + kind + '-toggle');
  const popover = $('ai-' + kind + '-popover');
  if (open) {
    toggleAIUtilityPicker(kind === 'model' ? 'effort' : 'model', false);
    closeNotePicker();
  }
  popover.hidden = !open;
  trigger.setAttribute('aria-expanded', String(open));
  if (!open) {
    if (restoreFocus) trigger.focus({ preventScroll: true });
  } else if (kind === 'model') {
    $('ai-model-search').value = '';
    renderModelOptions();
    $('ai-model-search').focus({ preventScroll: true });
  } else {
    (popover.querySelector('[aria-pressed="true"]') ?? popover.querySelector('button'))?.focus();
  }
}

function renderModelOptions() {
  const query = $('ai-model-search').value.trim().toLowerCase();
  const options = $('ai-model-options');
  options.replaceChildren();
  for (const [vendor, label] of Object.entries(modelVendors)) {
    const models = state.gatewayModelMeta.filter(item => item.vendor === vendor &&
      (item.label + ' ' + item.id).toLowerCase().includes(query));
    if (!models.length) continue;
    const group = el('div', 'ai-model-group');
    group.setAttribute('role', 'group');
    group.setAttribute('aria-label', label);
    group.append(el('div', 'ai-model-group-label', label));
    for (const item of models) {
      const option = el('button', 'ai-picker-row');
      option.type = 'button';
      const selected = item.id === state.gatewayModel;
      option.setAttribute('aria-pressed', String(selected));
      option.append(el('span', 'ai-picker-label', item.label));
      if (item.thinking) option.append(el('span', 'ai-thinking-badge', '思考'));
      if (item.id === state.defaultGatewayModel) {
        const star = el('span', 'ai-model-star', '★');
        star.title = '默认模型';
        star.setAttribute('aria-label', '默认模型');
        option.append(star);
      }
      if (selected) option.append(icon('check'));
      option.addEventListener('click', () => {
        setGatewayModel(item.id);
        toggleAIUtilityPicker('model', false, true);
      });
      group.append(option);
    }
    options.append(group);
  }
  if (!options.childElementCount) options.append(el('p', 'ai-picker-empty', '未找到模型'));
}

function renderAIModelPicker() {
  const item = activeModelMeta();
  const visible = hasGatewayModels() && item;
  $('ai-model-picker').hidden = !visible;
  $('ai-effort-picker').hidden = !visible || !item.thinking;
  if (!visible) {
    toggleAIUtilityPicker('model', false);
    toggleAIUtilityPicker('effort', false);
    return;
  }
  $('ai-model-toggle').replaceChildren(el('span', 'ai-picker-label', item.label), el('span', 'ai-picker-chevron'));
  const fixed = $('ai-effort-fixed');
  const trigger = $('ai-effort-toggle');
  fixed.hidden = !item.fixedEffort;
  trigger.hidden = !item.efforts.length;
  if (!item.efforts.length) toggleAIUtilityPicker('effort', false);
  fixed.textContent = item.fixedEffort ? effortLabels[item.fixedEffort] + '思考' : '';
  const effort = item.efforts.includes(state.reasoningEffort) ? state.reasoningEffort : '';
  trigger.replaceChildren(el('span', '', '思考：' + effortLabels[effort]), el('span', 'ai-picker-chevron'));
  $('ai-effort-popover').replaceChildren(...['', ...item.efforts].map(value => {
    const option = el('button', 'ai-picker-row', effortLabels[value]);
    option.type = 'button';
    option.setAttribute('aria-pressed', String(value === effort));
    if (value === effort) option.append(icon('check'));
    option.addEventListener('click', () => {
      state.reasoningEffort = value;
      try { localStorage.setItem('weiji.reasoningEffort', value); } catch {}
      renderAIModelPicker();
      syncAIOverrides();
      toggleAIUtilityPicker('effort', false, true);
    });
    return option;
  }));
}

function renderGatewayModels() {
  const hasModels = hasGatewayModels();
  for (const id of gatewaySelectIds) {
    const select = $(id);
    const rerun = id === 'ins-rerun-model';
    select.hidden = !hasModels;
    if (rerun) $('ins-rerun-controls').hidden = !hasModels;
    select.replaceChildren(...state.gatewayModels.map(model => new Option(model, model)));
    select.value = state.gatewayModel ?? '';
  }
  renderAIModelPicker();
  syncSettingsModels();
  syncAIStyleToggle();
  if (writingStyleView) renderWritingStyle();
}

let gatewayModelsRevision = 0;

async function loadGatewayModels(signal = accountLifecycle.signal) {
  if (!gatewayMode()) return;
  const revision = ++gatewayModelsRevision;
  try {
    const { models, defaultModel, modelMeta } = await request('/api/ai/models', undefined, signal);
    if (revision !== gatewayModelsRevision || !gatewayMode() || signal.aborted) return;
    state.gatewayModels = models;
    state.defaultGatewayModel = defaultModel;
    state.gatewayModelMeta = modelMeta ?? models.map(id => ({ id, label: id, vendor: 'other', efforts: [] }));
    let remembered;
    try {
      remembered = localStorage.getItem('weiji.gatewayModel');
      const preferred = localStorage.getItem('weiji.defaultModel');
      state.preferredModel = models.includes(preferred) ? preferred : null;
      state.defaultEffort = localStorage.getItem('weiji.defaultEffort') || '';
      state.reasoningEffort = localStorage.getItem('weiji.reasoningEffort') ?? state.defaultEffort;
    } catch {}
    const preferred = state.gatewayModel || remembered || state.preferredModel;
    state.gatewayModel = models.includes(preferred) ? preferred : defaultModel;
    renderGatewayModels();
  } catch (error) {
    if (revision === gatewayModelsRevision && error.name !== 'AbortError' && !signal.aborted) notify(error.message);
  }
}

function providerSettings() {
  return state.chatProvider === 'codex' && state.codexAvailable
    ? { provider: 'codex', ...(hasGatewayModels() && state.gatewayModel ? { model: state.gatewayModel } : {}) }
    : { provider: 'openai', model: state.model, apiKey: state.apiKey };
}

let prof = null;
const profileView = $('ins-panel-profile');
const profileButton = action => profileView.querySelector('[data-action="profile-' + action + '"]');

function initProfile() {
  if (prof) return;
  const view = prof = {
    lifecycle: new AbortController(), profile: null,
    loading: false, loaded: false, loadError: false, saving: false, generating: null, editing: false,
  };
  loadProfile(view);
}

function closeProfile() {
  const view = prof;
  if (!view) return;
  prof = null;
  view.lifecycle.abort();
  profileView.hidden = true;
  $('profile-reader').hidden = false;
  $('profile-editor').hidden = $('profile-empty').hidden = true;
  $('profile-enabled').checked = true;
  $('profile-body').replaceChildren();
  $('profile-status').textContent = $('profile-meta').textContent = $('profile-text').value = '';
  setError('profile-error', '');
  profileButton('reload').hidden = true;
}

async function loadProfile(view) {
  if (!view || view.loading) return;
  const signal = view.lifecycle.signal;
  view.loading = true;
  $('profile-status').textContent = '正在读取画像…';
  setError('profile-error', '');
  syncProfileControls();
  try {
    // Reopening during a save must read the committed profile.
    if (pendingProfileSave) await pendingProfileSave;
    if (prof !== view) return;
    const { profile } = await request('/api/ai/profile', undefined, signal);
    if (prof !== view) return;
    view.profile = profile;
    view.loaded = true;
    view.loadError = false;
    failedProfileSave = null;
    renderProfile();
  } catch (error) {
    if (prof === view) {
      view.loaded = false;
      view.loadError = true;
      setError('profile-error', error.message);
    }
  } finally {
    if (prof === view) {
      view.loading = false;
      $('profile-status').textContent = '';
      syncProfileControls();
    }
  }
}

function renderProfile() {
  const profile = prof.profile;
  const content = profile?.content ?? '';
  $('profile-enabled').checked = profile?.enabled ?? true;
  $('profile-meta').textContent = content
    ? '基于 ' + profile.noteCount + ' 条笔记 · ' + profile.updatedAt.slice(0, 10) + ' 更新'
    : '尚未生成';
  $('profile-empty').hidden = Boolean(content);
  renderSafeMarkdown($('profile-body'), content, []);
}

function syncProfileControls() {
  const busy = !prof.loaded || prof.loading || prof.saving;
  const generating = Boolean(prof.generating);
  profileButton('reload').hidden = !prof.loadError || prof.loading;
  const generate = profileButton('generate');
  generate.disabled = busy;
  generate.textContent = generating ? '停止生成' : prof.profile?.content ? '重新生成' : '生成画像';
  for (const button of profileView.querySelectorAll('[data-action="profile-edit"]')) {
    button.disabled = busy || generating || prof.editing;
  }
  profileButton('clear').disabled = busy || generating || !prof.profile?.content;
  profileButton('save').disabled = profileButton('cancel-edit').disabled =
    $('profile-enabled').disabled = $('profile-text').disabled = busy || generating;
  $('profile-reader').hidden = prof.editing;
  $('profile-editor').hidden = !prof.editing;
}

function setProfileEditing(editing) {
  if (!prof?.loaded || (editing && (prof.loading || prof.saving || prof.generating))) return;
  prof.editing = editing;
  $('profile-text').value = editing ? prof.profile?.content ?? '' : '';
  setError('profile-error', '');
  syncProfileControls();
  (editing ? $('profile-text') : profileButton('edit')).focus({ preventScroll: true });
}

function saveProfile(toggleOnly = false, clear = false) {
  const view = prof;
  if (!view?.loaded || view.loading || view.saving || view.generating) return;
  const enabled = $('profile-enabled').checked;
  const body = toggleOnly ? { enabled } : { enabled, content: clear ? '' : $('profile-text').value };
  const status = $('profile-status');
  view.saving = true;
  status.textContent = '正在保存…';
  setError('profile-error', '');
  const signal = accountLifecycle.signal;
  const save = pendingProfileSave = request('/api/ai/profile', body, signal).then(({ profile }) => {
    if (signal.aborted) return false;
    failedProfileSave = null;
    if (prof === view) {
      view.profile = profile;
      if (!toggleOnly) {
        view.editing = false;
        $('profile-text').value = '';
      }
      renderProfile();
      status.textContent = toggleOnly ? (profile.enabled ? '已启用' : '已停用') : '已保存';
    }
    return true;
  }).catch(error => {
    if (signal.aborted || error.name === 'AbortError') return false;
    failedProfileSave = error.message || '个人画像设置保存失败';
    if (prof === view) {
      status.textContent = '';
      if (toggleOnly) $('profile-enabled').checked = view.profile?.enabled ?? true;
      setError('profile-error', failedProfileSave);
    }
    return false;
  }).finally(() => {
    if (pendingProfileSave === save) pendingProfileSave = null;
    if (prof === view) {
      view.saving = false;
      syncProfileControls();
      if (!toggleOnly && !view.editing) profileButton('edit').focus({ preventScroll: true });
    }
  });
  syncProfileControls();
}

async function generateProfile() {
  const view = prof;
  if (!view?.loaded || view.loading || view.saving) return;
  if (view.generating) { view.generating.abort(); return; }
  const settings = providerSettings();
  if (settings.provider === 'openai' && !settings.apiKey) {
    setError('profile-error', '请先在设置里填写 OpenAI API Key。');
    return;
  }
  const controller = view.generating = new AbortController();
  const signal = AbortSignal.any([view.lifecycle.signal, controller.signal]);
  const status = $('profile-status');
  view.editing = false;
  $('profile-text').value = '';
  $('profile-empty').hidden = true;
  setError('profile-error', '');
  status.textContent = '正在整理代表性笔记…';
  syncProfileControls();
  let preview = '', result = null;
  try {
    await requestStream('/api/ai/profile/generate', { ...settings, stream: true }, {
      signal,
      onEvent(name, data) {
        if (prof !== view || signal.aborted) return;
        if (name === 'status') status.textContent = data.message;
        else if (name === 'delta') {
          preview = (preview + data.text).slice(0, $('profile-text').maxLength);
          renderStreamingMarkdown($('profile-body'), preview);
        } else if (name === 'done') result = data.profile;
        else if (name === 'error') throw new Error(data.error || '暂时无法生成画像，请稍后重试。');
      },
    });
    if (prof !== view) return;
    if (!result) throw new Error('画像生成意外中断，请重试。');
    view.profile = result;
    failedProfileSave = null;
    status.textContent = '已生成并保存';
  } catch (error) {
    if (prof !== view) return;
    status.textContent = signal.aborted ? '已停止生成' : '';
    if (!signal.aborted) setError('profile-error', error.message);
  } finally {
    if (prof === view) {
      view.generating = null;
      renderProfile();
      syncProfileControls();
    }
  }
}

const stylePath = '/api/ai/writing-style';
const styleRelayMessage = '当前 Codex 中转暂不支持写作风格，请切换到服务端网关或 OpenAI 接口。';
let writingStyleView = null;
const styleButton = action => $('profile-pane-style').querySelector(`[data-action="style-${action}"]`);

function relayMode() {
  return state.chatProvider === 'codex' && state.codexMode === 'relay';
}

function setProfilePane(pane) {
  for (const button of profileView.querySelectorAll('[data-action="profile-pane"]')) {
    const selected = button.dataset.pane === pane;
    insPressed(button, selected);
    $('profile-pane-' + button.dataset.pane).hidden = !selected;
  }
  if (pane !== 'style' || writingStyleView) return;
  const view = writingStyleView = { controller: new AbortController(), tags: new Set(), suggested: [], style: null };
  $('style-range').value = 'all';
  $('style-start').value = $('style-end').value = dayKey(new Date());
  loadWritingStyle(view);
}

function closeWritingStyle() {
  writingStyleView?.controller.abort();
  writingStyleView = null;
  setProfilePane('bio');
  for (const id of ['style-status', 'style-rules', 'style-tag-list', 'style-anchors', 'style-anchor-options', 'style-candidates', 'style-reveal']) {
    $(id).replaceChildren();
  }
  for (const id of ['style-text', 'style-blind-prompt', 'style-anchor-search', 'style-tags-search']) $(id).value = '';
  for (const id of ['style-votes', 'style-reveal', 'style-editor', 'style-tags-picker', 'style-anchor-picker']) $(id).hidden = true;
  $('style-tags-toggle').setAttribute('aria-expanded', 'false');
  $('style-anchor-toggle').setAttribute('aria-expanded', 'false');
  setError('style-error', '');
}

async function loadWritingStyle(view) {
  view.loading = true;
  setError('style-error', '');
  $('style-status').textContent = '正在读取写作风格…';
  renderWritingStyle();
  try {
    if (pendingStyleSave) await pendingStyleSave;
    if (writingStyleView !== view) return;
    const { style } = await request(stylePath, undefined, view.controller.signal);
    if (writingStyleView !== view) return;
    failedStyleSave = null;
    view.style = style;
    view.loaded = true;
    const scope = style?.scope;
    $('style-range').value = scope?.range ?? 'all';
    $('style-start').value = scope?.startDate ?? dayKey(new Date());
    $('style-end').value = scope?.endDate ?? $('style-start').value;
    view.tags = new Set(scope?.tags ?? []);
    view.tagMode = scope?.tagMode ?? 'any';
  } catch (error) {
    if (writingStyleView === view) setError('style-error', error.message);
  } finally {
    if (writingStyleView === view) {
      view.loading = false;
      $('style-status').textContent = '';
      renderWritingStyle();
    }
  }
}

function styleAction(label, action, id) {
  const button = actionButton(label, action);
  button.className = 'button button-secondary';
  if (id) button.dataset.id = id;
  return button;
}

function renderStyleTags() {
  const { tags } = writingStyleView;
  const names = state.noteIndex?.tagNames ?? new Map();
  const query = $('style-tags-search').value.trim().toLowerCase();
  $('style-tags-toggle').textContent = tags.size ? `${tags.size} 个标签` : '全部标签';
  const keys = [...tags, ...[...names.keys()].filter(tag => !tags.has(tag) && tag.includes(query)).slice(0, 24)];
  $('style-tag-list').replaceChildren(...keys.map(tag => {
    const button = actionButton('#' + (names.get(tag) ?? tag), 'style-tag');
    button.dataset.tag = tag;
    insPressed(button, tags.has(tag));
    return button;
  }));
}

function activeStyleAnchorIds(view) {
  return (view.style?.anchors ?? []).map(anchor => anchor.id);
}

function renderStyleAnchorPicker() {
  const view = writingStyleView;
  const selected = new Set(activeStyleAnchorIds(view));
  const query = $('style-anchor-search').value.trim().toLowerCase();
  const matches = [];
  for (const note of state.noteIndex?.all ?? []) {
    if (selected.has(note.id)) continue;
    const end = note.reading == null ? note.body.length : note.body.indexOf('\n\n原文：');
    if (end < 0) continue;
    const text = note.body.slice(0, end).trim();
    if (!text || (query && !text.toLowerCase().includes(query) && !note.reading?.bookTitle?.toLowerCase().includes(query))) continue;
    const button = styleAction(text.slice(0, 96), 'style-add-anchor', note.id);
    button.disabled = Boolean(view.saving || view.generating || view.blinding || view.editing);
    matches.push(button);
    if (matches.length === 24) break;
  }
  $('style-anchor-options').replaceChildren(...(matches.length ? matches : [el('p', 'help-text', '没有匹配的原创笔记。')]));
}

function toggleStylePicker(kind, open) {
  $(`style-${kind}-picker`).hidden = !open;
  $(`style-${kind}-toggle`).setAttribute('aria-expanded', String(open));
  if (!open) return;
  $(`style-${kind}-search`).value = '';
  if (kind === 'tags') renderStyleTags();
  else renderStyleAnchorPicker();
  $(`style-${kind}-search`).focus();
}

function renderWritingStyle() {
  const view = writingStyleView;
  const { style, loaded, loading, saving, generating, editing, blinding } = view;
  const relay = relayMode();
  const busy = !loaded || saving || generating || editing || blinding;
  setError('style-relay', relay ? styleRelayMessage : '');
  styleButton('reload').hidden = loaded || loading;
  styleButton('generate').textContent = generating ? '停止提炼' : '提炼风格';
  styleButton('generate').disabled = !generating && Boolean(busy || relay);
  styleButton('edit').disabled = Boolean(busy);
  for (const id of ['style-model-select', 'style-range', 'style-start', 'style-end', 'style-tags-toggle']) $(id).disabled = Boolean(busy || relay);
  $('style-custom-dates').hidden = $('style-range').value !== 'custom';
  $('style-editor').hidden = !editing;
  $('style-rules').hidden = Boolean(editing);
  for (const action of ['save', 'cancel-edit']) styleButton(action).disabled = Boolean(saving);
  $('style-text').disabled = Boolean(saving);
  if (!generating) renderSafeMarkdown($('style-rules'), style?.rules || (loaded ? '尚未添加风格规则。' : ''), []);
  renderStyleTags();
  const anchors = style?.anchors ?? [];
  $('style-anchor-count').textContent = `${anchors.length} / 5`;
  $('style-anchor-toggle').disabled = Boolean(busy || anchors.length >= 5);
  styleButton('adopt').hidden = !styleSuggestions(view).length;
  styleButton('adopt').disabled = Boolean(busy);
  $('style-anchors').replaceChildren(...(style?.anchorNoteIds ?? []).map(id => {
    const anchor = anchors.find(item => item.id === id);
    const row = el('li', 'style-row');
    const remove = styleAction('移除', 'style-remove-anchor', id);
    remove.setAttribute('aria-label', anchor ? '移除锚点：' + anchor.excerpt.slice(0, 24) : '移除失效锚点');
    remove.disabled = Boolean(busy);
    row.append(el('span', '', anchor?.excerpt ?? '该锚点已失效'), remove);
    return row;
  }));
  if (!$('style-anchor-picker').hidden) renderStyleAnchorPicker();
  styleButton('blind').disabled = Boolean(busy || relay || !style?.ready);
}

function styleSuggestions(view) {
  const ids = activeStyleAnchorIds(view);
  return view.suggested.filter(anchor => !ids.includes(anchor.id) && state.notes.has(anchor.id)).slice(0, 5 - ids.length);
}

function editStyleRules(editing) {
  const view = writingStyleView;
  view.editing = editing;
  $('style-text').value = editing ? view.style?.rules ?? '' : '';
  updateStyleCount();
  setError('style-error', '');
  renderWritingStyle();
  (editing ? $('style-text') : styleButton('edit')).focus();
}

function updateStyleCount() {
  $('style-count').textContent = `${$('style-text').value.length} / 1500`;
}

function saveStyle(changes) {
  const view = writingStyleView;
  if (!view?.loaded || view.saving || view.generating || view.blinding) return;
  const signal = accountLifecycle.signal;
  view.saving = true;
  setError('style-error', '');
  $('style-status').textContent = '正在保存…';
  const save = pendingStyleSave = request(stylePath, changes, signal).then(({ style }) => {
    if (signal.aborted) return false;
    failedStyleSave = null;
    if (writingStyleView === view) {
      view.style = style;
      if (changes.rules !== undefined) {
        view.editing = false;
        $('style-text').value = '';
      }
      toggleStylePicker('anchor', false);
      $('style-status').textContent = '已保存';
    }
    return true;
  }).catch(error => {
    if (signal.aborted || error.name === 'AbortError') return false;
    failedStyleSave = error.message || '写作风格保存失败';
    if (writingStyleView === view) {
      setError('style-error', failedStyleSave);
      $('style-status').textContent = '';
    }
    return false;
  }).finally(() => {
    if (pendingStyleSave === save) pendingStyleSave = null;
    if (writingStyleView !== view) return;
    view.saving = false;
    renderWritingStyle();
    if (!view.editing && changes.rules !== undefined) styleButton('edit').focus();
  });
  renderWritingStyle();
}

function styleProviderSettings() {
  const settings = providerSettings();
  const model = $('style-model-select').value;
  if (gatewayMode() && model) settings.model = model;
  if (settings.provider === 'openai' && !settings.apiKey) {
    setError('style-error', '请先在上方填写并保存 OpenAI API Key。');
    return null;
  }
  return settings;
}

async function generateWritingStyle() {
  const view = writingStyleView;
  if (view.generating) { view.generating.abort(); return; }
  if (relayMode()) { setError('style-error', styleRelayMessage); return; }
  const settings = styleProviderSettings();
  if (!settings) return;
  const range = $('style-range').value;
  const scope = { range, tags: [...view.tags], tagMode: view.tagMode, tzOffsetMinutes: new Date().getTimezoneOffset(),
    ...(range === 'custom' ? { startDate: $('style-start').value, endDate: $('style-end').value } : {}) };
  const controller = view.generating = new AbortController();
  const signal = AbortSignal.any([view.controller.signal, controller.signal]);
  const status = $('style-status');
  status.textContent = '正在整理原创笔记…';
  setError('style-error', '');
  toggleStylePicker('tags', false);
  toggleStylePicker('anchor', false);
  renderWritingStyle();
  let result, preview = '';
  try {
    await requestStream(stylePath + '/generate', { ...settings, scope, stream: true }, {
      signal,
      onEvent(name, data) {
        if (writingStyleView !== view || signal.aborted) return;
        if (name === 'status') status.textContent = data.message || '正在提炼…';
        if (name === 'delta') {
          preview = (preview + data.text).slice(0, 1500);
          renderStreamingMarkdown($('style-rules'), preview);
        }
        if (name === 'done') result = data;
        if (name === 'error') throw new Error(data.error || '提炼失败，请重试。');
      },
    });
    if (writingStyleView !== view) return;
    if (!result?.style) throw new Error('风格提炼意外中断，请重试。');
    view.style = result.style;
    view.suggested = result.suggestedAnchors;
    failedStyleSave = null;
    status.textContent = '已提炼并保存';
  } catch (error) {
    if (writingStyleView !== view) return;
    status.textContent = signal.aborted ? '已停止提炼' : '';
    if (!signal.aborted) setError('style-error', error.message);
  } finally {
    if (writingStyleView === view) {
      view.generating = null;
      renderWritingStyle();
    }
  }
}

async function startStyleBlindTest() {
  const view = writingStyleView;
  if (relayMode()) { setError('style-error', styleRelayMessage); return; }
  const settings = styleProviderSettings();
  if (!settings) return;
  view.blinding = true;
  view.candidates = [];
  $('style-candidates').replaceChildren();
  $('style-votes').hidden = $('style-reveal').hidden = true;
  $('style-status').textContent = '正在生成两版…';
  setError('style-error', '');
  renderWritingStyle();
  try {
    const { candidates } = await request(stylePath + '/blind-test', { ...settings, prompt: $('style-blind-prompt').value.trim() }, view.controller.signal);
    if (writingStyleView !== view) return;
    view.candidates = candidates;
    $('style-candidates').replaceChildren(...candidates.map(({ slot, text }) => {
      const card = el('article', 'style-candidate');
      card.append(el('strong', '', slot), el('p', '', text));
      return card;
    }));
    $('style-votes').hidden = false;
  } catch (error) {
    if (writingStyleView === view) setError('style-error', error.message);
  } finally {
    if (writingStyleView === view) {
      view.blinding = false;
      $('style-status').textContent = '';
      renderWritingStyle();
    }
  }
}

function revealStyleVote(slot) {
  const { candidates } = writingStyleView;
  candidates.forEach((candidate, index) => {
    $('style-candidates').children[index].firstElementChild.textContent = `${candidate.slot} · ${candidate.variant === 'styled' ? '写作风格' : '基准'}`;
  });
  const chosen = candidates.find(candidate => candidate.slot === slot);
  const reveal = $('style-reveal');
  reveal.textContent = chosen?.variant === 'styled' ? `你选了 ${slot}。觉得贴近的话，可以再换个主题试试。`
    : `${chosen ? `你选了 ${slot}。` : '你觉得差不多。'}可以把想要的句式或措辞写进风格规则，再试一次。`;
  $('style-votes').hidden = true;
  reveal.hidden = false;
}

const aiChatView = $('ai-chat-view');
const aiButton = action => document.querySelector('[data-action="ai-' + action + '"]');

function closeNotePicker(refocus = false) {
  $('ai-note-picker').hidden = true;
  syncAIScrollButton();
  ai.atIndex = null;
  if (refocus) $('ai-chat-input').focus({ preventScroll: true });
}

function setAISessionRail(open, trigger) { setDrawer('ai-session-rail', open, trigger); }

function closeAIChat() {
  const view = ai;
  view.lifecycle?.abort();
  closeInsights();
  ai = emptyAIState();
  setAISessionRail(false);
  setUtilityMenu('ai-options', false);
  closeNotePicker();
  aiChatView.hidden = true;
  $('main').hidden = false;
  $('ai-chat-input').value = $('ai-note-picker-search').value = '';
  $('ai-note-picker-results').replaceChildren();
  setError('ai-chat-error', '');
  renderAIThread();
  renderAIPins();
  renderAISessions();
  syncAIControls();
  syncNavActive();
}

function showNotes() {
  if (!ai.visible) return;
  ai.visible = false;
  setAISessionRail(false);
  setUtilityMenu('ai-options', false);
  aiChatView.hidden = true;
  $('main').hidden = false;
  syncNavActive();
  window.scrollTo(0, ai.scrollY);
}

function openAIChat() {
  if (!state.loaded) { notify('请先登录并完成同步'); return false; }
  sidebar(false);
  if (ai.visible) return true;
  ai.visible = true;
  ai.scrollY = window.scrollY;
  $('main').hidden = true;
  aiChatView.hidden = false;
  syncNavActive();
  if (!ai.lifecycle) {
    ai.lifecycle = new AbortController();
    openInsights();
    loadAISessions();
    loadGatewayModels(ai.lifecycle.signal);
  }
  renderAIThread();
  syncAIControls();
  return true;
}

function switchAI(action) {
  if (ai.afterSend) return;
  if (ai.sending || ins?.run) {
    if (!confirm('正在生成回复。停止并切换吗？')) return;
    if (ai.sending) {
      ai.afterSend = action;
      ai.sending.abort();
      return;
    }
    cancelInsRun();
  }
  action();
}

function aiNoteTitle(note) {
  return note.reading?.bookTitle || note.body.trim().split('\n')[0].slice(0, 80);
}

function storeAISession(view, session) {
  const { turns, ...summary } = session;
  const nextVersion = session.version ?? 0;
  if ((view.sessions.get(session.id)?.version ?? 0) <= nextVersion) view.sessions.set(session.id, summary);
  if (turns && (view.sessionCache.get(session.id)?.version ?? 0) <= nextVersion) view.sessionCache.set(session.id, session);
  if (session.sourceNoteId) view.upgradedNoteIds.add(session.sourceNoteId);
}

async function loadAISessions(more = false) {
  const view = ai;
  if (view.loadingSessions || (more && !view.nextCursor)) return;
  view.loadingSessions = true;
  renderAISessions();
  const path = '/api/ai/sessions' + (more ? '?cursor=' + encodeURIComponent(view.nextCursor) : '');
  try {
    const result = await request(path, undefined, view.lifecycle.signal);
    for (const session of result.sessions) storeAISession(view, session);
    if (result.upgradedNoteIds) {
      view.upgradedNoteIds = new Set(result.upgradedNoteIds);
      for (const session of view.sessions.values()) {
        if (session.sourceNoteId) view.upgradedNoteIds.add(session.sourceNoteId);
      }
    }
    view.nextCursor = result.nextCursor;
    view.sessionsLoaded = true;
  } catch (error) {
    if (view === ai && error.name !== 'AbortError') setError('ai-chat-error', error.message);
  } finally {
    view.loadingSessions = false;
    if (view === ai) renderAISessions();
  }
}

function historyGroup(value) {
  const date = new Date(value);
  const now = new Date();
  if (dayKey(date) === dayKey(now)) return '今天';
  now.setHours(0, 0, 0, 0);
  now.setDate(now.getDate() - (now.getDay() + 6) % 7);
  return date >= now ? '本周' : '更早';
}

function renderAISessions() {
  const entries = [...ai.sessions.values(), ...(ins?.reports ?? []).map(report => ({ ...report, report: true }))];
  if (ai.sessionsLoaded) {
    for (const note of state.notes.values()) {
      if (note.turns?.length && !ai.upgradedNoteIds.has(note.id)) {
        entries.push({ id: note.id, title: aiNoteTitle(note), createdAt: note.createdAt, legacy: true });
      }
    }
  }
  const timestamp = entry => entry.updatedAt || entry.createdAt;
  entries.sort((a, b) => Date.parse(timestamp(b)) - Date.parse(timestamp(a)) || b.id.localeCompare(a.id));
  const fragment = document.createDocumentFragment();
  let group;
  for (const entry of entries) {
    const next = historyGroup(timestamp(entry));
    if (next !== group) fragment.append(el('h3', 'meta history-group', group = next));
    const row = el('div', 'ai-session-row');
    const select = actionButton('', entry.report ? 'ins-open-report' : entry.legacy ? 'ai-select-legacy-note' : 'ai-select-session');
    select.append(el('span', 'ai-session-title', entry.title));
    select.dataset.id = entry.id;
    if (!entry.legacy && !entry.report) select.dataset.sessionId = entry.id;
    if (entry.report ? ins.report?.id === entry.id : ai.selectedSessionId === entry.id) select.setAttribute('aria-current', 'true');
    row.append(select);
    if (!entry.legacy) {
      const remove = actionButton('✕', entry.report ? 'ins-delete-report' : 'ai-delete-session', 'ai-session-delete');
      remove.dataset.id = entry.id;
      remove.setAttribute('aria-label', '删除：' + entry.title);
      row.append(remove);
    }
    fragment.append(row);
  }
  if (!entries.length && !ai.loadingSessions) fragment.append(el('p', 'help-text', '还没有历史记录'));
  $('ai-session-list').replaceChildren(fragment);
  const more = aiButton('load-more-sessions');
  more.hidden = !ai.nextCursor;
  more.disabled = ai.loadingSessions;
}

function buildAIUserMessage(text, citations) {
  const message = el('div', 'ai-msg ai-msg-user');
  const matched = text.match(/^\[洞察上下文：([^\n]+)\]\n([\s\S]*?)\n\n\[追问\]\n([\s\S]+)$/);
  if (matched) {
    const details = el('details', 'ai-ctx-fold ai-ctx-inline');
    details.append(el('summary', '', '附带洞察：' + matched[1]), el('div', 'ai-ctx-fold-body', matched[2]));
    const ask = el('div', 'ai-msg-ask');
    appendCitedText(ask, matched[3], citations);
    message.append(details, ask);
  } else {
    appendCitedText(message, text, citations);
  }
  return message;
}

function renderStreamingMarkdown(container, text) {
  renderSafeMarkdown(container, text, []);
  const last = container.lastElementChild;
  const end = last?.matches('ul, ol') ? last.lastElementChild : last;
  const caret = el('span', 'ai-stream-caret');
  caret.setAttribute('aria-hidden', 'true');
  (end?.matches('p, li, h2, h3, h4, blockquote') ? end : container).append(caret);
}

function aiSkeleton() {
  const node = el('div', 'loading-skeleton ai-session-skeleton');
  node.setAttribute('role', 'status');
  node.setAttribute('aria-label', '正在读取对话');
  node.append(el('i'), el('i'), el('i'));
  return node;
}

function buildAISteps(steps, pending = false) {
  const card = el('details', 'ai-steps ai-steps-card');
  const count = new Set(steps.flatMap(step => (step.items ?? []).map(item => item.noteId))).size;
  const summary = pending && !count ? '正在检索笔记' : `参考了 ${count} 条笔记`;
  card.append(el('summary', '', summary));
  const list = el('ol', 'ai-step-list');
  for (const step of steps) {
    const item = el('li', 'ai-step');
    item.dataset.status = step.status;
    const header = el('div', 'ai-step-heading');
    header.append(el('span', 'ai-step-dot'), el('strong', '', step.label));
    if (step.detail) header.append(el('span', 'ai-step-detail', step.detail));
    if (step.durationMs !== undefined) header.append(el('span', 'ai-step-time', step.durationMs + ' ms'));
    item.append(header);
    for (const note of step.items ?? []) {
      const button = el('button', 'ai-step-note');
      button.type = 'button';
      button.dataset.citeNoteId = note.noteId;
      button.append(el('span', '', '[' + note.ref + '] ' + note.title), el('span', 'ai-step-detail', note.excerpt));
      item.append(button);
    }
    list.append(item);
  }
  card.append(list);
  if (pending) {
    const reasoning = el('details', 'ai-reasoning');
    reasoning.hidden = true;
    reasoning.append(el('summary', '', '实时思考'), el('pre', 'ai-reasoning-text'));
    card.append(reasoning);
  }
  return card;
}

function renderAIPendingBubble(bubble, pending, finished = false) {
  let card = bubble.querySelector('.ai-steps');
  if (pending.steps.size && (!card || pending.stepsDirty)) {
    const next = buildAISteps([...pending.steps.values()], !finished);
    if (card) {
      next.open = !finished && card.open;
      if (!finished) next.querySelector('.ai-reasoning').replaceWith(card.querySelector('.ai-reasoning'));
      card.replaceWith(next);
    } else bubble.prepend(next);
    card = next;
    pending.stepsDirty = false;
  }
  if (card && pending.reasoning && !finished) {
    const reasoning = card.querySelector('.ai-reasoning');
    reasoning.hidden = false;
    const text = reasoning.querySelector('pre');
    if (text.textContent !== pending.reasoning) text.textContent = pending.reasoning;
  }
  const body = bubble.querySelector('.ai-pending-text');
  bubble.classList.toggle('is-streaming', !finished && Boolean(pending.streamText));
  if (pending.streamText) {
    const tail = updateStreamingMarkdown(body, pending.streamText, pending.citations);
    const caret = bubble.querySelector('.ai-stream-caret');
    if (finished) caret?.remove();
    else {
      const cursor = caret ?? el('span', 'ai-stream-caret');
      cursor.setAttribute('aria-hidden', 'true');
      if (cursor.parentNode !== tail) tail.append(cursor);
    }
  } else {
    let thinking = body.querySelector('.ai-thinking');
    if (!thinking || thinking.lastElementChild.textContent !== pending.status) {
      thinking = el('span', 'ai-thinking');
      thinking.append(el('i'), el('i'), el('i'), el('span', '', pending.status));
      body.replaceChildren(thinking);
    }
  }
}

function isAIThreadAtBottom(thread = $('ai-chat-thread')) {
  return thread.scrollHeight - thread.scrollTop - thread.clientHeight <= 40;
}

function syncAIScrollButton() {
  const thread = $('ai-chat-thread');
  const button = $('ai-scroll-bottom');
  if (!button) return;
  const scrollable = thread.scrollHeight > thread.clientHeight + 60;
  const show = scrollable && !isAIThreadAtBottom(thread) && $('ai-note-picker').hidden;
  button.hidden = !show;
  button.classList.toggle('is-streaming', Boolean(ai.sending));
}

function scrollAIThreadToBottom(smooth = false) {
  const thread = $('ai-chat-thread');
  ai.followBottom = true;
  if (smooth && typeof thread.scrollTo === 'function') {
    thread.scrollTo({ top: thread.scrollHeight, behavior: 'smooth' });
  } else {
    thread.scrollTop = thread.scrollHeight;
  }
  syncAIScrollButton();
}

function renderAIThread(walkPinsOpen = false) {
  const turns = ai.session?.turns ?? ai.source?.turns ?? [];
  $('ai-chat-title').textContent = ai.session?.title || ai.insightContext?.title || (ai.source && aiNoteTitle(ai.source)) || 'AI 对话';
  const thread = $('ai-chat-thread');
  const turnsBox = $('ai-turns');
  $('ai-empty').hidden = Boolean(turns.length || ai.pendingTurn || ai.source || ins?.report || ins?.attempt || ai.loadingSession);
  if (ai.loadingSession) {
    $('ai-chat-title').textContent = ai.sessions.get(ai.selectedSessionId)?.title || 'AI 对话';
    turnsBox.replaceChildren(aiSkeleton());
    syncAIScrollButton();
    return;
  }
  const prevTop = thread.scrollTop;
  const shouldFollow = ai.followBottom;
  const nodes = [];
  if (ai.source && ((!turns.length && !ai.pendingTurn) || (ai.fromWalk && ai.pins.size > 1))) {
    const card = el('section', 'ai-context-card');
    const relatedCount = [...ai.pins].filter(id => id !== ai.source.id).length;
    const label = !ai.fromWalk ? '笔记上下文'
      : relatedCount ? `随机漫步 · 含 ${relatedCount} 条相关笔记` : '随机漫步 · 焦点笔记';
    const preview = ai.source.body.trim().replace(/\s+/g, ' ');
    const meta = el('div', 'ai-context-meta');
    meta.append(el('span', 'ai-context-badge', label));
    card.append(meta,
      el('p', 'ai-context-excerpt', preview.slice(0, 120) + (preview.length > 120 ? '…' : '')));
    if (ai.pins.size > 1) {
      const details = el('details', 'ai-ctx-fold');
      details.open = walkPinsOpen;
      const list = el('ol', 'ai-walk-pin-list');
      for (const id of ai.pins) {
        const note = state.notes.get(id);
        if (!note) continue;
        const excerpt = note.body.trim().replace(/\s+/g, ' ').slice(0, 90);
        const button = el('button', '', excerpt || '未命名笔记');
        button.type = 'button';
        button.dataset.openNote = id;
        if (note.reading?.bookTitle) button.append(el('span', 'ai-walk-pin-book', '《' + note.reading.bookTitle + '》'));
        const item = el('li');
        item.append(button);
        list.append(item);
      }
      details.append(el('summary', '', '查看引用的 ' + ai.pins.size + ' 条笔记'), list);
      card.append(details);
    }
    nodes.push(card);
  }
  for (const turn of turns) {
    if (turn.role === 'user') {
      nodes.push(buildAIUserMessage(turn.text, turn.citations));
    } else {
      const message = el('div', 'ai-msg ai-msg-' + turn.role);
      const body = el('div', 'ai-reply-text');
      renderSafeMarkdown(body, turn.text, turn.citations ?? []);
      if (turn.steps?.length) message.append(buildAISteps(turn.steps));
      message.append(body, makeLensMenu(turn.text));
      nodes.push(message);
    }
  }
  if (ai.pendingTurn) {
    nodes.push(buildAIUserMessage(ai.pendingTurn.userText));
    const reply = el('div', 'ai-msg ai-msg-assistant ai-msg-pending');
    reply.id = 'ai-pending-reply';
    reply.append(el('div', 'ai-pending-text'));
    renderAIPendingBubble(reply, ai.pendingTurn);
    nodes.push(reply);
  }
  turnsBox.replaceChildren(...nodes);
  if (shouldFollow) thread.scrollTop = thread.scrollHeight;
  else thread.scrollTop = prevTop;
  syncAIScrollButton();
}

function aiPinLabel(note) {
  const body = note.body.trim().replace(/\s+/g, ' ');
  return body ? body.slice(0, 24) : (note.reading?.bookTitle || '未命名笔记');
}

function renderAIPins() {
  $('ai-pinned-notes').replaceChildren(...[...ai.pins].flatMap(id => {
    const note = state.notes.get(id);
    if (!note) return [];
    const label = aiPinLabel(note);
    const excerpt = note.body.trim().slice(0, 240);
    const button = el('button', 'ai-pin-chip');
    button.type = 'button';
    button.dataset.removePin = id;
    button.title = note.reading?.bookTitle ? '《' + note.reading.bookTitle + '》\n' + excerpt : excerpt;
    button.setAttribute('aria-label', '移除引用：' + label);
    button.append(el('span', 'ai-pin-label', label), el('span', 'ai-pin-x', '×'));
    return [button];
  }));
}

function syncAIComposerPlaceholder() {
  $('ai-chat-input').placeholder = ai.insightContext
    ? `针对《${ai.insightContext.title}》继续追问…`
    : ai.pins.size ? '问问引用的笔记…' : '问问你的笔记…';
}

function refreshAIPins() {
  renderAIPins();
  syncAIComposerPlaceholder();
  if (ai.source && (ai.fromWalk || (!ai.session?.turns?.length && !ai.pendingTurn))) {
    renderAIThread($('ai-chat-thread').querySelector('.ai-context-card .ai-ctx-fold')?.open);
  }
}

function renderNotePicker() {
  const query = $('ai-note-picker-search').value.trim().toLocaleLowerCase();
  const found = (state.noteIndex?.all ?? []).filter(note => !ai.pins.has(note.id) &&
    (!query || [note.body, note.reading?.bookTitle, note.reading?.chapter, note.reading?.author]
      .some(text => text?.toLocaleLowerCase().includes(query)))).slice(0, 40);
  const options = found.map(note => {
    const title = note.reading?.bookTitle ? note.reading.bookTitle + ' · ' : '';
    const button = el('button', 'ai-picker-option', title + note.body.trim().slice(0, 96));
    button.type = 'button';
    button.dataset.pickNoteId = note.id;
    return button;
  });
  $('ai-note-picker-results').replaceChildren(...(options.length ? options : [el('p', 'help-text', '没有匹配的笔记。')]));
}

function openNotePicker(query = '', atIndex = null) {
  toggleAIUtilityPicker('model', false);
  toggleAIUtilityPicker('effort', false);
  if (ai.pins.size >= 10) { setError('ai-chat-error', '最多引用 10 条笔记。'); return; }
  ai.atIndex = atIndex;
  $('ai-note-picker').hidden = false;
  syncAIScrollButton();
  $('ai-note-picker-search').value = query;
  renderNotePicker();
  $('ai-note-picker-search').focus({ preventScroll: true });
}

function pinFromPicker(id) {
  if (!state.notes.has(id) || ai.pins.size >= 10) return;
  ai.pins.add(id);
  if (ai.atIndex !== null) {
    const input = $('ai-chat-input');
    if (input.value[ai.atIndex] === '@') input.setRangeText('', ai.atIndex, ai.atIndex + 1, 'end');
  }
  refreshAIPins();
  closeNotePicker(true);
}

function rememberAIDraft() {
  ai.drafts.set(ai.draftKey, { text: $('ai-chat-input').value, pins: [...ai.pins].filter(id => state.notes.has(id)),
    useWritingStyle: ai.useWritingStyle, requestKey: ai.requestKey });
}

function restoreAIDraft(key) {
  ai.draftKey = key;
  const draft = ai.drafts.get(key);
  if (!draft) return;
  $('ai-chat-input').value = draft.text;
  ai.pins = new Set(draft.pins.filter(id => state.notes.has(id)));
  ai.useWritingStyle = draft.useWritingStyle;
  ai.requestKey = draft.requestKey;
}

function syncAIOverrides() {
  const model = activeModelMeta();
  const labels = [hasGatewayModels() && state.gatewayModel !== (state.preferredModel || state.defaultGatewayModel) && model?.label,
    model?.efforts.includes(state.reasoningEffort) && state.reasoningEffort !== state.defaultEffort && '思考：' + effortLabels[state.reasoningEffort],
    ai.useWritingStyle && '本轮使用写作风格'].filter(Boolean);
  $('ai-overrides').textContent = labels.join(' · ');
  $('ai-overrides').hidden = !labels.length;
}

function syncAIStyleToggle() {
  syncAIOverrides();
  const toggle = $('ai-style-toggle');
  const blocked = relayMode() && !ai.useWritingStyle;
  insPressed(toggle, ai.useWritingStyle);
  toggle.setAttribute('aria-disabled', String(blocked || Boolean(ai.sending)));
  toggle.title = relayMode() ? styleRelayMessage : '仅本轮使用写作风格';
  if (ai.lifecycle) {
    if (ai.useWritingStyle && relayMode()) setError('ai-chat-error', styleRelayMessage);
    else if ($('ai-chat-error').textContent === styleRelayMessage) setError('ai-chat-error', '');
  }
}

function toggleAIStyle() {
  if (ai.sending) return;
  if (ai.useWritingStyle) {
    ai.useWritingStyle = false;
    setError('ai-chat-error', '');
    syncAIStyleToggle();
    return;
  }
  if (relayMode()) { setError('ai-chat-error', styleRelayMessage); return; }
  ai.useWritingStyle = true;
  setError('ai-chat-error', '');
  syncAIStyleToggle();
}

function syncAIControls() {
  syncAIStyleToggle();
  const send = $('ai-chat-send');
  const stopping = Boolean(ai.sending || ins?.run);
  send.disabled = Boolean(ai.loadingSession || ai.sessionLoadFailed);
  aiButton('new-session').hidden = !(ai.session?.turns.length || ai.source || ai.pendingTurn || ins?.report || ins?.attempt);
  send.classList.toggle('ai-send-stopping', stopping);
  send.querySelector('span').textContent = stopping ? '停止' : '发送';
  send.setAttribute('aria-label', stopping ? '停止回复' : '发送');
}

function newAISession(source = null, session = null, { extraPinIds = [], fromWalk = false, draftKey = session?.id ?? source?.id ?? 'new' } = {}) {
  if (ai.sending || ins?.run) return false;
  rememberAIDraft();
  clearReport();
  ai.sessionLoadSeq++;
  ai.loadingSession = false;
  ai.sessionLoadFailed = false;
  ai.session = session;
  ai.selectedSessionId = session?.id ?? source?.id ?? null;
  ai.source = source;
  ai.fromWalk = fromWalk;
  ai.insightContext = null;
  ai.pendingTurn = null;
  ai.followBottom = true;
  ai.useWritingStyle = false;
  ai.pins = new Set([...new Set(source ? [source.id, ...extraPinIds] : [])].filter(id => state.notes.has(id)).slice(0, 10));
  ai.requestKey = null;
  $('ai-chat-input').value = '';
  restoreAIDraft(draftKey);
  syncAIComposerPlaceholder();
  setError('ai-chat-error', '');
  setAISessionRail(false);
  closeNotePicker();
  renderAIThread();
  renderAIPins();
  renderAISessions();
  syncAIControls();
  return true;
}

async function selectAISession(path, source = null, { preserveDraft = false, id = null } = {}) {
  const view = ai;
  if (view.sending) return false;
  const cached = id ? view.sessionCache.get(id) : null;
  if (cached) newAISession(state.notes.get(cached.sourceNoteId), cached);
  const seq = ++view.sessionLoadSeq;
  const isCurrent = () => ai === view && seq === view.sessionLoadSeq;
  const targetDraftKey = id ?? source?.id ?? 'new';
  if (!cached && !preserveDraft) {
    rememberAIDraft();
    clearReport();
    view.session = null;
    view.source = source;
    view.insightContext = null;
    view.pendingTurn = null;
    view.useWritingStyle = false;
    view.pins = new Set(source && state.notes.has(source.id) ? [source.id] : []);
    view.requestKey = null;
    $('ai-chat-input').value = '';
    restoreAIDraft(targetDraftKey);
    syncAIComposerPlaceholder();
  }
  view.selectedSessionId = id ?? source?.id ?? null;
  view.loadingSession = !cached;
  view.sessionLoadFailed = false;
  setAISessionRail(false);
  if (!cached) {
    setError('ai-chat-error', '');
    renderAIPins();
    renderAISessions();
    renderAIThread();
    syncAIControls();
  }
  try {
    const { session } = await request(path, undefined, view.lifecycle.signal);
    if (!isCurrent()) return false;
    if (session) storeAISession(view, session);
    view.loadingSession = false;
    view.sessionLoadFailed = false;
    if (cached && (!session || session.version <= (view.session?.version ?? 0) || view.sending)) return true;
    const note = source ?? state.notes.get(session?.sourceNoteId);
    const resolvedKey = session?.id ?? note?.id ?? targetDraftKey;
    if (preserveDraft || cached) {
      if (session && !cached) {
        if (!$('ai-chat-input').value) restoreAIDraft(session.id);
        else view.draftKey = session.id;
        renderAIPins();
      }
      view.session = session;
      view.selectedSessionId = session?.id ?? source?.id ?? null;
      renderAIThread();
      renderAISessions();
      syncAIControls();
    } else {
      const typedWhileLoading = $('ai-chat-input').value;
      view.session = session;
      view.selectedSessionId = session?.id ?? note?.id ?? null;
      view.source = note;
      view.pins = new Set([...view.pins, ...(note && state.notes.has(note.id) ? [note.id] : [])].slice(0, 10));
      if (!typedWhileLoading && resolvedKey !== targetDraftKey) {
        $('ai-chat-input').value = '';
        restoreAIDraft(resolvedKey);
      } else {
        view.draftKey = resolvedKey;
      }
      syncAIComposerPlaceholder();
      renderAIThread();
      renderAIPins();
      renderAISessions();
      syncAIControls();
      $('ai-chat-input').focus({ preventScroll: true });
    }
    return true;
  } catch (error) {
    if (isCurrent() && cached && error.status === 404) {
      view.sessionCache.delete(id);
      view.sessions.delete(id);
      if (!view.sending) newAISession();
    }
    if (isCurrent() && error.name !== 'AbortError' && !cached) {
      view.loadingSession = false;
      view.sessionLoadFailed = true;
      view.selectedSessionId = id ?? source?.id ?? null;
      renderAIThread();
      renderAISessions();
      setError('ai-chat-error', error.message);
    }
    return false;
  } finally {
    if (isCurrent()) {
      view.loadingSession = false;
      syncAIControls();
    }
  }
}

function aiSessionsForNote(id) {
  return '/api/ai/sessions?sourceNoteId=' + encodeURIComponent(id);
}

async function deleteAISession(id) {
  const view = ai;
  if (view.session?.id === id && view.sending) return;
  const source = view.sessions.get(id)?.sourceNoteId;
  const signal = view.lifecycle.signal;
  try {
    await request('/api/ai/sessions/' + id, undefined, signal, 'DELETE');
    if (ai !== view) return;
    view.sessions.delete(id);
    view.sessionCache.delete(id);
    view.drafts.delete(id);
    if (view.session?.id === id) newAISession();
    else renderAISessions();
    if (source) {
      const { session } = await request(aiSessionsForNote(source), undefined, signal);
      if (ai !== view) return;
      if (session) storeAISession(view, session);
      else if (![...view.sessions.values()].some(item => item.sourceNoteId === source)) view.upgradedNoteIds.delete(source);
      renderAISessions();
    }
  } catch (error) {
    if (ai === view && error.name !== 'AbortError') setError('ai-chat-error', error.message);
  }
}

async function sendAIChat(event) {
  event?.preventDefault();
  const view = ai;
  if (!view.lifecycle) return;
  if (ins?.run) { cancelInsRun(); return; }
  if (view.sending) {
    view.sending.abort();
    return;
  }
  if (view.loadingSession || view.sessionLoadFailed) return;
  const input = $('ai-chat-input');
  const draft = input.value;
  const message = draft.trim();
  if (!state.loaded || !message || view.loadingSession) return;
  if (view.useWritingStyle && relayMode()) { setError('ai-chat-error', styleRelayMessage); return; }
  const settings = providerSettings();
  if (settings.provider === 'openai' && !settings.apiKey) {
    setError('ai-chat-error', '请先在设置里填写 OpenAI API Key。');
    openSettings();
    showSettingsPane('ai');
    return;
  }
  const ctx = !view.session ? view.insightContext : null;
  const header = ctx ? `[洞察上下文：${ctx.title}（${ctx.lensName}）]\n` : '';
  const tail = ctx ? `\n\n[追问]\n${message}` : '';
  const payloadMessage = ctx ? header + ctx.content.slice(0, Math.max(0, 7900 - header.length - tail.length)) + tail : message;
  const body = {
    ...settings, message: payloadMessage, referencedNoteIds: [...view.pins],
    useAllNotes: true,
    ...(view.useWritingStyle ? { useWritingStyle: true } : {}),
    ...(gatewayMode() && activeModelMeta()?.efforts.includes(state.reasoningEffort)
      ? { reasoningEffort: state.reasoningEffort } : {}),
    ...(view.session ? { sessionId: view.session.id, expectedVersion: view.session.version } : {}),
    ...(!view.session && view.source ? { sourceNoteId: view.source.id } : {}),
  };
  const signature = JSON.stringify({ ...body, apiKey: undefined });
  if (view.requestKey?.signature !== signature) view.requestKey = { signature, id: randomUUID() };
  const controller = new AbortController();
  view.sending = controller;
  const signal = AbortSignal.any([view.lifecycle.signal, controller.signal]);
  view.followBottom = true;
  const pending = view.pendingTurn = {
    userText: message, status: '正在检索相关笔记…', streamText: '', citations: [], reasoning: '', steps: new Map(),
  };
  let frame;
  const paintPending = () => {
    frame = undefined;
    if (ai !== view || view.pendingTurn !== pending || signal.aborted) return;
    const bubble = $('ai-pending-reply');
    if (bubble) renderAIPendingBubble(bubble, pending);
    if (view.followBottom) $('ai-chat-thread').scrollTop = $('ai-chat-thread').scrollHeight;
    syncAIScrollButton();
  };
  input.value = '';
  syncAIControls();
  setError('ai-chat-error', '');
  renderAIThread();
  let completed = false;
  try {
    const saved = pendingProfileSave ? await pendingProfileSave : true;
    if (ai !== view) return;
    signal.throwIfAborted();
    if (!saved || failedProfileSave) {
      throw new Error('个人画像设置保存失败，已取消本次发送，请前往「个人画像」重试。');
    }
    if (body.useWritingStyle) {
      const styleSaved = pendingStyleSave ? await pendingStyleSave : true;
      if (ai !== view) return;
      signal.throwIfAborted();
      if (!styleSaved || failedStyleSave) throw new Error('写作风格保存失败，已取消本次发送，请前往「写作风格」重试。');
    }
    let streamError = null;
    await requestStream('/api/ai/chat', { ...body, stream: true, clientRequestId: view.requestKey.id }, {
      signal,
      onEvent(name, data) {
        if (ai !== view || signal.aborted) return;
        if (name === 'status') pending.status = data.message || '正在思考…';
        else if (name === 'step') {
          pending.steps.set(data.id, data);
          pending.stepsDirty = true;
        } else if (name === 'citations') pending.citations = data.citations;
        else if (name === 'reasoning' && typeof data.text === 'string') pending.reasoning += data.text;
        else if (name === 'delta' && typeof data.text === 'string') pending.streamText += data.text;
        else if (name === 'done' && data?.session) {
          completed = true;
          const previousTurns = view.session?.turns ?? view.source?.turns ?? [];
          const finalTurn = data.session.turns.at(-1);
          const bubble = $('ai-pending-reply');
          const keepReply = !data.deduplicated && bubble && pending.streamText.trim() === finalTurn?.text &&
            data.session.turns.length === previousTurns.length + 2;
          view.session = data.session;
          view.selectedSessionId = view.session.id;
          view.drafts.delete(view.draftKey);
          view.draftKey = view.session.id;
          view.insightContext = null;
          view.pendingTurn = null;
          storeAISession(view, view.session);
          view.requestKey = null;
          view.useWritingStyle = false;
          syncAIComposerPlaceholder();
          if (keepReply) {
            pending.steps = new Map((finalTurn.steps ?? []).map(step => [step.id, step]));
            pending.stepsDirty = true;
            renderAIPendingBubble(bubble, pending, true);
            bubble.classList.remove('ai-msg-pending');
            bubble.removeAttribute('id');
            bubble.append(makeLensMenu(finalTurn.text));
            $('ai-chat-title').textContent = view.session.title;
            if (view.followBottom) scrollAIThreadToBottom();
          } else renderAIThread();
          renderAISessions();
        } else if (name === 'error') {
          streamError = new Error(data?.error || '暂时无法回复，请稍后重试。');
        }
        if (!completed && frame === undefined) frame = requestAnimationFrame(paintPending);
      },
    });
    if (streamError) throw streamError;
    signal.throwIfAborted();
    if (!completed && ai === view) throw new Error('回复意外中断，请重试。');
  } catch (error) {
    if (ai !== view) return;
    view.pendingTurn = null;
    renderAIThread();
    if (!input.value.trim()) input.value = draft;
    if (error.name === 'AbortError' || signal.aborted) {
      view.requestKey = null;
      return;
    }
    if (error.status === 409) {
      if (error.current) {
        view.session = error.current;
        storeAISession(view, view.session);
      }
      else if (error.deleted) view.session = null;
      view.requestKey = null;
      renderAIThread();
    }
    setError('ai-chat-error', error.message);
  } finally {
    if (frame !== undefined) cancelAnimationFrame(frame);
    if (ai === view && view.sending === controller) {
      view.sending = null;
      if (!completed && view.pendingTurn) {
        view.pendingTurn = null;
        renderAIThread();
      }
      syncAIControls();
      const action = view.afterSend;
      view.afterSend = null;
      action?.();
    }
  }
}

async function openNoteAIChat(note, starter = null, { extraPinIds = [], fromWalk = false, useWritingStyle = false } = {}) {
  if (!note || state.detailWorking || !mayCloseNote()) return;
  if (useWritingStyle && relayMode()) { setError('detail-error', styleRelayMessage); return; }
  if ($('note-dialog').open) closeNote(true);
  if (!openAIChat()) return;
  const view = ai;
  newAISession(note, null, { extraPinIds, fromWalk });
  const input = $('ai-chat-input');
  input.focus({ preventScroll: true });
  const selected = await selectAISession(aiSessionsForNote(note.id), note, { preserveDraft: true });
  if (selected && ai === view && starter && !input.value) {
    view.useWritingStyle = useWritingStyle;
    syncAIStyleToggle();
    if (useWritingStyle && relayMode()) { setError('ai-chat-error', styleRelayMessage); return; }
    input.value = starter;
    sendAIChat();
  }
}

const insButton = action => document.querySelector('[data-action="ins-' + action + '"]');
const insRanges = { '7d': '近 7 天', week: '本周', month: '本月', all: '全部', custom: '自定义' };
let ins = null;

function insScope() {
  return {
    range: ins.range, tags: [...ins.tags], tzOffsetMinutes: new Date().getTimezoneOffset(),
    ...(ins.range === 'custom' ? { startDate: $('ins-start-date').value, endDate: $('ins-end-date').value } : {}),
  };
}

function insPressed(button, on) {
  button.setAttribute('aria-pressed', String(on));
}

function toggleInsTags(open, focus = false) {
  $('ins-tag-popover').hidden = !open;
  $('ins-tag-trigger').setAttribute('aria-expanded', String(open));
  if (focus) $(open ? 'ins-tag-search' : 'ins-tag-trigger').focus();
}

function renderInsControls() {
  const { report, attempt, run } = ins;
  $('ins-report-view').hidden = !(report || attempt);
  $('ins-report-actions').hidden = !report;
  insButton('retry').hidden = !attempt || Boolean(run || report);
  $('ins-range-select').value = ins.range;
  $('ins-custom-dates').hidden = ins.range !== 'custom';
  $('ins-tag-trigger').textContent = ins.tags.size ? `标签 · ${ins.tags.size}` : '全部标签';
  insButton('clear-tags').disabled = !ins.tags.size;
  syncAIControls();
}

function renderInsTags(query = '') {
  const tags = state.noteIndex?.tagNames ?? new Map();
  const search = query.trim().toLowerCase();
  const selected = [...ins.tags].map(key => [key, tags.get(key) ?? key]);
  const matches = [...tags].filter(([key]) => !ins.tags.has(key) && key.includes(search)).slice(0, 32);
  const buttons = [...selected, ...matches].map(([key, name]) => {
    const button = actionButton('#' + name, 'ins-toggle-tag');
    button.dataset.insTag = key;
    insPressed(button, ins.tags.has(key));
    return button;
  });
  $('ins-tag-list').replaceChildren(...buttons);
}

function renderInsLenses() {
  const featured = ins.lenses.filter(lens => lens.featured).slice(0, 5);
  $('ins-lens-grid').replaceChildren(...featured.map(lens => {
    const row = el('div', 'lens-row');
    const start = actionButton(lens.name, 'ins-run-lens');
    const range = actionButton(insRanges[ins.ranges.get(lens.id) || lens.suggestedRange || '7d'] + ' ›', 'ins-lens-range');
    start.dataset.id = range.dataset.id = lens.id;
    range.setAttribute('aria-label', lens.name + ' · ' + range.textContent);
    row.append(start, range);
    return row;
  }));
  $('ins-custom-list').replaceChildren(...ins.lenses.filter(lens => !lens.builtin).map(lens => {
    const row = el('div', 'lens-row');
    for (const [label, action] of [[lens.name, 'ins-run-lens'], ['范围', 'ins-lens-range'], ['编辑', 'ins-edit-lens'], ['删除', 'ins-delete-lens']]) {
      const button = actionButton(label, action);
      button.dataset.id = lens.id;
      row.append(button);
    }
    return row;
  }));
  renderInsControls();
}

function chooseLensRange(id) {
  const lens = ins.lenses.find(item => item.id === id);
  ins.lensId = id;
  ins.range = ins.ranges.get(id) || lens?.suggestedRange || '7d';
  const dates = ins.dates.get(id);
  $('ins-start-date').value = dates?.[0] || dayKey(new Date());
  $('ins-end-date').value = dates?.[1] || $('ins-start-date').value;
}

function finishLensScope() {
  const scope = insScope();
  if (scope.range === 'custom' && (!scope.startDate || !scope.endDate || scope.startDate > scope.endDate)) {
    setError('ins-scope-error', '请选择有效的起止日期。');
    return false;
  }
  setError('ins-scope-error', '');
  ins.ranges.set(ins.lensId, scope.range);
  if (scope.range === 'custom') ins.dates.set(ins.lensId, [scope.startDate, scope.endDate]);
  $('ins-scope').hidden = true;
  toggleInsTags(false);
  renderInsLenses();
  return true;
}

function makeLensMenu(text) {
  const menu = el('details', 'message-menu');
  const summary = el('summary', '', '···');
  summary.setAttribute('aria-label', '消息选项');
  const save = actionButton('存为视角', 'ins-save-message');
  save.dataset.prompt = text.slice(0, 4000);
  menu.append(summary, save);
  return menu;
}

function insCount(report) {
  const count = report.analyzedCount === report.noteCount
    ? `已分析 ${report.analyzedCount} 条笔记`
    : `已从 ${report.noteCount} 条中精选分析 ${report.analyzedCount} 条`;
  return count + (report.contentTruncated ? '（部分正文已裁剪）' : '');
}

function showInsReport(report) {
  ai.drafts.delete('insight:' + ins.attempt?.clientRequestId);
  ai.draftKey = 'report:' + report.id;
  ins.report = report;
  ins.attempt = null;
  $('ins-stream-status').textContent = '';
  setError('ins-report-error', '');
  $('ins-report-body').classList.remove('is-streaming');
  $('ins-rerun-model').value = state.gatewayModel ?? '';
  const { range, startDate, endDate, tags } = report.scope;
  const dates = range === 'custom' ? startDate + ' 至 ' + endDate : insRanges[range];
  $('ins-report-meta').textContent = [report.lensName, dates, report.model, ...(tags ?? []).map(tag => '#' + tag), insCount(report)].filter(Boolean).join(' · ');
  renderSafeMarkdown($('ins-report-body'), report.content, report.citations);
  $('ins-report-body').append(makeLensMenu(report.content));
  ai.insightContext = { title: report.title, lensName: report.lensName, content: report.content, citations: report.citations ?? [] };
  syncAIComposerPlaceholder();
  renderInsControls();
  renderAIThread();
  renderAISessions();
  $('ai-chat-thread').scrollTop = 0;
  $('ins-report-view').focus({ preventScroll: true });
}

async function loadInsLenses(view) {
  const revision = ++view.lensRevision;
  try {
    const result = await request('/api/insights/lenses', undefined, view.lifecycle.signal);
    if (ins !== view || revision !== view.lensRevision || view.lifecycle.signal.aborted) return;
    view.lensesLoaded = true;
    view.lenses = result.lenses;
    renderInsLenses();
  } catch (error) {
    if (ins === view && revision === view.lensRevision && !view.lifecycle.signal.aborted && error.name !== 'AbortError') setError('ins-view-error', error.message);
  }
}

async function loadInsReports(view) {
  const revision = ++view.historyRevision;
  try {
    const { reports } = await request('/api/insights/reports', undefined, view.lifecycle.signal);
    if (ins !== view || revision !== view.historyRevision || view.lifecycle.signal.aborted) return;
    view.reports = reports;
    renderAISessions();
  } catch (error) {
    if (ins === view && revision === view.historyRevision && !view.lifecycle.signal.aborted && error.name !== 'AbortError') setError('ins-view-error', error.message);
  }
}

function openInsights() {
  const view = ins = {
    lifecycle: ai.lifecycle, lenses: [], lensId: null, lensRevision: 0, lensesLoaded: false,
    tags: new Set(), ranges: new Map(), dates: new Map(), range: '7d', reports: [], historyRevision: 0,
    report: null, run: null, lensDraft: null, attempt: null,
  };
  $('ins-use-profile').checked = false;
  $('ins-tag-search').value = '';
  renderInsTags();
  renderInsLenses();
  loadInsLenses(view);
  loadInsReports(view);
}

function clearReport() {
  if (!ins) return;
  ins.run?.abort();
  ins.run = ins.report = ins.attempt = null;
  $('ins-report-body').replaceChildren();
  $('ins-scope').hidden = true;
  renderInsControls();
}

function closeInsights() {
  if (!ins) return;
  clearReport();
  ins = null;
  if ($('insight-lens-dialog').open) $('insight-lens-dialog').close();
  resetLensForm();
  $('ins-lens-grid').replaceChildren();
  $('ins-custom-list').replaceChildren();
  $('ins-tag-list').replaceChildren();
  $('ins-report-meta').textContent = $('ins-stream-status').textContent = '';
  for (const id of ['ins-view-error', 'ins-lens-error', 'ins-scope-error', 'ins-report-error']) setError(id, '');
}

function openInsLens(id, prompt = '') {
  const lens = ins.lenses.find(item => item.id === id);
  const dialog = $('insight-lens-dialog');
  ins.lensDraft = { id: lens?.id };
  $('ins-lens-title').textContent = lens ? '编辑自定义视角' : '新建自定义视角';
  $('ins-lens-name').value = lens?.name ?? '';
  $('ins-lens-desc').value = lens?.description ?? '';
  $('ins-lens-prompt').value = lens?.prompt ?? prompt;
  $('ins-lens-category').value = lens?.category ?? '';
  $('ins-lens-suggested').value = lens?.suggestedRange ?? '';
  setError('ins-lens-error', '');
  dialog.showModal();
}

async function saveInsLens(event) {
  event.preventDefault();
  const view = ins;
  const draft = view?.lensDraft;
  if (!draft || draft.saving) return;
  const submit = event.currentTarget.querySelector('button[type="submit"]');
  const category = $('ins-lens-category').value.trim();
  const body = {
    id: draft.id, name: $('ins-lens-name').value, description: $('ins-lens-desc').value,
    prompt: $('ins-lens-prompt').value, suggestedRange: $('ins-lens-suggested').value || null,
    ...(category ? { category } : {}),
  };
  submit.disabled = draft.saving = true;
  setError('ins-lens-error', '');
  try {
    const { lens } = await request('/api/insights/lenses', body, view.lifecycle.signal);
    if (ins !== view) return;
    view.lensRevision++;
    view.lenses = [lens, ...view.lenses.filter(item => item.id !== lens.id)];
    renderInsLenses();
    if (!view.lensesLoaded) loadInsLenses(view);
    if (view.lensDraft === draft) $('insight-lens-dialog').close();
  } catch (error) {
    if (ins === view && view.lensDraft === draft) setError('ins-lens-error', error.message);
  } finally {
    if (ins === view && view.lensDraft === draft) submit.disabled = false;
  }
}

async function deleteInsLens(id) {
  const view = ins;
  try {
    await request('/api/insights/lenses/' + id, undefined, view.lifecycle.signal, 'DELETE');
    if (ins !== view) return;
    view.lensRevision++;
    view.lenses = view.lenses.filter(lens => lens.id !== id);
    if (view.lensId === id) view.lensId = null;
    renderInsLenses();
    if (!view.lensesLoaded) loadInsLenses(view);
  } catch (error) {
    if (ins === view) setError(view.report ? 'ins-report-error' : 'ins-view-error', error.message);
  }
}

function runInsightReport(id) {
  const settings = providerSettings();
  if (settings.provider === 'openai' && !settings.apiKey) {
    setError('ins-view-error', '请先在设置里填写 OpenAI API Key。');
    openSettings();
    showSettingsPane('ai');
    return;
  }
  chooseLensRange(id);
  beginInsight({ ...settings, scope: insScope(), lensId: id, useProfile: $('ins-use-profile').checked });
}

function rerunInsightReport() {
  if (!ins.report || !hasGatewayModels()) return;
  const { lensId, scope, useProfile } = ins.report;
  beginInsight({ provider: 'codex', model: $('ins-rerun-model').value, lensId, scope, useProfile: useProfile ?? false });
}

function beginInsight(options) {
  const clientRequestId = randomUUID();
  if (newAISession(null, null, { draftKey: 'insight:' + clientRequestId })) startInsRun({ ...options, clientRequestId, stream: true });
}

async function startInsRun(body) {
  const view = ins;
  if (view.run) return;
  const controller = view.run = new AbortController();
  view.report = null;
  ai.insightContext = null;
  setUtilityMenu('ai-options', false);
  view.attempt = body;
  toggleInsTags(false);
  setError('ins-report-error', '');
  $('ins-report-meta').textContent = '';
  $('ins-stream-status').textContent = '正在准备…';
  const text = document.createTextNode('');
  $('ins-report-body').classList.add('is-streaming');
  $('ins-report-body').replaceChildren(text);
  renderInsControls();
  renderAIThread();
  $('ai-chat-thread').scrollTop = 0;
  $('ins-report-view').focus({ preventScroll: true });
  let report;
  let length = 0;
  try {
    await requestStream('/api/insights/run', body, { signal: controller.signal, onEvent(event, data) {
      if (event === 'status') {
        $('ins-stream-status').textContent = data.stage === 'selecting' ? '正在筛选笔记…' : '正在生成…';
      } else if (event === 'delta') {
        text.appendData(data.text);
        length += data.text.length;
        $('ins-stream-status').textContent = `正在生成 · ${length} 字`;
      } else if (event === 'done') {
        report = data.report;
      } else if (event === 'error') {
        throw new ApiError(data.status, data);
      }
    } });
    if (!report) throw new Error('报告还未生成完毕，连接已断开。');
    if (ins !== view || controller.signal.aborted) return;
    view.historyRevision++;
    view.reports = [report, ...view.reports.filter(item => item.id !== report.id)].slice(0, 50);
    renderAISessions();
    showInsReport(report);
  } catch (error) {
    if (ins === view && !controller.signal.aborted && error.name !== 'AbortError') {
      $('ins-stream-status').textContent = '生成失败';
      setError('ins-report-error', error.message);
    }
  } finally {
    if (ins === view && view.run === controller) {
      view.run = null;
      renderInsControls();
    }
  }
}

function cancelInsRun() {
  ins.run?.abort();
  ins.run = null;
  $('ins-stream-status').textContent = '已停止生成';
  renderInsControls();
}

async function openInsReport(id) {
  if (!newAISession(null, null, { draftKey: 'report:' + id })) return;
  const view = ins;
  const seq = ai.sessionLoadSeq;
  const isCurrent = () => view === ins && seq === ai.sessionLoadSeq;
  ai.loadingSession = true;
  renderAIThread();
  syncAIControls();
  try {
    const { report } = await request('/api/insights/reports/' + id, undefined, view.lifecycle.signal);
    if (isCurrent()) {
      ai.loadingSession = false;
      showInsReport(report);
    }
  } catch (error) {
    if (isCurrent() && error.name !== 'AbortError') setError('ins-view-error', error.message);
  } finally {
    if (isCurrent() && ai.loadingSession) {
      ai.loadingSession = false;
      renderAIThread();
      syncAIControls();
    }
  }
}

async function deleteInsReport(id) {
  const view = ins;
  try {
    await request('/api/insights/reports/' + id, undefined, view.lifecycle.signal, 'DELETE');
    if (ins !== view) return;
    view.historyRevision++;
    view.reports = view.reports.filter(report => report.id !== id);
    if (view.report?.id === id) newAISession();
    renderAISessions();
  } catch (error) {
    if (ins === view) setError(view.report ? 'ins-report-error' : 'ins-view-error', error.message);
  }
}

function resetLensForm() {
  if (ins) ins.lensDraft = null;
  $('ins-lens-form').reset();
  $('ins-lens-form').querySelector('button[type="submit"]').disabled = false;
}

$('ins-lens-form').addEventListener('submit', saveInsLens);
$('insight-lens-dialog').addEventListener('close', () => {
  if (!$('insight-lens-dialog').open) resetLensForm();
});
for (const id of ['profile-model-select', 'style-model-select']) $(id).addEventListener('change', event => {
  setGatewayModel(event.target.value);
});
for (const kind of ['model', 'effort']) {
  const popover = $('ai-' + kind + '-popover');
  const picker = $('ai-' + kind + '-picker');
  $('ai-' + kind + '-toggle').addEventListener('click', () => toggleAIUtilityPicker(kind, popover.hidden));
  document.addEventListener('pointerdown', event => {
    if (!popover.hidden && !picker.contains(event.target)) toggleAIUtilityPicker(kind, false);
  });
  picker.addEventListener('keydown', event => {
    if (popover.hidden || event.isComposing) return;
    if (event.key === 'Escape') {
      event.preventDefault();
      event.stopPropagation();
      toggleAIUtilityPicker(kind, false, true);
    } else if (event.key === 'ArrowDown' || event.key === 'ArrowUp' || (event.key === 'Enter' && event.target.id === 'ai-model-search')) {
      const options = [...popover.querySelectorAll('button')];
      if (!options.length) return;
      event.preventDefault();
      const index = options.indexOf(event.target);
      if (event.key === 'Enter') (options.find(option => option.getAttribute('aria-pressed') === 'true') ?? options[0]).click();
      else if (event.key === 'ArrowDown') options[(index + 1) % options.length].focus();
      else options[index <= 0 ? options.length - 1 : index - 1].focus();
    }
  });
}
$('ai-model-search').addEventListener('input', renderModelOptions);
$('ins-range-select').addEventListener('change', event => {
  ins.range = event.target.value;
  renderInsControls();
});
$('ins-tag-search').addEventListener('input', event => { if (ins) renderInsTags(event.target.value); });

$('ai-chat-form').addEventListener('submit', sendAIChat);
$('profile-enabled').addEventListener('change', () => saveProfile(true));
$('style-range').addEventListener('change', renderWritingStyle);
$('style-text').addEventListener('input', updateStyleCount);
$('style-tags-search').addEventListener('input', renderStyleTags);
$('style-anchor-search').addEventListener('input', renderStyleAnchorPicker);
$('ai-chat-thread').addEventListener('scroll', () => {
  ai.followBottom = isAIThreadAtBottom();
  syncAIScrollButton();
}, { passive: true });
$('ai-note-picker-search').addEventListener('input', renderNotePicker);
$('ai-chat-input').addEventListener('input', event => {
  const input = event.target;
  const index = input.selectionStart - 1;
  if (!event.isComposing && event.data === '@' && input.value[index] === '@') openNotePicker('', index);
});
async function logoutAccount() {
  const oauth = state.authMode === 'oauth';
  const account = state.user?.id;
  if (!account || state.authSuspended) return;
  await invalidateAccount({ notice: false });
  if (!oauth) {
    window.top.location.href = $('sign-out').getAttribute('href');
    return;
  }
  try {
    const response = await fetch('/api/auth/logout', {
      method: 'POST', credentials: 'same-origin', headers: { Accept: 'application/json', 'X-Journal-Account': account },
    });
    if (!response.ok && response.status !== 401) throw new Error('退出未完成，请重新打开页面后重试。');
    location.replace('/');
  } catch (error) {
    showSyncSkeleton(false);
    setAuthNotice(error.message);
  }
}
function onLogoutClick(event) {
  event.preventDefault();
  void logoutAccount();
}
$('sign-out').addEventListener('click', onLogoutClick);
$('sign-out').addEventListener('auxclick', event => { if (event.button === 1) onLogoutClick(event); });
$('sign-out').addEventListener('contextmenu', event => event.preventDefault());

function toggleSearch(force = false) {
  sidebar(false);
  const open = force || $('search-field').hidden;
  $('search-field').hidden = !open;
  document.querySelectorAll('[data-action="toggle-search"]').forEach(button => button.setAttribute('aria-expanded', String(open)));
  if (open) $('search').focus({ preventScroll: true });
}

function setDayFilter(day) {
  state.dayFilter = day || null;
  sidebar(false);
  renderFeedList({ reset: true });
}

const actions = {
  'open-notes': () => switchAI(showNotes),
  'open-sidebar': button => sidebar(true, button),
  'close-sidebar': () => sidebar(false),
  'toggle-stats': button => {
    const open = $('heatmap').hidden;
    $('heatmap').hidden = !open;
    $('mini-pulse').hidden = open;
    $('stats-chevron').textContent = open ? '▴' : '▾';
    button.setAttribute('aria-expanded', String(open));
  },
  'toggle-search': () => toggleSearch(),
  'retry-sync': () => refresh(),
  'clear-day': () => setDayFilter(null),
  'ins-tag-popover': () => toggleInsTags($('ins-tag-popover').hidden, true),
  'ins-lens-range': button => {
    const id = button.dataset.id;
    if (!$('ins-scope').hidden && !finishLensScope()) return;
    chooseLensRange(id);
    setUtilityMenu('ai-options', false);
    $('ins-scope').hidden = false;
    renderInsControls();
    $('ins-range-select').focus();
  },
  'ins-close-scope': finishLensScope,
  'ins-rerun': () => switchAI(rerunInsightReport),
  'ins-retry': () => switchAI(() => startInsRun(ins.attempt)),
  'ins-toggle-tag': button => {
    const tag = button.dataset.insTag;
    if (ins.tags.has(tag)) ins.tags.delete(tag);
    else if (ins.tags.size < 20) ins.tags.add(tag);
    else { setError('ins-scope-error', '最多选择 20 个标签。'); return; }
    insPressed(button, ins.tags.has(tag));
    renderInsControls();
  },
  'ins-clear-tags': () => { ins.tags.clear(); renderInsTags($('ins-tag-search').value); renderInsControls(); },
  'ins-new-lens': () => openInsLens(),
  'ins-edit-lens': button => openInsLens(button.dataset.id),
  'ins-save-message': button => openInsLens(null, button.dataset.prompt),
  'ins-close-lens': () => $('insight-lens-dialog').close(),
  'ins-delete-lens': button => { if (confirm('删除这个视角？')) deleteInsLens(button.dataset.id); },
  'ins-custom-lenses': button => {
    const open = $('ins-custom-list').hidden;
    $('ins-custom-list').hidden = !open;
    button.setAttribute('aria-expanded', String(open));
  },
  'ins-run-lens': button => switchAI(() => {
    if ($('ins-scope').hidden || finishLensScope()) runInsightReport(button.dataset.id);
  }),
  'ins-open-report': button => switchAI(() => openInsReport(button.dataset.id)),
  'ins-copy-report': () => { if (ins.report) copyText(ins.report.content); },
  'ins-delete-report': button => {
    const id = button.dataset.id ?? ins.report?.id;
    if (id && confirm('删除这份报告？')) deleteInsReport(id);
  },
  'open-random-walk': () => shuffleReader(true),
  'reader-shuffle': () => shuffleReader(),
  'reader-back': readerBack,
  'reader-options': () => setUtilityMenu('reader-options', $('reader-options').hidden),
  'copy-note': () => {
    const note = state.notes.get(state.noteID);
    if (!note) return;
    setUtilityMenu('reader-options', false, true);
    void copyText(note.body, $('note-dialog'));
  },
  'undo-delete': restoreDeletedNote,
  'merge-edit': () => {
    const input = $('edit-body');
    const remote = $('edit-remote').textContent;
    if (input.value.trim() !== remote.trim()) input.value = remote + '\n\n' + input.value;
    $('edit-conflict').hidden = true;
    input.focus();
  },
  'open-ai-chat': openAIChat,
  'ai-options': () => setUtilityMenu('ai-options', $('ai-options').hidden),
  'ai-toggle-sessions': button => {
    setUtilityMenu('ai-options', false);
    setAISessionRail(true, button);
  },
  'ai-close-history': () => setAISessionRail(false),
  'ai-load-more-sessions': () => loadAISessions(true),
  'open-note-ai-chat': () => switchAI(() => openNoteAIChat(state.notes.get(state.noteID), null, {
    extraPinIds: reader.random ? reader.related.map(item => item.id) : [], fromWalk: reader.random,
  })),
  'note-ai-starter': button => switchAI(() => openNoteAIChat(state.notes.get(state.noteID), button.dataset.prompt, { useWritingStyle: button.dataset.useStyle === 'true' })),
  'ai-style-toggle': toggleAIStyle,
  'ai-select-legacy-note': button => switchAI(() => openNoteAIChat(state.notes.get(button.dataset.id))),
  'ai-new-session': () => switchAI(() => { if (newAISession()) $('ai-chat-input').focus({ preventScroll: true }); }),
  'ai-select-session': button => switchAI(() => selectAISession('/api/ai/sessions/' + button.dataset.id, null, { id: button.dataset.id })),
  'ai-delete-session': button => { if (confirm('删除这段对话？')) deleteAISession(button.dataset.id); },
  'profile-clear': () => { if (confirm('清空个人画像？')) saveProfile(false, true); },
  'profile-reload': () => loadProfile(prof),
  'profile-generate': generateProfile,
  'profile-edit': () => setProfileEditing(true),
  'profile-cancel-edit': () => setProfileEditing(false),
  'profile-save': () => saveProfile(),
  'profile-pane': button => setProfilePane(button.dataset.pane),
  'style-reload': () => loadWritingStyle(writingStyleView),
  'style-edit': () => editStyleRules(true),
  'style-cancel-edit': () => editStyleRules(false),
  'style-save': () => saveStyle({ rules: $('style-text').value }),
  'style-generate': generateWritingStyle,
  'style-tags': () => toggleStylePicker('tags', $('style-tags-picker').hidden),
  'style-tag': button => {
    const { tags } = writingStyleView;
    if (!tags.delete(button.dataset.tag)) {
      if (tags.size >= 20) { setError('style-error', '最多选择 20 个标签。'); return; }
      tags.add(button.dataset.tag);
    }
    renderStyleTags();
    [...$('style-tag-list').children].find(item => item.dataset.tag === button.dataset.tag)?.focus();
  },
  'style-anchor-picker': () => toggleStylePicker('anchor', $('style-anchor-picker').hidden),
  'style-add-anchor': button => saveStyle({ anchorNoteIds: [...activeStyleAnchorIds(writingStyleView), button.dataset.id] }),
  'style-remove-anchor': button => saveStyle({ anchorNoteIds: activeStyleAnchorIds(writingStyleView).filter(id => id !== button.dataset.id) }),
  'style-adopt': () => {
    const view = writingStyleView;
    saveStyle({ anchorNoteIds: [...activeStyleAnchorIds(view), ...styleSuggestions(view).map(anchor => anchor.id)] });
  },
  'style-blind': startStyleBlindTest,
  'style-vote': button => revealStyleVote(button.dataset.slot),
  'ai-pick-note': () => $('ai-note-picker').hidden ? openNotePicker() : closeNotePicker(true),
  'ai-scroll-bottom': () => scrollAIThreadToBottom(true),
  'open-import-hub': () => {
    if (!state.loaded || !state.user?.id) { notify('请先登录并完成同步'); return; }
    $('import-hub-dialog').showModal();
  },
  'open-import': openImport,
  'open-flomo-import': () => openFileImport('flomo'),
  'open-joplin-import': () => openFileImport('joplin'),
  'pick-joplin-dir': () => $('joplin-dir').click(),
  'open-settings': () => { sidebar(false); setUtilityMenu('ai-options', false); openSettings(); },
  'settings-pane': button => showSettingsPane(button.dataset.pane, button),
  'semantic-status': () => loadSemanticStatus(),
  'semantic-reindex': () => loadSemanticStatus(true),
  'focus-compose': focusCompose,
  'clear-search': () => { clearSearchInput(); renderFeedList({ reset: true }); },
  'clear-filters': () => {
    state.dayFilter = null;
    state.filter = 'all';
    clearSearchInput();
    renderFeedList({ reset: true });
  },
  'toggle-tag-sort': () => {
    state.tagSort = state.tagSort === 'count' ? 'alpha' : 'count';
    if (state.noteIndex) sortTagTree(state.noteIndex.tagTree, state.tagSort);
    renderTagList();
  },
  'toggle-sort': () => {
    state.sortOrder = state.sortOrder === 'newest' ? 'oldest' : 'newest';
    renderFeedList({ reset: true });
  },
  'load-more': () => appendNextPage(),
  'edit-note': () => toggleEdit(true),
  'delete-note': () => {
    setUtilityMenu('reader-options', false);
    $('delete-confirm').hidden = false;
    $('delete-confirm').scrollIntoView({ block: 'nearest' });
    $('delete-confirm').querySelector('button').focus();
  },
  'cancel-delete': () => { $('delete-confirm').hidden = true; },
  'confirm-delete': deleteNote,
  'pick-file': () => $('import-file').click(),
  'import-back': () => { if (!state.importWorking) { importMode(null); setError('import-error', ''); } },
  'weread-mode-official': () => setWereadMode(false),
  'weread-mode-manual': () => setWereadMode(true),
  'weread-more': () => loadWereadBooks(true),
  'weread-batch-save': saveSelectedWereadBooks,
  'weread-book': previewWereadBook,
  'weread-back': backToWereadBooks,
  'weread-save': saveWereadNotes,
  'flomo-back': () => { if (!state.flomoWorking) resetFileImport('flomo'); },
  'joplin-back': () => { if (!state.joplinWorking) resetFileImport('joplin'); },
};

document.addEventListener('click', (event) => {
  if (!event.target.closest) return;
  for (const id of ['sidebar', 'ai-session-rail']) {
    const drawer = $(id);
    if (event.target === drawer && drawer.open) {
      const bounds = drawer.getBoundingClientRect();
      if (event.clientX < bounds.left || event.clientX > bounds.right || event.clientY < bounds.top || event.clientY > bounds.bottom) setDrawer(id, false);
      return;
    }
  }
  for (const id of ['ai-options', 'reader-options']) {
    if (!$(id).hidden && !event.target.closest(`#${id}, [data-action="${id}"]`)) setUtilityMenu(id, false);
  }
  if (ins && !$('ins-tag-popover').hidden && !event.target.closest('.ins-tags')) toggleInsTags(false);
  if (state.tagSuggest.open && !event.target.closest('.composer-input-wrap')) closeTagSuggest();
  const button = event.target.closest('button');
  if (!button) {
    const note = event.target.closest('#note-list .note-card');
    if (note && !event.target.closest('a') && window.getSelection()?.isCollapsed) openNote(note.dataset.noteId);
    return;
  }
  if (button.disabled) return;
  if (button.dataset.citeNoteId) {
    if (!openNote(button.dataset.citeNoteId)) {
      if (!state.notes.has(button.dataset.citeNoteId)) notify('这条笔记已不可用');
    }
    return;
  }
  if (button.dataset.removePin) {
    ai.pins.delete(button.dataset.removePin);
    refreshAIPins();
    return;
  }
  if (button.dataset.pickNoteId) {
    pinFromPicker(button.dataset.pickNoteId);
    return;
  }
  if (button.dataset.suggestIndex !== undefined) {
    applyTagSuggest(Number(button.dataset.suggestIndex));
    return;
  }
  if (button.dataset.toggleTag) {
    const path = button.dataset.toggleTag;
    if (state.collapsedTags.has(path)) state.collapsedTags.delete(path);
    else state.collapsedTags.add(path);
    renderTagList();
    return;
  }
  if (button.dataset.day) {
    setDayFilter(state.dayFilter === button.dataset.day ? null : button.dataset.day);
    return;
  }
  if (button.dataset.close) {
    if (button.dataset.close === 'import-hub-dialog') $('import-hub-dialog').close();
    if (button.dataset.close === 'settings-dialog') $('settings-dialog').close();
    if (button.dataset.close === 'import-dialog' && !state.importWorking && !state.wereadImport?.saving) $('import-dialog').close();
    if (button.dataset.close === 'flomo-dialog' && !state.flomoWorking) $('flomo-dialog').close();
    if (button.dataset.close === 'joplin-dialog' && !state.joplinWorking) $('joplin-dialog').close();
  }
  if (button.dataset.action && actions[button.dataset.action]) actions[button.dataset.action](button);
  if (button.dataset.openNote) openNote(button.dataset.openNote);
  if (button.dataset.filter) {
    if ($('note-dialog').open) closeNote(true);
    if (ai.visible) { switchAI(() => applyFilter(button.dataset.filter)); return; }
    applyFilter(button.dataset.filter);
  }
});

function applyFilter(filter) {
  showNotes();
  sidebar(false);
  state.filter = filter;
  renderFeedList({ reset: true });
  window.scrollTo(0, 0);
}

for (const id of ['sidebar', 'ai-session-rail']) {
  $(id).addEventListener('cancel', event => { event.preventDefault(); setDrawer(id, false); });
}
$('date-filter').addEventListener('change', event => setDayFilter(event.target.value));
$('settings-default-model').addEventListener('change', syncSettingsEffort);

$('tag-suggest').addEventListener('mousedown', (event) => {
  event.preventDefault();
});

$('note-dialog').addEventListener('cancel', event => {
  event.preventDefault();
  if (!$('reader-options').hidden) setUtilityMenu('reader-options', false, true);
  else if (!$('delete-confirm').hidden) $('delete-confirm').hidden = true;
  else readerBack();
});
$('import-dialog').addEventListener('cancel', (event) => {
  if (state.importWorking || state.wereadImport?.saving) event.preventDefault();
});
$('import-dialog').addEventListener('close', resetWereadImport);
for (const kind of ['flomo', 'joplin']) {
  $(`${kind}-dialog`).addEventListener('cancel', event => { if (state[kind + 'Working']) event.preventDefault(); });
  $(`${kind}-dialog`).addEventListener('close', () => {
    if (!$(`${kind}-dialog`).open) resetFileImport(kind, true);
  });
  $(`${kind}-form`).addEventListener('submit', event => importFileNotes(event, kind));
}
$('joplin-file').addEventListener('change', () => {
  if (!$('joplin-file').files.length) return;
  $('joplin-dir').value = '';
  setError('joplin-dir-status', '');
});
$('joplin-dir').addEventListener('change', () => {
  const files = $('joplin-dir').files;
  if (files.length) $('joplin-file').value = '';
  const root = files[0]?.webkitRelativePath.split('/')[0];
  setError('joplin-dir-status', root ? '已选择：' + root : '');
});
$('settings-dialog').addEventListener('close', () => {
  if ($('settings-dialog').open) return;
  cleanupSettings();
});
$('settings-form').addEventListener('submit', saveSettings);
$('chat-provider').addEventListener('change', updateAISettings);
$('import-form').addEventListener('submit', importNotes);
$('weread-connect').addEventListener('submit', (event) => { event.preventDefault(); loadWereadBooks(); });
$('weread-select-all').addEventListener('change', (event) => {
  const session = state.wereadImport;
  if (!session || session.controller || session.saving) return;
  session.selected = event.target.checked ? new Set(session.books.map((book) => book.id)) : new Set();
  for (const box of $('weread-book-list').querySelectorAll('.weread-book-check')) box.checked = event.target.checked;
  updateWereadBatchControls(session);
});
$('weread-book-list').addEventListener('change', (event) => {
  const box = event.target.closest('.weread-book-check');
  const session = state.wereadImport;
  if (!box || !session || session.controller || session.saving) return;
  if (box.checked) session.selected.add(box.dataset.bookSelect);
  else session.selected.delete(box.dataset.bookSelect);
  updateWereadBatchControls(session);
});
$('weread-key').addEventListener('input', () => {
  const session = state.wereadImport;
  if (!session?.queried) return;
  session.queried = false;
  session.books = [];
  session.selected.clear();
  session.nextCursor = null;
  renderWereadBooks();
  setError('weread-error', '');
});
$('import-file').addEventListener('change', pickImportFile);
$('edit-form').addEventListener('submit', submitEdit);
$('composer').addEventListener('submit', createNote);
$('note-body').addEventListener('input', syncComposerUI);
$('note-body').addEventListener('click', () => {
  suppressNextTagSuggestKeyup = false;
  updateTagSuggest();
});
$('note-body').addEventListener('keyup', (event) => {
  if (event.isComposing || event.keyCode === 229) return;
  if (suppressNextTagSuggestKeyup) {
    suppressNextTagSuggestKeyup = false;
    return;
  }
  updateTagSuggest();
});
$('note-body').addEventListener('blur', () => {
  suppressNextTagSuggestKeyup = false;
  closeTagSuggest();
});
$('search').addEventListener('input', () => {
  clearTimeout(searchTimer);
  searchTimer = null;
  if (!$('search').value.trim()) {
    renderFeedList({ reset: true });
    return;
  }
  searchTimer = setTimeout(() => {
    searchTimer = null;
    renderFeedList({ reset: true });
  }, 150);
});
$('note-body').addEventListener('focus', syncComposerUI);
$('note-body').addEventListener('blur', () => {
  const input = $('note-body');
  if (!input.value) input.style.height = '';
});

document.addEventListener('keydown', event => {
  if (event.isComposing || event.keyCode === 229) return;
  if (event.key === 'Escape') {
    if (document.querySelector('dialog[open]')) return;
    if (!$('ai-options').hidden) setUtilityMenu('ai-options', false, true);
    else if (!$('ai-note-picker').hidden) closeNotePicker(true);
    else if (state.tagSuggest.open) {
      suppressNextTagSuggestKeyup = true;
      closeTagSuggest();
    } else if (ai.visible) switchAI(showNotes);
    else if (!$('search-field').hidden) toggleSearch();
    return;
  }
  if (event.target.id === 'ai-chat-input' && event.key === 'Enter' && (event.metaKey || event.ctrlKey)) {
    event.preventDefault();
    $('ai-chat-form').requestSubmit();
    return;
  }
  if (event.target.id === 'note-body' && state.tagSuggest.open) {
    if (event.key === 'ArrowDown' || event.key === 'ArrowUp') {
      event.preventDefault();
      suppressNextTagSuggestKeyup = true;
      moveTagSuggest(event.key === 'ArrowDown' ? 1 : -1);
      return;
    }
    if (event.key === 'Enter' || event.key === 'Tab') {
      event.preventDefault();
      suppressNextTagSuggestKeyup = true;
      applyTagSuggest(state.tagSuggest.activeIndex);
      return;
    }
  }
  if ((event.ctrlKey || event.metaKey) && event.key.toLowerCase() === 'k' && !document.querySelector('dialog[open]')) {
    event.preventDefault();
    if (ai.visible) switchAI(() => { showNotes(); toggleSearch(true); });
    else toggleSearch(true);
  }
  if ((event.ctrlKey || event.metaKey) && event.key === '/' && !document.querySelector('dialog[open]')) {
    event.preventDefault();
    focusCompose();
  }
  if ((event.ctrlKey || event.metaKey || event.shiftKey) && event.key === 'Enter' && event.target.id === 'note-body') {
    event.preventDefault();
    if (!$('save-note').disabled) $('composer').requestSubmit();
  }
});

window.addEventListener('focus', () => refresh({ silent: true }));
let pageHidden = false;
let suspendedComposeDraft = null;
window.addEventListener('storage', event => {
  if (event.key !== weijiAuthEvent || !event.newValue) return;
  if (!authEventRevokesAccount(event.newValue)) {
    pageAuthStamp = event.newValue;
    return;
  }
  pageHidden = false;
  suspendedComposeDraft = null;
  void invalidateAccount({ broadcast: false });
});
window.addEventListener('pagehide', () => {
  pageHidden = !state.authSuspended;
  if (state.user?.id && $('note-body').value) {
    suspendedComposeDraft = { userId: state.user.id, text: $('note-body').value };
  }
  state.authSuspended = true;
  resetAccount();
});
window.addEventListener('pageshow', event => {
  if (!event.persisted || !pageHidden) return;
  if (!syncAuthStampIfCompatible(pageUserId)) {
    suspendedComposeDraft = null;
    void invalidateAccount({ broadcast: false });
    return;
  }
  state.authSuspended = false;
  void refresh();
});
document.addEventListener('visibilitychange', () => { if (!document.hidden) refresh({ silent: true }); });
setInterval(() => { if (!document.hidden) refresh({ silent: true }); }, 15000);
refresh();
rebuildNoteIndex();
renderFeedList({ reset: true });
