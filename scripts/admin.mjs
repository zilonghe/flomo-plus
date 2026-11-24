import { randomUUID } from "node:crypto";
import { DatabaseSync } from "node:sqlite";
import { applyMigrations, createInvite, digest, immediate, listInvites, revokeInvite } from "../src/auth.js";

function options(args, allowed, required = []) {
  const result = Object.create(null);
  for (let i = 0; i < args.length; i += 2) {
    const key = args[i].startsWith("--") && args[i].slice(2);
    if (!allowed.includes(key) || Object.hasOwn(result, key) || !args[i + 1] || args[i + 1].startsWith("--")) {
      throw new Error("Invalid or missing command options");
    }
    result[key] = args[i + 1];
  }
  if (required.some(key => !result[key]?.trim())) throw new Error("Missing required command options");
  return result;
}

const tables = ["journal_notes", "note_embeddings", "ai_sessions", "ai_profile", "ai_insight_lenses", "ai_insight_reports", "note_fts"];

function migrate(db, args) {
  const { from, to } = options(args, ["from", "to"], ["from", "to"]);
  if (from === to) throw new Error("Source and destination accounts must differ");
  return immediate(db, () => {
    const counts = {};
    const count = (table, account) => db.prepare(`SELECT COUNT(*) AS n FROM ${table} WHERE account = ?`).get(account).n;
    for (const table of tables) {
      if (count(table, to)) throw new Error(`Destination account already has rows in ${table}`);
      counts[table] = count(table, from);
    }
    for (const table of tables) {
      if (table === "note_fts") {
        db.prepare("INSERT INTO note_fts (account, note_id, tokens) SELECT ?, note_id, tokens FROM note_fts WHERE account = ?")
          .run(to, from);
        db.prepare("DELETE FROM note_fts WHERE account = ?").run(from);
      } else {
        db.prepare(`UPDATE ${table} SET account = ? WHERE account = ?`).run(to, from);
      }
      if (count(table, from) !== 0 || count(table, to) !== counts[table]) throw new Error(`Row count mismatch in ${table}`);
    }
    return counts;
  });
}

function prebind(db, args) {
  const { provider, subject, name, email = null, login = null, "user-id": id = randomUUID() } =
    options(args, ["provider", "subject", "name", "login", "email", "user-id"], ["provider", "subject", "name"]);
  if (!["github", "google"].includes(provider) || (provider === "github" && !/^[1-9][0-9]*$/.test(subject)) ||
      !/^[A-Za-z0-9_-]{1,128}$/.test(id)) throw new Error("Invalid provider, subject, or user ID");
  return immediate(db, () => {
    const now = new Date().toISOString();
    db.prepare("INSERT INTO auth_users (id, role, name, email, created_at, updated_at) VALUES (?, 'admin', ?, ?, ?, ?)")
      .run(id, name, email, now, now);
    db.prepare("INSERT INTO auth_identities (provider, subject, user_id, email, login, created_at) VALUES (?, ?, ?, ?, ?, ?)")
      .run(provider, subject, id, email, login, now);
    return { userId: id };
  });
}

function run(db, [group, action, ...args]) {
  const rest = action === undefined ? args : [action, ...args];
  if (group === "prebind-admin") return prebind(db, rest);
  if (group === "migrate-account") return migrate(db, rest);
  if (group === "invite") {
    if (action === "list" && !args.length) return listInvites(db);
    if (action === "create") {
      const { "max-uses": maxUses = "1", days, note } = options(args, ["max-uses", "days", "note"]);
      return createInvite(db, { maxUses: Number(maxUses), days: days === undefined ? null : Number(days), note });
    }
    if (action === "revoke" && args.length === 1) {
      const value = args[0].trim();
      if (!revokeInvite(db, /^[a-f0-9]{64}$/i.test(value) ? value.toLowerCase() : digest(value.toUpperCase()))) {
        throw new Error("No active invite found");
      }
      return { revoked: true };
    }
  }
  if (group === "user") {
    if (action === "list" && !args.length) return db.prepare("SELECT * FROM auth_users ORDER BY created_at").all();
    if (["promote", "disable"].includes(action) && args.length === 1) {
      const [id] = args;
      return immediate(db, () => {
        const now = new Date().toISOString();
        const set = action === "promote" ? "role = 'admin'" : "status = 'disabled'";
        if (!db.prepare(`UPDATE auth_users SET ${set}, updated_at = ? WHERE id = ?`).run(now, id).changes) {
          throw new Error("User not found");
        }
        if (action === "disable") {
          db.prepare("UPDATE auth_sessions SET revoked_at = ? WHERE user_id = ? AND revoked_at IS NULL AND expires_at > ?")
            .run(now, id, now);
        }
        return { userId: id };
      });
    }
  }
  throw new Error("Usage: admin.mjs invite create|list|revoke, user list|promote|disable, prebind-admin, or migrate-account");
}

let db;
try {
  const path = process.env.SQLITE_PATH;
  if (!path?.trim() || path === ":memory:") throw new Error("Set SQLITE_PATH to a persistent database");
  db = new DatabaseSync(path);
  if (!db.prepare("PRAGMA database_list").all().find(row => row.name === "main")?.file) throw new Error("Expected a persistent database");
  db.exec("PRAGMA busy_timeout = 5000;");
  await applyMigrations(db);
  console.log(JSON.stringify(run(db, process.argv.slice(2)), null, 2));
} catch (error) {
  console.error(error.message);
  process.exitCode = 1;
} finally {
  db?.close();
}
