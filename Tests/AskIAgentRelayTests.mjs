import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

import {
  V2_ACTION_TOOL_SCHEMA_DIGEST,
  V2_ACTION_TOOL_SCHEMA_VERSION,
  V2_TOOL_SCHEMA_DIGEST,
  V2_TOOL_SCHEMA_VERSION,
  buildOpenAIRequest,
  createAskIAgentRelay,
  extractStructuredClaims,
  extractV2RelayResult,
  routeForClientRequest,
} from "../Scripts/ask-iagent-openai-relay.mjs";
import {
  V2_ACTION_TOOL_SCHEMA_DIGEST as WORKER_ACTION_TOOL_SCHEMA_DIGEST,
  V2_ACTION_TOOL_SCHEMA_VERSION as WORKER_ACTION_TOOL_SCHEMA_VERSION,
} from "../Workers/AskIAgentRelay/src/contract.mjs";

function clientRequest(tier = "fast") {
  const isPro = tier === "pro";
  return {
    protocolVersion: 1,
    tier,
    model: isPro ? "gpt-5.6-sol" : "gpt-5.6-luna",
    reasoning: isPro ? { mode: "pro", effort: "medium" } : { effort: "low" },
    prompt: "What should I focus on today?",
    contextAsOf: "2026-08-08T08:00:00Z",
    localeIdentifier: "en_US",
    safetyIdentifier: "test-user",
    recentConversation: [],
    evidence: [
      {
        id: "E1",
        source: "todo",
        title: "Send the launch update",
        revision: "r1",
        updatedAt: "2026-08-08T07:00:00Z",
        content: "Due today at 4 PM. Status: open.",
      },
    ],
    research: { intent: "plan", resolvedQuery: "today priorities", coverage: [], catalog: {} },
  };
}

function catalog() {
  return {
    version: 2,
    snapshotID: "snapshot-1",
    temporalContext: {
      contextAsOf: "2026-08-08T08:00:00Z",
      timeZoneIdentifier: "Europe/Athens",
      localeIdentifier: "en_US",
      calendarIdentifier: "gregorian",
      firstWeekday: 2,
    },
    domains: [
      {
        domain: "todo",
        availability: "available",
        availabilityReason: "none",
        recordCount: 3,
        observedAt: "2026-08-08T08:00:00Z",
        lastSuccessfulReadAt: "2026-08-08T08:00:00Z",
        freshness: "current",
        coverage: {
          start: null,
          end: null,
          isCompleteWithinRange: true,
          isTruncated: false,
        },
      },
    ],
  };
}

function todoArguments(queryID = "todo-1") {
  return JSON.stringify({
    query_id: queryID,
    text: null,
    record_ids: [],
    states: ["open"],
    starred: null,
    due: "any",
    list_names: [],
    sort: "attentionDesc",
    content: "preview",
    time: { field: "due", preset: "today", start: null, end: null },
    limit: 5,
    cursor: null,
  });
}

function v2ClientRequest(tier = "fast") {
  const base = clientRequest(tier);
  return {
    protocolVersion: 2,
    tier: base.tier,
    model: base.model,
    reasoning: base.reasoning,
    round: 0,
    prompt: base.prompt,
    contextAsOf: base.contextAsOf,
    localeIdentifier: base.localeIdentifier,
    safetyIdentifier: base.safetyIdentifier,
    recentConversation: [],
    catalog: catalog(),
    enabledTools: ["query_todos", "prepare_create_todo"],
    toolHistory: [],
    evidence: [],
    toolSchemaVersion: V2_TOOL_SCHEMA_VERSION,
    toolSchemaDigest: V2_TOOL_SCHEMA_DIGEST,
    actionToolSchemaVersion: V2_ACTION_TOOL_SCHEMA_VERSION,
    actionToolSchemaDigest: V2_ACTION_TOOL_SCHEMA_DIGEST,
  };
}

