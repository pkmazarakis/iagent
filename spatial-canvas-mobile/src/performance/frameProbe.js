const FRAME_BUDGET_MS = 1000 / 60;

export function percentile(values, quantile) {
  if (!values.length) return 0;
  const sorted = [...values].sort((a, b) => a - b);
  const index = Math.min(
    sorted.length - 1,
    Math.max(0, Math.ceil(sorted.length * quantile) - 1),
  );
  return sorted[index];
}

export function summarizeFrameIntervals(intervals, durationMs, extras = {}) {
  const safeIntervals = intervals.filter((value) => Number.isFinite(value) && value >= 0);
  const measuredFrameDuration = safeIntervals.reduce((total, value) => total + value, 0);
  const droppedFrames = safeIntervals.reduce(
    (total, value) => total + Math.max(0, Math.round(value / FRAME_BUDGET_MS) - 1),
    0,
  );
  const longFrames = safeIntervals.filter((value) => value > FRAME_BUDGET_MS * 2).length;
  return {
    durationMs: Math.round(durationMs * 10) / 10,
    frames: safeIntervals.length + 1,
    averageFps: measuredFrameDuration > 0
      ? Math.round((safeIntervals.length * 1000 / measuredFrameDuration) * 10) / 10
      : 0,
    p95FrameMs: Math.round(percentile(safeIntervals, 0.95) * 10) / 10,
    maxFrameMs: Math.round(Math.max(0, ...safeIntervals) * 10) / 10,
    longFrames,
    droppedFrames,
    ...extras,
  };
}

function createEntryCollector(type, options = {}) {
  const entries = [];
  if (typeof PerformanceObserver !== "function") return { entries, disconnect() {} };
  try {
    const observer = new PerformanceObserver((list) => entries.push(...list.getEntries()));
    observer.observe({ type, buffered: false, ...options });
    return { entries, disconnect: () => observer.disconnect() };
  } catch {
    return { entries, disconnect() {} };
  }
}

function entriesWithin(entries, start, end) {
  return entries.filter((entry) => entry.startTime >= start && entry.startTime <= end);
}

function describeLayoutShiftSource(source) {
  const node = source.node;
  const name = node?.dataset?.itemId
    || node?.getAttribute?.("aria-label")
    || (typeof node?.className === "string" ? node.className : "")
    || node?.tagName
    || "unknown";
  const rect = (value) => value ? {
    x: Math.round(value.x * 10) / 10,
    y: Math.round(value.y * 10) / 10,
    width: Math.round(value.width * 10) / 10,
    height: Math.round(value.height * 10) / 10,
  } : null;
  return {
    node: String(name).slice(0, 120),
    previousRect: rect(source.previousRect),
    currentRect: rect(source.currentRect),
  };
}

