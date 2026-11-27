import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { once, EventEmitter } from 'node:events';
import { existsSync } from 'node:fs';
import { mkdir, mkdtemp, readFile, rm, utimes, writeFile } from 'node:fs/promises';
import { createServer } from 'node:http';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { DatabaseSync } from 'node:sqlite';
import { setTimeout as delay } from 'node:timers/promises';
import test from 'node:test';
import worker from '../dist/server/index.js';
import { parseJoplinFiles, parseJoplinJex, parseJoplinMarkdownFiles } from '../public/joplin.js';
import { tagsFor } from '../public/ux-helpers.js';
import { applyMigrations } from '../src/auth.js';

const date = '2026-11-26 09:30:00Z';
const isoDate = '2026-11-26T09:30:00.000Z';
const id = n => n.toString(16).padStart(32, '0');
const raw = (n, type, text = '', fields = {}) => text + '\n\nid: ' + id(n) + '\n'
  + Object.entries(fields).map(([key, value]) => key + ': ' + value + '\n').join('') + 'type_: ' + type + '\n';
const rawNote = (n, title, body, fields) => raw(n, 1, title + '\n\n' + body, { created_time: date, ...fields });

function header(name, size, { type = '0', prefix = '', binary = false } = {}) {
  const block = Buffer.alloc(512);
  block.write(name, 0, 100);
  block.write('0000644\0', 100);
  block.write('0000000\0', 108);
  block.write('0000000\0', 116);
  if (binary) {
    block[124] = 128;
    block.writeBigUInt64BE(BigInt(size), 128);
  } else block.write(size.toString(8).padStart(11, '0') + '\0', 124);
  block.write('00000000000\0', 136);
  block.fill(32, 148, 156);
  block.write(type, 156);
  block.write('ustar\0', 257);
  block.write('00', 263);
  block.write(prefix, 345, 155);
  const checksum = block.reduce((sum, byte) => sum + byte, 0);
  block.write(checksum.toString(8).padStart(6, '0') + '\0 ', 148);
  return block;
}

function tarEntry(name, content, options = {}) {
  const payload = Buffer.from(content);
  return Buffer.concat([header(name, options.size ?? payload.length, options),
    payload, Buffer.alloc((512 - payload.length % 512) % 512)]);
}

function pax(key, value) {
  const tail = ' ' + key + '=' + value + '\n';
  const length = Buffer.byteLength(tail);
  let size = length + 1;
  while (size !== length + String(size).length) size = length + String(size).length;
  return String(size) + tail;
}

const archive = (...entries) => new File([...entries, Buffer.alloc(1024)], 'test.jex');
const md = (name, source, { path, lastModified = Date.parse(isoDate) } = {}) => {
  const file = new File([source], name, { lastModified });
  if (path) Object.defineProperty(file, 'webkitRelativePath', { value: path });
  return file;
};

function richArchive() {
  const body = '[另一条笔记](:/' + id(2) + ')\n![图](:/' + id(10) + ')\n<a href=":/' + id(11) + '">PDF</a>';
  const note = rawNote(1, '会议记录', body, { parent_id: id(4), user_created_time: date });
  return archive(
    tarEntry('PaxHeader', pax('path', '导出/会议记录.md') + pax('size', Buffer.byteLength(note)), { type: 'x' }),
    tarEntry('placeholder', note, { size: 0 }),
    tarEntry('second.md', rawNote(2, '第二条', '正常内容', { parent_id: id(5) }), { binary: true }),
    tarEntry('LongLink', '导出/' + '长'.repeat(60) + '.md\0', { type: 'L' }),
    tarEntry('placeholder', raw(4, 2, '项目 A', { parent_id: id(3) })),
    tarEntry('work.md', raw(3, 2, '工作'), { prefix: 'folders' }),
    tarEntry('year.md', raw(5, 2, '2026')),
    tarEntry('tag1.md', raw(6, 5, '自定义 Tag')),
    tarEntry('tag2.md', raw(7, 5, '自定义 tag')),
    tarEntry('link1.md', raw(8, 6, '', { note_id: id(1), tag_id: id(6) })),
    tarEntry('link2.md', raw(9, 6, '', { note_id: id(1), tag_id: id(7) })),
    tarEntry('resource1.md', raw(10, 4)),
    tarEntry('resource2.md', raw(11, 4)),
    tarEntry('locked.md', rawNote(12, '锁定', '不能导入', { is_locked: 1 })),
    tarEntry('encrypted.md', rawNote(13, '加密', '密文', { encryption_applied: 1 })),
    tarEntry('revision.md', raw(14, 13, '历史版本')),
    tarEntry('hidden.md', rawNote(15, '隐藏', '不导入'), { prefix: 'resources' }),
    tarEntry('resources/' + id(10) + '.png', Buffer.alloc(2000, 255)),
  );
}