test("maps Fast and Pro to the exact allowlisted model settings", () => {
  assert.equal(routeForClientRequest(clientRequest("fast")).model, "gpt-5.6-luna");
  assert.deepEqual(buildOpenAIRequest(clientRequest("fast")).reasoning, { effort: "low" });
  assert.equal(routeForClientRequest(clientRequest("pro")).model, "gpt-5.6-sol");
  assert.deepEqual(buildOpenAIRequest(clientRequest("pro")).reasoning, {
    mode: "pro",
    effort: "medium",
  });
});

test("keeps the native, local relay, and Worker action schema identities identical", () => {
  const nativeSource = readFileSync(
    new URL("../Sources/iAgentActionContracts/ActionProposalValidator.swift", import.meta.url),
    "utf8",
  );
  const nativeVersion = nativeSource.match(/public static let schemaVersion = (\d+)/u)?.[1];
  const nativeDigest = nativeSource.match(
    /public static let schemaDigest\s*=\s*"([a-f0-9]{64})"/u,
  )?.[1];

  assert.equal(Number(nativeVersion), V2_ACTION_TOOL_SCHEMA_VERSION);
  assert.equal(nativeDigest, V2_ACTION_TOOL_SCHEMA_DIGEST);
  assert.equal(WORKER_ACTION_TOOL_SCHEMA_VERSION, V2_ACTION_TOOL_SCHEMA_VERSION);
  assert.equal(WORKER_ACTION_TOOL_SCHEMA_DIGEST, V2_ACTION_TOOL_SCHEMA_DIGEST);
});

test("rejects client attempts to select another model", () => {
  const request = clientRequest("fast");
  request.model = "gpt-5.6-sol";
  assert.throws(() => routeForClientRequest(request), /Unsupported model route/);
});

test("extracts structured output from a raw Responses API message", () => {
  const claims = {
    claims: [
      {
        text: "Send the launch update before 4 PM.",
        supports: [{ evidenceID: "E1", excerpt: "Due today at 4 PM" }],
      },
    ],
  };
  const result = extractStructuredClaims({
    output: [
      {
        type: "message",
        content: [{ type: "output_text", text: JSON.stringify(claims) }],
      },
    ],
  });
  assert.deepEqual(result, claims);
});

test("builds a stateless V2 tool round from the catalog and fixed allowlist", () => {
  const request = v2ClientRequest("fast");
  const upstream = buildOpenAIRequest(request);
  assert.equal(upstream.model, "gpt-5.6-luna");
  assert.equal(upstream.store, false);
  assert.equal(upstream.tool_choice, "auto");
  assert.deepEqual(upstream.tools.map((tool) => tool.name), [
    "query_todos",
    "prepare_create_todo",
  ]);
  assert.ok(upstream.tools.every((tool) => tool.strict === true));
  const packet = JSON.parse(upstream.input[1].content.split("\n\n").at(-1));
  assert.equal(packet.round, 0);
  assert.equal(packet.remainingToolCallBudget, 8);
  assert.equal(packet.toolHistory, undefined);
  assert.equal(packet.cumulativeEvidence, undefined);
  assert.equal(packet.catalog.snapshotID, "snapshot-1");
});

test("replays only the bounded stateless receipt packet and forces an answer at round three", () => {
  const request = v2ClientRequest("pro");
  request.round = 3;
  request.toolHistory = [1, 2, 3].map((value) => ({
    callID: `call-${value}`,
    name: "query_todos",
    arguments: todoArguments(`todo-${value}`),
    output: `query_id=todo-${value} matched=1 returned=1 warnings=none evidence_ids=[E${value}]`,
  }));
  request.evidence = request.toolHistory.map((_, index) => ({
    id: `E${index + 1}`,
    source: "todo",
    title: `Todo ${index + 1}`,
    revision: `r${index + 1}`,
    updatedAt: "2026-08-08T08:00:00Z",
    content: "Status: open.",
  }));
  request.modelContinuation = [1, 2, 3].map((value, index) => ({
    round: index,
    callIDs: [`call-${value}`],
    reasoningID: `rs_round_${value}`,
    encryptedContent: Buffer.from(`reasoning-${value}`).toString("base64"),
  }));
  const upstream = buildOpenAIRequest(request);
  assert.equal(upstream.model, "gpt-5.6-sol");
  assert.equal(upstream.tools, undefined);
  assert.equal(upstream.tool_choice, undefined);
  assert.deepEqual(upstream.input.slice(2).map((item) => [item.type, item.call_id || item.id]), [
    ["reasoning", "rs_round_1"],
    ["function_call", "call-1"],
    ["function_call_output", "call-1"],
    ["reasoning", "rs_round_2"],
    ["function_call", "call-2"],
    ["function_call_output", "call-2"],
    ["reasoning", "rs_round_3"],
    ["function_call", "call-3"],
    ["function_call_output", "call-3"],
  ]);
  const packet = JSON.parse(upstream.input[1].content.split("\n\n").at(-1));
  assert.equal(packet.round, 3);
  assert.equal(packet.toolHistory, undefined);
  assert.equal(packet.cumulativeEvidence, undefined);
  assert.deepEqual(JSON.parse(upstream.input[4].output).evidence.map((item) => item.id), ["E1"]);
});

