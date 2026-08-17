import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

import {
  V2_ACTION_TOOL_SCHEMA_DIGEST as LOCAL_ACTION_DIGEST,
  V2_ACTION_TOOL_SCHEMA_VERSION as LOCAL_ACTION_VERSION,
  V2_CANONICAL_TOOL_NAMES as LOCAL_TOOL_NAMES,
  V2_MAX_MODEL_CONTINUATION_BYTES as LOCAL_CONTINUATION_BYTES,
  V2_MAX_MODEL_CONTINUATIONS as LOCAL_CONTINUATION_COUNT,
  V2_READ_TOOL_SCHEMA_DIGEST as LOCAL_READ_DIGEST,
  V2_READ_TOOL_SCHEMA_VERSION as LOCAL_READ_VERSION,
  buildOpenAIRequest as buildLocalRequest,
  createAskIAgentRelay,
  extractV2RelayResult as extractLocalResult,
  routeForClientRequest as validateLocalRequest,
} from "../Scripts/ask-iagent-openai-relay.mjs";
import { createLocalAnonymousToken } from "../Workers/AskIAgentRelay/src/auth.mjs";
import { sha256Base64URL } from "../Workers/AskIAgentRelay/src/attestation.mjs";
import { AttestationState } from "../Workers/AskIAgentRelay/src/attestation-state.mjs";
import {
  MAX_REQUEST_BYTES as WORKER_REQUEST_BYTES,
  ROUTES as WORKER_ROUTES,
  V2_ACTION_TOOL_SCHEMA_DIGEST as WORKER_ACTION_DIGEST,
  V2_ACTION_TOOL_SCHEMA_VERSION as WORKER_ACTION_VERSION,
  V2_CANONICAL_TOOL_NAMES as WORKER_TOOL_NAMES,
  V2_MAX_MODEL_CONTINUATION_BYTES as WORKER_CONTINUATION_BYTES,
  V2_MAX_MODEL_CONTINUATIONS as WORKER_CONTINUATION_COUNT,
  V2_READ_TOOL_SCHEMA_DIGEST as WORKER_READ_DIGEST,
  V2_READ_TOOL_SCHEMA_VERSION as WORKER_READ_VERSION,
  buildOpenAIRequest as buildWorkerRequest,
  extractV2RelayResponse as extractWorkerResult,
  validateClientRequest as validateWorkerRequest,
} from "../Workers/AskIAgentRelay/src/contract.mjs";
import { createWorker } from "../Workers/AskIAgentRelay/src/worker.mjs";

const NOW = "2026-08-12T08:00:00Z";
const NOW_MS = Date.parse(NOW);
const REMOTE_TIERS = ["fast", "pro"];
const ALL_TIERS = ["free", ...REMOTE_TIERS];

function clone(value) {
  return structuredClone(value);
}

function route(tier) {
  return tier === "pro"
    ? { model: "gpt-5.6-sol", reasoning: { mode: "pro", effort: "medium" } }
    : { model: "gpt-5.6-luna", reasoning: { effort: "low" } };
}

function domainEntry(domain, recordCount = 0, overrides = {}) {
  return {
    domain,
    availability: "available",
    availabilityReason: "none",
    recordCount,
    observedAt: NOW,
    lastSuccessfulReadAt: NOW,
    freshness: "current",
    coverage: {
      start: null,
      end: null,
      isCompleteWithinRange: true,
      isTruncated: false,
    },
    ...overrides,
  };
}

function catalog(entries = [domainEntry("todo")]) {
  return {
    version: 2,
    snapshotID: "reliability-snapshot-001",
    temporalContext: {
      contextAsOf: NOW,
      timeZoneIdentifier: "Europe/Athens",
      localeIdentifier: "en_US",
      calendarIdentifier: "gregorian",
      firstWeekday: 2,
    },
    domains: entries,
  };
}

function v2Request(tier = "fast", overrides = {}) {
  const selectedRoute = route(tier);
  return {
    protocolVersion: 2,
    tier,
    model: selectedRoute.model,
    reasoning: selectedRoute.reasoning,
    round: 0,
    prompt: "Plan my day.",
    contextAsOf: NOW,
    localeIdentifier: "en_US",
    safetyIdentifier: "reliability-eval-installation",
    recentConversation: [],
    catalog: catalog(),
    toolSchemaVersion: LOCAL_READ_VERSION,
    toolSchemaDigest: LOCAL_READ_DIGEST,
    actionToolSchemaVersion: LOCAL_ACTION_VERSION,
    actionToolSchemaDigest: LOCAL_ACTION_DIGEST,
    enabledTools: [...LOCAL_TOOL_NAMES],
    toolHistory: [],
    modelContinuation: [],
    evidence: [],
    ...overrides,
  };
}

function time(field, preset) {
  return { field, preset, start: null, end: null };
}

const readArguments = {
  query_todos(queryID = "todo-focus") {
    return {
      query_id: queryID,
      text: null,
      record_ids: [],
      states: ["open"],
      starred: null,
      due: "any",
      list_names: [],
      sort: "attentionDesc",
      content: "preview",
      time: time("due", "today"),
      limit: 5,
      cursor: null,
    };
  },
  query_calendar(queryID = "calendar-today") {
    return {
      query_id: queryID,
      text: null,
      record_ids: [],
      calendar_titles: [],
      all_day: null,
      sort: "startAsc",
      content: "details",
      time: time("occurrence", "today"),
      limit: 5,
      cursor: null,
    };
  },
  query_notes(queryID = "notes-launch") {
    return {
      query_id: queryID,
      text: "launch",
      record_ids: [],
      sort: "relevanceDesc",
      content: "preview",
      time: time("updated", "last30Days"),
      limit: 5,
      cursor: null,
    };
  },
  query_meetings(queryID = "latest-meeting") {
    return {
      query_id: queryID,
      text: null,
      record_ids: [],
      states: ["completed"],
      has_readable_content: true,
      sort: "occurrenceDesc",
      content: "summaryAndTranscriptPassages",
      time: time("occurrence", "past"),
      limit: 1,
      cursor: null,
    };
  },
  query_codex(queryID = "codex-active") {
    return {
      query_id: queryID,
      text: null,
      record_ids: [],
      states: ["running", "waitingForInput", "needsApproval"],
      modes: [],
      project_names: [],
      sort: "updatedDesc",
      content: "activity",
      time: time("updated", "last7Days"),
      limit: 5,
      cursor: null,
    };
  },
};