test('Joplin parser: JEX resolves USTAR, GNU and UTF-8 PAX entries and distinguishes attachments from note links', async () => {
  const file = richArchive();
  const result = await parseJoplinJex(file);
  assert.equal(result.notes.length, 2);
  assert.equal(result.skippedAttachments, 2);
  assert.equal(result.skippedEncrypted, 2);
  assert.equal(result.notes[0].createdAt, isoDate);
  assert.deepEqual(tagsFor(result.notes[0].body), ['工作/项目_A', '自定义_Tag']);
  assert.deepEqual(tagsFor(result.notes[1].body), ['joplin/2026']);
  const { notes } = await parseJoplinFiles([file]);
  assert.deepEqual(notes.map(note => note.id), result.notes.map(note => note.id));
  assert.ok(notes.every(note => /^[0-9a-f]{8}-[0-9a-f]{4}-8[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.test(note.id)));

  const slashArchive = archive(
    tarEntry('f1.md', raw(30, 2, '客户/项目')),
    tarEntry('f2.md', raw(31, 2, '客户')),
    tarEntry('f3.md', raw(32, 2, '项目', { parent_id: id(31) })),
    tarEntry('n1.md', rawNote(33, '单层含斜杠', '内容一', { parent_id: id(30) })),
    tarEntry('n2.md', rawNote(34, '双层笔记本', '内容二', { parent_id: id(32) })),
  );
  const slashRes = await parseJoplinJex(slashArchive);
  assert.equal(slashRes.notes.length, 2);
  assert.deepEqual(tagsFor(slashRes.notes[0].body), ['客户_项目']);
  assert.deepEqual(tagsFor(slashRes.notes[1].body), ['客户/项目']);
});

test('Joplin parser: preserves original Markdown and only deduplicates an actual matching H1', async () => {
  const bodies = ['# 预算\r\n\r\n    const x = 1;\r\na\r\n\r\n\r\nb  \r\n',
    '    # 会议记录\n代码', '# 会议记录\n正文', '   # 会议记录\n正文', '    e\u0301\n'];
  const expected = bodies.map((body, i) => (i === 2 || i === 3 ? '' : '# 会议记录\n\n') + body.replace(/\r\n/g, '\n'));
  const { notes } = await parseJoplinJex(archive(...bodies.map((body, i) =>
    tarEntry(i + '.md', rawNote(i + 1, '会议记录', body)))));
  assert.deepEqual(notes.map(note => note.body), expected);
  const markdown = await parseJoplinMarkdownFiles(bodies.map(body => md('会议记录.md', body)));
  assert.deepEqual(markdown.notes.map(note => note.body), expected);

  const hashTitles = await parseJoplinMarkdownFiles([
    md('C#.md', '# C#\n正文'),
    md('C.md', '# C#\n正文'),
    md('C.md', '# C ##\n正文'),
  ]);
  assert.deepEqual(hashTitles.notes.map(note => note.body), ['# C#\n正文', '# C\n\n# C#\n正文', '# C ##\n正文']);
});

test('Joplin parser: accepts upstream front matter, decodes BOMs and filters non-note targets', async () => {
  const source = '---\ntitle: >-\n  这个很长的标题\n  继续一行\ncompleted?: no\ndue: ' + date + '\ncreated: ' + date
    + '\ntags:\n- 远程\n- >-\n  项目\n  计划\n---\n\n    a\n\n\n'
    + '[互链](./other.md) ![图](../_resources/a.png) [合同](../_resources/合同.pdf)';
  const result = await parseJoplinFiles([
    md('笔记.md', source, { path: '导出目录/工作/项目 A/笔记.md' }),
    md('本地.markdown', '---\ntitle: "带引号"\ncreated: \'2026-11-26 09:30:00\'\n'
      + 'tags: [现有, "多字 标签", 2026]\nfolder: 公司/资料\n...\n\n#现有\n'
      + '[外链](https://example.org/_resources/a.pdf) ![笔记](./other.md)'),
    md('跳过.md', '忽略', { path: '导出目录/_resources/跳过.md' }),
    md('跳过.md', '忽略', { path: '导出目录/resources/跳过.md' }),
    md('跳过.md', '忽略', { path: '导出目录/.隐藏/跳过.md' }),
    md('附件.pdf', '忽略', { path: '导出目录/附件.pdf' }),
  ]);
  assert.equal(result.notes.length, 2);
  assert.equal(result.skippedAttachments, 2);
  assert.equal(result.notes[0].createdAt, isoDate);
  assert.equal(result.notes[0].body, '# 这个很长的标题 继续一行\n\n    a\n\n\n'
    + '[互链](./other.md) ![图](../_resources/a.png) [合同](../_resources/合同.pdf)\n\n#工作/项目_A #远程 #项目_计划');
  assert.equal(result.notes[1].createdAt, '2026-11-26T01:30:00.000Z');
  assert.deepEqual(tagsFor(result.notes[1].body), ['现有', '公司/资料', '多字_标签', 'joplin/2026']);
  const zero = await parseJoplinFiles([md('反例.md',
    '[外链](https://example.org/_resources/a.pdf) ![笔记](./other.md) <img src="#anchor">')]);
  assert.equal(zero.skippedAttachments, 0);
  const html = await parseJoplinFiles([md('附件.md',
    '[音频](../resources/a.mp3) <img src="local.png"> <a href="../_resources/b.pdf">PDF</a>')]);
  assert.equal(html.skippedAttachments, 3);

  const unicode = Buffer.from('\ufeff---\ntitle: |-\n  保留\n  换行\ndate: "2026-11-26T09:30:00+02:00"\n---\n正文', 'utf16le');
  for (const bytes of [unicode, Buffer.from(unicode).swap16()]) {
    const { notes: [note] } = await parseJoplinFiles([md('BOM.md', bytes)]);
    assert.equal(note.body, '# 保留\n换行\n\n正文');
    assert.equal(note.createdAt, '2026-11-26T07:30:00.000Z');
  }
  const apostrophe = await parseJoplinFiles([md('出版.md',
    "---\ntitle: 书单\ntags: [O'Reilly, Work, 'it''s ok', \"a, b\"]\n---\n正文")]);
  assert.deepEqual(tagsFor(apostrophe.notes[0].body), ['O_Reilly', 'Work', 'it_s_ok', 'a_b']);
  const commentedContinuation = await parseJoplinFiles([md('原文.md',
    '---\ntitle: # 项目名\n  预算\n---\n正文')]);
  assert.equal(commentedContinuation.notes[0].body, '# 预算\n\n正文');

  for (const text of ['---\n# 预算\n---\n正文', '---\ntitle: 正文\n仍然是正文',
    '---\n普通正文\n---\n下一段', '---\nunknown: value\n---\n正文',
    '---\ntitle: 预算\n未缩进正文\n---\n正文',
    '---\ntitle: 预算\ndraft: [未闭合\n---\n正文',
    '---\ntitle: 预算\ndraft: [草稿 # 注释]\n---\n正文',
    '---\ntitle: 预算\ndraft: &drafts [未闭合\n---\n正文',
    '---\ntitle: 预算\ndraft: &drafts {未闭合\n---\n正文',
    '---\ntitle: 预算\ndraft: !!seq [未闭合\n---\n正文',
    '---\ntitle: 预算\ndraft: # 备注\n  &drafts [未闭合\n---\n正文',
    '---\ntitle: 预算\ndraft: # 备注\n  &drafts {未闭合\n---\n正文',
    '---\ntitle: 预算\ndraft: # 备注\n  !!seq [未闭合\n---\n正文',
    '---\ntitle: 预算 # 注释\n  续行\n---\n正文',
    '---\ntitle: 预算\ndraft: {未闭合\n---\n正文']) {
    const { notes: [note] } = await parseJoplinFiles([md('原文.md', text)]);
    assert.equal(note.body, '# 原文\n\n' + text);
  }
});

test('Joplin parser: blocks oversized extension payloads before reading and rejects invalid inputs', async () => {
  for (const type of ['L', 'x']) {
    const size = 64 * 1024 + 1;
    const bad = archive(tarEntry('oversized', Buffer.alloc(size), { type }));
    const reads = [];
    await assert.rejects(parseJoplinJex({
      size: bad.size,
      slice(start, end) { reads.push([start, end]); return bad.slice(start, end); },
    }), /扩展头超过 64 KB/);
    assert.deepEqual(reads, [[0, 512]]);
  }
  await assert.rejects(parseJoplinJex(new Blob([header('note.md', 20), Buffer.alloc(20)])), /截断/);
  await assert.rejects(parseJoplinJex(new Blob([header('note.md', 200), Buffer.alloc(16)])), /截断/);
  const negative = header('bad.md', 1, { binary: true });
  negative[124] = 255;
  await assert.rejects(parseJoplinJex(new Blob([negative])), /归档格式无效/);
  const badChecksum = tarEntry('bad.md', rawNote(1, '不能导入', '归档头损坏'));
  badChecksum[0] ^= 1;
  await assert.rejects(parseJoplinJex(archive(badChecksum)), /归档格式无效/);
  await assert.rejects(parseJoplinJex(archive(tarEntry('ordinary.md', '非 Joplin 正文'))), /没有有效/);
  await assert.rejects(parseJoplinFiles([richArchive(), md('note.md', 'A')]), /不能混选/);
  await assert.rejects(parseJoplinFiles([richArchive(), richArchive()]), /一次只能/);
  await assert.rejects(parseJoplinFiles([]), /请选择/);
  await assert.rejects(parseJoplinFiles([md('note.txt', 'A')]), /没有可导入/);
});

test('Joplin parser: identities survive mtime changes and unrelated directory entries', async () => {
  const a = md('A.md', '正文', { path: '导出/A.md', lastModified: 1000 });
  const modified = md('A.md', '正文', { path: '另一个导出根/A.md', lastModified: 2000 });
  const b = md('B.md', '正文', { path: '导出/子目录/B.md' });
  const { notes: [first] } = await parseJoplinFiles([a]);
  const { notes: [second, other] } = await parseJoplinFiles([modified, b]);
  assert.equal(first.id, second.id);
  assert.notEqual(first.createdAt, second.createdAt);
  assert.deepEqual(tagsFor(first.body), []);
  assert.deepEqual(tagsFor(other.body), ['子目录']);
  const { notes } = await parseJoplinFiles([a, a]);
  assert.equal(notes[0].id, first.id);
  assert.notEqual(notes[1].id, first.id);
  const skipped = await parseJoplinFiles([md('.markdown', ''), md('无日期.md', '正文', { lastModified: 0 }),
    md(' .md', ' \n  ')]);
  assert.equal(skipped.skippedInvalidDate, 1);
  assert.equal(skipped.skippedEmpty, 1);
});

test('Joplin dist asset: built Worker serves the browser parser as JavaScript', async () => {
  const response = await worker.fetch(new Request('https://weiji.test/joplin.js'), {});
  assert.equal(response.status, 200);
  assert.match(response.headers.get('Content-Type'), /javascript/);
  assert.match(await response.text(), /parseJoplinFiles/);
});

async function fixture(t) {
  const db = new DatabaseSync(':memory:');
  t.after(() => db.close());
  await applyMigrations(db);
  const DB = {
    prepare(sql) {
      return { bind(...args) {
        const stmt = db.prepare(sql);
        const rows = () => ({ results: stmt.all(...args) });
        return { rows, all: async () => rows(), first: async () => stmt.get(...args) ?? null };
      } };
    },
    async batch(statements) {
      db.exec('BEGIN');
      try {
        const results = statements.map(statement => statement.rows());
        db.exec('COMMIT');
        return results;
      } catch (error) {
        db.exec('ROLLBACK');
        throw error;
      }
    },
  };
  const account = 'joplin-test';
  const call = (url, options) => worker.fetch(new Request(url, {
    method: options?.method,
    headers: {
      ...options?.headers,
      'oai-authenticated-user-id': account,
      'oai-authenticated-auth-mode': 'oauth',
    },
    body: options?.body,
  }), { DB });
  const post = async (path, body) => {
    const origin = 'https://weiji.test';
    const response = await call(origin + path, {
      method: 'POST', headers: { Origin: origin, 'Content-Type': 'application/json' }, body: JSON.stringify(body),
    });
    assert.equal(response.status, 200, await response.clone().text());
    return response.json();
  };
  const row = id => ({ ...db.prepare('SELECT revision, payload FROM journal_notes WHERE account = ? AND id = ?').get(account, id) });
  return { db, call, post, row };
}

test('Joplin API: import is idempotent and never replaces a delete tombstone', async t => {
  const { post, row } = await fixture(t);
  const { notes } = await parseJoplinFiles([richArchive()]);
  const first = await post('/api/import/joplin', { notes });
  assert.equal(first.skipped, 0);
  assert.deepEqual(first.notes.map(note => note.id), notes.map(note => note.id));
  assert.equal(JSON.parse(row(notes[0].id).payload).body, notes[0].body);
  assert.deepEqual(await post('/api/import/joplin', { notes }), { notes: [], skipped: 2 });
  const [{ id }] = notes;
  await post('/api/notes', { id, delete: true, expectedRevision: first.notes[0].revision });
  const tombstone = row(id);
  assert.deepEqual(tombstone, { revision: 2, payload: null });
  assert.deepEqual(await post('/api/import/joplin', { notes: [notes[0]] }), { notes: [], skipped: 1 });
  assert.deepEqual(row(id), tombstone);
});

const chrome = process.env.WEIJI_TEST_CHROME || [
  '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
  '/usr/bin/chromium', '/usr/bin/google-chrome',
].find(existsSync);

async function until(fn, description) {
  for (let i = 0; i < 240; i++) {
    const value = await fn();
    if (value) return value;
    await delay(25);
  }
  assert.fail('Timed out: ' + description);
}

async function headless(t, dir) {
  assert.ok(chrome, 'Chromium binary is required (set WEIJI_TEST_CHROME)');
  const profile = join(dir, 'chrome');
  const child = spawn(chrome, ['--headless', '--disable-gpu', '--disable-dev-shm-usage', '--no-first-run',
    ...(process.getuid?.() === 0 ? ['--no-sandbox'] : []),
    '--remote-debugging-port=0', '--user-data-dir=' + profile, 'about:blank'], { stdio: 'ignore' });
  let socket;
  t.after(async () => {
    socket?.close();
    if (child.exitCode === null && child.signalCode === null) {
      const exited = once(child, 'exit');
      child.kill();
      await exited;
    }
    await rm(dir, { force: true, recursive: true, maxRetries: 3 });
  });
  const port = await until(async () => (await readFile(join(profile, 'DevToolsActivePort'), 'utf8').catch(() => '')).split('\n')[0],
    'Chromium CDP port');
  const page = await (await fetch('http://127.0.0.1:' + port + '/json/new?about:blank', { method: 'PUT' })).json();
  socket = new WebSocket(page.webSocketDebuggerUrl);
  await once(socket, 'open');
  const events = new EventEmitter();
  const calls = new Map();
  let sequence = 0;
  socket.addEventListener('message', ({ data }) => {
    const message = JSON.parse(data);
    if (message.method) events.emit(message.method, message.params);
    const call = calls.get(message.id);
    if (!call) return;
    calls.delete(message.id);
    if (message.error) call.reject(new Error(JSON.stringify(message.error)));
    else call.resolve(message.result);
  });
  const send = (method, params) => new Promise((resolve, reject) => {
    const id = ++sequence;
    calls.set(id, { resolve, reject });
    socket.send(JSON.stringify({ id, method, params }));
  });
  const evaluate = async expression => {
    const { result, exceptionDetails } = await send('Runtime.evaluate', { expression, awaitPromise: true, returnByValue: true });
    if (exceptionDetails) throw new Error(result.description ?? exceptionDetails.text);
    return result.value;
  };
  await send('Page.enable');
  await send('DOM.enable');
  return { send, evaluate, events };
}

async function serve(t, call, onImport) {
  const server = createServer(async (req, res) => {
    try {
      const url = 'http://' + req.headers.host + req.url;
      const chunks = [];
      for await (const chunk of req) chunks.push(chunk);
      const body = chunks.length ? Buffer.concat(chunks) : undefined;
      if (req.method === 'POST' && req.url === '/api/import/joplin' && onImport(JSON.parse(body).notes)) {
        res.writeHead(500, { 'Content-Type': 'application/json' }).end('{"error":"测试注入：第 2 批失败"}');
        return;
      }
      const response = await call(url, { method: req.method, headers: req.headers, body });
      res.writeHead(response.status, Object.fromEntries(response.headers)).end(Buffer.from(await response.arrayBuffer()));
    } catch (error) {
      res.writeHead(500).end(String(error));
    }
  });
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  t.after(() => new Promise(resolve => { server.closeAllConnections(); server.close(resolve); }));
  return 'http://127.0.0.1:' + server.address().port;
}

test('Joplin E2E: desktop JEX and directory import, retry, tombstone, and 375px mobile layout', { timeout: 60_000 }, async t => {
  const { db, call, row } = await fixture(t);
  const requests = [];
  let failSecondBatch = false;
  const url = await serve(t, call, notes => {
    requests.push(notes.map(note => note.id));
    if (failSecondBatch && notes.length === 5) {
      failSecondBatch = false;
      return true;
    }
    return false;
  });
  const dir = await mkdtemp(join(tmpdir(), 'weiji-joplin-'));
  const { send, evaluate, events } = await headless(t, dir);
  const file = async (name, content) => {
    const path = join(dir, name);
    await writeFile(path, content);
    return path;
  };
  const selectFiles = async paths => {
    const { root: { nodeId } } = await send('DOM.getDocument');
    const input = await send('DOM.querySelector', { nodeId, selector: '#joplin-file' });
    await send('DOM.setFileInputFiles', { nodeId: input.nodeId, files: paths });
  };
  const click = selector => evaluate('document.querySelector(' + JSON.stringify(selector) + ').click()');
  const openImport = () => click('[data-action="open-joplin-import"]');
  const submit = () => click('#joplin-submit');
  const wait = (expression, description) => until(() => evaluate(expression), description);
  const preview = async count => {
    await submit();
    await wait('!document.querySelector("#joplin-preview").hidden && '
      + 'document.querySelector("#joplin-summary").textContent.includes("待导入 ' + count + ' 条")', 'preview ' + count + ' notes');
  };
  const save = async () => {
    await submit();
    await wait('!document.querySelector("#joplin-dialog").open', 'import completed');
  };
  const metrics = (width, height, mobile) => send('Emulation.setDeviceMetricsOverride', {
    width, height, deviceScaleFactor: 1, mobile,
  });
  await metrics(1280, 800, false);
  await send('Page.navigate', { url });
  await wait('document.querySelector("#sync-state")?.dataset.status === "ok"', 'account synced');
  await openImport();
  await selectFiles([await file('test.jex', Buffer.from(await richArchive().arrayBuffer()))]);
  await preview(2);
  assert.match(await evaluate('document.querySelector("#joplin-skipped").textContent'), /跳过 2 个附件.*跳过 2 条加密或锁定/);
  await save();
  for (const tag of ['工作/项目_A', 'joplin/2026']) {
    assert.equal(await evaluate('Array.from(document.querySelectorAll("#feed .inline-tag")).some('
      + 'node => node.textContent === ' + JSON.stringify('#' + tag) + ')'), true);
    assert.equal(await evaluate('Array.from(document.querySelectorAll("#tag-list [data-filter]")).some('
      + 'node => node.dataset.filter === ' + JSON.stringify('tag:' + tag.toLowerCase()) + ')'), true);
  }

  const exportDir = join(dir, '导出目录');
  const subdir = join(exportDir, '工作', '项目 A');
  await mkdir(subdir, { recursive: true });
  const markdownPath = join(subdir, '笔记.md');
  await writeFile(markdownPath, '目录导入墓碑验证');
  await send('Page.setInterceptFileChooserDialog', { enabled: true });
  const selectDirectory = async () => {
    const button = '[data-action="pick-joplin-dir"]';
    const found = await evaluate(`(() => {
      const node = document.querySelector('${button}');
      const rect = node.getBoundingClientRect();
      return { x: rect.x + rect.width / 2, y: rect.y + rect.height / 2,
        visible: rect.width > 0 && rect.height > 0, text: node.textContent };
    })()`);
    assert.equal(found.visible, true);
    assert.equal(found.text, '选择 Markdown 导出目录');
    const choosing = once(events, 'Page.fileChooserOpened', { signal: AbortSignal.timeout(5000) });
    const { x, y } = found;
    await send('Input.dispatchMouseEvent', { type: 'mousePressed', x, y, button: 'left', clickCount: 1 });
    await send('Input.dispatchMouseEvent', { type: 'mouseReleased', x, y, button: 'left', clickCount: 1 });
    const [{ backendNodeId }] = await choosing;
    const { node } = await send('DOM.describeNode', { backendNodeId });
    assert.equal(node.nodeName, 'INPUT');
    assert.equal(node.attributes[node.attributes.indexOf('id') + 1], 'joplin-dir');
    assert.ok(node.attributes.includes('webkitdirectory'));
    await send('DOM.setFileInputFiles', { backendNodeId, files: [exportDir] });
    await wait('document.querySelector("#joplin-dir").files[0]?.webkitRelativePath === "导出目录/工作/项目 A/笔记.md"',
      'native directory relative path');
  };
  await openImport();
  await selectDirectory();
  await preview(1);
  await save();
  const [directoryId] = requests.at(-1);
  assert.match(JSON.parse(row(directoryId).payload).body, /目录导入墓碑验证\n\n#工作\/项目_A/);
  assert.ok(await evaluate('!!document.querySelector(\'#tag-list [data-filter="tag:工作/项目_a" i]\')'));
  await click('[data-open-note="' + directoryId + '"]');
  await wait('document.querySelector("#note-dialog").open', 'opening imported note');
  await click('[data-action="delete-note"]');
  await click('[data-action="confirm-delete"]');
  await wait('!document.querySelector("#note-dialog").open', 'note deleted');
  const tombstone = row(directoryId);
  assert.deepEqual(tombstone, { revision: 2, payload: null });
  const beforeMtime = await evaluate('Date.now()');
  const later = new Date(beforeMtime + 10_000);
  await utimes(markdownPath, later, later);
  await openImport();
  await selectDirectory();
  assert.ok(await evaluate('document.querySelector("#joplin-dir").files[0].lastModified > ' + beforeMtime));
  await preview(0);
  assert.match(await evaluate('document.querySelector("#joplin-skipped").textContent'), /已存在或此前删除 1 条/);
  assert.equal(await evaluate('document.querySelector("#joplin-submit").disabled'), true);
  assert.equal(requests.length, 2);
  assert.deepEqual(row(directoryId), tombstone);
  await click('[data-close="joplin-dialog"]');

  const reopenRace = await evaluate(`(async () => {
    const dialog = document.querySelector('#joplin-dialog');
    const fileInput = document.querySelector('#joplin-file');
    document.querySelector('[data-action="open-joplin-import"]').click();
    let closeDelivered = false;
    const closed = new Promise(resolve => dialog.addEventListener('close', () => {
      closeDelivered = true;
      resolve();
    }, { once: true }));
    dialog.close();
    document.querySelector('[data-action="open-joplin-import"]').click();
    const transfer = new DataTransfer();
    transfer.items.add(new File(['快速重开保留'], '快速重开.md', { type: 'text/markdown' }));
    fileInput.files = transfer.files;
    const before = fileInput.files.length;
    await closed;
    return { before, after: fileInput.files.length, open: dialog.open, closeDelivered };
  })()`);
  assert.deepEqual(reopenRace, { before: 1, after: 1, open: true, closeDelivered: true });
  await click('[data-close="joplin-dialog"]');

  await openImport();
  await selectFiles([await file('超长.md', 'x'.repeat(600_001)), await file('普通.md', '正常批量笔记')]);
  await preview(1);
  assert.match(await evaluate('document.querySelector("#joplin-skipped").textContent'), /跳过 1 条超出大小限制/);
  await save();
  assert.equal(requests.at(-1).length, 1);
  assert.match(JSON.parse(row(requests.at(-1)[0]).payload).body, /正常批量笔记/);

  await openImport();
  await selectFiles(await Promise.all(Array.from({ length: 25 }, (_, i) => file('批量-' + i + '.md', '第 ' + i + ' 条正文'))));
  await preview(25);
  failSecondBatch = true;
  const beforeRetry = requests.length;
  await submit();
  await wait('document.querySelector("#joplin-submit").textContent === "重试剩余 5 条" && !document.querySelector("#joplin-submit").disabled',
    'retry button contains the remaining count');
  assert.match(await evaluate('document.querySelector("#joplin-error").textContent'), /第 2 批失败/);
  assert.deepEqual(requests.slice(beforeRetry).map(ids => ids.length), [20, 5]);
  await save();
  const [committed, failed, retried] = requests.slice(beforeRetry);
  assert.deepEqual(retried, failed);
  assert.equal(new Set([...committed, ...retried]).size, 25);
  assert.ok([...committed, ...retried].every(id => JSON.parse(row(id).payload).body.includes('条正文')));
  assert.equal(db.prepare('SELECT count(*) AS total FROM journal_notes WHERE payload IS NOT NULL').get().total, 28);

  await metrics(375, 812, true);
  await wait('innerWidth === 375 && document.querySelector("#mobile-toggle").getBoundingClientRect().width > 0', 'mobile viewport');
  await click('#mobile-toggle');
  assert.equal(await evaluate('document.querySelector("#sidebar").classList.contains("open")'), true);
  await openImport();
  assert.equal(await evaluate(`(() => {
    const dialog = document.querySelector('#joplin-dialog');
    const bounds = dialog.getBoundingClientRect();
    const form = dialog.querySelector('form');
    return dialog.open && bounds.left >= 0 && bounds.right <= 375 && form.scrollWidth <= form.clientWidth
      && document.documentElement.scrollWidth <= 375;
  })()`), true);
});
