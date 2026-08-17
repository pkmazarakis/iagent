import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import test from "node:test";
import cbor from "cbor";

import {
  createLocalAnonymousToken,
  verifyAnonymousInstallationToken,
} from "../src/auth.mjs";
import {
  ATTESTATION_DIAGNOSTIC_CODES,
  AppAttestEnvironmentMismatchError,
  AttestationError,
  classifyNodeAttestationVerificationError,
  sha256Base64URL,
  validateAppAttestAuthenticatorSignals,
  verifyAppAttestAssertion,
  verifyAppAttestAttestation,
} from "../src/attestation.mjs";
import { AttestationState, processAttestationExchange } from "../src/attestation-state.mjs";
import {
  ROUTES,
  V2_ACTION_TOOL_SCHEMA_DIGEST,
  V2_ACTION_TOOL_SCHEMA_VERSION,
  V2_CANONICAL_TOOL_NAMES,
  V2_READ_TOOL_SCHEMA_DIGEST,
  V2_READ_TOOL_SCHEMA_VERSION,
  V2_TOOL_SCHEMAS,
  buildOpenAIRequest,
  extractV2RelayResponse,
  validateClientRequest,
} from "../src/contract.mjs";
import { InstallationLimiter, reserveInstallationBudget } from "../src/limiter.mjs";
import { createWorker } from "../src/worker.mjs";

const TOKEN_KEY = "token-key-that-is-at-least-thirty-two-bytes-long";
const SAFETY_KEY = "safety-key-that-is-at-least-thirty-two-bytes-long";
const INSTALLATION_ID = "installation_0123456789abcdefghijk";
const NOW = Date.parse("2026-08-08T08:00:00Z");

function assertAttestationDiagnostic(callback, expectedCode) {
  assert.throws(callback, (error) => {
    assert.ok(error instanceof AttestationError);
    assert.equal(error.diagnosticCode, expectedCode);
    return true;
  });
}

function appAttestAuthenticatorData(extensions, { attestedCredentialData = true } = {}) {
  if (!attestedCredentialData) {
    const flags = extensions === undefined ? 0 : 0x80;
    return Buffer.concat([
      Buffer.alloc(32),
      Buffer.from([flags]),
      Buffer.alloc(4),
      extensions === undefined ? Buffer.alloc(0) : cbor.encode(extensions),
    ]);
  }
  const credentialID = Buffer.alloc(32, 0x2a);
  const coseKey = cbor.encode(new Map([[1, 2]]));
  return Buffer.concat([
    Buffer.alloc(32),
    Buffer.from([0x40]),
    Buffer.alloc(20),
    Buffer.from([0, credentialID.length]),
    credentialID,
    coseKey,
    extensions === undefined ? Buffer.alloc(0) : cbor.encode(extensions),
  ]);
}

function canonicalJSON(value) {
  if (Array.isArray(value)) return `[${value.map(canonicalJSON).join(",")}]`;
  if (value !== null && typeof value === "object") {
    return `{${Object.keys(value).sort().map((key) =>
      `${JSON.stringify(key)}:${canonicalJSON(value[key])}`
    ).join(",")}}`;
  }
  return JSON.stringify(value);
}

function authConfig() {
  return {
    tokenHMACKey: TOKEN_KEY,
    tokenIssuer: "iagent-anonymous-attestation",
    tokenAudience: "ask-iagent-relay",
    tokenMaxTTLSeconds: 600,
  };
}

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
    safetyIdentifier: "client-value-is-not-forwarded",
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
    research: {
      intent: "plan",
      resolvedQuery: "today priorities",
      coverage: [{ source: "todo", totalMatches: 1, returnedMatches: 1, reason: "due today" }],
      catalog: { todo: 1 },
    },
  };
}

function groupedDailyPlanRequest(tier = "fast") {
  return {
    ...clientRequest(tier),
    prompt: "Plan my day using my calendar, todos, notes, meetings, and Codex tasks.",
    evidence: [
      {
        id: "E-todo",
        source: "todo",
        title: "Send the launch update",
        revision: "todo-r1",
        updatedAt: "2026-08-08T07:00:00Z",
        content: "Due today at 4 PM. Status: open.",
      },
      {
        id: "E-calendar",
        source: "calendar",
        title: "Design sync",
        revision: "calendar-r1",
        updatedAt: "2026-08-08T06:30:00Z",
        content: "Starts today at 10 AM and ends at 10:45 AM.",
      },
      {
        id: "E-note",
        source: "note",
        title: "Launch checklist",
        revision: "note-r1",
        updatedAt: "2026-08-08T06:00:00Z",
        content: "Confirm the launch owner before the design sync.",
      },
      {
        id: "E-meeting",
        source: "meeting",
        title: "Product review",
        revision: "meeting-r1",
        updatedAt: "2026-08-07T18:00:00Z",
        content: "The release scope still needs final approval.",
      },
      {
        id: "E-codex",
        source: "codex",
        title: "Refine ingestion pipeline",
        revision: "codex-r1",
        updatedAt: "2026-08-08T07:30:00Z",
        content: "State: needs approval. Waiting for feedback.",
      },
    ],
    research: {
      intent: "dailyPlanning",
      resolvedQuery: "Plan today from fixed commitments, open work, and recent context.",
      coverage: [
        { source: "todo", totalMatches: 7, returnedMatches: 1, reason: "open and due work" },
        { source: "calendar", totalMatches: 3, returnedMatches: 1, reason: "today's events" },
        { source: "note", totalMatches: 4, returnedMatches: 1, reason: "recent planning notes" },
        { source: "meeting", totalMatches: 2, returnedMatches: 1, reason: "recent action items" },
        { source: "codex", totalMatches: 2, returnedMatches: 1, reason: "active Codex work" },
      ],
      catalog: { todo: 24, calendar: 12, note: 18, meeting: 57, codex: 6 },
    },
  };
}

function latestMeetingArguments(queryID = "latest-meeting") {
  return {
    query_id: queryID,
    text: null,
    record_ids: [],
    states: ["completed"],
    has_readable_content: true,
    time: { field: "occurrence", preset: "past", start: null, end: null },
    sort: "occurrenceDesc",
    content: "summaryAndTranscriptPassages",
    limit: 1,
    cursor: null,
  };
}

function v2Catalog() {
  return {
    version: 2,
    snapshotID: "snapshot-v2-0001",
    temporalContext: {
      contextAsOf: "2026-08-08T08:00:00Z",
      timeZoneIdentifier: "Europe/Athens",
      localeIdentifier: "en_US",
      calendarIdentifier: "gregorian",
      firstWeekday: 2,
    },
    domains: [
      {
        domain: "meeting",
        availability: "available",
        availabilityReason: "none",
        recordCount: 57,
        observedAt: "2026-08-08T08:00:00Z",
        freshness: "current",
        coverage: { isCompleteWithinRange: true, isTruncated: false },
      },
    ],
  };
}

function v2ClientRequest(tier = "fast") {
  const isPro = tier === "pro";
  return {
    protocolVersion: 2,
    tier,
    model: isPro ? "gpt-5.6-sol" : "gpt-5.6-luna",
    reasoning: isPro ? { mode: "pro", effort: "medium" } : { effort: "low" },
    round: 0,
    prompt: "Summarize my latest meeting.",
    contextAsOf: "2026-08-08T08:00:00Z",
    localeIdentifier: "en_US",
    safetyIdentifier: "client-value-is-not-forwarded",
    recentConversation: [],
    catalog: v2Catalog(),
    toolSchemaVersion: V2_READ_TOOL_SCHEMA_VERSION,
    toolSchemaDigest: V2_READ_TOOL_SCHEMA_DIGEST,
    actionToolSchemaVersion: V2_ACTION_TOOL_SCHEMA_VERSION,
    actionToolSchemaDigest: V2_ACTION_TOOL_SCHEMA_DIGEST,
    enabledTools: ["query_meetings"],
    toolHistory: [],
    evidence: [],
  };
}

function v2ContinuationRequest(tier = "fast") {
  return {
    ...v2ClientRequest(tier),
    round: 1,
    toolHistory: [
      {
        callID: "call_latest_meeting_1",
        name: "query_meetings",
        arguments: JSON.stringify(latestMeetingArguments()),
        output: "query_id=latest-meeting matched=57 returned=1 warnings=none evidence_ids=[E-meeting]",
      },
    ],
    evidence: [
      {
        id: "E-meeting",
        source: "meeting",
        title: "Launch readiness review",
        revision: "meeting-r2",
        updatedAt: "2026-08-08T07:30:00Z",
        content: "The team approved the launch after Gabby completes the final checklist.",
      },
    ],
  };
}

class FakeLimiterNamespace {
  constructor() {
    this.calls = [];
  }

  idFromName(value) {
    return value;
  }

  get(id) {
    return {
      fetch: async (url, options) => {
        this.calls.push({ id, path: new URL(url).pathname, body: JSON.parse(options.body) });
        return new Response(JSON.stringify({ ok: true }), {
          status: 200,
          headers: { "Content-Type": "application/json" },
        });
      },
    };
  }
}

class StatefulLimiterNamespace {
  constructor() {
    this.limiters = new Map();
    this.calls = [];
  }

  idFromName(value) { return value; }

  get(id) {
    if (!this.limiters.has(id)) {
      this.limiters.set(id, new InstallationLimiter({ storage: new MemoryStorage() }, {}));
    }
    const limiter = this.limiters.get(id);
    return {
      fetch: async (url, options) => {
        this.calls.push({ id, path: new URL(url).pathname, body: JSON.parse(options.body) });
        return limiter.fetch(new Request(url, options));
      },
    };
  }
}

class FakeAttestationNamespace {
  constructor() {
    this.calls = [];
  }

  idFromName(value) {
    return value;
  }

  get(id) {
    return {
      fetch: async (url, options) => {
        const body = JSON.parse(options.body);
        const path = new URL(url).pathname;
        this.calls.push({ id, path, body });
        if (path === "/gate" || path === "/consume-devicecheck") {
          return new Response(JSON.stringify({ ok: true }), {
            status: 200,
            headers: { "Content-Type": "application/json" },
          });
        }
        if (path === "/challenge") {
          return new Response(JSON.stringify({
            protocolVersion: 1,
            challengeID: "challenge_identifier_000001",
            mode: "attestation",
            clientData: Buffer.from("server-controlled-client-data").toString("base64url"),
            expiresAt: NOW + 120_000,
          }), { status: 200, headers: { "Content-Type": "application/json" } });
        }
        return new Response(JSON.stringify({
          protocolVersion: 1,
          token: "short-lived-test-token",
          expiresAt: NOW + 180_000,
          assurance: body.assurance,
        }), { status: 200, headers: { "Content-Type": "application/json" } });
      },
    };
  }
}

function workerEnv(overrides = {}) {
  return {
    SERVICE_ENABLED: "true",
    ATTESTATION_EXCHANGE_ENABLED: "true",
    PRICING_CONFIGURED: "true",
    ENABLED_TIERS: "fast,pro",
    TOKEN_ISSUER: "iagent-anonymous-attestation",
    TOKEN_AUDIENCE: "ask-iagent-relay",
    TOKEN_MAX_TTL_SECONDS: "600",
    CHALLENGE_TTL_SECONDS: "120",
    CHALLENGE_REQUESTS_PER_MINUTE: "12",
    ATTESTATION_GLOBAL_REQUESTS_PER_MINUTE: "600",
    ATTESTATION_NETWORK_REQUESTS_PER_MINUTE: "60",
    APP_ATTEST_TEAM_IDENTIFIER: "625CGY297X",
    APP_ATTEST_BUNDLE_IDENTIFIER: "com.platon.iagent.mobile",
    APP_ATTEST_ALLOWED_ENVIRONMENTS: "production",
    APP_ATTEST_ALLOWED_VALIDATION_CATEGORIES: "2,4",
    APP_ATTEST_ALLOWED_BUNDLE_VERSIONS: "16",
    APP_ATTEST_REQUIRE_IOS27_SIGNALS: "false",
    DEVICECHECK_FALLBACK_ENABLED: "false",
    DEVICECHECK_ENVIRONMENT: "production",
    DEVICECHECK_REPLAY_TTL_SECONDS: "86400",
    REQUESTS_PER_MINUTE: "12",
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
    ANONYMOUS_TOKEN_HMAC_KEY: TOKEN_KEY,
    SAFETY_IDENTIFIER_HMAC_KEY: SAFETY_KEY,
    INSTALLATION_LIMITER: new FakeLimiterNamespace(),
    ATTESTATION_STATE: new FakeAttestationNamespace(),
    ...overrides,
  };
}

