import { createHash, createHmac } from "node:crypto";
import { createReadStream, createWriteStream } from "node:fs";
import { stat } from "node:fs/promises";
import { pipeline } from "node:stream/promises";

const sha256 = value => createHash("sha256").update(value).digest("hex");
const hmac = (key, value) => createHmac("sha256", key).update(value).digest();
const encode = value => encodeURIComponent(value).replace(/[!'()*]/g, char => "%" + char.charCodeAt(0).toString(16).toUpperCase());
const compare = (a, b) => a < b ? -1 : a > b ? 1 : 0;
const canonicalQuery = params => Array.from(params, ([name, value]) => [encode(name), encode(value)])
  .sort(([a, av], [b, bv]) => compare(a, b) || compare(av, bv)).map(pair => pair.join("=")).join("&");
const emptyHash = sha256("");

export function parseForcePathStyle(value, defaultValue = true) {
  const normalized = String(value ?? "").trim().toLowerCase();
  if (!normalized) return defaultValue;
  if (normalized === "true" || normalized === "1") return true;
  if (normalized === "false" || normalized === "0") return false;
  throw new Error("Invalid S3 force path style setting");
}

export function signS3Request({ method, url, region, accessKeyId, secretAccessKey, date, payloadHash = emptyHash }) {
  const amzDate = date.toISOString().replace(/[:-]|\.\d{3}/g, "");
  const short = amzDate.slice(0, 8);
  const headers = { host: url.host, "x-amz-content-sha256": payloadHash, "x-amz-date": amzDate };
  const signed = Object.keys(headers).join(";");
  const canonicalHeaders = Object.entries(headers).map(([name, value]) => name + ":" + value + "\n").join("");
  const canonical = [method, url.pathname, canonicalQuery(url.searchParams), canonicalHeaders, signed, payloadHash].join("\n");
  const scope = [short, region, "s3", "aws4_request"].join("/");
  const key = hmac(hmac(hmac(hmac("AWS4" + secretAccessKey, short), region), "s3"), "aws4_request");
  const signature = hmac(key, ["AWS4-HMAC-SHA256", amzDate, scope, sha256(canonical)].join("\n")).toString("hex");
  headers.authorization = "AWS4-HMAC-SHA256 Credential=" + accessKeyId + "/" + scope + ", SignedHeaders=" + signed + ", Signature=" + signature;
  return headers;
}

const xmlText = value => value.replace(/&(amp|lt|gt|quot|apos|#\d+|#x[0-9a-fA-F]+);/g, (_, entity) => {
  const plain = { amp: "&", lt: "<", gt: ">", quot: '"', apos: "'" }[entity];
  return plain ?? String.fromCodePoint(entity[1] === "x" ? parseInt(entity.slice(2), 16) : Number(entity.slice(1)));
});

function fields(xml, name) {
  return Array.from(xml.matchAll(new RegExp("<" + name + ">([^<]*)</" + name + ">", "g")), match => xmlText(match[1]));
}

export function createS3Client({ endpoint, bucket, region, accessKeyId, secretAccessKey, forcePathStyle = true,
  now = () => new Date(), fetchImpl = fetch, timeoutMs = 300_000 }) {
  let target;
  try { target = new URL(endpoint); } catch { throw new Error("Invalid S3 endpoint"); }
  if (target.username || target.password || target.search || target.hash ||
    !(target.protocol === "https:" || (target.protocol === "http:" && ["localhost", "127.0.0.1", "[::1]"].includes(target.hostname)))) {
    throw new Error("S3 endpoint requires HTTPS or loopback HTTP");
  }
  if (!/^[a-z0-9][a-z0-9.-]*[a-z0-9]$/.test(bucket ?? "")) throw new Error("Invalid S3 bucket name");
  const origin = forcePathStyle ? target.origin : target.protocol + "//" + bucket + "." + target.host;
  const pathPrefix = target.pathname.replace(/\/$/, "").split("/").map(s => encode(decodeURIComponent(s))).join("/");
  const base = pathPrefix + (forcePathStyle ? "/" + bucket : "");

  async function request(method, { key, params = [], file } = {}) {
    const uri = key === undefined ? base || "/" : base + "/" + key.split("/").map(encode).join("/");
    const query = canonicalQuery(params);
    const url = new URL(origin + uri + (query ? "?" + query : ""));
    if (url.pathname !== uri) throw new Error("Unsafe S3 object key path");
    let payloadHash = emptyHash;
    if (file) {
      const hash = createHash("sha256");
      for await (const chunk of createReadStream(file)) hash.update(chunk);
      payloadHash = hash.digest("hex");
    }
    const headers = signS3Request({ method, url, region, accessKeyId, secretAccessKey, date: now(), payloadHash });
    if (file) headers["content-length"] = String((await stat(file)).size);
    const response = await fetchImpl(url, {
      method, headers, redirect: "error", signal: AbortSignal.timeout(timeoutMs),
      ...(file ? { body: createReadStream(file), duplex: "half" } : {}),
    });
    if (!response.ok) {
      await response.body?.cancel();
      throw new Error("S3 " + method + " failed with HTTP " + response.status);
    }
    return response;
  }

  async function listObjects(prefix) {
    const objects = [];
    const params = [["list-type", "2"], ["prefix", prefix], ["encoding-type", "url"]];
    const seenTokens = new Set();
    let token;
    while (true) {
      const xml = await (await request("GET", { params: token ? [...params, ["continuation-token", token]] : params })).text();
      const result = xml.match(/^\s*(?:<\?xml\s[^?]*\?>\s*)?<ListBucketResult(?:\s[^>]*)?>([\s\S]*?)<\/ListBucketResult>\s*$/)?.[1];
      if (result === undefined || /<\/?ListBucketResult\b/.test(result)) throw new Error("Invalid S3 list response");
      const itemPattern = /<Contents>([\s\S]*?)<\/Contents>/g;
      const items = Array.from(result.matchAll(itemPattern));
      const metadata = result.replace(itemPattern, "");
      if (/<\/?Contents\b/.test(metadata)) throw new Error("Invalid S3 object list");
      const [truncated, ...extraFlags] = fields(metadata, "IsTruncated");
      const tokens = fields(metadata, "NextContinuationToken");
      if (extraFlags.length || !["true", "false"].includes(truncated) ||
        (truncated === "true" && (tokens.length !== 1 || !tokens[0].trim() || seenTokens.has(tokens[0])))) {
        throw new Error("Invalid S3 pagination");
      }
      const urlEncoded = fields(metadata, "EncodingType")[0] === "url";
      for (const [, item] of items) {
        const [key, ...extraKeys] = fields(item, "Key");
        const [etag, ...extraEtags] = fields(item, "ETag");
        const [lastModified = null] = fields(item, "LastModified");
        const [rawSize] = fields(item, "Size");
        const size = Number(rawSize);
        const normalizedETag = etag?.replace(/^"(.*)"$/, "$1").trim();
        if (!key || !normalizedETag || extraKeys.length || extraEtags.length || !/^\d+$/.test(rawSize ?? "") || !Number.isSafeInteger(size)) {
          throw new Error("Invalid S3 object entry");
        }
        objects.push({ key: urlEncoded ? decodeURIComponent(key) : key, etag: normalizedETag, lastModified, size });
      }
      if (truncated === "false") return objects;
      [token] = tokens;
      seenTokens.add(token);
    }
  }

  return {
    listObjects,
    async getObjectText(key) { return (await request("GET", { key })).text(); },
    async getObjectToFile(key, destPath) {
      const response = await request("GET", { key });
      await pipeline(response.body, createWriteStream(destPath));
    },
    async putObjectFile(key, file) { await (await request("PUT", { key, file })).body?.cancel(); },
    async deleteObject(key) { await (await request("DELETE", { key })).body?.cancel(); },
  };
}