test("extracts bounded V2 tool calls without executing them", () => {
  const request = v2ClientRequest();
  const result = extractV2RelayResult(
    {
      status: "completed",
      output: [
        {
          type: "function_call",
          call_id: "call-1",
          name: "query_todos",
          arguments: todoArguments(),
        },
      ],
    },
    request,
  );
  assert.deepEqual(result, {
    protocolVersion: 2,
    kind: "tool_calls",
    calls: [{ callID: "call-1", name: "query_todos", arguments: todoArguments() }],
  });
});

test("carries Pro encrypted reasoning across the exact function-call group", () => {
  const firstRound = v2ClientRequest("pro");
  const encryptedContent = Buffer.from("opaque-model-state").toString("base64");
  const result = extractV2RelayResult(
    {
      status: "completed",
      output: [
        {
          type: "reasoning",
          id: "rs_round_zero",
          summary: [],
          encrypted_content: encryptedContent,
        },
        {
          type: "function_call",
          call_id: "call-1",
          name: "query_todos",
          arguments: todoArguments("todo-1"),
        },
        {
          type: "function_call",
          call_id: "call-2",
          name: "query_todos",
          arguments: todoArguments("todo-2"),
        },
      ],
    },
    firstRound,
  );
  assert.deepEqual(result.modelContinuation, [{
    round: 0,
    callIDs: ["call-1", "call-2"],
    reasoningID: "rs_round_zero",
    encryptedContent,
  }]);

  const replay = v2ClientRequest("pro");
  replay.round = 1;
  replay.toolHistory = result.calls.map((call, index) => ({
    ...call,
    output: `query_id=todo-${index + 1} matched=0 returned=0 warnings=none evidence_ids=[]`,
  }));
  replay.modelContinuation = result.modelContinuation;
  const upstream = buildOpenAIRequest(replay);
  assert.deepEqual(upstream.input.slice(2), [
    {
      type: "reasoning",
      id: "rs_round_zero",
      summary: [],
      encrypted_content: encryptedContent,
    },
    {
      type: "function_call",
      call_id: "call-1",
      name: "query_todos",
      arguments: todoArguments("todo-1"),
    },
    {
      type: "function_call",
      call_id: "call-2",
      name: "query_todos",
      arguments: todoArguments("todo-2"),
    },
    {
      type: "function_call_output",
      call_id: "call-1",
      output: JSON.stringify({
        receipt: "query_id=todo-1 matched=0 returned=0 warnings=none evidence_ids=[]",
        evidence: [],
      }),
    },
    {
      type: "function_call_output",
      call_id: "call-2",
      output: JSON.stringify({
        receipt: "query_id=todo-2 matched=0 returned=0 warnings=none evidence_ids=[]",
        evidence: [],
      }),
    },
  ]);
});

