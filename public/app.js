import { parseWeRead, readWeReadFile } from './weread.js';
import { parseFlomoFile } from './flomo.js';
import { randomUUID } from './crypto.js';
import { tagsFor, buildTagTree, tokenizeBody, appendCitedText, renderSafeMarkdown, updateStreamingMarkdown,
  clearWeijiCacheDB, notesCacheTransaction, publishWeijiAuthEvent, weijiAuthEvent } from './ux-helpers.js';

const $ = (id) => document.getElementById(id);
const SVG_NS = 'http://www.w3.org/2000/svg';
const excerptsMarker = '\n\nAI 摘录\n';
const FEED_PAGE_SIZE = 40;
const pageUserId = document.querySelector('meta[name="weiji-user-id"]')?.content || null;
function authEventStamp() {
  try { return localStorage.getItem(weijiAuthEvent); } catch { return null; }
}
let pageAuthStamp = authEventStamp();
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
  bookFilter: null,
  sortOrder: 'newest',
  feedItems: [],
  feedRendered: 0,
  inlineEdit: null,
  orphanDrafts: new Map(),
  inlineDeleteId: null,
  openMenuId: null,
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

const filters = { all: '全部笔记', journal: '日志', reading: '读书摘录' };
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
  if (node.dataset.status === status && node.textContent === message) return;
  node.dataset.status = status;
  node.replaceChildren(el('span'), message);
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
  if (pageAuthStamp !== authEventStamp()) {
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
  const label = name || email || '我的空间';
  $('profile-name').textContent = label;
  const oauth = state.authMode === 'oauth';
  $('profile-caption').textContent = email || (state.user ? oauth ? '微记账号' : 'ChatGPT 账号' : '未登录');
  $('avatar').textContent = state.user ? (Array.from(label)[0] || '微').toUpperCase() : '微';
  $('sign-out').hidden = !state.user;
  $('settings-account').textContent = email ? '已登录 · ' + email : oauth ? label : state.user ? '已使用 ChatGPT 账号登录。' : '请先使用 ChatGPT 账号登录。';
  $('settings-sync-help').textContent = oauth ? '在 iOS 微记里用同一账号登录，即可同步笔记及对话。' : '在 iOS 微记里使用同一 ChatGPT 账号登录，即可同步笔记及对话。';
}

