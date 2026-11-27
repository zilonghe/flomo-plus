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
import { applyMigrations, createAuth } from '../src/auth.js';
import { metaOverlapScore, rankNoteIds } from '../src/retrieval.js';
import worker from '../dist/server/index.js';
import * as ux from '../public/ux-helpers.js';

const origin = 'https://weiji.test';
const id = '11111111-1111-4111-8111-111111111111';
const anotherId = '22222222-2222-4222-8222-222222222222';
const createdAt = '2026-11-24T00:00:00.000Z';
const note = (body, noteId = id) => ({ id: noteId, body, createdAt, updatedAt: createdAt, attachments: [], turns: [] });

test('Related ranking prioritizes cross-book diversity, caps same-book results, and backfills when needed', () => {
  const reading = { bookTitle: 'Focus' };
  assert.equal(metaOverlapScore({ body: '#first', reading }, { body: '#second', reading }), 0);

  const focusId = 'focus';
  const metadataFor = (bookTitle, entries) => new Map([[focusId, { bookTitle, tags: [] }],
    ...entries.map(([id, bookTitle]) => [id, { bookTitle, tags: [], createdAt }])]);
  const matchesFor = (metadata) => new Map([...metadata.keys()].filter(id => id !== 'zero').map(id => [id, ['key']]));
  const rank = (metadata, options = {}) => rankNoteIds(metadata, {
    focusId, queryTokens: ['key'], matches: matchesFor(metadata), ...options,
  }).map(item => item.id);

  const rich = metadataFor('focus', [
    ['a-same', 'focus'], ['b-same', 'focus'], ['c-one', 'one'], ['d-one', 'one'], ['e-one', 'one'],
    ['f-memo'], ['g-two', 'two'], ['h-two', 'two'], ['i-memo'],
  ]);
  const primary = ['c-one', 'd-one', 'f-memo', 'g-two', 'h-two', 'i-memo'];
  assert.deepEqual(rank(rich, { limit: 6 }), primary);
  assert.deepEqual(rank(rich), [...primary, 'a-same', 'e-one', 'b-same']);
  assert.deepEqual(rank(rich, { focusId: undefined, limit: 3, includeIds: ['c-one', 'd-one', 'e-one', 'i-memo'] }),
    ['c-one', 'd-one', 'e-one']);

  const sparse = metadataFor('focus', [
    ...[1, 2, 3, 4, 5].map(i => [`same${i}`, 'focus']), ['other', 'one'], ['zero', 'focus'],
  ]);
  assert.deepEqual(rank(sparse, { limit: 4 }), ['other', 'same1', 'same2', 'same3']);
  assert.deepEqual(rank(sparse), ['other', 'same1', 'same2', 'same3', 'same4', 'same5']);

  const memos = metadataFor(null, [['a-memo', null], ['b-memo', null], ['c-book', 'one'], ['d-memo', null]]);
  assert.deepEqual(rank(memos), ['a-memo', 'b-memo', 'c-book', 'd-memo']);
  assert.deepEqual(rank(sparse, { matches: new Map(), vector: [1, 0], vectors: new Map([
    ['same1', { vector: [1, 0] }], ['other', { vector: [1, 1] }],
  ]) }), ['other', 'same1']);
});

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
  return { db, call, put, env };
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
  const raw = await response.text();
  assert.ok(raw.startsWith(': connected\n\n'), 'SSE stream should flush an immediate connected preface');
  return raw.trim().split('\n\n').filter(frame => frame.startsWith('event: '))
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