test("forwards repairable proposal arguments to the native validator", () => {
  const request = v2ClientRequest();
  request.enabledTools = ["prepare_create_note"];
  const incompleteArguments = JSON.stringify({ title: "Bitcoin bull case" });
  const result = extractV2RelayResult(
    {
      status: "completed",
      output: [
        {
          type: "function_call",
          call_id: "proposal-note-repair",
          name: "prepare_create_note",
          arguments: incompleteArguments,
        },
      ],
    },
    request,
  );
  assert.deepEqual(result, {
    protocolVersion: 2,
    kind: "tool_calls",
    calls: [{
      callID: "proposal-note-repair",
      name: "prepare_create_note",
      arguments: incompleteArguments,
    }],
  });

  request.round = 1;
  request.toolHistory = [{
    callID: "proposal-note-repair",
    name: "prepare_create_note",
    arguments: incompleteArguments,
    output: "Proposal not prepared: body is required. Revise the arguments.",
  }];
  assert.doesNotThrow(() => buildOpenAIRequest(request));
  const instructions = buildOpenAIRequest(request).input[0].content;
  assert.match(instructions, /retry a proposal only when its receipt explicitly says to revise/iu);
  assert.match(instructions, /retry budget is exhausted.*stop calling proposal tools/isu);
});

test("allows parallel reads but rejects more than one proposal in a model round", () => {
  const request = v2ClientRequest();
  request.enabledTools = ["prepare_create_todo", "prepare_create_note"];
  assert.throws(
    () => extractV2RelayResult({
      status: "completed",
      output: [
        {
          type: "function_call",
          call_id: "proposal-todo",
          name: "prepare_create_todo",
          arguments: JSON.stringify({
            title: "Write the memo",
            due_at: null,
            time_zone_id: null,
            list_name: null,
          }),
        },
        {
          type: "function_call",
          call_id: "proposal-note",
          name: "prepare_create_note",
          arguments: JSON.stringify({ title: "Bull case for Bitcoin", body: "Draft" }),
        },
      ],
    }, request),
    /more than one proposal/u,
  );
});

test("rejects disabled tools, repeated queries, over-budget calls, and a fourth proposal", () => {
  const disabled = v2ClientRequest();
  assert.throws(
    () => extractV2RelayResult({
      status: "completed",
      output: [{
        type: "function_call",
        call_id: "call-1",
        name: "query_notes",
        arguments: "{}",
      }],
    }, disabled),
    /disabled tool/,
  );

  const repeated = v2ClientRequest();
  repeated.round = 1;
  repeated.toolHistory = [{
    callID: "call-1",
    name: "query_todos",
    arguments: todoArguments(),
    output: "ok",
  }];
  assert.throws(
    () => extractV2RelayResult({
      status: "completed",
      output: [{
        type: "function_call",
        call_id: "call-2",
        name: "query_todos",
        arguments: todoArguments(),
      }],
    }, repeated),
    /repeated a query id/,
  );

  const overBudget = v2ClientRequest();
  assert.throws(
    () => extractV2RelayResult({
      status: "completed",
      output: Array.from({ length: 5 }, (_, index) => ({
        type: "function_call",
        call_id: `call-${index}`,
        name: "query_todos",
        arguments: todoArguments(`todo-${index}`),
      })),
    }, overBudget),
    /too many tools/,
  );

  const proposal = v2ClientRequest();
  proposal.round = 1;
  proposal.toolHistory = Array.from({ length: 3 }, (_, index) => ({
    callID: `proposal-${index + 1}`,
    name: "prepare_create_todo",
    arguments: JSON.stringify({
      title: `Attempt ${index + 1}`,
      due_at: null,
      time_zone_id: null,
      list_name: null,
    }),
    output: "Proposal not prepared: revise the arguments.",
  }));
  assert.throws(
    () => extractV2RelayResult({
      status: "completed",
      output: [{
        type: "function_call",
        call_id: "proposal-4",
        name: "prepare_create_todo",
        arguments: JSON.stringify({
          title: "A second todo",
          due_at: null,
          time_zone_id: null,
          list_name: null,
        }),
      }],
    }, proposal),
    /proposal retry budget/,
  );
});

