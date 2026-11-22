import {
  blobToVector, contentHashHex, ftsQueryForTokens, normalizeVector, noteIndexText, noteMetadata,
  rankNoteIds, tokenizeForFts, vectorToBlob,
} from './retrieval.js';

function makeEmbedder(env) {
  const provider = env.EMBEDDING_PROVIDER;
  if (provider === 'disabled' || provider === 'none') return { provider: 'disabled', model: null };
  if (provider === 'hash-test') return {
    provider, model: 'hash-test-v1', dims: 128,
    async embed(texts) {
      return texts.map(text => {
        const values = new Float32Array(128);
        for (const token of tokenizeForFts(text)) {
          const hash = contentHashHex(token);
          const bucket = Number.parseInt(hash.slice(0, 8), 16) % values.length;
          values[bucket] += Number.parseInt(hash.at(-1), 16) % 2 ? 1 : -1;
        }
        return normalizeVector(values);
      });
    },
  };
  if (provider === 'remote' || (!provider && env.EMBEDDING_BASE_URL && env.EMBEDDING_API_KEY && env.EMBEDDING_MODEL)) {
    const model = env.EMBEDDING_MODEL;
    return {
      provider: 'remote', model,
      async embed(texts) {
        if (!env.EMBEDDING_BASE_URL || !env.EMBEDDING_API_KEY || !model) throw new Error('远程向量服务配置不完整。');
        const base = new URL(env.EMBEDDING_BASE_URL);
        if (!['http:', 'https:'].includes(base.protocol) || base.username || base.password || base.search || base.hash) {
          throw new Error('远程向量服务地址无效。');
        }
        const response = await fetch(base.href.replace(/\/+$/, '') + '/embeddings', {
          method: 'POST', redirect: 'error', signal: AbortSignal.timeout(55000),
          headers: { Authorization: 'Bearer ' + env.EMBEDDING_API_KEY, 'Content-Type': 'application/json' },
          body: JSON.stringify({ model, input: texts }),
        });
        if (!response.ok) throw new Error('远程向量服务返回 HTTP ' + response.status);
        const data = (await response.json()).data;
        return [...data].sort((a, b) => a.index - b.index).map(row => row.embedding);
      },
    };
  }
  const model = env.EMBEDDING_MODEL || 'Xenova/bge-small-zh-v1.5';
  let pipelinePromise = null;
  return {
    provider: 'local', model, dims: 512,
    async embed(texts, { isQuery } = {}) {
      pipelinePromise ??= import('@huggingface/transformers').then(({ pipeline }) =>
        pipeline('feature-extraction', model, { dtype: 'q8', cache_dir: env.EMBEDDING_CACHE_DIR })).catch(error => {
        pipelinePromise = null;
        throw error;
      });
      const extract = await pipelinePromise;
      const inputs = isQuery ? texts.map(text => '为这个句子生成表示以用于检索相关文章：' + text) : texts;
      return (await extract(inputs, { pooling: 'cls', normalize: true })).tolist();
    },
  };
}

