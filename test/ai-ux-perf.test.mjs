import assert from 'node:assert/strict';
import { existsSync } from 'node:fs';
import { mkdtemp, rm } from 'node:fs/promises';
import { spawn } from 'node:child_process';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { setTimeout as delay } from 'node:timers/promises';
import { once } from 'node:events';
import { readFile } from 'node:fs/promises';
import { createServer } from 'node:http';
import { DatabaseSync } from 'node:sqlite';
import test from 'node:test';
import { applyMigrations } from '../src/auth.js';
import worker from '../dist/server/index.js';
import * as ux from '../public/ux-helpers.js';

const origin = 'https://weiji.test';
const id = '11111111-1111-4111-8111-111111111111';
const anotherId = '22222222-2222-4222-8222-222222222222';
const createdAt = '2026-11-24T00:00:00.000Z';
const note = (body, noteId = id) => ({ id: noteId, body, createdAt, updatedAt: createdAt, attachments: [], turns: [] });

async function fixture(t) {
  const db = new DatabaseSync(':memory:');
  t.after(() => db.close());
  await applyMigrations(db);
  const env = {
    DB: {
      prepare(sql) {
        const stmt = db.prepare(sql);
        return { bind: (...args) => ({
          all: async () => ({ results: stmt.all(...args) }),
          first: async () => stmt.get(...args) ?? null,
        }) };
      },
    },
  };
  const call = (path, { user = 'A', headers, body, method = body ? 'POST' : 'GET' } = {}, options = {}) =>
    worker.fetch(new Request(origin + path, {
      method,
      headers: {
        ...(user ? { 'oai-authenticated-user-id': user } : {}),
        ...(body ? { Origin: origin, 'Content-Type': 'application/json' } : {}),
        ...headers,
      },
      ...(body ? { body: JSON.stringify(body) } : {}),
    }), { ...env, ...options });
  const put = (user, item, revision = 1) => db.prepare('INSERT OR REPLACE INTO journal_notes VALUES (?, ?, ?, ?)')
    .run(user, item.id, revision, JSON.stringify(item));
  return { db, call, put };
}

test('Notes validators bind the full ordered snapshot and authenticated page identity', async t => {
  const { db, call, put } = await fixture(t);
  put('A', note('cat'));
  put('B', note('dog'));
  put('C', note('cat'));
  const first = await call('/api/notes');
  const etag = first.headers.get('etag');
  const tags = [await call('/api/notes', { user: 'B' }), await call('/api/notes', { user: 'C' })];
  assert.match(etag, /^"notes-[a-f0-9]{32}"$/);
  assert.equal(new Set([etag, ...tags.map(x => x.headers.get('etag'))]).size, 3);
  assert.equal((await first.json()).notes[0].body, 'cat');
  for (const value of [etag, 'W/' + etag, '"miss", W/' + etag, '*']) {
    const response = await call('/api/notes', { headers: { 'If-None-Match': value, 'X-Journal-Account': 'A' } });
    assert.equal(response.status, 304);
    assert.equal(await response.text(), '');
    for (const key of ['ETag', 'Cache-Control', 'Vary']) assert.equal(response.headers.get(key), first.headers.get(key));
  }
  assert.equal(first.headers.get('Cache-Control'), 'private, no-store');
  assert.equal(first.headers.get('Vary'), 'Accept-Encoding');
  for (const [user, status] of [[null, 401], ['B', 403]]) {
    assert.equal((await call('/api/notes', { user, headers: { 'If-None-Match': '*', 'X-Journal-Account': 'A' } })).status, status);
  }
  let previous = etag;
  for (const change of [
    () => put('A', note('dog')), // Same revision and encoded length, different content.
    () => put('A', note('dog'), 2),
    () => put('A', note('new', anotherId)),
    () => db.prepare('UPDATE journal_notes SET payload = NULL, revision = 3 WHERE account = ? AND id = ?').run('A', id),
    () => { db.prepare('DELETE FROM journal_notes WHERE account = ? AND id = ?').run('A', anotherId); put('A', note('cat')); },
  ]) {
    change();
    const response = await call('/api/notes', { headers: { 'If-None-Match': previous } });
    assert.equal(response.status, 200);
    assert.notEqual(response.headers.get('etag'), previous);
    previous = response.headers.get('etag');
  }
  assert.equal(previous, etag); // An identical snapshot has an identical strong validator.
  const page = await call('/', { user: 'abc"<&\'z' });
  assert.match(await page.text(), /<head>\s+<meta name="weiji-user-id" content="abc&quot;&lt;&amp;&#39;z">/);
  assert.equal(page.headers.get('Cache-Control'), 'private, no-store');
  assert.doesNotMatch(await (await call('/', { user: null })).text(), /weiji-user-id/);
  assert.equal(await (await call('/', { method: 'HEAD' })).text(), '');
});