async function bearerHeader(body = clientRequest(), options = {}) {
  const requestHash = await sha256Base64URL(new TextEncoder().encode(JSON.stringify(body)));
  const token = await createLocalAnonymousToken(INSTALLATION_ID, requestHash, authConfig(), {
    now: NOW,
    tokenID: options.tokenID || "token_identifier_0123456789",
    ttlSeconds: options.ttlSeconds || 300,
  });
  return `Bearer ${token}`;
}

async function askRequest(body = clientRequest(), headers = {}, signal = undefined) {
  return new Request("https://relay.example/v1/ask", {
    method: "POST",
    headers: {
      Authorization: await bearerHeader(body),
      "Content-Type": "application/json",
      "X-iAgent-Relay-Protocol": "1",
      ...headers,
    },
    body: JSON.stringify(body),
    signal,
  });
}

async function v2AskRequest(body = v2ClientRequest(), headers = {}) {
  return new Request("https://relay.example/v1/ask", {
    method: "POST",
    headers: {
      Authorization: await bearerHeader(body),
      "Content-Type": "application/json",
      "X-iAgent-Relay-Protocol": "2",
      ...headers,
    },
    body: JSON.stringify(body),
  });
}

test("validates the exact Fast and Pro model routes", () => {
  const fast = validateClientRequest(clientRequest("fast"));
  const pro = validateClientRequest(clientRequest("pro"));
  assert.equal(ROUTES[fast.tier].model, "gpt-5.6-luna");
  assert.deepEqual(ROUTES[fast.tier].reasoning, { effort: "low" });
  assert.equal(ROUTES[pro.tier].model, "gpt-5.6-sol");
  assert.deepEqual(ROUTES[pro.tier].reasoning, { mode: "pro", effort: "medium" });
});

test("validates a content-free V2 catalog and builds only fixed enabled tools", () => {
  const body = validateClientRequest(v2ClientRequest("pro"));
  assert.equal(body.protocolVersion, 2);
  assert.equal(body.round, 0);
  assert.equal(body.toolSchemaVersion, 1);
  assert.equal(body.toolSchemaDigest, "8b8df423c5f84945c54ba2f467cdf774ba7f3a3a399025278924ccc629eb1ba5");
  assert.deepEqual(body.catalog.domains.map((item) => item.domain), ["meeting"]);
  assert.equal(body.catalog.domains[0].lastSuccessfulReadAt, null);
  assert.equal(body.catalog.domains[0].coverage.start, null);

  const upstream = buildOpenAIRequest(body, ROUTES.pro, "derived-safety-id");
  assert.equal(upstream.model, "gpt-5.6-sol");
  assert.equal(upstream.store, false);
  assert.equal(upstream.safety_identifier, "derived-safety-id");
  assert.deepEqual(upstream.tools.map((tool) => tool.name), ["query_meetings"]);
  assert.equal(upstream.tools[0].strict, true);
  assert.equal(upstream.tools[0].parameters.additionalProperties, false);
  assert.equal(upstream.text.format.type, "json_schema");
  const packet = JSON.parse(upstream.input[1].content.split("\n\n").at(-1));
  assert.deepEqual(packet.catalog.domains[0].recordCount, 57);
  assert.equal(packet.cumulativeEvidence, undefined);
  assert.equal(packet.toolHistory, undefined);
  assert.equal(packet.remainingToolCallBudget, 8);
});

test("V2 rejects a read-tool schema identity mismatch before OpenAI", async () => {
  const body = { ...v2ClientRequest(), toolSchemaDigest: "0".repeat(64) };
  assert.throws(() => validateClientRequest(body), /schema identity is not supported/u);
  let upstreamCalled = false;
  const worker = createWorker({
    now: () => NOW,
    fetchImpl: async () => {
      upstreamCalled = true;
      return new Response("unexpected");
    },
  });
  const response = await worker.fetch(await v2AskRequest(body), workerEnv());
  assert.equal(response.status, 422);
  assert.equal(upstreamCalled, false);

  const actionBody = { ...v2ClientRequest(), actionToolSchemaDigest: "0".repeat(64) };
  assert.throws(
    () => validateClientRequest(actionBody),
    /action-tool schema identity is not supported/u,
  );

  const legacyActionHandshake = v2ClientRequest();
  delete legacyActionHandshake.actionToolSchemaVersion;
  delete legacyActionHandshake.actionToolSchemaDigest;
  assert.throws(
    () => validateClientRequest(legacyActionHandshake),
    /action-tool schema identity is not supported/u,
  );

  let missingIdentityCalledUpstream = false;
  const missingIdentityWorker = createWorker({
    now: () => NOW,
    fetchImpl: async () => {
      missingIdentityCalledUpstream = true;
      return new Response("unexpected");
    },
  });
  const missingIdentityResponse = await missingIdentityWorker.fetch(
    await v2AskRequest(legacyActionHandshake),
    workerEnv(),
  );
  assert.equal(missingIdentityResponse.status, 422);
  assert.equal(missingIdentityCalledUpstream, false);
});

test("V2 rejects unknown tools, malformed strict arguments, duplicate calls, and round mismatches", () => {
  const unknownTool = { ...v2ClientRequest(), enabledTools: ["search_everything"] };
  assert.throws(() => validateClientRequest(unknownTool), /enabledTools is invalid/u);

  const unexpectedArgument = v2ContinuationRequest();
  unexpectedArgument.toolHistory = [{
    ...unexpectedArgument.toolHistory[0],
    arguments: JSON.stringify({ ...latestMeetingArguments(), hidden_scope: "all" }),
  }];
  assert.throws(() => validateClientRequest(unexpectedArgument), /unknown field/u);

  const duplicate = v2ContinuationRequest();
  duplicate.toolHistory.push({ ...duplicate.toolHistory[0] });
  assert.throws(() => validateClientRequest(duplicate), /call ids must be unique/u);

  const invalidRound = { ...v2ClientRequest(), round: 1 };
  assert.throws(() => validateClientRequest(invalidRound), /does not match the round/u);
});

test("V2 emits a bounded allowlisted tool-call envelope", () => {
  const body = validateClientRequest(v2ClientRequest());
  const response = extractV2RelayResponse({
    status: "completed",
    output: [{
      type: "function_call",
      call_id: "call_latest_meeting_1",
      name: "query_meetings",
      arguments: JSON.stringify(latestMeetingArguments()),
    }],
  }, body);
  assert.deepEqual(response, {
    protocolVersion: 2,
    kind: "tool_calls",
    calls: [{
      callID: "call_latest_meeting_1",
      name: "query_meetings",
      arguments: JSON.stringify(latestMeetingArguments()),
    }],
  });
});

test("V2 reconstructs exact parallel Responses items, bound evidence, zero results, and Pro reasoning", () => {
  const request = v2ClientRequest("pro");
  request.round = 2;
  request.toolHistory = [
    {
      callID: "call_round0_a",
      name: "query_meetings",
      arguments: JSON.stringify(latestMeetingArguments("round0-a")),
      output: "query_id=round0-a matched=1 returned=1 warnings=none evidence_ids=[E-meeting]",
    },
    {
      callID: "call_round0_b",
      name: "query_meetings",
      arguments: JSON.stringify(latestMeetingArguments("round0-b")),
      output: "query_id=round0-b matched=0 returned=0 warnings=none",
    },
    {
      callID: "call_round1",
      name: "query_meetings",
      arguments: JSON.stringify(latestMeetingArguments("round1")),
      output: "query_id=round1 matched=1 returned=1 warnings=none evidence_ids=[E-followup]",
    },
  ];
  request.evidence = [
    {
      id: "E-meeting",
      source: "meeting",
      title: "Launch review",
      revision: "r1",
      updatedAt: "2026-08-08T07:30:00Z",
      content: "Launch approved.",
    },
    {
      id: "E-followup",
      source: "meeting",
      title: "Follow-up",
      revision: "r2",
      updatedAt: "2026-08-08T07:40:00Z",
      content: "Checklist remains.",
    },
  ];
  request.modelContinuation = [
    {
      round: 0,
      callIDs: ["call_round0_a", "call_round0_b"],
      reasoningID: "rs_round0",
      encryptedContent: "ZW5jcnlwdGVkMA==",
    },
    {
      round: 1,
      callIDs: ["call_round1"],
      reasoningID: "rs_round1",
      encryptedContent: "ZW5jcnlwdGVkMQ==",
    },
  ];
  const body = validateClientRequest(request);
  const upstream = buildOpenAIRequest(body, ROUTES.pro, "derived-safety-id");
  assert.deepEqual(upstream.include, ["reasoning.encrypted_content"]);
  assert.deepEqual(upstream.input.slice(2).map((item) => [item.type, item.call_id || item.id]), [
    ["reasoning", "rs_round0"],
    ["function_call", "call_round0_a"],
    ["function_call", "call_round0_b"],
    ["function_call_output", "call_round0_a"],
    ["function_call_output", "call_round0_b"],
    ["reasoning", "rs_round1"],
    ["function_call", "call_round1"],
    ["function_call_output", "call_round1"],
  ]);
  assert.deepEqual(upstream.input[2], {
    type: "reasoning",
    id: "rs_round0",
    summary: [],
    encrypted_content: "ZW5jcnlwdGVkMA==",
  });
  assert.deepEqual(JSON.parse(upstream.input[5].output).evidence.map((item) => item.id), ["E-meeting"]);
  assert.deepEqual(JSON.parse(upstream.input[6].output).evidence, []);
  assert.deepEqual(JSON.parse(upstream.input[9].output).evidence.map((item) => item.id), ["E-followup"]);
  const packet = JSON.parse(upstream.input[1].content.split("\n\n").at(-1));
  assert.equal(packet.toolHistory, undefined);
  assert.equal(packet.cumulativeEvidence, undefined);
});

test("V2 returns a cumulative opaque reasoning continuation for exact call IDs", () => {
  const body = validateClientRequest(v2ClientRequest("pro"));
  const response = extractV2RelayResponse({
    status: "completed",
    output: [
      { type: "reasoning", id: "rs_round0", summary: [], encrypted_content: "ZW5jcnlwdGVk" },
      {
        type: "function_call",
        call_id: "call_a",
        name: "query_meetings",
        arguments: JSON.stringify(latestMeetingArguments("a")),
      },
      {
        type: "function_call",
        call_id: "call_b",
        name: "query_meetings",
        arguments: JSON.stringify(latestMeetingArguments("b")),
      },
    ],
  }, body);
  assert.deepEqual(response.modelContinuation, [{
    round: 0,
    callIDs: ["call_a", "call_b"],
    reasoningID: "rs_round0",
    encryptedContent: "ZW5jcnlwdGVk",
  }]);
  assert.throws(() => extractV2RelayResponse({
    status: "completed",
    output: [{
      type: "function_call",
      call_id: "call_a",
      name: "query_meetings",
      arguments: JSON.stringify(latestMeetingArguments("a")),
    }],
  }, body), /missing_encrypted_reasoning/u);
});

