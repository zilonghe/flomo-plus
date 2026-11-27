import assert from "node:assert/strict";
import { execFile, spawn } from "node:child_process";
import { createHash } from "node:crypto";
import { once } from "node:events";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createInterface } from "node:readline";
import { DatabaseSync } from "node:sqlite";
import test from "node:test";
import { promisify } from "node:util";
import { applyMigrations, authConfig, createAuth, digest } from "../src/auth.js";
import { createObsidianSync, isBlankDailyTemplate, obsidianConfig, obsidianNoteId, parseObsidianMarkdown } from "../src/obsidian.js";
import { createS3Client, parseForcePathStyle, signS3Request } from "../src/s3.js";
import { createSemanticEngine } from "../src/semantic.js";

const exec = promisify(execFile);
const storage = { bucket: "vault-123", region: "ap-tokyo", accessKeyId: "test-access", secretAccessKey: "test-secret" };
const escapeXml = value => value.replaceAll("&", "&amp;").replaceAll("<", "&lt;").replaceAll(">", "&gt;");
const list = (objects, { truncated = false, token } = {}) => `<?xml version="1.0" encoding="UTF-8"?>
<ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/"><EncodingType>url</EncodingType>
<IsTruncated>${truncated}</IsTruncated>${token === undefined ? "" : `<NextContinuationToken>${escapeXml(token)}</NextContinuationToken>`}
${objects.map(({ key, etag = "test-etag", lastModified = "2026-11-24T00:00:00Z", size = 1 }) =>
    `<Contents><Key>${encodeURIComponent(key)}</Key><ETag>&quot;${etag}&quot;</ETag><LastModified>${lastModified}</LastModified><Size>${size}</Size></Contents>`).join("")}
</ListBucketResult>`;

async function listen(t, handle) {
  const failure = [];
  const server = createServer((req, res) => {
    Promise.resolve().then(() => handle(req, res)).catch(error => {
      failure.push(error);
      res.writeHead(500).end();
    });
  });
  server.listen(0, "127.0.0.1");
  await once(server, "listening");
  t.after(async () => {
    await promisify(server.close.bind(server))();
    assert.deepEqual(failure, []);
  });
  return server.address().port;
}

test("S3 signs virtual-hosted paths and encoded query parameters at a fixed time", async () => {
  const date = new Date("2026-11-24T01:02:03Z");
  const host = "vault-123.cos.ap-tokyo.myqcloud.com";
  const chinese = "永久笔记/你想要如何生活.md";
  const encodedChinese = "/%E6%B0%B8%E4%B9%85%E7%AC%94%E8%AE%B0/%E4%BD%A0%E6%83%B3%E8%A6%81%E5%A6%82%E4%BD%95%E7%94%9F%E6%B4%BB.md";
  const expected = [
    ["/", "?encoding-type=url&list-type=2&prefix=memo%2F", "5370433363766290708a612bc7fa37b4d62480274e2e4a8f4564bb6bcfdee665", list([{ key: "memo/one.md" }], { truncated: true, token: "+/%=" })],
    ["/", "?continuation-token=%2B%2F%25%3D&encoding-type=url&list-type=2&prefix=memo%2F", "9bcf62e0eb4dcd39a13e06f6dc0d96135e361649b2210051b566509f72670588", list([{ key: "memo/two.md" }])],
    [encodedChinese, "", "64b72a1fbfe7b0ac16a2b284b521d6e77dc7a3b63d5aa45aa40f2e20237b8cf7", "正文"],
    ["/memo/an%20object.md", "", "3f0fb14a8e980f50f52a7c5e587c2477cb1b633462bb0a2f273c0390d2fa5974", "body"],
  ];
  const authorization = signature => "AWS4-HMAC-SHA256 Credential=test-access/20261124/ap-tokyo/s3/aws4_request, SignedHeaders=host;x-amz-content-sha256;x-amz-date, Signature=" + signature;
  const s3 = createS3Client({
    ...storage, endpoint: "https://cos.ap-tokyo.myqcloud.com", forcePathStyle: false, now: () => date,
    fetchImpl: async (url, options) => {
      const [path, query, signature, body] = expected.shift();
      assert.equal(options.method, "GET");
      assert.equal(url.host, host);
      assert.equal(options.headers.host, host);
      assert.equal(url.pathname, path);
      assert.equal(url.search, query);
      assert.equal(options.headers.authorization, authorization(signature));
      return new Response(body);
    },
  });
  assert.equal(signS3Request({ ...storage, method: "GET", url: new URL("https://" + host + encodedChinese), date }).authorization,
    authorization("64b72a1fbfe7b0ac16a2b284b521d6e77dc7a3b63d5aa45aa40f2e20237b8cf7"));
  const unsorted = new URL("https://" + host + "/?prefix=memo%2F&list-type=2&encoding-type=url");
  assert.equal(signS3Request({ ...storage, method: "GET", url: unsorted, date }).authorization,
    authorization("5370433363766290708a612bc7fa37b4d62480274e2e4a8f4564bb6bcfdee665"));
  assert.deepEqual(await s3.listObjects("memo/"), ["one", "two"].map(name =>
    ({ key: "memo/" + name + ".md", etag: "test-etag", lastModified: "2026-11-24T00:00:00Z", size: 1 })));
  assert.equal(await s3.getObjectText(chinese), "正文");
  assert.equal(await s3.getObjectText("memo/an object.md"), "body");
  assert.equal(expected.length, 0);
  assert.equal(parseForcePathStyle(undefined), true);
  assert.equal(parseForcePathStyle("0"), false);
  assert.equal(parseForcePathStyle("false"), false);
  assert.throws(() => createS3Client({ ...storage, endpoint: "http://remote.invalid" }), /HTTPS/);
});