test("requires the exact V2 native tool schema identity", () => {
  const request = v2ClientRequest();
  request.toolSchemaDigest = "0".repeat(64);
  assert.throws(() => routeForClientRequest(request), /schema identity/);

  const actionRequest = v2ClientRequest();
  actionRequest.actionToolSchemaDigest = "0".repeat(64);
  assert.throws(() => routeForClientRequest(actionRequest), /action-tool schema identity/);

  const legacyActionHandshake = v2ClientRequest();
  delete legacyActionHandshake.actionToolSchemaVersion;
  delete legacyActionHandshake.actionToolSchemaDigest;
  assert.throws(
    () => routeForClientRequest(legacyActionHandshake),
    /action-tool schema identity/,
  );

  const incompleteActionHandshake = v2ClientRequest();
  delete incompleteActionHandshake.actionToolSchemaDigest;
  assert.throws(
    () => routeForClientRequest(incompleteActionHandshake),
    /action-tool schema identity/,
  );
});

test("returns a V2 answer only when every support is exact cumulative evidence", () => {
  const request = v2ClientRequest();
  request.evidence = [{
    id: "E1",
    source: "todo",
    title: "Send the launch update",
    revision: "r1",
    updatedAt: "2026-08-08T07:00:00Z",
    content: "Due today at 4 PM. Status: open.",
  }];
  const response = {
    status: "completed",
    output_text: JSON.stringify({
      claims: [{
        text: "Send the launch update before 4 PM.",
        supports: [{ evidenceID: "E1", excerpt: "Due today at 4 PM" }],
      }],
    }),
  };
  assert.deepEqual(extractV2RelayResult(response, request), {
    protocolVersion: 2,
    kind: "answer",
    claims: [{
      text: "Send the launch update before 4 PM.",
      supports: [{ evidenceID: "E1", excerpt: "Due today at 4 PM" }],
    }],
  });
  response.output_text = JSON.stringify({
    claims: [{
      text: "Send it tomorrow.",
      supports: [{ evidenceID: "E1", excerpt: "tomorrow" }],
    }],
  });
  assert.throws(() => extractV2RelayResult(response, request), /unsupported claim/);
});

test("returns one truthful action message only after a successful native proposal receipt", () => {
  const request = v2ClientRequest();
  request.round = 1;
  request.enabledTools = ["prepare_create_note"];
  request.toolHistory = [{
    callID: "proposal-note",
    name: "prepare_create_note",
    arguments: JSON.stringify({ title: "Bull case for Bitcoin", body: "Draft body" }),
    output: "Proposal prepared for native review; nothing was changed. intent_id=intent-1 evidence_ids=[]",
  }];
  const response = {
    status: "completed",
    output_text: JSON.stringify({
      claims: [],
      actionMessage: "I prepared the Bitcoin memo for your review.",
    }),
  };
  assert.deepEqual(extractV2RelayResult(response, request), {
    protocolVersion: 2,
    kind: "answer",
    claims: [],
    actionMessage: "I prepared the Bitcoin memo for your review.",
  });

  for (const actionMessage of [
    "Prepared “Grab coffee with Gabby” as a to-do for your review; nothing has been created yet.",
    "A concise memo was prepared as a note for review. Nothing has been saved yet.",
    "The draft is ready for review; nothing was created or saved.",
  ]) {
    response.output_text = JSON.stringify({ claims: [], actionMessage });
    assert.equal(extractV2RelayResult(response, request).actionMessage, actionMessage);
  }

  response.output_text = JSON.stringify({
    claims: [],
    actionMessage: "I created and saved the Bitcoin memo.",
  });
  assert.throws(() => extractV2RelayResult(response, request), /action message/u);

  response.output_text = JSON.stringify({
    claims: [],
    actionMessage: "I created the Bitcoin memo for review; nothing has been saved yet.",
  });
  assert.throws(() => extractV2RelayResult(response, request), /action message/u);
});