test("V2 validates action-only model messages only after a successful native proposal receipt", () => {
  const request = v2ClientRequest();
  request.round = 1;
  request.enabledTools = ["prepare_create_note"];
  request.toolHistory = [{
    callID: "proposal_note",
    name: "prepare_create_note",
    arguments: JSON.stringify({ title: "Bull Case for Bitcoin", body: "Draft thesis" }),
    output: "Proposal prepared for native review; nothing was changed. intent_id=opaque",
  }];
  const body = validateClientRequest(request);
  const response = extractV2RelayResponse({
    status: "completed",
    output_text: JSON.stringify({
      claims: [],
      actionMessage: "I prepared the Bitcoin memo for your review.",
    }),
  }, body);
  assert.deepEqual(response, {
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
    assert.equal(extractV2RelayResponse({
      status: "completed",
      output_text: JSON.stringify({ claims: [], actionMessage }),
    }, body).actionMessage, actionMessage);
  }

  const noProposal = validateClientRequest(v2ContinuationRequest());
  assert.throws(() => extractV2RelayResponse({
    status: "completed",
    output_text: JSON.stringify({ claims: [], actionMessage: "I prepared this for review." }),
  }, noProposal), /unexpected_action_message/u);
  assert.throws(() => extractV2RelayResponse({
    status: "completed",
    output_text: JSON.stringify({ claims: [], actionMessage: "I created and saved the note." }),
  }, body), /invalid_action_message/u);
  assert.throws(() => extractV2RelayResponse({
    status: "completed",
    output_text: JSON.stringify({
      claims: [],
      actionMessage: "I created the note for review; nothing has been saved yet.",
    }),
  }, body), /invalid_action_message/u);
});

test("V2 forwards repairable proposal arguments to the native validator", () => {
  const request = v2ClientRequest();
  request.enabledTools = ["prepare_create_note"];
  const body = validateClientRequest(request);
  const incompleteArguments = JSON.stringify({ title: "Bitcoin bull case" });
  const response = extractV2RelayResponse({
    status: "completed",
    output: [{
      type: "function_call",
      call_id: "proposal_note_repair",
      name: "prepare_create_note",
      arguments: incompleteArguments,
    }],
  }, body);
  assert.deepEqual(response, {
    protocolVersion: 2,
    kind: "tool_calls",
    calls: [{
      callID: "proposal_note_repair",
      name: "prepare_create_note",
      arguments: incompleteArguments,
    }],
  });

  request.round = 1;
  request.toolHistory = [{
    callID: "proposal_note_repair",
    name: "prepare_create_note",
    arguments: incompleteArguments,
    output: "Proposal not prepared: body is required. Revise the arguments.",
  }];
  assert.doesNotThrow(() => validateClientRequest(request));
  const instructions = buildOpenAIRequest(
    validateClientRequest(request),
    ROUTES.fast,
    "test-safety-identifier",
  ).input[0].content;
  assert.match(instructions, /retry a proposal only when its receipt explicitly says to revise/iu);
  assert.match(instructions, /retry budget is exhausted.*stop calling proposal tools/isu);
});

test("V2 rejects more than one proposal in a model round", () => {
  const request = v2ClientRequest();
  request.enabledTools = ["prepare_create_todo", "prepare_create_note"];
  const body = validateClientRequest(request);
  assert.throws(() => extractV2RelayResponse({
    status: "completed",
    output: [
      {
        type: "function_call",
        call_id: "proposal_todo",
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
        call_id: "proposal_note",
        name: "prepare_create_note",
        arguments: JSON.stringify({ title: "Bull case for Bitcoin", body: "Draft" }),
      },
    ],
  }, body), /multiple_proposals_in_round/u);
});

test("V2 emits only exact-supported final claims from cumulative evidence", () => {
  const body = validateClientRequest(v2ContinuationRequest());
  const response = extractV2RelayResponse({
    status: "completed",
    output_text: JSON.stringify({
      claims: [{
        text: "The launch was approved, pending Gabby's final checklist.",
        supports: [{ evidenceID: "E-meeting", excerpt: "approved the launch" }],
      }],
    }),
  }, body);
  assert.deepEqual(response, {
    protocolVersion: 2,
    kind: "answer",
    claims: [{
      text: "The launch was approved, pending Gabby's final checklist.",
      supports: [{ evidenceID: "E-meeting", excerpt: "approved the launch" }],
    }],
  });
});

test("V2 enforces the final-round and bounded proposal-repair budgets", () => {
  const finalRound = v2ContinuationRequest();
  finalRound.round = 3;
  const validatedFinal = validateClientRequest(finalRound);
  const upstream = buildOpenAIRequest(validatedFinal, ROUTES.fast, "derived-safety-id");
  assert.equal(upstream.tools, undefined);
  assert.throws(() => extractV2RelayResponse({
    status: "completed",
    output: [{
      type: "function_call",
      call_id: "call_too_late",
      name: "query_meetings",
      arguments: JSON.stringify(latestMeetingArguments("too-late")),
    }],
  }, validatedFinal), /tool_call_budget_exceeded/u);

  const proposal = v2ClientRequest();
  proposal.round = 1;
  proposal.enabledTools = ["prepare_create_note"];
  proposal.toolHistory = Array.from({ length: 3 }, (_, index) => ({
    callID: `proposal_${index + 1}`,
    name: "prepare_create_note",
    arguments: JSON.stringify({ title: `Attempt ${index + 1}`, body: "Needs repair" }),
    output: "Proposal not prepared: revise the arguments.",
  }));
  const validatedProposal = validateClientRequest(proposal);
  assert.throws(() => extractV2RelayResponse({
    status: "completed",
    output: [{
      type: "function_call",
      call_id: "proposal_4",
      name: "prepare_create_note",
      arguments: JSON.stringify({ title: "Duplicate", body: "Not allowed" }),
    }],
  }, validatedProposal), /proposal_call_budget_exceeded/u);
});

test("V2 canonical tool names stay aligned with the native tool catalog", () => {
  assert.deepEqual(V2_CANONICAL_TOOL_NAMES, [
    "query_todos",
    "query_calendar",
    "query_notes",
    "query_meetings",
    "query_codex",
    "prepare_create_todo",
    "prepare_create_note",
    "prepare_calendar_event_draft",
    "prepare_codex_task_request",
  ]);
  const readManifest = {
    schema_version: V2_READ_TOOL_SCHEMA_VERSION,
    tools: V2_CANONICAL_TOOL_NAMES.slice(0, 5).map((name) => V2_TOOL_SCHEMAS[name]),
  };
  assert.equal(
    createHash("sha256").update(canonicalJSON(readManifest)).digest("hex"),
    V2_READ_TOOL_SCHEMA_DIGEST,
  );
});

test("accepts one grouped coverage row for each daily-plan source domain", () => {
  const request = groupedDailyPlanRequest();
  const validated = validateClientRequest(request);
  assert.deepEqual(validated.research.coverage, request.research.coverage);
  assert.deepEqual(
    validated.research.coverage.map((item) => item.source),
    ["todo", "calendar", "note", "meeting", "codex"],
  );

  const upstream = buildOpenAIRequest(validated, ROUTES.fast, "derived-safety-id");
  const packet = JSON.parse(upstream.input[1].content.split("\n\n").at(-1));
  assert.deepEqual(packet.research, request.research);
  assert.deepEqual(packet.evidence.map((item) => item.source), [
    "todo",
    "calendar",
    "note",
    "meeting",
    "codex",
  ]);
});

test("rejects more than five research coverage rows before calling OpenAI", async () => {
  const body = groupedDailyPlanRequest();
  body.research.coverage.push({
    source: "todo",
    totalMatches: 1,
    returnedMatches: 0,
    reason: "an ungrouped duplicate query must not cross the relay boundary",
  });
  assert.throws(() => validateClientRequest(body), /research coverage is invalid/u);

  let upstreamCalled = false;
  const worker = createWorker({
    now: () => NOW,
    fetchImpl: async () => {
      upstreamCalled = true;
      return new Response("unexpected");
    },
  });
  const response = await worker.fetch(await askRequest(body), workerEnv());
  assert.equal(response.status, 422);
  assert.deepEqual(await response.json(), { error: "invalid_request" });
  assert.equal(upstreamCalled, false);
});

test("rejects unknown fields and client-selected models", () => {
  const unknown = { ...clientRequest(), extra: "field" };
  assert.throws(() => validateClientRequest(unknown), /unknown field/u);
  const model = { ...clientRequest(), model: "gpt-5.6-sol" };
  assert.throws(() => validateClientRequest(model), /not allowlisted/u);
});

test("verifies short-lived anonymous installation tokens", async () => {
  const body = clientRequest();
  const token = (await bearerHeader(body)).slice("Bearer ".length);
  const verified = await verifyAnonymousInstallationToken(token, authConfig(), NOW + 1_000);
  assert.equal(verified.installationID, INSTALLATION_ID);
  assert.equal(verified.requestHash, await sha256Base64URL(new TextEncoder().encode(JSON.stringify(body))));
  await assert.rejects(
    verifyAnonymousInstallationToken(token, authConfig(), NOW + 301_000),
    /unauthorized/u,
  );
  const pieces = token.split(".");
  pieces[2] = `${pieces[2].slice(0, -1)}${pieces[2].endsWith("a") ? "b" : "a"}`;
  await assert.rejects(verifyAnonymousInstallationToken(pieces.join("."), authConfig(), NOW), /unauthorized/u);
});

test("binds a bearer token to the exact request body", async () => {
  const authorizedBody = clientRequest();
  const modifiedBody = { ...authorizedBody, prompt: "Use a captured token for a different question" };
  const worker = createWorker({ fetchImpl: async () => assert.fail("upstream must not be called"), now: () => NOW });
  const response = await worker.fetch(new Request("https://relay.example/v1/ask", {
    method: "POST",
    headers: {
      Authorization: await bearerHeader(authorizedBody),
      "Content-Type": "application/json",
      "X-iAgent-Relay-Protocol": "1",
    },
    body: JSON.stringify(modifiedBody),
  }), workerEnv());
  assert.equal(response.status, 401);
});

test("attestation routes are gated, schema-validated, and return only the protocol envelope", async () => {
  const worker = createWorker({ fetchImpl: async () => assert.fail("upstream must not be called"), now: () => NOW });
  const keyID = "A".repeat(43) + "=";
  const body = {
    protocolVersion: 1,
    assurance: "app_attest",
    installationID: INSTALLATION_ID,
    keyID,
    requestHash: "a".repeat(43),
  };
  const request = () => new Request("https://relay.example/v1/attestation/challenge", {
    method: "POST",
    headers: {
      "CF-Connecting-IP": "192.0.2.1",
      "Content-Type": "application/json",
      "X-iAgent-Relay-Protocol": "1",
    },
    body: JSON.stringify(body),
  });
  const disabled = await worker.fetch(request(), workerEnv({ ATTESTATION_EXCHANGE_ENABLED: "false" }));
  assert.equal(disabled.status, 503);

  const env = workerEnv();
  const response = await worker.fetch(request(), env);
  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), {
    protocolVersion: 1,
    challengeID: "challenge_identifier_000001",
    mode: "attestation",
    clientData: Buffer.from("server-controlled-client-data").toString("base64url"),
    expiresAt: NOW + 120_000,
  });
  assert.equal(env.ATTESTATION_STATE.calls[0].id, "global-attestation-gate-v1");
  assert.equal(env.ATTESTATION_STATE.calls[1].id, `app-attest:${keyID}`);

  const invalid = await worker.fetch(new Request("https://relay.example/v1/attestation/challenge", {
    method: "POST",
    headers: {
      "CF-Connecting-IP": "192.0.2.1",
      "Content-Type": "application/json",
      "X-iAgent-Relay-Protocol": "1",
    },
    body: JSON.stringify({ ...body, unknown: "field" }),
  }), workerEnv());
  assert.equal(invalid.status, 400);
});

test("verifies an Apple App Attest certificate-chain fixture", () => {
  const fixture = JSON.parse(readFileSync(
    new URL("../node_modules/node-app-attest/test/fixtures/attestation-production.json", import.meta.url),
    "utf8",
  ));
  const result = verifyAppAttestAttestation({
    artifact: Buffer.from(fixture.attestation, "base64"),
    clientData: Buffer.from(fixture.challenge, "base64"),
    keyID: fixture.keyId,
    config: {
      bundleIdentifier: "io.uebelacker.AppAttestExample",
      teamIdentifier: "V8H6LQ9448",
      allowedEnvironments: new Set(["production"]),
      allowedValidationCategories: new Set([2, 4]),
      allowedBundleVersions: new Set(["1"]),
      requireIOS27Signals: false,
    },
    now: Date.parse("2024-02-07T00:00:00Z"),
  });
  assert.equal(result.environment, "production");
  assert.match(result.publicKey, /BEGIN PUBLIC KEY/u);
});

test("validates Apple's iOS 27 TestFlight signals and distributed bundle version", () => {
  const credentialID = Buffer.alloc(32, 0x2a);
  const coseKey = cbor.encode(new Map([[1, 2]]));
  const extensions = cbor.encode({
    apple_bundle_version_01: "26",
    // Apple's official fixture uses a little-endian UInt32 byte string, not a CBOR integer.
    apple_validation_category_01: Buffer.from([2, 0, 0, 0]),
  });
  const authenticatorData = Buffer.concat([
    Buffer.alloc(32),
    // Apple's official iOS 27 fixture leaves the ED flag unset even though extensions follow.
    Buffer.from([0x40]),
    Buffer.alloc(20),
    Buffer.from([0, credentialID.length]),
    credentialID,
    coseKey,
    extensions,
  ]);
  const config = {
    allowedValidationCategories: new Set([2, 4]),
    allowedBundleVersions: new Set(["25", "26"]),
    requireIOS27Signals: false,
  };

  assert.deepEqual(validateAppAttestAuthenticatorSignals(authenticatorData, true, config), {
    validationCategory: 2,
    bundleVersion: "26",
  });
  assert.throws(
    () => validateAppAttestAuthenticatorSignals(
      authenticatorData,
      true,
      { ...config, allowedBundleVersions: new Set(["25"]) },
    ),
    AttestationError,
  );
});