async function databaseFor(t, path = ":memory:") {
  const db = new DatabaseSync(path);
  t.after(() => db.close());
  await applyMigrations(db);
  return db;
}
async function scratch(t) {
  const dir = await mkdtemp(join(tmpdir(), "weiji-test-"));
  t.after(() => rm(dir, { recursive: true, force: true }));
  return dir;
}
const insertUser = (db, id, role = "admin", status = "active") =>
  db.prepare("INSERT INTO auth_users(id, role, status, created_at, updated_at) VALUES (?, ?, ?, datetime(), datetime())").run(id, role, status);

test("backup CLI uploads to a virtual host, verifies the binary snapshot, and prunes only after valid pagination", async t => {
  const dir = await scratch(t);
  const path = join(dir, "main.db");
  const db = await databaseFor(t, path);
  db.prepare("INSERT INTO journal_notes VALUES ('test', 'one', 1, ?), ('test', 'two', 2, NULL)").run('{"body":"测试备份"}');

  const prefix = "_weiji-backup/";
  const outside = "memo/not-a-backup.db.gz";
  const expired = prefix + "expired.db.gz";
  const expiredSecondPage = prefix + "expired-second-page.db.gz";
  const oldMarkdown = prefix + "keep.md";
  const old = key => ({ key, lastModified: "2000-01-01T00:00:00Z" });
  const uploaded = new Map();
  const calls = [];
  let scenario = "valid";
  let port;
  port = await listen(t, async (req, res) => {
    assert.equal(req.headers.host, storage.bucket + ".localhost:" + port);
    assert.match(req.headers.authorization, /^AWS4-HMAC-SHA256 /);
    const url = new URL(req.url, "http://localhost");
    const key = decodeURIComponent(url.pathname.slice(1));
    calls.push([req.method, url.search ? "LIST" : key]);
    if (req.method === "PUT") {
      const chunks = [];
      for await (const chunk of req) chunks.push(chunk);
      const body = Buffer.concat(chunks);
      assert.equal(req.headers["x-amz-content-sha256"], digest(body));
      assert.equal(Number(req.headers["content-length"]), body.length);
      assert.ok(key.startsWith(prefix));
      uploaded.set(key, body);
      res.end();
    } else if (url.search) {
      assert.equal(url.pathname, "/");
      assert.equal(url.searchParams.get("prefix"), prefix);
      const token = url.searchParams.get("continuation-token");
      if (token === null) {
        res.end(list([old(expired), old(outside), old(oldMarkdown)], { truncated: true, token: "+/%=" }));
      } else {
        assert.equal(token, "+/%=");
        if (scenario === "repeat") res.end(list([old(expiredSecondPage)], { truncated: true, token }));
        else if (scenario === "missing") res.end(list([old(expiredSecondPage)], { truncated: true }));
        else res.end(list([old(expiredSecondPage)]));
      }
    } else if (req.method === "DELETE") res.writeHead(204).end();
    else if (uploaded.has(key)) res.end(scenario === "corrupt" ? "not gzip" : uploaded.get(key));
    else res.writeHead(404).end();
  });
  // Limit the mock virtual host lookup to loopback on Linux and macOS alike.
  const preload = `import dns from 'node:dns';
    const lookup = dns.lookup;
    dns.lookup = (host, options, callback) => lookup(host === '${storage.bucket}.localhost' ? '127.0.0.1' : host, options, callback);`;
  const backup = (...args) => exec(process.execPath, [
    "--import", "data:text/javascript," + encodeURIComponent(preload), "--experimental-sqlite", "scripts/backup-r2.mjs", ...args,
  ], { timeout: 10_000, env: {
    PATH: process.env.PATH,
    SQLITE_PATH: path, BACKUP_S3_ENDPOINT: "http://localhost:" + port, BACKUP_S3_BUCKET: storage.bucket,
    BACKUP_S3_REGION: storage.region, BACKUP_S3_ACCESS_KEY_ID: storage.accessKeyId, BACKUP_S3_SECRET_ACCESS_KEY: storage.secretAccessKey,
    BACKUP_S3_FORCE_PATH_STYLE: "0", BACKUP_S3_PREFIX: prefix, BACKUP_RETENTION_DAYS: "30",
  } });
  const { stdout } = await backup("--verify-uploaded");
  const key = stdout.match(/^BACKUP_OK key=(\S+) journal_notes=2 pruned=2$/m)?.[1];
  assert.match(key ?? "", /^_weiji-backup\/notes-.*\.db\.gz$/);
  assert.deepEqual(calls, [["PUT", key], ["GET", key], ["GET", "LIST"], ["GET", "LIST"], ["DELETE", expired], ["DELETE", expiredSecondPage]]);
  assert.equal((await backup("--verify-remote", key)).stdout.trim(), `BACKUP_VERIFY_REMOTE_OK key=${key} journal_notes=2`);
  const local = join(dir, "local.db.gz");
  await writeFile(local, uploaded.get(key));
  assert.equal((await backup("--verify", local)).stdout.trim(), "BACKUP_VERIFY_OK journal_notes=2");

  for (scenario of ["missing", "repeat"]) {
    calls.length = 0;
    await assert.rejects(backup(), /Invalid S3 pagination/);
    assert.deepEqual(calls.map(([method]) => method), ["PUT", "GET", "GET"]);
  }
  scenario = "corrupt";
  calls.length = 0;
  await assert.rejects(backup("--verify-uploaded"), /incorrect header check/);
  assert.deepEqual(calls.map(([method]) => method), ["PUT", "GET"]);
});

