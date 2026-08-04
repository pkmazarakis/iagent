// @ts-check

import { createSpatialDatabase } from "./database.js";
import { SpatialRepository } from "./repository.js";

/**
 * @param {Parameters<typeof createSpatialDatabase>[0]} [options]
 */
export function createSpatialRepository(options) {
  return new SpatialRepository(createSpatialDatabase(options));
}

export { SpatialDatabase, createSpatialDatabase } from "./database.js";
export { SpatialRepository } from "./repository.js";