test("accepts Apple's signed assertion layout when its AT flag is retained without credential data", () => {
  // This is node-app-attest's real signed assertion fixture, not a constructed authData shape.
  // It is 141 bytes total and contains exactly 37 bytes of authenticatorData with flags 0x40.
  const assertion = Buffer.from(
    "omlzaWduYXR1cmVYRzBFAiBB8BGAwkmFCg1M5J0mOYEun0SUN1/lse79/7ypG9WiMQIhAIHvqj7eg59B1PMFX1CN4GMGlsgfFtdL30pHCf7G/dNRcWF1dGhlbnRpY2F0b3JEYXRhWCXKPdw7T3iujcFZbHVrHX0mDSMrNms5PzEbrFbQPRA6rEAAAAAB",
    "base64",
  );
  const publicKey = [
    "-----BEGIN PUBLIC KEY-----",
    "MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEg69t2YzgcPTLUx8Zgu+rbcikeaEL",
    "8Ppb+HG0QTIulz8YUB9tgv1pDRruWk87nZC3our56pzIWaqXEbaWyamdzA==",
    "-----END PUBLIC KEY-----",
    "",
  ].join("\n");
  const clientData = Buffer.from(
    '{"subject":"Lorem ipsum","message":"Lorem ipsum dolor sit amet, consectetur adipiscing elit."}',
  );
  const decoded = cbor.decodeFirstSync(assertion);
  assert.equal(assertion.length, 141);
  assert.equal(decoded.authenticatorData.length, 37);
  assert.equal(decoded.authenticatorData[32], 0x40);

  assert.deepEqual(verifyAppAttestAssertion({
    artifact: assertion,
    clientData,
    publicKey,
    signCount: 0,
    config: {
      bundleIdentifier: "io.uebelacker.AppAttestExample",
      teamIdentifier: "V8H6LQ9448",
      allowedValidationCategories: new Set([2, 4]),
      allowedBundleVersions: new Set(["29"]),
      requireIOS27Signals: false,
    },
  }), {
    signCount: 1,
    validationCategory: null,
    bundleVersion: null,
  });
});

test("optional iOS 27 signals are optional per key and validate every present key", () => {
  const config = {
    allowedValidationCategories: new Set([2, 4]),
    allowedBundleVersions: new Set(["28"]),
    requireIOS27Signals: false,
  };

  assert.deepEqual(
    validateAppAttestAuthenticatorSignals(
      appAttestAuthenticatorData({ unrelated_extension: true }),
      true,
      config,
    ),
    { validationCategory: null, bundleVersion: null },
  );
  assert.deepEqual(
    validateAppAttestAuthenticatorSignals(
      appAttestAuthenticatorData({ apple_validation_category_01: Buffer.from([2, 0, 0, 0]) }),
      true,
      config,
    ),
    { validationCategory: 2, bundleVersion: null },
  );
  assert.deepEqual(
    validateAppAttestAuthenticatorSignals(
      appAttestAuthenticatorData({ apple_bundle_version_01: "28" }),
      true,
      config,
    ),
    { validationCategory: null, bundleVersion: "28" },
  );

  const required = { ...config, requireIOS27Signals: true };
  assertAttestationDiagnostic(
    () => validateAppAttestAuthenticatorSignals(
      appAttestAuthenticatorData({ apple_bundle_version_01: "28" }),
      true,
      required,
    ),
    ATTESTATION_DIAGNOSTIC_CODES.validationCategoryMissing,
  );
  assertAttestationDiagnostic(
    () => validateAppAttestAuthenticatorSignals(
      appAttestAuthenticatorData({ apple_validation_category_01: Buffer.from([2, 0, 0, 0]) }),
      true,
      required,
    ),
    ATTESTATION_DIAGNOSTIC_CODES.bundleVersionMissing,
  );
});

test("App Attest verifier failures have fixed privacy-safe diagnostic categories", () => {
  const fixture = JSON.parse(readFileSync(
    new URL("../node_modules/node-app-attest/test/fixtures/attestation-production.json", import.meta.url),
    "utf8",
  ));
  const developmentFixture = JSON.parse(readFileSync(
    new URL("../node_modules/node-app-attest/test/fixtures/attestation-development.json", import.meta.url),
    "utf8",
  ));
  const artifact = Buffer.from(fixture.attestation, "base64");
  const clientData = Buffer.from(fixture.challenge, "base64");
  const config = {
    bundleIdentifier: "io.uebelacker.AppAttestExample",
    teamIdentifier: "V8H6LQ9448",
    allowedEnvironments: new Set(["production"]),
    allowedValidationCategories: new Set([2, 4]),
    allowedBundleVersions: new Set(["1"]),
    requireIOS27Signals: false,
  };

  assertAttestationDiagnostic(
    () => verifyAppAttestAttestation({
      artifact: Buffer.from("not-cbor"),
      clientData,
      keyID: fixture.keyId,
      config,
      now: Date.parse("2024-02-07T00:00:00Z"),
    }),
    ATTESTATION_DIAGNOSTIC_CODES.certificateCBORInvalid,
  );
  assertAttestationDiagnostic(
    () => verifyAppAttestAttestation({
      artifact,
      clientData,
      keyID: fixture.keyId,
      config,
      now: Date.parse("2124-02-07T00:00:00Z"),
    }),
    ATTESTATION_DIAGNOSTIC_CODES.certificateDateInvalid,
  );
  assertAttestationDiagnostic(
    () => verifyAppAttestAttestation({
      artifact,
      clientData,
      keyID: "B".repeat(43) + "=",
      config,
      now: Date.parse("2024-02-07T00:00:00Z"),
    }),
    ATTESTATION_DIAGNOSTIC_CODES.nodeAttestationKeyIDInvalid,
  );
  assert.throws(
    () => verifyAppAttestAttestation({
      artifact: Buffer.from(developmentFixture.attestation, "base64"),
      clientData: Buffer.from(developmentFixture.challenge, "base64"),
      keyID: developmentFixture.keyId,
      config,
      now: Date.parse("2024-02-07T00:00:00Z"),
    }),
    (error) => {
      assert.ok(error instanceof AppAttestEnvironmentMismatchError);
      assert.equal(error.diagnosticCode, ATTESTATION_DIAGNOSTIC_CODES.environmentMismatch);
      return true;
    },
  );

  const signalConfig = {
    allowedValidationCategories: new Set([2, 4]),
    allowedBundleVersions: new Set(["28"]),
    requireIOS27Signals: true,
  };
  assertAttestationDiagnostic(
    () => validateAppAttestAuthenticatorSignals(
      Buffer.concat([Buffer.alloc(32), Buffer.from([0x80]), Buffer.alloc(4)]),
      false,
      signalConfig,
    ),
    ATTESTATION_DIAGNOSTIC_CODES.extensionsDictionaryMissing,
  );
  assertAttestationDiagnostic(
    () => validateAppAttestAuthenticatorSignals(
      appAttestAuthenticatorData({
        apple_validation_category_01: Buffer.from([3, 0, 0, 0]),
        apple_bundle_version_01: "28",
      }),
      true,
      signalConfig,
    ),
    ATTESTATION_DIAGNOSTIC_CODES.validationCategoryInvalid,
  );
  assertAttestationDiagnostic(
    () => validateAppAttestAuthenticatorSignals(
      appAttestAuthenticatorData({
        apple_validation_category_01: Buffer.from([2, 0, 0, 0]),
        apple_bundle_version_01: 28,
      }),
      true,
      signalConfig,
    ),
    ATTESTATION_DIAGNOSTIC_CODES.bundleVersionTypeInvalid,
  );
  assertAttestationDiagnostic(
    () => validateAppAttestAuthenticatorSignals(
      appAttestAuthenticatorData({
        apple_validation_category_01: Buffer.from([2, 0, 0, 0]),
        apple_bundle_version_01: "27",
      }),
      true,
      signalConfig,
    ),
    ATTESTATION_DIAGNOSTIC_CODES.bundleVersionValueInvalid,
  );
});

test("node App Attest verifier messages map only by exact privacy-safe category", () => {
  const cases = [
    ["invalid attestation", ATTESTATION_DIAGNOSTIC_CODES.nodeAttestationStructureInvalid],
    [
      "number of decoded attestations is not 1",
      ATTESTATION_DIAGNOSTIC_CODES.nodeAttestationStructureInvalid,
    ],
    [
      "invalid certificate",
      ATTESTATION_DIAGNOSTIC_CODES.nodeAttestationCertificateChainInvalid,
    ],
    [
      "no sub CA certificate found",
      ATTESTATION_DIAGNOSTIC_CODES.nodeAttestationCertificateChainInvalid,
    ],
    [
      "sub CA certificate is not signed by Apple App Attestation Root CA",
      ATTESTATION_DIAGNOSTIC_CODES.nodeAttestationCertificateChainInvalid,
    ],
    [
      "no client CA certificate found",
      ATTESTATION_DIAGNOSTIC_CODES.nodeAttestationCertificateChainInvalid,
    ],
    [
      "client CA certificate is not signed by Apple App Attestation CA 1",
      ATTESTATION_DIAGNOSTIC_CODES.nodeAttestationCertificateChainInvalid,
    ],
    ["nonce does not match", ATTESTATION_DIAGNOSTIC_CODES.nodeAttestationNonceInvalid],
    ["keyId does not match", ATTESTATION_DIAGNOSTIC_CODES.nodeAttestationKeyIDInvalid],
    ["appId does not match", ATTESTATION_DIAGNOSTIC_CODES.nodeAttestationAppIDInvalid],
    ["signCount is not 0", ATTESTATION_DIAGNOSTIC_CODES.nodeAttestationCounterInvalid],
    ["aaguid is not valid", ATTESTATION_DIAGNOSTIC_CODES.nodeAttestationAAGUIDInvalid],
    [
      "development environment is not allowed",
      ATTESTATION_DIAGNOSTIC_CODES.nodeAttestationAAGUIDInvalid,
    ],
    [
      "credentialId does not match",
      ATTESTATION_DIAGNOSTIC_CODES.nodeAttestationCredentialIDInvalid,
    ],
  ];
  for (const [message, expectedCode] of cases) {
    assert.equal(classifyNodeAttestationVerificationError(new Error(message)), expectedCode);
  }

  const privateDetail = "nonce does not match:private-key-and-installation";
  const unknownCode = classifyNodeAttestationVerificationError(new Error(privateDetail));
  assert.equal(unknownCode, ATTESTATION_DIAGNOSTIC_CODES.nodeAttestationVerificationFailed);
  assert.equal(JSON.stringify({ errorCode: unknownCode }).includes(privateDetail), false);
  assert.equal(
    classifyNodeAttestationVerificationError({ message: "keyId does not match " }),
    ATTESTATION_DIAGNOSTIC_CODES.nodeAttestationVerificationFailed,
  );
});

test("attestation exchange advances assertion counters and rejects replay", async () => {
  const config = {
    tokenHMACKey: TOKEN_KEY,
    tokenIssuer: "iagent-anonymous-attestation",
    tokenAudience: "ask-iagent-relay",
    tokenMaxTTLSeconds: 180,
  };
  const challenge = {
    id: "challenge_identifier_000001",
    requestHash: "a".repeat(43),
    clientData: Buffer.from("server-controlled-client-data").toString("base64url"),
  };
  const attested = await processAttestationExchange({
    record: null,
    challenge,
    body: {
      assurance: "app_attest",
      artifactType: "attestation",
      artifact: Buffer.from("fixture"),
      keyID: "A".repeat(43) + "=",
      installationID: "installation_0123456789abcdefghijk",
    },
    config,
    now: NOW,
  }, {
    verifyAttestation: () => ({
      publicKey: "public-key",
      receipt: "receipt",
      environment: "production",
      signCount: 0,
    }),
  });
  const asserted = await processAttestationExchange({
    record: attested.record,
    challenge,
    body: {
      assurance: "app_attest",
      artifactType: "assertion",
      artifact: Buffer.from("assertion"),
      keyID: attested.record.keyID,
      installationID: attested.record.installationID,
    },
    config,
    now: NOW + 1_000,
  }, {
    verifyAssertion: ({ signCount }) => {
      if (signCount >= 1) throw new AttestationError();
      return { signCount: 1 };
    },
  });
  assert.equal(asserted.record.signCount, 1);
  await assert.rejects(processAttestationExchange({
    record: asserted.record,
    challenge,
    body: {
      assurance: "app_attest",
      artifactType: "assertion",
      artifact: Buffer.from("replay"),
      keyID: asserted.record.keyID,
      installationID: asserted.record.installationID,
    },
    config,
    now: NOW + 2_000,
  }, {
    verifyAssertion: ({ signCount }) => {
      if (signCount >= 1) throw new AttestationError();
      return { signCount: 1 };
    },
  }), /unauthorized/u);
});

