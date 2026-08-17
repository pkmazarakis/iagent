#!/usr/bin/env node

import { spawnSync } from "node:child_process";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";

const repositoryRoot = fileURLToPath(new URL("..", import.meta.url));
export const mobileDerivedDataPath = "/private/tmp/iagent-ask-reliability-mobile-derived";

export function createReliabilityCommands({
  contractsOnly = false,
  soakRequested = false,
  soakRuns = 1,
  root = repositoryRoot,
} = {}) {
  const commands = [
    {
      name: "Reliability runner orchestration suite",
      command: process.execPath,
      args: ["--test", "Tests/AskIAgentReliabilityRunnerTests.mjs"],
      cwd: root,
    },
  ];

  for (let index = 1; index <= soakRuns; index += 1) {
    commands.push({
      name: soakRuns === 1
        ? "Ask iAgent reliability scenario matrix"
        : `Ask iAgent reliability scenario matrix (soak ${index}/${soakRuns})`,
      command: process.execPath,
      args: ["--test", "Tests/AskIAgentHarnessReliabilityMatrixTests.mjs"],
      cwd: root,
    });
  }

  if (!contractsOnly) {
    commands.push(
      {
        name: "Local relay regression suite",
        command: process.execPath,
        args: ["--test", "Tests/AskIAgentRelayTests.mjs"],
        cwd: root,
      },
      {
        name: "Release/schema readiness suite",
        command: process.execPath,
        args: ["--test", "Tests/AskIAgentReleaseReadinessTests.mjs"],
        cwd: root,
      },
      {
        name: "Production Worker syntax gate",
        command: "npm",
        args: ["run", "check"],
        cwd: `${root}/Workers/AskIAgentRelay`,
      },
      {
        name: "Production Worker reliability suite",
        command: "npm",
        args: ["test"],
        cwd: `${root}/Workers/AskIAgentRelay`,
      },
      {
        name: "Swift Ask iAgent query/history suite",
        command: "swift",
        args: ["test", "--filter", "AskIAgent"],
        cwd: root,
      },
      {
        name: "Swift action proposal/broker safety suite",
        command: "swift",
        args: ["test", "--filter", "AssistantAction"],
        cwd: root,
      },
    );
  }

  // A contract soak intentionally stays device- and Xcode-free. The normal full
  // gate must compile the app and its iAgentMobileTests bundle, but a generic
  // destination only selects the Simulator SDK and never boots a device.
  if (!contractsOnly && !soakRequested) {
    commands.push({
      name: "iAgentMobile test-bundle compile gate",
      command: "xcodebuild",
      args: [
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
      ],
      cwd: root,
    });
  }

  return commands;
}

function main(argv) {
  const contractsOnly = argv.includes("--contracts-only");
  const soakIndex = argv.indexOf("--soak");
  const soakRequested = soakIndex >= 0;
  const soakRuns = soakRequested ? Number.parseInt(argv[soakIndex + 1] ?? "", 10) : 1;

  if (!Number.isSafeInteger(soakRuns) || soakRuns < 1 || soakRuns > 100) {
    console.error("--soak must be an integer from 1 through 100.");
    process.exit(2);
  }

  const commands = createReliabilityCommands({ contractsOnly, soakRequested, soakRuns });
  const results = [];
  for (const item of commands) {
    const startedAt = Date.now();
    console.log(`\n=== ${item.name} ===`);
    const result = spawnSync(item.command, item.args, {
      cwd: item.cwd,
      encoding: "utf8",
      stdio: ["ignore", "pipe", "pipe"],
      maxBuffer: 64 * 1024 * 1024,
    });
    if (result.stdout) process.stdout.write(result.stdout);
    if (result.stderr) process.stderr.write(result.stderr);
    const status = result.status ?? 1;
    results.push({ name: item.name, status, durationMS: Date.now() - startedAt });
  }

  console.log("\n=== Ask iAgent reliability gate summary ===");
  for (const result of results) {
    console.log(
      `${result.status === 0 ? "PASS" : "FAIL"}  ${result.name}  ${(result.durationMS / 1_000).toFixed(2)}s`,
    );
  }

  const failed = results.filter((result) => result.status !== 0);
  if (failed.length > 0) {
    console.error(`\nReliability gate failed: ${failed.length}/${results.length} command(s) failed.`);
    process.exit(1);
  }

  if (contractsOnly || soakRequested) {
    console.log(`\nPartial reliability run passed: ${results.length}/${results.length} command(s) passed.`);
    console.log("The contracts-only/soak mode skips the iOS test-bundle compile gate.");
  } else {
    console.log(`\nFull reliability gate passed: ${results.length}/${results.length} command(s) passed.`);
    console.log(
      "iAgentMobileTests compiled for the generic iOS Simulator SDK without booting a device; "
      + "signed-device canaries remain required before upload.",
    );
  }
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main(process.argv.slice(2));
}