const proposalArguments = {
  prepare_create_todo: {
    title: "Grab coffee with Gabby",
    due_at: null,
    time_zone_id: null,
    list_name: null,
  },
  prepare_create_note: {
    title: "Bull case for Bitcoin",
    body: "A balanced memo with thesis, evidence, risks, and open questions.",
  },
  prepare_calendar_event_draft: {
    title: "Coffee with Gabby",
    start_at: "2026-08-13T10:00:00+03:00",
    end_at: "2026-08-13T10:30:00+03:00",
    time_zone_id: "Europe/Athens",
    is_all_day: false,
    calendar_id: null,
    location: null,
    notes: null,
  },
  prepare_codex_task_request: {
    prompt: "Audit the launch checklist and report blockers without deploying.",
    workspace_id: null,
  },
};

function functionCall(callID, name, args) {
  return {
    type: "function_call",
    call_id: callID,
    name,
    arguments: JSON.stringify(args),
  };
}

function reasoningItem(
  id = "rs_reliability_round",
  encryptedContent = "opaque_reliability_reasoning_AA==",
) {
  return {
    type: "reasoning",
    id,
    summary: [],
    encrypted_content: encryptedContent,
  };
}

function modelToolResponse(calls, reasoning = null) {
  return {
    status: "completed",
    output: reasoning === null ? calls : [reasoning, ...calls],
  };
}

function modelToolResponseForTier(tier, calls, round = 0) {
  return modelToolResponse(
    calls,
    tier === "pro"
      ? reasoningItem(`rs_${tier}_round_${round}`, `opaque_${tier}_round_${round}_AA==`)
      : null,
  );
}

function modelAnswer(claims, actionMessage = null) {
  return { status: "completed", output_text: JSON.stringify({ claims, actionMessage }) };
}

function evidence(id, source, title, content) {
  return {
    id,
    source,
    title,
    revision: `${id}-revision`,
    updatedAt: NOW,
    content,
  };
}

function receipt(callID, name, args, output) {
  return { callID, name, arguments: JSON.stringify(args), output };
}

function continuation(round, callIDs, suffix = `${round}`) {
  return {
    round,
    callIDs,
    reasoningID: `rs_reliability_${suffix}`,
    encryptedContent: `opaque_reliability_${suffix}_AA==`,
  };
}

function validateBoth(raw) {
  assert.doesNotThrow(() => validateLocalRequest(clone(raw)));
  return validateWorkerRequest(clone(raw));
}

function assertBothReject(raw) {
  assert.throws(() => validateLocalRequest(clone(raw)));
  assert.throws(() => validateWorkerRequest(clone(raw)));
}

function extractBoth(response, raw) {
  const local = extractLocalResult(clone(response), clone(raw));
  const validatedWorker = validateWorkerRequest(clone(raw));
  const worker = extractWorkerResult(clone(response), validatedWorker);
  assert.deepEqual(worker, local);
  return local;
}

function assertBothRejectOutput(response, raw) {
  assert.throws(() => extractLocalResult(clone(response), clone(raw)));
  const validatedWorker = validateWorkerRequest(clone(raw));
  assert.throws(() => extractWorkerResult(clone(response), validatedWorker));
}

function packetFromOpenAIRequest(request) {
  const content = request.input[1].content;
  return JSON.parse(content.slice(content.indexOf("\n\n") + 2));
}

