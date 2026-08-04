export const BLOCK_TYPES = Object.freeze([
  "paragraph",
  "heading1",
  "heading2",
  "heading3",
  "bulleted",
  "numbered",
  "todo",
  "quote",
  "code",
  "divider",
]);

const BLOCK_TYPE_SET = new Set(BLOCK_TYPES);
let blockSequence = 0;

function nextBlockId() {
  blockSequence += 1;
  return `block-${globalThis.crypto?.randomUUID?.() || `${Date.now()}-${blockSequence}`}`;
}

function clampIndent(value) {
  const parsed = Number.isFinite(value) ? Math.round(value) : 0;
  return Math.max(0, Math.min(3, parsed));
}

export function createBlock(type = "paragraph", text = "", options = {}) {
  const safeType = BLOCK_TYPE_SET.has(type) ? type : "paragraph";
  return {
    id: options.id || nextBlockId(),
    type: safeType,
    text: String(text ?? ""),
    html: typeof options.html === "string" ? options.html : "",
    checked: safeType === "todo" ? Boolean(options.checked) : false,
    indent: clampIndent(options.indent),
  };
}

export function normalizeBlocks(blocks) {
  if (!Array.isArray(blocks)) return [];
  const ids = new Set();
  return blocks.map((block) => {
    const id = typeof block?.id === "string" && block.id && !ids.has(block.id)
      ? block.id
      : nextBlockId();
    ids.add(id);
    return createBlock(block?.type, block?.text, {
      id,
      html: block?.html,
      checked: block?.checked,
      indent: block?.indent,
    });
  });
}

function proseBlocks(text) {
  if (typeof text !== "string" || !text.trim()) return [];
  return text
    .replace(/\r/g, "")
    .split(/\n{2,}/)
    .map((paragraph) => createBlock("paragraph", paragraph.trim()));
}

/** Convert legacy title/body/tasks content into the ordered block document. */
export function documentFromItem(item = {}) {
  const title = typeof item.title === "string" ? item.title : "";
  const persisted = normalizeBlocks(item.blocks);
  if (persisted.length) return { title, blocks: persisted };

  const blocks = [];
  if (typeof item.subtitle === "string" && item.subtitle.trim()) {
    blocks.push(createBlock("paragraph", item.subtitle.trim()));
  }
  if (Array.isArray(item.tasks)) {
    for (const task of item.tasks) {
      blocks.push(createBlock("todo", task?.text || "", {
        checked: task?.done,
      }));
    }
  }
  blocks.push(...proseBlocks(item.body || item.text || item.excerpt || ""));
  if (!blocks.length) blocks.push(createBlock());
  return { title, blocks };
}

export function serializableBlocks(blocks) {
  return normalizeBlocks(blocks).map((block) => ({
    id: block.id,
    type: block.type,
    text: block.text,
    ...(block.html ? { html: block.html } : {}),
    ...(block.type === "todo" ? { checked: block.checked } : {}),
    ...(block.indent ? { indent: block.indent } : {}),
  }));
}

function blockPreviewLine(block, number) {
  if (!block.text && block.type !== "divider") return "";
  if (block.type === "bulleted") return `• ${block.text}`;
  if (block.type === "numbered") return `${number}. ${block.text}`;
  if (block.type === "quote") return `> ${block.text}`;
  if (block.type === "code") return `\`\`\`\n${block.text}\n\`\`\``;
  if (block.type === "divider") return "---";
  return block.text;
}

/** Keep the existing canvas previews compatible while blocks are canonical. */
export function contentPatchFromDocument(title, blocks) {
  const normalized = normalizeBlocks(blocks);
  const tasks = normalized
    .filter((block) => block.type === "todo")
    .map((block) => ({ text: block.text, done: block.checked }));
  let numbered = 0;
  const body = normalized
    .filter((block) => block.type !== "todo")
    .map((block) => {
      numbered = block.type === "numbered" ? numbered + 1 : 0;
      return blockPreviewLine(block, numbered);
    })
    .filter(Boolean)
    .join("\n\n");

  return {
    title: String(title ?? ""),
    blocks: serializableBlocks(normalized),
    tasks,
    body,
  };
}

export function continuationType(block) {
  if (["bulleted", "numbered", "todo"].includes(block.type)) return block.type;
  return "paragraph";
}

export function splitBlockAt(block, offset) {
  const position = Math.max(0, Math.min(block.text.length, offset));
  const left = { ...block, text: block.text.slice(0, position), html: "" };
  const right = createBlock(continuationType(block), block.text.slice(position), {
    checked: false,
    indent: block.indent,
  });
  return [left, right];
}

/**
 * Delete one continuous text range that crosses block boundaries.
 *
 * The surviving block keeps the first block's semantics while its unselected
 * prefix is joined to the last block's unselected suffix. Covered blocks are
 * removed as one document transaction, matching native multi-paragraph text
 * deletion instead of letting one contenteditable mutate in isolation.
 */
