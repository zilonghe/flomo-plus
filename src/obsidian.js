import { digest, immediate } from "./auth.js";
import { createS3Client, parseForcePathStyle } from "./s3.js";

export function obsidianConfig(env) {
  const [endpoint, bucket, region, accessKeyId, secretAccessKey] = [
    "ENDPOINT", "BUCKET", "REGION", "ACCESS_KEY_ID", "SECRET_ACCESS_KEY",
  ].map(key => env["OBSIDIAN_S3_" + key]?.trim());
  if (![endpoint, bucket, region, accessKeyId, secretAccessKey].every(Boolean)) return null;
  const prefixes = [...new Set((env.OBSIDIAN_SYNC_PREFIXES ?? "memo/,永久笔记/").split(",").map(prefix => prefix.trim()).filter(Boolean))];
  if (!prefixes.length || prefixes.some(prefix => !prefix.endsWith("/"))) throw new Error("Invalid OBSIDIAN_SYNC_PREFIXES");
  function milliseconds(name, fallback) {
    const value = env[name]?.trim() ? Number(env[name]) : fallback;
    if (!Number.isSafeInteger(value) || value < 0 || value > 2_147_483_647) throw new Error("Invalid " + name);
    return value;
  }
  return {
    endpoint, bucket, region, accessKeyId, secretAccessKey, prefixes,
    forcePathStyle: parseForcePathStyle(env.OBSIDIAN_S3_FORCE_PATH_STYLE, false),
    accountId: env.OBSIDIAN_ACCOUNT_ID?.trim() || null,
    intervalMs: milliseconds("OBSIDIAN_SYNC_INTERVAL_MS", 3_600_000),
    indexRecoveryCooldownMs: milliseconds("OBSIDIAN_INDEX_RECOVERY_COOLDOWN_MS", 60_000),
  };
}

const dailyHeading = /^# \d{4}-\d{2}-\d{2} 📘 每日复盘$/;
const templateLines = new Set([
  "## 😄 情绪 & 精神状态", "- 今日情绪（1-10）：", "- 描述一下今天的情绪或状态：",
  "## ✅ 完成的关键事项", "- [ ]", "## ❌ 未完成的 & 原因", "-",
  "## 🔍 今日的反思 / 认知提升", "## 🙏 一件值得感恩的事", "## 💡 明天的重点关注",
]);

export function isBlankDailyTemplate(text) {
  const lines = text.split(/\r?\n/).map(line => line.trim()).filter(Boolean);
  return !lines.length || (dailyHeading.test(lines[0]) && lines.slice(1).every(line => templateLines.has(line)));
}

const memoDate = key => key.match(/^memo\/(\d{4}-\d{2}-\d{2})\.md$/)?.[1];
const permanentTitle = key => key.match(/^永久笔记\/([^/.][^/]*)\.md$/)?.[1];
const iso = value => Number.isFinite(Date.parse(value)) ? new Date(value).toISOString() : null;
const chinaTime = (date, time) => {
  const value = iso(date + "T" + time + ":00+08:00");
  return value && new Date(Date.parse(value) + 8 * 3_600_000).toISOString().slice(0, 16) === date + "T" + time ? value : null;
};
const withTag = (body, tag) => body.split(/\s+/).includes(tag) ? body : body + "\n\n" + tag;

export function parseObsidianMarkdown(objectKey, text, lastModified, now = Date.now) {
  const date = memoDate(objectKey);
  const title = permanentTitle(objectKey);
  const body = text.replace(/\r\n/g, "\n").trim();
  if (!body) return [];
  if (date) {
    const evening = chinaTime(date, "21:00");
    if (!evening || isBlankDailyTemplate(body)) return [];
    const markers = [...body.matchAll(/^-\s+(\d{1,2}:\d{2})(?:[^\S\n]+|(?=\n|$))/gm)];
    if (!markers.length) return [{ entryKey: "whole", body: withTag(body, "#obsidian/memo"), createdAt: evening }];
    return markers.flatMap((match, i) => {
      const time = match[1].padStart(5, "0");
      const createdAt = chinaTime(date, time);
      const entry = body.slice(match.index + match[0].length, markers[i + 1]?.index).replace(/<br\s*\/?>/gi, "\n").trim();
      return entry && createdAt ? [{ time, body: withTag(entry, "#obsidian/memo"), createdAt }] : [];
    });
  }
  if (!title) return [];
  const uid = body.match(/- uid:\s*(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})\b/);
  const fromUid = uid && chinaTime(uid[1] + "-" + uid[2] + "-" + uid[3], uid[4] + ":" + uid[5]);
  return [{
    entryKey: "whole",
    body: withTag(body.startsWith("# ") ? body : "# " + title + "\n\n" + body, "#obsidian/永久笔记"),
    createdAt: fromUid || iso(lastModified) || new Date(now()).toISOString(),
  }];
}

