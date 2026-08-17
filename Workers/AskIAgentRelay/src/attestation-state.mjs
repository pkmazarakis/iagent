import {
  ATTESTATION_DIAGNOSTIC_CODES,
  AppAttestEnvironmentMismatchError,
  AttestationError,
  decodeClientData,
  sha256Base64URL,
  validateDeviceCheckToken,
  verifyAppAttestAssertion,
  verifyAppAttestAttestation,
} from "./attestation.mjs";
import {
  bytesToBase64URL,
  createAnonymousInstallationToken,
  deriveAnonymousInstallationSubject,
} from "./auth.mjs";
import { loadAttestationConfig } from "./config.mjs";

function json(status, value, extraHeaders = {}) {
  return new Response(JSON.stringify(value), {
    status,
    headers: {
      "Content-Type": "application/json; charset=utf-8",
      "Cache-Control": "no-store",
      "X-Content-Type-Options": "nosniff",
      ...extraHeaders,
    },
  });
}

function randomBase64URL(byteCount) {
  const bytes = new Uint8Array(byteCount);
  crypto.getRandomValues(bytes);
  return bytesToBase64URL(bytes);
}

function challengeMode(record, assurance) {
  if (assurance === "devicecheck") return "devicecheck";
  return record ? "assertion" : "attestation";
}

const APP_ATTEST_IDENTITY_BINDING_MISMATCH = "app_attest_identity_binding_mismatch";
const APP_ATTEST_ENVIRONMENT_MISMATCH = "app_attest_environment_mismatch";

function diagnosticError(code, status = 401) {
  return new AttestationError(status === 503 ? "attestation_unavailable" : "unauthorized", status, code);
}

function stateError() {
  return diagnosticError(ATTESTATION_DIAGNOSTIC_CODES.stateInvalid);
}

function settlementError(status = 401) {
  return diagnosticError(ATTESTATION_DIAGNOSTIC_CODES.settlementFailed, status);
}

function prunedRateTimestamps(value, now) {
  return Array.isArray(value)
    ? value.filter((timestamp) => Number.isSafeInteger(timestamp) && timestamp > now - 60_000)
    : [];
}

function prunedGlobalGateState(value, now) {
  const state = value && typeof value === "object" ? structuredClone(value) : {};
  state.totalTimestamps = prunedRateTimestamps(state.totalTimestamps, now);
  state.subjectTimestamps = state.subjectTimestamps && typeof state.subjectTimestamps === "object"
    ? state.subjectTimestamps
    : {};
  for (const [subject, timestamps] of Object.entries(state.subjectTimestamps)) {
    const pruned = prunedRateTimestamps(timestamps, now);
    if (pruned.length === 0) delete state.subjectTimestamps[subject];
    else state.subjectTimestamps[subject] = pruned;
  }
  state.usedDeviceCheckTokens = state.usedDeviceCheckTokens && typeof state.usedDeviceCheckTokens === "object"
    ? state.usedDeviceCheckTokens
    : {};
  for (const [tokenHash, expiresAt] of Object.entries(state.usedDeviceCheckTokens)) {
    if (!Number.isSafeInteger(expiresAt) || expiresAt <= now) delete state.usedDeviceCheckTokens[tokenHash];
  }
  return state;
}

export function attestationStateName(body) {
  return body.assurance === "app_attest"
    ? `app-attest:${body.keyID}`
    : `devicecheck:${body.installationID}`;
}

function recordVersion(record, diagnosticCode = ATTESTATION_DIAGNOSTIC_CODES.stateInvalid) {
  const value = record?.recordVersion;
  if (value === undefined) return 0;
  if (!Number.isSafeInteger(value) || value < 0) throw diagnosticError(diagnosticCode);
  return value;
}

function nextRecordVersion(record, diagnosticCode = ATTESTATION_DIAGNOSTIC_CODES.stateInvalid) {
  const value = recordVersion(record, diagnosticCode);
  if (value >= Number.MAX_SAFE_INTEGER) throw diagnosticError(diagnosticCode);
  return value + 1;
}