const permanent = "永久笔记/长久的习惯.md";
const blankTemplate = `# 2026-11-24 📘 每日复盘

## 😄 情绪 & 精神状态
- 今日情绪（1-10）：
- 描述一下今天的情绪或状态：
## ✅ 完成的关键事项
- [ ]
## ❌ 未完成的 & 原因
-
## 🔍 今日的反思 / 认知提升
## 🙏 一件值得感恩的事
## 💡 明天的重点关注`;

test("Obsidian config and Markdown filtering, dates, fallback and tags", () => {
  assert.equal(obsidianConfig({ OBSIDIAN_S3_BUCKET: "vault-123" }), null);
  const env = { OBSIDIAN_S3_ENDPOINT: "https://cos.ap-tokyo.myqcloud.com", OBSIDIAN_S3_BUCKET: "vault-123",
    OBSIDIAN_S3_REGION: storage.region, OBSIDIAN_S3_ACCESS_KEY_ID: storage.accessKeyId, OBSIDIAN_S3_SECRET_ACCESS_KEY: storage.secretAccessKey };
  const settings = obsidianConfig(env);
  assert.deepEqual(settings.prefixes, ["memo/", "永久笔记/"]);
  assert.equal(settings.forcePathStyle, false);
  assert.equal(settings.intervalMs, 3_600_000);
  assert.equal(settings.indexRecoveryCooldownMs, 60_000);
  assert.equal(obsidianConfig({ ...env, OBSIDIAN_SYNC_INTERVAL_MS: "0", OBSIDIAN_ACCOUNT_ID: " test " }).accountId, "test");
  assert.equal(obsidianConfig({ ...env, OBSIDIAN_SYNC_INTERVAL_MS: "0" }).intervalMs, 0);
  assert.throws(() => obsidianConfig({ ...env, OBSIDIAN_SYNC_PREFIXES: "memo" }), /OBSIDIAN_SYNC_PREFIXES/);

  assert.equal(isBlankDailyTemplate(blankTemplate), true);
  assert.equal(isBlankDailyTemplate(blankTemplate + "\n实质内容"), false);
  assert.deepEqual(parseObsidianMarkdown("memo/2026-11-24.md", "- 8:03 A<br/>B\n  C\n- 13:42 D #obsidian/memo"), [
    { time: "08:03", body: "A\nB\n  C\n\n#obsidian/memo", createdAt: "2026-11-24T00:03:00.000Z" },
    { time: "13:42", body: "D #obsidian/memo", createdAt: "2026-11-24T05:42:00.000Z" },
  ]);
  assert.equal(parseObsidianMarkdown("memo/2026-11-24.md", "整篇正文")[0].createdAt, "2026-11-24T13:00:00.000Z");
  assert.deepEqual(parseObsidianMarkdown(permanent, "- uid: 202611241137\n正文"), [
    { entryKey: "whole", body: "# 长久的习惯\n\n- uid: 202611241137\n正文\n\n#obsidian/永久笔记", createdAt: "2026-11-24T03:37:00.000Z" },
  ]);
  assert.equal(parseObsidianMarkdown(permanent, "# 自定义标题", "2026-11-24T08:00:00Z")[0].createdAt, "2026-11-24T08:00:00.000Z");
  assert.equal(parseObsidianMarkdown(permanent, "正文", null, () => 0)[0].createdAt, "1970-01-01T00:00:00.000Z");
});

async function vaultFor(t) {
  const objects = new Map();
  const gets = [];
  let onGet;
  const port = await listen(t, async (req, res) => {
    const url = new URL(req.url, "http://localhost");
    assert.equal(req.method, "GET");
    if (url.search) {
      // A mock endpoint can return out-of-scope keys; the importer must still reject them.
      res.end(list([...objects.values()]));
    } else {
      const key = decodeURIComponent(url.pathname.replace("/" + storage.bucket + "/", ""));
      const obj = objects.get(key);
      assert.ok(obj, key);
      gets.push(key);
      await onGet?.(key);
      res.end(obj.body);
    }
  });
  const endpoint = "http://127.0.0.1:" + port;
  return { endpoint, gets, s3Client: createS3Client({ ...storage, endpoint }),
    put(key, body) { objects.set(key, { key, etag: digest(body), body, size: Buffer.byteLength(body) }); },
    beforeGet(callback) { onGet = callback; },
  };
}
const syncConfig = { accountId: null, prefixes: ["memo/", "永久笔记/"], intervalMs: 0, indexRecoveryCooldownMs: 60_000 };
const readNote = (db, id, account = "admin") => {
  const row = db.prepare("SELECT revision, payload FROM journal_notes WHERE account = ? AND id = ?").get(account, id);
  return row && { revision: row.revision, note: JSON.parse(row.payload) };
};
const history = (db, key) => db.prepare("SELECT note_id FROM obsidian_sync_notes WHERE account = 'admin' AND object_key = ? ORDER BY entry_key").all(key);

