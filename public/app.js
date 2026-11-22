import { parseWeRead, readWeReadFile } from './weread.js';
import { parseFlomoFile } from './flomo.js';

const $ = (id) => document.getElementById(id);
const SVG_NS = 'http://www.w3.org/2000/svg';
const excerptsMarker = '\n\nAI 摘录\n';
const state = {
  notes: new Map(),
  deletedNotes: new Set(),
  filter: 'all',
  user: null,
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
  chatRequest: null,
  unsavedChat: null,
  model: 'gpt-4.1-mini',
  chatProvider: 'openai',
  codexAvailable: false,
  apiKey: '',
};

const filters = { all: '全部笔记', journal: '日志', reading: '读书摘录' };
const dateLong = new Intl.DateTimeFormat('zh-CN', { year: 'numeric', month: 'long', day: 'numeric' });
const dateTime = new Intl.DateTimeFormat('zh-CN', { hour: '2-digit', minute: '2-digit', hourCycle: 'h23' });
let toastTimer;

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
  }
}

async function request(path, body, signal) {
  const headers = { Accept: 'application/json' };
  if (state.user?.id) headers['X-Journal-Account'] = state.user.id;
  if (body !== undefined) headers['Content-Type'] = 'application/json';
  let response;
  try {
    response = await fetch(path, {
      method: body === undefined ? 'GET' : 'POST',
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
  const data = await response.json().catch(() => null);
  if (!response.ok || !data) {
    throw new ApiError(response.status, data, response.status === 401 ? '登录状态已过期，请重新登录。' : '服务暂时无法响应，请稍后重试。');
  }
  return data;
}

function updateProfile() {
  const { name, email } = state.user || {};
  const label = name || email || '我的空间';
  $('profile-name').textContent = label;
  $('profile-caption').textContent = email || (state.user ? 'ChatGPT 账号' : '未登录');
  $('avatar').textContent = state.user ? (Array.from(label)[0] || '微').toUpperCase() : '微';
  $('sign-out').hidden = !state.user;
  $('settings-account').textContent = email ? '已登录 · ' + email : state.user ? '已使用 ChatGPT 账号登录。' : '请先使用 ChatGPT 账号登录。';
}

async function refresh({ silent = false } = {}) {
  if (state.refreshing || state.writeCount) return;
  state.refreshing = true;
  $('refresh-button').disabled = true;
  const epoch = state.writeEpoch;
  if (!silent || !state.loaded) setSync('loading', '正在同步');
  try {
    if (!state.user) {
      const result = await request('/api/session');
      if (!result.user) throw new ApiError(401, null, '请先登录。');
      state.user = result.user;
      state.codexAvailable = result.codexAvailable === true;
      state.chatProvider = state.codexAvailable ? 'codex' : 'openai';
      updateProfile();
    }
    const result = await request('/api/notes');
    if (epoch !== state.writeEpoch || state.writeCount) return;
    const previous = state.notes;
    const current = new Map((result.notes || []).map((note) => [note.id, note]));
    const changed = previous.size !== current.size || [...current].some(([id, note]) => previous.get(id)?.revision !== note.revision);
    const openChanged = state.noteID && previous.get(state.noteID)?.revision !== current.get(state.noteID)?.revision;
    state.notes = current;
    state.deletedNotes = new Set((result.deleted || []).map(({ id }) => id));
    const firstLoad = !state.loaded;
    state.loaded = true;
    setAuthNotice('');
    $('note-body').disabled = false;
    updateComposer();
    if (changed || firstLoad) renderFeed();
    if (openChanged && $('note-dialog').open) showRemoteDetail();
    setSync('ok', '已同步');
  } catch (error) {
    if (error.status === 401 || error.status === 403) {
      state.user = null;
      state.loaded = false;
      state.notes.clear();
      state.deletedNotes.clear();
      state.apiKey = '';
      state.chatProvider = 'openai';
      state.codexAvailable = false;
      state.composeDraft = null;
      $('note-body').value = '';
      $('search').value = '';
      $('edit-body').value = '';
      $('chat-input').value = '';
      $('import-text').value = '';
      importMode(null);
      resetWereadImport();
      resetFlomoImport(true);
      for (const id of ['settings-dialog', 'import-dialog', 'flomo-dialog']) if ($(id).open) $(id).close();
      if ($('note-dialog').open) closeNote(true);
      $('note-body').disabled = true;
      updateComposer();
      renderFeed();
      updateProfile();
      setAuthNotice('登录状态已失效，请使用 ChatGPT 账号登录。', true);
    } else if (!state.loaded) {
      state.refreshing = false;
      setAuthNotice(error.message);
      renderFeed();
    }
    setSync('error', '同步未完成');
  } finally {
    state.refreshing = false;
    $('refresh-button').disabled = false;
  }
}

function showRemoteDetail() {
  const note = state.notes.get(state.noteID);
  if (!note) {
    setError('detail-error', '这条笔记已在另一端删除。你可以复制尚未保存的内容再关闭。');
    $('detail-actions').hidden = true;
    $('chat-send').disabled = true;
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
    state.deletedNotes.add(data.deleted.id);
  }
}

async function mutate(change) {
  ++state.writeEpoch;
  ++state.writeCount;
  setSync('loading', '正在同步');
  try {
    const data = await request('/api/notes', change);
    acceptVersion(data);
    setSync('ok', '已同步');
    renderFeed();
    return data;
  } catch (error) {
    if (error.status === 409) {
      acceptVersion(error.current);
      renderFeed();
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

function tagsFor(body) {
  const matched = (body || '').matchAll(/(?<![\p{L}\p{N}_])#([\p{L}\p{N}_]+(?:\/[\p{L}\p{N}_]+)*)/gu);
  const seen = new Map();
  for (const [, tag] of matched) if (!seen.has(tag.toLowerCase())) seen.set(tag.toLowerCase(), tag);
  return [...seen.values()];
}

function dayKey(date) {
  return [date.getFullYear(), date.getMonth() + 1, date.getDate()].map((part) => String(part).padStart(2, '0')).join('-');
}

function renderActivity(notes, tagCount) {
  const days = new Map();
  for (const note of notes) {
    const key = dayKey(new Date(note.createdAt));
    days.set(key, (days.get(key) || 0) + 1);
  }
  $('activity-memos').textContent = notes.length;
  $('activity-tags').textContent = tagCount;
  $('activity-days').textContent = days.size;
  const today = new Date();
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
    const count = days.get(key) || 0;
    const square = el('span', 'heatmap-square');
    square.dataset.level = String(Math.min(count, 4));
    square.title = key + ' · ' + count + ' 条笔记';
    if (key === dayKey(today)) square.classList.add('today');
    if (date > today) square.classList.add('future');
    squares.push(square);
    date.setDate(date.getDate() + 1);
  }
  $('heatmap').replaceChildren(...squares);
  $('heatmap-months').replaceChildren(...months);
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

function renderFeed() {
  const all = [...state.notes.values()];
  const counts = { all: all.length, journal: 0, reading: 0 };
  const tags = new Map();
  const byNote = new Map();
  for (const note of all) {
    counts[note.reading ? 'reading' : 'journal']++;
    const noteTags = tagsFor(note.body);
    byNote.set(note.id, noteTags);
    for (const tag of noteTags) {
      const key = tag.toLowerCase();
      const entry = tags.get(key) || { tag, count: 0 };
      entry.count++;
      tags.set(key, entry);
    }
  }
  if (state.filter.startsWith('tag:') && !tags.has(state.filter.slice(4))) state.filter = 'all';
  for (const name of Object.keys(counts)) $('count-' + name).textContent = state.loaded ? counts[name] : '';
  $('tag-section').hidden = tags.size === 0;
  renderActivity(all, tags.size);
  $('tag-list').replaceChildren(...[...tags].sort(([, a], [, b]) => b.count - a.count || a.tag.localeCompare(b.tag, 'zh-CN')).map(([key, entry]) => {
    const button = el('button', 'nav-item');
    button.type = 'button';
    button.dataset.filter = 'tag:' + key;
    button.append(icon('hash'), el('span', '', entry.tag), el('span', 'nav-count', entry.count));
    return button;
  }));
  for (const button of document.querySelectorAll('[data-filter]')) {
    const selected = button.dataset.filter === state.filter;
    button.classList.toggle('active', selected);
    if (selected) button.setAttribute('aria-current', 'page');
    else button.removeAttribute('aria-current');
  }

  const title = filters[state.filter] || ('#' + tags.get(state.filter.slice(4))?.tag);
  $('page-title').textContent = title;
  if (!state.loaded) {
    $('feed-count').hidden = true;
    showEmpty('note', state.refreshing ? '正在打开笔记' : '暂时无法打开笔记', '');
    return;
  }

  const query = $('search').value.trim().toLocaleLowerCase();
  const shown = all.filter((note) => {
    const matchesFilter = state.filter === 'all'
      || (state.filter === 'reading' && note.reading)
      || (state.filter === 'journal' && !note.reading)
      || (state.filter.startsWith('tag:') && byNote.get(note.id).some((tag) => tag.toLowerCase() === state.filter.slice(4)));
    const fields = [note.body, note.reading?.bookTitle, note.reading?.chapter, note.reading?.author];
    return matchesFilter && (!query || fields.some((value) => value?.toLocaleLowerCase().includes(query)));
  }).sort((a, b) => Date.parse(b.createdAt) - Date.parse(a.createdAt));
  $('feed-count').textContent = '共 ' + shown.length + ' 条笔记';
  $('feed-count').hidden = false;

  if (!shown.length) {
    if (query) showEmpty('search', '没有找到相关笔记', '试试其他关键词，或清空搜索。', actionButton('清空搜索', 'clear-search'));
    else if (state.filter === 'reading') showEmpty('book', '还没有读书摘录', '', actionButton('导入微信读书', 'open-import'));
    else showEmpty('note', '从一条笔记开始', '记下一件今天想留住的事。', actionButton('写第一条笔记', 'focus-compose'));
    return;
  }

  const fragment = document.createDocumentFragment();
  for (const note of shown) fragment.append(renderCard(note, byNote.get(note.id)));
  $('note-list').replaceChildren(fragment);
}

function renderCard(note, tags = [], interactive = true, dateFormatter) {
  const card = el(interactive ? 'button' : 'article', 'note-card');
  if (interactive) {
    card.type = 'button';
    card.dataset.openNote = note.id;
  }
  const meta = el('div', 'card-meta');
  if (note.reading) meta.append(labeled(el('span', 'card-source'), 'book', note.reading.bookTitle || '微信读书'));
  if (note.reading?.chapter) meta.append(el('span', '', note.reading.chapter));
  if (note.createdAt) {
    const date = new Date(note.createdAt);
    meta.append(el('span', '', dateFormatter?.format(date) ?? (dayKey(date) + ' ' + dateTime.format(date))));
  }
  if (interactive) {
    const menu = el('span', 'card-ellipsis', '···');
    menu.setAttribute('aria-hidden', 'true');
    meta.append(menu);
  }
  if (meta.childElementCount) card.append(meta);
  card.append(el('div', 'card-body', note.body));

  const bottom = el('div', 'card-bottom');
  for (const tag of tags.slice(0, 3)) bottom.append(el('span', 'card-tag', '#' + tag));
  if (note.turns?.length) bottom.append(labeled(el('span', 'card-chat'), 'chat', Math.floor(note.turns.length / 2) + ' 轮对话'));
  if (bottom.childElementCount) card.append(bottom);
  return card;
}

function updateComposer() {
  $('save-note').disabled = !state.loaded || !($('note-body').value.trim()) || $('composer').dataset.saving === 'true';
}

async function createNote(event) {
  event.preventDefault();
  if ($('save-note').disabled) return;
  const body = $('note-body').value.trim();
  const draft = state.composeDraft;
  const note = draft?.body === body ? draft : { id: crypto.randomUUID(), body, createdAt: new Date().toISOString(), turns: [] };
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
    updateComposer();
  }
}

function finishCompose(note) {
  if ($('note-body').value.trim() === note.body) $('note-body').value = '';
  state.composeDraft = null;
  state.filter = 'all';
  $('search').value = '';
  renderFeed();
  notify('笔记已保存');
}

function openNote(id) {
  if (!state.notes.has(id)) return;
  state.noteID = id;
  state.editRevision = null;
  state.unsavedChat = null;
  $('chat-input').value = '';
  $('chat-send').disabled = false;
  $('delete-confirm').hidden = true;
  $('detail-actions').hidden = false;
  setError('detail-error', '');
  setError('chat-error', '');
  renderDetail();
  $('note-dialog').showModal();
}

function mayCloseNote() {
  const differs = state.editRevision !== null && $('edit-body').value.trim() !== (state.notes.get(state.noteID)?.body || '');
  return !(state.unsavedChat || differs) || confirm('关闭会放弃尚未保存的内容。仍要关闭吗？');
}

function closeNote(force = false) {
  if (!force && !mayCloseNote()) return;
  state.chatRequest?.abort();
  state.chatRequest = null;
  state.noteID = null;
  state.editRevision = null;
  state.unsavedChat = null;
  $('note-dialog').close();
}

function renderDetail({ showChat = true } = {}) {
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
  if (showChat) renderChat(note);
}

function toggleEdit(enabled) {
  const note = state.notes.get(state.noteID);
  if (!note) return;
  state.editRevision = enabled ? note.revision : null;
  $('delete-confirm').hidden = true;
  setError('detail-error', '');
  if (enabled) $('edit-body').value = note.body;
  renderDetail({ showChat: false });
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

function chatCard(turn, index, body, saved = true) {
  const card = el('article', 'chat-turn ' + turn.role);
  card.append(el('p', 'chat-role', turn.role === 'assistant' ? 'AI' : '我'), el('p', 'chat-text', turn.text));
  if (turn.role === 'assistant' && saved) {
    const excerpt = excerptsMarker + turn.text.trim();
    if (body.endsWith(excerpt) || body.includes(excerpt + excerptsMarker)) {
      card.append(labeled(el('p', 'privacy-note'), 'check', '已摘录'));
    } else {
      const button = actionButton('摘录到笔记', 'save-excerpt');
      button.dataset.turn = String(index);
      card.append(button);
    }
  }
  return card;
}

function renderChat(note) {
  const turns = note.turns || [];
  const thread = $('chat-thread');
  $('chat-privacy').textContent = state.chatProvider === 'codex'
    ? '发送时会把当前笔记和近期对话交给私有主机上的 Codex。'
    : '发送时会把当前笔记和近期对话提交给 OpenAI。';
  thread.replaceChildren(...turns.map((turn, index) => chatCard(turn, index, note.body)));
  $('chat-starters').hidden = Boolean(turns.length || state.chatRequest || state.unsavedChat);
  if (state.chatRequest) thread.append(el('p', 'help-text', 'AI 正在回复…'), actionButton('停止', 'cancel-chat'));
  if (state.unsavedChat) {
    thread.append(chatCard(state.unsavedChat.question, 0, '', false), chatCard(state.unsavedChat.reply, 0, '', false), actionButton('重试保存对话', 'retry-chat'));
  }
  $('chat-input').disabled = Boolean(state.chatRequest || state.unsavedChat);
  $('chat-send').disabled = Boolean(state.chatRequest || state.unsavedChat);
}

async function sendChat(event) {
  event.preventDefault();
  const text = $('chat-input').value.trim();
  const note = state.notes.get(state.noteID);
  if (!note || !text || state.chatRequest || state.unsavedChat) return;
  const useCodex = state.chatProvider === 'codex' && state.codexAvailable;
  if (!useCodex && !state.apiKey) {
    setError('chat-error', '请先配置 Codex 中转，或在设置里填写 OpenAI API Key。');
    openSettings();
    return;
  }
  const question = { role: 'user', text };
  const controller = new AbortController();
  state.chatRequest = controller;
  setError('chat-error', '');
  renderChat(note);
  try {
    const data = await request('/api/ai', {
      note: note.body,
      history: [...(note.turns || []).slice(-11), question],
      ...(useCodex ? { provider: 'codex' } : { provider: 'openai', model: state.model, apiKey: state.apiKey }),
    }, controller.signal);
    if (state.noteID !== note.id || controller.signal.aborted) return;
    state.unsavedChat = {
      id: note.id,
      history: note.turns || [],
      question,
      reply: { role: 'assistant', text: data.reply },
    };
    $('chat-input').value = '';
    await persistChat();
  } catch (error) {
    if (error.name !== 'AbortError' && state.noteID === note.id) setError('chat-error', error.message);
  } finally {
    if (state.chatRequest === controller) {
      state.chatRequest = null;
      const current = state.notes.get(state.noteID);
      if (current) renderChat(current);
    }
  }
}

function sameTurns(a, b) {
  return a.length === b.length && a.every((turn, index) => turn.role === b[index].role && turn.text === b[index].text);
}

async function persistChat() {
  const pending = state.unsavedChat;
  const note = state.notes.get(state.noteID);
  if (!pending || pending.saving || !note) return;
  const desired = [...pending.history, pending.question, pending.reply];
  const history = note.turns || [];
  if (sameTurns(history, desired)) {
    state.unsavedChat = null;
    renderDetail();
    return;
  }
  const originalHistory = sameTurns(history, pending.history);
  if (!originalHistory && !pending.acceptedConflict) {
    pending.acceptedConflict = true;
    setError('chat-error', '另一端添加了新对话。再次点击保存，可把这次问答追加到最新对话。');
    renderDetail();
    return;
  }
  pending.saving = true;
  try {
    await mutate({
      id: note.id,
      expectedRevision: note.revision,
      note: notePayload({ ...note, turns: [...history, pending.question, pending.reply] }),
    });
    if (state.unsavedChat === pending) {
      state.unsavedChat = null;
      setError('chat-error', '');
      renderDetail();
    }
  } catch (error) {
    if (state.unsavedChat === pending) {
      setError('chat-error', error.status === 409 ? '另一端更新了这条笔记。回复仍保留，可以重试保存。' : error.message);
      const current = state.notes.get(state.noteID);
      if (current) renderDetail();
    }
  } finally {
    pending.saving = false;
  }
}

function cancelChat() {
  state.chatRequest?.abort();
  state.chatRequest = null;
  const note = state.notes.get(state.noteID);
  if (note) renderChat(note);
}

async function saveExcerpt(turnIndex) {
  const note = state.notes.get(state.noteID);
  const turn = note?.turns?.[turnIndex];
  if (!turn || turn.role !== 'assistant' || state.detailWorking || state.editRevision !== null) {
    if (state.editRevision !== null) setError('chat-error', '请先保存或取消正在编辑的正文。');
    return;
  }
  const addition = excerptsMarker + turn.text.trim();
  if (note.body.endsWith(addition) || note.body.includes(addition + excerptsMarker)) return;
  state.detailWorking = true;
  try {
    await mutate({ id: note.id, expectedRevision: note.revision, note: notePayload({ ...note, body: note.body + addition }) });
    setError('chat-error', '');
    renderDetail();
    notify('已摘录到笔记');
  } catch (error) {
    setError('chat-error', error.status === 409 ? '另一端更新了这条笔记。查看后可重新摘录。' : error.message);
    renderDetail();
  } finally {
    state.detailWorking = false;
  }
}

function updateAISettings() {
  const select = $('chat-provider');
  select.querySelector('option[value=codex]').disabled = !state.codexAvailable;
  $('codex-status').textContent = state.codexAvailable
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
}

function saveSettings(event) {
  event.preventDefault();
  if ($('chat-provider').value === 'codex' && state.codexAvailable) {
    state.chatProvider = 'codex';
    $('settings-dialog').close();
    setError('chat-error', '');
    if (state.notes.has(state.noteID)) renderChat(state.notes.get(state.noteID));
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
  $('openai-key').value = '';
  $('settings-dialog').close();
  if (apiKey) setError('chat-error', '');
  if (state.notes.has(state.noteID)) renderChat(state.notes.get(state.noteID));
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
        $('search').value = '';
        renderFeed();
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
    $('search').value = '';
    renderFeed();
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
  if (items) $('import-preview').replaceChildren(...items.map((note) => renderCard(note, [], false)));
}

async function importNotes(event) {
  event.preventDefault();
  if (!state.loaded || state.importWorking) return;
  setError('import-error', '');
  state.importWorking = true;
  const button = $('import-submit');
  button.disabled = true;
  try {
    if (state.importItems === null) {
      const raw = $('import-text').value.trim();
      if (!raw) {
        setError('import-error', '请粘贴笔记或选择文本文件。');
        return;
      }
      const parsed = await parseWeRead(raw);
      const existing = new Set([...state.notes.values()].filter((note) => note.reading).map(importKey));
      const items = [];
      for (const entry of parsed) {
        const key = importKey(entry);
        if (existing.has(key)) continue;
        existing.add(key);
        items.push({ ...entry, id: crypto.randomUUID(), turns: [] });
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
        importMode(remaining);
        setError('import-error', (imported ? '已导入 ' + imported + ' 条。' : '') + error.message);
        return;
      }
    }
    importMode(null);
    $('import-text').value = '';
    $('import-dialog').close();
    state.filter = 'reading';
    $('search').value = '';
    renderFeed();
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
  event.target.value = '';
  if (!file) return;
  try {
    if (file.size > 2 * 1024 * 1024) throw new Error('文件超过 2 MB，请拆成几个文本文件再导入。');
    const content = await readWeReadFile(file);
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
    renderFeed();
    throw error;
  } finally {
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
  $('search').value = '';
  renderFeed();
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
  $('mobile-toggle').setAttribute('aria-expanded', String(open));
  $('mobile-toggle').setAttribute('aria-label', open ? '关闭导航' : '打开导航');
}

function focusCompose() {
  if (state.loaded) {
    $('note-body').scrollIntoView({ block: 'nearest' });
    $('note-body').focus();
  } else {
    notify('请先登录并完成同步');
  }
}

const actions = {
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
    updateComposer();
  },
  'clear-search': () => { $('search').value = ''; renderFeed(); },
  'edit-note': () => toggleEdit(true),
  'cancel-edit': () => toggleEdit(false),
  'delete-note': () => { $('delete-confirm').hidden = false; },
  'cancel-delete': () => { $('delete-confirm').hidden = true; },
  'confirm-delete': deleteNote,
  'save-excerpt': (button) => saveExcerpt(Number(button.dataset.turn)),
  'cancel-chat': cancelChat,
  'retry-chat': persistChat,
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
  const button = event.target.closest('button');
  if (!$('sidebar').contains(event.target) && !event.target.closest('#mobile-toggle')) sidebar(false);
  if (!button || button.disabled) return;
  if (button.dataset.close) {
    if (button.dataset.close === 'note-dialog') closeNote();
    if (button.dataset.close === 'settings-dialog') $('settings-dialog').close();
    if (button.dataset.close === 'import-dialog' && !state.importWorking && !state.wereadImport?.saving) $('import-dialog').close();
    if (button.dataset.close === 'flomo-dialog' && !state.flomoWorking) $('flomo-dialog').close();
  }
  if (button.dataset.action && actions[button.dataset.action]) actions[button.dataset.action](button);
  if (button.dataset.openNote) openNote(button.dataset.openNote);
  if (button.dataset.filter) {
    state.filter = button.dataset.filter;
    sidebar(false);
    renderFeed();
  }
  if (button.dataset.prompt) {
    $('chat-input').value = button.dataset.prompt;
    $('chat-input').focus();
  }
});

$('note-dialog').addEventListener('cancel', (event) => { event.preventDefault(); closeNote(); });
$('import-dialog').addEventListener('cancel', (event) => {
  if (state.importWorking || state.wereadImport?.saving) event.preventDefault();
});
$('import-dialog').addEventListener('close', resetWereadImport);
$('flomo-dialog').addEventListener('cancel', (event) => { if (state.flomoWorking) event.preventDefault(); });
$('flomo-dialog').addEventListener('close', () => resetFlomoImport(true));
$('settings-dialog').addEventListener('close', () => { $('openai-key').value = ''; });
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
$('chat-form').addEventListener('submit', sendChat);
$('edit-form').addEventListener('submit', submitEdit);
$('composer').addEventListener('submit', createNote);
$('note-body').addEventListener('input', updateComposer);
$('search').addEventListener('input', renderFeed);
$('refresh-button').addEventListener('click', () => refresh());
$('mobile-toggle').addEventListener('click', () => sidebar(!$('sidebar').classList.contains('open')));

document.addEventListener('keydown', (event) => {
  if (event.isComposing) return;
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
window.addEventListener('pagehide', () => { $('weread-key').value = ''; state.wereadImport?.controller?.abort(); state.wereadImport?.batchController?.abort(); });
document.addEventListener('visibilitychange', () => { if (!document.hidden) refresh({ silent: true }); });
setInterval(() => { if (!document.hidden) refresh({ silent: true }); }, 15000);
refresh();
renderFeed();
