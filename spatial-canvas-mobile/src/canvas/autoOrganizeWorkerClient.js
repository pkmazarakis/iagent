import { autoOrganizeItems } from "./autoOrganize.js";

const WORKER_THRESHOLD = 750;
let worker = null;
let requestId = 0;
const pending = new Map();

function rejectPending(error) {
  for (const request of pending.values()) request.reject(error);
  pending.clear();
}

function getWorker() {
  if (worker || typeof Worker !== "function") return worker;
  worker = new Worker(new URL("./autoOrganize.worker.js", import.meta.url), { type: "module" });
  worker.addEventListener("message", (event) => {
    const request = pending.get(event.data.id);
    if (!request) return;
    pending.delete(event.data.id);
    if (event.data.error) request.reject(new Error(event.data.error));
    else request.resolve(event.data.layout);
  });
  worker.addEventListener("error", (event) => {
    rejectPending(event.error || new Error(event.message || "Auto-organize worker failed"));
    worker?.terminate();
    worker = null;
  });
  return worker;
}

/**
 * Keep the common small-board path immediate, but move large-board solving
 * off the interaction thread so an infinite canvas never freezes while the
 * tidy constraints are calculated.
 */
export function autoOrganizeItemsAsync(items, options) {
  if (items.length < WORKER_THRESHOLD || typeof Worker !== "function") {
    return Promise.resolve(autoOrganizeItems(items, options));
  }
  const activeWorker = getWorker();
  if (!activeWorker) return Promise.resolve(autoOrganizeItems(items, options));
  const id = ++requestId;
  return new Promise((resolve, reject) => {
    pending.set(id, { resolve, reject });
    activeWorker.postMessage({ id, items, options });
  });
}