test("Obsidian sync preserves identities, turns, tombstones and user edits across ETag changes and restart", async t => {
  const database = await databaseFor(t);
  insertUser(database, "admin");
  insertUser(database, "disabled", "admin", "disabled");
  const vault = await vaultFor(t);
  const semantic = createSemanticEngine({ database, env: { EMBEDDING_PROVIDER: "hash-test" } });
  await semantic.syncAccount("admin", { waitForEmbeddings: true });
  const makeSync = () => createObsidianSync({ database, semantic, config: syncConfig, s3Client: vault.s3Client });
  const sync = makeSync();
  const daily = "memo/2026-11-23.md";
  const transition = "memo/2026-11-22.md";
  const clean = "memo/2026-11-21.md";
  const collision = "memo/2026-11-20.md";
  const bodyA = "- 18:52 A";
  const bodyB = "- 18:52 B";
  const turns = [{ role: "assistant", content: "保留旧对话" }];
  const reading = { bookTitle: "保留旧阅读信息" };
  const setPayload = database.prepare("UPDATE journal_notes SET payload = ?, revision = ? WHERE account = 'admin' AND id = ?");
  vault.put(daily, bodyA + "\n" + bodyB);
  vault.put(transition, bodyA);
  vault.put(clean, "清理前的内容");
  vault.put(permanent, "- uid: 202611241137\n燕麦早餐与远足");
  const blanks = ["memo/2026-11-24.md", "memo/2026-11-25.md"];
  vault.put(blanks[0], blankTemplate);
  vault.put(blanks[1], " \n ");
  const excluded = ["memo/", "memo/delete.md", "memo/生产力看板.md", "memo/.2026-11-24.md", "memo/2026-11-24.pdf",
    "读书笔记/燕麦.md", "永久笔记/.hidden.md", "永久笔记/目录/正文.md", "_weiji-backup/backup.db.gz"];
  for (const key of excluded) vault.put(key, "不会导入");
  let release;
  const gate = new Promise(resolve => { release = resolve; });
  vault.beforeGet(() => gate);
  const first = sync.sync();
  const parallel = sync.sync({ trigger: "timer" });
  assert.equal(first, parallel);
  assert.equal(sync.getStatus("admin").running, true);
  release();
  assert.deepEqual(await first, { scanned: 4 + blanks.length + excluded.length, fetched: 4 + blanks.length, created: 5, updated: 0, skipped: 0, excluded: blanks.length + excluded.length, conflicts: 0 });
  assert.equal(sync.getStatus("admin").running, false);
  vault.beforeGet(null);
  assert.equal(vault.gets.length, 6);
  assert.ok(vault.gets.every(key => !excluded.includes(key)));
  await semantic.waitIdle();
  const found = await semantic.searchNotes("admin", "燕麦早餐与远足");
  assert.equal(found.mode, "hybrid");
  assert.match(found.items[0].note.body, /燕麦早餐与远足/);
  assert.equal(found.items[0].note.id, obsidianNoteId(permanent, "whole"));

  vault.gets.length = 0;
  assert.equal((await makeSync().sync()).fetched, 0);
  assert.deepEqual(vault.gets, []);
  const [a, b] = history(database, daily).map(({ note_id: id }) => id)
    .sort((a, b) => readNote(database, a).note.body.localeCompare(readNote(database, b).note.body));
  setPayload.run(JSON.stringify({ ...readNote(database, a).note, turns }), 2, a);
  setPayload.run(null, 2, b);
  const cleanId = obsidianNoteId(clean, "whole");
  setPayload.run(JSON.stringify({ ...readNote(database, cleanId).note, turns, reading }), 1, cleanId);
  const transitionA = obsidianNoteId(transition, "time=18:52");
  setPayload.run(JSON.stringify({ ...readNote(database, transitionA).note, turns }), 2, transitionA);
  const collisionId = obsidianNoteId(collision, "whole");
  database.prepare("INSERT INTO journal_notes VALUES ('admin', ?, 1, ?)").run(collisionId, JSON.stringify({ id: collisionId, body: "来源不明" }));

  vault.put(daily, "- 18:52 X\n" + bodyA + "\n" + bodyB);
  vault.put(transition, bodyA + "\n" + bodyB);
  vault.put(clean, "来自 Obsidian 的更新");
  vault.put(collision, "不能覆盖已有正文");
  const changed = await sync.sync();
  assert.equal(changed.created, 2);
  assert.equal(changed.updated, 1);
  assert.equal(changed.conflicts, 1);
  assert.equal(history(database, daily).length, 3);
  assert.deepEqual(readNote(database, a).note.turns, turns);
  assert.deepEqual(readNote(database, b), { revision: 2, note: null });
  assert.deepEqual(readNote(database, cleanId).note.turns, turns);
  assert.deepEqual(readNote(database, cleanId).note.reading, reading);
  assert.equal(readNote(database, collisionId).note.body, "来源不明");

  const transitionB = history(database, transition).find(row => row.note_id !== transitionA).note_id;
  vault.put(transition, bodyB);
  await sync.sync();
  assert.match(readNote(database, transitionB).note.body, /^B\n/);
  assert.deepEqual(readNote(database, transitionA).note.turns, turns);
  assert.match(readNote(database, transitionA).note.body, /^A\n/);

  const userId = obsidianNoteId(permanent, "whole");
  const userBody = { ...readNote(database, userId).note, body: "用户在下载期间修改的正文" };
  vault.put(permanent, "从 COS 修改的正文");
  vault.beforeGet(key => {
    if (key === permanent) setPayload.run(JSON.stringify(userBody), 2, userId);
  });
  assert.equal((await sync.sync()).conflicts, 2);
  vault.beforeGet(null);
  for (let retry = 0; retry < 2; retry++) {
    assert.equal((await sync.sync()).conflicts, 2);
    assert.deepEqual(readNote(database, userId), { revision: 2, note: userBody });
    assert.equal(database.prepare("SELECT etag FROM obsidian_sync_objects WHERE account = 'admin' AND object_key = ?").get(permanent), undefined);
    assert.equal(database.prepare("SELECT synced_revision FROM obsidian_sync_notes WHERE account = 'admin' AND note_id = ?").get(userId).synced_revision, 1);
  }

  vault.put(daily, "- 18:52 X\n- 18:52 A 修改\n- 18:52 B 修改");
  assert.equal((await sync.sync()).conflicts, 4);
  assert.equal(history(database, daily).length, 3);
  assert.match(readNote(database, a).note.body, /^A\n/);
  assert.deepEqual(readNote(database, b), { revision: 2, note: null });

  // Partial conflict then source reverts to original ETag: clean entry B must still revert while user-edited A stays protected.
  const partialKey = "memo/2026-02-01.md";
  vault.put(partialKey, "- 10:00 A1\n- 11:00 B1");
  assert.equal((await sync.sync()).created, 2);
  const partialA = obsidianNoteId(partialKey, "time=10:00");
  const partialB = obsidianNoteId(partialKey, "time=11:00");
  const editedA = { ...readNote(database, partialA).note, body: "用户保留的 A 正文" };
  setPayload.run(JSON.stringify(editedA), 2, partialA);
  vault.put(partialKey, "- 10:00 A2\n- 11:00 B2");
  const partialStats = await sync.sync();
  assert.equal(partialStats.updated, 1);
  assert.equal(partialStats.conflicts, 5);
  assert.match(readNote(database, partialB).note.body, /^B2\n/);
  assert.deepEqual(readNote(database, partialA), { revision: 2, note: editedA });
  assert.equal(database.prepare("SELECT etag FROM obsidian_sync_objects WHERE account = 'admin' AND object_key = ?").get(partialKey), undefined);
  vault.put(partialKey, "- 10:00 A1\n- 11:00 B1");
  const revertedSync = createObsidianSync({ database, semantic, config: syncConfig, s3Client: vault.s3Client });
  const revertStats = await revertedSync.sync();
  assert.equal(revertStats.updated, 1);
  assert.match(readNote(database, partialB).note.body, /^B1\n/);
  assert.deepEqual(readNote(database, partialA), { revision: 2, note: editedA });
  await semantic.waitIdle();
});

