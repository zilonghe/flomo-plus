import { escapeContextTags, extractNoteTags } from "./retrieval.js";

export const INSIGHT_CATEGORIES = ["复盘整理", "自我觉察", "思维决策", "大师视角"];
export const BUILTIN_LENSES = [
  ["default", "默认洞察", 0, "7d", "找出笔记里的主题、变化与下一步", "归纳反复出现的主题，指出新变化和彼此矛盾的线索，最后提出一个可尝试的行动。"],
  ["values", "价值澄清", 1, "month", "从选择中看见你在意的事", "从选择、取舍与情绪反应推断重视的价值，区分已践行的价值与愿望，指出可能冲突的价值。"],
  ["inversion", "逆向思考", 2, "month", "从失败路径反推行动", "反过来问什么会让笔记中的目标落空，列出可预防的失败路径，并将其中一项变成具体行动。"],
  ["second-order", "二阶思考", 2, "month", "看见选择的后续影响", "找出正在考虑的选择，区分即时结果与长期后果，标注依赖的假设和可能反转的条件。"],
  ["cbt", "CBT 疗法", 1, "7d", "梳理情境、念头和反应", "用认知行为框架区分情境、念头、情绪与行为。提出可检验的替代解释，避免诊断。"],
  ["mbti", "MBTI 分析", 1, "all", "从记录观察偏好", "用 MBTI 的四组维度观察行为偏好，为每项列出正反证据。不确定时保留疑问，不给人格定论。"],
  ["weekly-review", "周期复盘", 0, "week", "梳理进展、阻力与计划", "对比本期意图与实际行动，提炼进展、阻力与未决事项，给下一周期排出可行的优先级。"],
  ["knowledge-synthesis", "知识卡片提炼", 0, "month", "将散落的记录整理成知识卡片", "把相互呼应的记录整理成独立知识卡片，每张给出概念、出处、适用条件和一个应用例子。"],
  ["first-principles", "第一性原理", 2, "month", "分清事实和习惯性假设", "还原问题，分开可验证的事实与未经验证的假设，从事实出发重建候选方案。"],
  ["munger", "查理·芒格视角", 3, "all", "用多个模型审视同一个问题", "从激励、机会成本和心理偏差等适用模型分析问题，说明模型何时会失效。"],
  ["drucker", "德鲁克效能视角", 3, "month", "把时间投入到真正的贡献上", "梳理时间花在哪里、哪些行动产生贡献，给出一件应该停止的事和一个可衡量的成果。"],
  ["naval", "纳瓦尔杠杆视角", 3, "all", "寻找能积累和放大的投入", "找出能形成专长、复利或杠杆的行动，区分重复投入与可以重复产生价值的投入。"],
].map(([id, name, category, suggestedRange, description, prompt], index) => ({
  id: "builtin:" + id, name, category: INSIGHT_CATEGORIES[category], suggestedRange, description, prompt,
  featured: index < 6, builtin: true,
}));

export function isChatModelId(id) {
  return typeof id === "string" && /^[A-Za-z0-9_.:-]{1,100}$/.test(id) &&
    !/(?:^|[-_.:/])(?:image|tts|whisper|embedding|embed|moderation|realtime|audio|transcribe|auto-review)(?:$|[-_.:/0-9])/i.test(id);
}

const insightNoteLimit = 80;
const insightChars = 24_000;
const insightDayMs = 86_400_000;
const insightRanges = ["7d", "week", "month", "all", "custom"];

function isInsightDate(value) {
  if (typeof value !== "string" || !/^(?!0000)\d{4}-\d{2}-\d{2}$/.test(value)) return false;
  const parsed = new Date(value + "T00:00:00Z");
  return Number.isFinite(+parsed) && parsed.toISOString().slice(0, 10) === value;
}