function assertAppAttestRecord(
  record,
  diagnosticCode = ATTESTATION_DIAGNOSTIC_CODES.stateInvalid,
) {
  if (
    record?.assurance !== "app_attest"
    || typeof record.installationID !== "string"
    || typeof record.keyID !== "string"
    || typeof record.publicKey !== "string"
    || record.publicKey.length === 0
    || typeof record.environment !== "string"
    || !Number.isSafeInteger(record.signCount)
    || record.signCount < 0
    || !Number.isSafeInteger(record.createdAt)
    || !Number.isSafeInteger(record.lastVerifiedAt)
  ) {
    throw diagnosticError(diagnosticCode);
  }
  recordVersion(record, diagnosticCode);
}

function mergeAppAttestRecords(
  current,
  candidate,
  diagnosticCode = ATTESTATION_DIAGNOSTIC_CODES.stateInvalid,
) {
  assertAppAttestRecord(current, diagnosticCode);
  assertAppAttestRecord(candidate, diagnosticCode);
  if (
    current.installationID !== candidate.installationID
    || current.keyID !== candidate.keyID
    || current.publicKey !== candidate.publicKey
    || current.environment !== candidate.environment
  ) {
    throw diagnosticError(diagnosticCode);
  }
  // The established record remains authoritative. Only monotonic facts from a verified
  // concurrent result may advance it; a late completion cannot replace key material, receipt,
  // environment, creation metadata, or an already-higher assertion counter.
  return {
    ...current,
    createdAt: Math.min(current.createdAt, candidate.createdAt),
    lastVerifiedAt: Math.max(current.lastVerifiedAt, candidate.lastVerifiedAt),
    signCount: Math.max(current.signCount, candidate.signCount),
  };
}

function settleAttestationRecord(current, result) {
  const diagnosticCode = ATTESTATION_DIAGNOSTIC_CODES.settlementFailed;
  const settlement = result?.settlement;
  if (
    !settlement
    || !Number.isSafeInteger(settlement.baseRecordVersion)
    || settlement.baseRecordVersion < 0
  ) {
    throw settlementError();
  }
  const currentVersion = recordVersion(current, diagnosticCode);
  // A base version newer than durable storage indicates rollback/corruption rather than a
  // harmless concurrent completion. Never settle it.
  if (settlement.baseRecordVersion > currentVersion) throw settlementError();

  if (result.record?.assurance === "app_attest") {
    assertAppAttestRecord(result.record, diagnosticCode);
    if (!current) {
      if (settlement.kind !== "attestation" || settlement.baseRecordVersion !== 0) {
        throw settlementError();
      }
      return { ...result.record, recordVersion: 1 };
    }
    if (settlement.kind !== "attestation" && settlement.kind !== "assertion") {
      throw settlementError();
    }
    return {
      ...mergeAppAttestRecords(current, result.record, diagnosticCode),
      recordVersion: nextRecordVersion(current, diagnosticCode),
    };
  }

  if (result.record?.assurance !== "devicecheck" || settlement.kind !== "devicecheck") {
    throw settlementError();
  }
  if (!current) {
    if (settlement.baseRecordVersion !== 0) throw settlementError();
    return { ...result.record, recordVersion: 1 };
  }
  if (
    current.assurance !== "devicecheck"
    || current.installationID !== result.record.installationID
  ) {
    throw settlementError();
  }
  const recentTokenHashes = Array.isArray(current.recentTokenHashes)
    ? current.recentTokenHashes.filter((value) => typeof value === "string")
    : [];
  for (const tokenHash of result.record.recentTokenHashes ?? []) {
    if (typeof tokenHash === "string" && !recentTokenHashes.includes(tokenHash)) {
      recentTokenHashes.push(tokenHash);
    }
  }
  return {
    ...current,
    createdAt: Math.min(current.createdAt, result.record.createdAt),
    lastVerifiedAt: Math.max(current.lastVerifiedAt, result.record.lastVerifiedAt),
    recentTokenHashes: recentTokenHashes.slice(-8),
    recordVersion: nextRecordVersion(current, diagnosticCode),
  };
}

