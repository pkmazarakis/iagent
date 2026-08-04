import { autoOrganizeItems } from "./autoOrganize.js";

self.onmessage = (event) => {
  const { id, items, options } = event.data;
  try {
    self.postMessage({ id, layout: autoOrganizeItems(items, options) });
  } catch (error) {
    self.postMessage({ id, error: error instanceof Error ? error.message : String(error) });
  }
};