test("all tiers are pinned to one V2 architecture and one schema identity", () => {
  assert.deepEqual(LOCAL_TOOL_NAMES, WORKER_TOOL_NAMES);
  assert.equal(LOCAL_READ_VERSION, WORKER_READ_VERSION);
  assert.equal(LOCAL_READ_DIGEST, WORKER_READ_DIGEST);
  assert.equal(LOCAL_ACTION_VERSION, WORKER_ACTION_VERSION);
  assert.equal(LOCAL_ACTION_DIGEST, WORKER_ACTION_DIGEST);
  assert.equal(LOCAL_CONTINUATION_COUNT, WORKER_CONTINUATION_COUNT);
  assert.equal(LOCAL_CONTINUATION_BYTES, WORKER_CONTINUATION_BYTES);
  assert.deepEqual(ALL_TIERS, ["free", "fast", "pro"]);

  const harnessSource = readFileSync(
    new URL("../Mobile/iAgentMobile/Model/AskIAgentV2Harness.swift", import.meta.url),
    "utf8",
  );
  const modelSource = readFileSync(
    new URL("../Mobile/iAgentMobile/Model/AskIAgentModel.swift", import.meta.url),
    "utf8",
  );
  assert.match(harnessSource, /#else\s+[\s\S]*?return \.v2\s+#endif/u);
  assert.match(
    modelSource,
    /inferenceProfile: turn\.modelTier == \.free \? \.onDevice : \.remote/u,
  );
  assert.match(
    harnessSource,
    /enabledToolNames = AskReadToolSchemas\.allowedNames \+ enabledActionDefinitions\.map/u,
  );
  assert.ok((modelSource.match(/generateV2\(/gu) ?? []).length >= 4);
});

test("plan-day completes a bounded read-read-read then grounded answer loop for Fast and Pro", () => {
  for (const tier of REMOTE_TIERS) {
    const initial = v2Request(tier, {
      prompt: "Plan my day.",
      catalog: catalog([
        domainEntry("calendar", 3),
        domainEntry("todo", 7),
        domainEntry("codex", 2),
      ]),
      enabledTools: ["query_calendar", "query_todos", "query_codex"],
    });
    validateBoth(initial);
    const firstCalls = [
      functionCall("calendar-1", "query_calendar", readArguments.query_calendar()),
      functionCall("todo-1", "query_todos", readArguments.query_todos()),
      functionCall("codex-1", "query_codex", readArguments.query_codex()),
    ];
    const selected = extractBoth(modelToolResponseForTier(tier, firstCalls), initial);
    assert.equal(selected.kind, "tool_calls");
    assert.equal(selected.calls.length, 3);
    const selectedContinuation = selected.modelContinuation ?? [];
    assert.equal(selectedContinuation.length, tier === "pro" ? 1 : 0);

    const continuationEvidence = [
      evidence("E-calendar", "calendar", "Design sync", "Starts today at 10 AM."),
      evidence("E-todo", "todo", "Send launch update", "Due today at 4 PM."),
      evidence("E-codex", "codex", "Ingestion audit", "State: needs approval."),
    ];
    const continuation = {
      ...initial,
      round: 1,
      toolHistory: [
        receipt("calendar-1", "query_calendar", readArguments.query_calendar(), "query_id=calendar-today matched=1 returned=1 warnings=none evidence_ids=[E-calendar]"),
        receipt("todo-1", "query_todos", readArguments.query_todos(), "query_id=todo-focus matched=1 returned=1 warnings=none evidence_ids=[E-todo]"),
        receipt("codex-1", "query_codex", readArguments.query_codex(), "query_id=codex-active matched=1 returned=1 warnings=none evidence_ids=[E-codex]"),
      ],
      modelContinuation: selectedContinuation,
      evidence: continuationEvidence,
    };
    const validatedWorker = validateBoth(continuation);
    const localRequest = buildLocalRequest(continuation);
    const workerRequest = buildWorkerRequest(
      validatedWorker,
      WORKER_ROUTES[tier],
      "derived-safety-id",
    );
    for (const request of [localRequest, workerRequest]) {
      const packet = packetFromOpenAIRequest(request);
      assert.equal(packet.question, "Plan my day.");
      assert.equal(packet.round, 1);
      assert.equal(packet.remainingToolCallBudget, 5);
      assert.equal(Object.hasOwn(packet, "toolHistory"), false);
      assert.equal(Object.hasOwn(packet, "cumulativeEvidence"), false);

      const replay = request.input.slice(2);
      assert.deepEqual(
        replay.map((item) => item.type),
        tier === "pro"
          ? [
              "reasoning",
              "function_call", "function_call", "function_call",
              "function_call_output", "function_call_output", "function_call_output",
            ]
          : [
              "function_call", "function_call_output",
              "function_call", "function_call_output",
              "function_call", "function_call_output",
            ],
      );
      if (tier === "pro") {
        assert.deepEqual(replay[0], {
          type: "reasoning",
          id: selectedContinuation[0].reasoningID,
          summary: [],
          encrypted_content: selectedContinuation[0].encryptedContent,
        });
      }
      assert.deepEqual(
        replay.filter((item) => item.type === "function_call").map((item) => item.call_id),
        ["calendar-1", "todo-1", "codex-1"],
      );
      assert.deepEqual(
        replay
          .filter((item) => item.type === "function_call_output")
          .flatMap((item) => JSON.parse(item.output).evidence.map((record) => record.id)),
        ["E-calendar", "E-todo", "E-codex"],
      );
    }

    const answer = extractBoth(modelAnswer([
      {
        text: "Keep the 10 AM design sync fixed, then send the launch update before 4 PM.",
        supports: [
          { evidenceID: "E-calendar", excerpt: "Starts today at 10 AM" },
          { evidenceID: "E-todo", excerpt: "Due today at 4 PM" },
        ],
      },
      {
        text: "Review the ingestion audit because it is waiting for approval.",
        supports: [{ evidenceID: "E-codex", excerpt: "needs approval" }],
      },
    ]), continuation);
    assert.equal(answer.kind, "answer");
    assert.equal(answer.claims.length, 2);
  }
});

test("latest-meeting and lexical lookup calls preserve precise model-selected semantics", () => {
  const cases = [
    {
      prompt: "Summarize my latest completed meeting.",
      name: "query_meetings",
      args: readArguments.query_meetings(),
      expected: {
        sort: "occurrenceDesc",
        has_readable_content: true,
        states: ["completed"],
        limit: 1,
      },
    },
    {
      prompt: "Find my launch note.",
      name: "query_notes",
      args: readArguments.query_notes(),
      expected: { text: "launch", sort: "relevanceDesc", content: "preview" },
    },
  ];

  for (const tier of REMOTE_TIERS) {
    for (const scenario of cases) {
      const request = v2Request(tier, {
        prompt: scenario.prompt,
        enabledTools: [scenario.name],
      });
      const result = extractBoth(
        modelToolResponseForTier(
          tier,
          [functionCall(`${tier}-${scenario.name}`, scenario.name, scenario.args)],
        ),
        request,
      );
      assert.equal(result.kind, "tool_calls");
      const forwarded = JSON.parse(result.calls[0].arguments);
      for (const [key, value] of Object.entries(scenario.expected)) {
        assert.deepEqual(forwarded[key], value);
      }
    }
  }
});

test("every action remains a model-selected proposal across the shared tier architecture", () => {
  assert.deepEqual(
    Object.keys(proposalArguments),
    [
      "prepare_create_todo",
      "prepare_create_note",
      "prepare_calendar_event_draft",
      "prepare_codex_task_request",
    ],
  );
  for (const tier of REMOTE_TIERS) {
    for (const [name, args] of Object.entries(proposalArguments)) {
      const request = v2Request(tier, {
        prompt: `Fixture request for ${name}`,
        enabledTools: [name],
      });
      const result = extractBoth(
        modelToolResponseForTier(tier, [functionCall(`${tier}-${name}`, name, args)]),
        request,
      );
      assert.equal(result.protocolVersion, 2);
      assert.equal(result.kind, "tool_calls");
      assert.deepEqual(
        result.calls,
        [{ callID: `${tier}-${name}`, name, arguments: JSON.stringify(args) }],
      );
      assert.equal((result.modelContinuation ?? []).length, tier === "pro" ? 1 : 0);
    }
  }
});

test("successful proposals require one truthful model-authored review message", () => {
  const reviewMessages = {
    prepare_create_todo: "I prepared the to-do for your review.",
    prepare_create_note: "I prepared the note for your review.",
    prepare_calendar_event_draft: "I prepared the calendar draft for your review.",
    prepare_codex_task_request: "I prepared the Codex request for your review.",
  };
  for (const tier of REMOTE_TIERS) {
    for (const [name, args] of Object.entries(proposalArguments)) {
      const initial = v2Request(tier, {
        prompt: `Prepare ${name} for review.`,
        enabledTools: [name],
      });
      const callID = `${tier}-${name}-review`;
      const selected = extractBoth(
        modelToolResponseForTier(tier, [functionCall(callID, name, args)]),
        initial,
      );
      const afterProposal = {
        ...initial,
        round: 1,
        toolHistory: [receipt(
          callID,
          name,
          args,
          "Proposal prepared for native review; nothing was changed. intent_id=fixture",
        )],
        modelContinuation: selected.modelContinuation ?? [],
      };
      validateBoth(afterProposal);
      const message = reviewMessages[name];
      const answer = extractBoth(modelAnswer([], message), afterProposal);
      assert.deepEqual(answer, {
        protocolVersion: 2,
        kind: "answer",
        claims: [],
        actionMessage: message,
      });

      assertBothRejectOutput(modelAnswer([]), afterProposal);
      assertBothRejectOutput(modelAnswer([], "I created it."), afterProposal);
      assertBothRejectOutput(
        modelAnswer([], "I prepared it for review. intent_id=fixture"),
        afterProposal,
      );
    }
  }

  const noProposal = v2Request("fast", { enabledTools: ["query_todos"] });
  assertBothRejectOutput(
    modelAnswer([], "I prepared a to-do for your review."),
    noProposal,
  );
  const failedProposal = {
    ...v2Request("fast", { enabledTools: ["prepare_create_note"] }),
    round: 1,
    toolHistory: [receipt(
      "failed-note",
      "prepare_create_note",
      proposalArguments.prepare_create_note,
      "Proposal not prepared: title is missing. Nothing changed.",
    )],
  };
  assert.deepEqual(extractBoth(modelAnswer([]), failedProposal), {
    protocolVersion: 2,
    kind: "answer",
    claims: [],
  });
  assertBothRejectOutput(
    modelAnswer([], "I prepared the note for your review."),
    failedProposal,
  );
});

test("empty data returns an explicit empty grounded envelope rather than fabricating", () => {
  for (const tier of REMOTE_TIERS) {
    const request = v2Request(tier, {
      catalog: catalog([
        domainEntry("todo"),
        domainEntry("calendar"),
        domainEntry("note"),
        domainEntry("meeting"),
        domainEntry("codex"),
      ]),
      enabledTools: ["query_calendar", "query_todos", "query_codex"],
    });
    const result = extractBoth(modelAnswer([]), request);
    assert.deepEqual(result, { protocolVersion: 2, kind: "answer", claims: [] });
  }
});

test("stale and partial catalogs remain visible while corrupt or cross-snapshot metadata fails closed", () => {
  for (const tier of REMOTE_TIERS) {
    const stale = v2Request(tier, {
      catalog: catalog([
        domainEntry("meeting", 12, {
          availability: "partial",
          availabilityReason: "offline",
          freshness: "stale",
          lastSuccessfulReadAt: "2026-08-10T08:00:00Z",
          coverage: {
            start: "2026-08-01T00:00:00Z",
            end: "2026-08-12T00:00:00Z",
            isCompleteWithinRange: false,
            isTruncated: true,
          },
        }),
      ]),
      enabledTools: ["query_meetings"],
    });
    const normalized = validateBoth(stale);
    const packet = packetFromOpenAIRequest(
      buildWorkerRequest(normalized, WORKER_ROUTES[tier], "derived-safety-id"),
    );
    assert.equal(packet.catalog.domains[0].freshness, "stale");
    assert.equal(packet.catalog.domains[0].availability, "partial");
    assert.equal(packet.catalog.domains[0].coverage.isTruncated, true);

    const wrongClock = clone(stale);
    wrongClock.catalog.temporalContext.contextAsOf = "2026-08-11T08:00:00Z";
    assertBothReject(wrongClock);

    const duplicateDomain = clone(stale);
    duplicateDomain.catalog.domains.push(clone(duplicateDomain.catalog.domains[0]));
    assertBothReject(duplicateDomain);

    const corruptEvidence = clone(stale);
    corruptEvidence.evidence = [
      { ...evidence("E-bad", "meeting", "Bad record", "Content"), updatedAt: "not-a-date" },
    ];
    assertBothReject(corruptEvidence);
  }
});

function evidenceAtCharacterBudget(characterCount) {
  const values = [];
  let remaining = characterCount;
  let index = 0;
  while (remaining > 0) {
    const length = Math.min(1_200, remaining);
    values.push(evidence(`E-${index}`, "note", "", "x".repeat(length)));
    remaining -= length;
    index += 1;
  }
  return values;
}

test("maximum legal context is accepted and every next byte/call is rejected", async () => {
  for (const tier of REMOTE_TIERS) {
    const atEvidenceLimit = v2Request(tier, {
      evidence: evidenceAtCharacterBudget(14_000),
    });
    validateBoth(atEvidenceLimit);
    assert.ok(Buffer.byteLength(JSON.stringify(atEvidenceLimit)) < 64 * 1024);

    const aboveEvidenceLimit = clone(atEvidenceLimit);
    aboveEvidenceLimit.evidence.at(-1).content += "x";
    assertBothReject(aboveEvidenceLimit);

    const eightHistoryItems = Array.from({ length: 8 }, (_, index) =>
      receipt(
        `call-${index}`,
        "query_todos",
        readArguments.query_todos(`query-${index}`),
        `receipt-${index}`,
      ));
    const finalRound = v2Request(tier, {
      round: 3,
      enabledTools: ["query_todos"],
      toolHistory: eightHistoryItems,
      modelContinuation: tier === "pro"
        ? [
            continuation(0, ["call-0", "call-1", "call-2", "call-3"], "budget_0"),
            continuation(1, ["call-4", "call-5", "call-6"], "budget_1"),
            continuation(2, ["call-7"], "budget_2"),
          ]
        : [],
    });
    const normalized = validateBoth(finalRound);
    assert.equal(buildLocalRequest(finalRound).tools, undefined);
    assert.equal(
      buildWorkerRequest(normalized, WORKER_ROUTES[tier], "derived-safety-id").tools,
      undefined,
    );

    const ninthCall = clone(finalRound);
    ninthCall.toolHistory.push(
      receipt("call-8", "query_todos", readArguments.query_todos("query-8"), "receipt-8"),
    );
    assertBothReject(ninthCall);
  }

  const wireLimitHistory = Array.from({ length: 8 }, (_, index) =>
    receipt(
      `wire-call-${index}`,
      "query_todos",
      readArguments.query_todos(`wire-query-${index}`),
      "x",
    ));
  const atWireLimit = v2Request("pro", {
    round: 3,
    prompt: "x".repeat(1_200),
    recentConversation: Array.from({ length: 4 }, (_, index) => ({
      role: index % 2 === 0 ? "user" : "assistant",
      content: "c".repeat(600),
    })),
    enabledTools: ["query_todos"],
    toolHistory: wireLimitHistory,
    evidence: evidenceAtCharacterBudget(14_000),
    modelContinuation: [
      continuation(0, ["wire-call-0", "wire-call-1", "wire-call-2", "wire-call-3"], "wire_0"),
      continuation(1, ["wire-call-4", "wire-call-5", "wire-call-6"], "wire_1"),
      continuation(2, ["wire-call-7"], "wire_2"),
    ],
  });
  let remainingBytes = WORKER_REQUEST_BYTES - Buffer.byteLength(JSON.stringify(atWireLimit));
  assert.ok(remainingBytes > 0, "fixture baseline must leave room to exercise the byte boundary");
  for (const item of atWireLimit.modelContinuation) {
    const available = WORKER_CONTINUATION_BYTES
      - atWireLimit.modelContinuation.reduce(
        (total, value) => total + Buffer.byteLength(value.encryptedContent),
        0,
      );
    const added = Math.min(remainingBytes, available);
    item.encryptedContent += "A".repeat(added);
    remainingBytes -= added;
    if (remainingBytes === 0) break;
  }
  for (const item of atWireLimit.toolHistory) {
    const totalOutput = atWireLimit.toolHistory.reduce(
      (total, value) => total + value.output.length,
      0,
    );
    const added = Math.min(remainingBytes, 24_000 - totalOutput, 12_000 - item.output.length);
    item.output += "x".repeat(added);
    remainingBytes -= added;
    if (remainingBytes === 0) break;
  }
  assert.equal(remainingBytes, 0, "semantic maxima must be able to reach the wire boundary");
  assert.equal(Buffer.byteLength(JSON.stringify(atWireLimit)), WORKER_REQUEST_BYTES);
  validateBoth(atWireLimit);

  const oneWireByteTooMany = clone(atWireLimit);
  oneWireByteTooMany.toolHistory.at(-1).output += "x";
  assert.equal(Buffer.byteLength(JSON.stringify(oneWireByteTooMany)), WORKER_REQUEST_BYTES + 1);
  assert.throws(() => validateLocalRequest(oneWireByteTooMany));
  let upstreamDispatches = 0;
  const worker = createWorker({
    fetchImpl: async () => {
      upstreamDispatches += 1;
      return new Response();
    },
    now: () => NOW_MS,
  });
  const tooLargeResponse = await worker.fetch(
    await workerAskRequest(oneWireByteTooMany, "wire-limit-token"),
    workerRuntimeEnv(),
  );
  assert.equal(tooLargeResponse.status, 413);
  assert.deepEqual(await tooLargeResponse.json(), { error: "request_too_large" });
  assert.equal(upstreamDispatches, 0);
});

test("multiple rounds are stateless, bounded, and cannot replay call or query identities", () => {
  for (const tier of REMOTE_TIERS) {
    const first = v2Request(tier, { enabledTools: ["query_todos", "query_notes"] });
    const firstResult = extractBoth(
      modelToolResponseForTier(
        tier,
        [functionCall("read-1", "query_todos", readArguments.query_todos("q-1"))],
      ),
      first,
    );
    const second = {
      ...first,
      round: 1,
      toolHistory: [
        receipt("read-1", "query_todos", readArguments.query_todos("q-1"), "query_id=q-1 matched=1 returned=1 warnings=none evidence_ids=[E-1]"),
      ],
      modelContinuation: firstResult.modelContinuation ?? [],
      evidence: [evidence("E-1", "todo", "Launch update", "Status: open")],
    };
    const refinement = extractBoth(
      modelToolResponseForTier(
        tier,
        [functionCall("read-2", "query_notes", readArguments.query_notes("q-2"))],
        1,
      ),
      second,
    );
    assert.equal(refinement.calls[0].callID, "read-2");

    assertBothRejectOutput(
      modelToolResponseForTier(
        tier,
        [functionCall("read-1", "query_notes", readArguments.query_notes("q-3"))],
        1,
      ),
      second,
    );
    assertBothRejectOutput(
      modelToolResponseForTier(
        tier,
        [functionCall("read-3", "query_notes", readArguments.query_notes("q-1"))],
        1,
      ),
      second,
    );

    const third = {
      ...second,
      round: 2,
      toolHistory: [
        ...second.toolHistory,
        receipt("read-2", "query_notes", readArguments.query_notes("q-2"), "query_id=q-2 matched=1 returned=1 warnings=none evidence_ids=[E-2]"),
      ],
      modelContinuation: refinement.modelContinuation ?? [],
      evidence: [
        ...second.evidence,
        evidence("E-2", "note", "Launch checklist", "Gabby owns final approval."),
      ],
    };
    const answer = extractBoth(modelAnswer([{
      text: "The launch update remains open, and Gabby owns final approval.",
      supports: [
        { evidenceID: "E-1", excerpt: "Status: open" },
        { evidenceID: "E-2", excerpt: "Gabby owns final approval" },
      ],
    }]), third);
    assert.equal(answer.kind, "answer");
  }
});

test("model continuation is exact, opaque, bounded, and backward-compatible where allowed", () => {
  assert.equal(WORKER_CONTINUATION_COUNT, 3);
  assert.equal(WORKER_CONTINUATION_BYTES, 24 * 1024);

  const fastInitial = v2Request("fast", {
    enabledTools: ["query_todos", "query_notes"],
  });
  const fastWithoutOptionalField = clone(fastInitial);
  delete fastWithoutOptionalField.modelContinuation;
  validateBoth(fastWithoutOptionalField);
  const fastCalls = [
    functionCall("fast-read-1", "query_todos", readArguments.query_todos("fast-q-1")),
  ];
  const fastResult = extractBoth(modelToolResponse(fastCalls), fastWithoutOptionalField);
  assert.deepEqual(fastResult.modelContinuation ?? [], []);

  const proInitial = v2Request("pro", {
    enabledTools: ["query_todos", "query_notes"],
  });
  const proCalls = [
    functionCall("pro-read-1", "query_todos", readArguments.query_todos("pro-q-1")),
    functionCall("pro-read-2", "query_notes", readArguments.query_notes("pro-q-2")),
  ];
  assertBothRejectOutput(modelToolResponse(proCalls), proInitial);

  const opaque = reasoningItem("rs_exact_round_zero", "opaque_round_zero_AA==");
  const proResult = extractBoth(modelToolResponse(proCalls, opaque), proInitial);
  assert.deepEqual(proResult.modelContinuation, [{
    round: 0,
    callIDs: ["pro-read-1", "pro-read-2"],
    reasoningID: "rs_exact_round_zero",
    encryptedContent: "opaque_round_zero_AA==",
  }]);

  const proNext = {
    ...proInitial,
    round: 1,
    toolHistory: [
      receipt(
        "pro-read-1",
        "query_todos",
        readArguments.query_todos("pro-q-1"),
        "query_id=pro-q-1 matched=1 returned=1 warnings=none evidence_ids=[E-pro-1]",
      ),
      receipt(
        "pro-read-2",
        "query_notes",
        readArguments.query_notes("pro-q-2"),
        "query_id=pro-q-2 matched=1 returned=1 warnings=none evidence_ids=[E-pro-2]",
      ),
    ],
    modelContinuation: proResult.modelContinuation,
    evidence: [
      evidence("E-pro-1", "todo", "Launch", "Status: open"),
      evidence("E-pro-2", "note", "Launch", "Owner: Gabby"),
    ],
  };
  const normalizedProNext = validateBoth(proNext);
  for (const request of [
    buildLocalRequest(proNext),
    buildWorkerRequest(normalizedProNext, WORKER_ROUTES.pro, "derived-safety-id"),
  ]) {
    assert.deepEqual(request.input.slice(2).map((item) => item.type), [
      "reasoning",
      "function_call", "function_call",
      "function_call_output", "function_call_output",
    ]);
    assert.deepEqual(request.input[2], {
      type: "reasoning",
      id: "rs_exact_round_zero",
      summary: [],
      encrypted_content: "opaque_round_zero_AA==",
    });
    assert.deepEqual(
      request.input.filter((item) => item.type === "function_call").map((item) => item.call_id),
      ["pro-read-1", "pro-read-2"],
    );
    assert.deepEqual(
      request.input.filter((item) => item.type === "function_call_output").map((item) => item.call_id),
      ["pro-read-1", "pro-read-2"],
    );
  }

  const malformedRequests = [];
  const malformed = (mutate) => {
    const value = clone(proNext);
    mutate(value);
    malformedRequests.push(value);
  };
  malformed((value) => { value.modelContinuation[0].round = 1; });
  malformed((value) => { value.modelContinuation[0].callIDs.reverse(); });
  malformed((value) => { value.modelContinuation[0].callIDs.pop(); });
  malformed((value) => { value.modelContinuation[0].reasoningID = "not_rs_reasoning"; });
  malformed((value) => { value.modelContinuation[0].reasoningID = `rs_${"x".repeat(118)}`; });
  malformed((value) => { value.modelContinuation[0].encryptedContent = "contains whitespace"; });
  malformed((value) => {
    value.modelContinuation[0].encryptedContent = "A".repeat(WORKER_CONTINUATION_BYTES + 1);
  });
  malformed((value) => {
    value.modelContinuation[0].unknown = "schema-drift";
  });
  for (const request of malformedRequests) assertBothReject(request);

  const continuationLimit = v2Request("pro", {
    round: 3,
    enabledTools: ["query_todos"],
    toolHistory: [0, 1, 2].map((index) =>
      receipt(
        `continuation-call-${index}`,
        "query_todos",
        readArguments.query_todos(`continuation-query-${index}`),
        `returned continuation evidence ${index}`,
      )),
    modelContinuation: [0, 1, 2].map((round) => ({
      round,
      callIDs: [`continuation-call-${round}`],
      reasoningID: `rs_continuation_limit_${round}`,
      encryptedContent: "A".repeat(WORKER_CONTINUATION_BYTES / 3),
    })),
  });
  validateBoth(continuationLimit);
  const tooManyContinuations = clone(continuationLimit);
  tooManyContinuations.modelContinuation.push(clone(continuationLimit.modelContinuation[2]));
  assertBothReject(tooManyContinuations);
  const duplicateContinuationRound = clone(continuationLimit);
  duplicateContinuationRound.modelContinuation[1].round = 0;
  assertBothReject(duplicateContinuationRound);
  const descendingContinuationRounds = clone(continuationLimit);
  [
    descendingContinuationRounds.modelContinuation[0],
    descendingContinuationRounds.modelContinuation[1],
  ] = [
    descendingContinuationRounds.modelContinuation[1],
    descendingContinuationRounds.modelContinuation[0],
  ];
  assertBothReject(descendingContinuationRounds);
  const aggregateOversize = clone(continuationLimit);
  aggregateOversize.modelContinuation[2].encryptedContent += "A";
  assertBothReject(aggregateOversize);

  const malformedResponses = [
    modelToolResponse(proCalls, { ...opaque, summary: [{ type: "summary_text", text: "leak" }] }),
    modelToolResponse(proCalls, { ...opaque, id: "bad-id" }),
    modelToolResponse(proCalls, { ...opaque, encrypted_content: "contains whitespace" }),
    modelToolResponse(
      proCalls,
      reasoningItem("rs_oversize", "A".repeat(WORKER_CONTINUATION_BYTES + 1)),
    ),
    {
      status: "completed",
      output: [
        reasoningItem("rs_first", "opaque_first_AA=="),
        reasoningItem("rs_second", "opaque_second_AA=="),
        ...proCalls,
      ],
    },
  ];
  for (const response of malformedResponses) assertBothRejectOutput(response, proInitial);
});

test("malformed, unallowlisted, over-batched, refused, and unsupported model output fails closed", () => {
  const base = v2Request("fast", {
    enabledTools: ["query_todos", "prepare_create_todo", "prepare_create_note"],
  });
  const malformedCases = [
    { status: "incomplete", output: [] },
    modelToolResponse([{
      type: "function_call",
      call_id: "bad-json",
      name: "query_todos",
      arguments: "{",
    }]),
    modelToolResponse([functionCall("unknown", "delete_everything", {})]),
    modelToolResponse([
      functionCall("duplicate", "query_todos", readArguments.query_todos("q-a")),
      functionCall("duplicate", "query_todos", readArguments.query_todos("q-b")),
    ]),
    modelToolResponse([
      functionCall("proposal-a", "prepare_create_todo", proposalArguments.prepare_create_todo),
      functionCall("proposal-b", "prepare_create_note", proposalArguments.prepare_create_note),
    ]),
    {
      status: "completed",
      output: [{ type: "message", content: [{ type: "refusal", refusal: "no" }] }],
    },
  ];
  for (const response of malformedCases) assertBothRejectOutput(response, base);

  const grounded = {
    ...base,
    evidence: [evidence("E1", "todo", "Launch", "Due today at 4 PM")],
  };
  assertBothRejectOutput(modelAnswer([{
    text: "Launch tomorrow.",
    supports: [{ evidenceID: "E1", excerpt: "tomorrow" }],
  }]), grounded);
});

test("read and action schema drift is rejected before an upstream model call", () => {
  for (const tier of REMOTE_TIERS) {
    for (const field of ["toolSchemaVersion", "toolSchemaDigest", "actionToolSchemaVersion", "actionToolSchemaDigest"]) {
      const drifted = v2Request(tier);
      drifted[field] = field.endsWith("Version") ? 999 : "0".repeat(64);
      assertBothReject(drifted);
    }
  }
});

async function localRelayStatus(upstream) {
  const relay = createAskIAgentRelay({
    apiKey: "not-a-real-key",
    fetchImpl: upstream,
    logger: { log() {}, error() {} },
  });
  await new Promise((resolve) => relay.listen(0, "127.0.0.1", resolve));
  try {
    const address = relay.address();
    const response = await fetch(`http://127.0.0.1:${address.port}/ask`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "X-iAgent-Relay-Protocol": "2",
      },
      body: JSON.stringify(v2Request("fast")),
    });
    const result = { status: response.status, body: await response.json() };
    const retryAfter = response.headers.get("Retry-After");
    return retryAfter === null ? result : { ...result, retryAfter };
  } finally {
    await new Promise((resolve) => relay.close(resolve));
  }
}