test("a stale-mode attestation replacement preserves established state and rejects identity drift", async () => {
  const keyID = "A".repeat(43) + "=";
  const record = {
    assurance: "app_attest",
    installationID: INSTALLATION_ID,
    keyID,
    publicKey: "established-public-key",
    receipt: "established-receipt",
    environment: "production",
    signCount: 4,
    createdAt: NOW - 10_000,
    lastVerifiedAt: NOW - 5_000,
    recordVersion: 6,
  };
  const request = {
    record,
    challenge: {
      id: "challenge_identifier_stale_mode",
      requestHash: "a".repeat(43),
      clientData: Buffer.from("server-controlled-client-data").toString("base64url"),
    },
    body: {
      assurance: "app_attest",
      artifactType: "attestation",
      artifact: Buffer.from("replacement-attestation"),
      keyID,
      installationID: INSTALLATION_ID,
    },
    config: {},
    now: NOW,
  };
  const replacement = await processAttestationExchange(request, {
    verifyAttestation: async () => ({
      publicKey: record.publicKey,
      receipt: "replacement-receipt",
      environment: record.environment,
      signCount: 0,
    }),
  });
  assert.deepEqual(replacement.record, {
    ...record,
    lastVerifiedAt: NOW,
  });
  assert.deepEqual(replacement.settlement, { kind: "attestation", baseRecordVersion: 6 });

  await assert.rejects(processAttestationExchange(request, {
    verifyAttestation: async () => ({
      publicKey: "different-public-key",
      receipt: "replacement-receipt",
      environment: record.environment,
      signCount: 0,
    }),
  }), AttestationError);
  await assert.rejects(processAttestationExchange(request, {
    verifyAttestation: async () => ({
      publicKey: record.publicKey,
      receipt: "replacement-receipt",
      environment: "development",
      signCount: 0,
    }),
  }), AttestationError);
  await assert.rejects(processAttestationExchange({
    ...request,
    body: { ...request.body, installationID: "different_installation_0123456789ab" },
  }, {
    verifyAttestation: async () => ({
      publicKey: record.publicKey,
      receipt: "replacement-receipt",
      environment: record.environment,
      signCount: 0,
    }),
  }), AttestationError);
  await assert.rejects(processAttestationExchange({
    ...request,
    body: { ...request.body, keyID: "B".repeat(43) + "=" },
  }, {
    verifyAttestation: async () => ({
      publicKey: record.publicKey,
      receipt: "replacement-receipt",
      environment: record.environment,
      signCount: 0,
    }),
  }), AttestationError);
});

test("DeviceCheck fallback rejects a recently reused Apple token", async () => {
  const config = { deviceCheckEnabled: true };
  const challenge = {
    id: "challenge_identifier_000001",
    requestHash: "a".repeat(43),
    clientData: Buffer.from("server-controlled-client-data").toString("base64url"),
  };
  const body = {
    assurance: "devicecheck",
    artifactType: "devicecheck",
    artifact: Buffer.from("device-check-token"),
    keyID: null,
    installationID: INSTALLATION_ID,
  };
  let validationCount = 0;
  const first = await processAttestationExchange({
    record: null,
    challenge,
    body,
    config,
    now: NOW,
  }, {
    verifyDeviceCheck: async () => { validationCount += 1; },
  });
  assert.equal(validationCount, 1);
  assert.equal(first.record.recentTokenHashes.length, 1);

  await assert.rejects(processAttestationExchange({
    record: first.record,
    challenge: { ...challenge, id: "challenge_identifier_000002" },
    body,
    config,
    now: NOW + 1_000,
  }, {
    verifyDeviceCheck: async () => { validationCount += 1; },
  }), /unauthorized/u);
  assert.equal(validationCount, 1);
});

test("builds a non-persisted structured Responses API request", () => {
  const body = validateClientRequest(clientRequest("fast"));
  const upstream = buildOpenAIRequest(body, ROUTES.fast, "derived-safety-id");
  assert.equal(upstream.model, "gpt-5.6-luna");
  assert.equal(upstream.store, false);
  assert.equal(upstream.safety_identifier, "derived-safety-id");
  assert.equal(upstream.text.format.type, "json_schema");
  assert.equal(upstream.text.format.strict, true);
});

test("fails closed when disabled or missing authentication", async () => {
  const worker = createWorker({ fetchImpl: async () => assert.fail("upstream must not be called"), now: () => NOW });
  const disabled = await worker.fetch(await askRequest(), workerEnv({ SERVICE_ENABLED: "false" }));
  assert.equal(disabled.status, 503);
  const noAuth = await worker.fetch(
    new Request("https://relay.example/v1/ask", {
      method: "POST",
      headers: { "Content-Type": "application/json", "X-iAgent-Relay-Protocol": "1" },
      body: JSON.stringify(clientRequest()),
    }),
    workerEnv(),
  );
  assert.equal(noAuth.status, 401);
});

test("root health response exposes only non-sensitive disabled state", async () => {
  const worker = createWorker({ fetchImpl: async () => assert.fail("upstream must not be called"), now: () => NOW });
  const response = await worker.fetch(new Request("https://relay.example/"), workerEnv({
    SERVICE_ENABLED: "false",
    ATTESTATION_EXCHANGE_ENABLED: "false",
  }));
  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), {
    service: "iagent-ask-iagent-relay",
    protocolVersion: 1,
    status: "disabled",
    attestation: "disabled",
  });
  assert.equal(response.headers.get("Access-Control-Allow-Origin"), null);
  assert.equal(response.headers.get("Cache-Control"), "no-store");
});

test("refuses browser CORS requests without emitting permissive headers", async () => {
  const worker = createWorker({ now: () => NOW });
  const response = await worker.fetch(await askRequest(clientRequest(), { Origin: "https://example.com" }), workerEnv());
  assert.equal(response.status, 403);
  assert.equal(response.headers.get("Access-Control-Allow-Origin"), null);
});

test("rejects an oversized body before calling OpenAI", async () => {
  const worker = createWorker({ fetchImpl: async () => assert.fail("upstream must not be called"), now: () => NOW });
  const response = await worker.fetch(new Request("https://relay.example/v1/ask", {
    method: "POST",
    headers: {
      Authorization: await bearerHeader(),
      "Content-Type": "application/json",
      "X-iAgent-Relay-Protocol": "1",
    },
    body: "x".repeat(64 * 1024 + 1),
  }), workerEnv());
  assert.equal(response.status, 413);
  assert.deepEqual(await response.json(), { error: "request_too_large" });
});

test("forwards a grounded request and returns only the validated claims envelope", async () => {
  let forwarded;
  const worker = createWorker({
    now: () => NOW,
    fetchImpl: async (_url, options) => {
      forwarded = JSON.parse(options.body);
      return new Response(
        JSON.stringify({
          status: "completed",
          output_text: JSON.stringify({
            claims: [
              {
                text: "Send the launch update before 4 PM.",
                supports: [{ evidenceID: "E1", excerpt: "Due today at 4 PM" }],
              },
            ],
          }),
          usage: { input_tokens: 250, output_tokens: 50 },
        }),
        { status: 200, headers: { "Content-Type": "application/json" } },
      );
    },
  });
  const env = workerEnv();
  const response = await worker.fetch(await askRequest(), env);
  assert.equal(response.status, 200);
  assert.equal(forwarded.model, "gpt-5.6-luna");
  assert.equal(forwarded.store, false);
  assert.notEqual(forwarded.safety_identifier, "client-value-is-not-forwarded");
  assert.deepEqual(await response.json(), {
    claims: [
      {
        text: "Send the launch update before 4 PM.",
        supports: [{ evidenceID: "E1", excerpt: "Due today at 4 PM" }],
      },
    ],
  });
  assert.deepEqual(env.INSTALLATION_LIMITER.calls.map((call) => call.path), ["/reserve", "/settle"]);
  assert.equal(env.INSTALLATION_LIMITER.calls[0].id, INSTALLATION_ID);
});

test("Worker forwards a V2 planning round and returns only validated local tool calls", async () => {
  let forwarded;
  const worker = createWorker({
    now: () => NOW,
    fetchImpl: async (_url, options) => {
      forwarded = JSON.parse(options.body);
      return new Response(JSON.stringify({
        status: "completed",
        output: [{
          type: "function_call",
          call_id: "call_latest_meeting_1",
          name: "query_meetings",
          arguments: JSON.stringify(latestMeetingArguments()),
        }],
        usage: { input_tokens: 300, output_tokens: 60 },
      }), { status: 200, headers: { "Content-Type": "application/json" } });
    },
  });
  const env = workerEnv();
  const response = await worker.fetch(await v2AskRequest(), env);
  assert.equal(response.status, 200);
  assert.equal(forwarded.store, false);
  assert.equal(forwarded.model, "gpt-5.6-luna");
  assert.deepEqual(forwarded.tools.map((tool) => tool.name), ["query_meetings"]);
  assert.equal(forwarded.input.some((item) => item.type === "function_call_output"), false);
  assert.deepEqual(await response.json(), {
    protocolVersion: 2,
    kind: "tool_calls",
    calls: [{
      callID: "call_latest_meeting_1",
      name: "query_meetings",
      arguments: JSON.stringify(latestMeetingArguments()),
    }],
  });
  assert.deepEqual(env.INSTALLATION_LIMITER.calls.map((call) => call.path), ["/reserve", "/settle"]);
});

test("Worker returns a V2 grounded answer after a bounded local tool receipt", async () => {
  let forwarded;
  const worker = createWorker({
    now: () => NOW,
    fetchImpl: async (_url, options) => {
      forwarded = JSON.parse(options.body);
      return new Response(JSON.stringify({
      status: "completed",
      output_text: JSON.stringify({
        claims: [{
          text: "The launch was approved, pending Gabby's final checklist.",
          supports: [{ evidenceID: "E-meeting", excerpt: "approved the launch" }],
        }],
      }),
      usage: { input_tokens: 400, output_tokens: 70 },
      }), { status: 200, headers: { "Content-Type": "application/json" } });
    },
  });
  const response = await worker.fetch(await v2AskRequest(v2ContinuationRequest()), workerEnv());
  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), {
    protocolVersion: 2,
    kind: "answer",
    claims: [{
      text: "The launch was approved, pending Gabby's final checklist.",
      supports: [{ evidenceID: "E-meeting", excerpt: "approved the launch" }],
    }],
  });
  assert.deepEqual(forwarded.input.slice(2).map((item) => [item.type, item.call_id]), [
    ["function_call", "call_latest_meeting_1"],
    ["function_call_output", "call_latest_meeting_1"],
  ]);
  const output = JSON.parse(forwarded.input[3].output);
  assert.equal(output.receipt.includes("evidence_ids=[E-meeting]"), true);
  assert.deepEqual(output.evidence.map((item) => item.id), ["E-meeting"]);
});

test("Worker rejects mismatched V2 headers and invalid upstream tool calls", async () => {
  let upstreamCalled = false;
  const mismatchWorker = createWorker({
    now: () => NOW,
    fetchImpl: async () => {
      upstreamCalled = true;
      return new Response("unexpected");
    },
  });
  const body = v2ClientRequest();
  const mismatch = await mismatchWorker.fetch(new Request("https://relay.example/v1/ask", {
    method: "POST",
    headers: {
      Authorization: await bearerHeader(body),
      "Content-Type": "application/json",
      "X-iAgent-Relay-Protocol": "1",
    },
    body: JSON.stringify(body),
  }), workerEnv());
  assert.equal(mismatch.status, 400);
  assert.equal(upstreamCalled, false);

  const invalidWorker = createWorker({
    now: () => NOW,
    fetchImpl: async () => new Response(JSON.stringify({
      status: "completed",
      output: [{
        type: "function_call",
        call_id: "call_forbidden_1",
        name: "delete_everything",
        arguments: "{}",
      }],
      usage: { input_tokens: 100, output_tokens: 20 },
    }), { status: 200, headers: { "Content-Type": "application/json" } }),
  });
  const invalid = await invalidWorker.fetch(await v2AskRequest(), workerEnv());
  assert.equal(invalid.status, 502);
  assert.deepEqual(await invalid.json(), { error: "invalid_upstream_output" });
});

