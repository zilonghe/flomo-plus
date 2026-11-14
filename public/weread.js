// Common layouts from WeRead's clipboard export and Markdown exporters.
const patterns = {
    bookTitle: /^(?:#\s+)?《(.+?)》(?:\s*(?:读书笔记|阅读笔记|笔记|划线))?$/u,
    noteCount: /^\d+\s*(?:个|条|则)?\s*(?:笔记|条划线)$/u,
    footer: /^(?:[-―—–]+\s*)?来自微信读书[。.]?$/u,
    author: /^(?:\*\*)?作者\s*[:：]\s*(?:\*\*)?\s*(.+?)\s*(?:\*\*)?$/u,
    thoughtStart: /^(?:[◆•*\-]\s*)?(?:(?:\d{4}[./-]\d{1,2}[./-]\d{1,2}|\d{4}年\d{1,2}月\d{1,2}日)\s*)?发表想法\s*(?:[:：].*)?$/u,
    inlineThought: /发表想法\s*[:：]\s*(.+)$/u,
    date: /(\d{4}[./-]\d{1,2}[./-]\d{1,2}|\d{4}年\d{1,2}月\d{1,2}日)/u,
    original: /^(?:>+\s*)?(?:\*\*)?(?:原文|摘录|划线)\s*[:：]\s*(?:\*\*)?\s*(.*)$/u,
    remark: /^(?:\*\*)?(?:我的想法|想法|批注|点评)\s*[:：]\s*(?:\*\*)?\s*(.*)$/u,
    classified: /^〖(想法|批注|点评|直线|高亮|波浪线|未识别)〗/u,
    markdownChapter: /^#{2,6}\s+(.+)$/u,
    bracketedChapter: /^〖(.+)〗$/u,
    nativeChapter: /^(?:第[零一二三四五六七八九十百千两\d]+[卷篇部章节回幕集讲]|文前$|序言|前言|(?:推荐|译者|译|自|代)序|后记|跋$|附录).*$/u,
    bareChapter: /^[^。．，,！？!?；;：:◆>《》#]{1,45}$/u,
    bullet: /^(?:[-*+]\s+|\d+[.、)）]\s*)(.+)$/u,
    separator: /^(?:-{3,}|\*{3,}|_{3,})$/u
};

const ideaHeadings = new Set(["想法", "我的想法", "批注", "点评", "书评"]);

function group(pattern, line) {
    return pattern.exec(line)?.[1]?.trim();
}

function parseDate(value) {
    if (!value) return undefined;
    const [year, month, day] = value.match(/\d+/g).map(Number);
    if (!year || month < 1 || month > 12 || day < 1 || day > 31) return undefined;
    const date = new Date(0);
    date.setFullYear(year, month - 1, day);
    date.setHours(0, 0, 0, 0);
    if (date.getFullYear() !== year || date.getMonth() !== month - 1 || date.getDate() !== day) return undefined;
    return date.toISOString();
}

function chapterHeading(line, previous, next, nativeLayout, separatedFromNote) {
    const markdown = group(patterns.markdownChapter, line);
    if (markdown) return markdown;
    const bracketed = group(patterns.bracketedChapter, line);
    if (bracketed && patterns.bullet.test(next)) return bracketed;
    if (line.startsWith("◆") && next.startsWith(">>") && !patterns.thoughtStart.test(line)) {
        const older = line.slice(1).trim();
        if (older) return older;
    }
    if (!nativeLayout || (!next.startsWith("◆") && !patterns.thoughtStart.test(next))) return undefined;
    if (patterns.nativeChapter.test(line)) return line;
    const followsQuote = patterns.original.test(previous)
        || (previous.startsWith("◆") && !patterns.thoughtStart.test(previous));
    const followsCount = patterns.noteCount.test(previous);
    if ((followsCount || (followsQuote && separatedFromNote)) && patterns.bareChapter.test(line)) return line;
    return undefined;
}

function newDraft() {
    return { section: "remark", quoteUsesMarkdown: false, date: undefined, quote: [], remark: [] };
}

function parseEntries(text) {
    const originalLines = text.split("\n");
    const lines = originalLines.map(line => line.trim());
    const nativeLayout = lines.some(line => patterns.noteCount.test(line) || patterns.footer.test(line));
    const markers = lines.some(line => line.startsWith("◆") || line.startsWith(">")
        || patterns.thoughtStart.test(line) || patterns.original.test(line)
        || patterns.classified.test(line) || patterns.remark.test(line));
    const markdownLayout = lines[0].startsWith("# ") && lines.some(line => line.startsWith("## "));
    if (!nativeLayout && !markers && !markdownLayout) return [];

    const followingNonempty = Array(lines.length);
    let nextIndex = lines.length;
    for (let index = lines.length - 1; index >= 0; index -= 1) {
        followingNonempty[index] = nextIndex;
        if (lines[index]) nextIndex = index;
    }

    const entries = [];
    let bookTitle = null;
    let author = null;
    let chapter = null;
    let draft = newDraft();
    let previous = "";
    let expectingBookHeader = true;
    let readingMetadata = false;
    let markdownListSection;

    const flush = () => {
        const quote = draft.quote.join("\n").trim();
        const remark = draft.remark.join("\n").trim();
        const body = remark && quote ? `${remark}\n\n原文：${quote}` : (remark || quote);
        if (body) {
            entries.push({
                body,
                bookTitle,
                author,
                chapter,
                sourceDate: draft.date
            });
        }
        draft = newDraft();
    };

    for (const [index, line] of lines.entries()) {
        if (!line) {
            if (draft.quote.length || draft.remark.length) draft[draft.section].push("");
            continue;
        }

        const followingIndex = followingNonempty[index];
        const next = lines[followingIndex] ?? "";
        const prior = previous;
        previous = line;

        if (patterns.footer.test(line)) {
            flush();
            expectingBookHeader = true;
            continue;
        }

        const atBookHeader = expectingBookHeader;
        expectingBookHeader = false;
        const title = group(patterns.bookTitle, line) ?? (line.startsWith("# ") ? line.slice(2) : undefined);
        if (title && atBookHeader) {
            flush();
            bookTitle = title.trim();
            author = null;
            chapter = null;
            markdownListSection = undefined;
            readingMetadata = true;
            continue;
        }

        if (readingMetadata) {
            const metadata = line.startsWith(">") ? line.slice(1).trim() : line;
            const namedAuthor = group(patterns.author, metadata);
            if (namedAuthor) {
                author = namedAuthor;
                continue;
            }
            if (patterns.noteCount.test(next) && !patterns.noteCount.test(line) && !line.startsWith("◆")) {
                author = line;
                continue;
            }
            readingMetadata = false;
        }

        if (patterns.noteCount.test(line) && !draft.quote.length && !draft.remark.length) continue;
        if (patterns.separator.test(line)) {
            flush();
            continue;
        }

        const separatedFromNote = (index > 0 && !lines[index - 1]) || followingIndex > index + 1;
        const heading = chapterHeading(line, prior, next, nativeLayout, separatedFromNote);
        if (heading) {
            flush();
            chapter = heading;
            markdownListSection = line.startsWith("#") || line.startsWith("〖")
                ? (ideaHeadings.has(heading) ? "remark" : "quote")
                : undefined;
            continue;
        }

        if (patterns.thoughtStart.test(line)) {
            flush();
            draft.date = parseDate(group(patterns.date, line));
            const remark = group(patterns.inlineThought, line);
            if (remark) draft.remark.push(remark);
            continue;
        }

        const kind = group(patterns.classified, line);
        if (kind) {
            flush();
            draft.section = ideaHeadings.has(kind) ? "remark" : "quote";
            draft[draft.section].push(line.slice(line.indexOf("〗") + 1));
            continue;
        }

        if (line.startsWith("◆")) {
            flush();
            draft.section = "quote";
            const quote = line.slice(1).trim();
            draft.quote.push(group(patterns.original, quote) ?? quote);
            continue;
        }

        const quote = group(patterns.original, line);
        if (quote !== undefined) {
            if (draft.quote.length) flush();
            draft.section = "quote";
            draft.quote.push(quote);
            continue;
        }

        const remark = group(patterns.remark, line);
        if (remark !== undefined) {
            draft.section = "remark";
            draft.remark.push(remark);
            continue;
        }

        if (line.startsWith(">")) {
            if (draft.quote.length && index > 0 && !lines[index - 1]) flush();
            draft.section = "quote";
            draft.quoteUsesMarkdown = true;
            draft.quote.push(line.replace(/^>+/u, "").trim());
            continue;
        }

        const bullet = markdownListSection ? group(patterns.bullet, line) : undefined;
        if (bullet) {
            flush();
            draft.section = markdownListSection;
            draft[draft.section].push(bullet);
            continue;
        }

        if (draft.quoteUsesMarkdown) draft.section = "remark";
        draft[draft.section].push(originalLines[index]);
    }

    flush();
    return entries;
}

async function fingerprint(body) {
    const digest = await globalThis.crypto.subtle.digest("SHA-256", new TextEncoder().encode(body.trim().normalize("NFC")));
    return btoa(String.fromCharCode(...new Uint8Array(digest)));
}

export async function parseWeRead(source) {
    const text = source.replace(/^\uFEFF/u, "").replace(/\r\n?|[\u2028\u2029]/gu, "\n").trim();
    if (!text) return [];
    const entries = parseEntries(text);
    if (!entries.length) entries.push({ body: text, bookTitle: null, author: null, chapter: null });
    const importedAt = new Date().toISOString();
    return Promise.all(entries.map(async ({ body, bookTitle, author, chapter, sourceDate }) => ({
        body,
        createdAt: sourceDate ?? importedAt,
        reading: {
            bookTitle,
            author,
            chapter,
            ...(sourceDate && { sourceDate }),
            fingerprint: await fingerprint(body)
        }
    })));
}

export async function readWeReadFile(file) {
    try {
        const bytes = new Uint8Array(await file.arrayBuffer());
        const encoding = bytes[0] === 0xFF && bytes[1] === 0xFE ? "utf-16le"
            : bytes[0] === 0xFE && bytes[1] === 0xFF ? "utf-16be" : "utf-8";
        const text = new TextDecoder(encoding, { fatal: true }).decode(bytes);
        if (text.includes("\0")) throw new Error("NUL");
        return text;
    } catch {
        throw new Error("无法读取文件。请选择 UTF-8 或带字节顺序标记的 UTF-16 文本文件。");
    }
}