test("an unchanged ETag still allows semantic recovery after the 60s backoff", async t => {
  const database = await databaseFor(t);
  insertUser(database, "admin");
  const vault = await vaultFor(t);
  vault.put(permanent, "恢复后应生成向量");
  let time = Date.parse("2026-11-24T00:00:00Z");
  const now = () => time;
  let attempts = 0;
  let failing = true;
  const engine = createSemanticEngine({
    database,
    now,
    embedder: {
      provider: "test", model: "recovery-test", dims: 3,
      async embed(texts) {
        attempts++;
        if (failing) throw new Error("simulated embedding error");
        return texts.map(() => [1, 0, 0]);
      },
    },
  });
  await engine.syncAccount("admin");
  let recoveries = 0;
  const semantic = { ...engine, syncAccount: (...args) => { recoveries++; return engine.syncAccount(...args); } };
  const sync = createObsidianSync({ database, semantic, config: syncConfig, s3Client: vault.s3Client, now });
  assert.equal((await sync.sync()).created, 1);
  await engine.waitIdle();
  assert.equal(attempts, 3);
  const error = engine.getStatus("admin");
  assert.equal(error.lastError, "simulated embedding error");
  assert.equal(error.indexing, false);
  assert.ok(error.indexed < error.total);
  vault.gets.length = 0;

  await sync.sync();  // Record the first unhealthy observation at time zero.
  assert.ok(sync.getStatus("admin").lastRun.indexWarning);
  time += 59_999;
  await sync.sync();
  assert.equal(recoveries, 0);
  assert.deepEqual(vault.gets, []);
  time++;
  failing = false;
  await sync.sync();
  await engine.waitIdle();
  assert.equal(recoveries, 1);
  assert.deepEqual(vault.gets, []);
  const ready = engine.getStatus("admin");
  assert.equal(ready.indexed, ready.total);
  assert.equal(ready.lastError, null);
  assert.equal(sync.getStatus("admin").lastRun.indexWarning, null);

  const disabled = createSemanticEngine({ database, env: { EMBEDDING_PROVIDER: "disabled" }, now });
  await disabled.syncAccount("admin");
  const disabledSync = createObsidianSync({ database, config: syncConfig, s3Client: vault.s3Client, now,
    semantic: { ...disabled, syncAccount: () => { assert.fail("disabled embeddings must not trigger recovery"); } } });
  await disabledSync.sync();
  time += 120_000;
  await disabledSync.sync();
  assert.equal(disabled.getStatus("admin").ftsReady, true);
  assert.equal(disabled.getStatus("admin").indexed, 0);
  assert.equal(disabledSync.getStatus("admin").lastRun.indexWarning, null);
  assert.deepEqual(vault.gets, []);

  // Disabled embeddings with a broken FTS index must report indexWarning without triggering vector rebuild.
  disabled.recordError("admin", new Error("controlled FTS failure"));
  await disabledSync.sync();
  assert.equal(disabled.getStatus("admin").ftsReady, false);
  assert.ok(disabledSync.getStatus("admin").lastRun.indexWarning);
  assert.deepEqual(vault.gets, []);
});

