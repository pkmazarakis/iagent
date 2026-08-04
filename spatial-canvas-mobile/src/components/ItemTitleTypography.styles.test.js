import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";

const styles = readFileSync(new URL("../styles.css", import.meta.url), "utf8");

describe("shared canvas item title typography", () => {
  it("uses the folder title metrics for every retained item title", () => {
    for (const contract of [
      '--item-title-font-family: "Inter Display", sans-serif',
      "--item-title-font-size: 15px",
      "--item-title-font-weight: 500",
      "--item-title-line-height: 1.08",
      "--item-title-letter-spacing: -0.025em",
      ".note-preview h3",
      ".document-preview h3",
      ".web-preview h3",
      ".stack-front h3",
      ".artifact-title-overlay strong",
      ".image-caption",
    ]) {
      expect(styles).toContain(contract);
    }
  });
});