test("fails closed on a claim whose excerpt is not in the supplied evidence", async () => {
  const worker = createWorker({
    now: () => NOW,
    fetchImpl: async () => new Response(
      JSON.stringify({
        status: "completed",
        output_text: JSON.stringify({
          claims: [{ text: "Invented result.", supports: [{ evidenceID: "E1", excerpt: "not present" }] }],
        }),
        usage: { input_tokens: 100, output_tokens: 20 },
      }),
      { status: 200, headers: { "Content-Type": "application/json" } },
    ),
  });
  const response = await worker.fetch(await askRequest(), workerEnv());
  assert.equal(response.status, 502);
  assert.deepEqual(await response.json(), { error: "invalid_upstream_output" });
});

test("charges the conservative reservation when a dispatched response cannot be parsed", async () => {
  const worker = createWorker({
    now: () => NOW,
    fetchImpl: async () => new Response("not-json", { status: 200 }),
  });
  const env = workerEnv();
  const response = await worker.fetch(await askRequest(), env);
  assert.equal(response.status, 503);
  assert.deepEqual(env.INSTALLATION_LIMITER.calls.map((call) => call.path), ["/reserve", "/settle"]);
  assert.equal(
    env.INSTALLATION_LIMITER.calls[1].body.actualMicros,
    env.INSTALLATION_LIMITER.calls[0].body.estimatedMicros,
  );
});

test("rejects an incomplete Responses API result", async () => {
  const worker = createWorker({
    now: () => NOW,
    fetchImpl: async () => new Response(JSON.stringify({
      status: "incomplete",
      output_text: JSON.stringify({
        claims: [{
          text: "Send the launch update before 4 PM.",
          supports: [{ evidenceID: "E1", excerpt: "Due today at 4 PM" }],
        }],
      }),
      usage: { input_tokens: 100, output_tokens: 20 },
    }), { status: 200, headers: { "Content-Type": "application/json" } }),
  });
  const response = await worker.fetch(await askRequest(), workerEnv());
  assert.equal(response.status, 502);
  assert.deepEqual(await response.json(), { error: "invalid_upstream_output" });
});

class MemoryStorage {
  values = new Map();

  async get(key) { return this.values.get(key); }
  async put(key, value) { this.values.set(key, structuredClone(value)); }
  async delete(key) { this.values.delete(key); }
  async deleteAll() { this.values.clear(); }
  async transaction(callback) { return callback(this); }
  async setAlarm(value) { this.alarm = value; }
  async deleteAlarm() { this.alarm = undefined; }
}

class ExchangePausingStorage extends MemoryStorage {
  constructor() {
    super();
    this.consumed = new Promise((resolve) => { this.resolveConsumed = resolve; });
    this.resume = new Promise((resolve) => { this.resolveResume = resolve; });
  }

  async put(key, value) {
    await super.put(key, value);
    if (key === "activeChallenge" && value?.consumed === true && !this.didPauseExchange) {
      this.didPauseExchange = true;
      this.resolveConsumed();
      await this.resume;
    }
  }

  resumeExchange() {
    this.resolveResume();
  }
}

class FailingSettlementStorage extends MemoryStorage {
  constructor(privateFailure) {
    super();
    this.privateFailure = privateFailure;
  }

  async transaction() {
    throw new Error(this.privateFailure);
  }
}

test("attestation diagnostics distinguish verifier, state, and settlement without leaking private inputs", async () => {
  const keyID = "K".repeat(43) + "=";
  const installationID = "private_installation_0123456789abcdef";
  const artifactText = "private-attestation-artifact-material";
  const privateFailure = `${installationID}:${keyID}:${artifactText}`;
  const logs = [];
  const logger = { error(value) { logs.push(value); } };
  const storage = new MemoryStorage();
  const state = new AttestationState({ storage }, workerEnv(), {
    logger,
    verifiers: {
      verifyAttestation: async () => {
        throw new AttestationError(
          privateFailure,
          401,
          ATTESTATION_DIAGNOSTIC_CODES.nodeAttestationVerificationFailed,
        );
      },
    },
  });
  const challengeResponse = await state.fetch(new Request("https://state/challenge", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      protocolVersion: 1,
      assurance: "app_attest",
      installationID,
      keyID,
      requestHash: "a".repeat(43),
      now: NOW,
    }),
  }));
  assert.equal(challengeResponse.status, 200);
  const challenge = await challengeResponse.json();
  const exchangeBody = {
    protocolVersion: 1,
    challengeID: challenge.challengeID,
    assurance: "app_attest",
    installationID,
    keyID,
    artifactType: "attestation",
    artifact: Buffer.from(artifactText).toString("base64"),
    now: NOW + 1,
  };

  const verifierFailure = await state.fetch(new Request("https://state/exchange", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(exchangeBody),
  }));
  assert.equal(verifierFailure.status, 401);
  assert.deepEqual(await verifierFailure.json(), { error: "unauthorized" });

  const stateFailure = await state.fetch(new Request("https://state/exchange", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ ...exchangeBody, now: NOW + 2 }),
  }));
  assert.equal(stateFailure.status, 401);
  assert.deepEqual(await stateFailure.json(), { error: "unauthorized" });

  const settlementLogs = [];
  const settlementStorage = new FailingSettlementStorage(privateFailure);
  const settlementState = new AttestationState({ storage: settlementStorage }, workerEnv(), {
    logger: { error(value) { settlementLogs.push(value); } },
    verifiers: {
      verifyAttestation: async () => ({
        publicKey: "verified-public-key",
        receipt: "private-receipt-not-for-observability",
        environment: "production",
        signCount: 0,
      }),
    },
  });
  const settlementChallengeResponse = await settlementState.fetch(new Request("https://state/challenge", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      protocolVersion: 1,
      assurance: "app_attest",
      installationID,
      keyID,
      requestHash: "b".repeat(43),
      now: NOW + 3,
    }),
  }));
  const settlementChallenge = await settlementChallengeResponse.json();
  const settlementFailure = await settlementState.fetch(new Request("https://state/exchange", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      ...exchangeBody,
      challengeID: settlementChallenge.challengeID,
      now: NOW + 4,
    }),
  }));
  assert.equal(settlementFailure.status, 503);
  assert.deepEqual(await settlementFailure.json(), { error: "attestation_unavailable" });

  assert.deepEqual(logs.map((log) => log.errorCode), [
    ATTESTATION_DIAGNOSTIC_CODES.nodeAttestationVerificationFailed,
    ATTESTATION_DIAGNOSTIC_CODES.stateInvalid,
  ]);
  assert.deepEqual(settlementLogs.map((log) => log.errorCode), [
    ATTESTATION_DIAGNOSTIC_CODES.settlementFailed,
  ]);
  for (const log of [...logs, ...settlementLogs]) {
    assert.deepEqual(Object.keys(log).sort(), ["errorCode", "event", "operation", "outcome"]);
    assert.equal(log.event, "attestation_verification");
    assert.equal(log.operation, "exchange");
    assert.equal(log.outcome, "error");
    const encoded = JSON.stringify(log);
    assert.equal(encoded.includes(installationID), false);
    assert.equal(encoded.includes(keyID), false);
    assert.equal(encoded.includes(artifactText), false);
    assert.equal(encoded.includes("private-receipt"), false);
    assert.equal(encoded.includes("verified-public-key"), false);
  }
});

test("only a verified development-environment mismatch receives the recovery envelope", async () => {
  const exchangeResponse = async (verificationError) => {
    const keyID = "E".repeat(43) + "=";
    const installationID = "environment_recovery_installation_01";
    const storage = new MemoryStorage();
    const logs = [];
    const state = new AttestationState({ storage }, workerEnv(), {
      logger: { error(value) { logs.push(value); } },
      verifiers: {
        verifyAttestation: async () => { throw verificationError; },
      },
    });
    const challengeResponse = await state.fetch(new Request("https://state/challenge", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        protocolVersion: 1,
        assurance: "app_attest",
        installationID,
        keyID,
        requestHash: "e".repeat(43),
        now: NOW,
      }),
    }));
    assert.equal(challengeResponse.status, 200);
    const challenge = await challengeResponse.json();
    const response = await state.fetch(new Request("https://state/exchange", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        protocolVersion: 1,
        challengeID: challenge.challengeID,
        assurance: "app_attest",
        installationID,
        keyID,
        artifactType: "attestation",
        artifact: Buffer.from("bounded-attestation").toString("base64"),
        now: NOW + 1,
      }),
    }));
    return { response, logs };
  };

  const recoverable = await exchangeResponse(new AppAttestEnvironmentMismatchError());
  assert.equal(recoverable.response.status, 401);
  assert.deepEqual(await recoverable.response.json(), {
    error: "unauthorized",
    code: "app_attest_environment_mismatch",
  });
  assert.deepEqual(recoverable.logs.map((value) => value.errorCode), [
    ATTESTATION_DIAGNOSTIC_CODES.environmentMismatch,
  ]);

  const generic = await exchangeResponse(new AttestationError(
    "private-verifier-detail",
    401,
    ATTESTATION_DIAGNOSTIC_CODES.environmentInvalid,
  ));
  assert.equal(generic.response.status, 401);
  assert.deepEqual(await generic.response.json(), { error: "unauthorized" });
  assert.deepEqual(generic.logs.map((value) => value.errorCode), [
    ATTESTATION_DIAGNOSTIC_CODES.environmentInvalid,
  ]);
});

test("a client cancellation aborts OpenAI, settles once, and immediately releases concurrency for retry", async () => {
  const limiter = new StatefulLimiterNamespace();
  const env = workerEnv({
    INSTALLATION_LIMITER: limiter,
    MAX_CONCURRENT_REQUESTS: "1",
    REQUESTS_PER_MINUTE: "12",
  });
  let upstreamCalls = 0;
  let firstStarted;
  const started = new Promise((resolve) => { firstStarted = resolve; });
  const worker = createWorker({
    now: () => NOW,
    logger: { info() {} },
    fetchImpl: async (_url, options) => {
      upstreamCalls += 1;
      if (upstreamCalls === 1) {
        firstStarted();
        return new Promise((_resolve, reject) => {
          options.signal.addEventListener(
            "abort",
            () => reject(options.signal.reason ?? new DOMException("Aborted", "AbortError")),
            { once: true },
          );
        });
      }
      return new Response(JSON.stringify({
        status: "completed",
        output_text: JSON.stringify({
          claims: [{
            text: "Send the launch update before 4 PM.",
            supports: [{ evidenceID: "E1", excerpt: "Due today at 4 PM" }],
          }],
        }),
        usage: { input_tokens: 100, output_tokens: 20 },
      }), { status: 200, headers: { "Content-Type": "application/json" } });
    },
  });

  const body = clientRequest();
  const clientController = new AbortController();
  const first = worker.fetch(await askRequest(body, {
    Authorization: await bearerHeader(body, { tokenID: "token_cancel_000000000000001" }),
  }, clientController.signal), env);
  await started;
  clientController.abort();
  const cancelled = await first;
  assert.equal(cancelled.status, 499);
  assert.deepEqual(await cancelled.json(), { error: "client_closed_request" });
  assert.deepEqual(limiter.calls.map((call) => call.path), ["/reserve", "/settle"]);

  const retry = await worker.fetch(await askRequest(body, {
    Authorization: await bearerHeader(body, { tokenID: "token_cancel_000000000000002" }),
  }), env);
  assert.equal(retry.status, 200);
  assert.equal(upstreamCalls, 2);
  assert.deepEqual(limiter.calls.map((call) => call.path), [
    "/reserve", "/settle", "/reserve", "/settle",
  ]);
});

