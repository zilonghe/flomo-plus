const gateway = "https://i.weread.qq.com/api/agent/gateway";
// Match the version in Tencent/WeChatReading/skills/SKILL.md.
const skillVersion = "1.0.5";
const firstReviewCount = 100;
const maxReviews = 5000;
const maxReviewPages = 50;
const maxGatewayResponseBytes = 8 * 1024 * 1024;
const maxBookEntries = 10_000;
const encoder = new TextEncoder();

export class WeReadError extends Error {
  constructor(status, message) {
    super(message);
    this.status = status;
  }
}

function responseError() {
  return new WeReadError(502, "微信读书返回了无法识别的数据，请稍后再试。");
}

function invalidKey() {
  return new WeReadError(400, "微信读书未接受此 API Key，请核对或重新获取。");
}

function dataTooLarge() {
  return new WeReadError(413, "这本书的微信读书数据较多，请使用手动导入。");
}

function incompleteReviews() {
  return new WeReadError(502, "微信读书没有返回这本书的完整想法，请稍后重试或使用手动导入。");
}

function isRecord(value) {
  return Boolean(value) && typeof value === "object" && !Array.isArray(value);
}

function integer(value) {
  if (typeof value !== "number" && (typeof value !== "string" || !/^-?\d+$/.test(value))) {
    return null;
  }
  const number = Number(value);
  return Number.isSafeInteger(number) ? number : null;
}

function apiKey(value) {
  const key = typeof value === "string" ? value.trim() : "";
  if (!/^wrk-[!-~]{1,512}$/.test(key)) {
    throw new WeReadError(400, "请填写从微信读书官方页面获取的 API Key。");
  }
  return key;
}

async function readGatewayResponse(response) {
  const reader = response.body?.getReader();
  if (!reader) throw responseError();

  const decoder = new TextDecoder("utf-8", { fatal: true });
  const chunks = [];
  let bytes = 0;
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      bytes += value.byteLength;
      if (bytes > maxGatewayResponseBytes) {
        await reader.cancel();
        throw dataTooLarge();
      }
      chunks.push(decoder.decode(value, { stream: true }));
    }
    chunks.push(decoder.decode());
    return JSON.parse(chunks.join(""));
  } catch (error) {
    if (error instanceof WeReadError) throw error;
    throw responseError();
  } finally {
    reader.releaseLock();
  }
}

