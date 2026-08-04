import {
  Check,
  CheckSquare,
  CodeBlock,
  DotsSixVertical,
  LinkSimple,
  ListBullets,
  ListNumbers,
  Minus,
  Plus,
  Quotes,
  TextB,
  TextHOne,
  TextHThree,
  TextHTwo,
  TextItalic,
  TextStrikethrough,
  TextT,
  TextUnderline,
  Trash,
} from "@phosphor-icons/react";
import {
  useEffect,
  useLayoutEffect,
  useMemo,
  useRef,
  useState,
} from "react";
import {
  contentPatchFromDocument,
  createBlock,
  deleteBlockTextRange,
  documentFromItem,
  ensureTitleParagraph,
  markdownShortcut,
  moveBlock,
  parseMarkdownText,
  splitBlockAt,
} from "../editor/blockModel.js";
import { edgeScrollVelocity, revealDelta } from "../editor/textSelection.js";

const BLOCK_COMMANDS = [
  { id: "paragraph", type: "paragraph", label: "Text", hint: "Plain text block", Icon: TextT, keywords: "paragraph plain" },
  { id: "heading1", type: "heading1", label: "Heading 1", hint: "Large section heading", Icon: TextHOne, keywords: "h1 title" },
  { id: "heading2", type: "heading2", label: "Heading 2", hint: "Medium section heading", Icon: TextHTwo, keywords: "h2 subtitle" },
  { id: "heading3", type: "heading3", label: "Heading 3", hint: "Small section heading", Icon: TextHThree, keywords: "h3" },
  { id: "bulleted", type: "bulleted", label: "Bulleted list", hint: "Create a simple list", Icon: ListBullets, keywords: "bullet unordered" },
  { id: "numbered", type: "numbered", label: "Numbered list", hint: "Create an ordered list", Icon: ListNumbers, keywords: "number ordered" },
  { id: "todo", type: "todo", label: "To-do list", hint: "Track a task", Icon: CheckSquare, keywords: "task checkbox check" },
  { id: "quote", type: "quote", label: "Quote", hint: "Capture a quotation", Icon: Quotes, keywords: "blockquote" },
  { id: "code", type: "code", label: "Code", hint: "Write a code snippet", Icon: CodeBlock, keywords: "pre monospace" },
  { id: "divider", type: "divider", label: "Divider", hint: "Separate sections", Icon: Minus, keywords: "line rule separator" },
  { id: "delete", action: "delete", label: "Delete", hint: "Remove this block", Icon: Trash, keywords: "remove trash" },
];

function editorText(node) {
  return node?.innerText?.replace(/\r/g, "") || "";
}

function caretOffset(element) {
  const selection = window.getSelection();
  if (!selection?.rangeCount || !element.contains(selection.anchorNode)) {
    return editorText(element).length;
  }
  const range = selection.getRangeAt(0).cloneRange();
  range.selectNodeContents(element);
  range.setEnd(selection.anchorNode, selection.anchorOffset);
  return range.toString().length;
}

function selectionCollapsedIn(element) {
  const selection = window.getSelection();
  return Boolean(selection?.isCollapsed && element.contains(selection.anchorNode));
}

function pointForTextOffset(element, requestedOffset) {
  const walker = document.createTreeWalker(element, NodeFilter.SHOW_TEXT);
  let offset = Math.max(0, requestedOffset);
  let node = walker.nextNode();
  while (node) {
    if (offset <= node.textContent.length) return { node, offset };
    offset -= node.textContent.length;
    node = walker.nextNode();
  }
  return { node: element, offset: element.childNodes.length };
}

function placeCaret(element, position = "end") {
  element.focus({ preventScroll: true });
  if (!element.isContentEditable) return;
  const textLength = editorText(element).length;
  const numericPosition = position === "start"
    ? 0
    : position === "end"
      ? textLength
      : Math.max(0, Math.min(textLength, position));
  const point = pointForTextOffset(element, numericPosition);
  const range = document.createRange();
  range.setStart(point.node, point.offset);
  range.collapse(true);
  const selection = window.getSelection();
  selection.removeAllRanges();
  selection.addRange(range);
  revealEditorElement(element);
}

function revealEditorElement(element) {
  const scroller = element?.closest?.(".item-document, .item-note, .item-web");
  if (!scroller) return;
  const scrollerRect = scroller.getBoundingClientRect();
  const visible = {
    top: Math.max(0, scrollerRect.top),
    bottom: Math.min(window.innerHeight, scrollerRect.bottom),
  };
  const delta = revealDelta(element.getBoundingClientRect(), visible);
  if (!delta) return;
  const scaleY = Math.max(
    scroller.offsetHeight ? scrollerRect.height / scroller.offsetHeight : 1,
    0.001,
  );
  scroller.scrollTop += delta / scaleY;
}

function selectionElement(node) {
  if (!node) return null;
  return node.nodeType === Node.ELEMENT_NODE ? node : node.parentElement;
}

function selectedTextClientRects(range, root) {
  const rects = [];
  const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
  let node = walker.nextNode();
  while (node) {
    const host = selectionElement(node)?.closest?.(".notion-page-title, .notion-block-content");
    let intersects = false;
    try {
      intersects = Boolean(node.textContent?.length && host && root.contains(host) && range.intersectsNode(node));
    } catch {
      intersects = false;
    }
    if (intersects) {
      const segment = document.createRange();
      segment.selectNodeContents(node);
      if (range.startContainer === node) {
        segment.setStart(node, Math.min(range.startOffset, node.textContent.length));
      }
      if (range.endContainer === node) {
        segment.setEnd(node, Math.min(range.endOffset, node.textContent.length));
      }
      if (!segment.collapsed) rects.push(...segment.getClientRects());
    }
    node = walker.nextNode();
  }
  return rects;
}

function blockPointForBoundary(root, node, offset) {
  if (!node || !root.contains(node)) return null;
  const host = selectionElement(node)?.closest?.(".notion-block-content");
  const row = host?.closest?.("[data-editor-block]");
  if (!host || !row || !root.contains(row)) return null;
  const prefix = document.createRange();
  try {
    prefix.selectNodeContents(host);
    prefix.setEnd(node, offset);
  } catch {
    return null;
  }
  return {
    id: row.dataset.blockId,
    offset: prefix.toString().length,
    host,
  };
}

