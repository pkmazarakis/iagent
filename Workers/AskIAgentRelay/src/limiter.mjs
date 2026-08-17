function json(status, value, extraHeaders = {}) {
  return new Response(JSON.stringify(value), {
    status,
    headers: {
      "Content-Type": "application/json; charset=utf-8",
      "Cache-Control": "no-store",
      ...extraHeaders,
    },
  });
}

function utcDay(now) {
  return new Date(now).toISOString().slice(0, 10);
}

function nextUTCDay(now) {
  const date = new Date(now);
  return Date.UTC(date.getUTCFullYear(), date.getUTCMonth(), date.getUTCDate() + 1) + 1_000;
}

function initialState(now) {
  return { day: utcDay(now), spentMicros: 0, rateTimestamps: [], reservations: {}, usedTokens: {} };
}

function prunedState(stored, now) {
  const state = stored && typeof stored === "object" ? structuredClone(stored) : initialState(now);
  if (state.day !== utcDay(now)) {
    state.day = utcDay(now);
    state.spentMicros = 0;
    state.rateTimestamps = [];
  }
  state.rateTimestamps = Array.isArray(state.rateTimestamps)
    ? state.rateTimestamps.filter((timestamp) => Number.isFinite(timestamp) && timestamp > now - 60_000)
    : [];
  state.reservations = state.reservations && typeof state.reservations === "object"
    ? state.reservations
    : {};
  state.usedTokens = state.usedTokens && typeof state.usedTokens === "object" ? state.usedTokens : {};
  for (const [id, reservation] of Object.entries(state.reservations)) {
    if (!reservation || !Number.isFinite(reservation.expiresAt) || reservation.expiresAt <= now) {
      delete state.reservations[id];
    }
  }
  for (const [id, expiresAt] of Object.entries(state.usedTokens)) {
    if (!Number.isSafeInteger(expiresAt) || expiresAt <= now) delete state.usedTokens[id];
  }
  state.spentMicros = Number.isSafeInteger(state.spentMicros) && state.spentMicros >= 0
    ? state.spentMicros
    : 0;
  return state;
}

function reservedMicros(state) {
  return Object.values(state.reservations).reduce(
    (sum, reservation) => sum + (Number.isSafeInteger(reservation.estimatedMicros) ? reservation.estimatedMicros : 0),
    0,
  );
}

function validateInternalInteger(value, maximum = Number.MAX_SAFE_INTEGER) {
  return Number.isSafeInteger(value) && value > 0 && value <= maximum;
}

export class InstallationLimiter {
  constructor(state, _env) {
    this.state = state;
  }

  async fetch(request) {
    const url = new URL(request.url);
    if (request.method !== "POST") return json(404, { error: "not_found" });
    let body;
    try {
      body = await request.json();
    } catch {
      return json(400, { error: "invalid_request" });
    }
    const now = body?.now;
    if (!Number.isSafeInteger(now) || now <= 0) return json(400, { error: "invalid_request" });
    const state = prunedState(await this.state.storage.get("limits"), now);

    if (url.pathname === "/reserve") {
      if (
        typeof body.requestID !== "string" ||
        !/^[A-Za-z0-9_-]{16,128}$/u.test(body.requestID) ||
        typeof body.tokenID !== "string" ||
        !/^[A-Za-z0-9_-]{16,128}$/u.test(body.tokenID) ||
        !Number.isSafeInteger(body.tokenExpiresAt) || body.tokenExpiresAt <= now ||
        !validateInternalInteger(body.estimatedMicros) ||
        !validateInternalInteger(body.requestsPerMinute, 1_000) ||
        !validateInternalInteger(body.maxConcurrentRequests, 20) ||
        !validateInternalInteger(body.dailySpendLimitMicros) ||
        !validateInternalInteger(body.leaseMilliseconds, 600_000)
      ) {
        return json(400, { error: "invalid_request" });
      }
      if (state.usedTokens[body.tokenID]) return json(401, { error: "token_replayed" });
      if (state.reservations[body.requestID]) return json(409, { error: "duplicate_request" });
      if (state.rateTimestamps.length >= body.requestsPerMinute) {
        const retryAfter = Math.max(1, Math.ceil((state.rateTimestamps[0] + 60_000 - now) / 1_000));
        return json(429, { error: "rate_limited" }, { "Retry-After": String(retryAfter) });
      }
      if (Object.keys(state.reservations).length >= body.maxConcurrentRequests) {
        return json(429, { error: "too_many_concurrent_requests" }, { "Retry-After": "5" });
      }
      if (state.spentMicros + reservedMicros(state) + body.estimatedMicros > body.dailySpendLimitMicros) {
        return json(429, { error: "daily_spend_limit" });
      }
      state.rateTimestamps.push(now);
      state.usedTokens[body.tokenID] = body.tokenExpiresAt;
      state.reservations[body.requestID] = {
        estimatedMicros: body.estimatedMicros,
        expiresAt: now + body.leaseMilliseconds,
      };
      await this.state.storage.put("limits", state);
      if (typeof this.state.storage.setAlarm === "function") {
        const alarms = Object.values(state.reservations).map((reservation) => reservation.expiresAt);
        await this.state.storage.setAlarm(Math.min(...alarms));
      }
      return json(200, { ok: true });
    }

    if (url.pathname === "/settle" || url.pathname === "/release") {
      if (typeof body.requestID !== "string") return json(400, { error: "invalid_request" });
      const reservation = state.reservations[body.requestID];
      if (!reservation) return json(200, { ok: true });
      delete state.reservations[body.requestID];
      if (url.pathname === "/settle") {
        if (!validateInternalInteger(body.actualMicros)) return json(400, { error: "invalid_request" });
        state.spentMicros += body.actualMicros;
      }
      await this.state.storage.put("limits", state);
      if (Object.keys(state.reservations).length === 0 && typeof this.state.storage.setAlarm === "function") {
        // Retain today's spend counter, then remove idle installation state just after UTC rollover.
        await this.state.storage.setAlarm(nextUTCDay(now));
      }
      return json(200, { ok: true });
    }
    return json(404, { error: "not_found" });
  }