export function normalizeInsightScope(input = {}) {
  if (!input || typeof input !== "object" || Array.isArray(input)) throw new TypeError("请选择笔记范围。");
  const { range = "7d", tzOffsetMinutes = 0, tags = [], tagMode = "any", startDate, endDate } = input;
  if (!insightRanges.includes(range) || !Number.isInteger(tzOffsetMinutes) || Math.abs(tzOffsetMinutes) > 840 ||
      !["any", "all"].includes(tagMode) || !Array.isArray(tags) || tags.length > 20 ||
      !tags.every(tag => typeof tag === "string" && /^[\p{L}\p{N}_]+(?:\/[\p{L}\p{N}_]+)*$/u.test(tag.trim()))) {
    throw new TypeError("请检查日期范围和标签。");
  }
  if (range === "custom" && (!isInsightDate(startDate) || !isInsightDate(endDate) || startDate > endDate)) {
    throw new TypeError("请选择有效的起止日期。");
  }
  return {
    range, tzOffsetMinutes, tags: [...new Set(tags.map(tag => tag.trim().toLowerCase()))], tagMode,
    ...(range === "custom" ? { startDate, endDate } : {}),
  };
}

function insightLocalTime(value, offset) {
  return new Date(+new Date(value) - offset * 60_000);
}

export function filterNotesByScope(notes, scope, now = new Date()) {
  const { range, tzOffsetMinutes, tags, tagMode, startDate, endDate } = normalizeInsightScope(scope);
  let start = startDate, end = endDate;
  if (range !== "custom" && range !== "all") {
    const local = insightLocalTime(now, tzOffsetMinutes);
    end = local.toISOString().slice(0, 10);
    const days = range === "week" ? (local.getUTCDay() + 6) % 7 : range === "month" ? local.getUTCDate() - 1 : 6;
    start = new Date(+local - days * insightDayMs).toISOString().slice(0, 10);
  }
  return notes.filter(note => {
    if (start) {
      const date = insightLocalTime(note.createdAt, tzOffsetMinutes).toISOString().slice(0, 10);
      if (date < start || date > end) return false;
    }
    if (!tags.length) return true;
    const actual = extractNoteTags(note.body);
    const matches = tag => actual.some(found => found === tag || found.startsWith(tag + "/"));
    return tagMode === "all" ? tags.every(matches) : tags.some(matches);
  });
}

