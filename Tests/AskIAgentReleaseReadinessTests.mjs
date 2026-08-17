import assert from "node:assert/strict";
import test from "node:test";

import {
  ReleaseReadinessError,
  evaluateReleaseReadiness,
  loadReleaseReadinessInputs,
} from "../Scripts/check-ask-iagent-release-readiness.mjs";

test("current non-secret release configuration is internally ready", () => {
  const summary = evaluateReleaseReadiness(loadReleaseReadinessInputs());
  assert.equal(summary.appAttestEnvironment, "production");
  assert.match(summary.relayURL, /^https:\/\//u);
  assert.match(summary.readSchema.digest, /^[a-f0-9]{64}$/u);
  assert.match(summary.actionSchema.digest, /^[a-f0-9]{64}$/u);
});

test("explicitly validates the next candidate without creating an infinite build chase", () => {
  const inputs = loadReleaseReadinessInputs();
  const current = evaluateReleaseReadiness(inputs);
  const candidate = `${Number(current.build) + 1}`;
  inputs.workerConfiguration = inputs.workerConfiguration.replace(
    /("APP_ATTEST_ALLOWED_BUNDLE_VERSIONS"\s*:\s*")([^"]*)(")/u,
    (_match, prefix, versions, suffix) => `${prefix}${versions},${candidate}${suffix}`,
  );
  assert.equal(evaluateReleaseReadiness(inputs, { candidateBuild: candidate }).candidateBuild, candidate);
  assert.throws(
    () => evaluateReleaseReadiness(inputs, { candidateBuild: `${Number(candidate) + 100}` }),
    new RegExp(`Release candidate build ${Number(candidate) + 100} is absent`, "u"),
  );
});

test("fails closed when the current app and widget build is not Worker allowlisted", () => {
  const inputs = loadReleaseReadinessInputs();
  const current = evaluateReleaseReadiness(inputs);
  inputs.workerConfiguration = inputs.workerConfiguration.replace(
    /("APP_ATTEST_ALLOWED_BUNDLE_VERSIONS"\s*:\s*")([^"]*)(")/u,
    (_match, prefix, versions, suffix) => {
      const withoutCurrent = versions
        .split(",")
        .filter((version) => version.trim() !== current.build)
        .join(",");
      return `${prefix}${withoutCurrent}${suffix}`;
    },
  );
  assert.throws(
    () => evaluateReleaseReadiness(inputs),
    (error) => error instanceof ReleaseReadinessError
      && error.message === `Release candidate build ${current.build} is absent from Worker APP_ATTEST_ALLOWED_BUNDLE_VERSIONS.`,
  );
});

test("rejects a non-HTTPS Release relay or non-production App Attest", () => {
  const relayInputs = loadReleaseReadinessInputs();
  relayInputs.project = relayInputs.project.replace(
    'IAGENT_OPENAI_RELAY_URL = "https://',
    'IAGENT_OPENAI_RELAY_URL = "http://',
  );
  assert.throws(
    () => evaluateReleaseReadiness(relayInputs),
    /Release relay URL must use HTTPS/u,
  );

  const attestationInputs = loadReleaseReadinessInputs();
  attestationInputs.releaseEntitlements = attestationInputs.releaseEntitlements.replace(
    "<string>production</string>",
    "<string>development</string>",
  );
  assert.throws(
    () => evaluateReleaseReadiness(attestationInputs),
    /Release App Attest environment must be production/u,
  );
});

test("rejects read or action schema drift between native, local relay, and Worker", () => {
  const readInputs = loadReleaseReadinessInputs();
  readInputs.localRelayContract = readInputs.localRelayContract.replace(
    /V2_READ_TOOL_SCHEMA_DIGEST = "[a-f0-9]{64}"/u,
    `V2_READ_TOOL_SCHEMA_DIGEST = "${"0".repeat(64)}"`,
  );
  assert.throws(() => evaluateReleaseReadiness(readInputs), /Read-tool schema identity mismatch/u);

  const actionInputs = loadReleaseReadinessInputs();
  actionInputs.workerRelayContract = actionInputs.workerRelayContract.replace(
    /(V2_ACTION_TOOL_SCHEMA_DIGEST\s*=\s*)"[a-f0-9]{64}"/u,
    `$1"${"0".repeat(64)}"`,
  );
  assert.throws(() => evaluateReleaseReadiness(actionInputs), /Action-tool schema identity mismatch/u);
});