test("relay status boundaries preserve rate limits, availability failures, and invalid model output", async () => {
  const cases = [
    {
      label: "upstream authentication/configuration",
      upstream: async () => new Response(JSON.stringify({ error: { type: "authentication_error" } }), {
        status: 401,
        headers: { "Content-Type": "application/json" },
      }),
      expected: { status: 503, body: { error: "upstream_unavailable" } },
    },
    {
      label: "upstream rate limit",
      upstream: async () => new Response(JSON.stringify({ error: { type: "rate_limit" } }), {
        status: 429,
        headers: { "Content-Type": "application/json", "Retry-After": "17" },
      }),
      expected: {
        status: 429,
        body: { error: "upstream_rate_limited" },
        retryAfter: "17",
      },
    },
    {
      label: "upstream server failure",
      upstream: async () => new Response(JSON.stringify({ error: { type: "server_error" } }), {
        status: 500,
        headers: { "Content-Type": "application/json" },
      }),
      expected: { status: 503, body: { error: "upstream_unavailable" } },
    },
    {
      label: "network failure",
      upstream: async () => { throw new TypeError("offline"); },
      expected: { status: 503, body: { error: "relay_unavailable" } },
    },
    {
      label: "malformed model call",
      upstream: async () => new Response(JSON.stringify({
        status: "completed",
        output: [functionCall("bad", "delete_everything", {})],
      }), { status: 200, headers: { "Content-Type": "application/json" } }),
      expected: { status: 502, body: { error: "invalid_upstream_output" } },
    },
  ];
  for (const scenario of cases) {
    let dispatchCount = 0;
    const actual = await localRelayStatus((...args) => {
      dispatchCount += 1;
      return scenario.upstream(...args);
    });
    assert.deepEqual(actual, scenario.expected, scenario.label);
    assert.equal(dispatchCount, 1, `${scenario.label} must dispatch upstream exactly once`);
  }
});