function crossBlockSelection(root) {
  const selection = window.getSelection();
  if (!selection?.rangeCount || selection.isCollapsed) return null;
  const range = selection.getRangeAt(0);
  const start = blockPointForBoundary(root, range.startContainer, range.startOffset);
  const end = blockPointForBoundary(root, range.endContainer, range.endOffset);
  if (!start || !end || start.id === end.id) return null;
  return { start, end };
}

function caretPointFromClient(root, clientX, clientY) {
  const pointAt = (x, y) => {
    const position = document.caretPositionFromPoint?.(x, y);
    if (position) return { node: position.offsetNode, offset: position.offset };
    const range = document.caretRangeFromPoint?.(x, y);
    return range ? { node: range.startContainer, offset: range.startOffset } : null;
  };
  const belongsToEditor = (point, host = null) => {
    if (!point?.node || !root.contains(point.node)) return false;
    const pointHost = selectionElement(point.node)?.closest?.(".notion-page-title, .notion-block-content");
    return Boolean(pointHost && (!host || pointHost === host));
  };

  const direct = pointAt(clientX, clientY);
  if (belongsToEditor(direct)) return direct;

  const hosts = [...root.querySelectorAll(".notion-page-title, .notion-block-content")];
  let nearest = null;
  let nearestDistance = Number.POSITIVE_INFINITY;
  for (const host of hosts) {
    const rect = host.getBoundingClientRect();
    const distance = clientY < rect.top
      ? rect.top - clientY
      : clientY > rect.bottom
        ? clientY - rect.bottom
        : 0;
    if (distance < nearestDistance) {
      nearest = host;
      nearestDistance = distance;
    }
  }
  if (!nearest) return null;
  const bounds = nearest.getBoundingClientRect();
  const x = Math.max(bounds.left + 1, Math.min(bounds.right - 1, clientX));
  const y = Math.max(bounds.top + 1, Math.min(bounds.bottom - 1, clientY));
  const clamped = pointAt(x, y);
  if (belongsToEditor(clamped, nearest)) return clamped;
  return pointForTextOffset(nearest, clientX <= bounds.left + bounds.width / 2 ? 0 : editorText(nearest).length);
}

function setDocumentSelection(anchor, focus) {
  if (!anchor?.node || !focus?.node) return false;
  const selection = window.getSelection();
  if (!selection) return false;
  try {
    if (typeof selection.setBaseAndExtent === "function") {
      selection.setBaseAndExtent(anchor.node, anchor.offset, focus.node, focus.offset);
    } else {
      const range = document.createRange();
      range.setStart(anchor.node, anchor.offset);
      range.collapse(true);
      selection.removeAllRanges();
      selection.addRange(range);
      selection.extend(focus.node, focus.offset);
    }
    return true;
  } catch {
    return false;
  }
}

function caretRectForRange(range, host) {
  const direct = [...range.getClientRects()].find((rect) => rect.height > 0);
  if (direct) return direct;

  const container = range.startContainer;
  if (container?.nodeType === Node.TEXT_NODE && container.textContent?.length) {
    const probe = range.cloneRange();
    if (range.startOffset > 0) {
      probe.setStart(container, range.startOffset - 1);
      probe.setEnd(container, range.startOffset);
      const rect = [...probe.getClientRects()].at(-1);
      if (rect) return { left: rect.right, top: rect.top, right: rect.right, bottom: rect.bottom, width: 0, height: rect.height };
    }
    if (range.startOffset < container.textContent.length) {
      probe.setStart(container, range.startOffset);
      probe.setEnd(container, range.startOffset + 1);
      const rect = [...probe.getClientRects()][0];
      if (rect) return { left: rect.left, top: rect.top, right: rect.left, bottom: rect.bottom, width: 0, height: rect.height };
    }
  }

  const hostRect = host?.getBoundingClientRect();
  if (!hostRect) return null;
  const style = getComputedStyle(host);
  const lineHeight = Number.parseFloat(style.lineHeight) || Number.parseFloat(style.fontSize) * 1.3 || 20;
  const paddingLeft = Number.parseFloat(style.paddingLeft) || 0;
  const paddingTop = Number.parseFloat(style.paddingTop) || 0;
  return {
    left: hostRect.left + paddingLeft,
    top: hostRect.top + paddingTop,
    right: hostRect.left + paddingLeft,
    bottom: hostRect.top + paddingTop + lineHeight,
    width: 0,
    height: lineHeight,
  };
}

function sanitizeInlineHtml(html) {
  if (typeof document === "undefined") return "";
  const root = document.createElement("div");
  root.innerHTML = html;
  const allowed = new Set(["BR", "B", "STRONG", "I", "EM", "U", "S", "DEL", "CODE", "A"]);

  const clean = (node) => {
    for (const child of [...node.childNodes]) {
      if (child.nodeType !== Node.ELEMENT_NODE) continue;
      clean(child);
      if (!allowed.has(child.tagName)) {
        const fragment = document.createDocumentFragment();
        if (["DIV", "P"].includes(child.tagName) && child.previousSibling) {
          fragment.append(document.createElement("br"));
        }
        while (child.firstChild) fragment.append(child.firstChild);
        child.replaceWith(fragment);
        continue;
      }
      for (const attribute of [...child.attributes]) {
        if (child.tagName !== "A" || attribute.name !== "href") {
          child.removeAttribute(attribute.name);
        }
      }
      if (child.tagName === "A") {
        const href = child.getAttribute("href") || "";
        if (!/^(https?:|mailto:)/i.test(href)) child.removeAttribute("href");
        else {
          child.setAttribute("target", "_blank");
          child.setAttribute("rel", "noreferrer");
        }
      }
    }
  };
  clean(root);
  return root.innerHTML === root.textContent ? "" : root.innerHTML;
}

function commandMatches(command, query) {
  const normalized = query.trim().toLowerCase();
  if (!normalized) return true;
  return `${command.label} ${command.keywords}`.toLowerCase().includes(normalized);
}

function numberedValue(blocks, index) {
  const block = blocks[index];
  if (block.type !== "numbered") return null;
  let value = 1;
  for (let cursor = index - 1; cursor >= 0; cursor -= 1) {
    const previous = blocks[cursor];
    if (previous.type !== "numbered" || previous.indent !== block.indent) break;
    value += 1;
  }
  return value;
}