  async alarm() {
    const now = Date.now();
    const stored = await this.state.storage.get("limits");
    if (
      stored &&
      stored.day !== utcDay(now) &&
      Object.keys(stored.reservations ?? {}).length === 0
    ) {
      await this.state.storage.delete("limits");
      if (typeof this.state.storage.deleteAlarm === "function") await this.state.storage.deleteAlarm();
      return;
    }
    const state = prunedState(stored, now);
    await this.state.storage.put("limits", state);
    const alarms = Object.values(state.reservations).map((reservation) => reservation.expiresAt);
    await this.state.storage.setAlarm(alarms.length > 0 ? Math.min(...alarms) : nextUTCDay(now));
  }
}

export function estimatedRequestCostMicros(openAIRequest, route, price) {
  // One UTF-8 byte per token is deliberately conservative; actual text token counts are lower.
  const estimatedInputTokens = Math.max(1, new TextEncoder().encode(JSON.stringify(openAIRequest)).length);
  return tokenCostMicros(
    estimatedInputTokens,
    0,
    0,
    route.maxOutputTokens,
    { ...price, inputPerMillionMicros: Math.max(price.inputPerMillionMicros, price.cacheWritePerMillionMicros) },
  );
}

export function actualRequestCostMicros(usage, price) {
  const inputTokens = Number.isSafeInteger(usage?.input_tokens) && usage.input_tokens >= 0 ? usage.input_tokens : 0;
  const outputTokens = Number.isSafeInteger(usage?.output_tokens) && usage.output_tokens >= 0 ? usage.output_tokens : 0;
  if (inputTokens + outputTokens === 0) return null;
  const details = usage?.input_tokens_details;
  const cachedTokens = Number.isSafeInteger(details?.cached_tokens) && details.cached_tokens >= 0
    ? Math.min(details.cached_tokens, inputTokens)
    : 0;
  const cacheWriteTokens = Number.isSafeInteger(details?.cache_write_tokens) && details.cache_write_tokens >= 0
    ? Math.min(details.cache_write_tokens, inputTokens - cachedTokens)
    : 0;
  const uncachedTokens = inputTokens - cachedTokens - cacheWriteTokens;
  return tokenCostMicros(uncachedTokens, cachedTokens, cacheWriteTokens, outputTokens, price);
}

function tokenCostMicros(inputTokens, cachedInputTokens, cacheWriteTokens, outputTokens, price) {
  const input = Math.ceil((inputTokens * price.inputPerMillionMicros) / 1_000_000);
  const cachedInput = Math.ceil((cachedInputTokens * price.cachedInputPerMillionMicros) / 1_000_000);
  const cacheWrite = Math.ceil((cacheWriteTokens * price.cacheWritePerMillionMicros) / 1_000_000);
  const output = Math.ceil((outputTokens * price.outputPerMillionMicros) / 1_000_000);
  return Math.max(1, input + cachedInput + cacheWrite + output);
}

export async function reserveInstallationBudget(
  config,
  installationID,
  estimatedMicros,
  now = Date.now(),
  { tokenID, tokenExpiresAt, attestation = "app_attest" } = {},
) {
  const requestID = crypto.randomUUID().replaceAll("-", "_");
  const usesDeviceCheck = attestation === "devicecheck";
  // DeviceCheck does not expose a trustworthy stable device identifier to the server. Never use
  // its client-supplied installation ID as a spend boundary: every fallback request shares one
  // conservative global bucket. App Attest remains isolated by its server-verified key subject.
  const limiterSubject = usesDeviceCheck ? "devicecheck-global-hard-cap-v1" : installationID;
  const id = config.limiterNamespace.idFromName(limiterSubject);
  const stub = config.limiterNamespace.get(id);
  const response = await stub.fetch("https://installation-limiter/reserve", {
    method: "POST",
    body: JSON.stringify({
      requestID,
      tokenID,
      tokenExpiresAt,
      now,
      estimatedMicros,
      requestsPerMinute: usesDeviceCheck ? config.deviceCheckRequestsPerMinute : config.requestsPerMinute,
      maxConcurrentRequests: usesDeviceCheck ? config.deviceCheckMaxConcurrentRequests : config.maxConcurrentRequests,
      dailySpendLimitMicros: usesDeviceCheck ? config.deviceCheckDailySpendLimitMicros : config.dailySpendLimitMicros,
      leaseMilliseconds: config.reservationLeaseMilliseconds,
    }),
  });
  if (!response.ok) return { ok: false, response };
  return { ok: true, requestID, stub, estimatedMicros };
}

export async function finalizeInstallationBudget(reservation, actualMicros, now = Date.now()) {
  const path = actualMicros === null ? "/release" : "/settle";
  const response = await reservation.stub.fetch(`https://installation-limiter${path}`, {
    method: "POST",
    body: JSON.stringify({ requestID: reservation.requestID, now, actualMicros }),
  });
  if (!response.ok) throw new Error("limiter_settlement_failed");
}