test("one bearer token cannot replay a request or duplicate model spend", async () => {
  const limiter = new StatefulLimiterNamespace();
  const env = workerEnv({ INSTALLATION_LIMITER: limiter });
  let upstreamCalls = 0;
  const worker = createWorker({
    now: () => NOW,
    logger: { info() {} },
    fetchImpl: async () => {
      upstreamCalls += 1;
      return new Response(JSON.stringify({
        status: "completed",
        output_text: JSON.stringify({
          claims: [{
            text: "Send the launch update before 4 PM.",
            supports: [{ evidenceID: "E1", excerpt: "Due today at 4 PM" }],
          }],
        }),
        usage: { input_tokens: 100, output_tokens: 20 },
      }), { status: 200, headers: { "Content-Type": "application/json" } });
    },
  });
  const body = clientRequest();
  const authorization = await bearerHeader(body, { tokenID: "token_no_duplicate_spend_0001" });
  assert.equal((await worker.fetch(await askRequest(body, { Authorization: authorization }), env)).status, 200);
  const replay = await worker.fetch(await askRequest(body, { Authorization: authorization }), env);
  assert.equal(replay.status, 401);
  assert.equal(upstreamCalls, 1);
});

test("production rate gates admit a four-round turn, retry, and an immediate second turn", async () => {
  const wrangler = JSON.parse(readFileSync(new URL("../wrangler.jsonc", import.meta.url), "utf8"));
  assert.equal(Number(wrangler.vars.REQUESTS_PER_MINUTE), 12);
  assert.equal(Number(wrangler.vars.CHALLENGE_REQUESTS_PER_MINUTE), 12);
  assert.ok(Number(wrangler.vars.ATTESTATION_NETWORK_REQUESTS_PER_MINUTE) >= 12);
  assert.ok(wrangler.compatibility_flags.includes("enable_request_signal"));
  assert.ok(wrangler.vars.APP_ATTEST_ALLOWED_BUNDLE_VERSIONS.split(",").includes("27"));

  const storage = new MemoryStorage();
  const limiter = new InstallationLimiter({ storage }, {});
  for (let index = 0; index < 10; index += 1) {
    const requestID = `request_turn_budget_${String(index).padStart(4, "0")}`;
    const response = await limiter.fetch(new Request("https://limiter/reserve", {
      method: "POST",
      body: JSON.stringify({
        requestID,
        tokenID: `token_turn_budget_${String(index).padStart(5, "0")}`,
        tokenExpiresAt: NOW + 300_000,
        now: NOW + index,
        estimatedMicros: 1,
        requestsPerMinute: 12,
        maxConcurrentRequests: 1,
        dailySpendLimitMicros: 1_000,
        leaseMilliseconds: 60_000,
      }),
    }));
    assert.equal(response.status, 200);
    assert.equal((await limiter.fetch(new Request("https://limiter/release", {
      method: "POST",
      body: JSON.stringify({ requestID, now: NOW + index, actualMicros: null }),
    }))).status, 200);
  }
});

test("Worker emits one privacy-safe trace and correlates client and upstream request IDs", async () => {
  const logs = [];
  let upstreamClientRequestID;
  const worker = createWorker({
    now: () => NOW,
    logger: { info(value) { logs.push(value); } },
    fetchImpl: async (_url, options) => {
      upstreamClientRequestID = options.headers["X-Client-Request-Id"];
      return new Response(JSON.stringify({
        status: "completed",
        output_text: JSON.stringify({
          claims: [{
            text: "Send the launch update before 4 PM.",
            supports: [{ evidenceID: "E1", excerpt: "Due today at 4 PM" }],
          }],
        }),
        usage: { input_tokens: 100, output_tokens: 20 },
      }), { status: 200 });
    },
  });
  const response = await worker.fetch(await askRequest(), workerEnv());
  const responseRequestID = response.headers.get("X-iAgent-Request-ID");
  assert.match(responseRequestID, /^iareq_[a-f0-9]{32}$/u);
  assert.equal(upstreamClientRequestID, responseRequestID);
  assert.equal(logs.length, 1);
  assert.deepEqual(Object.keys(logs[0]).sort(), [
    "errorCode", "event", "latencyMs", "outcome", "protocolVersion", "requestID", "round", "tier",
  ]);
  assert.equal(logs[0].requestID, responseRequestID);
  assert.equal(logs[0].tier, "fast");
  const encodedLog = JSON.stringify(logs[0]);
  assert.equal(encodedLog.includes(clientRequest().prompt), false);
  assert.equal(encodedLog.includes(INSTALLATION_ID), false);
  assert.equal(encodedLog.includes("Due today"), false);
});

test("a retry supersedes an abandoned attestation challenge without weakening replay checks", async () => {
  const storage = new MemoryStorage();
  const state = new AttestationState({ storage }, workerEnv());
  const keyID = "A".repeat(43) + "=";
  const challengeBody = {
    protocolVersion: 1,
    assurance: "app_attest",
    installationID: INSTALLATION_ID,
    keyID,
    requestHash: "a".repeat(43),
  };
  const challengeRequest = (requestHash, now) => new Request("https://state/challenge", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ ...challengeBody, requestHash, now }),
  });

  const first = await state.fetch(challengeRequest("a".repeat(43), NOW));
  assert.equal(first.status, 200);
  const firstEnvelope = await first.json();

  const second = await state.fetch(challengeRequest("b".repeat(43), NOW + 1));
  assert.equal(second.status, 200);
  const secondEnvelope = await second.json();
  assert.notEqual(secondEnvelope.challengeID, firstEnvelope.challengeID);
  assert.equal((await storage.get("activeChallenge")).id, secondEnvelope.challengeID);
  assert.equal((await storage.get("challengeRate")).length, 2);

  const staleExchange = await state.fetch(new Request("https://state/exchange", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      ...challengeBody,
      challengeID: firstEnvelope.challengeID,
      artifactType: "attestation",
      artifact: Buffer.from("stale-attestation").toString("base64"),
      now: NOW + 2,
    }),
  }));
  assert.equal(staleExchange.status, 401);
  assert.equal((await storage.get("activeChallenge")).id, secondEnvelope.challengeID);
  assert.equal((await storage.get("activeChallenge")).consumed, false);

  for (let index = 2; index < 12; index += 1) {
    const allowed = await state.fetch(challengeRequest("b".repeat(43), NOW + index + 1));
    assert.equal(allowed.status, 200);
  }
  const limited = await state.fetch(challengeRequest("b".repeat(43), NOW + 20));
  assert.equal(limited.status, 429);
});

test("challenge exposes a non-secret recovery code only for an established identity binding mismatch", async () => {
  const keyID = "A".repeat(43) + "=";
  const establishedInstallationID = INSTALLATION_ID;
  const presentedInstallationID = "replacement_0123456789abcdefghijkl";
  const record = {
    assurance: "app_attest",
    installationID: establishedInstallationID,
    keyID,
    publicKey: "established-public-key",
    receipt: "private-apple-receipt",
    environment: "production",
    signCount: 3,
    createdAt: NOW - 10_000,
    lastVerifiedAt: NOW - 1_000,
    recordVersion: 4,
  };
  const challengeBody = {
    protocolVersion: 1,
    assurance: "app_attest",
    installationID: presentedInstallationID,
    keyID,
    requestHash: "a".repeat(43),
    now: NOW,
  };

  const mismatchStorage = new MemoryStorage();
  await mismatchStorage.put("attestationRecord", record);
  const mismatchState = new AttestationState({ storage: mismatchStorage }, workerEnv());
  const mismatch = await mismatchState.fetch(new Request("https://state/challenge", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(challengeBody),
  }));
  assert.equal(mismatch.status, 401);
  assert.deepEqual(await mismatch.clone().json(), {
    error: "unauthorized",
    code: "app_attest_identity_binding_mismatch",
  });
  const encodedMismatch = await mismatch.text();
  for (const secret of [
    establishedInstallationID,
    presentedInstallationID,
    keyID,
    record.publicKey,
    record.receipt,
    record.environment,
  ]) {
    assert.equal(encodedMismatch.includes(secret), false);
  }
  assert.equal(await mismatchStorage.get("activeChallenge"), undefined);
  assert.equal(await mismatchStorage.get("challengeRate"), undefined);

  // A malformed/corrupt record is not a trustworthy binding oracle and stays generic.
  const corruptStorage = new MemoryStorage();
  await corruptStorage.put("attestationRecord", { ...record, publicKey: "" });
  const corruptState = new AttestationState({ storage: corruptStorage }, workerEnv());
  const corrupt = await corruptState.fetch(new Request("https://state/challenge", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(challengeBody),
  }));
  assert.equal(corrupt.status, 401);
  assert.deepEqual(await corrupt.json(), { error: "unauthorized" });

  // A key inconsistency in the per-key object is likewise generic, not recoverable.
  const wrongKeyStorage = new MemoryStorage();
  await wrongKeyStorage.put("attestationRecord", { ...record, keyID: "B".repeat(43) + "=" });
  const wrongKeyState = new AttestationState({ storage: wrongKeyStorage }, workerEnv());
  const wrongKey = await wrongKeyState.fetch(new Request("https://state/challenge", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(challengeBody),
  }));
  assert.equal(wrongKey.status, 401);
  assert.deepEqual(await wrongKey.json(), { error: "unauthorized" });
});

test("an accepted attestation exchange cannot erase a replacement challenge while verification yields", async () => {
  const now = NOW;
  const storage = new ExchangePausingStorage();
  const keyID = "A".repeat(43) + "=";
  const state = new AttestationState({ storage }, workerEnv(), {
    verifiers: {
      verifyAttestation: async () => ({
        publicKey: "same-verified-public-key",
        receipt: "verified-receipt",
        environment: "production",
        signCount: 0,
      }),
    },
  });
  const firstChallenge = {
    id: "challenge_identifier_exchange_a",
    mode: "attestation",
    assurance: "app_attest",
    installationID: INSTALLATION_ID,
    keyID,
    requestHash: "a".repeat(43),
    clientData: Buffer.from("server-controlled-client-data-a").toString("base64url"),
    expiresAt: now + 120_000,
    consumed: false,
  };
  await storage.put("challengeRate", [now]);
  await storage.put("activeChallenge", firstChallenge);
  await storage.setAlarm(firstChallenge.expiresAt + 1_000);

  const firstExchange = state.fetch(new Request("https://state/exchange", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      protocolVersion: 1,
      challengeID: firstChallenge.id,
      assurance: "app_attest",
      installationID: INSTALLATION_ID,
      keyID,
      artifactType: "attestation",
      artifact: Buffer.from("attestation-a").toString("base64"),
      now,
    }),
  }));
  await storage.consumed;
  assert.equal((await storage.get("activeChallenge")).consumed, true);

  const replacement = await state.fetch(new Request("https://state/challenge", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      protocolVersion: 1,
      assurance: "app_attest",
      installationID: INSTALLATION_ID,
      keyID,
      requestHash: "b".repeat(43),
      now: now + 1,
    }),
  }));
  assert.equal(replacement.status, 200);
  const replacementEnvelope = await replacement.json();
  assert.equal(replacementEnvelope.mode, "attestation");
  const replacementAlarm = replacementEnvelope.expiresAt + 1_000;
  assert.equal((await storage.get("activeChallenge")).id, replacementEnvelope.challengeID);
  assert.equal((await storage.get("activeChallenge")).consumed, false);
  assert.deepEqual(await storage.get("challengeRate"), [now, now + 1]);
  assert.equal(storage.alarm, replacementAlarm);

  storage.resumeExchange();
  const completed = await firstExchange;
  assert.equal(completed.status, 200);
  assert.equal((await storage.get("activeChallenge")).id, replacementEnvelope.challengeID);
  assert.equal((await storage.get("activeChallenge")).consumed, false);
  assert.deepEqual(await storage.get("challengeRate"), [now, now + 1]);
  assert.equal(storage.alarm, replacementAlarm);
  assert.deepEqual(await storage.get("attestationRecord"), {
    assurance: "app_attest",
    installationID: INSTALLATION_ID,
    keyID,
    publicKey: "same-verified-public-key",
    receipt: "verified-receipt",
    environment: "production",
    signCount: 0,
    createdAt: now,
    lastVerifiedAt: now,
    recordVersion: 1,
  });

  const replay = await state.fetch(new Request("https://state/exchange", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      protocolVersion: 1,
      challengeID: firstChallenge.id,
      assurance: "app_attest",
      installationID: INSTALLATION_ID,
      keyID,
      artifactType: "attestation",
      artifact: Buffer.from("attestation-a").toString("base64"),
      now: now + 2,
    }),
  }));
  assert.equal(replay.status, 401);
  assert.equal((await storage.get("activeChallenge")).id, replacementEnvelope.challengeID);
  assert.equal((await storage.get("activeChallenge")).consumed, false);
  assert.deepEqual(await storage.get("challengeRate"), [now, now + 1]);
  assert.equal(storage.alarm, replacementAlarm);

  const replacementExchange = await state.fetch(new Request("https://state/exchange", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      protocolVersion: 1,
      challengeID: replacementEnvelope.challengeID,
      assurance: "app_attest",
      installationID: INSTALLATION_ID,
      keyID,
      artifactType: "attestation",
      artifact: Buffer.from("attestation-b").toString("base64"),
      now: now + 3,
    }),
  }));
  assert.equal(replacementExchange.status, 200);
  assert.equal(await storage.get("activeChallenge"), undefined);
  assert.deepEqual(await storage.get("challengeRate"), [now, now + 1]);
  assert.equal(storage.alarm, replacementAlarm);
  assert.deepEqual(await storage.get("attestationRecord"), {
    assurance: "app_attest",
    installationID: INSTALLATION_ID,
    keyID,
    publicKey: "same-verified-public-key",
    receipt: "verified-receipt",
    environment: "production",
    signCount: 0,
    createdAt: now,
    lastVerifiedAt: now + 3,
    recordVersion: 2,
  });

  const replacementReplay = await state.fetch(new Request("https://state/exchange", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      protocolVersion: 1,
      challengeID: replacementEnvelope.challengeID,
      assurance: "app_attest",
      installationID: INSTALLATION_ID,
      keyID,
      artifactType: "attestation",
      artifact: Buffer.from("attestation-b").toString("base64"),
      now: now + 4,
    }),
  }));
  assert.equal(replacementReplay.status, 401);
});