export function NotionBlockEditor({ item, onChange, interactive = false }) {
  const initialDocument = useMemo(() => documentFromItem(item), [item.id]);
  const [title, setTitle] = useState(initialDocument.title);
  const [blocks, setBlocks] = useState(initialDocument.blocks);
  const [commandMenu, setCommandMenu] = useState(null);
  const [formatBar, setFormatBar] = useState(null);
  const itemIdRef = useRef(item.id);
  const titleRef = useRef(initialDocument.title);
  const blocksRef = useRef(initialDocument.blocks);
  const titleEditorRef = useRef(null);
  const blockRefs = useRef(new Map());
  const rootRef = useRef(null);
  const pendingFocusRef = useRef(null);
  const commitTimerRef = useRef(null);
  const onChangeRef = useRef(onChange);
  const draggedBlockRef = useRef(null);
  const commandMenuRef = useRef(null);
  const selectionRectsRef = useRef(null);
  const customCaretRef = useRef(null);
  const customCaretStemRef = useRef(null);
  const selectionVisualFrameRef = useRef(null);
  const textSelectionFrameRef = useRef(null);
  const textSelectionGestureRef = useRef(null);
  const instantCaretUntilRef = useRef(0);
  const composingRef = useRef(false);

  onChangeRef.current = onChange;
  blocksRef.current = blocksRef.current || blocks;

  const emitChange = () => {
    clearTimeout(commitTimerRef.current);
    commitTimerRef.current = null;
    onChangeRef.current?.(contentPatchFromDocument(
      titleRef.current,
      blocksRef.current,
    ));
  };

  const scheduleChange = (delay = 140) => {
    clearTimeout(commitTimerRef.current);
    commitTimerRef.current = setTimeout(emitChange, delay);
  };

  useEffect(() => {
    if (itemIdRef.current === item.id) return;
    clearTimeout(commitTimerRef.current);
    const next = documentFromItem(item);
    itemIdRef.current = item.id;
    titleRef.current = next.title;
    blocksRef.current = next.blocks;
    setTitle(next.title);
    setBlocks(next.blocks);
    setCommandMenu(null);
    setFormatBar(null);
  }, [item, item.id]);

  useEffect(() => () => clearTimeout(commitTimerRef.current), []);

  useLayoutEffect(() => {
    const pending = pendingFocusRef.current;
    if (!pending) return;
    const editor = pending.id === "title"
      ? titleEditorRef.current
      : blockRefs.current.get(pending.id);
    if (!editor) return;
    pendingFocusRef.current = null;
    placeCaret(editor, pending.position);
  }, [blocks]);

  useEffect(() => {
    if (!interactive) {
      setFormatBar(null);
      return undefined;
    }
    const updateFormatBar = () => {
      const selection = window.getSelection();
      const root = rootRef.current;
      if (!root || textSelectionGestureRef.current?.dragging || !selection?.rangeCount || selection.isCollapsed) {
        setFormatBar(null);
        return;
      }
      const anchor = selectionElement(selection.anchorNode);
      const focus = selectionElement(selection.focusNode);
      const anchorBlock = anchor?.closest?.("[data-editor-block]");
      const focusBlock = focus?.closest?.("[data-editor-block]");
      if (!anchorBlock || !focusBlock || anchorBlock !== focusBlock || !root.contains(anchorBlock)) {
        setFormatBar(null);
        return;
      }
      const selectionRect = selection.getRangeAt(0).getBoundingClientRect();
      const rootRect = root.getBoundingClientRect();
      const scaleX = root.offsetWidth ? rootRect.width / root.offsetWidth : 1;
      const scaleY = root.offsetHeight ? rootRect.height / root.offsetHeight : scaleX;
      setFormatBar({
        left: (selectionRect.left - rootRect.left + selectionRect.width / 2) / Math.max(scaleX, 0.001),
        top: (selectionRect.top - rootRect.top) / Math.max(scaleY, 0.001),
        blockId: anchorBlock.dataset.blockId,
      });
    };
    document.addEventListener("selectionchange", updateFormatBar);
    return () => document.removeEventListener("selectionchange", updateFormatBar);
  }, [interactive]);

  useEffect(() => {
    const root = rootRef.current;
    const caret = customCaretRef.current;
    const caretStem = customCaretStemRef.current;
    const selectionLayer = selectionRectsRef.current;
    if (!root || !caret || !selectionLayer) return undefined;

    const clearVisuals = () => {
      caret.classList.remove("is-visible", "is-animated");
      selectionLayer.replaceChildren();
      root.classList.remove("has-custom-caret", "has-custom-selection", "is-composing");
    };

    if (!interactive) {
      clearVisuals();
      return undefined;
    }

    const nativeVisualsRequired = window.matchMedia?.("(pointer: coarse)").matches
      || window.matchMedia?.("(forced-colors: active)").matches;
    if (nativeVisualsRequired) {
      clearVisuals();
      return undefined;
    }

    const hideCaret = () => {
      caret.classList.remove("is-visible", "is-animated");
      root.classList.remove("has-custom-caret");
    };

    const updateVisuals = () => {
      selectionVisualFrameRef.current = null;
      const selection = window.getSelection();
      if (composingRef.current || !selection?.rangeCount) {
        clearVisuals();
        if (composingRef.current) root.classList.add("is-composing");
        return;
      }

      const anchor = selectionElement(selection.anchorNode);
      const focus = selectionElement(selection.focusNode);
      if (!anchor || (!root.contains(anchor) && !root.contains(focus))) {
        clearVisuals();
        return;
      }

      const range = selection.getRangeAt(0);
      const rootRect = root.getBoundingClientRect();
      const scaleX = Math.max(root.offsetWidth ? rootRect.width / root.offsetWidth : 1, 0.001);
      const scaleY = Math.max(root.offsetHeight ? rootRect.height / root.offsetHeight : scaleX, 0.001);

      if (selection.isCollapsed) {
        selectionLayer.replaceChildren();
        root.classList.remove("has-custom-selection");
        if (!root.contains(document.activeElement)) {
          hideCaret();
          return;
        }
        const host = anchor.closest?.(".notion-page-title, .notion-block-content");
        const measured = host ? caretRectForRange(range, host) : null;
        if (!measured) {
          hideCaret();
          return;
        }
        const x = (measured.left - rootRect.left) / scaleX;
        const y = (measured.top - rootRect.top) / scaleY;
        const height = Math.max(12, measured.height / scaleY);
        const shouldAnimate = performance.now() > instantCaretUntilRef.current;
        caret.classList.toggle("is-animated", shouldAnimate);
        caret.style.width = `${1.6 / scaleX}px`;
        caret.style.height = `${height}px`;
        caret.style.transform = `translate3d(${x}px, ${y}px, 0)`;
        caret.classList.add("is-visible");
        root.classList.add("has-custom-caret");
        if (caretStem) {
          caretStem.style.animation = "none";
          void caretStem.offsetWidth;
          caretStem.style.animation = "";
        }
        return;
      }

      hideCaret();
      const fragment = document.createDocumentFragment();
      let rectCount = 0;
      for (const rect of selectedTextClientRects(range, root)) {
        const left = Math.max(rect.left, rootRect.left);
        const top = Math.max(rect.top, rootRect.top);
        const right = Math.min(rect.right, rootRect.right);
        const bottom = Math.min(rect.bottom, rootRect.bottom);
        if (right - left < 0.5 || bottom - top < 1) continue;
        const highlight = document.createElement("span");
        highlight.className = "notion-text-selection-rect";
        highlight.style.left = `${(left - rootRect.left) / scaleX}px`;
        highlight.style.top = `${(top - rootRect.top) / scaleY}px`;
        highlight.style.width = `${(right - left) / scaleX}px`;
        highlight.style.height = `${(bottom - top) / scaleY}px`;
        fragment.append(highlight);
        rectCount += 1;
      }
      selectionLayer.replaceChildren(fragment);
      root.classList.toggle("has-custom-selection", rectCount > 0);
    };

    const scheduleVisualUpdate = () => {
      if (selectionVisualFrameRef.current !== null) return;
      selectionVisualFrameRef.current = requestAnimationFrame(updateVisuals);
    };
    const markTyping = () => {
      instantCaretUntilRef.current = performance.now() + 90;
      scheduleVisualUpdate();
    };
    const beginComposition = () => {
      composingRef.current = true;
      clearVisuals();
      root.classList.add("is-composing");
    };
    const endComposition = () => {
      composingRef.current = false;
      root.classList.remove("is-composing");
      instantCaretUntilRef.current = performance.now() + 90;
      scheduleVisualUpdate();
    };
    const scrollHost = root.closest(".item-document, .item-note, .item-web");
    const observer = typeof ResizeObserver === "undefined" ? null : new ResizeObserver(scheduleVisualUpdate);
    observer?.observe(root);
    document.addEventListener("selectionchange", scheduleVisualUpdate);
    root.addEventListener("input", markTyping, true);
    root.addEventListener("keyup", scheduleVisualUpdate, true);
    root.addEventListener("pointerup", scheduleVisualUpdate, true);
    root.addEventListener("focusin", scheduleVisualUpdate, true);
    root.addEventListener("focusout", scheduleVisualUpdate, true);
    root.addEventListener("compositionstart", beginComposition, true);
    root.addEventListener("compositionend", endComposition, true);
    scrollHost?.addEventListener("scroll", scheduleVisualUpdate, { passive: true });
    window.addEventListener("resize", scheduleVisualUpdate, { passive: true });
    scheduleVisualUpdate();

    return () => {
      if (selectionVisualFrameRef.current !== null) cancelAnimationFrame(selectionVisualFrameRef.current);
      selectionVisualFrameRef.current = null;
      observer?.disconnect();
      document.removeEventListener("selectionchange", scheduleVisualUpdate);
      root.removeEventListener("input", markTyping, true);
      root.removeEventListener("keyup", scheduleVisualUpdate, true);
      root.removeEventListener("pointerup", scheduleVisualUpdate, true);
      root.removeEventListener("focusin", scheduleVisualUpdate, true);
      root.removeEventListener("focusout", scheduleVisualUpdate, true);
      root.removeEventListener("compositionstart", beginComposition, true);
      root.removeEventListener("compositionend", endComposition, true);
      scrollHost?.removeEventListener("scroll", scheduleVisualUpdate);
      window.removeEventListener("resize", scheduleVisualUpdate);
      clearVisuals();
    };
  }, [interactive, item.id]);

  const commitBlocks = (next, focus = null) => {
    blocksRef.current = next;
    if (focus) pendingFocusRef.current = focus;
    setBlocks(next);
    scheduleChange();
  };

  useEffect(() => {
    const root = rootRef.current;
    const surface = root?.closest(".shared-document-surface");
    const scrollHost = root?.closest(".item-document, .item-note, .item-web");
    if (!interactive || !root || !surface || !scrollHost) return undefined;

    const finishGesture = () => {
      const gesture = textSelectionGestureRef.current;
      if (!gesture) return;
      if (textSelectionFrameRef.current !== null) cancelAnimationFrame(textSelectionFrameRef.current);
      textSelectionFrameRef.current = null;
      textSelectionGestureRef.current = null;
      try { surface.releasePointerCapture(gesture.pointerId); } catch {}
      if (gesture.dragging) {
        requestAnimationFrame(() => document.dispatchEvent(new Event("selectionchange")));
      }
    };

    const updateTextSelection = () => {
      textSelectionFrameRef.current = null;
      const gesture = textSelectionGestureRef.current;
      if (!gesture?.dragging) return;
      const scrollRect = scrollHost.getBoundingClientRect();
      const visibleBounds = {
        top: Math.max(0, scrollRect.top),
        bottom: Math.min(window.innerHeight, scrollRect.bottom),
      };
      const clampedY = Math.max(
        visibleBounds.top + 1,
        Math.min(visibleBounds.bottom - 1, gesture.clientY),
      );
      const focus = caretPointFromClient(root, gesture.clientX, clampedY);
      if (focus) setDocumentSelection(gesture.anchor, focus);

      const velocity = edgeScrollVelocity(gesture.clientY, visibleBounds, {
        edge: 48,
        minimum: 2,
        maximum: 14,
      });
      if (!velocity || scrollHost.scrollHeight <= scrollHost.clientHeight) return;
      const scaleY = Math.max(
        scrollHost.offsetHeight ? scrollRect.height / scrollHost.offsetHeight : 1,
        0.001,
      );
      const before = scrollHost.scrollTop;
      scrollHost.scrollTop = Math.max(0, Math.min(
        scrollHost.scrollHeight - scrollHost.clientHeight,
        before + velocity / scaleY,
      ));
      if (scrollHost.scrollTop !== before) {
        textSelectionFrameRef.current = requestAnimationFrame(updateTextSelection);
      }
    };

    const scheduleTextSelection = () => {
      if (textSelectionFrameRef.current !== null) return;
      textSelectionFrameRef.current = requestAnimationFrame(updateTextSelection);
    };

    const pointerDown = (event) => {
      if (event.button !== 0 || event.pointerType === "touch" || event.detail > 1) return;
      if (event.metaKey || event.ctrlKey || event.altKey || event.shiftKey || composingRef.current) return;
      const target = event.target;
      if (!(target instanceof Element)) return;
      const host = target.closest(".notion-page-title, .notion-block-content");
      if (!host || !root.contains(host)) return;
      const anchor = caretPointFromClient(root, event.clientX, event.clientY);
      if (!anchor) return;
      textSelectionGestureRef.current = {
        pointerId: event.pointerId,
        startClientX: event.clientX,
        startClientY: event.clientY,
        clientX: event.clientX,
        clientY: event.clientY,
        anchor,
        dragging: false,
      };
    };

    const pointerMove = (event) => {
      const gesture = textSelectionGestureRef.current;
      if (!gesture || gesture.pointerId !== event.pointerId) return;
      gesture.clientX = event.clientX;
      gesture.clientY = event.clientY;
      if (!gesture.dragging) {
        const distance = Math.hypot(event.clientX - gesture.startClientX, event.clientY - gesture.startClientY);
        if (distance < 4) return;
        gesture.dragging = true;
        setFormatBar(null);
        try { surface.setPointerCapture(event.pointerId); } catch {}
      }
      event.preventDefault();
      scheduleTextSelection();
    };

    const pointerUp = (event) => {
      const gesture = textSelectionGestureRef.current;
      if (!gesture || gesture.pointerId !== event.pointerId) return;
      if (gesture.dragging) {
        gesture.clientX = event.clientX;
        gesture.clientY = event.clientY;
        if (textSelectionFrameRef.current !== null) cancelAnimationFrame(textSelectionFrameRef.current);
        textSelectionFrameRef.current = null;
        updateTextSelection();
      }
      finishGesture();
    };
    const pointerCancel = (event) => {
      if (textSelectionGestureRef.current?.pointerId !== event.pointerId) return;
      finishGesture();
    };

    surface.addEventListener("pointerdown", pointerDown);
    surface.addEventListener("pointermove", pointerMove, { passive: false });
    surface.addEventListener("pointerup", pointerUp);
    surface.addEventListener("pointercancel", pointerCancel);
    surface.addEventListener("lostpointercapture", pointerCancel);
    return () => {
      finishGesture();
      surface.removeEventListener("pointerdown", pointerDown);
      surface.removeEventListener("pointermove", pointerMove);
      surface.removeEventListener("pointerup", pointerUp);
      surface.removeEventListener("pointercancel", pointerCancel);
      surface.removeEventListener("lostpointercapture", pointerCancel);
    };
  }, [interactive, item.id]);

  const syncBlockNode = (blockId, node) => {
    const text = editorText(node);
    const html = sanitizeInlineHtml(node.innerHTML);
    blocksRef.current = blocksRef.current.map((block) => block.id === blockId
      ? { ...block, text, html }
      : block);
    node.dataset.empty = String(text.length === 0);
    return text;
  };

  const updateBlock = (blockId, patch, focus = null) => {
    const next = blocksRef.current.map((block) => block.id === blockId
      ? { ...block, ...patch }
      : block);
    commitBlocks(next, focus);
  };

  const insertBlockAfter = (blockId, type = "paragraph") => {
    const current = blocksRef.current;
    const index = current.findIndex((block) => block.id === blockId);
    const block = createBlock(type);
    const insertAt = index < 0 ? current.length : index + 1;
    commitBlocks([
      ...current.slice(0, insertAt),
      block,
      ...current.slice(insertAt),
    ], { id: block.id, position: "start" });
    setCommandMenu(null);
  };

  const deleteBlock = (blockId) => {
    const current = blocksRef.current;
    const index = current.findIndex((block) => block.id === blockId);
    if (index < 0) return;
    if (current.length === 1) {
      const replacement = createBlock();
      commitBlocks([replacement], { id: replacement.id, position: "start" });
      setCommandMenu(null);
      return;
    }
    const focusBlock = current[index > 0 ? index - 1 : 1];
    const next = current.filter((block) => block.id !== blockId);
    commitBlocks(next, { id: focusBlock.id, position: index > 0 ? "end" : "start" });
    setCommandMenu(null);
  };

  const applyBlockCommand = (command, blockId) => {
    if (command.action === "delete") {
      deleteBlock(blockId);
      return;
    }
    const node = blockRefs.current.get(blockId);
    const current = blocksRef.current;
    const index = current.findIndex((block) => block.id === blockId);
    if (index < 0) return;
    const fromSlash = commandMenu?.mode === "slash";
    const source = current[index];
    const text = fromSlash ? "" : source.text;
    if (fromSlash && node) node.innerHTML = "";

    if (command.type === "divider") {
      const divider = { ...source, type: "divider", text: "", html: "", checked: false };
      const paragraph = createBlock();
      commitBlocks([
        ...current.slice(0, index),
        divider,
        paragraph,
        ...current.slice(index + 1),
      ], { id: paragraph.id, position: "start" });
    } else {
      updateBlock(blockId, {
        type: command.type,
        text,
        html: fromSlash ? "" : source.html,
        checked: command.type === "todo" ? source.checked : false,
      }, { id: blockId, position: fromSlash ? "start" : "end" });
    }
    setCommandMenu(null);
  };

  const visibleCommands = commandMenu
    ? BLOCK_COMMANDS.filter((command) => commandMatches(command, commandMenu.query))
    : [];

  useLayoutEffect(() => {
    const menu = commandMenuRef.current;
    if (!menu || !commandMenu) return;
    const option = menu.querySelector(`[data-command-index="${commandMenu.selected}"]`);
    if (!option) return;
    const top = option.offsetTop;
    const bottom = top + option.offsetHeight;
    if (top < menu.scrollTop) menu.scrollTop = Math.max(0, top - 6);
    else if (bottom > menu.scrollTop + menu.clientHeight) {
      menu.scrollTop = bottom - menu.clientHeight + 6;
    }
  }, [commandMenu?.blockId, commandMenu?.query, commandMenu?.selected, visibleCommands.length]);

  const handleCommandMenuKey = (blockId, event) => {
    if (!commandMenu || commandMenu.blockId !== blockId || !visibleCommands.length) return false;
    if (event.key === "ArrowDown" || event.key === "ArrowUp") {
      event.preventDefault();
      const delta = event.key === "ArrowDown" ? 1 : -1;
      setCommandMenu((current) => ({
        ...current,
        selected: (current.selected + delta + visibleCommands.length) % visibleCommands.length,
      }));
      return true;
    }
    if (event.key === "Enter") {
      event.preventDefault();
      applyBlockCommand(visibleCommands[commandMenu.selected] || visibleCommands[0], blockId);
      return true;
    }
    if (event.key === "Escape") {
      event.preventDefault();
      setCommandMenu(null);
      return true;
    }
    return false;
  };

  const handleTitleEnter = (event) => {
    if (event.nativeEvent?.isComposing) return;
    event.preventDefault();
    titleRef.current = editorText(event.currentTarget).replace(/\n/g, " ");
    const result = ensureTitleParagraph(blocksRef.current);
    blocksRef.current = result.blocks;
    pendingFocusRef.current = { id: result.focusId, position: "start" };
    if (result.inserted) setBlocks(result.blocks);
    else requestAnimationFrame(() => placeCaret(blockRefs.current.get(result.focusId), "start"));
    scheduleChange();
  };

  const handleBlockEnter = (block, event) => {
    if (event.nativeEvent?.isComposing || event.shiftKey) return;
    if (handleCommandMenuKey(block.id, event)) return;
    if (block.type === "code") return;
    event.preventDefault();
    const node = event.currentTarget;
    const text = syncBlockNode(block.id, node);
    const current = blocksRef.current;
    const index = current.findIndex((entry) => entry.id === block.id);
    if (index < 0) return;

    if (text === "---") {
      const divider = { ...current[index], type: "divider", text: "", html: "" };
      const paragraph = createBlock();
      commitBlocks([
        ...current.slice(0, index),
        divider,
        paragraph,
        ...current.slice(index + 1),
      ], { id: paragraph.id, position: "start" });
      setCommandMenu(null);
      return;
    }

    if (!text && block.type !== "paragraph") {
      updateBlock(block.id, { type: "paragraph", checked: false, html: "" }, {
        id: block.id,
        position: "start",
      });
      setCommandMenu(null);
      return;
    }

    const offset = caretOffset(node);
    const [before, after] = splitBlockAt(current[index], offset);
    commitBlocks([
      ...current.slice(0, index),
      before,
      after,
      ...current.slice(index + 1),
    ], { id: after.id, position: "start" });
    setCommandMenu(null);
  };

  const handleBackspace = (block, event) => {
    const node = event.currentTarget;
    if (!selectionCollapsedIn(node) || caretOffset(node) !== 0) return false;
    const text = syncBlockNode(block.id, node);
    const current = blocksRef.current;
    const index = current.findIndex((entry) => entry.id === block.id);
    if (index < 0) return false;

    if (block.type !== "paragraph") {
      event.preventDefault();
      updateBlock(block.id, { type: "paragraph", checked: false, html: "" }, {
        id: block.id,
        position: "start",
      });
      return true;
    }
    if (index === 0) {
      if (!text && current.length > 1) {
        event.preventDefault();
        commitBlocks(current.slice(1), { id: "title", position: "end" });
        return true;
      }
      if (!text) {
        event.preventDefault();
        pendingFocusRef.current = { id: "title", position: "end" };
        placeCaret(titleEditorRef.current, "end");
        return true;
      }
      return false;
    }

    event.preventDefault();
    const previous = current[index - 1];
    if (previous.type === "divider") {
      commitBlocks(current.filter((entry) => entry.id !== previous.id), {
        id: block.id,
        position: "start",
      });
      return true;
    }
    const previousLength = previous.text.length;
    const merged = { ...previous, text: previous.text + text, html: "" };
    commitBlocks([
      ...current.slice(0, index - 1),
      merged,
      ...current.slice(index + 1),
    ], { id: merged.id, position: previousLength });
    return true;
  };

  const handleForwardDelete = (block, event) => {
    const node = event.currentTarget;
    const text = syncBlockNode(block.id, node);
    if (!selectionCollapsedIn(node) || caretOffset(node) !== text.length) return false;
    const current = blocksRef.current;
    const index = current.findIndex((entry) => entry.id === block.id);
    if (index < 0 || index >= current.length - 1) return false;
    event.preventDefault();
    const nextBlock = current[index + 1];
    if (nextBlock.type === "divider") {
      commitBlocks(current.filter((entry) => entry.id !== nextBlock.id), {
        id: block.id,
        position: "end",
      });
      return true;
    }
    const merged = { ...current[index], text: text + nextBlock.text, html: "" };
    commitBlocks([
      ...current.slice(0, index),
      merged,
      ...current.slice(index + 2),
    ], { id: merged.id, position: text.length });
    return true;
  };

  const handleCrossBlockDeletion = (event) => {
    const points = crossBlockSelection(rootRef.current);
    if (!points) return false;
    syncBlockNode(points.start.id, points.start.host);
    syncBlockNode(points.end.id, points.end.host);
    const result = deleteBlockTextRange(blocksRef.current, points.start, points.end);
    if (!result) return false;

    event.preventDefault();
    event.stopPropagation();
    window.getSelection()?.removeAllRanges();
    setFormatBar(null);
    setCommandMenu(null);
    commitBlocks(result.blocks, result.focus);
    return true;
  };

  const handleArrowNavigation = (block, event) => {
    if (!selectionCollapsedIn(event.currentTarget)) return false;
    const offset = caretOffset(event.currentTarget);
    const textLength = editorText(event.currentTarget).length;
    const current = blocksRef.current;
    const index = current.findIndex((entry) => entry.id === block.id);
    if (event.key === "ArrowUp" && offset === 0) {
      event.preventDefault();
      if (index === 0) placeCaret(titleEditorRef.current, "end");
      else placeCaret(blockRefs.current.get(current[index - 1].id), "end");
      return true;
    }
    if (event.key === "ArrowDown" && offset === textLength && index < current.length - 1) {
      event.preventDefault();
      placeCaret(blockRefs.current.get(current[index + 1].id), "start");
      return true;
    }
    return false;
  };

  const handleBlockKeyDown = (block, event) => {
    if ((event.key === "Backspace" || event.key === "Delete") && handleCrossBlockDeletion(event)) return;
    if (handleCommandMenuKey(block.id, event)) return;
    const commandKey = event.metaKey || event.ctrlKey;
    if (commandKey && ["b", "i", "u"].includes(event.key.toLowerCase())) {
      event.preventDefault();
      document.execCommand({ b: "bold", i: "italic", u: "underline" }[event.key.toLowerCase()]);
      syncBlockNode(block.id, event.currentTarget);
      scheduleChange();
      return;
    }
    if (commandKey && event.shiftKey && event.key.toLowerCase() === "s") {
      event.preventDefault();
      document.execCommand("strikeThrough");
      syncBlockNode(block.id, event.currentTarget);
      scheduleChange();
      return;
    }
    if (event.key === "Enter") handleBlockEnter(block, event);
    else if (event.key === "Backspace") handleBackspace(block, event);
    else if (event.key === "Delete") handleForwardDelete(block, event);
    else if (event.key === "ArrowUp" || event.key === "ArrowDown") handleArrowNavigation(block, event);
    else if (event.key === "Tab") {
      event.preventDefault();
      const nextIndent = Math.max(0, Math.min(3, block.indent + (event.shiftKey ? -1 : 1)));
      updateBlock(block.id, { indent: nextIndent }, {
        id: block.id,
        position: caretOffset(event.currentTarget),
      });
    }
  };

  const handleBlockInput = (block, event) => {
    const text = syncBlockNode(block.id, event.currentTarget);
    const shortcut = markdownShortcut(text);
    if (shortcut && caretOffset(event.currentTarget) === text.length) {
      event.currentTarget.innerHTML = "";
      updateBlock(block.id, {
        type: shortcut.type,
        text: "",
        html: "",
        checked: Boolean(shortcut.checked),
      }, { id: block.id, position: "start" });
      setCommandMenu(null);
      return;
    }
    if (text.startsWith("/")) {
      setCommandMenu({ blockId: block.id, mode: "slash", query: text.slice(1), selected: 0 });
    } else if (commandMenu?.blockId === block.id && commandMenu.mode === "slash") {
      setCommandMenu(null);
    }
    scheduleChange();
  };

  const handlePaste = (block, event) => {
    const pasted = event.clipboardData.getData("text/plain").replace(/\r/g, "");
    event.preventDefault();
    if (!pasted.includes("\n")) {
      document.execCommand("insertText", false, pasted);
      syncBlockNode(block.id, event.currentTarget);
      scheduleChange();
      return;
    }

    const node = event.currentTarget;
    const currentText = syncBlockNode(block.id, node);
    const offset = caretOffset(node);
    const parsed = parseMarkdownText(pasted);
    const current = blocksRef.current;
    const index = current.findIndex((entry) => entry.id === block.id);
    const before = currentText.slice(0, offset);
    const after = currentText.slice(offset);
    const first = {
      ...parsed[0],
      id: block.id,
      type: before ? block.type : parsed[0].type,
      text: before + parsed[0].text,
    };
    const inserted = [first, ...parsed.slice(1)];
    const last = inserted[inserted.length - 1];
    inserted[inserted.length - 1] = { ...last, text: last.text + after };
    commitBlocks([
      ...current.slice(0, index),
      ...inserted,
      ...current.slice(index + 1),
    ], { id: last.id, position: last.text.length });
  };

  const executeInlineFormat = (command, value = null) => {
    document.execCommand(command, false, value);
    const blockId = formatBar?.blockId;
    const node = blockId ? blockRefs.current.get(blockId) : null;
    if (node) syncBlockNode(blockId, node);
    scheduleChange();
  };

  const inlineButton = (label, Icon, command, value = null) => (
    <button
      type="button"
      aria-label={label}
      onPointerDown={(event) => {
        event.preventDefault();
        executeInlineFormat(command, value);
      }}
    >
      <Icon size={15} weight="bold" />
    </button>
  );

  return (
    <div ref={rootRef} className="notion-editor" data-item-id={item.id}>
      <div className="notion-selection-layer" aria-hidden="true">
        <div ref={selectionRectsRef} className="notion-text-selection-layer" />
        <span ref={customCaretRef} className="notion-custom-caret"><span ref={customCaretStemRef} /></span>
      </div>
      <div
        ref={titleEditorRef}
        className="notion-page-title"
        contentEditable={interactive}
        suppressContentEditableWarning
        role="textbox"
        aria-label="Page title"
        aria-multiline="false"
        data-placeholder="Untitled"
        spellCheck="true"
        onInput={(event) => {
          titleRef.current = editorText(event.currentTarget).replace(/\n/g, " ");
          scheduleChange();
        }}
        onBlur={(event) => {
          titleRef.current = editorText(event.currentTarget).replace(/\n/g, " ");
          emitChange();
        }}
        onKeyDown={(event) => {
          if (event.key === "Enter") handleTitleEnter(event);
          else if (event.key === "ArrowDown" && blocksRef.current[0]) {
            event.preventDefault();
            placeCaret(blockRefs.current.get(blocksRef.current[0].id), "start");
          }
        }}
        onBeforeInput={(event) => {
          // iOS Safari does not consistently dispatch a useful keydown for the
          // software keyboard's return key. beforeinput is the reliable editing
          // contract there, so intercept the paragraph insertion and perform
          // the same title -> first block transition used on desktop.
          if (event.nativeEvent.inputType === "insertParagraph") {
            handleTitleEnter(event);
          }
        }}
        onPaste={(event) => {
          event.preventDefault();
          document.execCommand("insertText", false, event.clipboardData.getData("text/plain").replace(/\s*\n\s*/g, " "));
        }}
      >
        {title}
      </div>

      <div className="notion-block-list" role="group" aria-label="Page content">
        {blocks.map((block, index) => {
          const number = numberedValue(blocks, index);
          const menuOpen = commandMenu?.blockId === block.id;
          const content = block.html
            ? { dangerouslySetInnerHTML: { __html: block.html } }
            : { children: block.text };
          return (
            <div
              key={block.id}
              className={`notion-block-row notion-block-${block.type} ${menuOpen ? "has-menu" : ""}`}
              data-editor-block
              data-block-id={block.id}
              style={{ "--block-indent": block.indent }}
              onDragOver={(event) => {
                if (!draggedBlockRef.current) return;
                event.preventDefault();
              }}
              onDrop={(event) => {
                event.preventDefault();
                const sourceId = draggedBlockRef.current;
                draggedBlockRef.current = null;
                if (!sourceId) return;
                const bounds = event.currentTarget.getBoundingClientRect();
                const after = event.clientY > bounds.top + bounds.height / 2;
                commitBlocks(moveBlock(blocksRef.current, sourceId, block.id, after));
              }}
            >
              <div className="notion-block-gutter" contentEditable={false}>
                <button
                  type="button"
                  className="notion-block-add"
                  aria-label="Add block"
                  onClick={() => insertBlockAfter(block.id)}
                >
                  <Plus size={14} />
                </button>
                <button
                  type="button"
                  className="notion-block-handle"
                  aria-label="Block menu and drag handle"
                  draggable
                  onDragStart={(event) => {
                    draggedBlockRef.current = block.id;
                    event.dataTransfer.effectAllowed = "move";
                    event.dataTransfer.setData("text/plain", block.id);
                  }}
                  onDragEnd={() => { draggedBlockRef.current = null; }}
                  onClick={() => setCommandMenu({
                    blockId: block.id,
                    mode: "block",
                    query: "",
                    selected: 0,
                  })}
                >
                  <DotsSixVertical size={14} weight="bold" />
                </button>
              </div>

              {block.type === "todo" && (
                <button
                  type="button"
                  className={`notion-todo-check ${block.checked ? "is-checked" : ""}`}
                  role="checkbox"
                  aria-checked={block.checked}
                  aria-label={block.checked ? "Mark incomplete" : "Mark complete"}
                  onClick={() => updateBlock(block.id, { checked: !block.checked })}
                >
                  {block.checked && <Check size={11} weight="bold" />}
                </button>
              )}
              {block.type === "bulleted" && <span className="notion-list-marker" aria-hidden="true">•</span>}
              {block.type === "numbered" && <span className="notion-list-marker notion-number-marker" aria-hidden="true">{number}.</span>}

              {block.type === "divider" ? (
                <div
                  ref={(node) => {
                    if (node) blockRefs.current.set(block.id, node);
                    else blockRefs.current.delete(block.id);
                  }}
                  className="notion-divider"
                  role="separator"
                  tabIndex={0}
                  aria-label="Divider block"
                  onKeyDown={(event) => {
                    if (event.key === "Enter") {
                      event.preventDefault();
                      insertBlockAfter(block.id);
                    } else if (event.key === "Backspace" || event.key === "Delete") {
                      event.preventDefault();
                      deleteBlock(block.id);
                    }
                  }}
                >
                  <span />
                </div>
              ) : (
                <div
                  ref={(node) => {
                    if (node) blockRefs.current.set(block.id, node);
                    else blockRefs.current.delete(block.id);
                  }}
                  className="notion-block-content"
                  contentEditable={interactive}
                  suppressContentEditableWarning
                  role="textbox"
                  aria-label={`${BLOCK_COMMANDS.find((entry) => entry.type === block.type)?.label || "Text"} block`}
                  aria-multiline="true"
                  data-empty={String(block.text.length === 0)}
                  data-placeholder="Type '/' for commands"
                  spellCheck={block.type !== "code"}
                  onInput={(event) => handleBlockInput(block, event)}
                  onBlur={(event) => {
                    syncBlockNode(block.id, event.currentTarget);
                    emitChange();
                  }}
                  onKeyDown={(event) => handleBlockKeyDown(block, event)}
                  onBeforeInput={(event) => {
                    if (event.nativeEvent.inputType?.startsWith("delete") && handleCrossBlockDeletion(event)) {
                      return;
                    }
                    // Mirrors the desktop Enter path for mobile virtual
                    // keyboards while leaving insertLineBreak (Shift+Enter)
                    // available as a soft line break inside the current block.
                    if (event.nativeEvent.inputType === "insertParagraph") {
                      handleBlockEnter(block, event);
                    }
                  }}
                  onPaste={(event) => handlePaste(block, event)}
                  {...content}
                />
              )}

              {menuOpen && (
                <div ref={commandMenuRef} className="notion-command-menu" role="listbox" aria-label={commandMenu.mode === "slash" ? "Insert block" : "Block actions"}>
                  <span className="notion-command-label">{commandMenu.mode === "slash" ? "Basic blocks" : "Turn into"}</span>
                  {visibleCommands.length ? visibleCommands.map((command, commandIndex) => {
                    const Icon = command.Icon;
                    return (
                      <button
                        key={command.id}
                        type="button"
                        role="option"
                        data-command-index={commandIndex}
                        aria-selected={commandIndex === commandMenu.selected}
                        className={commandIndex === commandMenu.selected ? "is-selected" : ""}
                        onPointerDown={(event) => event.preventDefault()}
                        onClick={() => applyBlockCommand(command, block.id)}
                        onPointerEnter={() => setCommandMenu((current) => ({ ...current, selected: commandIndex }))}
                      >
                        <span className="notion-command-icon"><Icon size={17} /></span>
                        <span><strong>{command.label}</strong><small>{command.hint}</small></span>
                      </button>
                    );
                  }) : (
                    <span className="notion-command-empty">No blocks found</span>
                  )}
                </div>
              )}
            </div>
          );
        })}
      </div>

      {formatBar && (
        <div
          className="notion-format-bar"
          style={{ left: formatBar.left, top: formatBar.top }}
          role="toolbar"
          aria-label="Text formatting"
        >
          {inlineButton("Bold", TextB, "bold")}
          {inlineButton("Italic", TextItalic, "italic")}
          {inlineButton("Underline", TextUnderline, "underline")}
          {inlineButton("Strikethrough", TextStrikethrough, "strikeThrough")}
          {inlineButton("Inline code", CodeBlock, "formatBlock", "code")}
          <button
            type="button"
            aria-label="Add link"
            onPointerDown={(event) => {
              event.preventDefault();
              const url = window.prompt("Paste a link");
              if (url) executeInlineFormat("createLink", url);
            }}
          >
            <LinkSimple size={15} weight="bold" />
          </button>
        </div>
      )}
    </div>
  );
}