test('Chat falls back to the source only when referencedNoteIds is omitted', async t => {
  const { put, env } = await fixture(t);
  const gateway = await upstream(t);
  const sourceBody = '只存在于来源笔记正文里的检索标记';
  put('A', note(sourceBody));
  const send = async (body) => {
    const response = await worker.fetch(new Request(origin + '/api/ai/chat', {
      method: 'POST',
      headers: { 'oai-authenticated-user-id': 'A', Origin: origin, 'Content-Type': 'application/json' },
      body,
    }), { ...env, ...gateway.env });
    assert.equal(response.status, 200);
    return response.json();
  };
  const initial = await send(JSON.stringify({ message: '第一问', provider: 'codex', sourceNoteId: id, useAllNotes: false }));
  assert.equal(initial.session.sourceNoteId, id);
  assert.equal(initial.citations[0].noteId, id);
  const sessionId = initial.session.id;
  const followUp = await send(JSON.stringify({ message: '第二问', provider: 'codex', sessionId, expectedVersion: 1, useAllNotes: false }));
  assert.equal(followUp.citations[0].noteId, id);
  const cleared = await send(JSON.stringify({ message: '第三问', provider: 'codex', sessionId, expectedVersion: 2, referencedNoteIds: [], useAllNotes: false }));
  assert.deepEqual(cleared.citations, []);
  assert.equal(gateway.calls.length, 3);
  const messages = gateway.calls.map(({ body }) => body.messages.map(message => message.content).join('\n'));
  for (const context of messages.slice(0, 2)) {
    assert.match(context, /<相关历史笔记>/);
    assert.ok(context.includes(sourceBody));
  }
  assert.doesNotMatch(messages[2], /<相关历史笔记>/);
  assert.ok(!messages[2].includes(sourceBody));
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
      document.querySelector('[data-action=open-import-hub]').click();
      const source = document.querySelector('#import-hub-dialog [data-action=open-flomo-import]');
      if (!source.getClientRects().length) throw new Error('flomo source is not visible');
      source.click();
      if (!document.getElementById('flomo-dialog').open || document.getElementById('import-hub-dialog').open) {
        throw new Error('flomo dialog did not replace the import hub');
      }
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
    const retrieveStep = {
      id: 'retrieve',
      kind: 'retrieve',
      status: 'done',
      label: '检索相关笔记',
      detail: '命中 19 条笔记',
      durationMs: 272,
      items: [
        { ref: 'N1', noteId: id, title: '2023-08-20', excerpt: '这是一段很长的笔记摘录，用于验证处理过程卡片内不会因为白空不换行而撑爆右侧边框并把耗时顶出卡片外面：'.repeat(3) },
        { ref: 'N2', noteId: id, title: '巴黎评论（套装共7册）'.repeat(10), excerpt: '创作者的作品，首要目的是为了取悦自己。海明威真是一个有意思的人，写了书和故事又能不被别人要求去解释它们可真够难的。' },
      ],
    };
    const step = { id: 'think', kind: 'think', status: 'running', label: '思考与生成' };
    const stream = chat.res.writeHead(200, { 'Content-Type': 'text/event-stream' });
    const event = (name, data) => stream.write('event: ' + name + '\ndata: ' + JSON.stringify(data) + '\n\n');
    event('citations', { citations: [citation] });
    event('step', retrieveStep);
    event('step', step);
    event('reasoning', { text: '第一段推理：' });
    await until(() => page.evaluate(`(() => {
      const el = document.querySelector('#ai-pending-reply details.ai-reasoning');
      return Boolean(el && !el.hidden);
    })()`), 'live reasoning disclosure visible before first delta');
    const measureStepsCard = selector => `(() => {
      const card = ${selector};
      const measureTextLines = node => {
        const range = document.createRange();
        range.selectNodeContents(node);
        const tops = new Set([...range.getClientRects()].filter(r => r.width > 0 && r.height > 0).map(r => Math.round(r.top)));
        return tops.size;
      };
      const cardRect = card.getBoundingClientRect();
      const scrollOverflow = card.scrollWidth - card.clientWidth;
      const listRect = card.querySelector('.ai-step-list').getBoundingClientRect();
      const timeRect = card.querySelector('.ai-step-time').getBoundingClientRect();
      const notes = [...card.querySelectorAll('.ai-step-note')].map(btn => ({
        right: btn.getBoundingClientRect().right,
        titleLines: measureTextLines(btn.querySelector('span:first-child')),
      }));
      return {
        scrollOverflow,
        listOverflow: listRect.right - cardRect.right,
        timeOverflow: timeRect.right - cardRect.right,
        maxNoteOverflow: Math.max(...notes.map(n => n.right - cardRect.right)),
        maxTitleLines: Math.max(...notes.map(n => n.titleLines)),
      };
    })()`;
    const stepBounds = await page.evaluate(measureStepsCard("document.querySelector('#ai-pending-reply .ai-steps-card')"));
    assert.ok(stepBounds.scrollOverflow <= 1, 'steps card must not scroll horizontally: ' + JSON.stringify(stepBounds));
    assert.ok(stepBounds.listOverflow <= 1, 'step list must stay within card right edge: ' + JSON.stringify(stepBounds));
    assert.ok(stepBounds.timeOverflow <= 1, 'step duration must stay within card right edge: ' + JSON.stringify(stepBounds));
    assert.ok(stepBounds.maxNoteOverflow <= 1, 'step note rows must stay within card right edge: ' + JSON.stringify(stepBounds));
    assert.equal(stepBounds.maxTitleLines, 1, 'step note titles must stay single-line: ' + JSON.stringify(stepBounds));
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
      { role: 'user', text: chat.body.message }, { role: 'assistant', text: '原笔记 `[N1]`\n\n后续', citations: [citation], steps: [retrieveStep, doneStep] }] } });
    stream.end();
    await until(() => page.evaluate("!document.getElementById('ai-pending-reply')"), 'done painted');
    assert.equal(await page.evaluate("document.querySelector('#ai-chat-thread details.ai-steps').open"), false);
    assert.equal(await page.evaluate("window.frozenReply.isConnected"), true);
    await page.send('Emulation.setDeviceMetricsOverride', { width: 375, height: 812, deviceScaleFactor: 2, mobile: true });
    await page.evaluate("[...document.querySelectorAll('#ai-chat-thread details.ai-steps')].at(-1).querySelector('summary').click()");
    const historyStepBounds = await page.evaluate(measureStepsCard("[...document.querySelectorAll('#ai-chat-thread details.ai-steps')].at(-1)"));
    await page.evaluate("[...document.querySelectorAll('#ai-chat-thread details.ai-steps')].at(-1).querySelector('summary').click()");
    await page.send('Emulation.clearDeviceMetricsOverride');
    assert.ok(historyStepBounds.scrollOverflow <= 1, 'mobile history steps card must not overflow: ' + JSON.stringify(historyStepBounds));
    assert.ok(historyStepBounds.listOverflow <= 1, 'mobile history step list overflow: ' + JSON.stringify(historyStepBounds));
    assert.ok(historyStepBounds.timeOverflow <= 1, 'mobile history step time overflow: ' + JSON.stringify(historyStepBounds));
    assert.ok(historyStepBounds.maxNoteOverflow <= 1, 'mobile history step notes overflow: ' + JSON.stringify(historyStepBounds));
    assert.equal(historyStepBounds.maxTitleLines, 1, 'mobile history step note titles must stay single-line: ' + JSON.stringify(historyStepBounds));

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