export function obsidianNoteId(objectKey, entryKey) {
  const bytes = digest("weiji:obsidian:v2:" + objectKey + "#" + entryKey).slice(0, 32);
  return [bytes.slice(0, 8), bytes.slice(8, 12), bytes.slice(12, 16), bytes.slice(16, 20), bytes.slice(20)].join("-");
}

export function createObsidianSync({ database, semantic, config, s3Client = createS3Client(config), now = Date.now }) {
  const prepare = sql => database.prepare(sql);
  const admin = prepare("SELECT id FROM auth_users WHERE id = ? AND role = 'admin' AND status = 'active'");
  const admins = prepare("SELECT id FROM auth_users WHERE role = 'admin' AND status = 'active' LIMIT 2");
  function resolveTargetAccount() {
    if (config.accountId) return admin.get(config.accountId)?.id ?? null;
    const rows = admins.all();
    return rows.length === 1 ? rows[0].id : null;
  }
  const objectState = prepare("SELECT etag FROM obsidian_sync_objects WHERE account = ? AND object_key = ?");
  const saveObject = prepare(`INSERT INTO obsidian_sync_objects (account, object_key, etag, last_modified, synced_at)
    VALUES (?, ?, ?, ?, ?) ON CONFLICT (account, object_key) DO UPDATE SET
    etag = excluded.etag, last_modified = excluded.last_modified, synced_at = excluded.synced_at`);
  const groupState = prepare(`SELECT entry_key, note_id, synced_body_sha256 FROM obsidian_sync_notes
    WHERE account = ? AND object_key = ? AND (entry_key = ? OR entry_key LIKE ?)`);
  const noteState = prepare("SELECT revision, payload FROM journal_notes WHERE account = ? AND id = ?");
  const baselineState = prepare("SELECT * FROM obsidian_sync_notes WHERE account = ? AND note_id = ?");
  const saveBaseline = prepare(`INSERT INTO obsidian_sync_notes (account, object_key, entry_key, note_id, synced_body_sha256, synced_revision)
    VALUES (?, ?, ?, ?, ?, ?) ON CONFLICT (account, note_id) DO UPDATE SET
    synced_body_sha256 = excluded.synced_body_sha256, synced_revision = excluded.synced_revision`);
  const insertNote = prepare("INSERT INTO journal_notes (account, id, revision, payload) VALUES (?, ?, 1, ?)");
  const updateNote = prepare(`UPDATE journal_notes SET revision = revision + 1, payload = ?
    WHERE account = ? AND id = ? AND revision = ? AND payload IS NOT NULL`);
  let inFlight = null;
  let lastRun = null;
  let indexBackoffObservedAt = null;
  let indexAccount = null;

  function applyEntries(account, object, entries, stats) {
    const { key, etag, lastModified } = object;
    const upserts = [];
    const initialConflicts = stats.conflicts;
    function apply(entry, entryKey, id = obsidianNoteId(key, entryKey)) {
      const row = noteState.get(account, id);
      const baseline = baselineState.get(account, id);
      const body = entry.body;
      const hash = entry.hash ?? digest(body);
      if (!row) {
        const note = { id, body, createdAt: entry.createdAt, reading: null, turns: [] };
        insertNote.run(account, id, JSON.stringify(note));
        saveBaseline.run(account, key, entryKey, id, hash, 1);
        stats.created++;
        upserts.push(note);
        return;
      }
      if (row.payload === null) { stats.skipped++; return; }
      if (!baseline || baseline.object_key !== key || baseline.entry_key !== entryKey) { stats.conflicts++; return; }
      const existing = JSON.parse(row.payload);
      if (existing.body === body) {
        if (baseline.synced_revision !== row.revision || baseline.synced_body_sha256 !== hash) {
          saveBaseline.run(account, key, entryKey, id, hash, row.revision);
        }
        stats.skipped++;
        return;
      }
      if (row.revision !== baseline.synced_revision || digest(existing.body) !== baseline.synced_body_sha256) {
        stats.conflicts++;
        return;
      }
      const note = { ...existing, body };
      if (!updateNote.run(JSON.stringify(note), account, id, row.revision).changes) { stats.conflicts++; return; }
      saveBaseline.run(account, key, entryKey, id, hash, row.revision + 1);
      stats.updated++;
      upserts.push(note);
    }

    immediate(database, () => {
      if (resolveTargetAccount() !== account) throw new Error("Obsidian target account changed");
      const groups = new Map();
      for (const entry of entries) {
        if (entry.entryKey) { apply(entry, entry.entryKey); continue; }
        const group = groups.get(entry.time) ?? new Map();
        const hash = digest(entry.body);
        // Identical entries in the same minute have the same content identity.
        if (group.has(hash)) stats.skipped++;
        else group.set(hash, { ...entry, hash });
        groups.set(entry.time, group);
      }
      for (const [time, current] of groups) {
        const base = "time=" + time;
        const history = groupState.all(account, key, base, base + "#hash=%");
        const unmatched = [];
        for (const row of history) {
          const exact = current.get(row.synced_body_sha256);
          if (!exact) { unmatched.push(row); continue; }
          apply(exact, row.entry_key, row.note_id);
          current.delete(exact.hash);
        }
        if (history.length === 1 && unmatched.length === 1 && current.size === 1) {
          apply(current.values().next().value, unmatched[0].entry_key, unmatched[0].note_id);
        } else if (!unmatched.length) {
          for (const entry of current.values()) {
            const entryKey = !history.length && current.size === 1 ? base : base + "#hash=" + entry.hash.slice(0, 12);
            const id = obsidianNoteId(key, entryKey);
            if (baselineState.get(account, id)) stats.conflicts++;
            else apply(entry, entryKey, id);
          }
        } else {
          stats.conflicts += current.size;
        }
      }
      if (stats.conflicts === initialConflicts) saveObject.run(account, key, etag, lastModified ?? null, new Date(now()).toISOString());
    });
    return upserts;
  }

  async function checkIndex(account) {
    if (indexAccount !== account) {
      indexAccount = account;
      indexBackoffObservedAt = null;
    }
    const unhealthy = st => st && st.provider !== "disabled" &&
      (Boolean(st.lastError) || !st.ftsReady || (st.indexed < st.total && st.pending === 0 && !st.indexing));
    let status = await semantic?.getStatus?.(account);
    if (unhealthy(status)) {
      if (indexBackoffObservedAt === null) indexBackoffObservedAt = now();
      else if (now() - indexBackoffObservedAt >= (config.indexRecoveryCooldownMs ?? 60_000)) {
        await semantic.syncAccount(account);
        indexBackoffObservedAt = now();
        status = await semantic.getStatus(account);
      }
    }
    if (!unhealthy(status)) {
      indexBackoffObservedAt = null;
      return null;
    }
    return "语义索引暂未就绪，稍后会自动重试。";
  }

  async function run(account, trigger, stats) {
    let indexWarning = null;
    let error = null;
    try {
      const seen = new Set();
      for (const prefix of config.prefixes) {
        for (const object of await s3Client.listObjects(prefix)) {
          const { key, etag, lastModified } = object;
          if (seen.has(key)) continue;
          seen.add(key);
          stats.scanned++;
          if (!config.prefixes.some(allowed => key.startsWith(allowed)) || !(memoDate(key) || permanentTitle(key))) {
            stats.excluded++;
            continue;
          }
          if (objectState.get(account, key)?.etag === etag) { stats.skipped++; continue; }
          const text = await s3Client.getObjectText(key);
          stats.fetched++;
          const entries = parseObsidianMarkdown(key, text, lastModified, now);
          if (!entries.length) stats.excluded++;
          const upserts = applyEntries(account, object, entries, stats);
          if (upserts.length) await semantic?.onNotesChanged?.(account, { upserts, deletes: [] });
        }
      }
      indexWarning = await checkIndex(account);
      return stats;
    } catch (cause) {
      error = "Obsidian 同步失败，请稍后重试。";
      throw new Error(error, { cause });
    } finally {
      lastRun = { account, result: { at: new Date(now()).toISOString(), trigger, ok: !error, error, indexWarning, stats } };
    }
  }

  function sync({ trigger = "manual", accountId } = {}) {
    const account = resolveTargetAccount();
    if (!account || (accountId && accountId !== account)) return Promise.resolve(null);
    if (inFlight) {
      if (inFlight.account === account) return inFlight.promise;
      return inFlight.promise.catch(() => {}).then(() => sync({ trigger, accountId: account }));
    }
    const stats = { scanned: 0, fetched: 0, created: 0, updated: 0, skipped: 0, excluded: 0, conflicts: 0 };
    const promise = run(account, trigger, stats).finally(() => { inFlight = null; });
    inFlight = { account, promise };
    return promise;
  }

  return {
    sync,
    isTargetAccount(account) { return Boolean(account) && resolveTargetAccount() === account; },
    getStatus(account) {
      if (!account || resolveTargetAccount() !== account) return { configured: false };
      return { configured: true, running: inFlight?.account === account, intervalMs: config.intervalMs,
        prefixes: config.prefixes, lastRun: lastRun?.account === account ? lastRun.result : null };
    },
  };
}