async function requestGateway(key, apiName, parameters, expectedField, signal) {
  let response;
  try {
    response = await fetch(gateway, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${key}`,
        "Content-Type": "application/json",
        Accept: "application/json",
      },
      redirect: "error",
      signal,
      body: JSON.stringify({ api_name: apiName, skill_version: skillVersion, ...parameters }),
    });
  } catch {
    throw new WeReadError(502, "暂时无法连接微信读书，请稍后再试。");
  }

  if (response.status === 401 || response.status === 403) throw invalidKey();
  if (response.status === 429) throw new WeReadError(429, "微信读书请求过于频繁，请稍后再试。");
  if (!response.ok) throw new WeReadError(502, "微信读书服务暂时不可用，请稍后再试。");

  const result = await readGatewayResponse(response);
  if (!isRecord(result)) throw responseError();
  const data = isRecord(result.data) ? result.data : null;

  if (result.upgrade_info != null || data?.upgrade_info != null) {
    throw new WeReadError(503, "微信读书官方接口要求升级，当前导入已暂停。请稍后再试。");
  }
  const errorCode = integer(result.errcode ?? data?.errcode);
  if (errorCode === -2010 || errorCode === -2012) throw invalidKey();
  if (errorCode != null && errorCode !== 0) {
    throw new WeReadError(502, "微信读书没有完成这次请求，请稍后再试。");
  }

  if (Object.hasOwn(result, expectedField)) return result;
  if (data && Object.hasOwn(data, expectedField)) return data;
  throw responseError();
}

function text(value) {
  return typeof value === "string" ? value.trim() : "";
}

function identifier(value) {
  if (typeof value === "string") return value.trim();
  return Number.isSafeInteger(value) ? String(value) : "";
}

function readTimestamp(value) {
  const seconds = integer(value);
  if (seconds == null || seconds <= 0 || seconds >= 253402300800) return null;
  return new Date(seconds * 1000).toISOString();
}

function hasMore(value) {
  return value === true || integer(value) === 1;
}

function rows(value) {
  if (!Array.isArray(value)) throw responseError();
  return value;
}

export async function listWeReadBooks(input) {
  const key = apiKey(input.apiKey);
  const previous = input.lastSort == null ? null : integer(input.lastSort);
  if (input.lastSort != null && (previous == null || previous <= 0)) {
    throw new WeReadError(400, "微信读书笔记列表的分页位置无效。");
  }
  const parameters = { count: 40, ...(previous == null ? {} : { lastSort: previous }) };
  const result = await requestGateway(key, "/user/notebooks", parameters, "books", AbortSignal.timeout(12_000));
  const books = rows(result.books);
  const nextCursor = hasMore(result.hasMore) ? integer(books.at(-1)?.sort) : null;
  if (hasMore(result.hasMore) && (nextCursor == null || nextCursor <= 0 || (previous != null && nextCursor >= previous))) {
    throw responseError();
  }
  return {
    books: books.flatMap((item) => {
      const id = identifier(item?.bookId);
      const title = text(item?.book?.title);
      if (!id || !title) return [];
      return [{
        id,
        title,
        author: text(item.book.author),
        noteCount: Math.max(0, integer(item.noteCount) ?? 0),
        reviewCount: Math.max(0, integer(item.reviewCount) ?? 0),
      }];
    }),
    nextCursor,
  };
}

async function readReviews(key, bookId, signal) {
  const reviews = [];
  const cursors = new Set([0]);
  let cursor = 0;
  let count = firstReviewCount;
  let responseSize = 0;
  let repeatedIDs = 0;
  const seenIDs = new Set();
  for (let page = 0; page < maxReviewPages; page++) {
    const result = await requestGateway(
      key, "/review/list/mine", { bookid: bookId, synckey: cursor, count }, "reviews", signal
    );
    const latest = rows(result.reviews);
    const total = integer(result.totalCount);
    const more = hasMore(result.hasMore);

    // Some gateway responses marked a truncated first page as complete.
    // Request the reported count once and check that we got it.
    if (!more && cursor === 0 && total != null && reviews.length + latest.length < total && total > count && total <= maxReviews) {
      count = total;
      continue;
    }

    if (reviews.length + latest.length > maxReviews) throw incompleteReviews();
    responseSize += JSON.stringify(latest).length;
    if (responseSize > maxGatewayResponseBytes) throw dataTooLarge();
    for (const item of latest) {
      const id = identifier(item?.review?.reviewId);
      if (id && seenIDs.has(id)) repeatedIDs++;
      if (id) seenIDs.add(id);
      reviews.push(item);
    }
    if (!more) {
      if (total != null && reviews.length - repeatedIDs < total) throw incompleteReviews();
      return reviews;
    }

    const next = integer(result.synckey);
    if (next == null || cursors.has(next) || latest.length === 0) throw incompleteReviews();
    cursors.add(next);
    cursor = next;
  }
  throw incompleteReviews();
}

async function sha256(value) {
  return new Uint8Array(await crypto.subtle.digest("SHA-256", encoder.encode(value)));
}

async function noteID(bookId, kind, sourceID) {
  const digest = await sha256(JSON.stringify(["weread", bookId, kind, sourceID]));
  const bytes = digest.slice(0, 16);
  bytes[6] = (bytes[6] & 0x0f) | 0x80;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  const hex = Array.from(bytes, byte => byte.toString(16).padStart(2, "0")).join("");
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
}

function sourceNotes(highlights, reviews) {
  const entries = [];
  for (const highlight of rows(highlights.updated)) {
    if (integer(highlight?.type) === 0) continue;
    entries.push({
      kind: "highlight",
      id: identifier(highlight?.bookmarkId),
      chapter: identifier(highlight?.chapterUid),
      createdAt: readTimestamp(highlight?.createTime),
      body: text(highlight?.markText),
    });
  }
  for (const item of reviews) {
    const review = item?.review;
    const comment = text(review?.content);
    const quote = text(review?.abstract);
    const body = comment && quote && quote !== comment ? `${comment}\n\n原文：${quote}` : comment || quote;
    entries.push({
      kind: "review",
      id: identifier(review?.reviewId),
      chapter: identifier(review?.chapterUid),
      chapterName: text(review?.chapterName),
      createdAt: readTimestamp(review?.createTime),
      body,
    });
  }
  return entries;
}

function bookMetadata(value) {
  return { bookTitle: text(value?.title).slice(0, 500), author: text(value?.author).slice(0, 500) };
}

export async function listWeReadNotes(input) {
  const key = apiKey(input.apiKey);
  const bookId = identifier(input.bookId);
  if (!bookId || bookId.length > 192 || /[\s\x00-\x1f]/.test(bookId)) {
    throw new WeReadError(400, "请选择一本微信读书里的书。");
  }
  const signal = AbortSignal.timeout(35_000);
  const [highlights, reviews] = await Promise.all([
    requestGateway(key, "/book/bookmarklist", { bookId }, "updated", signal),
    readReviews(key, bookId, signal),
  ]);
  if (rows(highlights.updated).length + reviews.length > maxBookEntries) throw dataTooLarge();
  const entries = sourceNotes(highlights, reviews);
  let metadata = bookMetadata(highlights.book);
  if (entries.length && !metadata.bookTitle) {
    const result = await requestGateway(key, "/book/info", { bookId }, "title", signal);
    const fallback = bookMetadata(result);
    metadata = { bookTitle: fallback.bookTitle, author: metadata.author || fallback.author };
    if (!metadata.bookTitle) throw responseError();
  }
  const chapters = new Map((Array.isArray(highlights.chapters) ? highlights.chapters : []).map(chapter => [
    identifier(chapter?.chapterUid), text(chapter?.title).slice(0, 500),
  ]));
  const seen = new Set();
  let skipped = 0;
  const candidates = entries.filter(entry => {
    if (!entry.id || !entry.createdAt || !entry.body) {
      skipped++;
      return false;
    }
    const key = entry.kind + ":" + entry.id;
    if (seen.has(key)) return false;
    seen.add(key);
    return true;
  });
  candidates.sort((left, right) => right.createdAt.localeCompare(left.createdAt));

  // Work in bounded groups to avoid hashing an entire large book at once.
  const notes = [];
  for (let index = 0; index < candidates.length; index += 128) {
    const group = await Promise.all(candidates.slice(index, index + 128).map(async entry => ({
      id: await noteID(bookId, entry.kind, entry.id),
      body: entry.body,
      createdAt: entry.createdAt,
      reading: {
        ...metadata,
        chapter: chapters.get(entry.chapter) || entry.chapterName?.slice(0, 500) || null,
        sourceDate: entry.createdAt,
        fingerprint: btoa(String.fromCharCode(...await sha256(entry.body.normalize("NFC")))),
      },
      turns: [],
    })));
    notes.push(...group);
  }
  return { notes, skipped };
}