test('Chromium verifies AI insights filter bar consistency and random walk previous-hop card',
  { timeout: 30_000 }, async t => {
    assert.ok(chrome, 'Chromium binary is required (set WEIJI_TEST_CHROME)');
    const tab = await headless(t);
    const thirdId = '33333333-3333-4333-8333-333333333333';
    const noteA = { ...note('随机漫步起点笔记 A，用于验证上一步卡片展示和返回导航。', id), revision: 1 };
    const noteB = { ...note('随机漫步中继笔记 B，用于验证聚焦切换和同步删除回退。', anotherId), revision: 1 };
    const noteC = { ...note('随机漫步终点笔记 C，用于验证三跳历史清理。', thirdId), revision: 1 };
    const noteMap = new Map([[noteA.id, noteA], [noteB.id, noteB], [noteC.id, noteC]]);
    let liveNotes = [noteA, noteB, noteC];
    let deletedNotes = [];
    let getNotesCount = 0;
    let postDeleteCount = 0;
    let relatedRequests = 0;
    let holdNextRelated = false;
    let heldRelatedStarted = null;
    let releaseHeldRelated = null;
    let profileLoads = 0;
    const nextInCycle = new Map([[noteA.id, noteB], [noteB.id, noteC], [noteC.id, noteA]]);
    const json = (res, value, status = 200) => res.writeHead(status, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' }).end(JSON.stringify(value));
    const web = createServer(async (req, res) => {
      const pathname = new URL(req.url, origin).pathname;
      if (pathname === '/api/session') return json(res, { user: { id: 'A', name: 'A' }, authMode: 'oauth', codexAvailable: true, codexMode: 'gateway' });
      if (pathname === '/api/notes' && req.method === 'POST') {
        const chunks = [];
        for await (const chunk of req) chunks.push(chunk);
        const body = JSON.parse(Buffer.concat(chunks).toString('utf8'));
        if (body.delete && body.id) {
          postDeleteCount++;
          liveNotes = liveNotes.filter(n => n.id !== body.id);
          const tombstone = { id: body.id, revision: (body.expectedRevision ?? 1) + 1 };
          deletedNotes = [...deletedNotes.filter(d => d.id !== body.id), tombstone];
          return json(res, { deleted: tombstone });
        }
      }
      if (pathname === '/api/notes') {
        getNotesCount++;
        return json(res, { notes: liveNotes, deleted: deletedNotes });
      }
      if (pathname === '/api/ai/models') return json(res, {
        models: ['gemini-4-neon-xhigh', 'gemini-3-flash', 'gpt-6.2-sol'],
        defaultModel: 'gemini-4-neon-xhigh',
        modelMeta: [
          { id: 'gemini-4-neon-xhigh', vendor: 'gemini', label: 'Gemini 4 Neon', thinking: true, fixedEffort: 'xhigh', efforts: [] },
          { id: 'gemini-3-flash', vendor: 'gemini', label: 'Gemini 3 Flash', thinking: true, efforts: ['low', 'medium', 'high'] },
          { id: 'gpt-6.2-sol', vendor: 'openai', label: 'GPT-6.2 Sol', thinking: true, efforts: ['low', 'medium', 'high', 'xhigh'] },
        ],
      });
      if (pathname === '/api/insights/lenses') return json(res, { lenses: [], categories: [] });
      if (pathname === '/api/insights/preview') return json(res, { noteCount: 2, tagCount: 0, dayCount: 1, willSample: false });
      if (pathname === '/api/ai/sessions') {
        const source = new URL(req.url, origin).searchParams.get('sourceNoteId');
        if (!source) return json(res, { sessions: [] });
        return json(res, { session: source === anotherId ? {
          id: thirdId, sourceNoteId: anotherId, title: '已有笔记对话', version: 1, origin: 'note', updatedAt: createdAt,
          turns: [{ role: 'assistant', text: '历史回答' }],
        } : null });
      }
      if (pathname === '/api/ai/profile') {
        profileLoads++;
        return json(res, { profile: { content: '画像测试正文', enabled: true, noteCount: 2, updatedAt: createdAt } });
      }
      const relatedMatch = pathname.match(/^\/api\/notes\/([^/]+)\/related$/);
      if (relatedMatch) {
        relatedRequests++;
        const focus = noteMap.get(relatedMatch[1]) ?? noteA;
        const other = nextInCycle.get(focus.id) ?? noteB;
        if (holdNextRelated) {
          holdNextRelated = false;
          if (heldRelatedStarted) { heldRelatedStarted(); heldRelatedStarted = null; }
          await new Promise(resolve => { releaseHeldRelated = resolve; });
          if (res.writableEnded || req.destroyed) return;
        }
        return json(res, { focus, related: [{ id: other.id, note: other, relevancePercent: 92 }] });
      }
      const response = await worker.fetch(new Request(origin + req.url, {
        headers: { 'oai-authenticated-user-id': 'A', 'oai-authenticated-auth-mode': 'oauth' },
      }), {});
      res.writeHead(response.status, Object.fromEntries(response.headers)).end(await response.text());
    });
    web.listen(0, '127.0.0.1');
    await once(web, 'listening');
    t.after(() => new Promise(resolve => { web.closeAllConnections(); web.close(resolve); }));
    const local = 'http://127.0.0.1:' + web.address().port;

    const page = await tab();
    await page.send('Emulation.setDeviceMetricsOverride', { width: 1280, height: 800, deviceScaleFactor: 1, mobile: false });
    await page.navigate(local + '/');
    await until(() => page.evaluate("document.getElementById('sync-state')?.dataset.status === 'ok'"), 'notes loaded');

    assert.equal(await page.evaluate(`document.querySelectorAll(
      '[data-action=ins-close], [data-action=ai-close], [data-action=rw-close], [data-action=profile-close], #sidebar [data-action=open-ai-profile], #ai-profile-view'
    ).length`), 0);
    assert.deepEqual(await page.evaluate(`['notes-topbar', 'main', 'random-walk-overlay', 'ai-chat-view', 'ai-insights-view']
      .map(id => document.getElementById(id).parentElement.classList.contains('workspace'))`), [true, true, true, true, true]);
    const clickNav = selector => page.evaluate(`document.querySelector('#sidebar ' + ${JSON.stringify(selector)}).click()`);
    const currentNav = () => page.evaluate(`[...document.querySelectorAll('#sidebar .nav-item.active, #sidebar [aria-current=page]')]
      .map(button => [button.dataset.action ?? button.dataset.filter, button.classList.contains('active'), button.getAttribute('aria-current')])`);
    const assertNav = async name => assert.deepEqual(await currentNav(), [[name, true, 'page']]);
    await assertNav('all');

    // Open both new and existing note chats through the reader button.
    const chatEntry = `document.querySelector('#note-dialog [data-action="open-note-ai-chat"]')`;
    for (const [current, label] of [[noteA, '问 AI'], [noteB, '继续对话']]) {
      await page.evaluate(`document.querySelector('[data-open-note="${current.id}"]').click()`);
      await until(() => page.evaluate(`document.getElementById('note-dialog').open && ${chatEntry}.textContent.trim() === ${JSON.stringify(label)}`), label);
      await page.evaluate(`${chatEntry}.click()`);
      await until(() => page.evaluate(`!document.getElementById('note-dialog').open && !document.getElementById('ai-chat-send').disabled &&
        !document.getElementById('ai-pinned-notes').closest('[hidden]') &&
        document.querySelector('#ai-pinned-notes [data-remove-pin="${current.id}"] .ai-pin-label')?.textContent === ${JSON.stringify(current.body.slice(0, 24))}`),
      'source note appears as an automatic reference after loading');
      await assertNav('open-ai-chat');
      await clickNav('[data-filter=all]');
      await assertNav('all');
    }

    // 1. AI Insights filter bar uniform control height & searchable model picker
    await page.evaluate("document.querySelector('[data-action=open-ai-insights]').click()");
    await until(() => page.evaluate("!document.getElementById('ins-model-picker').hidden && document.getElementById('ins-model-toggle').textContent.includes('Gemini 4 Neon')"),
      'insights model picker rendered');
    const insState = await page.evaluate(`(() => {
      const range = document.getElementById('ins-range-select');
      const tag = document.getElementById('ins-tag-trigger');
      const toggle = document.getElementById('ins-model-toggle');
      const profile = document.querySelector('#ins-scope label:has(#ins-use-profile)');
      const select = document.getElementById('ins-model-select');
      return {
        selectHidden: select.hidden,
        selectValue: select.value,
        toggleText: toggle.textContent.trim(),
        hasVendorIcon: Boolean(toggle.querySelector('svg.ai-vendor-gemini')),
        heights: {
          range: range.getBoundingClientRect().height,
          tag: tag.getBoundingClientRect().height,
          toggle: toggle.getBoundingClientRect().height,
          profile: profile.getBoundingClientRect().height,
        },
      };
    })()`);
    assert.equal(insState.selectHidden, true);
    assert.equal(insState.selectValue, 'gemini-4-neon-xhigh');
    assert.equal(insState.toggleText, 'Gemini 4 Neon');
    assert.equal(insState.hasVendorIcon, true);
    assert.ok(!insState.toggleText.includes('gemini-4-neon-xhigh'));
    const heights = Object.values(insState.heights);
    for (const h of heights) assert.ok(h > 0, 'control height must be positive: ' + JSON.stringify(insState.heights));
    for (const h1 of heights) {
      for (const h2 of heights) {
        assert.ok(Math.abs(h1 - h2) <= 2, `insights controls height mismatch: ${JSON.stringify(insState.heights)}`);
      }
    }

    await page.evaluate(`(() => {
      document.getElementById('ins-model-toggle').click();
      const search = document.getElementById('ins-model-search');
      search.value = 'gpt';
      search.dispatchEvent(new InputEvent('input', { bubbles: true }));
    })()`);
    const popoverState = await page.evaluate(`(() => {
      const popover = document.getElementById('ins-model-popover');
      const options = [...popover.querySelectorAll('#ins-model-options button')].map(b => b.textContent.trim());
      return { open: !popover.hidden, options };
    })()`);
    assert.equal(popoverState.open, true);
    assert.ok(popoverState.options.some(text => text.includes('GPT-6.2 Sol')), 'filtered option list: ' + JSON.stringify(popoverState.options));

    await page.evaluate("document.querySelector('#ins-model-options button').click()");
    const afterSelect = await page.evaluate(`({
      popoverHidden: document.getElementById('ins-model-popover').hidden,
      selectValue: document.getElementById('ins-model-select').value,
      toggleText: document.getElementById('ins-model-toggle').textContent.trim(),
      hasOpenAIIcon: Boolean(document.querySelector('#ins-model-toggle svg.ai-vendor-openai')),
    })`);
    assert.equal(afterSelect.popoverHidden, true);
    assert.equal(afterSelect.selectValue, 'gpt-6.2-sol');
    assert.equal(afterSelect.toggleText, 'GPT-6.2 Sol');
    assert.equal(afterSelect.hasOpenAIIcon, true);

    await page.evaluate("document.getElementById('ins-model-toggle').click()");
    assert.equal(await page.evaluate("document.getElementById('ins-model-popover').hidden"), false);
    await page.evaluate("document.getElementById('ins-model-search').dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true }))");
    assert.equal(await page.evaluate("document.getElementById('ins-model-popover').hidden"), true);
    await assertNav('open-ai-insights');
    await page.evaluate("document.querySelector('[data-action=ins-tab][data-tab=profile]').click()");
    await until(() => page.evaluate(`document.querySelector('#ai-insights-view .ins-content #ins-panel-profile')
      .getClientRects().length && document.querySelector('#profile-body').textContent.includes('画像测试正文')`), 'profile loaded inside insights');
    assert.deepEqual(await page.evaluate(`['ai-insights-view', 'ins-panel-profile', 'ins-scope', 'ins-panel-new', 'ins-panel-history', 'ins-report-view']
      .map(id => document.getElementById(id).hidden)`), [false, false, true, true, true, true]);
    await assertNav('open-ai-insights');
    await page.evaluate("document.querySelector('[data-action=ins-tab][data-tab=new]').click()");
    assert.equal(await page.evaluate("document.querySelector('#ins-model-toggle').textContent"), 'GPT-6.2 Sol', 'profile tab preserves insights scope and model');
    await clickNav('[data-filter=all]');
    await assertNav('all');
    await clickNav('[data-action=open-ai-insights]');
    await page.evaluate("document.querySelector('[data-action=ins-tab][data-tab=profile]').click()");
    await until(() => page.evaluate("document.querySelector('#profile-body').textContent.includes('画像测试正文')"), 'profile reloaded on re-entry');
    assert.equal(profileLoads, 2);
    await clickNav('[data-action=open-ai-chat]');
    await assertNav('open-ai-chat');
    assert.equal(await page.evaluate("document.activeElement.id"), 'ai-chat-title');
    await clickNav('[data-filter=all]');
    await assertNav('all');

    // 2. Random Walk previous-hop card on left + curved link + back navigation
    await page.evaluate("document.querySelector('[data-action=open-random-walk]').click()");
    await until(() => page.evaluate("Boolean(document.querySelector('#rw-focus .rw-focus-card') && document.querySelector('#rw-related .rw-related-card'))"),
      'random walk initial card and related list loaded');
    await assertNav('open-random-walk');
    assert.equal(await page.evaluate(`document.querySelector('[data-action="rw-shuffle"]').textContent.trim()`), '随机');
    assert.equal(await page.evaluate(`document.getElementById('rw-prev-slot').getAttribute('aria-label')`), '上一步笔记');
    assert.equal(await page.evaluate("document.activeElement.id"), 'rw-title');
    assert.equal(await page.evaluate("document.getElementById('refresh-button').closest('header').id"), 'notes-topbar');
    assert.equal(await page.evaluate("document.getElementById('notes-topbar').hidden"), true);
    const initialWalk = await page.evaluate(`({
      focusId: document.querySelector('#rw-focus .rw-focus-card').dataset.noteId,
      relatedId: document.querySelector('#rw-related .rw-related-card').dataset.noteId,
      hasPrevCard: Boolean(document.querySelector('#rw-prev-slot .rw-prev-card')),
      hasPrevLink: Boolean(document.querySelector('svg.rw-links path.rw-link-prev')),
    })`);
    assert.equal(initialWalk.hasPrevCard, false);
    assert.equal(initialWalk.hasPrevLink, false);
    assert.notEqual(initialWalk.focusId, initialWalk.relatedId);

    await page.evaluate("document.querySelector('#rw-related .rw-related-card').click()");
    await until(() => page.evaluate(`document.querySelector('#rw-focus .rw-focus-card')?.dataset.noteId === ${JSON.stringify(initialWalk.relatedId)} && Boolean(document.querySelector('#rw-prev-slot .rw-prev-card'))`),
      'random walk pivoted and rendered previous-hop card');
    const pivotedWalk = await page.evaluate(`(() => {
      const prevCard = document.querySelector('#rw-prev-slot .rw-prev-card');
      const focusCard = document.querySelector('#rw-focus .rw-focus-card');
      const prevPath = document.querySelector('svg.rw-links path.rw-link-prev');
      const prevRect = prevCard.getBoundingClientRect();
      const focusRect = focusCard.getBoundingClientRect();
      return {
        prevText: prevCard.textContent,
        prevRect: { left: prevRect.left, right: prevRect.right, width: prevRect.width, height: prevRect.height },
        focusRect: { left: focusRect.left, right: focusRect.right },
        prevPathD: prevPath?.getAttribute('d') ?? '',
      };
    })()`);
    assert.ok(pivotedWalk.prevRect.width > 0 && pivotedWalk.prevRect.height > 0);
    assert.ok(pivotedWalk.prevRect.right <= pivotedWalk.focusRect.left,
      `previous-hop card must be strictly to the left of focus card: ${JSON.stringify(pivotedWalk)}`);
    assert.match(pivotedWalk.prevPathD, /^M\s+-?\d+\s+-?\d+\s+C\s+/);
    assert.ok(pivotedWalk.prevText.includes('← 上一步'));

    await until(() => page.evaluate("!!document.querySelector('#rw-related .rw-related-card')"), 'walk related cards loaded after pivot');
    const preservedWalk = () => page.evaluate(`({
      focusId: document.querySelector('#rw-focus .rw-focus-card').dataset.noteId,
      prevCard: document.querySelector('#rw-prev-slot .rw-prev-card').outerHTML,
      related: document.querySelector('#rw-related').innerHTML,
    })`);
    const beforeSwitch = await preservedWalk();
    const requestsBeforeSwitch = relatedRequests;
    await clickNav('[data-filter=all]');
    await assertNav('all');
    assert.deepEqual(await page.evaluate(`['random-walk-overlay', 'notes-topbar', 'main']
      .map(id => document.getElementById(id).hidden)`), [true, false, false]);
    await clickNav('[data-action=open-random-walk]');
    await assertNav('open-random-walk');
    await until(() => page.evaluate("!!document.querySelector('svg.rw-links path.rw-link-prev')"), 'walk redrew the previous hop after re-entry');
    assert.deepEqual(await preservedWalk(), beforeSwitch);
    assert.equal(relatedRequests, requestsBeforeSwitch, 'reopening walk does not fetch related notes again');

    // Leaving Random Walk while related fetch is still in flight must resume fetching for the same focus without adding history.
    holdNextRelated = true;
    const heldStarted = new Promise(resolve => { heldRelatedStarted = resolve; });
    const reqBeforeAbort = relatedRequests;
    await page.evaluate("document.querySelector('#rw-related .rw-related-card').click()");
    await heldStarted;
    const inFlightWalk = await page.evaluate(`({
      focusId: document.querySelector('#rw-focus .rw-focus-card').dataset.noteId,
      prevText: document.querySelector('#rw-prev-slot .rw-prev-card')?.textContent ?? '',
    })`);
    await clickNav('[data-filter=all]');
    await assertNav('all');
    if (releaseHeldRelated) { releaseHeldRelated(); releaseHeldRelated = null; }
    await clickNav('[data-action=open-random-walk]');
    await assertNav('open-random-walk');
    await until(() => page.evaluate("!!document.querySelector('#rw-related .rw-related-card')"),
      'walk resumed aborted related fetch upon re-entry');
    assert.equal(relatedRequests, reqBeforeAbort + 2, 'aborted in-flight related fetch reloads once on re-entry');
    const afterResume = await page.evaluate(`({
      focusId: document.querySelector('#rw-focus .rw-focus-card').dataset.noteId,
      prevText: document.querySelector('#rw-prev-slot .rw-prev-card')?.textContent ?? '',
    })`);
    assert.deepEqual(afterResume, inFlightWalk, 'resumed walk keeps exact focus and previous-hop history');
    const reqAfterResume = relatedRequests;
    await clickNav('[data-filter=all]');
    await clickNav('[data-action=open-random-walk]');
    assert.equal(relatedRequests, reqAfterResume, 'completed resumed walk does not refetch on subsequent re-entry');
    // Return back one hop to restore expected state before testing prev-card click below.
    await page.evaluate("document.querySelector('#rw-prev-slot .rw-prev-card').click()");
    await until(() => page.evaluate(`document.querySelector('#rw-focus .rw-focus-card')?.dataset.noteId === ${JSON.stringify(beforeSwitch.focusId)} && !!document.querySelector('#rw-related .rw-related-card')`),
      'returned to pivoted note before previous-hop check');

    await page.evaluate("document.querySelector('#rw-prev-slot .rw-prev-card').click()");
    await until(() => page.evaluate(`document.querySelector('#rw-focus .rw-focus-card')?.dataset.noteId === ${JSON.stringify(initialWalk.focusId)}`),
      'clicking previous-hop card navigated back to initial note');
    const afterBack = await page.evaluate(`({
      focusId: document.querySelector('#rw-focus .rw-focus-card').dataset.noteId,
      hasPrevCard: Boolean(document.querySelector('#rw-prev-slot .rw-prev-card')),
      hasPrevLink: Boolean(document.querySelector('svg.rw-links path.rw-link-prev')),
    })`);
    assert.equal(afterBack.focusId, initialWalk.focusId);
    assert.equal(afterBack.hasPrevCard, false);
    assert.equal(afterBack.hasPrevLink, false);

    // 3. Revisit cycle (hop1 -> hop2 -> hop3 -> hop1): sync deleting hop2 must prune right related card & keep earlier hop1 in history
    await page.evaluate("document.querySelector('#rw-related .rw-related-card').click()");
    await until(() => page.evaluate(`document.querySelector('#rw-focus .rw-focus-card')?.dataset.noteId === ${JSON.stringify(initialWalk.relatedId)} && Boolean(document.querySelector('#rw-related .rw-related-card'))`),
      'hopped to second note');
    const hop1Id = initialWalk.focusId;
    const hop2Id = initialWalk.relatedId;
    const hop3Id = await page.evaluate("document.querySelector('#rw-related .rw-related-card').dataset.noteId");
    assert.notEqual(hop3Id, hop1Id);
    assert.notEqual(hop3Id, hop2Id);

    await page.evaluate("document.querySelector('#rw-related .rw-related-card').click()");
    await until(() => page.evaluate(`document.querySelector('#rw-focus .rw-focus-card')?.dataset.noteId === ${JSON.stringify(hop3Id)} && Boolean(document.querySelector('#rw-related .rw-related-card'))`),
      'hopped to third note');
    await page.evaluate("document.querySelector('#rw-related .rw-related-card').click()");
    await until(() => page.evaluate(`document.querySelector('#rw-focus .rw-focus-card')?.dataset.noteId === ${JSON.stringify(hop1Id)} && Boolean(document.querySelector('#rw-related .rw-related-card[data-note-id="' + ${JSON.stringify(hop2Id)} + '"]'))`),
      'revisited hop1 with hop2 shown on right');

    const hop1Body = noteMap.get(hop1Id).body.slice(0, 12);
    const hop3Body = noteMap.get(hop3Id).body.slice(0, 12);

    // Delete hop2 on server and sync -> right column must immediately remove hop2, left card keeps hop3
    liveNotes = liveNotes.filter(n => n.id !== hop2Id);
    deletedNotes = [{ id: hop2Id, revision: 2 }];
    await clickNav('[data-filter=all]');
    await page.evaluate(`(() => {
      const refresh = document.getElementById('refresh-button');
      if (!refresh.getClientRects().length) throw new Error('notes sync button is not visible');
      refresh.click();
    })()`);
    await clickNav('[data-action=open-random-walk]');
    await until(() => page.evaluate(`document.getElementById('sync-state')?.dataset.status === 'ok' && !document.getElementById('refresh-button').disabled && !document.querySelector('#rw-related .rw-related-card[data-note-id="' + ${JSON.stringify(hop2Id)} + '"]')`),
      'deleted hop2 pruned from right related column after sync');
    const afterRevisitSync = await page.evaluate(`({
      focusId: document.querySelector('#rw-focus .rw-focus-card')?.dataset.noteId,
      prevText: document.querySelector('#rw-prev-slot .rw-prev-card')?.textContent ?? '',
      relatedCount: document.querySelectorAll('#rw-related .rw-related-card').length,
      backDisabled: document.querySelector('#random-walk-overlay .rw-toolbar [data-action="rw-prev"]').disabled,
    })`);
    assert.equal(afterRevisitSync.focusId, hop1Id);
    assert.ok(afterRevisitSync.prevText.includes(hop3Body));
    assert.equal(afterRevisitSync.relatedCount, 0, 'deleted hop2 must be removed from right related column');
    assert.equal(afterRevisitSync.backDisabled, false);

    // Step back from revisited hop1 to hop3 -> surviving earlier hop1 MUST remain in history (not stripped by id !== rw.id)
    await page.evaluate("document.querySelector('#rw-prev-slot .rw-prev-card').click()");
    await until(() => page.evaluate(`document.querySelector('#rw-focus .rw-focus-card')?.dataset.noteId === ${JSON.stringify(hop3Id)} && Boolean(document.querySelector('#rw-related .rw-related-card[data-note-id="' + ${JSON.stringify(hop1Id)} + '"]'))`),
      'stepped back to hop3 with hop1 on both left prev card and right related card');
    const atHop3 = await page.evaluate(`({
      prevText: document.querySelector('#rw-prev-slot .rw-prev-card')?.textContent ?? '',
      backDisabled: document.querySelector('#random-walk-overlay .rw-toolbar [data-action="rw-prev"]').disabled,
      hasPrevLink: Boolean(document.querySelector('svg.rw-links path.rw-link-prev')),
      hasRightHop1: Boolean(document.querySelector('#rw-related .rw-related-card[data-note-id="' + ${JSON.stringify(hop1Id)} + '"]')),
    })`);
    assert.ok(atHop3.prevText.includes(hop1Body), `revisited hop1 must survive in history: ${JSON.stringify(atHop3)}`);
    assert.equal(atHop3.backDisabled, false);
    assert.equal(atHop3.hasPrevLink, true);
    assert.equal(atHop3.hasRightHop1, true);

    // 4. Local POST delete via mutate() (NO GET /api/notes sync!) -> immediately clears both left prev card and right related card
    const getsBeforeLocalDelete = getNotesCount;
    await clickNav('[data-filter=all]');
    await page.evaluate(`(() => {
      const menuBtn = document.querySelector('[data-action="card-menu"][data-note-id="' + ${JSON.stringify(hop1Id)} + '"]');
      if (!menuBtn) throw new Error('missing card menu button for hop1');
      menuBtn.click();
    })()`);
    await until(() => page.evaluate(`Boolean(document.querySelector('[data-action="card-inline-delete"][data-note-id="' + ${JSON.stringify(hop1Id)} + '"]'))`),
      'card menu inline delete item rendered');
    await page.evaluate(`document.querySelector('[data-action="card-inline-delete"][data-note-id="' + ${JSON.stringify(hop1Id)} + '"]').click()`);
    await until(() => page.evaluate(`Boolean(document.querySelector('[data-action="confirm-inline-delete"][data-note-id="' + ${JSON.stringify(hop1Id)} + '"]'))`),
      'inline delete confirmation rendered');
    await page.evaluate(`document.querySelector('[data-action="confirm-inline-delete"][data-note-id="' + ${JSON.stringify(hop1Id)} + '"]').click()`);
    await until(() => page.evaluate(`!document.querySelector('#rw-prev-slot .rw-prev-card') && !document.querySelector('#rw-related .rw-related-card[data-note-id="' + ${JSON.stringify(hop1Id)} + '"]')`),
      'local POST delete pruned both prev card and right related card without sync');
    await clickNav('[data-action=open-random-walk]');
    const afterLocalDelete = await page.evaluate(`({
      hasPrevCard: Boolean(document.querySelector('#rw-prev-slot .rw-prev-card')),
      hasPrevLink: Boolean(document.querySelector('svg.rw-links path.rw-link-prev')),
      relatedCount: document.querySelectorAll('#rw-related .rw-related-card').length,
      backDisabled: document.querySelector('#random-walk-overlay .rw-toolbar [data-action="rw-prev"]').disabled,
    })`);
    assert.equal(postDeleteCount, 1, 'expected local POST /api/notes delete');
    assert.equal(getNotesCount, getsBeforeLocalDelete, 'local delete cleanup must not rely on a subsequent GET /api/notes sync');
    assert.equal(afterLocalDelete.hasPrevCard, false);
    assert.equal(afterLocalDelete.hasPrevLink, false);
    assert.equal(afterLocalDelete.relatedCount, 0);
    assert.equal(afterLocalDelete.backDisabled, true);
  });

test('Chat SSE flushes : connected immediately before upstream replies', async t => {
  const { call, put } = await fixture(t);
  put('A', note('用于验证首包实时刷新的笔记'));
  let markUpstreamArrived;
  const upstreamArrived = new Promise(resolve => { markUpstreamArrived = resolve; });
  let releaseUpstream;
  const upstreamGate = new Promise(resolve => { releaseUpstream = resolve; });

  const server = createServer((req, res) => {
    if (req.url === '/v1/models') {
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ data: [{ id: 'gemini-3-flash' }] }));
      return;
    }
    const chunks = [];
    req.on('data', chunk => chunks.push(chunk));
    req.on('end', async () => {
      markUpstreamArrived();
      await upstreamGate;
      res.writeHead(200, { 'Content-Type': 'text/event-stream' });
      res.write('data: ' + JSON.stringify({ choices: [{ delta: { content: '实时回答' } }] }) + '\n\n');
      res.end('data: [DONE]\n\n');
    });
  });
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  t.after(() => {
    releaseUpstream?.();
    return new Promise(resolve => { server.closeAllConnections?.(); server.close(resolve); });
  });
  const base = 'http://127.0.0.1:' + server.address().port;
  const env = { OPENAI_BASE_URL: base + '/v1', OPENAI_API_KEY: 'test-gateway-token', OPENAI_MODEL: 'gemini-3-flash' };

  const response = await call('/api/ai/chat', {
    body: { message: '测试首包实时到达', provider: 'codex', referencedNoteIds: [id], useAllNotes: false, stream: true },
  }, env);
  assert.equal(response.status, 200);
  assert.match(response.headers.get('Content-Type'), /^text\/event-stream/);

  const reader = response.body.getReader();
  const decoder = new TextDecoder();
  // Read first chunk BEFORE releasing the upstream gate — buffered EOF streams will time out and fail here.
  const firstRead = await Promise.race([
    reader.read(),
    new Promise((_, reject) => setTimeout(() => reject(new Error('SSE : connected preface did not flush before upstream responded')), 1000)),
  ]);
  assert.equal(firstRead.done, false);
  const firstChunk = decoder.decode(firstRead.value, { stream: true });
  assert.equal(firstChunk, ': connected\n\n');

  await Promise.race([
    upstreamArrived,
    new Promise((_, reject) => setTimeout(() => reject(new Error('upstream did not receive chat request')), 2000)),
  ]);
  releaseUpstream();

  let rest = '';
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    rest += decoder.decode(value, { stream: true });
  }
  rest += decoder.decode();
  assert.ok(rest.includes('event: delta') && rest.includes('实时回答'), 'expected streamed delta after releasing upstream');
  assert.ok(rest.includes('event: done'), 'expected terminal done frame');
});