let accountLifecycle = new AbortController();
let pendingProfileSave = null;
let failedProfileSave = null;
function resetAccount() {
  state.syncEpoch++;
  accountLifecycle.abort();
  accountLifecycle = new AbortController();
  pendingProfileSave = null;
  failedProfileSave = null;
  closeProfile({ restore: false });
  closeInsights({ restore: false });
  closeAIChat({ restore: false });
  ai = emptyAIState();
  closeRandomWalk({ restore: false });
  state.user = null;
  state.authMode = null;
  state.loaded = false;
  state.notesETag = null;
  state.refreshing = false;
  $('refresh-button').disabled = false;
  showSyncSkeleton(true);
  state.notes.clear();
  state.deletedNotes.clear();
  state.noteIndex = null;
  state.dayFilter = null;
  state.bookFilter = null;
  state.inlineEdit = null;
  state.orphanDrafts.clear();
  renderOrphanDraft();
  state.inlineDeleteId = null;
  state.openMenuId = null;
  closeTagSuggest();
  state.apiKey = '';
  state.chatProvider = 'openai';
  state.codexAvailable = false;
  state.codexMode = null;
  gatewayModelsRevision++;
  state.gatewayModels = [];
  state.gatewayModelMeta = [];
  state.defaultGatewayModel = null;
  state.reasoningEffort = '';
  state.gatewayModel = null;
  renderGatewayModels();
  state.composeDraft = null;
  $('note-body').value = '';
  clearSearchInput();
  $('edit-body').value = '';
  $('import-text').value = '';
  importMode(null);
  resetWereadImport();
  resetFlomoImport(true);
  for (const id of ['settings-dialog', 'import-dialog', 'flomo-dialog']) if ($(id).open) $(id).close();
  if ($('note-dialog').open) closeNote(true);
  $('detail-body').replaceChildren();
  $('detail-meta').replaceChildren();
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

async function invalidateAccount({ reload = false, broadcast = true, notice = true } = {}) {
  const account = state.user?.id ?? pageUserId;
  const oauth = state.authMode === 'oauth';
  suspendedComposeDraft = null;
  state.authSuspended = true;
  resetAccount();
  const epoch = state.syncEpoch;
  if (broadcast) {
    publishWeijiAuthEvent(window, { type: 'logout', ...(account ? { userId: account } : {}) });
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
  return notesCacheTransaction('readwrite', store => store.put(snapshot), () => epoch === state.syncEpoch && pageAuthStamp === authEventStamp())
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
  reconcileInlineEditState();
  if (changed || firstLoad) {
    rebuildNoteIndex();
    renderFeedList({ reset: true, preservePage: true });
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
  $('refresh-button').disabled = true;
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
        await invalidateAccount({ reload: Boolean(result.user?.id) });
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
    setSync('error', '同步未完成');
  } finally {
    if (isCurrent()) {
      state.refreshing = false;
      $('refresh-button').disabled = false;
    }
  }
}

function showRemoteDetail() {
  const note = state.notes.get(state.noteID);
  if (!note) {
    setError('detail-error', '这条笔记已在另一端删除。你可以复制尚未保存的内容再关闭。');
    $('detail-actions').hidden = true;
    $('note-dialog').querySelector('.note-ai-entry').hidden = true;
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
    reconcileInlineEditState();
    setSync('ok', '已同步');
    rebuildNoteIndex();
    renderFeedList({ reset: true, preservePage: true });
    if (change.id === rw.id) reconcileWalkFocus(data);
    return data;
  } catch (error) {
    if (error.status === 409) {
      acceptVersion(error.current);
      finishLocalWrites(Boolean(error.current?.note || error.current?.deleted));
      reconcileInlineEditState();
      rebuildNoteIndex();
      renderFeedList({ reset: true, preservePage: true });
      setSync('ok', '已同步');
    } else {
      setSync('error', '同步未完成');
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
    tagCount: concreteTags.size,
    dayCounts,
  };

  if (state.filter.startsWith('tag:') && !tagNames.has(state.filter.slice(4))) {
    state.filter = 'all';
  }
  for (const name of Object.keys(counts)) {
    $('count-' + name).textContent = state.loaded ? counts[name] : '';
  }
  $('tag-section').hidden = tagTree.length === 0;
  renderActivity(all.length, concreteTags.size, dayCounts);
  renderTagList();
  if (ai.lifecycle) renderAISessions();
}

function renderActivity(totalNotes, tagCount, dayCounts) {
  $('activity-memos').textContent = totalNotes;
  $('activity-tags').textContent = tagCount;
  $('activity-days').textContent = dayCounts.size;
  const today = new Date();
  const todayKey = dayKey(today);
  const date = new Date(today.getFullYear(), today.getMonth(), today.getDate() - today.getDay() - 98);
  const squares = [];
  const months = [];
  let lastMonth = null;
  for (let cell = 0; cell < 105; cell++) {
    const key = dayKey(date);
    if (cell % 7 === 0 && date.getMonth() !== lastMonth) {
      const month = el('span', '', date.getMonth() + 1 + '月');
      month.style.gridColumn = String(Math.floor(cell / 7) + 1);
      months.push(month);
      lastMonth = date.getMonth();
    }
    const count = dayCounts.get(key) || 0;
    const square = count > 0 ? el('button', 'heatmap-square') : el('span', 'heatmap-square');
    if (count > 0) {
      square.type = 'button';
      square.dataset.day = key;
      square.setAttribute('aria-label', key + ' · ' + count + ' 条笔记');
      if (state.dayFilter === key) square.classList.add('active');
    }
    square.dataset.level = String(Math.min(count, 4));
    square.title = key + ' · ' + count + ' 条笔记';
    if (key === todayKey) square.classList.add('today');
    if (date > today) square.classList.add('future');
    squares.push(square);
    date.setDate(date.getDate() + 1);
  }
  $('heatmap').replaceChildren(...squares);
  $('heatmap-months').replaceChildren(...months);
}

function syncHeatmapActive() {
  for (const btn of $('heatmap').querySelectorAll('[data-day]')) {
    btn.classList.toggle('active', btn.dataset.day === state.dayFilter);
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
  const activeView = prof ? 'open-ai-profile' : ai.lifecycle ? 'open-ai-chat' : ins ? 'open-ai-insights' : null;
  for (const button of document.querySelectorAll('#sidebar [data-filter], #sidebar [data-action="open-ai-insights"], #sidebar [data-action="open-ai-chat"], #sidebar [data-action="open-ai-profile"]')) {
    const selected = activeView ? button.dataset.action === activeView : button.dataset.filter === state.filter;
    button.classList.toggle('active', selected);
    if (selected) button.setAttribute('aria-current', 'page');
    else button.removeAttribute('aria-current');
  }
}

function syncSortButton() {
  const btn = $('sort-button');
  if (!btn) return;
  const isNewest = state.sortOrder === 'newest';
  btn.title = isNewest ? '最新优先（点击切换最旧优先）' : '最旧优先（点击切换最新优先）';
  btn.setAttribute('aria-label', isNewest ? '当前最新优先，切换排序' : '当前最旧优先，切换排序');
  btn.classList.toggle('oldest', !isNewest);
}

function renderActiveFilters() {
  const box = $('active-filters');
  const chips = [];
  const searchQuery = $('search').value.trim();
  if (searchQuery) {
    const chip = el('button', 'filter-chip', '搜索：' + searchQuery + ' ×');
    chip.type = 'button';
    chip.dataset.clearFilter = 'search';
    chips.push(chip);
  }
  if (state.filter.startsWith('tag:')) {
    const tagKey = state.filter.slice(4);
    const tagDisplay = state.noteIndex?.tagNames.get(tagKey) || tagKey;
    const chip = el('button', 'filter-chip', '标签：#' + tagDisplay + ' ×');
    chip.type = 'button';
    chip.dataset.clearFilter = 'tag';
    chips.push(chip);
  }
  if (state.dayFilter) {
    const chip = el('button', 'filter-chip', '日期：' + state.dayFilter + ' ×');
    chip.type = 'button';
    chip.dataset.clearFilter = 'day';
    chips.push(chip);
  }
  if (state.bookFilter) {
    const chip = el('button', 'filter-chip', '书名：' + state.bookFilter + ' ×');
    chip.type = 'button';
    chip.dataset.clearFilter = 'book';
    chips.push(chip);
  }
  box.replaceChildren(...chips);
  box.hidden = chips.length === 0;
}

function renderOrphanDraft() {
  const box = $('inline-orphan-draft');
  const fragment = document.createDocumentFragment();
  for (const item of state.orphanDrafts.values()) {
    const card = el('div', 'orphan-draft notice');
    card.dataset.orphanId = item.id;
    const head = el('div', 'orphan-draft-head');
    const dismiss = actionButton('关闭', 'dismiss-orphan-draft');
    dismiss.dataset.orphanId = item.id;
    head.append(el('span', '', '这条笔记已在另一端删除，未保存的草稿已保留，可复制后关闭：'), dismiss);
    const textarea = el('textarea', 'field');
    textarea.rows = 4;
    textarea.readOnly = true;
    textarea.setAttribute('aria-label', '保留的草稿');
    textarea.value = item.draft;
    card.append(head, textarea);
    fragment.append(card);
  }
  box.replaceChildren(fragment);
  box.hidden = state.orphanDrafts.size === 0;
}

function reconcileInlineEditState() {
  const edit = state.inlineEdit;
  if (edit && !state.notes.has(edit.id)) {
    const { id, draft } = edit;
    state.orphanDrafts.set(id, { id, draft });
    state.inlineEdit = null;
    renderOrphanDraft();
    renderInlineDraftBanner();
  }
}

function focusedTextareaSelection(textarea) {
  if (textarea && document.activeElement === textarea) {
    return [textarea.selectionStart, textarea.selectionEnd, textarea.selectionDirection];
  }
  return null;
}

function restoreTextareaSelection(textarea, selection) {
  if (!textarea || !selection) return;
  textarea.focus({ preventScroll: true });
  textarea.setSelectionRange(...selection);
}

function renderInlineDraftBanner() {
  const box = $('inline-draft-banner');
  const edit = state.inlineEdit;
  const card = edit && findCardEl(edit.id);
  const selection = focusedTextareaSelection(box.querySelector('textarea'));
  if (!edit || !state.notes.has(edit.id) || card) {
    box.hidden = true;
    box.replaceChildren();
    if (card) {
      edit.showInBanner = false;
      restoreTextareaSelection(card.querySelector('textarea'), selection);
    }
    return;
  }

  const back = el('button', 'button button-primary', '回到草稿');
  back.type = 'button';
  back.dataset.action = 'return-to-inline-draft';
  const cancel = actionButton('放弃草稿', 'cancel-inline-edit');
  cancel.disabled = edit.saving;
  const actionsRow = el('div', 'inline-edit-actions');
  actionsRow.append(back, cancel);
  box.replaceChildren(el('span', '', '有一条未保存的编辑草稿不在当前视图'), actionsRow);
  if (edit.showInBanner) box.append(renderInlineEditForm(edit, false));
  box.hidden = false;
  restoreTextareaSelection(box.querySelector('textarea'), selection);
}

function compareFeedByTime(a, b) {
  const order = Date.parse(a.createdAt) - Date.parse(b.createdAt) || a.id.localeCompare(b.id);
  return state.sortOrder === 'oldest' ? order : -order;
}

function returnToInlineDraft() {
  const edit = state.inlineEdit;
  if (!edit) return;
  const note = state.notes.get(edit.id);
  if (!note) {
    reconcileInlineEditState();
    return;
  }
  if (!state.feedItems.some((note) => note.id === edit.id)) {
    state.filter = 'all';
    state.dayFilter = null;
    state.bookFilter = null;
    clearSearchInput();
  }

  let idx = 0;
  for (const other of state.notes.values()) {
    if (compareFeedByTime(other, note) < 0) idx++;
  }
  if (idx >= FEED_PAGE_SIZE && state.notes.size - 1 - idx < idx) {
    state.sortOrder = state.sortOrder === 'newest' ? 'oldest' : 'newest';
  }
  edit.showInBanner = true;
  renderFeedList({ reset: true });
  const textarea = findCardEl(edit.id)?.querySelector('textarea')
    || $('inline-draft-banner').querySelector('textarea');
  if (textarea) {
    textarea.focus({ preventScroll: true });
    textarea.scrollIntoView({ block: 'nearest' });
  }
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
  reconcileInlineEditState();
  syncNavActive();
  syncHeatmapActive();
  syncSortButton();
  renderActiveFilters();

  const title = filters[state.filter]
    || (state.filter.startsWith('tag:') ? '#' + (index.tagNames.get(state.filter.slice(4)) || state.filter.slice(4)) : '全部笔记');
  $('page-title').textContent = title;

  if (!state.loaded) {
    $('feed-count').hidden = true;
    disconnectFeedObserver();
    state.feedItems = [];
    state.feedRendered = 0;
    showEmpty('note', state.refreshing ? '正在打开笔记' : '暂时无法打开笔记', '');
    renderInlineDraftBanner();
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
    if (state.bookFilter && (!note.reading || (note.reading.bookTitle || '微信读书') !== state.bookFilter)) return false;
    if (!query) return true;
    const fields = [note.body, note.reading?.bookTitle, note.reading?.chapter, note.reading?.author];
    return fields.some((value) => value?.toLocaleLowerCase().includes(query));
  });

  shown.sort(compareFeedByTime);

  $('feed-count').textContent = '共 ' + shown.length + ' 条笔记';
  $('feed-count').hidden = false;
  state.feedItems = shown;

  if (!shown.length) {
    disconnectFeedObserver();
    state.feedRendered = 0;
    if (query) showEmpty('search', '没有找到相关笔记', '试试其他关键词，或清空搜索。', actionButton('清空搜索', 'clear-search'));
    else if (state.dayFilter || state.bookFilter) showEmpty('search', '当前筛选下没有笔记', '可以清除筛选查看全部笔记。', actionButton('清除筛选', 'clear-filters'));
    else if (state.filter === 'reading') showEmpty('book', '还没有读书摘录', '', actionButton('导入微信读书', 'open-import'));
    else showEmpty('note', '从一条笔记开始', '记下一件今天想留住的事。', actionButton('写第一条笔记', 'focus-compose'));
    renderInlineDraftBanner();
    return;
  }

  let minVisible = 0;
  let restoreFocus = null;
  if (reset) {
    const prevRendered = state.feedRendered;
    const editCard = state.inlineEdit && findCardEl(state.inlineEdit.id);
    if (preservePage) {
      minVisible = Math.max(FEED_PAGE_SIZE, prevRendered);
      if (editCard) {
        const editIdx = shown.findIndex((note) => note.id === state.inlineEdit.id);
        if (editIdx >= minVisible && editIdx < minVisible + FEED_PAGE_SIZE) {
          minVisible = Math.ceil((editIdx + 1) / FEED_PAGE_SIZE) * FEED_PAGE_SIZE;
        }
      }
    }
    restoreFocus = focusedTextareaSelection(editCard?.querySelector('textarea'));
    disconnectFeedObserver();
    state.feedRendered = 0;
    $('note-list').replaceChildren();
  }
  appendNextPage(minVisible);
  if (restoreFocus && state.inlineEdit) {
    restoreTextareaSelection(findCardEl(state.inlineEdit.id)?.querySelector('textarea'), restoreFocus);
  }
}

function appendNextPage(minCount = 0) {
  const list = $('note-list');
  const existingMore = list.querySelector('[data-action="load-more"]');
  if (existingMore) existingMore.remove();
  disconnectFeedObserver();

  const start = state.feedRendered;
  const end = Math.min(Math.max(start + FEED_PAGE_SIZE, minCount), state.feedItems.length);
  if (start < end) {
    const fragment = document.createDocumentFragment();
    const byNote = state.noteIndex?.byNote;
    for (let i = start; i < end; i++) {
      const note = state.feedItems[i];
      fragment.append(renderCard(note, byNote?.get(note.id) || [], true));
    }
    list.append(fragment);
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
  renderInlineDraftBanner();
}

function findCardEl(id) {
  for (const child of $('note-list').children) {
    if (child.dataset?.noteId === id) return child;
  }
  return null;
}

function rerenderCard(id) {
  const existing = findCardEl(id);
  const note = state.notes.get(id);
  if (!existing || !note) return null;
  const next = renderCard(note, state.noteIndex?.byNote.get(id) || [], true);
  if (existing.classList.contains('expanded') && state.inlineEdit?.id !== id) {
    next.classList.add('expanded');
    const btn = next.querySelector('[data-action="toggle-expand"]');
    if (btn) btn.textContent = '收起';
  }
  existing.replaceWith(next);
  return next;
}

function closeCardMenu() {
  if (!state.openMenuId) return;
  const prev = state.openMenuId;
  const activeTa = state.inlineEdit?.id === prev ? findCardEl(prev)?.querySelector('textarea') : null;
  const selection = focusedTextareaSelection(activeTa);
  state.openMenuId = null;
  const next = rerenderCard(prev);
  restoreTextareaSelection(next?.querySelector('textarea'), selection);
}

function renderInlineEditForm(edit, showCancel = true) {
  const form = el('form', 'inline-edit-form inline-editor');
  const textarea = el('textarea', 'field inline-edit-textarea');
  textarea.rows = 5;
  textarea.maxLength = 40000;
  textarea.value = edit.draft;
  textarea.readOnly = edit.saving;
  textarea.setAttribute('aria-label', '编辑笔记');
  textarea.addEventListener('input', () => {
    if (state.inlineEdit === edit && !edit.saving) edit.draft = textarea.value;
  });
  textarea.addEventListener('keydown', (event) => {
    if (event.isComposing) return;
    if ((event.ctrlKey || event.metaKey) && event.key === 'Enter') {
      event.preventDefault();
      if (state.inlineEdit === edit && !edit.saving) form.requestSubmit();
    }
  });
  const err = el('p', 'inline-error', edit.conflictError);
  err.setAttribute('role', 'alert');
  err.hidden = !edit.conflictError;
  const actionsRow = el('div', 'inline-edit-actions');
  if (showCancel) {
    const cancel = actionButton('取消', 'cancel-inline-edit');
    cancel.disabled = edit.saving;
    actionsRow.append(cancel);
  }
  const save = el('button', 'button button-primary', edit.saving ? '保存中…' : '保存');
  save.type = 'submit';
  save.disabled = edit.saving;
  actionsRow.append(save);
  form.append(textarea, err, actionsRow);
  form.addEventListener('submit', submitInlineEdit);
  return form;
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
  const meta = el('div', 'card-meta');
  if (note.reading) {
    const bookTitle = note.reading.bookTitle || '微信读书';
    const bookBtn = el('button', 'card-source');
    bookBtn.type = 'button';
    bookBtn.dataset.bookFilter = bookTitle;
    labeled(bookBtn, 'book', bookTitle);
    meta.append(bookBtn);
  }
  if (note.reading?.chapter) meta.append(el('span', '', note.reading.chapter));
  if (note.createdAt) {
    const date = new Date(note.createdAt);
    const timeBtn = el('button', 'card-time', dateFormatter?.format(date) ?? (dayKey(date) + ' ' + dateTime.format(date)));
    timeBtn.type = 'button';
    timeBtn.dataset.openNote = note.id;
    meta.append(timeBtn);
  }

  const menuWrap = el('div', 'card-menu-wrap');
  const menuOpen = state.openMenuId === note.id;
  const menuBtn = el('button', 'icon-button card-menu-btn', '···');
  menuBtn.type = 'button';
  menuBtn.dataset.action = 'card-menu';
  menuBtn.dataset.noteId = note.id;
  menuBtn.setAttribute('aria-label', '更多操作');
  menuBtn.setAttribute('aria-expanded', String(menuOpen));
  menuWrap.append(menuBtn);

  const isEditing = state.inlineEdit?.id === note.id;

  if (menuOpen) {
    const menu = el('div', 'card-menu');
    menu.setAttribute('role', 'menu');
    const editItem = el('button', 'card-menu-item', '编辑');
    editItem.type = 'button';
    editItem.dataset.action = 'card-inline-edit';
    editItem.dataset.noteId = note.id;
    editItem.disabled = Boolean(state.inlineEdit?.saving);
    const copyItem = el('button', 'card-menu-item', '复制');
    copyItem.type = 'button';
    copyItem.dataset.action = 'card-copy';
    copyItem.dataset.noteId = note.id;
    const aiItem = el('button', 'card-menu-item', 'AI 对话');
    aiItem.type = 'button';
    aiItem.dataset.openNote = note.id;
    if (isEditing) {
      menu.append(editItem, copyItem, aiItem);
    } else {
      const deleteItem = el('button', 'card-menu-item card-menu-danger', '删除');
      deleteItem.type = 'button';
      deleteItem.dataset.action = 'card-inline-delete';
      deleteItem.dataset.noteId = note.id;
      menu.append(editItem, copyItem, aiItem, deleteItem);
    }
    menuWrap.append(menu);
  }
  meta.append(menuWrap);
  card.append(meta);

  if (isEditing) {
    card.append(renderInlineEditForm(state.inlineEdit));
    return card;
  }

  const bodyEl = el('div', 'card-body');
  for (const token of tokenizeBody(note.body)) {
    if (token.type === 'tag') {
      const tagBtn = el('button', 'inline-tag', token.text);
      tagBtn.type = 'button';
      tagBtn.dataset.filter = 'tag:' + token.tag.toLowerCase();
      bodyEl.append(tagBtn);
    } else {
      bodyEl.append(document.createTextNode(token.text));
    }
  }
  card.append(bodyEl);

  const rawBody = note.body || '';
  if ((rawBody.match(/\n/g)?.length || 0) >= 6 || rawBody.length > 260) {
    card.classList.add('is-collapsible');
    const expandBtn = el('button', 'card-expand', '展开');
    expandBtn.type = 'button';
    expandBtn.dataset.action = 'toggle-expand';
    card.append(expandBtn);
  }

  if (state.inlineDeleteId === note.id) {
    const confirmBar = el('div', 'inline-delete-confirm');
    confirmBar.append(el('span', '', '确定删除这条笔记？'));
    const cancelDel = el('button', 'button button-secondary', '取消');
    cancelDel.type = 'button';
    cancelDel.dataset.action = 'cancel-inline-delete';
    const confirmDel = el('button', 'button button-danger', '确认删除');
    confirmDel.type = 'button';
    confirmDel.dataset.action = 'confirm-inline-delete';
    confirmDel.dataset.noteId = note.id;
    confirmBar.append(cancelDel, confirmDel);
    card.append(confirmBar);
  }

  const bottom = el('div', 'card-bottom');
  const chatBtn = el('button', 'card-chat');
  chatBtn.type = 'button';
  chatBtn.dataset.openNote = note.id;
  labeled(chatBtn, 'chat', note.turns?.length ? Math.floor(note.turns.length / 2) + ' 轮对话' : 'AI 对话');
  bottom.append(chatBtn);
  card.append(bottom);
  return card;
}

function rerenderInlineEdit(id) {
  const card = rerenderCard(id);
  renderInlineDraftBanner();
  return card;
}

function startInlineEdit(id) {
  const note = state.notes.get(id);
  if (!note) return;
  if (state.inlineEdit?.saving) {
    closeCardMenu();
    return;
  }
  if (state.inlineEdit?.id === id) {
    closeCardMenu();
    const ta = findCardEl(id)?.querySelector('textarea');
    if (ta) ta.focus();
    return;
  }
  if (state.inlineEdit) {
    const currentBody = state.notes.get(state.inlineEdit.id)?.body || '';
    if (state.inlineEdit.draft !== currentBody) {
      if (!confirm('当前有未保存的编辑草稿，放弃并切换编辑其他笔记？')) {
        closeCardMenu();
        return;
      }
    }
  }
  const prevEditId = state.inlineEdit ? state.inlineEdit.id : null;
  const prevMenuId = state.openMenuId;
  const prevDelId = state.inlineDeleteId;
  state.openMenuId = null;
  state.inlineDeleteId = null;
  state.inlineEdit = {
    id,
    revision: note.revision,
    draft: note.body,
    conflictError: '',
    saving: false,
    showInBanner: false,
  };
  if (prevEditId && prevEditId !== id) rerenderCard(prevEditId);
  if (prevMenuId && prevMenuId !== id && prevMenuId !== prevEditId) rerenderCard(prevMenuId);
  if (prevDelId && prevDelId !== id && prevDelId !== prevEditId && prevDelId !== prevMenuId) rerenderCard(prevDelId);
  const card = rerenderInlineEdit(id);
  const ta = card?.querySelector('textarea');
  if (ta) {
    ta.focus();
    ta.setSelectionRange(ta.value.length, ta.value.length);
  }
}

function cancelInlineEdit() {
  if (!state.inlineEdit || state.inlineEdit.saving) return;
  const id = state.inlineEdit.id;
  state.inlineEdit = null;
  rerenderInlineEdit(id);
}

async function submitInlineEdit(event) {
  event.preventDefault();
  const edit = state.inlineEdit;
  if (!edit || edit.saving) return;
  const note = state.notes.get(edit.id);
  if (!note) {
    reconcileInlineEditState();
    return;
  }
  const submittedDraft = edit.draft;
  const body = submittedDraft.trim();
  if (!body) {
    edit.conflictError = '笔记内容不能为空。';
    rerenderInlineEdit(edit.id);
    return;
  }
  edit.saving = true;
  edit.conflictError = '';
  rerenderInlineEdit(edit.id);
  try {
    const data = await mutate({
      id: note.id,
      expectedRevision: edit.revision,
      note: notePayload({ ...note, body }),
    });
    if (state.inlineEdit === edit) {
      if (state.inlineEdit.draft === submittedDraft) {
        state.inlineEdit = null;
      } else {
        edit.saving = false;
        edit.revision = data?.note?.revision ?? state.notes.get(note.id)?.revision ?? edit.revision;
      }
    }
    rerenderInlineEdit(note.id);
    notify('修改已同步');
  } catch (error) {
    if (error.status === 409 && error.current?.deleted) {
      reconcileInlineEditState();
      return;
    }
    if (state.inlineEdit !== edit) return;
    edit.saving = false;
    if (error.status === 409 && error.current?.note) {
      edit.revision = error.current.note.revision;
      edit.conflictError = '另一端已修改这条笔记，草稿已保留。再次点击保存将以当前内容覆盖。';
    } else {
      edit.conflictError = error.message;
    }
    rerenderInlineEdit(edit.id);
  }
}

async function confirmInlineDelete(id) {
  const note = state.notes.get(id);
  if (!note) return;
  state.inlineDeleteId = null;
  try {
    await mutate({ id: note.id, expectedRevision: note.revision, delete: true });
    notify('笔记已删除');
  } catch (error) {
    if (error.status === 409 && error.current?.deleted) notify('笔记已删除');
    else notify(error.status === 409 ? '这条笔记有新修改，请查看后再删除。' : error.message);
  }
}

async function copyText(text, cardEl) {
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
    document.body.append(ta);
    ta.select();
    try {
      copied = document.execCommand('copy') === true;
    } catch {
      copied = false;
    } finally {
      ta.remove();
    }
  }
  if (copied) {
    notify('已复制');
  } else {
    if (cardEl) {
      cardEl.classList.add('expanded');
      const expandBtn = cardEl.querySelector('[data-action="toggle-expand"]');
      if (expandBtn) expandBtn.textContent = '收起';
    }
    notify('当前浏览器限制自动复制，已展开正文请手动划选复制');
  }
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
  const nextHeight = Math.min(320, Math.max(75, input.scrollHeight));
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
  state.bookFilter = null;
  clearSearchInput();
  closeTagSuggest();
  syncComposerUI();
  renderFeedList({ reset: true });
  notify('笔记已保存');
}

function openNote(id) {
  if (!state.notes.has(id)) return false;
  const dialog = $('note-dialog');
  if (dialog.open && state.noteID === id) return true;
  if (dialog.open && (state.detailWorking || !mayCloseNote())) return false;
  noteSessionLookup?.abort();
  state.noteID = id;
  state.editRevision = null;
  $('delete-confirm').hidden = true;
  $('detail-actions').hidden = false;
  setError('detail-error', '');
  renderDetail();
  if (!dialog.open) dialog.showModal();
  lookupNoteAIEntry(state.notes.get(id));
  dialog.querySelector('.dialog-scroll').scrollTop = 0;
  return true;
}

function mayCloseNote() {
  const differs = state.editRevision !== null && $('edit-body').value.trim() !== (state.notes.get(state.noteID)?.body || '');
  return !differs || confirm('关闭会放弃尚未保存的内容。仍要关闭吗？');
}

function closeNote(force = false) {
  if (!force && !mayCloseNote()) return;
  noteSessionLookup?.abort();
  state.noteID = null;
  state.editRevision = null;
  $('note-dialog').close();
}

function renderDetail() {
  const note = state.notes.get(state.noteID);
  if (!note) return;
  $('detail-meta').replaceChildren(icon(note.reading ? 'book' : 'calendar'), dateLong.format(new Date(note.createdAt)));
  const meta = [note.reading?.author, note.reading?.chapter].filter(Boolean).join(' · ');
  if (meta) $('detail-meta').append(' · ' + meta);
  $('dialog-note-title').textContent = note.reading ? (note.reading.bookTitle || '微信读书') : '日志';
  $('detail-body').textContent = note.body;
  $('detail-body').hidden = state.editRevision !== null;
  $('edit-form').hidden = state.editRevision === null;
  $('detail-actions').hidden = state.editRevision !== null;
  $('note-dialog').querySelector('.note-ai-entry').hidden = state.editRevision !== null;
  renderNoteAIEntry(note);
}

function toggleEdit(enabled) {
  const note = state.notes.get(state.noteID);
  if (!note) return;
  state.editRevision = enabled ? note.revision : null;
  $('delete-confirm').hidden = true;
  setError('detail-error', '');
  if (enabled) $('edit-body').value = note.body;
  renderDetail();
  if (enabled) $('edit-body').focus();
}

async function submitEdit(event) {
  event.preventDefault();
  const body = $('edit-body').value.trim();
  const note = state.notes.get(state.noteID);
  if (!note || !body || state.editRevision === null || state.detailWorking) return;
  state.detailWorking = true;
  const button = $('edit-form').querySelector('button[type=submit]');
  button.disabled = true;
  try {
    await mutate({ id: note.id, expectedRevision: state.editRevision, note: notePayload({ ...note, body }) });
    toggleEdit(false);
    notify('修改已同步');
  } catch (error) {
    if (error.status === 409 && error.current?.note) {
      state.editRevision = error.current.note.revision;
      setError('detail-error', '另一端已修改这条笔记。你的草稿仍保留。再次点击保存将用当前草稿替换正文。');
      renderDetail();
    } else setError('detail-error', error.message);
  } finally {
    state.detailWorking = false;
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
    notify('笔记已删除');
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
}

function openSettings() {
  $('chat-provider').value = state.chatProvider;
  updateAISettings();
  $('openai-key').value = state.apiKey;
  $('openai-model').value = state.model;
  setError('settings-error', '');
  $('settings-dialog').showModal();
  void loadAuthSettings();
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
    renderGatewayModels();
    const signal = ins?.lifecycle.signal ?? ai.lifecycle?.signal;
    if (signal) loadGatewayModels(signal);
    $('settings-dialog').close();
      notify('已选择 Codex');
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
    notify(imported ? '已导入 ' + imported + ' 条读书摘录' : '这批笔记已导入');
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

function openFlomoImport() {
  if (!state.loaded || !state.user?.id) {
    notify('请先登录并完成同步');
    return;
  }
  const select = $('flomo-zone');
  const browserZone = Intl.DateTimeFormat().resolvedOptions().timeZone;
  if (browserZone && ![...select.options].some((option) => option.value === browserZone)) {
    select.add(new Option('当前设备（' + browserZone + '）', browserZone), 1);
  }
  sidebar(false);
  $('flomo-dialog').showModal();
}

function resetFlomoImport(clearFile = false) {
  state.flomoImport = null;
  $('flomo-edit').hidden = false;
  $('flomo-preview').hidden = true;
  $('flomo-back').hidden = true;
  $('flomo-samples').replaceChildren();
  $('flomo-submit').textContent = '预览导入';
  $('flomo-submit').disabled = false;
  setError('flomo-progress', '');
  setError('flomo-error', '');
  if (clearFile) $('flomo-file').value = '';
}

function renderFlomoPreview() {
  const preview = state.flomoImport;
  const remaining = preview.pending.length;
  $('flomo-edit').hidden = true;
  $('flomo-preview').hidden = false;
  $('flomo-back').hidden = false;
  $('flomo-summary').textContent = remaining
    ? '待导入 ' + remaining + ' 条笔记。确认后会保存到当前微记账号。'
    : '没有新的笔记可以导入。';
  const skipped = [];
  if (preview.duplicated) skipped.push('已存在或此前删除 ' + preview.duplicated + ' 条');
  if (preview.skippedAttachments) skipped.push('跳过 ' + preview.skippedAttachments + ' 个附件');
  if (preview.skippedEmpty) skipped.push('跳过 ' + preview.skippedEmpty + ' 条没有文字的笔记');
  if (preview.skippedInvalidDate) skipped.push('跳过 ' + preview.skippedInvalidDate + ' 条日期无法识别的笔记');
  if (preview.skippedLarge) skipped.push('跳过 ' + preview.skippedLarge + ' 条超出大小限制的笔记');
  setError('flomo-skipped', skipped.length ? skipped.join('，') + '。' : '');
  const samples = preview.pending.slice(0, bulkPreviewLimit);
  const dateFormatter = new Intl.DateTimeFormat('zh-CN', {
    year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit', second: '2-digit',
    hourCycle: 'h23', timeZone: preview.timeZone,
  });
  $('flomo-samples').replaceChildren(...samples.map(({ note }) => renderCard(note, tagsFor(note.body), false, dateFormatter)));
  setError('flomo-sample-count', remaining > samples.length ? '仅预览前 ' + samples.length + ' 条。' : '');
  $('flomo-submit').textContent = '导入 ' + remaining + ' 条';
  $('flomo-submit').disabled = remaining === 0;
}

async function previewFlomoImport() {
  const file = $('flomo-file').files?.[0];
  if (!file) throw new Error('请选择 flomo 导出的 ZIP 或 HTML 文件。');
  const timeZone = $('flomo-zone').value;
  const account = state.user.id;
  const result = await parseFlomoFile(file, timeZone);
  if (state.user?.id !== account) return;

  const { pending, duplicated, skippedLarge } = prepareBulkNotes(result.notes);
  state.flomoImport = {
    account, timeZone, pending, duplicated, skippedLarge,
    total: pending.length, saved: 0, skippedDuringSave: 0,
    skippedAttachments: result.skippedAttachments,
    skippedEmpty: result.skippedEmpty,
    skippedInvalidDate: result.skippedInvalidDate,
  };
  renderFlomoPreview();
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
    setSync('error', '同步未完成');
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

async function saveFlomoImport(preview) {
  try {
    await saveBulkNotes(preview, '/api/import/flomo', 'flomo-progress');
  } catch (error) {
    if (state.flomoImport === preview) {
      renderFlomoPreview();
      $('flomo-submit').textContent = '重试剩余 ' + preview.pending.length + ' 条';
    }
    throw error;
  }
  state.filter = 'journal';
  clearSearchInput();
  rebuildNoteIndex();
  renderFeedList({ reset: true });
  const skipped = preview.skippedDuringSave ? '，跳过 ' + preview.skippedDuringSave + ' 条已存在或此前删除的笔记' : '';
  $('flomo-dialog').close();
  notify('已导入 ' + preview.saved + ' 条 flomo 笔记' + skipped);
}

async function importFlomoNotes(event) {
  event.preventDefault();
  if (!state.loaded || !state.user?.id || state.flomoWorking) return;
  state.flomoWorking = true;
  const submit = $('flomo-submit');
  const back = $('flomo-back');
  const close = $('flomo-dialog').querySelector('[data-close="flomo-dialog"]');
  const file = $('flomo-file');
  const zone = $('flomo-zone');
  submit.disabled = back.disabled = close.disabled = file.disabled = zone.disabled = true;
  setError('flomo-error', '');
  try {
    if (state.flomoImport) {
      if (state.flomoImport.pending.length) await saveFlomoImport(state.flomoImport);
    } else {
      setError('flomo-progress', '正在读取导出文件…');
      await previewFlomoImport();
      setError('flomo-progress', '');
    }
  } catch (error) {
    if (!state.flomoImport) setError('flomo-progress', '');
    setError('flomo-error', error.message);
  } finally {
    state.flomoWorking = false;
    submit.disabled = state.flomoImport?.pending.length === 0;
    back.disabled = close.disabled = file.disabled = zone.disabled = false;
  }
}

function sidebar(open) {
  $('sidebar').classList.toggle('open', open);
  const menus = document.querySelectorAll('#mobile-toggle, [data-action="ins-mobile-menu"], [data-action="profile-mobile-menu"]');
  for (const button of menus) {
    button.setAttribute('aria-expanded', String(open));
    button.setAttribute('aria-label', open ? '关闭导航' : '打开导航');
  }
}

function focusCompose() {
  if (state.loaded) {
    $('note-body').scrollIntoView({ block: 'nearest' });
    $('note-body').focus();
  } else {
    notify('请先登录并完成同步');
  }
}

const rw = {
  id: null, history: [], zoom: 1, scrollY: 0, seq: 0, opener: null,
  related: [], loading: false, relatedPromise: null, controller: null,
};
const refreshAnchor = document.createComment('位置：同步按钮');
$('refresh-button').before(refreshAnchor);

function applyWalkZoom() {
  $('rw-stage').style.transform = `translate(0px, 0px) scale(${rw.zoom})`;
  $('rw-zoom-label').textContent = Math.round(rw.zoom * 100) + '%';
}

function drawWalkLinks() {
  const stage = $('rw-stage');
  const svg = stage.querySelector('svg.rw-links');
  const focus = $('rw-focus').firstElementChild;
  if ($('random-walk-overlay').hidden || !focus) {
    svg.replaceChildren();
    return;
  }
  const bounds = stage.getBoundingClientRect();
  const x = value => Math.round((value - bounds.left) / rw.zoom);
  const y = value => Math.round((value - bounds.top) / rw.zoom);
  const from = focus.getBoundingClientRect();
  const paths = Array.from($('rw-related').querySelectorAll('.rw-related-card'), (card) => {
    const to = card.getBoundingClientRect();
    const path = document.createElementNS(SVG_NS, 'path');
    if (to.left >= from.right) {
      const start = x(from.right), end = x(to.left), middle = (start + end) / 2;
      const sy = y(from.top + from.height / 2), ey = y(to.top + to.height / 2);
      path.setAttribute('d', `M ${start} ${sy} C ${middle} ${sy}, ${middle} ${ey}, ${end} ${ey}`);
    } else {
      const sx = x(from.left + from.width / 2), ex = x(to.left + to.width / 2);
      const sy = y(from.bottom), ey = y(to.top), mid = (sy + ey) / 2;
      path.setAttribute('d', `M ${sx} ${sy} C ${sx} ${mid}, ${ex} ${mid}, ${ex} ${ey}`);
    }
    return path;
  });
  svg.replaceChildren(...paths);
}

function walkFocusCard(note) {
  const card = el('article', 'rw-focus-card');
  card.dataset.noteId = note.id;
  card.append(el('p', 'date-line', dateLong.format(new Date(note.createdAt))),
    el('h3', '', note.reading?.bookTitle || '日志'),
    el('p', 'rw-focus-body', note.body));
  const buttons = el('div', 'rw-card-actions');
  for (const [label, action] of [['编辑', 'edit'], ['对话', 'chat'], ['复制', 'copy'], ['删除', 'delete']]) {
    buttons.append(actionButton(label, 'rw-' + action + '-focus'));
  }
  card.append(buttons);
  return card;
}

function resetWalkRelated() {
  rw.controller?.abort();
  rw.seq++;
  rw.controller = rw.relatedPromise = null;
  rw.related = [];
  rw.loading = false;
}

function pivotWalk(id, remember = true) {
  const local = state.notes.get(id);
  if (!local) return;
  resetWalkRelated();
  const seq = rw.seq;
  const controller = rw.controller = new AbortController();
  rw.loading = true;
  if (remember && rw.id && rw.id !== id) rw.history.push(rw.id);
  rw.id = id;
  $('random-walk-overlay').querySelector('[data-action="rw-prev"]').disabled = !rw.history.length;
  $('rw-focus').replaceChildren(walkFocusCard(local));
  $('rw-related').replaceChildren();
  drawWalkLinks();
  setError('rw-status', '正在寻找相关笔记…');
  rw.relatedPromise = request('/api/notes/' + id + '/related?limit=10', undefined, controller.signal).then(result => {
    if (seq !== rw.seq) return;
    const wasWaiting = $('rw-focus').querySelector('[data-action="rw-chat-focus"]').disabled;
    const focus = walkFocusCard(result.focus);
    focus.querySelector('[data-action="rw-chat-focus"]').disabled = wasWaiting;
    $('rw-focus').replaceChildren(focus);
    const cards = result.related.map(({ note, id: relatedId, relevancePercent }) => {
      const button = el('button', 'rw-related-card');
      button.type = 'button';
      button.dataset.action = 'rw-pivot';
      button.dataset.noteId = relatedId;
      button.append(el('span', 'rw-related-text', note.body.slice(0, 140)), el('span', 'rw-score', relevancePercent + '%'));
      return button;
    });
    rw.related = result.related;
    $('rw-related').replaceChildren(...(cards.length ? cards : [el('p', 'help-text', '暂无相关笔记')]));
    $('rw-related').scrollTop = 0;
    setError('rw-status', '');
    drawWalkLinks();
  }).catch(error => {
    if (seq === rw.seq) setError('rw-status', error.message);
  }).finally(() => {
    if (seq !== rw.seq) return;
    rw.loading = false;
    rw.relatedPromise = rw.controller = null;
  });
}

function reconcileWalkFocus(data) {
  if (data.note) { pivotWalk(data.note.id, false); return; }
  if (!data.deleted) return;
  rw.history = rw.history.filter(id => id !== data.deleted.id);
  rw.id = null;
  resetWalkRelated();
  $('rw-focus').replaceChildren();
  $('rw-related').replaceChildren();
  drawWalkLinks();
  shuffleWalk();
}

function shuffleWalk() {
  const choices = [...state.notes.keys()].filter(id => id !== rw.id);
  if (choices.length) pivotWalk(choices[Math.floor(Math.random() * choices.length)]);
  else if (!rw.id) setError('rw-status', '先记录一条笔记再开始漫步。');
}

function openRandomWalk(button) {
  if (!state.loaded || !$('random-walk-overlay').hidden) return;
  const profileScrollY = prof?.scrollY;
  closeProfile({ restore: false });
  closeAIChat();
  closeInsights({ restore: false });
  rw.scrollY = profileScrollY ?? window.scrollY;
  rw.opener = button;
  rw.zoom = 1;
  applyWalkZoom();
  $('random-walk-overlay').hidden = false;
  $('random-walk-overlay').querySelector('.rw-controls').prepend($('refresh-button'));
  $('random-walk-overlay').querySelector('[data-action="rw-prev"]').disabled = true;
  $('random-walk-overlay').querySelector('[data-action="rw-close"]').focus({ preventScroll: true });
  sidebar(false);
  shuffleWalk();
}

function closeRandomWalk({ restore = true } = {}) {
  if ($('random-walk-overlay').hidden) return;
  $('random-walk-overlay').hidden = true;
  refreshAnchor.after($('refresh-button'));
  resetWalkRelated();
  rw.id = null;
  rw.history = [];
  $('rw-focus').replaceChildren();
  $('rw-related').replaceChildren();
  drawWalkLinks();
  setError('rw-status', '');
  if (restore) {
    rw.opener?.focus({ preventScroll: true });
    window.scrollTo(0, rw.scrollY);
  }
  rw.opener = null;
}

async function walkNoteAction(action) {
  const note = state.notes.get(rw.id);
  if (!note) return;
  if (action === 'copy') { copyText(note.body, $('rw-focus')); return; }
  if (action === 'chat') {
    const clickSeq = rw.seq;
    if (rw.loading && rw.relatedPromise) {
      $('rw-focus').querySelector('[data-action="rw-chat-focus"]').disabled = true;
      setError('rw-status', '正在载入相关笔记并打开对话…');
      await rw.relatedPromise;
      if ($('random-walk-overlay').hidden || rw.seq !== clickSeq) return;
      $('rw-focus').querySelector('[data-action="rw-chat-focus"]').disabled = false;
    }
    const walkRelatedIds = rw.related.map(item => item.id).filter(id => id !== note.id && state.notes.has(id)).slice(0, 9);
    openNoteAIChat(note, null, { extraPinIds: walkRelatedIds, fromWalk: true });
    return;
  }
  if (!openNote(note.id)) return;
  if (action === 'edit') toggleEdit(true);
  if (action === 'delete') $('delete-confirm').hidden = false;
}

function emptyAIState() {
  return {
    lifecycle: null, scrollY: 0, session: null, sessions: new Map(), sessionCache: new Map(), selectedSessionId: null, upgradedNoteIds: new Set(),
    origin: 'all', nextCursor: null, loadingSessions: false, sessionsLoaded: false,
    source: null, fromWalk: false, insightContext: null, pendingTurn: null, followBottom: true, pins: new Set(),
    sending: null, loadingSession: false, sessionLoadSeq: 0, requestKey: null, atIndex: null,
  };
}
let ai = emptyAIState();

function gatewayMode() {
  return state.chatProvider === 'codex' && state.codexMode === 'gateway';
}

function hasGatewayModels() {
  return gatewayMode() && state.gatewayModels.length > 0;
}

const gatewaySelectIds = ['ins-model-select', 'ins-rerun-model', 'profile-model-select'];
const modelVendors = { gemini: 'Gemini', openai: 'OpenAI', claude: 'Claude', other: '其他' };
const effortLabels = { '': '默认', low: '低', medium: '中', high: '高', xhigh: '极高' };
const vendorMarks = {
  gemini: 'M12 2c.8 5.5 4.5 9.2 10 10-5.5.8-9.2 4.5-10 10C11.2 16.5 7.5 12.8 2 12c5.5-.8 9.2-4.5 10-10Z',
  openai: 'M12 2a5 5 0 0 1 4.3 2.5A5 5 0 0 1 21 10a5 5 0 0 1 0 5A5 5 0 0 1 16.3 20a5 5 0 0 1-8.6 0A5 5 0 0 1 3 15a5 5 0 0 1 0-5 5 5 0 0 1 4.7-5.5A5 5 0 0 1 12 2Zm0 5-4.3 2.5v5L12 17l4.3-2.5v-5L12 7Z',
  claude: 'M11 2h2l.2 6.2 4.5-4.1 1.4 1.4-4.1 4.5 6.2.2v2l-6.2.2 4.1 4.5-1.4 1.4-4.5-4.1-.2 6.2h-2l-.2-6.2-4.5 4.1-1.4-1.4 4.1-4.5L3 12.2v-2L9.2 10 5.1 5.5l1.4-1.4 4.5 4.1L11 2Z',
};

function vendorBadge(vendor) {
  if (!Object.hasOwn(vendorMarks, vendor)) return icon('spark');
  const svg = document.createElementNS(SVG_NS, 'svg');
  svg.setAttribute('viewBox', '0 0 24 24');
  svg.setAttribute('aria-hidden', 'true');
  svg.setAttribute('class', 'ai-vendor ai-vendor-' + vendor);
  const path = document.createElementNS(SVG_NS, 'path');
  path.setAttribute('d', vendorMarks[vendor]);
  svg.append(path);
  return svg;
}

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
      option.append(vendorBadge(vendor), el('span', 'ai-picker-label', item.label));
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
  $('ai-model-toggle').replaceChildren(vendorBadge(item.vendor), el('span', 'ai-picker-label', item.label), el('span', 'ai-picker-chevron'));
  const fixed = $('ai-effort-fixed');
  const trigger = $('ai-effort-toggle');
  fixed.hidden = !item.fixedEffort;
  trigger.hidden = !item.efforts.length;
  if (!item.efforts.length) toggleAIUtilityPicker('effort', false);
  fixed.textContent = item.fixedEffort ? effortLabels[item.fixedEffort] + '思考' : '';
  const effort = item.efforts.includes(state.reasoningEffort) ? state.reasoningEffort : '';
  trigger.replaceChildren(icon('spark'), el('span', '', effortLabels[effort]), el('span', 'ai-picker-chevron'));
  $('ai-effort-popover').replaceChildren(...['', ...item.efforts].map(value => {
    const option = el('button', 'ai-picker-row', effortLabels[value]);
    option.type = 'button';
    option.setAttribute('aria-pressed', String(value === effort));
    if (value === effort) option.append(icon('check'));
    option.addEventListener('click', () => {
      state.reasoningEffort = value;
      try { localStorage.setItem('weiji.reasoningEffort', value); } catch {}
      renderAIModelPicker();
      toggleAIUtilityPicker('effort', false, true);
    });
    return option;
  }));
}

function renderGatewayModels() {
  for (const id of gatewaySelectIds) {
    const select = $(id);
    const rerun = id === 'ins-rerun-model';
    select.hidden = !hasGatewayModels();
    if (rerun) $('ins-rerun-controls').hidden = select.hidden;
    select.replaceChildren(...state.gatewayModels.map(model => new Option(model, model)));
    select.value = state.gatewayModel ?? '';
  }
  renderAIModelPicker();
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
      state.reasoningEffort = localStorage.getItem('weiji.reasoningEffort') || '';
    } catch {}
    const preferred = state.gatewayModel || remembered;
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
const profileView = $('ai-profile-view');
const profileButton = action => profileView.querySelector('[data-action="profile-' + action + '"]');

function openProfile(opener) {
  if (!state.loaded) { notify('请先登录并完成同步'); return; }
  sidebar(false);
  if (prof) return;
  const scrollY = ai.lifecycle ? ai.scrollY : ins?.scrollY ?? window.scrollY;
  closeRandomWalk({ restore: false });
  closeAIChat({ restore: false });
  closeInsights({ restore: false });
  const view = prof = {
    opener, scrollY, lifecycle: new AbortController(), profile: null,
    loading: false, loaded: false, loadError: false, saving: false, generating: null, editing: false,
  };
  $('notes-topbar').hidden = $('main').hidden = true;
  profileView.hidden = false;
  syncNavActive();
  window.scrollTo(0, 0);
  profileView.querySelector('.ins-scroll').scrollTop = 0;
  profileButton('close').focus({ preventScroll: true });
  loadGatewayModels(view.lifecycle.signal);
  loadProfile(view);
}

function closeProfile({ restore = true } = {}) {
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
  $('notes-topbar').hidden = $('main').hidden = false;
  syncNavActive();
  if (restore) {
    sidebar(false);
    (view.opener.getClientRects().length ? view.opener : $('mobile-toggle')).focus({ preventScroll: true });
    window.scrollTo(0, view.scrollY);
  }
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

function saveProfile(toggleOnly = false) {
  const view = prof;
  if (!view?.loaded || view.loading || view.saving || view.generating) return;
  const enabled = $('profile-enabled').checked;
  const body = toggleOnly ? { enabled } : { enabled, content: $('profile-text').value };
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
    openSettings();
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

const aiChatView = $('ai-chat-view');
const aiButton = action => aiChatView.querySelector('[data-action="ai-' + action + '"]');
const aiOriginLabels = { insight: '洞察续聊', note: '笔记对话', global: '全局对话' };

function closeNotePicker(refocus = false) {
  $('ai-note-picker').hidden = true;
  syncAIScrollButton();
  ai.atIndex = null;
  if (refocus) $('ai-chat-input').focus({ preventScroll: true });
}

function setAISessionRail(open) {
  $('ai-session-rail').classList.toggle('open', open);
  aiButton('toggle-sessions').setAttribute('aria-expanded', String(open));
}

function closeAIChat({ restore = true, focus = false } = {}) {
  const view = ai;
  if (!view.lifecycle) return;
  view.lifecycle.abort();
  ai = emptyAIState();
  ai.sessionCache = view.sessionCache;
  ai.upgradedNoteIds = view.upgradedNoteIds;
  aiChatView.hidden = true;
  toggleAIUtilityPicker('model', false);
  toggleAIUtilityPicker('effort', false);
  $('notes-topbar').hidden = $('main').hidden = false;
  $('ai-note-picker-search').value = '';
  $('ai-note-picker-results').replaceChildren();
  newAISession();
  syncNavActive();
  if (restore) window.scrollTo(0, view.scrollY);
  if (focus) {
    const opener = document.querySelector('#sidebar [data-action="open-ai-chat"]');
    (opener.getClientRects().length ? opener : $('mobile-toggle')).focus({ preventScroll: true });
  }
}

function openAIChat() {
  if (!state.loaded) { notify('请先登录并完成同步'); return false; }
  sidebar(false);
  if (ai.lifecycle) return true;
  const scrollY = prof?.scrollY ?? ins?.scrollY ?? window.scrollY;
  closeRandomWalk({ restore: false });
  closeProfile({ restore: false });
  closeInsights({ restore: false });
  ai.lifecycle = new AbortController();
  ai.scrollY = scrollY;
  $('notes-topbar').hidden = $('main').hidden = true;
  aiChatView.hidden = false;
  syncNavActive();
  window.scrollTo(0, 0);
  renderAIThread();
  loadAISessions();
  loadGatewayModels(ai.lifecycle.signal);
  $('ai-chat-input').focus({ preventScroll: true });
  return true;
}

function aiNoteTitle(note) {
  return note.reading?.bookTitle || note.body.trim().split('\n')[0].slice(0, 80);
}

function storeAISession(view, session) {
  const { turns, ...summary } = session;
  if ((view.sessions.get(session.id)?.version ?? 0) <= session.version) view.sessions.set(session.id, summary);
  if (turns && (view.sessionCache.get(session.id)?.version ?? 0) <= session.version) view.sessionCache.set(session.id, session);
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

function renderAISessions() {
  const entries = [...ai.sessions.values()].filter(session => ai.origin === 'all' || session.origin === ai.origin);
  if (ai.sessionsLoaded && (ai.origin === 'all' || ai.origin === 'note')) {
    for (const note of state.notes.values()) {
      if (note.turns?.length && !ai.upgradedNoteIds.has(note.id)) {
        entries.push({ id: note.id, title: aiNoteTitle(note), origin: 'note', createdAt: note.createdAt, legacy: true });
      }
    }
  }
  entries.sort((a, b) => Date.parse(b.updatedAt || b.createdAt) - Date.parse(a.updatedAt || a.createdAt) || b.id.localeCompare(a.id));
  $('ai-session-list').replaceChildren(...entries.map(entry => {
    const row = el('div', 'ai-session-row');
    const select = actionButton('', entry.legacy ? 'ai-select-legacy-note' : 'ai-select-session');
    select.append(el('span', 'ai-session-title', entry.title), el('span', 'ai-origin-badge', aiOriginLabels[entry.origin]));
    if (entry.legacy) select.dataset.noteId = entry.id;
    else select.dataset.sessionId = entry.id;
    if (ai.selectedSessionId === entry.id) select.setAttribute('aria-current', 'true');
    row.append(select);
    if (!entry.legacy) {
      const remove = actionButton('', 'ai-delete-session', 'ai-session-delete');
      remove.append(icon('close'));
      remove.dataset.sessionId = entry.id;
      remove.setAttribute('aria-label', '删除对话：' + entry.title);
      remove.title = '删除对话';
      row.append(remove);
    }
    return row;
  }));
  if (!entries.length && !ai.loadingSessions) $('ai-session-list').append(el('p', 'help-text', '还没有对话。'));
  const more = aiButton('load-more-sessions');
  more.hidden = !ai.nextCursor;
  more.disabled = ai.loadingSessions;
  aiChatView.querySelectorAll('[data-action="ai-filter-origin"]').forEach(button => {
    button.setAttribute('aria-pressed', String(button.dataset.origin === ai.origin));
  });
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
  card.open = pending;
  const duration = steps.reduce((sum, step) => sum + (step.durationMs ?? 0), 0);
  const matched = steps.find(step => step.kind === 'retrieve')?.detail;
  const summary = pending ? '处理过程' :
    [`已完成 ${steps.length} 步`, matched, duration > 0 ? (duration / 1000).toFixed(1) + 's' : null].filter(Boolean).join(' · ');
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
  if (ai.loadingSession) {
    $('ai-chat-title').textContent = ai.sessions.get(ai.selectedSessionId)?.title || 'AI 对话';
    thread.replaceChildren(aiSkeleton());
    syncAIScrollButton();
    return;
  }
  const prevTop = thread.scrollTop;
  const shouldFollow = ai.followBottom;
  const nodes = [];
  if (!turns.length && !ai.pendingTurn && ai.insightContext) {
    const ctx = ai.insightContext;
    const card = el('section', 'ai-context-card');
    card.setAttribute('aria-label', '附带的洞察报告');
    const head = el('div', 'ai-context-head');
    const meta = el('div', 'ai-context-meta');
    meta.append(el('span', 'ai-context-badge', ctx.lensName), el('strong', 'ai-context-title', ctx.title));
    const close = actionButton('×', 'ai-clear-insight-context', 'icon-button ai-context-close');
    close.setAttribute('aria-label', '移除附带的洞察报告');
    close.title = '移除附带的洞察报告';
    head.append(meta, close);
    const preview = ctx.content.replace(/^#{1,6}\s+/gm, '').replace(/[*_`~]/g, '').replace(/\n+/g, ' ').trim();
    const summary = el('p', 'ai-context-excerpt', preview.slice(0, 120) + (preview.length > 120 ? '…' : ''));
    card.append(head, summary);
    if (ctx.content.length > 120) {
      const details = el('details', 'ai-ctx-fold');
      const toggle = el('summary', '', '查看报告摘要');
      const body = el('div', 'ai-ctx-fold-body');
      renderSafeMarkdown(body, ctx.content, ctx.citations ?? []);
      details.append(toggle, body);
      card.append(details);
    }
    nodes.push(card);
  } else if (ai.source && ((!turns.length && !ai.pendingTurn) || (ai.fromWalk && ai.pins.size > 1))) {
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
      message.append(body);
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
  if (!nodes.length) nodes.push(el('p', 'ai-thread-empty', '问问你的笔记'));
  thread.replaceChildren(...nodes);
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

function syncAIControls() {
  const send = $('ai-chat-send');
  const stopping = Boolean(ai.sending);
  send.disabled = Boolean(ai.loadingSession);
  send.classList.toggle('ai-send-stopping', stopping);
  send.querySelector('span').textContent = stopping ? '停止' : '发送';
  send.setAttribute('aria-label', stopping ? '停止回复' : '发送');
}

function newAISession(source = null, session = null, { extraPinIds = [], fromWalk = false } = {}) {
  if (ai.sending) return false;
  ai.sessionLoadSeq++;
  ai.loadingSession = false;
  ai.session = session;
  ai.selectedSessionId = session?.id ?? source?.id ?? null;
  ai.source = source;
  ai.fromWalk = fromWalk;
  ai.insightContext = null;
  ai.pendingTurn = null;
  ai.followBottom = true;
  ai.pins = new Set([...new Set(source ? [source.id, ...extraPinIds] : [])].filter(id => state.notes.has(id)).slice(0, 10));
  ai.requestKey = null;
  $('ai-chat-input').value = '';
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
  view.selectedSessionId = id ?? source?.id ?? null;
  view.loadingSession = !cached;
  setAISessionRail(false);
  if (!cached) {
    setError('ai-chat-error', '');
    renderAISessions();
    renderAIThread();
    syncAIControls();
  }
  try {
    const { session } = await request(path, undefined, view.lifecycle.signal);
    if (!isCurrent()) return false;
    if (session) storeAISession(view, session);
    view.loadingSession = false;
    if (cached && (!session || session.version <= (view.session?.version ?? 0) || view.sending)) return true;
    if (preserveDraft || cached) {
      view.session = session;
      view.selectedSessionId = session?.id ?? source?.id ?? null;
      renderAIThread();
      renderAISessions();
    } else {
      const note = source ?? state.notes.get(session?.sourceNoteId);
      newAISession(note, session);
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
      view.selectedSessionId = view.session?.id ?? view.source?.id ?? null;
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
  if (view.sending) {
    view.sending.abort();
    return;
  }
  const input = $('ai-chat-input');
  const draft = input.value;
  const message = draft.trim();
  if (!state.loaded || !message || view.loadingSession) return;
  const settings = providerSettings();
  if (settings.provider === 'openai' && !settings.apiKey) {
    setError('ai-chat-error', '请先在设置里填写 OpenAI API Key。');
    openSettings();
    return;
  }
  const ctx = !view.session ? view.insightContext : null;
  const header = ctx ? `[洞察上下文：${ctx.title}（${ctx.lensName}）]\n` : '';
  const tail = ctx ? `\n\n[追问]\n${message}` : '';
  const payloadMessage = ctx ? header + ctx.content.slice(0, Math.max(0, 7900 - header.length - tail.length)) + tail : message;
  const body = {
    ...settings, message: payloadMessage, referencedNoteIds: [...view.pins],
    useAllNotes: true,
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
    userText: payloadMessage, status: '正在检索相关笔记…', streamText: '', citations: [], reasoning: '', steps: new Map(),
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
          view.insightContext = null;
          view.pendingTurn = null;
          storeAISession(view, view.session);
          view.requestKey = null;
          syncAIComposerPlaceholder();
          if (keepReply) {
            pending.steps = new Map((finalTurn.steps ?? []).map(step => [step.id, step]));
            pending.stepsDirty = true;
            renderAIPendingBubble(bubble, pending, true);
            bubble.classList.remove('ai-msg-pending');
            bubble.removeAttribute('id');
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
    if (!completed && ai === view && !signal.aborted) throw new Error('回复意外中断，请重试。');
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
    }
  }
}

function renderNoteAIEntry(note) {
  const button = $('note-dialog').querySelector('[data-action="open-note-ai-chat"]');
  button.textContent = ai.upgradedNoteIds.has(note.id) || note.turns?.length
    ? '继续和 AI 聊这条笔记' : '和 AI 聊这条笔记';
}

let noteSessionLookup = null;
async function lookupNoteAIEntry(note) {
  if (note.turns?.length || ai.upgradedNoteIds.has(note.id)) return;
  const lookup = noteSessionLookup = new AbortController();
  const signal = AbortSignal.any([accountLifecycle.signal, lookup.signal]);
  try {
    const { session } = await request(aiSessionsForNote(note.id), undefined, signal);
    if (session && !signal.aborted && state.noteID === note.id) {
      ai.upgradedNoteIds.add(note.id);
      renderNoteAIEntry(note);
    }
  } catch (error) {
    if (error.name !== 'AbortError' && !signal.aborted) console.warn('读取笔记对话状态失败。');
  } finally {
    if (noteSessionLookup === lookup) noteSessionLookup = null;
  }
}

async function openNoteAIChat(note, starter = null, { extraPinIds = [], fromWalk = false } = {}) {
  if (!note || ai.sending || state.detailWorking || !mayCloseNote()) return;
  if ($('note-dialog').open) closeNote(true);
  closeRandomWalk({ restore: false });
  if (!openAIChat()) return;
  const view = ai;
  newAISession(note, null, { extraPinIds, fromWalk });
  const input = $('ai-chat-input');
  input.focus({ preventScroll: true });
  const selected = await selectAISession(aiSessionsForNote(note.id), note, { preserveDraft: true });
  if (selected && ai === view && starter && !input.value) {
    input.value = starter;
    sendAIChat();
  }
}

const insView = $('ai-insights-view');
const insButton = action => insView.querySelector('[data-action="ins-' + action + '"]');
const insRanges = { '7d': '最近 7 天', week: '本周', month: '本月', all: '不限日期', custom: '自定义日期' };
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
  const { tab, report, run, attempt, stats, lenses, lensId } = ins;
  const viewingReport = Boolean(report || attempt);
  for (const name of ['new', 'history']) $('ins-panel-' + name).hidden = viewingReport || name !== tab;
  $('ins-report-view').hidden = !viewingReport;
  $('ins-scope').hidden = viewingReport || tab !== 'new';
  $('ins-report-actions').hidden = !report;
  insButton('cancel').hidden = !run;
  insButton('retry').hidden = !attempt || Boolean(run || report);
  insView.querySelectorAll('[data-tab]').forEach(button => insPressed(button, button.dataset.tab === tab));
  $('ins-range-select').value = ins.range;
  $('ins-custom-dates').hidden = ins.range !== 'custom';
  $('ins-tag-trigger').textContent = ins.tags.size ? `标签 · ${ins.tags.size}` : '全部标签';
  insButton('clear-tags').disabled = !ins.tags.size;
  $('ins-stat-notes').textContent = stats?.noteCount ?? '—';
  $('ins-stat-tags').textContent = stats?.tagCount ?? '—';
  $('ins-stat-days').textContent = stats?.dayCount ?? '—';
  $('ins-sampling').hidden = !stats?.willSample;
  insView.querySelectorAll('[data-action="ins-select-lens"]').forEach(button => insPressed(button, button.dataset.lensId === lensId));
  const lens = lenses.find(item => item.id === lensId);
  $('ins-selected-panel').hidden = !lens;
  $('ins-selected-lens').textContent = lens?.name ?? '';
  $('ins-preview-prompt').textContent = lens?.prompt ?? '';
  const suggested = lens?.suggestedRange;
  const apply = $('ins-apply-suggested');
  apply.hidden = !suggested || suggested === ins.range;
  apply.textContent = suggested ? '使用建议范围：' + insRanges[suggested] : '';
  insButton('run').disabled = !lens || !stats?.noteCount || Boolean(run);
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

function insLensCard(lens) {
  const card = el('div', 'ins-lens');
  const button = actionButton('', 'ins-select-lens');
  button.className = 'ins-lens-card';
  button.dataset.lensId = lens.id;
  button.append(el('strong', '', lens.name), el('span', '', lens.description));
  card.append(button);
  if (!lens.builtin) {
    const tools = el('div', 'ins-lens-tools');
    const edit = actionButton('编辑', 'ins-edit-lens');
    const remove = actionButton('删除', 'ins-delete-lens');
    edit.dataset.id = remove.dataset.id = lens.id;
    tools.append(edit, remove);
    card.append(tools);
  }
  return card;
}

function renderInsLenses() {
  const { lenses, categories, cat } = ins;
  $('ins-category-list').replaceChildren(...['精选', ...categories, '自定义'].map(category => {
    const button = actionButton(category, 'ins-category');
    button.dataset.insCat = category;
    insPressed(button, category === cat);
    return button;
  }));
  $('ins-lens-grid').replaceChildren(...lenses.filter(lens => cat === '精选' ? lens.featured
    : cat === '自定义' ? !lens.builtin : lens.builtin && lens.category === cat).map(insLensCard));
  renderInsControls();
}

function insCount(report) {
  const count = report.analyzedCount === report.noteCount
    ? `已分析 ${report.analyzedCount} 条笔记`
    : `已从 ${report.noteCount} 条中精选分析 ${report.analyzedCount} 条`;
  return count + (report.contentTruncated ? '（部分正文已裁剪）' : '');
}

function renderInsHistory() {
  $('ins-history-list').replaceChildren(...(ins.reports.length ? ins.reports.map(report => {
    const row = el('div', 'ins-history-row');
    const open = actionButton('', 'ins-open-report');
    open.className = 'ins-lens-card';
    const remove = actionButton('删除', 'ins-delete-report', 'button-danger');
    open.dataset.id = remove.dataset.id = report.id;
    open.append(el('strong', '', report.title), el('span', '', [report.lensName, dayKey(new Date(report.createdAt)), insCount(report)].join(' · ')));
    row.append(open, remove);
    return row;
  }) : [el('p', 'privacy-note', '暂无历史报告')]));
}

function showInsReport(report) {
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
  renderInsControls();
  $('ins-scroll').scrollTop = 0;
  $('ins-report-view').focus({ preventScroll: true });
}

async function previewInsScope() {
  const view = ins;
  view.preview?.abort();
  view.stats = null;
  renderInsControls();
  const scope = insScope();
  if (scope.range === 'custom' && (!scope.startDate || !scope.endDate || scope.startDate > scope.endDate)) {
    setError('ins-scope-error', scope.startDate && scope.endDate ? '起始日期不能晚于结束日期。' : '请选择起止日期。');
    return;
  }
  setError('ins-scope-error', '');
  const controller = new AbortController();
  view.preview = controller;
  try {
    const stats = await request('/api/insights/preview', { scope }, controller.signal);
    if (ins !== view || controller.signal.aborted) return;
    view.stats = stats;
    renderInsControls();
  } catch (error) {
    if (ins === view && !controller.signal.aborted && error.name !== 'AbortError') setError('ins-scope-error', error.message);
  }
}

async function loadInsLenses(view) {
  const revision = ++view.lensRevision;
  try {
    const result = await request('/api/insights/lenses', undefined, view.lifecycle.signal);
    if (ins !== view || revision !== view.lensRevision || view.lifecycle.signal.aborted) return;
    view.lensesLoaded = true;
    view.lenses = result.lenses;
    view.categories = result.categories;
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
    renderInsHistory();
  } catch (error) {
    if (ins === view && revision === view.historyRevision && !view.lifecycle.signal.aborted && error.name !== 'AbortError') setError('ins-view-error', error.message);
  }
}

function openInsights(opener) {
  if (ins) { sidebar(false); return; }
  if (!state.loaded) { notify('请先登录并完成同步'); return; }
  const profileScrollY = prof?.scrollY;
  closeRandomWalk({ restore: false });
  closeProfile({ restore: false });
  closeAIChat();
  const view = ins = {
    opener, scrollY: profileScrollY ?? window.scrollY, tab: 'new', cat: '精选', range: '7d', tags: new Set(),
    lifecycle: new AbortController(), lenses: [], categories: [], lensId: null, lensRevision: 0, lensesLoaded: false,
    stats: null, reports: [], historyRevision: 0,
    report: null, reportRevision: 0, preview: null, run: null, lensDraft: null, attempt: null,
  };
  $('ins-start-date').value = dayKey(new Date());
  $('ins-end-date').value = $('ins-start-date').value;
  $('ins-use-profile').checked = false;
  $('ins-tag-search').value = '';
  sidebar(false);
  $('notes-topbar').hidden = $('main').hidden = true;
  insView.hidden = false;
  syncNavActive();
  window.scrollTo(0, 0);
  $('ins-scroll').scrollTop = 0;
  insButton('close').focus({ preventScroll: true });
  renderInsTags();
  renderInsLenses();
  renderInsHistory();
  loadGatewayModels(view.lifecycle.signal);
  loadInsLenses(view);
  previewInsScope();
}

function closeInsights({ restore = true } = {}) {
  const view = ins;
  if (!view) return;
  ins = null;
  view.lifecycle.abort();
  view.preview?.abort();
  view.run?.abort();
  insView.hidden = true;
  $('notes-topbar').hidden = $('main').hidden = false;
  syncNavActive();
  toggleInsTags(false);
  if ($('insight-lens-dialog').open) $('insight-lens-dialog').close();
  $('ins-lens-form').reset();
  $('ins-lens-form').querySelector('button[type="submit"]').disabled = false;
  for (const id of ['ins-report-body', 'ins-report-meta', 'ins-stream-status', 'ins-tag-list', 'ins-lens-grid', 'ins-category-list', 'ins-history-list', 'ins-preview-prompt']) {
    $(id).replaceChildren();
  }
  $('ins-report-view').hidden = true;
  for (const id of ['ins-stat-notes', 'ins-stat-tags', 'ins-stat-days', 'ins-selected-lens']) $(id).textContent = '';
  $('ins-tag-search').value = '';
  $('ins-use-profile').checked = false;
  setError('ins-error', '');
  setError('ins-scope-error', '');
  setError('ins-lens-error', '');
  setError('ins-view-error', '');
  setError('ins-report-error', '');
  if (restore) {
    (view.opener.getClientRects().length ? view.opener : $('mobile-toggle')).focus({ preventScroll: true });
    window.scrollTo(0, view.scrollY);
  }
}

function setInsTab(tab) {
  ins.run?.abort();
  ins.run = null;
  ins.attempt = null;
  ins.tab = tab;
  ins.report = null;
  toggleInsTags(false);
  setError('ins-view-error', '');
  ins.reportRevision++;
  $('ins-report-body').replaceChildren();
  $('ins-scroll').scrollTop = 0;
  setError('ins-error', '');
  renderInsControls();
  if (tab === 'history') loadInsReports(ins);
}

function openInsLens(id) {
  const lens = ins.lenses.find(item => item.id === id);
  const dialog = $('insight-lens-dialog');
  ins.lensDraft = { id: lens?.id };
  $('ins-lens-title').textContent = lens ? '编辑自定义视角' : '新建自定义视角';
  $('ins-lens-name').value = lens?.name ?? '';
  $('ins-lens-desc').value = lens?.description ?? '';
  $('ins-lens-prompt').value = lens?.prompt ?? '';
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
    view.cat = '自定义';
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

function runInsightReport() {
  if (ins.run || !ins.lensId || !ins.stats?.noteCount) return;
  const settings = providerSettings();
  if (settings.provider === 'openai' && !settings.apiKey) {
    setError('ins-error', '请先在设置里填写 OpenAI API Key。');
    openSettings();
    return;
  }
  startInsRun({ ...settings, scope: insScope(), lensId: ins.lensId, useProfile: $('ins-use-profile').checked,
    clientRequestId: randomUUID(), stream: true });
}

function rerunInsightReport() {
  if (!ins.report || !hasGatewayModels()) return;
  const { lensId, scope, useProfile } = ins.report;
  startInsRun({ provider: 'codex', model: $('ins-rerun-model').value, lensId, scope, useProfile: useProfile ?? false,
    clientRequestId: randomUUID(), stream: true });
}

async function startInsRun(body) {
  const view = ins;
  if (view.run) return;
  const controller = view.run = new AbortController();
  view.report = null;
  view.attempt = body;
  view.reportRevision++;
  toggleInsTags(false);
  setError('ins-error', '');
  setError('ins-report-error', '');
  $('ins-report-meta').textContent = '';
  $('ins-stream-status').textContent = '正在准备…';
  const text = document.createTextNode('');
  $('ins-report-body').classList.add('is-streaming');
  $('ins-report-body').replaceChildren(text);
  renderInsControls();
  $('ins-scroll').scrollTop = 0;
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
    renderInsHistory();
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
  const view = ins;
  const revision = ++view.reportRevision;
  try {
    const { report } = await request('/api/insights/reports/' + id, undefined, view.lifecycle.signal);
    if (ins === view && revision === view.reportRevision && !view.lifecycle.signal.aborted) showInsReport(report);
  } catch (error) {
    if (ins === view && revision === view.reportRevision && !view.lifecycle.signal.aborted && error.name !== 'AbortError') setError('ins-view-error', error.message);
  }
}

async function deleteInsReport(id) {
  const view = ins;
  try {
    await request('/api/insights/reports/' + id, undefined, view.lifecycle.signal, 'DELETE');
    if (ins !== view) return;
    view.reportRevision++;
    view.historyRevision++;
    view.reports = view.reports.filter(report => report.id !== id);
    if (view.report?.id === id) setInsTab('history');
    renderInsHistory();
  } catch (error) {
    if (ins === view) setError(view.report ? 'ins-report-error' : 'ins-view-error', error.message);
  }
}

function continueInsightChat() {
  const report = ins.report;
  if (!report) return;
  if (!openAIChat() || !newAISession()) return;
  ai.insightContext = {
    title: report.title,
    lensName: report.lensName,
    content: report.content.slice(0, 2000),
    citations: report.citations ?? [],
  };
  syncAIComposerPlaceholder();
  renderAIThread();
}

$('ins-lens-form').addEventListener('submit', saveInsLens);
$('insight-lens-dialog').addEventListener('close', () => {
  if (ins) ins.lensDraft = null;
  $('ins-lens-form').reset();
  $('ins-lens-form').querySelector('button[type="submit"]').disabled = false;
});
for (const id of gatewaySelectIds) $(id).addEventListener('change', event => {
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
  previewInsScope();
});
$('ins-tag-search').addEventListener('input', event => { if (ins) renderInsTags(event.target.value); });
for (const id of ['ins-start-date', 'ins-end-date']) $(id).addEventListener('change', () => { if (ins) previewInsScope(); });

const walkResize = new ResizeObserver(drawWalkLinks);
walkResize.observe($('rw-stage'));
$('rw-related').addEventListener('scroll', drawWalkLinks, { passive: true });
$('ai-chat-form').addEventListener('submit', sendAIChat);
$('profile-enabled').addEventListener('change', () => saveProfile(true));
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

const actions = {
  'open-ai-insights': openInsights,
  'ins-close': () => closeInsights(),
  'ins-tab': button => setInsTab(button.dataset.tab),
  'ins-mobile-menu': () => sidebar(!$('sidebar').classList.contains('open')),
  'ins-tag-popover': () => toggleInsTags($('ins-tag-popover').hidden, true),
  'ins-apply-suggested': () => {
    ins.range = ins.lenses.find(lens => lens.id === ins.lensId).suggestedRange;
    previewInsScope();
  },
  'ins-back': () => setInsTab(ins.tab),
  'ins-rerun': rerunInsightReport,
  'ins-retry': () => startInsRun(ins.attempt),
  'ins-toggle-tag': button => {
    const tag = button.dataset.insTag;
    if (ins.tags.has(tag)) ins.tags.delete(tag);
    else if (ins.tags.size < 20) ins.tags.add(tag);
    else { setError('ins-error', '最多选择 20 个标签。'); return; }
    insPressed(button, ins.tags.has(tag));
    previewInsScope();
  },
  'ins-clear-tags': () => { ins.tags.clear(); renderInsTags($('ins-tag-search').value); previewInsScope(); },
  'ins-category': button => {
    ins.cat = button.dataset.insCat;
    renderInsLenses();
    [...$('ins-category-list').children].find(item => item.dataset.insCat === ins.cat)?.focus();
  },
  'ins-select-lens': button => {
    ins.lensId = button.dataset.lensId;
    setError('ins-error', '');
    renderInsControls();
  },
  'ins-new-lens': () => openInsLens(),
  'ins-edit-lens': button => openInsLens(button.dataset.id),
  'ins-close-lens': () => $('insight-lens-dialog').close(),
  'ins-delete-lens': button => deleteInsLens(button.dataset.id),
  'ins-run': runInsightReport,
  'ins-cancel': cancelInsRun,
  'ins-open-report': button => openInsReport(button.dataset.id),
  'ins-copy-report': () => { if (ins.report) copyText(ins.report.content); },
  'ins-delete-report': button => {
    const id = button.dataset.id ?? ins.report?.id;
    if (id) deleteInsReport(id);
  },
  'ins-continue-chat': continueInsightChat,
  'open-random-walk': openRandomWalk,
  'rw-close': () => closeRandomWalk(),
  'rw-shuffle': shuffleWalk,
  'rw-pivot': (button) => pivotWalk(button.dataset.noteId),
  'rw-prev': () => {
    while (rw.history.length) {
      const previous = rw.history.pop();
      if (state.notes.has(previous)) { pivotWalk(previous, false); return; }
    }
    $('random-walk-overlay').querySelector('[data-action="rw-prev"]').disabled = true;
  },
  'rw-zoom-in': () => { rw.zoom = Math.min(1.8, rw.zoom + 0.15); applyWalkZoom(); },
  'rw-zoom-out': () => { rw.zoom = Math.max(0.55, rw.zoom - 0.15); applyWalkZoom(); },
  'rw-center': () => { rw.zoom = 1; applyWalkZoom(); },
  'rw-edit-focus': () => walkNoteAction('edit'),
  'rw-chat-focus': () => walkNoteAction('chat'),
  'rw-copy-focus': () => walkNoteAction('copy'),
  'rw-delete-focus': () => walkNoteAction('delete'),
  'open-ai-chat': openAIChat,
  'ai-close': () => closeAIChat({ focus: true }),
  'ai-mobile-menu': () => { setAISessionRail(false); sidebar(!$('sidebar').classList.contains('open')); },
  'ai-toggle-sessions': () => setAISessionRail(!$('ai-session-rail').classList.contains('open')),
  'ai-filter-origin': button => { ai.origin = button.dataset.origin; renderAISessions(); },
  'ai-load-more-sessions': () => loadAISessions(true),
  'open-note-ai-chat': () => openNoteAIChat(state.notes.get(state.noteID)),
  'note-ai-starter': button => openNoteAIChat(state.notes.get(state.noteID), button.dataset.prompt),
  'ai-select-legacy-note': button => openNoteAIChat(state.notes.get(button.dataset.noteId)),
  'ai-new-session': () => { if (newAISession()) $('ai-chat-input').focus({ preventScroll: true }); },
  'ai-select-session': (button) => selectAISession('/api/ai/sessions/' + button.dataset.sessionId, null, { id: button.dataset.sessionId }),
  'ai-delete-session': (button) => deleteAISession(button.dataset.sessionId),
  'open-ai-profile': openProfile,
  'profile-close': () => closeProfile(),
  'profile-reload': () => loadProfile(prof),
  'profile-mobile-menu': () => sidebar(!$('sidebar').classList.contains('open')),
  'profile-generate': generateProfile,
  'profile-edit': () => setProfileEditing(true),
  'profile-cancel-edit': () => setProfileEditing(false),
  'profile-save': () => saveProfile(),
  'ai-pick-note': () => $('ai-note-picker').hidden ? openNotePicker() : closeNotePicker(true),
  'ai-scroll-bottom': () => scrollAIThreadToBottom(true),
  'ai-clear-insight-context': () => {
    ai.insightContext = null;
    $('ai-chat-input').placeholder = '问问你的笔记…';
    renderAIThread();
  },
  'open-import': openImport,
  'open-flomo-import': openFlomoImport,
  'open-settings': openSettings,
  'focus-compose': focusCompose,
  'insert-tag': () => {
    if (!state.loaded) return;
    const input = $('note-body');
    const before = input.value.slice(0, input.selectionStart);
    input.setRangeText((before.length && !/\s$/.test(before) ? ' ' : '') + '#', input.selectionStart, input.selectionEnd, 'end');
    input.focus();
    syncComposerUI();
  },
  'format-bullet': () => {
    if (!state.loaded) return;
    const input = $('note-body');
    const start = input.selectionStart;
    const before = input.value.slice(0, start);
    const prefix = before.length && !before.endsWith('\n') ? '\n- ' : '- ';
    input.setRangeText(prefix, start, input.selectionEnd, 'end');
    input.focus();
    syncComposerUI();
  },
  'format-ordered': () => {
    if (!state.loaded) return;
    const input = $('note-body');
    const start = input.selectionStart;
    const before = input.value.slice(0, start);
    const prefix = before.length && !before.endsWith('\n') ? '\n1. ' : '1. ';
    input.setRangeText(prefix, start, input.selectionEnd, 'end');
    input.focus();
    syncComposerUI();
  },
  'format-bold': () => {
    if (!state.loaded) return;
    const input = $('note-body');
    const start = input.selectionStart;
    const end = input.selectionEnd;
    const selected = input.value.slice(start, end);
    if (selected) {
      input.setRangeText('**' + selected + '**', start, end, 'end');
    } else {
      input.setRangeText('**文本**', start, end, 'end');
      input.setSelectionRange(start + 2, start + 4);
    }
    input.focus();
    syncComposerUI();
  },
  'clear-search': () => { clearSearchInput(); renderFeedList({ reset: true }); },
  'clear-filters': () => { state.dayFilter = null; state.bookFilter = null; renderFeedList({ reset: true }); },
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
  'card-menu': (button) => {
    const id = button.dataset.noteId;
    const prev = state.openMenuId;
    state.openMenuId = prev === id ? null : id;
    if (prev && prev !== id) rerenderCard(prev);
    rerenderCard(id);
  },
  'card-inline-edit': (button) => startInlineEdit(button.dataset.noteId),
  'cancel-inline-edit': cancelInlineEdit,
  'return-to-inline-draft': returnToInlineDraft,
  'dismiss-orphan-draft': (button) => {
    state.orphanDrafts.delete(button.dataset.orphanId);
    renderOrphanDraft();
  },
  'card-copy': (button) => {
    const id = button.dataset.noteId;
    const note = state.notes.get(id);
    closeCardMenu();
    if (!note) return;
    copyText(note.body || '', findCardEl(id));
  },
  'card-inline-delete': (button) => {
    const id = button.dataset.noteId;
    if (state.inlineEdit?.id === id) return;
    const prevDel = state.inlineDeleteId;
    state.openMenuId = null;
    state.inlineDeleteId = id;
    if (prevDel && prevDel !== id) rerenderCard(prevDel);
    rerenderCard(id);
  },
  'cancel-inline-delete': () => {
    const prev = state.inlineDeleteId;
    state.inlineDeleteId = null;
    if (prev) rerenderCard(prev);
  },
  'confirm-inline-delete': (button) => confirmInlineDelete(button.dataset.noteId),
  'toggle-expand': (button) => {
    const card = button.closest('.note-card');
    if (!card) return;
    const expanded = card.classList.toggle('expanded');
    button.textContent = expanded ? '收起' : '展开';
  },
  'edit-note': () => toggleEdit(true),
  'cancel-edit': () => toggleEdit(false),
  'delete-note': () => { $('delete-confirm').hidden = false; },
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
  'flomo-back': () => { if (!state.flomoWorking) resetFlomoImport(); },
};

document.addEventListener('click', (event) => {
  if (!event.target.closest) return;
  if (!$('sidebar').contains(event.target) && !event.target.closest('#mobile-toggle, [data-action="ins-mobile-menu"], [data-action="ai-mobile-menu"], [data-action="profile-mobile-menu"]')) sidebar(false);
  if (ins && !$('ins-tag-popover').hidden && !event.target.closest('.ins-tags')) toggleInsTags(false);
  if (state.openMenuId && !event.target.closest('.card-menu-wrap')) closeCardMenu();
  if (state.tagSuggest.open && !event.target.closest('.composer-input-wrap')) closeTagSuggest();
  const button = event.target.closest('button');
  if (!button || button.disabled) return;
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
    closeAIChat();
    closeInsights({ restore: false });
    closeProfile({ restore: false });
    const day = button.dataset.day;
    state.dayFilter = state.dayFilter === day ? null : day;
    sidebar(false);
    renderFeedList({ reset: true });
    return;
  }
  if (button.dataset.bookFilter) {
    state.bookFilter = button.dataset.bookFilter;
    renderFeedList({ reset: true });
    return;
  }
  if (button.dataset.clearFilter) {
    if (button.dataset.clearFilter === 'day') state.dayFilter = null;
    if (button.dataset.clearFilter === 'book') state.bookFilter = null;
    if (button.dataset.clearFilter === 'search') clearSearchInput();
    if (button.dataset.clearFilter === 'tag') state.filter = 'all';
    renderFeedList({ reset: true });
    return;
  }
  if (button.dataset.close) {
    if (button.dataset.close === 'note-dialog') closeNote();
    if (button.dataset.close === 'settings-dialog') $('settings-dialog').close();
    if (button.dataset.close === 'import-dialog' && !state.importWorking && !state.wereadImport?.saving) $('import-dialog').close();
    if (button.dataset.close === 'flomo-dialog' && !state.flomoWorking) $('flomo-dialog').close();
  }
  if (button.dataset.action && actions[button.dataset.action]) actions[button.dataset.action](button);
  if (button.dataset.openNote) {
    closeCardMenu();
    openNote(button.dataset.openNote);
  }
  if (button.dataset.filter) {
    const sameChatFilter = ai.lifecycle && state.filter === button.dataset.filter;
    closeAIChat();
    closeInsights({ restore: false });
    closeProfile({ restore: false });
    sidebar(false);
    if (sameChatFilter) return;
    state.filter = button.dataset.filter;
    renderFeedList({ reset: true });
  }
});

$('note-list').addEventListener('dblclick', (event) => {
  if (event.target.closest('.inline-tag, button, a, textarea, input, .inline-edit-form')) return;
  const bodyEl = event.target.closest('.card-body');
  if (!bodyEl) return;
  const card = bodyEl.closest('.note-card[data-note-id]');
  if (card) startInlineEdit(card.dataset.noteId);
});

$('tag-suggest').addEventListener('mousedown', (event) => {
  event.preventDefault();
});

$('note-dialog').addEventListener('cancel', (event) => { event.preventDefault(); closeNote(); });
$('import-dialog').addEventListener('cancel', (event) => {
  if (state.importWorking || state.wereadImport?.saving) event.preventDefault();
});
$('import-dialog').addEventListener('close', resetWereadImport);
$('flomo-dialog').addEventListener('cancel', (event) => { if (state.flomoWorking) event.preventDefault(); });
$('flomo-dialog').addEventListener('close', () => resetFlomoImport(true));
$('settings-dialog').addEventListener('close', () => {
  $('openai-key').value = '';
  $('admin-invite-created').textContent = '';
  $('admin-invite-created').hidden = true;
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
$('flomo-form').addEventListener('submit', importFlomoNotes);
$('import-file').addEventListener('change', pickImportFile);
$('edit-form').addEventListener('submit', submitEdit);
$('composer').addEventListener('submit', createNote);
$('note-body').addEventListener('input', syncComposerUI);
$('note-body').addEventListener('click', () => {
  suppressNextTagSuggestKeyup = false;
  updateTagSuggest();
});
$('note-body').addEventListener('keyup', (event) => {
  if (event.isComposing) return;
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
$('refresh-button').addEventListener('click', () => refresh());
$('mobile-toggle').addEventListener('click', () => sidebar(!$('sidebar').classList.contains('open')));

document.addEventListener('keydown', (event) => {
  if (event.isComposing) return;
  if (event.key === 'Escape') {
    if (document.querySelector('dialog[open]')) return;
    if (prof) {
      event.preventDefault();
      if (prof.editing && prof.saving) return;
      if (prof.editing) setProfileEditing(false);
      else closeProfile();
      return;
    }
    if (ins && !$('ins-tag-popover').hidden) {
      event.preventDefault();
      toggleInsTags(false, true);
      return;
    }
    if (ai.lifecycle || ins || !$('random-walk-overlay').hidden) {
      event.preventDefault();
      if (!$('random-walk-overlay').hidden) closeRandomWalk();
      else if (!$('ai-note-picker').hidden) closeNotePicker(true);
      else if ($('ai-session-rail').classList.contains('open')) setAISessionRail(false);
      else if (ai.lifecycle) closeAIChat({ focus: true });
      else closeInsights();
      return;
    }
    if (state.tagSuggest.open) {
      event.preventDefault();
      suppressNextTagSuggestKeyup = true;
      closeTagSuggest();
      return;
    }
    if (state.openMenuId) {
      event.preventDefault();
      closeCardMenu();
      return;
    }
    if (state.inlineEdit && event.target instanceof Element
      && event.target.closest('.inline-editor')
      && event.target.closest('article.note-card')?.dataset.noteId === state.inlineEdit.id) {
      event.preventDefault();
      cancelInlineEdit();
    }
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
    $('search').focus();
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

if (/Mac|iPhone|iPad/.test(navigator.platform)) {
  $('save-shortcut').textContent = '⌘ ↵';
  $('search-shortcut').textContent = '⌘ K';
}
window.addEventListener('focus', () => refresh({ silent: true }));
let pageHidden = false;
let suspendedComposeDraft = null;
window.addEventListener('storage', event => {
  if (event.key !== weijiAuthEvent || !event.newValue) return;
  let payload = null;
  try { payload = JSON.parse(event.newValue); } catch {}
  if (payload?.type === 'session') {
    const activeUser = state.user?.id ?? pageUserId;
    if (!activeUser) return;
    if (payload.userId === activeUser) {
      pageAuthStamp = event.newValue;
      return;
    }
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
  const currentStamp = authEventStamp();
  if (pageAuthStamp !== currentStamp) {
    let payload = null;
    try { payload = JSON.parse(currentStamp || ''); } catch {}
    const expectedUser = pageUserId;
    if (payload?.type === 'session' && expectedUser && payload.userId === expectedUser) {
      pageAuthStamp = currentStamp;
    } else {
      suspendedComposeDraft = null;
      void invalidateAccount({ broadcast: false });
      return;
    }
  }
  state.authSuspended = false;
  void refresh();
});
document.addEventListener('visibilitychange', () => { if (!document.hidden) refresh({ silent: true }); });
setInterval(() => { if (!document.hidden) refresh({ silent: true }); }, 15000);
refresh();
rebuildNoteIndex();
renderFeedList({ reset: true });
