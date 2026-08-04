import { describe, expect, it } from "vitest";
import {
  CONTAINER_VIEW_MODE,
  isContainerKind,
  transitionContainerView,
} from "./containerView.js";

describe("two-stage container view", () => {
  it("treats stacks and folders as the same visual container", () => {
    expect(isContainerKind("stack")).toBe(true);
    expect(isContainerKind({ kind: "folder" })).toBe(true);
    expect(isContainerKind("note")).toBe(false);
  });

  it("opens inline, promotes to a canvas, then backs out one level at a time", () => {
    const inline = transitionContainerView(null, { type: "open-inline", id: "folder" });
    expect(inline).toEqual({ id: "folder", mode: CONTAINER_VIEW_MODE.INLINE });

    const canvas = transitionContainerView(inline, { type: "expand-canvas", id: "folder" });
    expect(canvas).toEqual({ id: "folder", mode: CONTAINER_VIEW_MODE.CANVAS });
    expect(transitionContainerView(canvas, { type: "back" })).toEqual(inline);
    expect(transitionContainerView(inline, { type: "back" })).toBeNull();
  });

  it("ignores stale promotion events and clears a removed active container", () => {
    const inline = { id: "folder-a", mode: CONTAINER_VIEW_MODE.INLINE };
    expect(transitionContainerView(inline, { type: "expand-canvas", id: "folder-b" })).toBe(inline);
    expect(transitionContainerView(inline, { type: "remove", id: "folder-a" })).toBeNull();
  });
});