async function materialFixture(t) {
  assert.ok(chrome, 'Chromium binary is required (set WEIJI_TEST_CHROME)');
  const newPage = await headless(t);
  const { db, call, put } = await fixture(t);
  const auth = createAuth(db, { origin, providers: new Map([['github', { id: 'github', name: 'GitHub' }]]) });
  const today = new Date();
  const monday = Date.UTC(today.getUTCFullYear(), today.getUTCMonth(), today.getUTCDate() - today.getUTCDay() - 6, 12);
  for (const [i, noteID] of [id, anotherId].entries()) {
    const date = new Date(monday + i * 86400_000).toISOString();
    put('A', { ...note('主题验收正文 #设计/规范', noteID), createdAt: date, updatedAt: date });
  }
  const session = { id, title: '设计规范对话', version: 1, origin: 'global', createdAt, turns: [
    { role: 'user', text: '看看设计笔记' },
    { role: 'assistant', text: '原笔记 `[N1]`', citations: [{ ref: 'N1', noteId: id, excerpt: '主题验收正文', createdAt }],
      steps: [{ id: 'retrieve', kind: 'retrieve', status: 'done', label: '检索相关笔记', durationMs: 20 }] },
  ] };
  const { turns, ...summary } = session;
  const api = new Map([
    ['/api/session', { user: { id: 'A', name: 'A' }, authMode: 'oauth', codexAvailable: true, codexMode: 'gateway' }],
    ['/api/ai/models', { models: ['gemini-3-flash'], defaultModel: 'gemini-3-flash',
      modelMeta: [{ id: 'gemini-3-flash', vendor: 'gemini', label: 'Gemini 3 Flash', efforts: [] }] }],
    ['/api/ai/sessions', { sessions: [summary] }],
    ['/api/ai/sessions/' + id, { session }],
    ['/api/insights/lenses', { lenses: [], categories: [] }],
    ['/api/insights/preview', { noteCount: 2, tagCount: 2, dayCount: 2 }],
  ]);
  const web = createServer(async (req, res) => {
    const url = new URL(req.url, origin);
    const response = url.pathname === '/login'
      ? await auth.handle(new Request(url), url, '127.0.0.1')
      : api.has(url.pathname) ? Response.json(api.get(url.pathname))
        : await call(req.url, { headers: req.headers['if-none-match']
          ? { 'if-none-match': req.headers['if-none-match'] } : {} });
    res.writeHead(response.status, Object.fromEntries(response.headers)).end(await response.text());
  });
  web.listen(0, '127.0.0.1');
  await once(web, 'listening');
  t.after(() => new Promise(resolve => { web.closeAllConnections(); web.close(resolve); }));
  const base = 'http://127.0.0.1:' + web.address().port;
  return async ({ scheme = 'light', width = 1280, height = 800, mobile = false } = {}) => {
    const page = await newPage();
    await page.send('Emulation.setEmulatedMedia', { features: [
      { name: 'prefers-color-scheme', value: scheme }, { name: 'prefers-reduced-motion', value: 'reduce' },
    ] });
    await page.send('Emulation.setDeviceMetricsOverride', { width, height, deviceScaleFactor: 1, mobile });
    await page.send('Emulation.setTimezoneOverride', { timezoneId: 'UTC' });
    await page.navigate(base + '/');
    await until(() => page.evaluate("document.querySelector('.card-body')?.textContent.includes('主题验收正文')"), 'notes rendered');
    return { ...page, login: () => page.navigate(base + '/login') };
  };
}