export async function processAttestationExchange(
  { record, challenge, body, config, now, fetchImpl },
  verifiers = {
    verifyAttestation: verifyAppAttestAttestation,
    verifyAssertion: verifyAppAttestAssertion,
    verifyDeviceCheck: validateDeviceCheckToken,
  },
) {
  const clientData = decodeClientData(challenge.clientData);
  if (body.assurance === "app_attest") {
    if (body.artifactType === "attestation") {
      if (
        record
        && (
          record.assurance !== "app_attest"
          || record.installationID !== body.installationID
          || record.keyID !== body.keyID
        )
      ) {
        throw stateError();
      }
      const verification = await verifiers.verifyAttestation({
        artifact: body.artifact,
        clientData,
        keyID: body.keyID,
        config,
        now,
      });
      const verifiedRecord = {
        assurance: "app_attest",
        installationID: body.installationID,
        keyID: body.keyID,
        publicKey: verification.publicKey,
        receipt: verification.receipt,
        environment: verification.environment,
        signCount: 0,
        createdAt: now,
        lastVerifiedAt: now,
      };
      return {
        // A replacement challenge can have been issued as first-use attestation immediately
        // before another accepted exchange stores this key. Re-verification is allowed only for
        // the exact same installation, key, public key, and environment; merge then preserves the
        // established creation time and assertion counter.
        record: record ? mergeAppAttestRecords(record, verifiedRecord) : verifiedRecord,
        stableIdentifier: body.keyID,
        settlement: { kind: "attestation", baseRecordVersion: recordVersion(record) },
      };
    }
    if (!record || record.installationID !== body.installationID || record.keyID !== body.keyID) {
      throw stateError();
    }
    assertAppAttestRecord(record);
    const verification = await verifiers.verifyAssertion({
      artifact: body.artifact,
      clientData,
      publicKey: record.publicKey,
      signCount: record.signCount,
      config,
    });
    if (!Number.isSafeInteger(verification.signCount) || verification.signCount <= record.signCount) {
      throw stateError();
    }
    return {
      record: { ...record, signCount: verification.signCount, lastVerifiedAt: now },
      stableIdentifier: body.keyID,
      settlement: { kind: "assertion", baseRecordVersion: recordVersion(record) },
    };
  }

  const tokenHash = await sha256Base64URL(body.artifact);
  const recentTokenHashes = Array.isArray(record?.recentTokenHashes)
    ? record.recentTokenHashes.filter((value) => typeof value === "string")
    : [];
  if (recentTokenHashes.includes(tokenHash)) throw stateError();

  await verifiers.verifyDeviceCheck({
    token: body.artifact,
    transactionID: challenge.id,
    config,
    now,
    fetchImpl,
  });
  return {
    record: {
      assurance: "devicecheck",
      installationID: body.installationID,
      createdAt: record?.createdAt ?? now,
      lastVerifiedAt: now,
      // DeviceCheck is explicitly lower assurance than App Attest. Keep a small replay
      // window because Apple tokens are not scoped to our request body or challenge.
      recentTokenHashes: [...recentTokenHashes, tokenHash].slice(-8),
    },
    stableIdentifier: body.installationID,
    deviceCheckTokenHash: tokenHash,
    settlement: { kind: "devicecheck", baseRecordVersion: recordVersion(record) },
  };
}

export class AttestationState {
  constructor(state, env, dependencies = {}) {
    this.state = state;
    this.env = env;
    this.verifiers = dependencies.verifiers;
    this.fetchImpl = dependencies.fetchImpl ?? fetch;
    this.logger = dependencies.logger ?? console;
  }