test("client cancellation aborts the in-flight local transport exactly once", async () => {
  let dispatchCount = 0;
  let upstreamSignal;
  let markStarted;
  const started = new Promise((resolve) => { markStarted = resolve; });
  const relay = createAskIAgentRelay({
    apiKey: "not-a-real-key",
    fetchImpl: async (_url, options) => {
      dispatchCount += 1;
      upstreamSignal = options.signal;
      markStarted();
      return new Promise((_resolve, reject) => {
        const fail = () => reject(
          upstreamSignal.reason ?? new DOMException("Aborted", "AbortError"),
        );
        if (upstreamSignal.aborted) fail();
        else upstreamSignal.addEventListener("abort", fail, { once: true });
      });
    },
    logger: { log() {}, error() {} },
  });
  await new Promise((resolve) => relay.listen(0, "127.0.0.1", resolve));
  try {
    const client = new AbortController();
    const address = relay.address();
    const pending = fetch(`http://127.0.0.1:${address.port}/ask`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "X-iAgent-Relay-Protocol": "2",
      },
      body: JSON.stringify(v2Request("fast")),
      signal: client.signal,
    });
    await started;
    client.abort(new DOMException("User stopped the turn.", "AbortError"));
    await assert.rejects(pending, (error) => error?.name === "AbortError");
    await new Promise((resolve) => setTimeout(resolve, 10));
    assert.equal(dispatchCount, 1);
    assert.equal(upstreamSignal.aborted, true);
    assert.equal(upstreamSignal.reason?.name, "AbortError");
  } finally {
    relay.closeAllConnections?.();
    await new Promise((resolve) => relay.close(resolve));
  }
});