export function installFrameProbe() {
  if (typeof window === "undefined") return null;
  if (!new URLSearchParams(window.location.search).has("perf")) return null;
  if (window.__spatialPerformance) return window.__spatialPerformance;

  const reports = [];
  const active = new Map();
  const longTasks = createEntryCollector("longtask");
  const longAnimationFrames = createEntryCollector("long-animation-frame");
  const layoutShifts = createEntryCollector("layout-shift");

  const start = (label) => {
    const previous = active.get(label);
    previous?.cancel();
    const startedAt = performance.now();
    const intervals = [];
    let previousFrame = null;
    let frameId = 0;
    let stopped = false;
    const tick = (timestamp) => {
      if (stopped) return;
      if (previousFrame != null) intervals.push(timestamp - previousFrame);
      previousFrame = timestamp;
      frameId = requestAnimationFrame(tick);
    };
    frameId = requestAnimationFrame(tick);
    const session = {
      cancel() {
        stopped = true;
        cancelAnimationFrame(frameId);
      },
      stop(metadata = {}) {
        if (stopped) return reports.at(-1) || null;
        stopped = true;
        cancelAnimationFrame(frameId);
        const endedAt = performance.now();
        const observedLongTasks = entriesWithin(longTasks.entries, startedAt, endedAt);
        const observedLongFrames = entriesWithin(longAnimationFrames.entries, startedAt, endedAt);
        const observedLayoutShifts = entriesWithin(layoutShifts.entries, startedAt, endedAt)
          .filter((entry) => !entry.hadRecentInput);
        const layoutShiftSources = observedLayoutShifts
          .flatMap((entry) => Array.from(entry.sources || []))
          .slice(0, 8)
          .map(describeLayoutShiftSource);
        const report = {
          label,
          startedAt,
          endedAt,
          ...summarizeFrameIntervals(intervals, endedAt - startedAt, {
            longTasks: observedLongTasks.length,
            longTaskMs: Math.round(observedLongTasks.reduce((sum, entry) => sum + entry.duration, 0) * 10) / 10,
            longAnimationFrames: observedLongFrames.length,
            cumulativeLayoutShift: Math.round(observedLayoutShifts.reduce((sum, entry) => sum + entry.value, 0) * 10000) / 10000,
            layoutShiftSources,
            ...metadata,
          }),
        };
        active.delete(label);
        reports.push(report);
        document.documentElement.dataset.spatialPerfLast = JSON.stringify(report);
        document.documentElement.dataset.spatialPerfCount = String(reports.length);
        return report;
      },
    };
    active.set(label, session);
    return session;
  };

  const api = {
    start,
    stop(label, metadata) {
      return active.get(label)?.stop(metadata) || null;
    },
    cancel(label) {
      active.get(label)?.cancel();
      active.delete(label);
    },
    reset() {
      for (const session of active.values()) session.cancel();
      active.clear();
      reports.length = 0;
      delete document.documentElement.dataset.spatialPerfLast;
      document.documentElement.dataset.spatialPerfCount = "0";
    },
    snapshot() {
      return reports.map((report) => ({ ...report }));
    },
    destroy() {
      for (const session of active.values()) session.cancel();
      active.clear();
      longTasks.disconnect();
      longAnimationFrames.disconnect();
      layoutShifts.disconnect();
      delete window.__spatialPerformance;
    },
  };

  Object.defineProperty(window, "__spatialPerformance", {
    configurable: true,
    value: api,
  });
  document.documentElement.dataset.spatialPerfCount = "0";

  let gesture = null;
  let wheelLabel = null;
  let wheelTimer = 0;
  const armFixedSample = (label, duration = 1050) => {
    const session = start(label);
    window.setTimeout(() => session.stop(), duration);
  };
  const actionLabel = (event) => {
    const button = event.target.closest?.("button");
    return button?.getAttribute("aria-label") || button?.textContent?.trim() || "";
  };
  const armActionSample = (event) => {
    const label = actionLabel(event);
    if (label === "Focus selection") armFixedSample("focus-open");
    else if (label === "Exit focus") armFixedSample("focus-close");
    else if (label === "Close stack") armFixedSample("stack-close", 1400);
    else if (label.startsWith("Back to")) {
      armFixedSample(document.querySelector(".world-item.is-detail-viewer") ? "detail-close" : "folder-close", 1400);
    } else if (label === "Open scratch pad") armFixedSample("scratch-open", 850);
    else if (label === "Close scratch pad") armFixedSample("scratch-close", 850);
    else if (label.includes("Open boards")) armFixedSample("spaces-open", 850);
    else if (label === "Close board switcher") armFixedSample("spaces-close", 850);
    else if (label === "Add to board") armFixedSample("add-menu-open", 750);
    else if (label === "Close add menu") armFixedSample("add-menu-close", 750);
    else if (label === "Auto-organize board") armFixedSample("auto-organize", 1400);
    else if (label.startsWith("Use ") && label.endsWith(" canvas")) armFixedSample("theme-transition", 650);
  };
  const onDoubleClick = (event) => {
    const item = event.target.closest?.("[data-item-id]");
    if (!item) return;
    const kind = item.dataset.kind;
    if (kind !== "stack" && kind !== "folder") armFixedSample(`detail-open:${kind}`);
  };
  const onClick = (event) => {
    armActionSample(event);
    const item = event.target.closest?.("[data-item-id]");
    if (item?.dataset.kind === "stack") armFixedSample("stack-open", 1400);
    if (item?.dataset.kind === "folder") armFixedSample("folder-open", 1400);
  };
  const onKeyDown = (event) => {
    if (event.key !== "Escape") return;
    if (document.querySelector(".world-item.is-detail-viewer")) armFixedSample("detail-close");
    else if (document.querySelector(".world-item.is-folder-open")) armFixedSample("folder-close", 1400);
    else if (document.querySelector(".spatial-item.is-dimmed")) armFixedSample("context-close", 1400);
  };
  const onPointerDown = (event) => {
    if (event.button !== 0 && event.button !== 1) return;
    armActionSample(event);
    const item = event.target.closest?.("[data-item-id]");
    const label = item ? `pointer:${item.dataset.kind || "item"}` : "pointer:canvas";
    gesture = {
      label,
      pointerId: event.pointerId,
      x: event.clientX,
      y: event.clientY,
      session: start(label),
    };
  };
  const onPointerEnd = (event) => {
    if (!gesture || gesture.pointerId !== event.pointerId) return;
    const distance = Math.hypot(event.clientX - gesture.x, event.clientY - gesture.y);
    gesture.session.stop({ gestureDistance: Math.round(distance * 10) / 10 });
    gesture = null;
  };
  const onWheel = (event) => {
    const nextLabel = event.ctrlKey || event.metaKey ? "wheel-zoom" : "wheel-pan";
    if (wheelLabel !== nextLabel) {
      if (wheelLabel) api.stop(wheelLabel);
      wheelLabel = nextLabel;
      start(wheelLabel);
    }
    window.clearTimeout(wheelTimer);
    wheelTimer = window.setTimeout(() => {
      api.stop(wheelLabel);
      wheelLabel = null;
    }, 240);
  };
  document.addEventListener("dblclick", onDoubleClick, true);
  document.addEventListener("click", onClick, true);
  document.addEventListener("keydown", onKeyDown, true);
  document.addEventListener("pointerdown", onPointerDown, true);
  document.addEventListener("pointerup", onPointerEnd, true);
  document.addEventListener("pointercancel", onPointerEnd, true);
  document.addEventListener("wheel", onWheel, { capture: true, passive: true });
  return api;
}
