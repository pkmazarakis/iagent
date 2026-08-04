import { describe, expect, it } from "vitest";
import { isStackInspectionItem } from "./stackInspection.js";

describe("folder inspection scope", () => {
  const folder = { id: "folder", kind: "stack", stackId: null };
  const member = { id: "member", stackId: "folder" };
  const unrelated = { id: "other", stackId: null };

  it("allows only the active folder and its direct members", () => {
    expect(isStackInspectionItem(folder, "folder")).toBe(true);
    expect(isStackInspectionItem(member, "folder")).toBe(true);
    expect(isStackInspectionItem(unrelated, "folder")).toBe(false);
    expect(isStackInspectionItem(null, "folder")).toBe(false);
  });

  it("does not create a scope without an active folder", () => {
    expect(isStackInspectionItem(folder, null)).toBe(false);
    expect(isStackInspectionItem(member, null)).toBe(false);
  });
});
