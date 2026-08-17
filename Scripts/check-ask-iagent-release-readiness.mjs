#!/usr/bin/env node

import { readFileSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const scriptPath = fileURLToPath(import.meta.url);
const defaultRepositoryRoot = resolve(dirname(scriptPath), "..");

export class ReleaseReadinessError extends Error {
  constructor(message) {
    super(message);
    this.name = "ReleaseReadinessError";
  }
}

function requireCondition(condition, message) {
  if (!condition) throw new ReleaseReadinessError(message);
}

function escapeRegularExpression(value) {
  return value.replace(/[.*+?^${}()|[\]\\]/gu, "\\$&");
}

function objectBlock(source, objectID, comment) {
  const marker = new RegExp(
    `^[\\t ]*${escapeRegularExpression(objectID)} /\\* ${escapeRegularExpression(comment)} \\*/ = \\{`,
    "mu",
  );
  const match = marker.exec(source);
  requireCondition(match, `Could not find ${comment} build configuration ${objectID}.`);
  const openingBrace = source.indexOf("{", match.index);
  let depth = 0;
  for (let index = openingBrace; index < source.length; index += 1) {
    if (source[index] === "{") depth += 1;
    if (source[index] === "}") {
      depth -= 1;
      if (depth === 0) return source.slice(openingBrace + 1, index);
    }
  }
  throw new ReleaseReadinessError(`Build configuration ${objectID} is malformed.`);
}

function releaseBuildSettings(project, targetName) {
  const listPattern = new RegExp(
    String.raw`^[\t ]*([A-F0-9]{24}) /\* Build configuration list for PBXNativeTarget "${escapeRegularExpression(targetName)}" \*/ = \{([\s\S]*?)^[\t ]*\};`,
    "mu",
  );
  const list = listPattern.exec(project);
  requireCondition(list, `Could not find the ${targetName} target configuration list.`);
  const release = /([A-F0-9]{24}) \/\* Release \*\//u.exec(list[2]);
  requireCondition(release, `Could not find the ${targetName} Release configuration.`);
  return objectBlock(project, release[1], "Release");
}

function buildSetting(settings, name) {
  const match = new RegExp(
    `^[\\t ]*${escapeRegularExpression(name)}[\\t ]*=[\\t ]*(.+);[\\t ]*$`,
    "mu",
  ).exec(settings);
  requireCondition(match, `Release build setting ${name} is missing.`);
  const value = match[1].trim();
  return value.startsWith('"') && value.endsWith('"') ? value.slice(1, -1) : value;
}

function quotedProperty(source, name) {
  const match = new RegExp(
    `"${escapeRegularExpression(name)}"[\\t ]*:[\\t ]*"([^"]*)"`,
    "u",
  ).exec(source);
  requireCondition(match, `Worker setting ${name} is missing.`);
  return match[1];
}

function plistString(source, key) {
  const match = new RegExp(
    `<key>${escapeRegularExpression(key)}</key>[\\t\\r\\n ]*<string>([^<]+)</string>`,
    "u",
  ).exec(source);
  requireCondition(match, `Plist key ${key} is missing.`);
  return match[1].trim();
}

function exportedInteger(source, name, label) {
  const match = new RegExp(
    `export[\\t ]+const[\\t ]+${escapeRegularExpression(name)}[\\t ]*=[\\t ]*(\\d+)[\\t ]*;`,
    "u",
  ).exec(source);
  requireCondition(match, `${label} version is missing.`);
  return Number(match[1]);
}

function exportedDigest(source, name, label) {
  const match = new RegExp(
    `export[\\t ]+const[\\t ]+${escapeRegularExpression(name)}[\\t ]*=[\\t\\r\\n ]*"([a-f0-9]{64})"[\\t ]*;`,
    "u",
  ).exec(source);
  requireCondition(match, `${label} digest is missing or malformed.`);
  return match[1];
}

function nativeActionIdentity(source) {
  const catalog = /public enum AssistantProposalToolCatalog \{([\s\S]*?)public static let createTodoName/u.exec(source);
  requireCondition(catalog, "Native action-tool catalog is missing.");
  const version = /public static let schemaVersion = (\d+)/u.exec(catalog[1]);
  const digest = /public static let schemaDigest[\t ]*=[\t\r\n ]*"([a-f0-9]{64})"/u.exec(catalog[1]);
  requireCondition(version && digest, "Native action-tool schema identity is missing or malformed.");
  return { version: Number(version[1]), digest: digest[1] };
}

function nativeReadIdentity(contractSource, contractTestSource) {
  const catalog = /public enum AskReadToolSchemas \{([\s\S]*?)public static let todo/u.exec(contractSource);
  requireCondition(catalog, "Native read-tool catalog is missing.");
  const version = /public static let schemaVersion = (\d+)/u.exec(catalog[1]);
  const digestLock = /XCTAssertEqual\([\t\r\n ]*AskReadToolSchemas\.schemaDigest,[\t\r\n ]*"([a-f0-9]{64})"[\t\r\n ]*\)/u.exec(
    contractTestSource,
  );
  requireCondition(version && digestLock, "Native read-tool schema identity lock is missing or malformed.");
  return { version: Number(version[1]), digest: digestLock[1] };
}

function requireSameIdentity(label, identities) {
  const [first, ...rest] = identities;
  for (const candidate of rest) {
    requireCondition(
      candidate.version === first.version && candidate.digest === first.digest,
      `${label} schema identity mismatch: ${first.owner}=v${first.version}/${first.digest}, ${candidate.owner}=v${candidate.version}/${candidate.digest}.`,
    );
  }
  return { version: first.version, digest: first.digest };
}

export function loadReleaseReadinessInputs(repositoryRoot = defaultRepositoryRoot) {
  const read = (relativePath) => readFileSync(join(repositoryRoot, relativePath), "utf8");
  return {
    repositoryRoot,
    project: read("Mobile/iAgentMobile.xcodeproj/project.pbxproj"),
    mobileInfoPlist: read("Mobile/iAgentMobile/Resources/Info.plist"),
    releaseEntitlements: read("Mobile/iAgentMobile/Resources/iAgentMobileRelease.entitlements"),
    workerConfiguration: read("Workers/AskIAgentRelay/wrangler.jsonc"),
    nativeReadContract: read("Sources/iAgentCore/AskIAgentQueryContracts.swift"),
    nativeReadContractTest: read("Tests/iAgentTests/AskIAgentQueryFoundationTests.swift"),
    nativeActionContract: read("Sources/iAgentActionContracts/ActionProposalValidator.swift"),
    nativeV2Harness: read("Mobile/iAgentMobile/Model/AskIAgentV2Harness.swift"),
    nativeRelayRequest: read("Mobile/iAgentMobile/Model/AskIAgentModel.swift"),
    nativeRemoteTokenProvider: read("Mobile/iAgentMobile/Model/AskIAgentRemoteTokenProvider.swift"),
    localRelayContract: read("Scripts/ask-iagent-openai-relay.mjs"),
    workerRelayContract: read("Workers/AskIAgentRelay/src/contract.mjs"),
  };
}

export function evaluateReleaseReadiness(inputs, { candidateBuild } = {}) {
  const appRelease = releaseBuildSettings(inputs.project, "iAgentMobile");
  const widgetRelease = releaseBuildSettings(inputs.project, "iAgentWidgets");
  const appBuild = buildSetting(appRelease, "CURRENT_PROJECT_VERSION");
  const widgetBuild = buildSetting(widgetRelease, "CURRENT_PROJECT_VERSION");
  requireCondition(/^\d+(?:\.\d+){0,2}$/u.test(appBuild), `App build number ${appBuild} is invalid.`);
  requireCondition(/^\d+(?:\.\d+){0,2}$/u.test(widgetBuild), `Widget build number ${widgetBuild} is invalid.`);
  requireCondition(appBuild === widgetBuild, `App build ${appBuild} and widget build ${widgetBuild} differ.`);

  const allowedBuilds = new Set(
    quotedProperty(inputs.workerConfiguration, "APP_ATTEST_ALLOWED_BUNDLE_VERSIONS")
      .split(",")
      .map((value) => value.trim())
      .filter(Boolean),
  );
  const effectiveCandidateBuild = candidateBuild ?? appBuild;
  requireCondition(
    typeof effectiveCandidateBuild === "string" && /^\d+(?:\.\d+){0,2}$/u.test(effectiveCandidateBuild),
    `Candidate build ${effectiveCandidateBuild ?? "unknown"} is invalid.`,
  );
  requireCondition(
    allowedBuilds.has(effectiveCandidateBuild),
    `Release candidate build ${effectiveCandidateBuild} is absent from Worker APP_ATTEST_ALLOWED_BUNDLE_VERSIONS.`,
  );

  const releaseEntitlementsPath = buildSetting(appRelease, "CODE_SIGN_ENTITLEMENTS");
  requireCondition(
    releaseEntitlementsPath === "iAgentMobile/Resources/iAgentMobileRelease.entitlements",
    `Release uses unexpected entitlements: ${releaseEntitlementsPath}.`,
  );
  requireCondition(
    plistString(
      inputs.releaseEntitlements,
      "com.apple.developer.devicecheck.appattest-environment",
    ) === "production",
    "Release App Attest environment must be production.",
  );
  requireCondition(
    quotedProperty(inputs.workerConfiguration, "APP_ATTEST_ALLOWED_ENVIRONMENTS") === "production",
    "Worker App Attest environments must be production-only for release.",
  );
  requireCondition(
    quotedProperty(inputs.workerConfiguration, "ATTESTATION_EXCHANGE_ENABLED") === "true",
    "Worker App Attest exchange must be enabled for release.",
  );

  const relayURL = buildSetting(appRelease, "IAGENT_OPENAI_RELAY_URL");
  let parsedRelayURL;
  try {
    parsedRelayURL = new URL(relayURL);
  } catch {
    throw new ReleaseReadinessError(`Release relay URL is invalid: ${relayURL}.`);
  }
  requireCondition(parsedRelayURL.protocol === "https:", "Release relay URL must use HTTPS.");
  requireCondition(
    parsedRelayURL.pathname === "/v1/ask",
    `Release relay URL must target /v1/ask, not ${parsedRelayURL.pathname}.`,
  );
  requireCondition(
    plistString(inputs.mobileInfoPlist, "IAGENTOpenAIRelayURL") === "$(IAGENT_OPENAI_RELAY_URL)",
    "The app Info.plist no longer consumes the Release relay build setting.",
  );
  requireCondition(
    inputs.nativeRemoteTokenProvider.includes("DCAppAttestService.shared")
      && inputs.nativeRelayRequest.includes(
        "tokenProvider: any AskIAgentRemoteTokenProviding = AskIAgentRemoteTokenProvider()",
      )
      && inputs.nativeRelayRequest.includes("try await tokenProvider.authorizationHeader"),
    "The Release relay path is no longer protected by the native App Attest token provider.",
  );

  requireCondition(
    inputs.nativeV2Harness.includes("readToolSchemaVersion: AskReadToolSchemas.schemaVersion")
      && inputs.nativeV2Harness.includes("readToolSchemaDigest: AskReadToolSchemas.schemaDigest")
      && inputs.nativeV2Harness.includes("actionToolSchemaVersion: AssistantProposalToolCatalog.schemaVersion")
      && inputs.nativeV2Harness.includes("actionToolSchemaDigest: AssistantProposalToolCatalog.schemaDigest"),
    "Native V2 state is not wired to both canonical schema identities.",
  );
  requireCondition(
    inputs.nativeRelayRequest.includes("toolSchemaVersion: state.readToolSchemaVersion")
      && inputs.nativeRelayRequest.includes("toolSchemaDigest: state.readToolSchemaDigest")
      && inputs.nativeRelayRequest.includes("actionToolSchemaVersion: state.actionToolSchemaVersion")
      && inputs.nativeRelayRequest.includes("actionToolSchemaDigest: state.actionToolSchemaDigest"),
    "Native V2 relay requests do not transmit both canonical schema identities.",
  );

  const nativeRead = { owner: "native", ...nativeReadIdentity(inputs.nativeReadContract, inputs.nativeReadContractTest) };
  const localRead = {
    owner: "local relay",
    version: exportedInteger(inputs.localRelayContract, "V2_READ_TOOL_SCHEMA_VERSION", "Local read-tool schema"),
    digest: exportedDigest(inputs.localRelayContract, "V2_READ_TOOL_SCHEMA_DIGEST", "Local read-tool schema"),
  };
  const workerRead = {
    owner: "Worker",
    version: exportedInteger(inputs.workerRelayContract, "V2_READ_TOOL_SCHEMA_VERSION", "Worker read-tool schema"),
    digest: exportedDigest(inputs.workerRelayContract, "V2_READ_TOOL_SCHEMA_DIGEST", "Worker read-tool schema"),
  };
  const readSchema = requireSameIdentity("Read-tool", [nativeRead, localRead, workerRead]);

  const nativeAction = { owner: "native", ...nativeActionIdentity(inputs.nativeActionContract) };
  const localAction = {
    owner: "local relay",
    version: exportedInteger(inputs.localRelayContract, "V2_ACTION_TOOL_SCHEMA_VERSION", "Local action-tool schema"),
    digest: exportedDigest(inputs.localRelayContract, "V2_ACTION_TOOL_SCHEMA_DIGEST", "Local action-tool schema"),
  };
  const workerAction = {
    owner: "Worker",
    version: exportedInteger(inputs.workerRelayContract, "V2_ACTION_TOOL_SCHEMA_VERSION", "Worker action-tool schema"),
    digest: exportedDigest(inputs.workerRelayContract, "V2_ACTION_TOOL_SCHEMA_DIGEST", "Worker action-tool schema"),
  };
  const actionSchema = requireSameIdentity("Action-tool", [nativeAction, localAction, workerAction]);

  return {
    build: appBuild,
    candidateBuild: effectiveCandidateBuild,
    relayURL,
    appAttestEnvironment: "production",
    readSchema,
    actionSchema,
  };
}

export function verifyNativeReadSchemaRuntime(repositoryRoot = defaultRepositoryRoot) {
  const moduleCache = join(tmpdir(), "iagent-release-readiness-swiftpm");
  const clangCache = join(tmpdir(), "iagent-release-readiness-clang");
  const result = spawnSync(
    "swift",
    [
      "test",
      "--disable-sandbox",
      "--filter",
      "iAgentTests.AskIAgentQueryFoundationTests/testExternalReadToolContractHasStableVersionDigestAndAllowlist",
    ],
    {
      cwd: repositoryRoot,
      encoding: "utf8",
      env: {
        ...process.env,
        SWIFTPM_MODULECACHE_OVERRIDE: moduleCache,
        CLANG_MODULE_CACHE_PATH: clangCache,
      },
    },
  );
  if (result.status !== 0) {
    const detail = `${result.stdout ?? ""}\n${result.stderr ?? ""}`.trim().split("\n").slice(-20).join("\n");
    throw new ReleaseReadinessError(`Native read-schema runtime contract test failed.\n${detail}`);
  }
}

export function checkReleaseReadiness(repositoryRoot = defaultRepositoryRoot, options = {}) {
  const summary = evaluateReleaseReadiness(loadReleaseReadinessInputs(repositoryRoot), options);
  verifyNativeReadSchemaRuntime(repositoryRoot);
  return summary;
}

function report(summary) {
  process.stdout.write(
    [
      "Ask iAgent release readiness passed.",
      `Build: ${summary.build} (app + widget); candidate ${summary.candidateBuild} Worker allowlisted`,
      `Relay: ${summary.relayURL}`,
      `App Attest: ${summary.appAttestEnvironment}`,
      `Read schema: v${summary.readSchema.version} ${summary.readSchema.digest}`,
      `Action schema: v${summary.actionSchema.version} ${summary.actionSchema.digest}`,
      "",
    ].join("\n"),
  );
}

if (process.argv[1] && resolve(process.argv[1]) === scriptPath) {
  try {
    const candidateFlagIndex = process.argv.indexOf("--candidate-build");
    const candidateBuild = candidateFlagIndex >= 0 ? process.argv[candidateFlagIndex + 1] : undefined;
    if (candidateFlagIndex >= 0 && !candidateBuild) {
      throw new ReleaseReadinessError("--candidate-build requires a value.");
    }
    report(checkReleaseReadiness(defaultRepositoryRoot, { candidateBuild }));
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    process.stderr.write(`Ask iAgent release readiness failed: ${message}\n`);
    process.exitCode = 1;
  }
}