test("target account is active admin only, and unbound sync resolves only a single active admin", async t => {
  const database = await databaseFor(t);
  insertUser(database, "admin");
  insertUser(database, "other");
  insertUser(database, "reader", "user");
  insertUser(database, "disabled", "admin", "disabled");
  const s3Client = { listObjects: () => { assert.fail("disabled sync accessed object storage"); } };
  for (const accountId of [null, "disabled", "reader", "missing"]) {
    const sync = createObsidianSync({ database, s3Client, config: { ...syncConfig, accountId } });
    assert.equal(await sync.sync(), null);
    assert.deepEqual(sync.getStatus("admin"), { configured: false });
  }
  const pinned = createObsidianSync({ database, s3Client, config: { ...syncConfig, accountId: "admin" } });
  assert.equal(pinned.isTargetAccount("admin"), true);
  assert.equal(pinned.isTargetAccount("other"), false);
  assert.equal(await pinned.sync({ accountId: "other" }), null);
  database.prepare("UPDATE auth_users SET status = 'disabled' WHERE id = 'other'").run();
  const unbound = createObsidianSync({ database, s3Client, config: syncConfig });
  assert.equal(unbound.isTargetAccount("admin"), true);
  database.prepare("UPDATE auth_users SET status = 'disabled' WHERE id = 'admin'").run();
  assert.equal(unbound.isTargetAccount("admin"), false);
  assert.equal(await unbound.sync(), null);
});

async function preview(t, env) {
  const child = spawn(process.execPath, ["--experimental-sqlite", "scripts/preview.mjs"], {
    env, stdio: ["ignore", "pipe", "pipe"],
  });
  const exited = once(child, "exit");
  t.after(async () => {
    child.kill();
    await exited;
  });
  let stderr = "";
  child.stderr.on("data", data => { stderr += data; });
  const lines = createInterface({ input: child.stdout });
  const ready = (async () => {
    for await (const line of lines) {
      const port = line.match(/^Local preview ready on port (\d+)$/)?.[1];
      if (port) return "http://127.0.0.1:" + port;
    }
    throw new Error("Preview did not start: " + stderr);
  })();
  return await ready;
}