async function measureMaterial(page, targets) {
  return page.evaluate(`(() => {
    const canvas = document.createElement('canvas');
    canvas.width = canvas.height = 1;
    const ctx = canvas.getContext('2d', { willReadFrequently: true });
    const pixel = () => [...ctx.getImageData(0, 0, 1, 1).data];
    const paint = color => {
      ctx.fillStyle = color;
      ctx.fillRect(0, 0, 1, 1);
    };
    const luminance = rgb => rgb.slice(0, 3).map(v => {
      const c = v / 255;
      return c <= 0.04045 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4;
    }).reduce((sum, c, i) => sum + c * [0.2126, 0.7152, 0.0722][i], 0);
    return Object.fromEntries(${JSON.stringify(targets)}.map(([selector, pseudo]) => {
      const node = document.querySelector(selector);
      if (!node?.getBoundingClientRect().height) throw new Error('Missing visible target ' + selector);
      const style = getComputedStyle(node, pseudo || null);
      const layers = [];
      for (let ancestor = node; ancestor; ancestor = ancestor.parentElement) {
        layers.unshift(getComputedStyle(ancestor).backgroundColor);
      }
      ctx.clearRect(0, 0, 1, 1);
      layers.forEach(paint);
      const bg = pixel();
      ctx.globalAlpha = Number(style.opacity);
      paint(style.color);
      ctx.globalAlpha = 1;
      const fg = pixel();
      const bright = luminance(bg), ink = luminance(fg);
      return [selector, { bg, bright, ratio: (Math.max(ink, bright) + 0.05) / (Math.min(ink, bright) + 0.05) }];
    }));
  })()`);
}