export function createSemanticEngine({ database, env = {}, embedder }) {
  if (!embedder || env.EMBEDDING_PROVIDER === 'disabled' || env.EMBEDDING_PROVIDER === 'none') {
    embedder = makeEmbedder(env);
  }
  const { provider, model } = embedder;
  let dims = embedder.dims;
  const accounts = new Map();
  const queue = new Map();
  let running;
  let inFlight = [];
  const prepare = sql => database.prepare(sql);
  const allNotes = prepare('SELECT id, payload FROM journal_notes WHERE account = ? AND payload IS NOT NULL');
  const currentNote = prepare('SELECT payload FROM journal_notes WHERE account = ? AND id = ? AND payload IS NOT NULL');
  const selectedNotes = prepare(`SELECT n.id, n.payload FROM json_each(?) AS ids CROSS JOIN journal_notes AS n
    WHERE n.account = ? AND n.id = ids.value AND n.payload IS NOT NULL`);
  const lexicalSource = prepare(`SELECT id, json_extract(payload, '$.body') AS body, json_extract(payload, '$.createdAt') AS createdAt,
    json_extract(payload, '$.reading.bookTitle') AS bookTitle, json_extract(payload, '$.reading.chapter') AS chapter,
    json_extract(payload, '$.reading.author') AS author FROM journal_notes WHERE account = ? AND payload IS NOT NULL`);
  const countNotes = prepare('SELECT count(*) AS count FROM journal_notes WHERE account = ? AND payload IS NOT NULL');
  const accountFts = prepare('SELECT rowid, note_id, tokens FROM note_fts WHERE account = ?');
  const deleteFts = prepare('DELETE FROM note_fts WHERE rowid = ? AND account = ?');
  const updateFts = prepare('UPDATE note_fts SET tokens = ? WHERE rowid = ? AND account = ?');
  const addFts = prepare('INSERT INTO note_fts(account, note_id, tokens) VALUES (?, ?, ?)');
  const queryFts = prepare('SELECT note_id, tokens FROM note_fts WHERE tokens MATCH ? AND account = ?');
  const allVectors = prepare('SELECT note_id, model, dims, content_hash, vector FROM note_embeddings WHERE account = ?');
  const deleteVector = prepare('DELETE FROM note_embeddings WHERE account = ? AND note_id = ?');
  const saveVector = prepare(`INSERT INTO note_embeddings(account, note_id, model, dims, content_hash, vector, updated_at)
    VALUES (?, ?, ?, ?, ?, ?, ?) ON CONFLICT(account, note_id) DO UPDATE SET
    model = excluded.model, dims = excluded.dims, content_hash = excluded.content_hash, vector = excluded.vector, updated_at = excluded.updated_at`);

  function accountState(account) {
    if (!accounts.has(account)) accounts.set(account, {
      ready: false, error: null, embeddingError: null, metadata: new Map(), fts: new Map(), vectors: new Map(), coldTokens: null,
    });
    return accounts.get(account);
  }

  function transact(fn) {
    database.exec('BEGIN IMMEDIATE');
    try {
      fn();
      database.exec('COMMIT');
    } catch (error) {
      database.exec('ROLLBACK');
      throw error;
    }
  }

  const jobKey = (account, id) => JSON.stringify([account, id]);
  function updateIndex(account, id, note, state) {
    const existing = state.fts.get(id);
    const vector = state.vectors.get(id);
    const key = jobKey(account, id);
    if (!note) {
      if (existing) deleteFts.run(existing.rowid, account);
      deleteVector.run(account, id);
      state.metadata.delete(id);
      state.fts.delete(id);
      state.vectors.delete(id);
      queue.delete(key);
      return;
    }
    const text = noteIndexText(note);
    const contentHash = contentHashHex(text);
    state.metadata.set(id, { ...noteMetadata(note), contentHash });
    const tokens = tokenizeForFts(text).join(' ');
    if (!existing) state.fts.set(id, { rowid: addFts.run(account, id, tokens).lastInsertRowid, tokens });
    else if (existing.tokens !== tokens) {
      updateFts.run(tokens, existing.rowid, account);
      state.fts.set(id, { ...existing, tokens });
    }
    if (vector && vector.contentHash !== contentHash) {
      deleteVector.run(account, id);
      state.vectors.delete(id);
    }
    if (embedder.embed && (vector?.contentHash !== contentHash || (dims && vector.vector.length !== dims))) {
      queue.set(key, { account, id, contentHash, text });
    } else {
      queue.delete(key);
    }
  }

  async function embedTexts(texts, isQuery) {
    const vectors = await embedder.embed(texts, { isQuery });
    if (vectors?.length !== texts.length || !vectors.length) throw new Error('向量数与输入不一致。');
    const size = dims ?? vectors[0]?.length;
    if (!size || !vectors.every(vector => vector?.length === size && Array.from(vector).every(Number.isFinite))) {
      throw new Error('向量维数或数值无效。');
    }
    dims ??= size;
    return vectors.map(normalizeVector);
  }

  function startQueue() {
    if (running || !queue.size) return;
    running = (async () => {
      while (queue.size) {
        await new Promise(resolve => setImmediate(resolve));
        const account = queue.values().next().value?.account;
        for (const [key, job] of queue) {
          if (job.account !== account) continue;
          inFlight.push(job);
          queue.delete(key);
          if (inFlight.length === 16) break;
        }
        if (!inFlight.length) continue;
        try {
          const vectors = await embedTexts(inFlight.map(job => job.text), false);
          const written = [];
          transact(() => {
            inFlight.forEach(({ account, id, contentHash }, i) => {
              const { payload } = currentNote.get(account, id) ?? {};
              // Recheck the authoritative row under the same write lock as the vector upsert.
              if (!payload || contentHashHex(noteIndexText(JSON.parse(payload))) !== contentHash) return;
              saveVector.run(account, id, model, dims, contentHash, vectorToBlob(vectors[i]), new Date().toISOString());
              written.push({ account, id, contentHash, vector: vectors[i] });
            });
          });
          for (const { account, id, ...entry } of written) {
            const state = accountState(account);
            if (state.metadata.get(id)?.contentHash === entry.contentHash) state.vectors.set(id, entry);
            const key = jobKey(account, id);
            if (queue.get(key)?.contentHash === entry.contentHash) queue.delete(key);
          }
        } catch (error) {
          accountState(account).embeddingError = error.message || '无法生成笔记向量。';
        } finally {
          inFlight = [];
        }
      }
    })().finally(() => {
      running = undefined;
      startQueue();
    });
  }

  function recordError(account, error) {
    const state = accountState(account);
    state.ready = false;
    state.error = error.message || '更新语义索引失败。';
    state.metadata.clear();
    state.coldTokens = null;
    state.fts.clear();
    state.vectors.clear();
    for (const [key, job] of queue) if (job.account === account) queue.delete(key);
  }

  async function waitIdle() {
    while (running) await running;
  }

  async function syncAccount(account, { waitForEmbeddings = false } = {}) {
    const state = accountState(account);
    state.embeddingError = null;
    try {
      transact(() => {
        const active = allNotes.all(account);
        state.metadata = new Map();
        state.coldTokens = null;
        state.fts = new Map();
        for (const row of accountFts.all(account)) {
          if (state.fts.has(row.note_id)) deleteFts.run(row.rowid, account);
          else state.fts.set(row.note_id, row);
        }
        const stored = allVectors.all(account);
        state.vectors = new Map(stored
          .filter(row => embedder.embed && row.model === model && (!dims || row.dims === dims))
          .map(row => [row.note_id, { contentHash: row.content_hash, vector: blobToVector(row.vector) }]));
        const liveIds = new Set(active.map(row => row.id));
        for (const id of new Set([...state.fts.keys(), ...stored.map(row => row.note_id)])) {
          if (!liveIds.has(id)) updateIndex(account, id, null, state);
        }
        for (const { id, payload } of active) updateIndex(account, id, JSON.parse(payload), state);
      });
      state.ready = true;
      state.error = null;
      startQueue();
    } catch (error) {
      recordError(account, error);
    }
    if (waitForEmbeddings) await waitIdle();
    return getStatus(account);
  }

  function onNotesChanged(account, { upserts = [], deletes = [] }) {
    const state = accountState(account);
    if (!state.ready) return syncAccount(account);
    try {
      transact(() => {
        for (const id of new Set([...upserts.map(note => note.id), ...deletes])) {
          const row = currentNote.get(account, id);
          updateIndex(account, id, row ? JSON.parse(row.payload) : null, state);
        }
      });
      startQueue();
    } catch (error) {
      recordError(account, error);
    }
  }

  function getStatus(account) {
    const state = accountState(account);
    const pending = [...queue.values(), ...inFlight].filter(job => job.account === account).length;
    return {
      provider, model, indexed: state.vectors.size,
      total: countNotes.get(account).count, pending, indexing: pending > 0,
      ftsReady: state.ready, lastError: state.error ?? state.embeddingError,
    };
  }

  function retrievalState(account) {
    const state = accountState(account);
    // A cold chat may read the corpus before reconciliation, without writing an index before the model replies.
    if (!state.ready && !state.coldTokens) {
      const tokens = new Map();
      const metadata = new Map();
      for (const { id, body, createdAt, bookTitle, chapter, author } of lexicalSource.all(account)) {
        const note = { body, createdAt, reading: { bookTitle, chapter, author } };
        const text = noteIndexText(note);
        metadata.set(id, { ...noteMetadata(note), contentHash: contentHashHex(text) });
        tokens.set(id, tokenizeForFts(text));
      }
      state.metadata = metadata;
      state.coldTokens = tokens;
    }
    return state;
  }

  const splitTokens = tokens => tokens ? tokens.split(' ') : [];

  function retrieve(account, state, queryTokens, options) {
    const match = ftsQueryForTokens(queryTokens);
    const matches = state.coldTokens ?? new Map(match ? queryFts.all(match, account)
      .map(row => [row.note_id, splitTokens(row.tokens)]) : []);
    const ranked = rankNoteIds(state.metadata, { ...options, queryTokens, matches, vectors: state.vectors });
    if (!ranked.length) return [];
    const payloads = new Map(selectedNotes.all(JSON.stringify(ranked.map(item => item.id)), account)
      .map(({ id, payload }) => [id, JSON.parse(payload)]));
    return ranked.filter(item => payloads.has(item.id)).map(item => ({ ...item, note: payloads.get(item.id) }));
  }

  async function getRelatedNotes(account, noteId, limit = 10, { readOnly = false } = {}) {
    if (!readOnly && !accountState(account).ready) await syncAccount(account);
    const row = currentNote.get(account, noteId);
    if (!row) return null;
    const state = retrievalState(account);
    const queryTokens = state.coldTokens?.get(noteId) ?? splitTokens(state.fts.get(noteId)?.tokens);
    const vector = state.vectors.get(noteId)?.vector;
    const related = retrieve(account, state, queryTokens, { focusId: noteId, limit, vector });
    return { focus: JSON.parse(row.payload), mode: vector ? 'hybrid' : 'lexical', indexed: state.vectors.size,
      total: state.metadata.size, related };
  }

  async function searchNotes(account, query, { limit = 10, excludeIds = [], readOnly = false } = {}) {
    if (!readOnly && !accountState(account).ready) await syncAccount(account);
    const queryTokens = tokenizeForFts(query);
    if (!queryTokens.length) return { mode: 'lexical', items: [] };
    let vector;
    if (accountState(account).vectors.size) {
      try { [vector] = await embedTexts([query], true); }
      catch (error) {
        accountState(account).embeddingError = error.message || '无法生成查询向量。';
      }
    }
    const state = retrievalState(account);
    return { mode: vector ? 'hybrid' : 'lexical',
      items: retrieve(account, state, queryTokens, { limit, excludeIds, vector }) };
  }

  return { syncAccount, onNotesChanged, recordError, waitIdle, getStatus, getRelatedNotes, searchNotes };
}