  async fetch(request) {
    let operation = "unknown";
    try {
      const url = new URL(request.url);
      if (url.pathname === "/challenge") operation = "challenge";
      else if (url.pathname === "/exchange") operation = "exchange";
      else if (url.pathname === "/gate") operation = "gate";
      else if (url.pathname === "/consume-devicecheck") operation = "consume_devicecheck";
      if (request.method !== "POST") return json(404, { error: "not_found" });
      const body = await request.json();
      const now = body?.now;
      if (!Number.isSafeInteger(now) || now <= 0) return json(400, { error: "invalid_request" });
      const config = loadAttestationConfig(this.env);
      if (url.pathname === "/challenge") return await this.issueChallenge(body, config, now);
      if (url.pathname === "/exchange") return await this.exchange(body, config, now);
      if (url.pathname === "/gate") return await this.gate(body, config, now);
      if (url.pathname === "/consume-devicecheck") {
        return await this.consumeDeviceCheckToken(body, config, now);
      }
      return json(404, { error: "not_found" });
    } catch (error) {
      const errorCode = error instanceof AttestationError
        ? error.diagnosticCode
        : ATTESTATION_DIAGNOSTIC_CODES.internalFailure;
      try {
        this.logger.error({
          event: "attestation_verification",
          operation,
          outcome: "error",
          errorCode,
        });
      } catch {
        // Observability must never change the authorization result.
      }
      if (
        operation === "exchange"
        && error instanceof AppAttestEnvironmentMismatchError
      ) {
        return json(401, {
          error: "unauthorized",
          code: APP_ATTEST_ENVIRONMENT_MISMATCH,
        });
      }
      if (error instanceof AttestationError) return json(error.status, { error: error.status === 503 ? "attestation_unavailable" : "unauthorized" });
      return json(503, { error: "attestation_unavailable" });
    }
  }

  async issueChallenge(body, config, now) {
    const rateTimestamps = prunedRateTimestamps(await this.state.storage.get("challengeRate"), now);
    if (rateTimestamps.length >= config.challengeRequestsPerMinute) {
      return json(429, { error: "rate_limited" });
    }
    const record = await this.state.storage.get("attestationRecord");
    if (record && body.assurance === "app_attest") {
      // A pre-recovery client can retain a valid Apple key beside a different anonymous
      // installation identifier. That exact, established key/installation binding mismatch is
      // the only authorization failure the native client may heal by rotating both values once.
      // Validate the complete durable record before returning the code so corrupted state,
      // configuration failures, and ordinary verification failures remain indistinguishable.
      assertAppAttestRecord(record);
      if (record.keyID !== body.keyID) throw stateError();
      if (record.installationID !== body.installationID) {
        return json(401, {
          error: "unauthorized",
          code: APP_ATTEST_IDENTITY_BINDING_MISMATCH,
        });
      }
    } else if (record && record.installationID !== body.installationID) {
      throw stateError();
    }
    if (body.assurance === "devicecheck" && !config.deviceCheckEnabled) {
      throw new AttestationError("attestation_unavailable", 503);
    }
    // A client can be cancelled after this Durable Object vends a challenge but before it sends
    // the App Attest artifact. Let the same per-key object supersede that abandoned challenge so
    // an immediate, user-initiated retry is not locked out for the full challenge TTL. The write
    // below is atomic within the Durable Object: once replaced, an artifact for the old challenge
    // fails the challenge-ID check in `exchange`. The existing per-key and pre-attestation network
    // rate limits still bound both legitimate retries and deliberate challenge churn.
    const mode = challengeMode(record, body.assurance);
    const challenge = randomBase64URL(32);
    const id = crypto.randomUUID().replaceAll("-", "_");
    const clientDataValue = {
      protocolVersion: 1,
      challengeID: id,
      challenge,
      requestHash: body.requestHash,
      assurance: body.assurance,
      installationID: body.installationID,
      keyID: body.keyID,
    };
    const clientData = bytesToBase64URL(new TextEncoder().encode(JSON.stringify(clientDataValue)));
    const expiresAt = now + config.challengeTTLSeconds * 1_000;
    rateTimestamps.push(now);
    await this.state.storage.put("challengeRate", rateTimestamps);
    await this.state.storage.put("activeChallenge", {
      id,
      mode,
      assurance: body.assurance,
      installationID: body.installationID,
      keyID: body.keyID,
      requestHash: body.requestHash,
      clientData,
      expiresAt,
      consumed: false,
    });
    if (typeof this.state.storage.setAlarm === "function") {
      await this.state.storage.setAlarm(expiresAt + 1_000);
    }
    return json(200, { protocolVersion: 1, challengeID: id, mode, clientData, expiresAt });
  }