test('Material Design 3 light and dark theme maintains unified surfaces and readable contrast',
  { timeout: 30_000 }, async t => {
    const open = await materialFixture(t);
    for (const scheme of ['light', 'dark']) {
      const page = await open({ scheme });
      const notes = await measureMaterial(page, [
        ['body'], ['.topbar h1'], ['.nav-item.active'], ['.activity-numbers span'],
        ['.card-body'], ['.card-time'], ['.inline-tag'], ['#note-body', '::placeholder'],
        ['nav[aria-label=主视图] .nav-label'], ['#note-filters-title'],
      ]);
      assert.equal(await page.evaluate("document.querySelector('.topbar').getBoundingClientRect().height"), 64);
      const primary = await page.evaluate("getComputedStyle(document.documentElement).getPropertyValue('--md-sys-color-primary').trim()");
      assert.equal(primary, scheme === 'light' ? '#2d6a4f' : '#7ad4aa');
      assert.deepEqual(notes.body.bg, scheme === 'light' ? [246, 245, 240, 255] : [23, 22, 20, 255]);

      await page.evaluate("document.querySelector('[data-action=open-import-hub]').click()");
      const imports = await measureMaterial(page, [['#import-hub-title'], ...['open-flomo-import', 'open-joplin-import', 'open-import']
        .map(action => ['#import-hub-dialog [data-action=' + action + ']'])]);
      await page.evaluate("document.querySelector('[data-close=import-hub-dialog]').click()");
      await page.evaluate("document.querySelector('[data-action=open-ai-chat]').click()");
      await until(() => page.evaluate("!!document.querySelector('[data-action=ai-select-session]')"), 'AI session listed');
      await page.evaluate("document.querySelector('[data-action=ai-select-session]').click()");
      await until(() => page.evaluate("!!document.querySelector('.ai-steps-card') && document.querySelector('#ai-model-toggle').textContent.includes('Gemini')"), 'AI transcript and model loaded');
      await page.evaluate("document.querySelector('.ai-steps-card summary').click(); document.querySelector('#ai-model-toggle').click()");
      const chat = await measureMaterial(page, [
        ['#ai-chat-view'], ['.ai-session-title'], ['.ai-msg-user'], ['.ai-msg-assistant p'], ['.citation-chip'],
        ['.ai-steps-card summary'], ['.ai-step-heading strong'], ['#ai-chat-input', '::placeholder'],
        ['#ai-model-options [aria-pressed=true] .ai-picker-label'],
      ]);
      assert.deepEqual(chat['#ai-chat-view'].bg, notes.body.bg);

      await page.evaluate("document.querySelector('[data-action=open-ai-insights]').click()");
      await until(() => page.evaluate("document.querySelector('#ins-model-toggle').textContent.includes('Gemini')"), 'insights filters loaded');
      const insights = await measureMaterial(page, [
        ['#ai-insights-view'], ['#ins-scope'], ['#ins-range-select'], ['#ins-tag-trigger'], ['#ins-model-toggle'], ['.ins-profile-toggle'],
      ]);
      assert.deepEqual(await page.evaluate(`['#ins-range-select', '#ins-tag-trigger', '#ins-model-toggle', '.ins-profile-toggle']
        .map(selector => document.querySelector(selector).getBoundingClientRect().height)`), [40, 40, 40, 40]);
      await page.login();
      await until(() => page.evaluate("location.pathname === '/login' && document.readyState === 'complete' && !!document.querySelector('.auth-shell')"), 'real login page loaded');
      const login = await measureMaterial(page, [['.auth-shell'], ['.auth-page h1'], ['.auth-providers a'], ['.auth-footer a']]);
      assert.deepEqual(login['.auth-shell'].bg, notes.body.bg);

      for (const [selector, sample] of Object.entries({ ...notes, ...imports, ...chat, ...insights, ...login })) {
        assert.equal(sample.bg[3], 255, `${scheme} ${selector} should resolve to an opaque surface`);
        assert.ok(sample.ratio >= 4.5, `${scheme} ${selector} contrast ${sample.ratio.toFixed(3)}:1`);
        if (scheme === 'dark') {
          assert.ok(sample.bright < 0.12, `dark ${selector} background luminance ${sample.bright}`);
          assert.ok(sample.bg[0] >= sample.bg[2] || ['.inline-tag', '.citation-chip', '#ai-model-options [aria-pressed=true] .ai-picker-label', '.nav-item.active', '.ai-msg-user'].includes(selector),
            `dark ${selector} should use a warm neutral or a branded container: ${sample.bg}`);
        }
      }
    }
  });