async function upstream(t) {
  const calls = [];
  const models = ['gemini-3-flash', 'gemini-3.5-flash-lite', 'gemini-4-neon-xhigh', 'gpt-6.2-sol', 'gpt-6.2-astra',
    'claude-opus-5-5-high', 'claude-sonnet-5-5-high', 'gpt-4.1-mini', 'other-model', 'custom-thinking-preview', 'gpt-6.99-chat-thinking', 'o3'];
  const server = createServer(async (req, res) => {
    if (req.url === '/v1/models') {
      res.writeHead(200, { 'Content-Type': 'application/json' }).end(JSON.stringify({ data: models.map(id => ({ id })) }));
      return;
    }
    let content = '';
    for await (const chunk of req) content += chunk;
    const body = JSON.parse(content);
    calls.push({ url: req.url, body });
    if (!body.stream) {
      res.writeHead(200, { 'Content-Type': 'application/json' }).end(JSON.stringify({
        reply: 'relay [N1]', choices: [{ message: { content: '答复 [N1]' } }],
      }));
      return;
    }
    res.writeHead(200, { 'Content-Type': 'text/event-stream' });
    const delta = chunk => res.write('data: ' + JSON.stringify({ choices: [{ delta: chunk }] }) + '\n\n');
    delta({ reasoning_content: '内部推理'.repeat(6000) });
    delta({ reasoning_content: ' 这段不应出现' });
    delta({ content: '来自 ' });
    delta({ content: '`[N1]`。' });
    res.end('data: [DONE]\n\n');
  });
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  t.after(() => new Promise(resolve => server.close(resolve)));
  const base = 'http://127.0.0.1:' + server.address().port;
  const env = { OPENAI_BASE_URL: base + '/v1', OPENAI_API_KEY: 'test-gateway-token', OPENAI_MODEL: 'gemini-3-flash' };
  const fetchOriginal = globalThis.fetch;
  t.mock.method(globalThis, 'fetch', (url, options) => {
    const target = new URL(url);
    if (['api.openai.com', 'relay.test'].includes(target.hostname)) return fetchOriginal(base + target.pathname, options);
    return fetchOriginal(url, options);
  });
  return { env, calls };
}

async function streamEvents(response) {
  assert.equal(response.status, 200);
  assert.match(response.headers.get('Content-Type'), /^text\/event-stream/);
  return (await response.text()).trim().split('\n\n').filter(frame => frame.startsWith('event: '))
    .map(frame => {
      const [name, data] = frame.split('\n');
      return [name.slice(7), JSON.parse(data.slice(6))];
    });
}

test('Model catalog and chat stream honor capacity and preserve only completed steps', async t => {
  const { call, db, put } = await fixture(t);
  const { env, calls } = await upstream(t);
  const list = await (await call('/api/ai/models', {}, env)).json();
  assert.equal(list.available, true);
  assert.equal(list.defaultModel, 'gemini-3-flash');
  assert.equal(list.source, 'gateway');
  assert.deepEqual(list.modelMeta.map(model => model.id), list.models);
  const meta = id => list.modelMeta.find(item => item.id === id);
  assert.deepEqual(meta('gemini-3-flash'), { id: 'gemini-3-flash', label: 'Gemini 3 Flash', vendor: 'gemini',
    thinking: true, efforts: ['low', 'medium', 'high'], fixedEffort: null, defaultEffort: null });
  assert.deepEqual(meta('gemini-4-neon-xhigh'), { id: 'gemini-4-neon-xhigh', label: 'Gemini 4 Neon', vendor: 'gemini',
    thinking: true, efforts: [], fixedEffort: 'xhigh', defaultEffort: 'xhigh' });
  assert.equal(meta('gpt-6.2-sol').label, 'GPT-6.2 Sol');
  assert.deepEqual(meta('gpt-6.2-astra').efforts, ['low', 'medium', 'high', 'xhigh']);
  assert.equal(meta('gpt-6.2-astra').vendor, 'openai');
  assert.equal(meta('claude-opus-5-5-high').label, 'Claude Opus 5.5');
  assert.equal(meta('claude-sonnet-5-5-high').vendor, 'claude');
  assert.equal(meta('gpt-4.1-mini').thinking, false);
  assert.equal(meta('other-model').vendor, 'other');
  assert.equal(meta('custom-thinking-preview').thinking, false);
  assert.deepEqual(meta('custom-thinking-preview').efforts, []);
  assert.equal(meta('gpt-6.99-chat-thinking').thinking, false);
  assert.deepEqual(meta('gpt-6.99-chat-thinking').efforts, []);
  assert.deepEqual(meta('o3').efforts, ['low', 'medium', 'high']);

  put('A', note('相关的历史资料'));
  db.prepare('INSERT INTO ai_profile (account, content, enabled, note_count, updated_at) VALUES (?, ?, 1, 1, ?)')
    .run('A', '可供检索的画像', createdAt);
  const base = { message: '请概括', provider: 'codex', referencedNoteIds: [id], useAllNotes: false };
  const chat = (body, options = env) => call('/api/ai/chat', { body: { ...base, ...body } }, options);
  for (const value of ['extreme', 1, {}, false, 'HIGH']) {
    const bad = await chat({ stream: true, reasoningEffort: value });
    assert.equal(bad.status, 400);
    assert.match(bad.headers.get('Content-Type'), /^application\/json/);
    assert.equal((await bad.json()).error, '思考档位参数无效。');
  }
  assert.equal(calls.length, 0);
  const initial = { stream: true, reasoningEffort: 'high', clientRequestId: 'initial' };
  const events = await streamEvents(await chat(initial));
  assert.deepEqual(events.filter(([name]) => name !== 'status').map(([name, data]) =>
    name === 'step' ? data.id + ':' + data.status : name),
  ['retrieve:running', 'retrieve:done', 'profile:done', 'citations', 'think:running', 'reasoning', 'delta', 'think:done', 'delta', 'done']);
  assert.equal(events.find(([name]) => name === 'reasoning')[1].text.length, 20_000);
  assert.equal(events.find(([name]) => name === 'citations')[1].citations[0].noteId, id);
  assert.equal(calls[0].body.reasoning_effort, 'high');
  assert.match(calls[0].body.messages[0].content, /不要用反引号或代码块/);
  const { session, reply } = events.at(-1)[1];
  assert.equal(reply, '来自 `[N1]`。');
  const path = '/api/ai/sessions/' + session.id;
  const reread = (await (await call(path)).json()).session;
  const steps = reread.turns.at(-1).steps;
  assert.deepEqual(steps.map(step => [step.id, step.status]), [['retrieve', 'done'], ['profile', 'done'], ['think', 'done']]);
  assert.equal(steps[0].items[0].noteId, id);
  assert.ok(Number.isInteger(steps[2].durationMs));
  assert.doesNotMatch(JSON.stringify(reread), /内部推理/);

  const replay = await streamEvents(await chat(initial));
  assert.deepEqual(replay.map(([name]) => name), ['done']);
  assert.equal(replay[0][1].deduplicated, true);
  assert.equal(calls.length, 1);
  const continuation = await chat({ sessionId: session.id, expectedVersion: session.version, reasoningEffort: null });
  assert.equal(continuation.status, 200);
  assert.ok(calls[1].body.messages.some(message => message.role === 'assistant' && message.content === reply));
  assert.doesNotMatch(JSON.stringify(calls[1].body), /reasoning_content|"steps"|内部推理/);
  db.prepare('UPDATE ai_sessions SET turns_json = ? WHERE id = ?').run(JSON.stringify([
    { role: 'user', text: '旧问题' }, { role: 'assistant', text: '旧回答' },
  ]), session.id);
  assert.equal((await (await call(path)).json()).session.turns.at(-1).steps, undefined);
  assert.equal((await chat({ sessionId: session.id })).status, 200);
  assert.ok(calls.at(-1).body.messages.some(message => message.content === '旧回答'));
  for (const [body, options] of [
    [{ model: 'gemini-4-neon-xhigh', reasoningEffort: 'high' }, env],
    [{ model: 'other-model', reasoningEffort: 'high' }, env],
    [{ model: 'custom-thinking-preview', reasoningEffort: 'high' }, env],
    [{ model: 'unlisted-thinking-model', reasoningEffort: 'high' }, env],
    [{ model: 'gpt-6.99-chat-thinking', reasoningEffort: 'high' }, env],
    [{ model: 'gemini-3-flash', reasoningEffort: 'xhigh' }, env],
    [{ provider: 'openai', model: 'gpt-4.1-mini', apiKey: 'test-direct-key', reasoningEffort: 'high', useGateway: true }, env],
    [{ provider: 'openai', model: 'gpt-6.2-sol', apiKey: 'test-direct-key', reasoningEffort: 'high', useGateway: true }, env],
    [{ reasoningEffort: 'high' }, { CODEX_RELAY_URL: 'https://relay.test/journal/reply', CODEX_RELAY_TOKEN: 'a'.repeat(32) }],
  ]) {
    assert.equal((await chat(body, options)).status, 200);
    assert.equal(Object.hasOwn(calls.at(-1).body, 'reasoning_effort'), false);
  }
  assert.deepEqual(Object.keys(calls.at(-1).body), ['note', 'history']);
});