test("public auth HTML and admin sync guards preserve the other admin's real notes session", { timeout: 15_000 }, async t => {
  const dir = await scratch(t);
  const path = join(dir, "auth.db");
  const database = await databaseFor(t, path);
  for (const [id, role] of [["admin", "admin"], ["other", "admin"], ["reader", "user"]]) {
    insertUser(database, id, role);
    database.prepare(`INSERT INTO auth_sessions (id, user_id, token_hash, kind, label, created_at, last_used_at, expires_at)
      VALUES (?, ?, ?, 'web', 'test', datetime(), datetime(), '2999-01-01T00:00:00.000Z')`).run(id, id, digest(id + "-cookie"));
  }
  database.prepare("INSERT INTO journal_notes VALUES ('other', 'personal-note', 1, ?)").run(
    JSON.stringify({ id: "personal-note", body: "只属于另一名管理员", createdAt: "2026-11-24T00:00:00Z", reading: null, turns: [] }));
  database.prepare(`INSERT INTO auth_oauth_states (id, purpose, payload_json, expires_at)
    VALUES (?, 'invite_ticket', '{}', '2999-01-01T00:00:00.000Z')`).run(digest("invite-cookie"));
  const vault = await vaultFor(t);
  vault.put(permanent, "只属于 Obsidian 目标管理员");
  const origin = "https://weiji.example.invalid";
  const env = { PATH: process.env.PATH, PORT: "0", SQLITE_PATH: path, PUBLIC_ORIGIN: origin,
    AUTH_MODE: "oauth", GITHUB_CLIENT_ID: "test-gh", GITHUB_CLIENT_SECRET: "test-gh-secret",
    GOOGLE_CLIENT_ID: "test-google", GOOGLE_CLIENT_SECRET: "test-google-secret", EMBEDDING_PROVIDER: "disabled",
    OBSIDIAN_S3_ENDPOINT: vault.endpoint, OBSIDIAN_S3_BUCKET: storage.bucket, OBSIDIAN_S3_REGION: storage.region,
    OBSIDIAN_S3_ACCESS_KEY_ID: storage.accessKeyId, OBSIDIAN_S3_SECRET_ACCESS_KEY: storage.secretAccessKey,
    OBSIDIAN_S3_FORCE_PATH_STYLE: "true", OBSIDIAN_ACCOUNT_ID: "admin", OBSIDIAN_SYNC_INTERVAL_MS: "0",
  };
  const local = await preview(t, env);
  async function html(route, headers) {
    const res = await fetch(local + route, { headers });
    assert.equal(res.status, 200);
    assert.match(res.headers.get("content-type"), /^text\/html/);
    return await res.text();
  }
  for (const route of ["/", "/login"]) {
    const page = await html(route);
    assert.match(page, /auth-card/);
    assert.match(page, /<h1>微记<\/h1>/);
    for (const link of ["/auth/github/start", "/auth/google/start", "/privacy", "/terms"]) assert.ok(page.includes('href="' + link + '"'));
  }
  assert.match(await html("/auth/invite", { Cookie: "weiji_invite_ticket=invite-cookie" }), /auth-card[\s\S]*action="\/auth\/invite\/redeem"/);
  assert.match(await html("/privacy"), /显示名称、邮箱地址和头像 URL[\s\S]*登录设备[\s\S]*导出或删除/);
  assert.match(await html("/terms"), /服务条款[\s\S]*导出或删除/);

  function request(route, id, method = "GET", headers = {}) {
    return fetch(local + route, { method, headers: { Cookie: "weiji_session=" + id + "-cookie", "X-Journal-Account": id, ...headers } });
  }
  const statusPath = "/api/admin/obsidian/status";
  const syncPath = "/api/admin/obsidian/sync";
  async function expectJson(response, status, body) {
    const res = await response;
    assert.equal(res.status, status);
    const data = await res.json();
    if (body !== undefined) assert.deepEqual(data, body);
    return data;
  }

  await expectJson(request(statusPath, "other"), 200, { configured: false });
  const mismatch = await expectJson(request(syncPath, "other", "POST", { Origin: origin }), 409);
  assert.equal(mismatch.code, "obsidian_account_mismatch");
  const otherNotes = await expectJson(request("/api/notes", "other"), 200);
  assert.deepEqual(otherNotes.notes.map(note => note.body), ["只属于另一名管理员"]);
  await expectJson(request(statusPath, "reader"), 403);
  await expectJson(request(syncPath, "reader", "POST", { Origin: origin }), 403);
  await expectJson(request(syncPath, "admin", "POST"), 403);
  await expectJson(request(syncPath, "admin", "POST", { Origin: "https://other.invalid" }), 403);
  await expectJson(request(syncPath, "admin", "POST", { Origin: origin, "Sec-Fetch-Site": "cross-site" }), 403);
  await expectJson(request(syncPath, "admin", "POST", { Origin: origin, "X-Journal-Account": "other" }), 403);
  await expectJson(request(statusPath, "admin", "GET", { "X-Journal-Account": "other" }), 403);
  await expectJson(request(statusPath, "admin"), 200, { configured: true, running: false, intervalMs: 0,
    prefixes: ["memo/", "永久笔记/"], lastRun: null });
  assert.deepEqual(vault.gets, []);
  const result = await expectJson(request(syncPath, "admin", "POST", { Origin: origin }), 200);
  assert.equal(result.ok, true);
  assert.equal(result.stats.created, 1);
  assert.equal(result.status.lastRun.trigger, "manual");
  assert.deepEqual(result.status.lastRun.stats, result.stats);
  assert.deepEqual(await expectJson(request("/api/notes", "other"), 200), otherNotes);
  assert.match((await expectJson(request("/api/notes", "admin"), 200)).notes[0].body, /只属于 Obsidian 目标管理员/);

  const auth = createAuth(database, authConfig(env));
  const url = new URL(origin + syncPath);
  const unconfigured = await auth.handle(new Request(url, { method: "POST", headers: { Cookie: "weiji_session=admin-cookie", Origin: origin } }), url);
  assert.equal(unconfigured.status, 400);
  assert.equal((await unconfigured.json()).code, "obsidian_not_configured");
});