test("forwards a validated request and returns only the claims envelope", async (context) => {
  let forwardedRequest;
  const relay = createAskIAgentRelay({
    apiKey: "test-key",
    fetchImpl: async (_url, options) => {
      forwardedRequest = JSON.parse(options.body);
      return new Response(
        JSON.stringify({
          output_text: JSON.stringify({
            claims: [
              {
                text: "Send the launch update before 4 PM.",
                supports: [{ evidenceID: "E1", excerpt: "Due today at 4 PM" }],
              },
            ],
          }),
        }),
        { status: 200, headers: { "Content-Type": "application/json" } },
      );
    },
    logger: { log() {}, error() {} },
  });
  await new Promise((resolve) => relay.listen(0, "127.0.0.1", resolve));
  context.after(() => new Promise((resolve) => relay.close(resolve)));

  const address = relay.address();
  const response = await fetch(`http://127.0.0.1:${address.port}/ask`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "X-iAgent-Relay-Protocol": "1",
    },
    body: JSON.stringify(clientRequest("fast")),
  });
  assert.equal(response.status, 200);
  assert.equal(forwardedRequest.model, "gpt-5.6-luna");
  assert.equal(forwardedRequest.store, false);
  assert.deepEqual(await response.json(), {
    claims: [
      {
        text: "Send the launch update before 4 PM.",
        supports: [{ evidenceID: "E1", excerpt: "Due today at 4 PM" }],
      },
    ],
  });
});

test("forwards protocol two with header two and returns only validated tool calls", async (context) => {
  let forwardedRequest;
  const relay = createAskIAgentRelay({
    apiKey: "test-key",
    fetchImpl: async (_url, options) => {
      forwardedRequest = JSON.parse(options.body);
      return new Response(
        JSON.stringify({
          status: "completed",
          output: [{
            type: "function_call",
            call_id: "call-1",
            name: "query_todos",
            arguments: todoArguments(),
          }],
        }),
        { status: 200, headers: { "Content-Type": "application/json" } },
      );
    },
    logger: { log() {}, error() {} },
  });
  await new Promise((resolve) => relay.listen(0, "127.0.0.1", resolve));
  context.after(() => new Promise((resolve) => relay.close(resolve)));

  const address = relay.address();
  const response = await fetch(`http://127.0.0.1:${address.port}/ask`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "X-iAgent-Relay-Protocol": "2",
    },
    body: JSON.stringify(v2ClientRequest("fast")),
  });
  assert.equal(response.status, 200);
  assert.equal(forwardedRequest.store, false);
  assert.deepEqual(forwardedRequest.tools.map((tool) => tool.name), [
    "query_todos",
    "prepare_create_todo",
  ]);
  assert.deepEqual(await response.json(), {
    protocolVersion: 2,
    kind: "tool_calls",
    calls: [{ callID: "call-1", name: "query_todos", arguments: todoArguments() }],
  });

  const mismatch = await fetch(`http://127.0.0.1:${address.port}/ask`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "X-iAgent-Relay-Protocol": "1",
    },
    body: JSON.stringify(v2ClientRequest("fast")),
  });
  assert.equal(mismatch.status, 400);
  assert.deepEqual(await mismatch.json(), { error: "unsupported_protocol" });
});

test("maps an upstream network TypeError to availability, not request validation", async (context) => {
  const traces = [];
  const relay = createAskIAgentRelay({
    apiKey: "test-key",
    fetchImpl: async () => {
      throw new TypeError("fetch failed");
    },
    logger: { log(value) { traces.push(value); }, error() {} },
  });
  await new Promise((resolve) => relay.listen(0, "127.0.0.1", resolve));
  context.after(() => new Promise((resolve) => relay.close(resolve)));

  const address = relay.address();
  const response = await fetch(`http://127.0.0.1:${address.port}/ask`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "X-iAgent-Relay-Protocol": "1",
    },
    body: JSON.stringify(clientRequest("fast")),
  });
  assert.equal(response.status, 503);
  assert.deepEqual(await response.json(), { error: "relay_unavailable" });
  const requestID = response.headers.get("X-iAgent-Request-ID");
  assert.match(requestID, /^iareq_[a-f0-9]{32}$/u);
  assert.deepEqual(traces, [{
    event: "relay_request",
    requestID,
    tier: "fast",
    protocolVersion: 1,
    round: 0,
    outcome: "error",
    errorCode: "relay_unavailable",
    latencyMs: traces[0].latencyMs,
  }]);
  assert.equal(Number.isSafeInteger(traces[0].latencyMs), true);
  assert.deepEqual(Object.keys(traces[0]).sort(), [
    "errorCode",
    "event",
    "latencyMs",
    "outcome",
    "protocolVersion",
    "requestID",
    "round",
    "tier",
  ]);
});