  async exchange(body, config, now) {
    if (typeof body.artifact !== "string" || body.artifact.length > 64 * 1024) {
      throw stateError();
    }
    const artifact = Buffer.from(body.artifact, "base64");
    if (artifact.byteLength === 0 || artifact.toString("base64") !== body.artifact) {
      throw stateError();
    }
    const challenge = await this.state.storage.get("activeChallenge");
    if (
      !challenge || challenge.consumed || challenge.expiresAt <= now || challenge.id !== body.challengeID
      || challenge.assurance !== body.assurance || challenge.installationID !== body.installationID
      || challenge.keyID !== body.keyID || challenge.mode !== body.artifactType
    ) {
      throw stateError();
    }
    // Persist consumption before any certificate verification or Apple network call. A failed
    // exchange needs a fresh challenge and can never be replayed concurrently.
    await this.state.storage.put("activeChallenge", { ...challenge, consumed: true });
    const record = await this.state.storage.get("attestationRecord");
    const result = await processAttestationExchange({
      record,
      challenge,
      body: { ...body, artifact },
      config,
      now,
      fetchImpl: this.fetchImpl,
    }, this.verifiers);
    if (result.deviceCheckTokenHash) {
      const replayResponse = await consumeGlobalDeviceCheckToken(
        config,
        result.deviceCheckTokenHash,
        now,
      );
      if (!replayResponse.ok) throw stateError();
    }
    // Verification can yield while a replacement challenge or another accepted assertion runs.
    // Settle against the latest durable record, advancing its version and monotonic counters, and
    // delete only this exchange's challenge in the same transaction. A stale result may merge
    // verified facts but can never overwrite newer key state or consume a replacement challenge.
    try {
      await this.state.storage.transaction(async (transaction) => {
        const currentRecord = await transaction.get("attestationRecord");
        const settledRecord = settleAttestationRecord(currentRecord, result);
        await transaction.put("attestationRecord", settledRecord);
        const activeChallenge = await transaction.get("activeChallenge");
        if (activeChallenge?.id === challenge.id) {
          await transaction.delete("activeChallenge");
        }
      });
    } catch (error) {
      if (
        error instanceof AttestationError
        && error.diagnosticCode === ATTESTATION_DIAGNOSTIC_CODES.settlementFailed
      ) {
        throw error;
      }
      throw settlementError(503);
    }
    const subject = await deriveAnonymousInstallationSubject(
      `${body.assurance}:${result.stableIdentifier}`,
      config.tokenHMACKey,
    );
    const token = await createAnonymousInstallationToken(subject, challenge.requestHash, config, {
      now,
      ttlSeconds: Math.min(180, config.tokenMaxTTLSeconds),
      attestation: body.assurance,
    });
    // The rate window and alarm are shared by the Durable Object rather than owned by one
    // challenge. Leave both in place for `alarm()` to prune so one completion cannot erase a
    // replacement retry's rate history or expiry alarm.
    return json(200, {
      protocolVersion: 1,
      token: token.token,
      expiresAt: token.expiresAt,
      assurance: body.assurance,
    });
  }

  async gate(body, config, now) {
    if (typeof body.subject !== "string" || !/^[A-Za-z0-9_-]{43}$/u.test(body.subject)) {
      return json(400, { error: "invalid_request" });
    }
    const state = prunedGlobalGateState(await this.state.storage.get("globalGateState"), now);
    const subjectTimestamps = state.subjectTimestamps[body.subject] ?? [];
    if (
      state.totalTimestamps.length >= config.attestationGlobalRequestsPerMinute
      || subjectTimestamps.length >= config.attestationNetworkRequestsPerMinute
    ) {
      return json(429, { error: "rate_limited" }, { "Retry-After": "60" });
    }
    state.totalTimestamps.push(now);
    subjectTimestamps.push(now);
    state.subjectTimestamps[body.subject] = subjectTimestamps;
    await this.state.storage.put("globalGateState", state);
    if (typeof this.state.storage.setAlarm === "function") await this.state.storage.setAlarm(now + 60_000);
    return json(200, { ok: true });
  }