for (const client of ["android", "ios"]) {
  test(`${client} OAuth PKCE exchanges a native session and preserves web login`, { timeout: 15_000 }, async t => {
    const path = join(await scratch(t), "native.db");
    const database = await databaseFor(t, path);
    insertUser(database, "native", "user");
    database.prepare("INSERT INTO auth_identities (provider, subject, user_id, created_at) VALUES ('github', '42', 'native', datetime())").run();

    const providerPort = await listen(t, async (req, res) => {
      if (req.url === "/login/oauth/access_token" && req.method === "POST") {
        let body = "";
        for await (const chunk of req) body += chunk;
        const fields = new URLSearchParams(body);
        assert.equal(fields.get("code"), "upstream-code");
        assert.match(fields.get("code_verifier"), /^[A-Za-z0-9_-]{43}$/);
        res.end(JSON.stringify({ access_token: "upstream-token" }));
      } else {
        assert.equal(req.url, "/user");
        assert.equal(req.headers.authorization, "Bearer upstream-token");
        res.end(JSON.stringify({ id: 42 }));
      }
    });
    const provider = "http://127.0.0.1:" + providerPort;
    const origin = "https://weiji.example.invalid";
    const local = await preview(t, { PATH: process.env.PATH, PORT: "0", SQLITE_PATH: path, PUBLIC_ORIGIN: origin,
      AUTH_MODE: "oauth", GITHUB_CLIENT_ID: "test-gh", GITHUB_CLIENT_SECRET: "test-gh-secret",
      OAUTH_GITHUB_ORIGIN: provider, OAUTH_GITHUB_API_ORIGIN: provider, EMBEDDING_PROVIDER: "disabled" });
    const verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk";
    const challenge = createHash("sha256").update(verifier).digest("base64url");
    const label = client === "android" ? "Android (Test Phone)" : "iOS (Test Phone)";
    const state = "test-native-state";
    const call = (route, init) => fetch(local + route, { redirect: "manual", ...init });
    async function flow(kind) {
      const query = kind === "web" ? "" : "?" + new URLSearchParams({
        client: kind, redirect_uri: "weiji://auth/callback", code_challenge: challenge, code_challenge_method: "S256", state,
      });
      const start = await call("/auth/github/start" + query);
      assert.equal(start.status, 302);
      const upstream = new URL(start.headers.get("location"));
      assert.equal(upstream.origin, provider);
      assert.equal(upstream.searchParams.get("code_challenge_method"), "S256");
      const nonce = start.headers.get("set-cookie")?.split(";")[0];
      const result = await call("/auth/github/callback?" + new URLSearchParams({
        code: "upstream-code", state: upstream.searchParams.get("state"),
      }), nonce ? { headers: { Cookie: nonce } } : {});
      assert.equal(result.status, 302);
      return result;
    }

    const callback = new URL((await flow(client)).headers.get("location"));
    assert.equal(callback.href.split("?")[0], "weiji://auth/callback");
    assert.equal(callback.searchParams.get("state"), state);
    const code = callback.searchParams.get("code");
    assert.ok(code);
    function exchange(codeVerifier = verifier, requestOrigin = origin) {
      return call("/api/auth/exchange", { method: "POST", headers: { Origin: requestOrigin, "Content-Type": "application/json" },
        body: JSON.stringify({ code, codeVerifier, deviceLabel: label }) });
    }
    assert.equal((await exchange(verifier, "https://wrong.invalid")).status, 403);
    assert.equal((await exchange("x".repeat(43))).status, 401);
    const ok = await exchange();
    assert.equal(ok.status, 200);
    const { token, sessionId, expiresAt, user } = await ok.json();
    assert.match(token, /^[A-Za-z0-9_-]+$/);
    assert.ok(Date.parse(expiresAt) > Date.now());
    assert.deepEqual(user, { id: "native", name: "我的笔记", email: "", role: "user" });
    assert.equal((await exchange()).status, 401);

    const headers = { Authorization: "Bearer " + token, "X-Journal-Account": user.id };
    const sessions = await call("/api/auth/sessions", { headers });
    assert.equal(sessions.status, 200);
    assert.ok((await sessions.json()).sessions.some(s => s.id === sessionId && s.label === label && s.kind === "ios" && s.current));
    const note = { id: "9e0cf24a-fe22-4b30-a7cf-0c8aad068807", body: "移动端笔记", createdAt: "2026-11-24T00:00:00Z" };
    const write = await call("/api/notes", { method: "POST", headers: { ...headers, Origin: origin, "Content-Type": "application/json" },
      body: JSON.stringify({ id: note.id, expectedRevision: 0, note }) });
    assert.equal(write.status, 200);
    const read = await call("/api/notes", { headers });
    assert.equal(read.status, 200);
    assert.equal((await read.json()).notes[0].body, note.body);

    const web = await flow("web");
    assert.equal(web.headers.get("location"), origin + "/");
    const cookie = web.headers.getSetCookie().find(item => item.startsWith("weiji_session=")).split(";")[0];
    assert.equal((await call("/api/session", { headers: { Cookie: cookie } })).status, 200);

    database.prepare("UPDATE auth_users SET status = 'disabled' WHERE id = 'native'").run();
    const disabled = new URL((await flow(client)).headers.get("location"));
    assert.equal(disabled.href.split("?")[0], "weiji://auth/callback");
    assert.deepEqual(Object.fromEntries(disabled.searchParams), { error: "account_disabled", state });
  });
}