test('Material Design 3 mobile 375px layout enforces 48px touch targets without overflow',
  { timeout: 30_000 }, async t => {
    const open = await materialFixture(t);
    const page = await open({ width: 375, height: 812, mobile: true });
    const layout = selectors => page.evaluate(`(() => {
      const targets = ${JSON.stringify(selectors)}.flatMap(([selector, square]) => {
        const matches = [...document.querySelectorAll(selector)].filter(el => el.getClientRects().length);
        if (!matches.length) throw new Error('Missing visible target ' + selector);
        return matches.map(el => {
          const { width, height } = el.getBoundingClientRect();
          return { selector, square, width, height };
        });
      });
      return { width: document.documentElement.scrollWidth, targets };
    })()`);
    const check = ({ width, targets }) => {
      assert.ok(width <= 375, 'page overflows 375px: ' + width);
      for (const { selector, square, height, width } of targets) {
        assert.ok(height >= 48 && (!square || width >= 48), `${selector} has a ${width}×${height}px hit box`);
      }
    };
    check(await layout([
      ['#mobile-toggle', true], ['#sort-button', true], ['#refresh-button', true],
      ['.topbar .icon-button', true], ['#search'], ['#save-note', true], ['.composer-footer button'],
    ]));
    const bar = await page.evaluate(`(() => {
      const first = document.querySelector('.topbar-left').getBoundingClientRect();
      const search = document.querySelector('.search-field').getBoundingClientRect();
      return { right: Math.max(...[...document.querySelectorAll('.topbar > *, .topbar-left > *')].map(el => el.getBoundingClientRect().right)),
        firstBottom: first.bottom, searchTop: search.top, searchWidth: search.width };
    })()`);
    assert.ok(bar.right <= 375, 'top bar overflows: ' + bar.right);
    assert.ok(bar.searchTop >= bar.firstBottom && bar.searchWidth >= 350, 'search needs its own full-width row');

    await page.evaluate("document.querySelector('#mobile-toggle').click()");
    check(await layout([['.nav-item'], ['.tag-toggle', true], ['button.heatmap-square', true]]));
    const cells = await page.evaluate(`(() => {
      const heatmap = document.querySelector('.heatmap');
      const buttons = [...heatmap.querySelectorAll('button.heatmap-square')];
      buttons[0].scrollIntoView({ block: 'center', inline: 'center' });
      return { gridWidth: heatmap.clientWidth, scrollWidth: heatmap.scrollWidth,
        drawerTop: document.querySelector('.sidebar').getBoundingClientRect().top,
        drawerHeight: document.querySelector('.sidebar').getBoundingClientRect().height,
        cells: buttons.map(button => {
          const { left, top, right, bottom, width, height } = button.getBoundingClientRect();
          const hit = [left + 2, right - 2].every(x => [top + 2, bottom - 2].every(y => document.elementFromPoint(x, y) === button));
          const centerHit = document.elementFromPoint(left + width / 2, top + height / 2) === button;
          return { left, top, right, bottom, hit, centerHit };
        }) };
    })()`);
    assert.equal(cells.drawerTop, 0);
    assert.equal(cells.drawerHeight, 812);
    assert.ok(cells.scrollWidth > cells.gridWidth, 'heatmap must scroll within the drawer');
    assert.equal(cells.cells.length, 2, 'two adjacent dates have matching notes');
    const [a, b] = cells.cells;
    assert.equal(b.top - a.bottom, 4, 'adjacent date cells must have a 4px gap');
    assert.ok(a.hit && b.hit, 'all four corners inset by 2px must hit their own date button');
    assert.ok(a.centerHit && b.centerHit, 'both date button centers must hit their own date button');

    await page.evaluate("document.querySelector('[data-action=open-ai-insights]').click()");
    await until(() => page.evaluate("document.querySelector('#ins-model-toggle').textContent.includes('Gemini')"), 'mobile insights filters loaded');
    check(await layout([['#ins-range-select'], ['#ins-tag-trigger'], ['#ins-model-toggle'], ['.ins-profile-toggle']]));
    check(await layout([['[data-action=ins-mobile-menu]', true], ['.ins-tabs button', true], ['[data-action=ins-new-lens]', true]]));
    await page.evaluate("document.querySelector('[data-action=ins-tab][data-tab=profile]').click()");
    check(await layout([['#ins-panel-profile .profile-actions button', true], ['.profile-toggle', true]]));
    await page.evaluate("document.querySelector('[data-action=ins-mobile-menu]').click(); document.querySelector('[data-action=open-random-walk]').click()");
    check(await layout([['.rw-toolbar button', true], ['.rw-card-actions button', true]]));
    await page.evaluate("document.querySelector('[data-action=rw-mobile-menu]').click()");
    assert.equal(await page.evaluate("document.querySelector('[data-action=rw-mobile-menu]').getAttribute('aria-expanded')"), 'true');
    await page.evaluate("document.querySelector('[data-action=open-import-hub]').click()");
    const sources = await layout([['#import-hub-dialog .import-sources button', true]]);
    assert.equal(sources.targets.length, 3);
    check(sources);
    await page.evaluate("document.querySelector('#import-hub-dialog [data-action=open-import]').click()");
    assert.equal(await page.evaluate("document.querySelector('#import-dialog').open && !document.querySelector('#import-hub-dialog').open"), true);
  });
