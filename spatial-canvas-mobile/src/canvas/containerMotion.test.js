import { describe, expect, it } from "vitest";
import {
  applyGeometryPatches,
  collapsedContainerMemberTarget,
} from "./containerMotion.js";

const pose = (x, y, width = 100, height = 80) => ({
  x,
  y,
  width,
  height,
  rotation: 0,
});

const folder = (id, memberIds, folderPose = pose(100, 200, 225, 160)) => ({
  id,
  kind: "folder",
  pose: folderPose,
  z: 12,
  stackId: null,
  content: { memberIds },
  updatedAt: 0,
});

const member = (id, stackId, memberPose) => ({
  id,
  kind: "note",
  pose: memberPose,
  z: 1,
  stackId,
  content: {},
  updatedAt: 0,
});

describe("collapsed container motion", () => {
  it("translates a collapsed member target with its container", () => {
    const child = member("child", "folder", pose(900, 700, 180, 120));
    const beforeFolder = folder("folder", ["one", "two", "three", "child"]);
    const afterFolder = {
      ...beforeFolder,
      pose: {
        ...beforeFolder.pose,
        x: beforeFolder.pose.x + 37,
        y: beforeFolder.pose.y - 19,
      },
    };

    const before = collapsedContainerMemberTarget(child, beforeFolder, 3);
    const after = collapsedContainerMemberTarget(child, afterFolder, 3);

    expect(after).toEqual({
      ...before,
      x: before.x + 37,
      y: before.y - 19,
    });
  });
});

describe("applyGeometryPatches", () => {
  it("moves a folder and all of its direct members in one transaction", () => {
    const container = folder("folder", ["first", "second"]);
    const first = member("first", "folder", pose(420, 310));
    const second = member("second", "folder", pose(-80, 940, 160, 140));
    const items = [container, first, second];

    const result = applyGeometryPatches(
      items,
      new Map([["folder", { x: 145, y: 175 }]]),
      { translateFolderMembers: true, now: 42 },
    );

    expect(result).not.toBe(items);
    expect(result[0]).toMatchObject({
      pose: { x: 145, y: 175, width: 225, height: 160, rotation: 0 },
      updatedAt: 42,
    });
    expect(result[1]).toMatchObject({
      pose: { x: 465, y: 285, width: 100, height: 80, rotation: 0 },
      updatedAt: 42,
    });
    expect(result[2]).toMatchObject({
      pose: { x: -35, y: 915, width: 160, height: 140, rotation: 0 },
      updatedAt: 42,
    });
  });

  it("keeps legacy stacks and their members together as the same container gesture", () => {
    const container = { ...folder("stack", ["inside"]), kind: "stack" };
    const inside = member("inside", "stack", pose(300, 400));

    const result = applyGeometryPatches(
      [container, inside],
      new Map([["stack", { x: 130, y: 190 }]]),
      { translateFolderMembers: true, now: 7 },
    );

    expect(result[0].pose).toMatchObject({ x: 130, y: 190 });
    expect(result[1].pose).toMatchObject({ x: 330, y: 390 });
  });

  it("leaves unrelated items referentially unchanged", () => {
    const container = folder("folder", ["inside"]);
    const inside = member("inside", "folder", pose(300, 400));
    const unrelated = member("unrelated", null, pose(700, 800));

    const result = applyGeometryPatches(
      [container, inside, unrelated],
      new Map([["folder", { x: 120, y: 230 }]]),
      { translateFolderMembers: true, now: 9 },
    );

    expect(result[2]).toBe(unrelated);
  });

  it("does not move folder members when translation is disabled", () => {
    const container = folder("folder", ["inside"]);
    const inside = member("inside", "folder", pose(300, 400));

    const result = applyGeometryPatches(
      [container, inside],
      new Map([["folder", { x: 160, y: 260 }]]),
      { translateFolderMembers: false, now: 11 },
    );

    expect(result[0].pose).toMatchObject({ x: 160, y: 260 });
    expect(result[1]).toBe(inside);
  });

  it("lets an explicit member patch win without applying the folder delta twice", () => {
    const container = folder("folder", ["inside"]);
    const inside = member("inside", "folder", pose(300, 400, 120, 90));

    const result = applyGeometryPatches(
      [container, inside],
      new Map([
        ["folder", { x: 140, y: 220 }],
        ["inside", { x: 333, y: 444 }],
      ]),
      { translateFolderMembers: true, now: 17 },
    );

    expect(result[1]).toMatchObject({
      pose: { x: 333, y: 444, width: 120, height: 90, rotation: 0 },
      updatedAt: 17,
    });
  });
});
