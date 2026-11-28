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

test('Web minimal sources have no old navigation, decorative sparkle icon or gradients', async () => {
  const read = file => readFile(new URL('../public/' + file, import.meta.url), 'utf8');
  const [html, js, css] = await Promise.all(['index.html', 'app.js', 'styles.css'].map(read));
  assert.doesNotMatch(html + js, /i-spark|sparkles|random-walk-overlay|ai-insights-view|rw-zoom/);
  assert.doesNotMatch(css, /(?:linear|radial)-gradient|ai-vendor-/);
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
        return void history.push((status = 200) => status === 200
          ? json(res, { session: sessionEntries.find(x => req.url.endsWith(x.id)) })
          : json(res, { error: '会话加载失败' }, status));
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
      document.querySelector('.top-nav [data-action=open-settings]').click();
      document.querySelector('[data-action=settings-pane][data-pane=data]').click();
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
    await page.evaluate("document.querySelector('[data-close=flomo-dialog]').click(); document.querySelector('[data-close=settings-dialog]').click();");
    await page.evaluate("document.dispatchEvent(new Event('visibilitychange')); true");
    assert.equal(await found(page, bodyA), true);
    (await conditional()).writeHead(304, { ETag: cached.etag }).end();
    const composeDraft = '未提交的私密草稿-314';
    await page.evaluate(`(() => {
      document.querySelector('#note-nav-actions [data-action=open-settings]').click();
      document.querySelector('[data-action=settings-pane][data-pane=data]').click();
      document.querySelector('[data-action=open-import-hub]').click();
      if (!document.getElementById('import-hub-dialog').open) throw new Error('import hub did not open');
      const input = document.getElementById('note-body');
      input.value = ${JSON.stringify(composeDraft)};
      input.dispatchEvent(new InputEvent('input', { bubbles: true }));
    })()`);
    await page.evaluate("window.dispatchEvent(new PageTransitionEvent('pagehide', { persisted: true })); true");
    assert.equal(await found(page, bodyA), false);
    assert.equal(await page.evaluate("document.querySelectorAll('dialog[open]').length"), 0, 'account reset closes import-hub and all dialogs');
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
    assert.deepEqual(await page.evaluate(`[...document.querySelectorAll('.space-nav [aria-current="page"]')].map(n => n.dataset.action)`), ['open-ai-chat']);
    await until(() => page.evaluate("document.querySelectorAll('[data-action=\"ai-select-session\"][data-session-id]').length >= 2"), 'history list');
    const select = i => page.evaluate(`
      document.querySelector('[data-action=ai-toggle-sessions]').click();
      document.querySelector('[data-action="ai-select-session"][data-session-id="${sessionEntries[i].id}"]').click();
      [document.querySelector('[data-action="ai-select-session"][aria-current="true"]').dataset.sessionId,
        !!document.querySelector('#ai-chat-thread .ai-session-skeleton'),
        document.querySelector('#ai-turns .ai-reply-text')?.textContent ?? '']`);
    for (const i of [0, 1]) {
      const state = await select(i);
      assert.deepEqual(state, [sessionEntries[i].id, true, '']);
      assert.equal(await page.evaluate("document.getElementById('ai-chat-input').value"), '', 'uncached switch clears previous session draft before GET completes');
      if (i === 1) {
        await page.evaluate(`document.getElementById('ai-chat-input').value = '加载中输入的新草稿'`);
        (await receive(history, 'failed uncached history request'))(503);
        await until(() => page.evaluate("document.getElementById('ai-chat-error').textContent.includes('会话加载失败')"), 'uncached session error shown');
        assert.equal(await page.evaluate("document.getElementById('ai-chat-input').value"), '加载中输入的新草稿');
        assert.equal(await page.evaluate("document.getElementById('ai-chat-send').disabled"), true, 'failed session load keeps send disabled');
        await page.evaluate("document.getElementById('ai-chat-form').requestSubmit()");
        assert.equal(chats.length, 0, 'failed session load must not send without sessionId');
        // Switch back to cached session 0, then return to uncached session 1 and clear its draft before GET resolves.
        assert.deepEqual(await select(0), [id, false, '测试答案 0']);
        assert.equal(await page.evaluate("document.getElementById('ai-chat-input').value"), '会话草稿 0');
        (await receive(history, 'cached session 0 background refresh'))();
        assert.deepEqual(await select(1), [anotherId, true, '']);
        assert.equal(await page.evaluate("document.getElementById('ai-chat-input').value"), '加载中输入的新草稿');
        await page.evaluate("document.getElementById('ai-chat-input').value = ''");
      }
      (await receive(history, 'history request'))();
      await until(() => found(page, '测试答案 ' + i), 'loaded history');
      assert.equal(await page.evaluate("document.getElementById('ai-chat-input').value"), '', i === 1 ? 'cleared draft stays empty when GET resolves' : 'draft does not cross sessions');
      await page.evaluate(`document.getElementById('ai-chat-input').value = '会话草稿 ${i}'`);
    }
    assert.deepEqual(await select(0), [id, false, '测试答案 0']);
    assert.equal(await page.evaluate("document.getElementById('ai-chat-input').value"), '会话草稿 0');
    (await receive(history, 'background history refresh'))();

    await page.evaluate("document.querySelector('[data-action=ai-options]').click()");
    await until(() => found(page, 'Gemini 3 Flash'), 'model selector loaded');
    await page.evaluate(`
      document.getElementById('ai-model-toggle').click();
      const search = document.getElementById('ai-model-search');
      search.value = 'gpt';
      search.dispatchEvent(new InputEvent('input', { bubbles: true }));
      search.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true }));
      document.getElementById('ai-effort-toggle').click();
      [...document.querySelectorAll('#ai-effort-popover button')].find(b => b.textContent === '极高').click();
      document.querySelector('[data-action=ai-options]').click();
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
    assert.equal(await page.evaluate("document.querySelector('#ai-pending-reply .ai-steps-card').open"), false);
    await page.evaluate("document.querySelector('#ai-pending-reply .ai-steps-card > summary').click()");
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
    await page.evaluate(`window.confirm = () => false; document.querySelector('[data-action=open-notes]').click()`);
    assert.ok(await page.evaluate("!document.getElementById('ai-chat-view').hidden && !!document.getElementById('ai-pending-reply')"),
      'canceling a switch preserves the running stream');
    event('delta', { text: '原笔记 `[N1]`\n\n' });
    await until(() => page.evaluate("!!document.querySelector('#ai-pending-reply .citation-chip')"), 'early citation rendered');
    const detail = await page.evaluate(`
      window.frozenReply = document.querySelector('#ai-pending-reply p');
      frozenReply.querySelector('button').click();
      [document.getElementById('note-dialog').open, document.getElementById('detail-body').textContent]
    `);
    assert.deepEqual(detail, [true, bodyA]);
    await page.evaluate("document.querySelector('[data-action=reader-back]').click()");
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

test('Chromium verifies the shared AI space and the reader stack, tombstones and undo',
  { timeout: 30_000 }, async t => {
    assert.ok(chrome, 'Chromium binary is required (set WEIJI_TEST_CHROME)');
    const tab = await headless(t);
    const thirdId = '33333333-3333-4333-8333-333333333333';
    const noteA = { ...note('随机读起点 A，验证返回导航。', id), revision: 1,
      reading: { bookTitle: '读书测试', chapter: '第一章' }, turns: [{ role: 'user', text: '问题' }, { role: 'assistant', text: '回答' }] };
    const noteB = { ...note('随机读中继 B，验证同步删除回退。', anotherId), revision: 1 };
    const noteC = { ...note('随机读终点 C，验证三跳历史清理。', thirdId), revision: 1 };
    const noteMap = new Map([[noteA.id, noteA], [noteB.id, noteB], [noteC.id, noteC]]);
    const extra = Array.from({ length: 24 }, (_, i) => ({
      ...note('长笔记用于测试列表滚动恢复 #阅读\n'.repeat(8), '44444444-4444-4444-8444-' + String(i).padStart(12, '0')), revision: 1,
    }));
    let liveNotes = [noteA, noteB, noteC, ...extra];
    let undoPayload;
    let insightRun;
    let undoChat;
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
        undoPayload = body;
        const restored = { ...body.note, updatedAt: body.note.createdAt, revision: 1 };
        liveNotes.push(restored);
        return json(res, { note: restored });
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
      if (pathname === '/api/insights/lenses') return json(res, { lenses: [{ id: 'review', name: '本周回顾', suggestedRange: '7d', featured: true, builtin: true }] });
      if (pathname === '/api/insights/reports') return json(res, { reports: [{ id: 'old-report', title: '旧报告', createdAt }] });
      if (pathname === '/api/insights/run' || pathname === '/api/ai/chat') {
        const chunks = [];
        for await (const chunk of req) chunks.push(chunk);
        const body = JSON.parse(Buffer.concat(chunks).toString('utf8'));
        if (pathname.endsWith('/run')) {
          insightRun = body;
          const report = { id: 'report', title: '本月报告', lensName: '本周回顾', scope: body.scope, content: '报告正文',
            citations: [], model: body.model, noteCount: 3, analyzedCount: 3, createdAt };
          return res.writeHead(200, { 'Content-Type': 'text/event-stream' }).end(
            `event: delta\ndata: ${JSON.stringify({ text: '报告正文' })}\n\nevent: done\ndata: ${JSON.stringify({ report })}\n\n`);
        }
        undoChat = body;
        return res.writeHead(200, { 'Content-Type': 'text/event-stream' }).end(
          'event: error\ndata: {"error":"测试中断"}\n\n');
      }
      if (pathname === '/api/ai/sessions') {
        const source = new URL(req.url, origin).searchParams.get('sourceNoteId');
        if (!source) return json(res, { sessions: [{ id: 'history-session', title: '已有会话', createdAt }] });
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
        assert.equal(new URL(req.url, origin).searchParams.get('limit'), '3');
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

    const click = selector => page.evaluate(`document.querySelector(${JSON.stringify(selector)}).click()`);
    const action = name => '[data-action=' + name + ']';
    const has = selector => page.evaluate(`Boolean(document.querySelector(${JSON.stringify(selector)})?.getClientRects().length)`);
    const shown = selector => until(() => has(selector), 'visible ' + selector);
    const focusId = () => page.evaluate("document.getElementById('detail-body').dataset.noteId");
    const related = '#reader-related-list [data-open-note]';
    const relatedId = () => page.evaluate(`document.querySelector('${related}')?.dataset.openNote`);
    const open = noteId => click(`#feed [data-open-note="${noteId}"]`);
    const back = () => click(action('reader-back'));
    assert.deepEqual(await page.evaluate(`[...document.querySelectorAll('.space-nav button')].map(button => button.textContent)`), ['笔记', 'AI']);
    assert.equal(await page.evaluate("document.querySelectorAll('#random-walk-overlay, #ai-insights-view, #refresh-button, #i-spark, .ai-origin-filters, svg.rw-links').length"), 0);

    // Both new and existing note conversations still pin the source and load stored turns.
    for (const current of [noteA, noteB]) {
      await open(current.id);
      await click(action('reader-options'));
      await click(action('open-note-ai-chat'));
      await shown(`#ai-pinned-notes [data-remove-pin="${current.id}"]`);
      await until(() => page.evaluate("!document.getElementById('ai-chat-send').disabled"), 'source conversation loaded');
      assert.ok((await page.evaluate("document.getElementById('ai-turns').textContent")).includes(current === noteA ? '回答' : '历史回答'));
      await click(action('open-notes'));
    }

    await click(action('open-ai-chat'));
    await click(action('ai-new-session'));
    await shown(action('ins-run-lens'));
    assert.equal(await has(action('ai-new-session')), false);
    await click(action('ins-lens-range'));
    const heights = await page.evaluate(`['#ins-range-select', '#ins-tag-trigger', '.ins-profile-toggle'].map(s => document.querySelector(s).getBoundingClientRect().height)`);
    assert.ok(heights.every(height => height > 0 && Math.abs(height - heights[0]) <= 2), 'range control heights: ' + heights);
    await page.evaluate(`const range = document.getElementById('ins-range-select'); range.value = 'month'; range.dispatchEvent(new Event('change'));`);
    await click(action('ins-close-scope'));

    await click(action('ai-options'));
    assert.match(await page.evaluate("document.querySelector('#ai-model-toggle').textContent"), /^Gemini 4 Neon/);
    await click('#ai-model-toggle');
    await page.evaluate(`const search = document.getElementById('ai-model-search'); search.value = 'gpt'; search.dispatchEvent(new InputEvent('input', { bubbles: true }));`);
    assert.ok(await has('#ai-model-popover'));
    assert.match(await page.evaluate("document.getElementById('ai-model-options').textContent"), /GPT-6.2 Sol/);
    await click('#ai-model-options button');
    assert.equal(await has('#ai-model-popover'), false);
    assert.match(await page.evaluate("document.querySelector('#ai-model-toggle').textContent"), /^GPT-6.2 Sol/);
    assert.equal(await page.evaluate("document.querySelectorAll('[class*=ai-vendor-]').length"), 0);
    await click('#ai-model-toggle');
    assert.ok(await has('#ai-model-popover'));
    await page.evaluate("document.getElementById('ai-model-search').dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true }))");
    assert.equal(await has('#ai-model-popover'), false);

    for (let i = 0; i < 2; i++) {
      await click('.top-nav [data-ai-nav] ' + action('open-settings'));
      await click('[data-action=settings-pane][data-pane=ai]');
      await until(() => page.evaluate("document.querySelector('#profile-body').textContent.includes('画像测试正文')"), 'profile loaded from settings');
      await click('[data-close=settings-dialog]');
      await until(() => page.evaluate("document.querySelector('#profile-body').textContent === ''"), 'profile cleared on close');
    }
    assert.equal(profileLoads, 2);
    await click(action('ai-options'));
    assert.match(await page.evaluate("document.querySelector('#ai-model-toggle').textContent"), /^GPT-6.2 Sol/);
    await click(action('ai-options'));
    await click(action('ins-run-lens'));
    await until(() => page.evaluate("document.getElementById('ins-report-body').textContent.includes('报告正文') && !document.getElementById('ins-report-actions').hidden"), 'streamed report complete');
    assert.equal(insightRun.scope.range, 'month');
    assert.equal(insightRun.model, 'gpt-6.2-sol');
    assert.equal(await has(action('ai-new-session')), true);
    await page.evaluate(`const box = document.getElementById('ai-chat-input'); box.value = '继续追问';
      for (const extra of [{ isComposing: true }, { keyCode: 229 }]) {
        box.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', ctrlKey: true, bubbles: true, ...extra }));
      }`);
    assert.equal(undoChat, undefined, 'IME does not send a chat message');
    assert.equal(await page.evaluate("document.getElementById('ai-chat-input').value"), '继续追问');
    await page.evaluate("document.getElementById('ai-chat-form').requestSubmit()");
    await until(() => page.evaluate("document.getElementById('ai-chat-error').textContent.includes('测试中断')"), 'follow-up sent directly from report');
    assert.match(undoChat.message, /报告正文[\s\S]*继续追问/);
    await click(action('ai-toggle-sessions'));
    const history = await page.evaluate("document.getElementById('ai-session-list').textContent");
    for (const entry of ['本月报告', '旧报告', '已有会话']) assert.ok(history.includes(entry), entry + ' appears in unified history');
    await click(action('ai-close-history'));
    await click(action('open-notes'));
    assert.deepEqual(await page.evaluate(`[...document.querySelectorAll('.space-nav [aria-current="page"]')].map(n => n.dataset.action)`), ['open-notes']);

    await page.evaluate(`const input = document.getElementById('note-body'); input.value = '输入中的草稿';
      input.dispatchEvent(new InputEvent('input', { bubbles: true }));
      for (const extra of [{ isComposing: true }, { keyCode: 229 }]) {
        input.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', ctrlKey: true, bubbles: true, ...extra }));
      }`);
    assert.equal(undoPayload, undefined, 'IME does not save a note');
    assert.equal(await page.evaluate("document.getElementById('note-body').value"), '输入中的草稿');

    // Fresh snapshot invalidates related results from the note-chat entries above.
    const updated = extra.at(-1);
    liveNotes = liveNotes.map(item => item.id === updated.id ? { ...item, body: '更新快照 ' + item.body, revision: 2 } : item);
    await page.evaluate("window.dispatchEvent(new Event('focus'))");
    await until(() => page.evaluate("document.getElementById('note-list').textContent.includes('更新快照')"), 'fresh notes snapshot');
    // Use a deterministic shuffle so the test exercises the entire three-note cycle.
    await page.evaluate(`Math.random = () => 0; window.scrollTo(0, 520);`);
    const listScroll = await page.evaluate('window.scrollY');
    assert.ok(listScroll > 0);
    await click(action('open-random-walk'));
    assert.equal(await focusId(), noteA.id);
    assert.ok(await has(action('reader-shuffle')));
    await shown(related);
    assert.equal(await relatedId(), noteB.id);
    await click('#detail-body');
    assert.equal(await page.evaluate("document.getElementById('edit-form').hidden"), true, 'body never starts editing');
    await click(action('edit-note'));
    assert.equal(await has('#edit-body'), true);
    assert.equal(await has('#reader-save'), true);
    await page.evaluate(`(() => {
      const box = document.getElementById('edit-body');
      box.value = '未保存的正文修改';
      window.__origConfirm = window.confirm;
      window.__confirmCalls = 0;
      window.confirm = () => { window.__confirmCalls++; return false; };
    })()`);
    await back();
    assert.equal(await page.evaluate('window.__confirmCalls'), 1, 'canceling dirty edit asks confirmation');
    assert.equal(await has('#edit-body'), true, 'declining discard keeps editor open');
    assert.equal(await page.evaluate("document.getElementById('edit-body').value"), '未保存的正文修改', 'declining discard preserves exact text');
    await page.evaluate('window.confirm = () => true;');
    await back();
    await page.evaluate('window.confirm = window.__origConfirm; delete window.__origConfirm; delete window.__confirmCalls;');
    assert.equal(await has('#edit-body'), false);

    // Returning to a completed hop reuses related notes; a held, abandoned hop is fetched once on re-entry.
    holdNextRelated = true;
    const heldStarted = new Promise(resolve => { heldRelatedStarted = resolve; });
    const beforeHeld = relatedRequests;
    await click(related);
    await heldStarted;
    assert.equal(await focusId(), noteB.id);
    await back();
    assert.equal(await focusId(), noteA.id);
    releaseHeldRelated?.();
    assert.equal(relatedRequests, beforeHeld + 1);
    await click(related);
    await shown(related);
    assert.equal(await relatedId(), noteC.id);
    assert.equal(relatedRequests, beforeHeld + 2);
    await click(related);
    await shown(related);
    assert.equal(await relatedId(), noteA.id);
    await click(related);
    await shown(related);
    assert.equal(await focusId(), noteA.id);
    assert.equal(await relatedId(), noteB.id);
    assert.equal(relatedRequests, beforeHeld + 3, 'completed earlier hops did not refetch');

    liveNotes = liveNotes.filter(n => n.id !== noteB.id);
    deletedNotes = [{ id: noteB.id, revision: 2 }];
    await page.evaluate("window.dispatchEvent(new Event('focus'))");
    await until(async () => !await has(related), 'remote delete prunes related note while reader remains open');
    assert.equal(await focusId(), noteA.id);
    await back();
    assert.equal(await focusId(), noteC.id);
    await shown(related);
    assert.equal(await relatedId(), noteA.id);
    await back();
    assert.equal(await focusId(), noteA.id, 'earlier duplicate hop survives pruning the middle hop');
    await back();
    assert.equal(await has('#note-dialog'), false);
    assert.equal(await page.evaluate('window.scrollY'), listScroll, 'reader restores exact list position');
    await open(noteA.id);
    assert.equal(await has(action('reader-shuffle')), false, 'list and random read share the same modal');
    await click(action('reader-options'));
    await click(action('delete-note'));
    await shown(action('confirm-delete'));
    const getsBeforeLocalDelete = getNotesCount;
    await click(action('confirm-delete'));
    await shown(action('undo-delete'));
    assert.equal(postDeleteCount, 1);
    assert.equal(getNotesCount, getsBeforeLocalDelete, 'local delete does not wait for GET /api/notes');
    assert.equal(await has(`#feed [data-note-id="${noteA.id}"]`), false);
    await click(action('undo-delete'));
    await until(() => page.evaluate("document.getElementById('delete-undo').hidden"), 'restored note saved');
    assert.equal(undoPayload.expectedRevision, 0);
    assert.notEqual(undoPayload.id, noteA.id);
    assert.deepEqual(undoPayload.note, { id: undoPayload.id, body: noteA.body, createdAt: noteA.createdAt, reading: noteA.reading, turns: noteA.turns });
    assert.ok(deletedNotes.some(item => item.id === noteA.id), 'original tombstone stays');
    assert.equal(await page.evaluate(`document.querySelector('#feed [data-note-id="${undoPayload.id}"]').closest('.day-group').dataset.day`),
      await page.evaluate(`document.querySelector('#feed [data-note-id="${noteC.id}"]').closest('.day-group').dataset.day`));

    // Remote delete while editing preserves copyable draft and exits cleanly once discard is confirmed.
    await open(noteC.id);
    await click(action('edit-note'));
    await page.evaluate(`document.getElementById('edit-body').value = '尚未保存的远端删稿'`);
    liveNotes = liveNotes.filter(n => n.id !== noteC.id);
    deletedNotes = [...deletedNotes, { id: noteC.id, revision: 2 }];
    await page.evaluate("window.dispatchEvent(new Event('focus'))");
    await until(() => page.evaluate("document.getElementById('detail-error').textContent.includes('另一端删除')"), 'remote delete notice shown during edit');
    assert.equal(await page.evaluate("document.getElementById('edit-body').value"), '尚未保存的远端删稿');
    await page.evaluate('window.__origConfirm = window.confirm; window.confirm = () => true;');
    await back();
    await page.evaluate('window.confirm = window.__origConfirm; delete window.__origConfirm;');
    assert.equal(await page.evaluate("document.getElementById('note-dialog').open"), false, 'confirming cancel on remotely deleted note closes reader cleanly');
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

async function paperFixture(t) {
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
    ['/api/insights/lenses', { lenses: [{ id: 'review', name: '本周回顾', suggestedRange: '7d', featured: true, builtin: true }] }],
    ['/api/insights/reports', { reports: [] }],
    ['/api/ai/profile', { profile: null }],
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

async function measurePaper(page, targets) {
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

test('Paper and ink light/dark themes maintain opaque surfaces, AA roles and AAA emphasis',
  { timeout: 30_000 }, async t => {
    const open = await paperFixture(t);
    for (const scheme of ['light', 'dark']) {
      const page = await open({ scheme });
      const click = selector => page.evaluate(`document.querySelector(${JSON.stringify(selector)}).click()`);
      const notes = await measurePaper(page, [
        ['body'], ['.space-nav [aria-current]'], ['.top-nav [data-action=open-sidebar]:not(.mobile-only)'],
        ['.card-body'], ['.day-head'], ['.inline-tag'], ['#note-body', '::placeholder'],
      ]);
      assert.equal(await page.evaluate("document.querySelector('.top-nav').getBoundingClientRect().height"), 60);
      const accent = await page.evaluate("getComputedStyle(document.documentElement).getPropertyValue('--accent').trim()");
      assert.equal(accent, scheme === 'light' ? '#1D4D3A' : '#9AC4AE');
      assert.deepEqual(notes.body.bg, scheme === 'light' ? [250, 248, 244, 255] : [21, 21, 20, 255]);
      assert.ok(await page.evaluate(`[...document.querySelectorAll('#feed .note-card, .day-group')].every(node => {
        const s = getComputedStyle(node);
        return s.backgroundColor === 'rgba(0, 0, 0, 0)' && s.boxShadow === 'none' &&
          ['Top','Right','Bottom','Left'].every(side => s['border' + side + 'Width'] === '0px');
      })`), 'feed notes and days are frameless');
      assert.equal(await page.evaluate("document.getElementById('sync-state').getBoundingClientRect().height"), 0);
      await click('.top-nav [data-action=open-sidebar]:not(.mobile-only)');
      const drawer = await measurePaper(page, [['.nav-item.active'], ['.stats-toggle'], ['.nav-label-row'], ['.date-filter label']]);
      await click('[data-action=close-sidebar]');
      await click('.top-nav #note-nav-actions [data-action=open-settings]');
      await click('[data-action=settings-pane][data-pane=data]');
      await click('[data-action=open-import-hub]');
      const imports = await measurePaper(page, [['#import-hub-title'], ...['open-flomo-import', 'open-joplin-import', 'open-import']
        .map(action => ['#import-hub-dialog [data-action=' + action + ']'])]);
      await click('[data-close=import-hub-dialog]');
      await click('[data-close=settings-dialog]');
      await click('[data-action=open-ai-chat]');
      await until(() => page.evaluate("!!document.querySelector('[data-action=ai-select-session]') && !!document.querySelector('[data-action=ins-lens-range]')"), 'AI history and lenses loaded');
      await click('[data-action=ai-toggle-sessions]');
      const history = await measurePaper(page, [['.ai-session-title'], ['.history-group']]);
      await click('[data-action=ai-select-session]');
      await until(() => page.evaluate("!!document.querySelector('.ai-steps-card') && document.querySelector('#ai-model-toggle').textContent.includes('Gemini')"), 'AI transcript and model loaded');
      await click('.ai-steps-card summary');
      await click('[data-action=ai-options]');
      await click('#ai-model-toggle');
      const chat = await measurePaper(page, [
        ['#ai-chat-view'], ['.ai-msg-user'], ['#ai-turns .ai-msg-assistant p'], ['.citation-chip'],
        ['.ai-steps-card summary'], ['.ai-step-heading strong'], ['#ai-chat-input', '::placeholder'],
        ['#ai-model-options [aria-pressed=true] .ai-picker-label'], ['#ai-model-search', '::placeholder'],
      ]);
      assert.deepEqual(chat['#ai-chat-view'].bg, notes.body.bg);
      await click('[data-action=ai-options]');
      await click('[data-action=ai-new-session]');
      await click('[data-action=ins-lens-range]');
      const insights = await measurePaper(page, [
        ['#ai-empty'], ['#ins-scope'], ['#ins-range-select'], ['#ins-tag-trigger'], ['.ins-profile-toggle'],
      ]);
      await page.login();
      await until(() => page.evaluate("location.pathname === '/login' && document.readyState === 'complete' && !!document.querySelector('.auth-shell')"), 'real login page loaded');
      const login = await measurePaper(page, [['.auth-shell'], ['.auth-page h1'], ['.auth-providers a'], ['.auth-footer a']]);
      assert.deepEqual(login['.auth-shell'].bg, notes.body.bg);

      for (const [selector, sample] of Object.entries({ ...notes, ...drawer, ...imports, ...history, ...chat, ...insights, ...login })) {
        assert.equal(sample.bg[3], 255, `${scheme} ${selector} should resolve to an opaque surface`);
        const minimum = ['body', '.card-body', '.inline-tag', '.citation-chip', '#ai-turns .ai-msg-assistant p'].includes(selector) ? 7 : 4.5;
        assert.ok(sample.ratio >= minimum, `${scheme} ${selector} contrast ${sample.ratio.toFixed(3)}:1`);
        if (scheme === 'dark') {
          assert.ok(sample.bright < 0.12, `dark ${selector} background luminance ${sample.bright}`);
          assert.ok(sample.bg[0] >= sample.bg[2] || ['.inline-tag', '.citation-chip', '#ai-model-options [aria-pressed=true] .ai-picker-label', '.nav-item.active', '.ai-msg-user'].includes(selector),
            `dark ${selector} should use a warm neutral or a branded container: ${sample.bg}`);
        }
      }
    }
  });

test('Paper and ink mobile 375px enforces real 48px hit targets without overflow',
  { timeout: 30_000 }, async t => {
    const open = await paperFixture(t);
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
    const click = selector => page.evaluate(`document.querySelector(${JSON.stringify(selector)}).click()`);
    check(await layout([
      ['#mobile-toggle', true], ['.space-nav button', true], ['#note-nav-actions [data-action=open-random-walk]', true],
      ['.compose-fab', true], ['#save-note', true], ['.inline-tag', true],
    ]));
    await click('#mobile-toggle');
    assert.equal(await page.evaluate("document.querySelector('[data-action=toggle-stats]').getAttribute('aria-expanded')"), 'false');
    assert.equal(await page.evaluate("document.getElementById('heatmap').getBoundingClientRect().height"), 0);
    assert.equal(await page.evaluate("document.getElementById('mini-pulse').childElementCount"), 7);
    check(await layout([['.nav-item', true], ['.tag-toggle', true], ['#sort-button', true], ['#date-filter', true], ['[data-action=toggle-stats]', true]]));
    await click('[data-action=toggle-stats]');
    check(await layout([['button.heatmap-square', true]]));
    const cells = await page.evaluate(`(() => {
      const heatmap = document.querySelector('.heatmap');
      const buttons = [...heatmap.querySelectorAll('button[data-level="1"]')];
      buttons[0].scrollIntoView({ block: 'center', inline: 'center' });
      const style = getComputedStyle(heatmap);
      return { gridWidth: heatmap.clientWidth, scrollWidth: heatmap.scrollWidth, count: heatmap.childElementCount,
        border: style.borderWidth, shadow: style.boxShadow, background: style.backgroundColor,
        expanded: document.querySelector('[data-action=toggle-stats]').getAttribute('aria-expanded'),
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
    assert.equal(cells.expanded, 'true');
    assert.equal(cells.count, 84);
    assert.equal(cells.border, '0px');
    assert.equal(cells.shadow, 'none');
    assert.equal(cells.background, 'rgba(0, 0, 0, 0)');
    assert.ok(cells.scrollWidth <= cells.gridWidth, 'heatmap must not overflow horizontally');
    assert.equal(cells.cells.length, 2, 'two adjacent dates have matching notes');
    const [a, b] = cells.cells;
    assert.ok(b.left >= a.right - 1 || b.top >= a.bottom - 1, 'adjacent date hit boxes must not overlap');
    assert.ok(a.hit && b.hit, 'all four corners inset by 2px must hit their own date button');
    assert.ok(a.centerHit && b.centerHit, 'both date button centers must hit their own date button');
    await click('button.heatmap-square[data-level="1"]');
    assert.equal(await page.evaluate("document.querySelectorAll('#feed .note-card').length"), 1);
    await click('#mobile-toggle');
    await page.send('Input.dispatchKeyEvent', { type: 'keyDown', key: 'Escape', code: 'Escape', windowsVirtualKeyCode: 27 });
    await page.send('Input.dispatchKeyEvent', { type: 'keyUp', key: 'Escape', code: 'Escape', windowsVirtualKeyCode: 27 });
    await until(() => page.evaluate("!document.getElementById('sidebar').open && document.activeElement.id === 'mobile-toggle'"), 'Escape restores drawer trigger focus');
    await click('#mobile-toggle');
    await click('#sidebar [data-action=toggle-search]');
    check(await layout([['#search', true]]));
    const bar = await page.evaluate(`(() => {
      const nav = document.querySelector('#notes-topbar').getBoundingClientRect();
      const search = document.querySelector('.search-field').getBoundingClientRect();
      return { right: nav.right, firstBottom: nav.bottom, searchTop: search.top, searchWidth: search.width };
    })()`);
    assert.ok(bar.right <= 375, 'top bar overflows: ' + bar.right);
    assert.ok(bar.searchTop >= bar.firstBottom && bar.searchWidth >= 335, 'search needs its own full-width row');

    await click('[data-action=open-ai-chat]');
    await until(() => page.evaluate("!!document.querySelector('[data-action=ins-lens-range]')"), 'mobile lenses loaded');
    await click('[data-action=ins-lens-range]');
    check(await layout([['#ins-range-select', true], ['#ins-tag-trigger', true], ['.ins-profile-toggle', true]]));
    await click('[data-action=ins-close-scope]');
    await click('[data-action=ai-options]');
    check(await layout([['[data-action=ai-toggle-sessions]', true], ['[data-action=ai-options]', true], ['[data-action=ins-new-lens]', true], ['#ai-model-toggle', true], ['#ai-style-toggle', true], ['#ai-chat-send', true]]));
    await click('#ai-model-toggle');
    check(await layout([['#ai-model-search', true], ['.ai-picker-row', true]]));
    await click('#ai-options [data-action=open-settings]');
    await click('[data-action=settings-pane][data-pane=ai]');
    check(await layout([['#ins-panel-profile .profile-actions button', true], ['.profile-toggle', true], ['.profile-subtabs button', true]]));
    await click('[data-close=settings-dialog]');
    await click('[data-action=open-notes]');
    await click('[data-action=open-random-walk]');
    check(await layout([['.reader-nav button', true]]));
    await click('[data-action=reader-options]');
    check(await layout([['#reader-options button', true]]));
    await click('[data-action=reader-back]');
    await click('#mobile-toggle');
    await click('#sidebar [data-action=open-settings]');
    await click('[data-action=settings-pane][data-pane=data]');
    await click('[data-action=open-import-hub]');
    const sources = await layout([['#import-hub-dialog .import-sources button', true]]);
    assert.equal(sources.targets.length, 3);
    check(sources);
    await click('#import-hub-dialog [data-action=open-import]');
    assert.equal(await page.evaluate("document.querySelector('#import-dialog').open && !document.querySelector('#import-hub-dialog').open"), true);
  });