function insightEntry(note, index) {
  const ref = "N" + (index + 1);
  const source = escapeContextTags(note.reading?.bookTitle || "日志").replace(/\s+/g, " ").replaceAll(")", "）");
  const prefix = `[${ref}] (${note.createdAt.slice(0, 10)} | ${source}) `;
  const body = escapeContextTags(note.body).replace(/(^|\r?\n)(?=\[N\d+\]\s+\()/g, "$1 ");
  return { ref, prefix, body };
}

export function estimateInsightNotesChars(notes) {
  return notes.reduce((sum, note, i) => {
    const { prefix, body } = insightEntry(note, i);
    return sum + prefix.length + body.length + (i ? 2 : 0);
  }, 0);
}

export function computeScopeStats(notes, tzOffsetMinutes = 0) {
  const tags = new Map(), days = new Set();
  for (const note of notes) {
    days.add(insightLocalTime(note.createdAt, tzOffsetMinutes).toISOString().slice(0, 10));
    for (const tag of extractNoteTags(note.body)) tags.set(tag, (tags.get(tag) ?? 0) + 1);
  }
  const topTags = [...tags].sort(([a, x], [b, y]) => y - x || a.localeCompare(b)).slice(0, 12)
    .map(([tag, count]) => ({ tag, count }));
  return {
    noteCount: notes.length, tagCount: tags.size, dayCount: days.size, topTags,
    willSample: notes.length > insightNoteLimit || estimateInsightNotesChars(notes) > insightChars,
  };
}

const insightOrder = (a, b) => b.createdAt.localeCompare(a.createdAt) || a.id.localeCompare(b.id);
const insightNotesStart = "<洞察笔记资料>\n";
const insightNotesEnd = "\n</洞察笔记资料>";
const insightProfile = value => value?.trim() ? "<长期个人画像>\n" + escapeContextTags(value.trim().slice(0, 3_000)) + "\n</长期个人画像>\n\n" : "";

export function insightNotesBudget(profileText, maxTotalChars = Infinity) {
  return Math.max(0, Math.min(insightChars, maxTotalChars - insightProfile(profileText).length - insightNotesStart.length - insightNotesEnd.length));
}

export async function selectNotesForInsight(notes, { query, search, maxNotesChars = insightChars }) {
  const ordered = [...notes].sort(insightOrder);
  if (ordered.length <= insightNoteLimit && estimateInsightNotesChars(ordered) <= maxNotesChars) return ordered;
  const byId = new Map(ordered.map(note => [note.id, note]));
  const ranked = await search(query, { limit: 50, includeIds: new Set(byId.keys()), readOnly: true });
  const chosen = new Set(ranked.slice(0, 50).map(item => item.id).filter(id => byId.has(id)));
  const remaining = ordered.filter(note => !chosen.has(note.id));
  const count = Math.min(insightNoteLimit - chosen.size, remaining.length);
  // Spread the quota across the timeline; use more strata as the sampling rate falls.
  const strata = Math.min(count, Math.max(2, Math.ceil((remaining.length - count) / 8)));
  for (let i = 0; i < strata; i++) {
    const first = Math.floor(i * count / strata);
    const quota = Math.floor((i + 1) * count / strata) - first;
    const start = Math.floor(first * remaining.length / count);
    for (const note of remaining.slice(start, start + quota)) chosen.add(note.id);
  }
  return ordered.filter(note => chosen.has(note.id));
}

export function packInsightContext({ notes, profileText = "", maxNotesChars = insightChars }) {
  const entries = notes.slice(0, insightNoteLimit).map(insightEntry);
  let available = maxNotesChars;
  let count = 0;
  for (const { prefix } of entries) {
    const overhead = prefix.length + (count ? 2 : 0);
    if (available - overhead < count + 1) break;
    available -= overhead;
    count++;
  }
  entries.length = count;
  // Preserve short entries intact before dividing the remaining budget among longer ones.
  const budgets = new Map();
  const shortestFirst = [...entries].sort((a, b) => a.body.length - b.body.length);
  shortestFirst.forEach((entry, i) => {
    const limit = Math.min(entry.body.length, Math.max(0, Math.floor(available / (entries.length - i))));
    budgets.set(entry, limit);
    available -= limit;
  });
  const lines = [], citations = [];
  let contentTruncated = false;
  for (const entry of entries) {
    const { ref, prefix, body } = entry;
    const limit = budgets.get(entry);
    if (body.length > limit) contentTruncated = true;
    const excerpt = body.length <= limit ? body : body.trimStart().slice(0, limit);
    const note = notes[lines.length];
    const bookTitle = note.reading?.bookTitle;
    lines.push(prefix + excerpt);
    citations.push({ ref, noteId: note.id, createdAt: note.createdAt, excerpt, ...(bookTitle ? { bookTitle } : {}) });
  }
  return {
    text: insightProfile(profileText) + insightNotesStart + lines.join("\n\n") + insightNotesEnd,
    citations, analyzedCount: citations.length, contentTruncated,
  };
}

export function buildInsightTaskPrompt(lens) {
  const start = "请按以下视角复盘资料，输出 Markdown 洞察报告。以二级标题开头，用具体笔记编号（如 [N1]）支持发现，区分记录和推断，不编造经历。\n\n<洞察视角任务>\n";
  const end = "\n</洞察视角任务>";
  return start + escapeContextTags([lens.name, lens.description, lens.prompt].join("\n")).slice(0, 4_000 - start.length - end.length) + end;
}
