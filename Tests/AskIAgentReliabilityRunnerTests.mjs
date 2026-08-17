import assert from "node:assert/strict";
import test from "node:test";

import {
  createReliabilityCommands,
  mobileDerivedDataPath,
} from "../Scripts/run-ask-iagent-reliability-evals.mjs";

function mobileCompileStage(options) {
  return createReliabilityCommands({ root: "/repo", ...options })
    .find((item) => item.name === "iAgentMobile test-bundle compile gate");
}

test("normal full reliability run compiles the iAgentMobileTests bundle without a device", () => {
  const stage = mobileCompileStage();

  assert.ok(stage);
  assert.equal(stage.command, "xcodebuild");
  assert.equal(stage.cwd, "/repo");
  assert.deepEqual(stage.args, [
    "-project", "Mobile/iAgentMobile.xcodeproj",
    "-scheme", "iAgentMobile",
    "-sdk", "iphonesimulator",
    "-destination", "generic/platform=iOS Simulator",
    "-derivedDataPath", mobileDerivedDataPath,
    "-only-testing:iAgentMobileTests",
    "CODE_SIGNING_ALLOWED=NO",
    "ARCHS=arm64",
    "ONLY_ACTIVE_ARCH=YES",
    "build-for-testing",
  ]);
});

test("contracts-only and soak runs deliberately skip the mobile compile stage", () => {
  assert.equal(mobileCompileStage({ contractsOnly: true }), undefined);
  assert.equal(mobileCompileStage({ soakRequested: true, soakRuns: 20 }), undefined);
});

test("generic mobile compile stage contains no concrete Simulator lifecycle operation", () => {
  const stage = mobileCompileStage();
  const invocation = [stage.command, ...stage.args].join(" ");

  assert.doesNotMatch(invocation, /simctl|boot|shutdown|erase|install|launch/i);
  assert.match(invocation, /generic\/platform=iOS Simulator/);
});