test("overlapping assertion settlements cannot regress the durable sign counter", async () => {
  const storage = new MemoryStorage();
  const keyID = "A".repeat(43) + "=";
  const baseRecord = {
    assurance: "app_attest",
    installationID: INSTALLATION_ID,
    keyID,
    publicKey: "assertion-public-key",
    receipt: "established-receipt",
    environment: "production",
    signCount: 5,
    createdAt: NOW - 60_000,
    lastVerifiedAt: NOW - 30_000,
    recordVersion: 9,
  };
  await storage.put("attestationRecord", baseRecord);

  const controls = new Map(["assertion-a", "assertion-b"].map((name) => {
    let markStarted;
    let release;
    return [name, {
      started: new Promise((resolve) => { markStarted = resolve; }),
      markStarted,
      released: new Promise((resolve) => { release = resolve; }),
      release,
    }];
  }));
  const state = new AttestationState({ storage }, workerEnv(), {
    verifiers: {
      verifyAssertion: async ({ artifact, signCount }) => {
        const name = artifact.toString("utf8");
        const control = controls.get(name);
        assert.ok(control);
        assert.equal(signCount, 5);
        control.markStarted();
        await control.released;
        return { signCount: name === "assertion-a" ? 6 : 7 };
      },
    },
  });
  const issueChallenge = async (requestHash, now) => {
    const response = await state.fetch(new Request("https://state/challenge", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        protocolVersion: 1,
        assurance: "app_attest",
        installationID: INSTALLATION_ID,
        keyID,
        requestHash,
        now,
      }),
    }));
    assert.equal(response.status, 200);
    const envelope = await response.json();
    assert.equal(envelope.mode, "assertion");
    return envelope;
  };
  const exchangeAssertion = (challenge, name, now) => state.fetch(new Request("https://state/exchange", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      protocolVersion: 1,
      challengeID: challenge.challengeID,
      assurance: "app_attest",
      installationID: INSTALLATION_ID,
      keyID,
      artifactType: "assertion",
      artifact: Buffer.from(name).toString("base64"),
      now,
    }),
  }));

  const firstChallenge = await issueChallenge("a".repeat(43), NOW);
  const firstExchange = exchangeAssertion(firstChallenge, "assertion-a", NOW + 1);
  await controls.get("assertion-a").started;

  const secondChallenge = await issueChallenge("b".repeat(43), NOW + 2);
  const secondExchange = exchangeAssertion(secondChallenge, "assertion-b", NOW + 3);
  await controls.get("assertion-b").started;

  // Complete the newer, higher counter first, then let the stale lower result settle last.
  controls.get("assertion-b").release();
  assert.equal((await secondExchange).status, 200);
  assert.equal((await storage.get("attestationRecord")).signCount, 7);
  assert.equal((await storage.get("attestationRecord")).recordVersion, 10);

  controls.get("assertion-a").release();
  assert.equal((await firstExchange).status, 200);
  assert.deepEqual(await storage.get("attestationRecord"), {
    ...baseRecord,
    signCount: 7,
    lastVerifiedAt: NOW + 3,
    recordVersion: 11,
  });
});

test("attestation Durable Object rejects expired challenges and consumes failed exchanges", async () => {
  const storage = new MemoryStorage();
  const state = new AttestationState({ storage }, workerEnv());
  const keyID = "A".repeat(43) + "=";
  const challengeBody = {
    protocolVersion: 1,
    assurance: "app_attest",
    installationID: INSTALLATION_ID,
    keyID,
    requestHash: "a".repeat(43),
    now: NOW,
  };
  const challenge = await state.fetch(new Request("https://state/challenge", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(challengeBody),
  }));
  assert.equal(challenge.status, 200);
  const challengeEnvelope = await challenge.json();

  const expired = await state.fetch(new Request("https://state/exchange", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      ...challengeBody,
      challengeID: challengeEnvelope.challengeID,
      artifactType: "attestation",
      artifact: Buffer.from("invalid-attestation").toString("base64"),
      now: NOW + 121_000,
    }),
  }));
  assert.equal(expired.status, 401);
  assert.deepEqual(await expired.json(), { error: "unauthorized" });

  await storage.delete("activeChallenge");
  const fresh = await state.fetch(new Request("https://state/challenge", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ ...challengeBody, now: NOW + 122_000 }),
  }));
  const freshEnvelope = await fresh.json();
  const failedExchangeBody = {
    ...challengeBody,
    challengeID: freshEnvelope.challengeID,
    artifactType: "attestation",
    artifact: Buffer.from("invalid-attestation").toString("base64"),
    now: NOW + 123_000,
  };
  const failed = await state.fetch(new Request("https://state/exchange", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(failedExchangeBody),
  }));
  assert.equal(failed.status, 401);
  assert.deepEqual(await failed.json(), { error: "unauthorized" });
  assert.equal((await storage.get("activeChallenge")).consumed, true);

  const replay = await state.fetch(new Request("https://state/exchange", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ ...failedExchangeBody, now: NOW + 124_000 }),
  }));
  assert.equal(replay.status, 401);
  assert.deepEqual(await replay.json(), { error: "unauthorized" });

  await state.alarm();
  assert.equal(storage.values.size, 0);
});

test("global attestation gate bounds rotating identities and DeviceCheck token replay", async () => {
  const storage = new MemoryStorage();
  const env = workerEnv({
    ATTESTATION_GLOBAL_REQUESTS_PER_MINUTE: "2",
    ATTESTATION_NETWORK_REQUESTS_PER_MINUTE: "1",
    DEVICECHECK_FALLBACK_ENABLED: "true",
    APPLE_DEVICECHECK_KEY_ID: "ABCDEFGHIJ",
    APPLE_DEVICECHECK_PRIVATE_KEY: "test-private-key-material-that-is-long-enough",
  });
  const state = new AttestationState({ storage }, env);
  const gate = (subject, now) => state.fetch(new Request("https://state/gate", {
    method: "POST",
    body: JSON.stringify({ subject, now }),
  }));
  assert.equal((await gate("A".repeat(43), NOW)).status, 200);
  assert.equal((await gate("A".repeat(43), NOW + 1)).status, 429);
  assert.equal((await gate("B".repeat(43), NOW + 2)).status, 200);
  assert.equal((await gate("C".repeat(43), NOW + 3)).status, 429);

  const consume = (now) => state.fetch(new Request("https://state/consume-devicecheck", {
    method: "POST",
    body: JSON.stringify({ tokenHash: "D".repeat(43), now }),
  }));
  assert.equal((await consume(NOW + 4)).status, 200);
  assert.equal((await consume(NOW + 5)).status, 401);
});

test("DeviceCheck requests share one server-controlled hard budget bucket", async () => {
  const namespace = new FakeLimiterNamespace();
  const config = {
    limiterNamespace: namespace,
    requestsPerMinute: 4,
    maxConcurrentRequests: 1,
    dailySpendLimitMicros: 1_000_000,
    deviceCheckRequestsPerMinute: 2,
    deviceCheckMaxConcurrentRequests: 1,
    deviceCheckDailySpendLimitMicros: 150_000,
    reservationLeaseMilliseconds: 60_000,
  };
  await reserveInstallationBudget(config, "client-selected-installation-one", 100, NOW, {
    tokenID: "token_identifier_global_0001",
    tokenExpiresAt: NOW + 180_000,
    attestation: "devicecheck",
  });
  await reserveInstallationBudget(config, "client-selected-installation-two", 100, NOW + 1, {
    tokenID: "token_identifier_global_0002",
    tokenExpiresAt: NOW + 180_000,
    attestation: "devicecheck",
  });
  assert.equal(namespace.calls.length, 2);
  assert.equal(namespace.calls[0].id, "devicecheck-global-hard-cap-v1");
  assert.equal(namespace.calls[1].id, "devicecheck-global-hard-cap-v1");
});

test("Durable Object enforces per-installation rate and spend limits", async () => {
  const storage = new MemoryStorage();
  const limiter = new InstallationLimiter({ storage }, {});
  const reserveBody = {
    requestID: "request_identifier_00000001",
    tokenID: "token_identifier_000000001",
    tokenExpiresAt: NOW + 300_000,
    now: NOW,
    estimatedMicros: 500,
    requestsPerMinute: 1,
    maxConcurrentRequests: 2,
    dailySpendLimitMicros: 1_000,
    leaseMilliseconds: 60_000,
  };
  const first = await limiter.fetch(new Request("https://limiter/reserve", {
    method: "POST",
    body: JSON.stringify(reserveBody),
  }));
  assert.equal(first.status, 200);
  const second = await limiter.fetch(new Request("https://limiter/reserve", {
    method: "POST",
    body: JSON.stringify({
      ...reserveBody,
      requestID: "request_identifier_00000002",
      tokenID: "token_identifier_000000002",
    }),
  }));
  assert.equal(second.status, 429);
  const settle = await limiter.fetch(new Request("https://limiter/settle", {
    method: "POST",
    body: JSON.stringify({ requestID: reserveBody.requestID, now: NOW, actualMicros: 450 }),
  }));
  assert.equal(settle.status, 200);
  assert.equal((await storage.get("limits")).spentMicros, 450);
  const overBudget = await limiter.fetch(new Request("https://limiter/reserve", {
    method: "POST",
    body: JSON.stringify({
      ...reserveBody,
      requestID: "request_identifier_00000003",
      tokenID: "token_identifier_000000003",
      tokenExpiresAt: NOW + 400_000,
      now: NOW + 61_000,
      estimatedMicros: 600,
    }),
  }));
  assert.equal(overBudget.status, 429);
  assert.deepEqual(await overBudget.json(), { error: "daily_spend_limit" });
});

test("Durable Object consumes bearer token IDs exactly once", async () => {
  const storage = new MemoryStorage();
  const limiter = new InstallationLimiter({ storage }, {});
  const body = {
    requestID: "request_identifier_replay_001",
    tokenID: "token_identifier_replay_001",
    tokenExpiresAt: NOW + 180_000,
    now: NOW,
    estimatedMicros: 100,
    requestsPerMinute: 4,
    maxConcurrentRequests: 2,
    dailySpendLimitMicros: 1_000,
    leaseMilliseconds: 60_000,
  };
  const first = await limiter.fetch(new Request("https://limiter/reserve", {
    method: "POST",
    body: JSON.stringify(body),
  }));
  assert.equal(first.status, 200);
  const replay = await limiter.fetch(new Request("https://limiter/reserve", {
    method: "POST",
    body: JSON.stringify({ ...body, requestID: "request_identifier_replay_002" }),
  }));
  assert.equal(replay.status, 401);
  assert.deepEqual(await replay.json(), { error: "token_replayed" });
});