  async consumeDeviceCheckToken(body, config, now) {
    if (!config.deviceCheckEnabled) throw new AttestationError("attestation_unavailable", 503);
    if (typeof body.tokenHash !== "string" || !/^[A-Za-z0-9_-]{43}$/u.test(body.tokenHash)) {
      return json(400, { error: "invalid_request" });
    }
    const state = prunedGlobalGateState(await this.state.storage.get("globalGateState"), now);
    if (state.usedDeviceCheckTokens[body.tokenHash]) return json(401, { error: "unauthorized" });
    // Bound storage even if Apple changes token lifetime semantics. Reaching the cap fails the
    // lower-assurance fallback closed until the oldest entries expire.
    if (Object.keys(state.usedDeviceCheckTokens).length >= 10_000) {
      return json(503, { error: "attestation_unavailable" });
    }
    state.usedDeviceCheckTokens[body.tokenHash] = now + config.deviceCheckReplayTTLSeconds * 1_000;
    await this.state.storage.put("globalGateState", state);
    if (typeof this.state.storage.setAlarm === "function") await this.state.storage.setAlarm(now + 60_000);
    return json(200, { ok: true });
  }

  async alarm() {
    const now = Date.now();
    const globalGateState = await this.state.storage.get("globalGateState");
    if (globalGateState) {
      const state = prunedGlobalGateState(globalGateState, now);
      const hasState = state.totalTimestamps.length > 0
        || Object.keys(state.subjectTimestamps).length > 0
        || Object.keys(state.usedDeviceCheckTokens).length > 0;
      if (!hasState) {
        await this.state.storage.delete("globalGateState");
        if (typeof this.state.storage.deleteAlarm === "function") await this.state.storage.deleteAlarm();
      } else {
        await this.state.storage.put("globalGateState", state);
        await this.state.storage.setAlarm(now + 60_000);
      }
      return;
    }

    const record = await this.state.storage.get("attestationRecord");
    if (!record) {
      if (typeof this.state.storage.deleteAll === "function") await this.state.storage.deleteAll();
      else {
        await this.state.storage.delete("activeChallenge");
        await this.state.storage.delete("challengeRate");
      }
    } else {
      await this.state.storage.delete("activeChallenge");
      await this.state.storage.delete("challengeRate");
    }
    if (typeof this.state.storage.deleteAlarm === "function") await this.state.storage.deleteAlarm();
  }
}

async function callAttestationState(config, name, path, body, now) {
  const id = config.attestationNamespace.idFromName(name);
  const stub = config.attestationNamespace.get(id);
  return stub.fetch(`https://attestation-state${path}`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ ...body, now }),
  });
}

async function callGlobalAttestationGate(config, path, body, now) {
  return callAttestationState(config, "global-attestation-gate-v1", path, body, now);
}

export async function requestGlobalAttestationPermit(config, subject, now = Date.now()) {
  return callGlobalAttestationGate(config, "/gate", { subject }, now);
}

export async function consumeGlobalDeviceCheckToken(config, tokenHash, now = Date.now()) {
  return callGlobalAttestationGate(config, "/consume-devicecheck", { tokenHash }, now);
}

export async function requestAttestationChallenge(config, body, now = Date.now()) {
  return callAttestationState(config, attestationStateName(body), "/challenge", body, now);
}

export async function exchangeAttestation(config, body, now = Date.now()) {
  return callAttestationState(config, attestationStateName(body), "/exchange", {
    ...body,
    artifact: body.artifact.toString("base64"),
  }, now);
}