class Element {
  constructor(tagName, ownerDocument) {
    Object.assign(this, { tagName, ownerDocument, childNodes: [], dataset: {} });
  }
  get textContent() { return this.childNodes.map(child => typeof child === 'string' ? child : child.textContent).join(''); }
  set textContent(text) { this.replaceChildren(text); }
  append(...children) {
    for (const child of children) {
      if (child instanceof Element) {
        child.remove();
        child.parent = this;
      }
      this.childNodes.push(child);
    }
  }
  remove() {
    if (!this.parent) return;
    this.parent.childNodes.splice(this.parent.childNodes.indexOf(this), 1);
    this.parent = null;
  }
  before(...children) {
    for (const child of children) {
      child.remove();
      child.parent = this.parent;
      this.parent.childNodes.splice(this.parent.childNodes.indexOf(this), 0, child);
    }
  }
  replaceChildren(...children) {
    for (const child of this.childNodes) if (child instanceof Element) child.parent = null;
    this.childNodes = [];
    this.append(...children);
  }
  descendants() {
    return this.childNodes.filter(child => child instanceof Element).flatMap(node => [node, ...node.descendants()]);
  }
}
const doc = { createElement: tag => new Element(tag, doc) };

test('Web named imports exist and citation-only code renders clickable references', async () => {
  const app = await readFile(new URL('../public/app.js', import.meta.url), 'utf8');
  assert.ok(app.match(/import\s*\{([^}]+)\}\s*from\s*['"]\.\/ux-helpers\.js['"]/));
  const [, imports] = /import\s*\{([^}]+)\}\s*from\s*['"]\.\/ux-helpers\.js['"]/.exec(app);
  for (const item of imports.split(',').map(s => s.trim())) assert.ok(Object.hasOwn(ux, item.split(/\s+as\s+/)[0]), item);
  const citations = ['N1', 'N2', 'N3'].map((ref, i) => ({ ref, noteId: 'note-' + i }));
  const body = doc.createElement('div');
  ux.renderSafeMarkdown(body, '`[N1]` / `[N1]` `[N2]` / `[N1]、[N2]` / [N3] / `const a = 1` / `[N8]`', citations);
  assert.deepEqual(body.descendants().filter(node => node.className === 'citation-chip').map(node => node.dataset.citeNoteId),
    ['note-0', 'note-0', 'note-1', 'note-0', 'note-1', 'note-2']);
  assert.deepEqual(body.descendants().filter(node => node.tagName === 'code').map(node => node.textContent), ['const a = 1', '[N8]']);
  const stream = doc.createElement('div');
  const start = '第一段 `[N1]`\n\n';
  ux.updateStreamingMarkdown(stream, start + '第二', citations);
  const frozen = stream.childNodes[0];
  const citation = frozen.descendants().find(node => node.className === 'citation-chip');
  ux.updateStreamingMarkdown(stream, start + '第二段\n\n```js\nconst a = 1\n\n', citations);
  assert.strictEqual(stream.childNodes[0], frozen);
  assert.equal(citation.parent, frozen);
  const fence = '```js\nconst a = 1\n\n';
  assert.deepEqual(ux.splitStreamingMarkdown(start + fence), { stableBlocks: [start.trim()], tail: fence });
  ux.updateStreamingMarkdown(stream, start + '第二段\n\n' + fence + '```\n\n后续', citations);
  assert.strictEqual(stream.childNodes[0], frozen);
  assert.deepEqual(stream.descendants().filter(node => node.tagName === 'code').map(node => node.textContent), ['const a = 1\n']);
});

test('Connect signout is inert until bound, then broadcasts, deletes only current account cache and navigates', async t => {
  const { call } = await fixture(t);
  for (const mode of ['oauth', 'chatgpt']) {
    const html = await (await call('/connect', { headers: { 'oai-authenticated-auth-mode': mode } })).text();
    assert.match(html, /<script type="module" src="\/ux-helpers.js"><\/script>/);
    assert.match(html, /<meta name="weiji-user-id" content="A">/);
    const oauth = mode === 'oauth';
    if (oauth) assert.match(html, /<form method="POST" action="\/api\/auth\/logout" data-connect-logout="oauth" data-user-id="A"><button type="submit" disabled>/);
    else {
      const link = html.match(/<a data-connect-logout="chatgpt"[^>]+>/)[0];
      assert.match(link, /data-user-id="A"/);
      assert.match(link, /aria-disabled="true" tabindex="-1"/);
      assert.doesNotMatch(link, /\shref=/);
    }
    const events = [];
    const snapshots = new Map([['A', { userId: 'A' }], ['B', { userId: 'B' }]]);
    const button = { disabled: true };
    let handler;
    let finish;
    const signoutHref = '/signout-with-chatgpt?return_to=%2Fconnect';
    const control = {
      dataset: { connectLogout: mode, signoutHref, userId: 'A' },
      querySelector: () => button,
      addEventListener(name, fn) { if (name === (oauth ? 'submit' : 'click')) handler = fn; },
      removeAttribute(name) { events.push('removed:' + name); },
      submit() { events.push('navigated'); },
    };
    const win = {
      localStorage: { setItem(key, value) {
        assert.equal(key, 'weiji_auth_event');
        const payload = JSON.parse(value);
        assert.equal(payload.type, 'logout');
        assert.equal(payload.userId, 'A');
        events.push('broadcast');
      } },
      indexedDB: { open(name) {
        assert.equal(name, 'weiji-notes-cache');
        const open = { result: {
          transaction(store, mode) {
            assert.equal(store, 'accounts');
            assert.equal(mode, 'readwrite');
            const tx = { objectStore: () => ({
              delete(key) {
                assert.equal(key, 'A');
                events.push('deleting:' + key);
                finish = () => { snapshots.delete(key); events.push('deleted:' + key); tx.oncomplete(); };
                return {};
              },
              clear() { assert.fail('must delete only the signing-out account, not clear all accounts'); },
            }) };
            return tx;
          },
          close() {},
        } };
        queueMicrotask(() => open.onsuccess());
        return open;
      } },
      top: { location: { set href(value) { assert.equal(value, signoutHref); events.push('navigated'); } } },
    };
    ux.bindConnectLogout({ querySelector: selector => selector === '[data-connect-logout]' ? control : null }, win);
    if (oauth) assert.equal(button.disabled, false);
    else {
      assert.equal(control.href, signoutHref);
      assert.deepEqual(events.splice(0), ['removed:aria-disabled', 'removed:tabindex']);
    }
    const handled = handler({ preventDefault() { events.push('prevented'); } });
    assert.deepEqual(events, ['prevented', 'broadcast']);
    await new Promise(resolve => setImmediate(resolve));
    assert.deepEqual(events, ['prevented', 'broadcast', 'deleting:A']);
    finish();
    await handled;
    assert.deepEqual(events, ['prevented', 'broadcast', 'deleting:A', 'deleted:A', 'navigated']);
    assert.equal(snapshots.has('A'), false);
    assert.equal(snapshots.has('B'), true);
  }
  const warnings = [];
  const brokenWin = {
    localStorage: { setItem() {} },
    console: { warn: msg => warnings.push(msg) },
    indexedDB: { open() {
      const req = {};
      queueMicrotask(() => req.onerror?.());
      return req;
    } },
  };
  assert.equal(await ux.clearWeijiCacheDB('A', brokenWin), false);
  let failHandler;
  let navigated = false;
  const failControl = {
    dataset: { connectLogout: 'oauth', userId: 'A' },
    querySelector: () => ({ disabled: true }),
    addEventListener(name, fn) { if (name === 'submit') failHandler = fn; },
    submit() { navigated = true; },
  };
  ux.bindConnectLogout({ querySelector: selector => selector === '[data-connect-logout]' ? failControl : null }, brokenWin);
  await failHandler({ preventDefault() {} });
  assert.equal(navigated, true);
  assert.equal(warnings.length, 1);
});

const chrome = process.env.WEIJI_TEST_CHROME || [
  '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
  '/usr/bin/chromium', '/usr/bin/google-chrome',
].find(existsSync);

async function until(fn, description, attempts = 120) {
  for (let i = 0; i < attempts; i++) {
    const value = await fn();
    if (value) return value;
    await delay(25);
  }
  assert.fail('Timed out: ' + description);
}

async function headless(t) {
  const dir = await mkdtemp(join(tmpdir(), 'weiji-chrome-'));
  const child = spawn(chrome, ['--headless', '--disable-gpu', '--disable-dev-shm-usage', '--no-first-run',
    ...(process.getuid?.() === 0 ? ['--no-sandbox'] : []),
    '--remote-debugging-port=0', '--user-data-dir=' + dir, 'about:blank'], { stdio: 'ignore' });
  const sockets = [];
  t.after(async () => {
    for (const socket of sockets) socket.close();
    if (child.exitCode === null && child.signalCode === null) {
      const exited = once(child, 'exit');
      child.kill();
      await exited;
    }
    await rm(dir, { force: true, recursive: true, maxRetries: 3 });
  });
  const port = await until(async () => (await readFile(join(dir, 'DevToolsActivePort'), 'utf8').catch(() => '')).split('\n')[0],
    'Chromium CDP port', 400);
  const cdp = 'http://127.0.0.1:' + port;
  return async () => {
    const page = await (await fetch(cdp + '/json/new?about:blank', { method: 'PUT' })).json();
    const socket = new WebSocket(page.webSocketDebuggerUrl);
    sockets.push(socket);
    await once(socket, 'open');
    let sequence = 0;
    const calls = new Map();
    socket.addEventListener('message', ({ data }) => {
      const msg = JSON.parse(data);
      if (!calls.has(msg.id)) return;
      const { resolve, reject } = calls.get(msg.id);
      calls.delete(msg.id);
      if (msg.error) reject(new Error(JSON.stringify(msg.error)));
      else resolve(msg.result);
    });
    const send = (method, params) => new Promise((resolve, reject) => {
      const id = ++sequence;
      calls.set(id, { resolve, reject });
      socket.send(JSON.stringify({ id, method, params }));
    });
    await send('Page.enable');
    const evaluate = async expression => {
      const { result, exceptionDetails } = await send('Runtime.evaluate', { expression, awaitPromise: true, returnByValue: true });
      if (exceptionDetails) throw new Error(result.description ?? exceptionDetails.text);
      return result.value;
    };
    return { send, evaluate, navigate: url => send('Page.navigate', { url }) };
  };
}

test('Chromium gates real IndexedDB snapshots, holds bfcache blank, and switches chat sessions immediately',
  { timeout: 45_000 }, async t => {
    assert.ok(chrome, 'Chromium binary is required (set WEIJI_TEST_CHROME)');
    const tab = await headless(t);
    const bodyA = 'A-private-note-body-314';
    const bodyB = 'B-private-note-body-271';
    const deleted = [{ id: '1cf33953-ea68-85d9-bc4b-b1eeb45b9231', revision: 4 }];
    const cached = { userId: 'A', etag: '"cached-a"', notes: [{ ...note(bodyA), revision: 1 }], deleted, savedAt: 1 };
    const sessionEntries = [id, anotherId].map((sessionId, i) => ({
      id: sessionId, title: '对话 ' + i, version: 1, origin: 'global', createdAt,
      turns: [{ role: 'assistant', text: '测试答案 ' + i }],
    }));
    const sessions = [];
    const notes = [];
    const noteWrites = [];
    const history = [];
    const chats = [];
    const connect = [];
    const logouts = [];
    let holdConnectScript = false;
    let pageAccount = 'A';
    const sessionData = user => ({ user: { id: user, name: user }, authMode: 'oauth', codexAvailable: true, codexMode: 'gateway' });
    const json = (res, value, status = 200) => res.writeHead(status, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' }).end(JSON.stringify(value));
    const web = createServer(async (req, res) => {
      if (req.url === '/test-seed') return res.writeHead(200, { 'Content-Type': 'text/html' }).end('<!doctype html><title>Test fixture</title>');
      if (req.url === '/api/session') return void sessions.push((user, status) => json(res, sessionData(user), status));
      if (req.url === '/api/notes' && req.method === 'POST') {
        let raw = '';
        for await (const chunk of req) raw += chunk;
        return void noteWrites.push({ headers: req.headers, body: JSON.parse(raw), res });
      }
      if (req.url === '/api/notes') return void notes.push({ headers: req.headers, res });
      if (req.url === '/api/auth/logout') return void logouts.push(res);
      if (req.url === '/api/ai/models') return json(res, {
        models: ['gemini-3-flash', 'gpt-6.2-sol'], defaultModel: 'gemini-3-flash',
        modelMeta: [
          { id: 'gemini-3-flash', vendor: 'gemini', label: 'Gemini 3 Flash', thinking: true, efforts: ['low', 'medium', 'high'] },
          { id: 'gpt-6.2-sol', vendor: 'openai', label: 'GPT-6.2 Sol', thinking: true, efforts: ['low', 'medium', 'high', 'xhigh'] },
        ],
      });
      if (req.url === '/api/ai/chat') {
        let raw = '';
        for await (const chunk of req) raw += chunk;
        return void chats.push({ body: JSON.parse(raw), res });
      }
      if (req.url.startsWith('/api/ai/sessions?sourceNoteId=')) return json(res, { session: null });
      if (req.url === '/api/ai/sessions') return json(res, { sessions: sessionEntries.map(({ turns, ...summary }) => summary) });
      if (req.url.startsWith('/api/ai/sessions/')) {
        return void history.push(() => json(res, { session: sessionEntries.find(x => req.url.endsWith(x.id)) }));
      }
      const serve = async () => {
        const response = await worker.fetch(new Request(origin + req.url, {
          headers: { 'oai-authenticated-user-id': pageAccount, 'oai-authenticated-auth-mode': 'oauth' },
        }), {});
        res.writeHead(response.status, Object.fromEntries(response.headers)).end(await response.text());
      };
      if (req.url === '/ux-helpers.js' && holdConnectScript) connect.push(serve);
      else await serve();
    });
    web.listen(0, '127.0.0.1');
    await once(web, 'listening');
    t.after(() => new Promise(resolve => { web.closeAllConnections(); web.close(resolve); }));
    const local = 'http://127.0.0.1:' + web.address().port;
    const receive = (queue, label) => until(() => queue.shift(), label);
    const found = (page, text) => page.evaluate(`document.body?.textContent.includes(${JSON.stringify(text)})`);
    const skeleton = page => page.evaluate("document.getElementById('sync-skeleton')?.hidden === false");
    const seedPage = async () => {
      const page = await tab();
      await page.send('Page.addScriptToEvaluateOnNewDocument', { source: `
        window.firstFrameLeaks = [];
        // Browser tab activation can trigger unrelated periodic refreshes during this race.
        window.addEventListener('focus', event => event.stopImmediatePropagation(), true);
        document.addEventListener('visibilitychange', event => {
          if (event.isTrusted) event.stopImmediatePropagation();
        }, true);
        window.addEventListener('error', event => firstFrameLeaks.push(event.message));
        new MutationObserver(records => {
          if (document.body?.classList.contains('auth-checking') &&
              document.body.textContent.includes(${JSON.stringify(bodyA)})) firstFrameLeaks.push('A');
        }).observe(document, { subtree: true, childList: true });
      ` });
      await page.navigate(local + '/test-seed');
      await until(() => page.evaluate("location.pathname === '/test-seed' && document.readyState === 'complete'"), 'seed origin');
      await page.evaluate(`import('/ux-helpers.js').then(({ notesCacheTransaction }) =>
        notesCacheTransaction('readwrite', store => store.put(${JSON.stringify(cached)})))`);
      return page;
    };
    const conditional = async () => {
      const entry = await receive(notes, 'conditional request');
      assert.equal(entry.headers['x-journal-account'], 'A');
      assert.equal(entry.headers['if-none-match'], cached.etag);
      return entry.res;
    };
    const page = await seedPage();
    await page.navigate(local + '/');
    const session = await receive(sessions, 'first session request');
    const firstNotes = await conditional();
    firstNotes.writeHead(304, { ETag: cached.etag }).end();
    assert.equal(await skeleton(page), true);
    assert.equal(await found(page, bodyA), false);
    session('A');
    await until(() => found(page, bodyA), 'verified cached note');
    const diskDeleted = await page.evaluate("import('/ux-helpers.js').then(m => m.notesCacheTransaction('readonly', s => s.get('A'))).then(s => s.deleted)");
    assert.deepEqual(diskDeleted, deleted);

    await until(() => page.evaluate("document.getElementById('sync-state').dataset.status === 'ok'"), 'initial 304 applied');
    await page.evaluate(`
      document.querySelector('[data-action=open-flomo-import]').click();
      const files = new DataTransfer();
      files.items.add(new File(['<div class="memo" data-memo-id="tombstone-case"><div class="time">2026-11-24 12:00:00</div><div class="content">已删除的导入记录</div></div>'], 'notes.html', { type: 'text/html' }));
      document.getElementById('flomo-file').files = files.files;
      document.getElementById('flomo-form').requestSubmit();
    `);
    await until(() => found(page, '已存在或此前删除 1 条'), '304 kept the tombstone for real import deduplication');
    await page.evaluate("document.querySelector('[data-close=flomo-dialog]').click()");
    await page.evaluate("document.dispatchEvent(new Event('visibilitychange')); true");
    assert.equal(await found(page, bodyA), true);
    (await conditional()).writeHead(304, { ETag: cached.etag }).end();
    const composeDraft = '未提交的私密草稿-314';
    await page.evaluate(`(() => {
      const input = document.getElementById('note-body');
      input.value = ${JSON.stringify(composeDraft)};
      input.dispatchEvent(new InputEvent('input', { bubbles: true }));
    })()`);
    await page.evaluate("window.dispatchEvent(new PageTransitionEvent('pagehide', { persisted: true })); true");
    assert.equal(await found(page, bodyA), false);
    assert.equal(await page.evaluate("document.getElementById('note-body').value"), '');
    assert.equal(await skeleton(page), true);
    await page.evaluate("window.dispatchEvent(new PageTransitionEvent('pageshow', { persisted: true })); true");
    const backSession = await receive(sessions, 'bfcache revalidation');
    const backNotes = await conditional();
    assert.equal(await found(page, bodyA), false);
    assert.equal(await page.evaluate("document.getElementById('note-body').value"), '');
    backSession('A');
    await until(() => found(page, bodyA), 'cache rendered while full notes response is still held');
    assert.equal(await page.evaluate("document.getElementById('note-body').value"), composeDraft);
    await page.evaluate("document.getElementById('note-body').value = ''; true");
    backNotes.writeHead(304, { ETag: cached.etag }).end();
    assert.deepEqual(await page.evaluate('firstFrameLeaks'), []);

    const sameAccountTab = await tab();
    await sameAccountTab.navigate(local + '/');
    (await receive(sessions, 'same-account second tab session'))('A');
    (await conditional()).writeHead(304, { ETag: cached.etag }).end();
    await until(() => found(sameAccountTab, bodyA), 'same-account second tab rendered');
    assert.equal(await found(page, bodyA), true);
    assert.equal(await page.evaluate("document.getElementById('sign-in').hidden"), true);
    await page.send('Page.bringToFront');

    const concurrentBody = '同账号并发保存-777';
    await page.evaluate(`(() => {
      const input = document.getElementById('note-body');
      input.value = ${JSON.stringify(concurrentBody)};
      input.dispatchEvent(new InputEvent('input', { bubbles: true }));
      document.getElementById('composer').requestSubmit();
    })()`);
    const write = await receive(noteWrites, 'in-flight note save during same-account stamp update');
    // Simulate another same-account tab writing localStorage before this tab handles storage callback.
    await page.evaluate(`localStorage.setItem('weiji_auth_event', JSON.stringify({ type: 'session', userId: 'A', at: Date.now(), nonce: 99999 })); true`);
    const savedId = write.body.note.id;
    json(write.res, { note: { ...note(concurrentBody, savedId), revision: 1 } });
    await until(() => found(page, concurrentBody), 'concurrent same-account save stayed authenticated');
    assert.equal(await page.evaluate("document.getElementById('sign-in').hidden"), true);
    await until(() => page.evaluate(`import('/ux-helpers.js').then(m => m.notesCacheTransaction('readonly', s => s.get('A'))).then(s => Boolean(s?.notes?.some(n => n.body === ${JSON.stringify(concurrentBody)})))`),
      'concurrent same-account save persisted to IndexedDB');
    // Restore original ETag fixture for subsequent latePage/connect checks.
    await page.evaluate(`import('/ux-helpers.js').then(m => m.notesCacheTransaction('readwrite', s => s.put(${JSON.stringify(cached)})))`);

    await page.evaluate("document.querySelector('[data-action=open-ai-chat]').click()");
    await until(() => page.evaluate("document.querySelectorAll('[data-session-id]').length >= 4"), 'history list');
    const select = i => page.evaluate(`
      document.querySelector('[data-action="ai-select-session"][data-session-id="${sessionEntries[i].id}"]').click();
      [document.querySelector('[data-action="ai-select-session"][aria-current="true"]').dataset.sessionId,
        !!document.querySelector('#ai-chat-thread .ai-session-skeleton'),
        document.querySelector('#ai-chat-thread').textContent]`);
    for (const i of [0, 1]) {
      const state = await select(i);
      assert.deepEqual(state, [sessionEntries[i].id, true, '']);
      (await receive(history, 'history request'))();
      await until(() => found(page, '测试答案 ' + i), 'loaded history');
    }
    assert.deepEqual(await select(0), [id, false, '测试答案 0']);
    (await receive(history, 'background history refresh'))();

    await until(() => found(page, 'Gemini 3 Flash'), 'model selector loaded');
    await page.evaluate(`
      document.getElementById('ai-model-toggle').click();
      const search = document.getElementById('ai-model-search');
      search.value = 'gpt';
      search.dispatchEvent(new InputEvent('input', { bubbles: true }));
      search.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true }));
      document.getElementById('ai-effort-toggle').click();
      [...document.querySelectorAll('#ai-effort-popover button')].find(b => b.textContent === '极高').click();
      document.getElementById('ai-chat-input').value = '引用一条笔记';
      document.getElementById('ai-chat-form').requestSubmit();
    `);
    const chat = await receive(chats, 'chat from custom picker');
    assert.equal(chat.body.model, 'gpt-6.2-sol');
    assert.equal(chat.body.reasoningEffort, 'xhigh');
    assert.equal(await page.evaluate("localStorage.getItem('weiji.reasoningEffort')"), 'xhigh');
    const citation = { ref: 'N1', noteId: id, excerpt: bodyA, createdAt };
    const step = { id: 'think', kind: 'think', status: 'running', label: '思考与生成' };
    const stream = chat.res.writeHead(200, { 'Content-Type': 'text/event-stream' });
    const event = (name, data) => stream.write('event: ' + name + '\ndata: ' + JSON.stringify(data) + '\n\n');
    event('citations', { citations: [citation] });
    event('step', step);
    event('reasoning', { text: '第一段推理：' });
    await until(() => page.evaluate(`(() => {
      const el = document.querySelector('#ai-pending-reply details.ai-reasoning');
      return Boolean(el && !el.hidden);
    })()`), 'live reasoning disclosure visible before first delta');
    assert.equal(await found(page, '原笔记'), false);
    await page.evaluate("document.querySelector('#ai-pending-reply details.ai-reasoning summary').click()");
    event('reasoning', { text: '第二段推理' });
    await until(() => page.evaluate(`(() => {
      const el = document.querySelector('#ai-pending-reply details.ai-reasoning');
      const text = el?.querySelector('.ai-reasoning-text')?.textContent ?? '';
      return Boolean(el?.open && text.includes('第一段推理：第二段推理'));
    })()`), 'two live reasoning chunks concatenated and visible before first delta');
    assert.equal(await found(page, '原笔记'), false);
    event('delta', { text: '原笔记 `[N1]`\n\n' });
    await until(() => page.evaluate("!!document.querySelector('#ai-pending-reply .citation-chip')"), 'early citation rendered');
    const detail = await page.evaluate(`
      window.frozenReply = document.querySelector('#ai-pending-reply p');
      frozenReply.querySelector('button').click();
      [document.getElementById('note-dialog').open, document.getElementById('detail-body').textContent]
    `);
    assert.deepEqual(detail, [true, bodyA]);
    await page.evaluate("document.querySelector('[data-close=note-dialog]').click()");
    event('delta', { text: '后续' });
    await until(() => found(page, '后续'), 'stream tail painted');
    assert.equal(await page.evaluate("window.frozenReply === document.querySelector('#ai-pending-reply p')"), true);
    const doneStep = { ...step, status: 'done', durationMs: 20 };
    event('step', doneStep);
    event('done', { session: { ...sessionEntries[0], version: 2, turns: [...sessionEntries[0].turns,
      { role: 'user', text: chat.body.message }, { role: 'assistant', text: '原笔记 `[N1]`\n\n后续', citations: [citation], steps: [doneStep] }] } });
    stream.end();
    await until(() => page.evaluate("!document.getElementById('ai-pending-reply')"), 'done painted');
    assert.equal(await page.evaluate("document.querySelector('#ai-chat-thread details.ai-steps').open"), false);
    assert.equal(await page.evaluate("window.frozenReply.isConnected"), true);

    const cachedB = { userId: 'B', etag: '"cached-b"', notes: [{ ...note(bodyB), revision: 1 }], deleted: [], savedAt: 1 };
    await page.evaluate(`import('/ux-helpers.js').then(({ notesCacheTransaction }) =>
      notesCacheTransaction('readwrite', store => store.put(${JSON.stringify(cachedB)})))`);
    const latePage = await tab();
    await latePage.navigate(local + '/');
    const lateSession = await receive(sessions, 'late session');
    const lateNotes = await conditional();
    assert.equal(await skeleton(latePage), true);
    const connectPage = await tab();
    holdConnectScript = true;
    await connectPage.navigate(local + '/connect');
    const unblock = await receive(connect, 'connect helper held');
    assert.equal(await connectPage.evaluate("document.querySelector('[data-connect-logout] button').disabled"), true);
    holdConnectScript = false;
    await unblock();
    await until(() => connectPage.evaluate("!document.querySelector('[data-connect-logout] button').disabled"), 'connect logout bound');
    await connectPage.evaluate("document.querySelector('[data-connect-logout] button').click()");
    const logout = await receive(logouts, 'connect logout request');
    await until(async () => !await found(page, '测试答案 0'), 'other tab revokes private conversation');
    lateSession('A');
    json(lateNotes, { notes: [{ ...note(bodyA), revision: 2 }], deleted });
    assert.equal(await found(latePage, bodyA), false);
    assert.deepEqual(await page.evaluate('firstFrameLeaks'), []);
    assert.equal(await page.evaluate("import('/ux-helpers.js').then(m => m.notesCacheTransaction('readonly', s => s.get('A'))).then(Boolean)"), false);
    assert.equal(await page.evaluate("import('/ux-helpers.js').then(m => m.notesCacheTransaction('readonly', s => s.get('B'))).then(Boolean)"), true);
    json(logout, { ok: true });

    const hiddenTabA = await seedPage();
    pageAccount = 'A';
    await hiddenTabA.navigate(local + '/');
    (await receive(sessions, 'tabA session'))('A');
    (await conditional()).writeHead(304, { ETag: cached.etag }).end();
    await until(() => found(hiddenTabA, bodyA), 'tabA loaded');
    await hiddenTabA.evaluate("document.getElementById('note-body').value = 'A的未提交草稿'; true");
    const activeTabB = await tab();
    pageAccount = 'B';
    await activeTabB.navigate(local + '/');
    (await receive(sessions, 'tabB session confirms B without logout'))('B');
    const tabBNotes = await receive(notes, 'tabB notes');
    assert.equal(tabBNotes.headers['x-journal-account'], 'B');
    tabBNotes.res.writeHead(304, { ETag: cachedB.etag }).end();
    await until(() => found(activeTabB, bodyB), 'tabB rendered B');
    await until(async () => !await found(hiddenTabA, bodyA), 'tabA immediately revoked A when tabB confirmed B');
    assert.equal(await hiddenTabA.evaluate("document.getElementById('note-body').value"), '');
    assert.equal(await hiddenTabA.evaluate("import('/ux-helpers.js').then(m => m.notesCacheTransaction('readonly', s => s.get('A'))).then(Boolean)"), false);
    assert.equal(await activeTabB.evaluate("import('/ux-helpers.js').then(m => m.notesCacheTransaction('readonly', s => s.get('B'))).then(Boolean)"), true);
    await activeTabB.evaluate("import('/ux-helpers.js').then(m => m.notesCacheTransaction('readwrite', s => s.delete('B')))");

    for (const status of [200, 401]) {
      const stale = await seedPage();
      pageAccount = 'A';
      await stale.navigate(local + '/');
      const verify = await receive(sessions, 'stale-page session');
      const pending = await conditional();
      pending.writeHead(304, { ETag: cached.etag }).end();
      assert.equal(await found(stale, bodyA), false);
      if (status === 200) pageAccount = 'B';
      verify(status === 200 ? 'B' : null, status);
      if (status === 200) {
        (await receive(sessions, 'new account verification'))('B');
        const request = await receive(notes, 'new account notes');
        assert.equal(request.headers['x-journal-account'], 'B');
        assert.equal(request.headers['if-none-match'], undefined);
        json(request.res, { notes: [{ ...note(bodyB), revision: 1 }], deleted: [] });
        await until(() => found(stale, bodyB), 'new account body');
        assert.equal(await found(activeTabB, bodyB), true);
        assert.equal(await activeTabB.evaluate("document.getElementById('sign-in').hidden"), true);
      } else {
        await until(() => stale.evaluate("!document.getElementById('sign-in').hidden"), 'expired login notice');
      }
      assert.equal(await found(stale, bodyA), false);
      assert.deepEqual(await stale.evaluate('firstFrameLeaks'), []);
      assert.equal(await stale.evaluate("import('/ux-helpers.js').then(m => m.notesCacheTransaction('readonly', s => s.get('A'))).then(Boolean)"), false);
    }
  });