export function deleteBlockTextRange(blocks, start, end) {
  if (!Array.isArray(blocks) || !start?.id || !end?.id || start.id === end.id) return null;
  let startIndex = blocks.findIndex((block) => block.id === start.id);
  let endIndex = blocks.findIndex((block) => block.id === end.id);
  if (startIndex < 0 || endIndex < 0) return null;

  let first = start;
  let last = end;
  if (startIndex > endIndex) {
    [startIndex, endIndex] = [endIndex, startIndex];
    [first, last] = [last, first];
  }

  const firstBlock = blocks[startIndex];
  const lastBlock = blocks[endIndex];
  if (firstBlock.type === "divider" || lastBlock.type === "divider") return null;
  const firstOffset = Math.max(0, Math.min(firstBlock.text.length, first.offset ?? 0));
  const lastOffset = Math.max(0, Math.min(lastBlock.text.length, last.offset ?? 0));
  const prefix = firstBlock.text.slice(0, firstOffset);
  const suffix = lastBlock.text.slice(lastOffset);
  const merged = {
    ...firstBlock,
    text: prefix + suffix,
    html: "",
  };

  return {
    blocks: [
      ...blocks.slice(0, startIndex),
      merged,
      ...blocks.slice(endIndex + 1),
    ],
    focus: { id: merged.id, position: prefix.length },
  };
}

/** Title Enter always lands in a real paragraph block, never a title newline. */
export function ensureTitleParagraph(blocks) {
  const normalized = normalizeBlocks(blocks);
  if (normalized[0]?.type === "paragraph") {
    return { blocks: normalized, focusId: normalized[0].id, inserted: false };
  }
  const paragraph = createBlock();
  return {
    blocks: [paragraph, ...normalized],
    focusId: paragraph.id,
    inserted: true,
  };
}

export function markdownShortcut(text) {
  const shortcuts = new Map([
    ["# ", { type: "heading1" }],
    ["## ", { type: "heading2" }],
    ["### ", { type: "heading3" }],
    ["- ", { type: "bulleted" }],
    ["* ", { type: "bulleted" }],
    ["+ ", { type: "bulleted" }],
    ["1. ", { type: "numbered" }],
    ["> ", { type: "quote" }],
    ["[] ", { type: "todo", checked: false }],
    ["[ ] ", { type: "todo", checked: false }],
    ["[x] ", { type: "todo", checked: true }],
    ["[X] ", { type: "todo", checked: true }],
    ["- [ ] ", { type: "todo", checked: false }],
    ["- [x] ", { type: "todo", checked: true }],
    ["```", { type: "code" }],
  ]);
  return shortcuts.get(text) || null;
}

function blockFromMarkdownLine(line, inCode) {
  if (inCode) return createBlock("code", line);
  if (/^###\s/.test(line)) return createBlock("heading3", line.replace(/^###\s/, ""));
  if (/^##\s/.test(line)) return createBlock("heading2", line.replace(/^##\s/, ""));
  if (/^#\s/.test(line)) return createBlock("heading1", line.replace(/^#\s/, ""));
  const todo = line.match(/^[-*]?\s*\[([ xX])\]\s+(.*)$/);
  if (todo) return createBlock("todo", todo[2], { checked: todo[1].toLowerCase() === "x" });
  if (/^[-*+]\s/.test(line)) return createBlock("bulleted", line.replace(/^[-*+]\s/, ""));
  if (/^\d+\.\s/.test(line)) return createBlock("numbered", line.replace(/^\d+\.\s/, ""));
  if (/^>\s?/.test(line)) return createBlock("quote", line.replace(/^>\s?/, ""));
  if (/^\s*(---|___|\*\*\*)\s*$/.test(line)) return createBlock("divider");
  return createBlock("paragraph", line);
}

export function parseMarkdownText(source) {
  const lines = String(source ?? "").replace(/\r/g, "").split("\n");
  const blocks = [];
  let inCode = false;
  let codeLines = [];

  for (const line of lines) {
    if (/^```/.test(line)) {
      if (inCode) {
        blocks.push(createBlock("code", codeLines.join("\n")));
        codeLines = [];
      }
      inCode = !inCode;
      continue;
    }
    if (inCode) codeLines.push(line);
    else blocks.push(blockFromMarkdownLine(line, false));
  }
  if (inCode || codeLines.length) blocks.push(createBlock("code", codeLines.join("\n")));
  return blocks.length ? blocks : [createBlock()];
}

export function moveBlock(blocks, sourceId, targetId, after = false) {
  if (sourceId === targetId) return blocks;
  const source = blocks.find((block) => block.id === sourceId);
  const targetIndex = blocks.findIndex((block) => block.id === targetId);
  if (!source || targetIndex < 0) return blocks;
  const without = blocks.filter((block) => block.id !== sourceId);
  const nextTargetIndex = without.findIndex((block) => block.id === targetId);
  const insertAt = nextTargetIndex + (after ? 1 : 0);
  return [
    ...without.slice(0, insertAt),
    source,
    ...without.slice(insertAt),
  ];
}