class AlwaysAvailableLimiterNamespace {
  idFromName(value) { return value; }

  get() {
    return {
      fetch: async () => new Response(JSON.stringify({ ok: true }), {
        status: 200,
        headers: { "Content-Type": "application/json" },
      }),
    };
  }
}

function workerRuntimeEnv() {
  return {
    SERVICE_ENABLED: "true",
    ATTESTATION_EXCHANGE_ENABLED: "true",
    PRICING_CONFIGURED: "true",
    ENABLED_TIERS: "fast,pro",
    TOKEN_ISSUER: "iagent-anonymous-attestation",
    TOKEN_AUDIENCE: "ask-iagent-relay",
    TOKEN_MAX_TTL_SECONDS: "600",
    CHALLENGE_TTL_SECONDS: "120",
    CHALLENGE_REQUESTS_PER_MINUTE: "6",
    ATTESTATION_GLOBAL_REQUESTS_PER_MINUTE: "30",
    ATTESTATION_NETWORK_REQUESTS_PER_MINUTE: "4",
    APP_ATTEST_TEAM_IDENTIFIER: "625CGY297X",
    APP_ATTEST_BUNDLE_IDENTIFIER: "com.platon.iagent.mobile",
    APP_ATTEST_ALLOWED_ENVIRONMENTS: "production",
    APP_ATTEST_ALLOWED_VALIDATION_CATEGORIES: "2,4",
    APP_ATTEST_ALLOWED_BUNDLE_VERSIONS: "26,27",
    APP_ATTEST_REQUIRE_IOS27_SIGNALS: "false",
    DEVICECHECK_FALLBACK_ENABLED: "false",
    DEVICECHECK_ENVIRONMENT: "production",
    DEVICECHECK_REPLAY_TTL_SECONDS: "86400",
    REQUESTS_PER_MINUTE: "6",
    MAX_CONCURRENT_REQUESTS: "2",
    DAILY_SPEND_LIMIT_MICRODOLLARS: "1000000",
    DEVICECHECK_ENABLED_TIERS: "fast",
    DEVICECHECK_REQUESTS_PER_MINUTE: "2",
    DEVICECHECK_MAX_CONCURRENT_REQUESTS: "1",
    DEVICECHECK_DAILY_SPEND_LIMIT_MICRODOLLARS: "150000",
    RESERVATION_LEASE_MILLISECONDS: "300000",
    FAST_INPUT_MICRODOLLARS_PER_MILLION: "1000000",
    FAST_CACHED_INPUT_MICRODOLLARS_PER_MILLION: "100000",
    FAST_CACHE_WRITE_MICRODOLLARS_PER_MILLION: "1250000",
    FAST_OUTPUT_MICRODOLLARS_PER_MILLION: "6000000",
    PRO_INPUT_MICRODOLLARS_PER_MILLION: "5000000",
    PRO_CACHED_INPUT_MICRODOLLARS_PER_MILLION: "500000",
    PRO_CACHE_WRITE_MICRODOLLARS_PER_MILLION: "6250000",
    PRO_OUTPUT_MICRODOLLARS_PER_MILLION: "30000000",
    OPENAI_API_KEY: "test-openai-key-not-a-real-secret",
    ANONYMOUS_TOKEN_HMAC_KEY: "token-key-that-is-at-least-thirty-two-bytes-long",
    SAFETY_IDENTIFIER_HMAC_KEY: "safety-key-that-is-at-least-thirty-two-bytes-long",
    INSTALLATION_LIMITER: new AlwaysAvailableLimiterNamespace(),
    ATTESTATION_STATE: { idFromName(value) { return value; } },
  };
}

async function workerAskRequest(body, tokenID) {
  const encoded = JSON.stringify(body);
  const requestHash = await sha256Base64URL(new TextEncoder().encode(encoded));
  const token = await createLocalAnonymousToken(
    "installation_0123456789abcdefghijk",
    requestHash,
    {
      tokenHMACKey: workerRuntimeEnv().ANONYMOUS_TOKEN_HMAC_KEY,
      tokenIssuer: "iagent-anonymous-attestation",
      tokenAudience: "ask-iagent-relay",
      tokenMaxTTLSeconds: 600,
    },
    { now: NOW_MS, ttlSeconds: 300, tokenID },
  );
  return new Request("https://relay.example/v1/ask", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${token}`,
      "Content-Type": "application/json",
      "X-iAgent-Relay-Protocol": "2",
    },
    body: encoded,
  });
}

test("production Worker distinguishes client auth, upstream 429/5xx, and transport failure", async () => {
  const requestWithoutAuth = new Request("https://relay.example/v1/ask", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "X-iAgent-Relay-Protocol": "2",
    },
    body: JSON.stringify(v2Request("fast")),
  });
  const noAuthWorker = createWorker({
    fetchImpl: async () => assert.fail("unauthenticated request must not reach upstream"),
    now: () => NOW_MS,
  });
  const unauthorized = await noAuthWorker.fetch(requestWithoutAuth, workerRuntimeEnv());
  assert.equal(unauthorized.status, 401);
  assert.deepEqual(await unauthorized.json(), { error: "unauthorized" });

  const cases = [
    {
      upstream: async () => new Response(JSON.stringify({ error: { type: "rate_limit" } }), {
        status: 429,
        headers: { "Content-Type": "application/json", "Retry-After": "23" },
      }),
      expected: {
        status: 429,
        body: { error: "upstream_rate_limited" },
        retryAfter: "23",
      },
    },
    {
      upstream: async () => new Response(JSON.stringify({ error: { type: "server_error" } }), {
        status: 500,
        headers: { "Content-Type": "application/json" },
      }),
      expected: { status: 503, body: { error: "upstream_unavailable" } },
    },
    {
      upstream: async () => { throw new TypeError("offline"); },
      expected: { status: 503, body: { error: "service_unavailable" } },
    },
  ];
  for (const [index, scenario] of cases.entries()) {
    let dispatchCount = 0;
    const worker = createWorker({
      fetchImpl: (...args) => {
        dispatchCount += 1;
        return scenario.upstream(...args);
      },
      now: () => NOW_MS,
    });
    const response = await worker.fetch(
      await workerAskRequest(v2Request("fast"), `reliability-token-${index}`),
      workerRuntimeEnv(),
    );
    assert.equal(response.status, scenario.expected.status);
    assert.deepEqual(await response.json(), scenario.expected.body);
    assert.equal(response.headers.get("Retry-After"), scenario.expected.retryAfter ?? null);
    assert.equal(dispatchCount, 1);
  }
});

class MemoryStorage {
  values = new Map();

  async get(key) { return this.values.get(key); }
  async put(key, value) { this.values.set(key, structuredClone(value)); }
  async delete(key) { this.values.delete(key); }
  async deleteAll() { this.values.clear(); }
  async setAlarm(value) { this.alarm = value; }
  async deleteAlarm() { this.alarm = undefined; }
}

function attestationEnv() {
  return {
    ATTESTATION_STATE: { idFromName(value) { return value; } },
    APP_ATTEST_TEAM_IDENTIFIER: "625CGY297X",
    APP_ATTEST_BUNDLE_IDENTIFIER: "com.platon.iagent.mobile",
    APP_ATTEST_ALLOWED_ENVIRONMENTS: "production",
    APP_ATTEST_ALLOWED_VALIDATION_CATEGORIES: "2,4",
    APP_ATTEST_ALLOWED_BUNDLE_VERSIONS: "26,27",
    APP_ATTEST_REQUIRE_IOS27_SIGNALS: "false",
    ANONYMOUS_TOKEN_HMAC_KEY: "token-key-that-is-at-least-thirty-two-bytes-long",
    TOKEN_ISSUER: "iagent-anonymous-attestation",
    TOKEN_AUDIENCE: "ask-iagent-relay",
    TOKEN_MAX_TTL_SECONDS: "600",
    CHALLENGE_TTL_SECONDS: "120",
    CHALLENGE_REQUESTS_PER_MINUTE: "6",
    ATTESTATION_GLOBAL_REQUESTS_PER_MINUTE: "30",
    ATTESTATION_NETWORK_REQUESTS_PER_MINUTE: "4",
    DEVICECHECK_FALLBACK_ENABLED: "false",
    DEVICECHECK_REPLAY_TTL_SECONDS: "86400",
  };
}

test("App Attest cancel then retry supersedes the abandoned challenge without enabling replay", async () => {
  const storage = new MemoryStorage();
  const state = new AttestationState({ storage }, attestationEnv());
  const keyID = `${"A".repeat(43)}=`;
  const base = {
    protocolVersion: 1,
    assurance: "app_attest",
    installationID: "installation_0123456789abcdefghijk",
    keyID,
  };
  const challengeRequest = (requestHash, now) => new Request("https://state/challenge", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ ...base, requestHash, now }),
  });

  const abandonedResponse = await state.fetch(challengeRequest("a".repeat(43), NOW_MS));
  assert.equal(abandonedResponse.status, 200);
  const abandoned = await abandonedResponse.json();

  const retryResponse = await state.fetch(challengeRequest("b".repeat(43), NOW_MS + 1));
  assert.equal(retryResponse.status, 200);
  const retry = await retryResponse.json();
  assert.notEqual(retry.challengeID, abandoned.challengeID);
  assert.equal((await storage.get("activeChallenge")).id, retry.challengeID);

  const staleExchange = await state.fetch(new Request("https://state/exchange", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      ...base,
      challengeID: abandoned.challengeID,
      artifactType: "attestation",
      artifact: Buffer.from("stale-artifact").toString("base64"),
      now: NOW_MS + 2,
    }),
  }));
  assert.equal(staleExchange.status, 401);
  assert.equal((await storage.get("activeChallenge")).id, retry.challengeID);
  assert.equal((await storage.get("activeChallenge")).consumed, false);
});
