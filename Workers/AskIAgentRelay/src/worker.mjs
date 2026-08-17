import {
  MAX_REQUEST_BYTES,
  MAX_UPSTREAM_RESPONSE_BYTES,
  ROUTES,
  RequestValidationError,
  buildOpenAIRequest,
  extractStructuredClaims,
  extractV2RelayResponse,
  validateClientRequest,
} from "./contract.mjs";
import {
  AuthenticationError,
  bearerTokenFromRequest,
  deriveAnonymousInstallationSubject,
  deriveSafetyIdentifier,
  verifyAnonymousInstallationToken,
} from "./auth.mjs";
import {
  AttestationError,
  sha256Base64URL,
  validateChallengeRequest,
  validateExchangeRequest,
} from "./attestation.mjs";
import {
  AttestationState,
  exchangeAttestation,
  requestGlobalAttestationPermit,
  requestAttestationChallenge,
} from "./attestation-state.mjs";
import {
  ConfigurationError,
  attestationExchangeIsEnabled,
  loadAttestationConfig,
  loadConfig,
  serviceIsEnabled,
} from "./config.mjs";
import {
  InstallationLimiter,
  actualRequestCostMicros,
  estimatedRequestCostMicros,
  finalizeInstallationBudget,
  reserveInstallationBudget,
} from "./limiter.mjs";

const OPENAI_RESPONSES_URL = "https://api.openai.com/v1/responses";

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

async function readJSON(request) {
  const contentLength = request.headers.get("Content-Length");
  if (contentLength && (!/^\d+$/u.test(contentLength) || Number(contentLength) > MAX_REQUEST_BYTES)) {
    throw new RequestValidationError("Request body is too large.", 413);
  }
  if (!request.body) throw new RequestValidationError("Request body must be valid JSON.", 400);
  const reader = request.body.getReader();
  const chunks = [];
  let byteCount = 0;
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    byteCount += value.byteLength;
    if (byteCount > MAX_REQUEST_BYTES) {
      await reader.cancel();
      throw new RequestValidationError("Request body is too large.", 413);
    }
    chunks.push(value);
  }
  const bytes = new Uint8Array(byteCount);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.byteLength;
  }
  try {
    return { value: JSON.parse(new TextDecoder().decode(bytes)), bytes };
  } catch {
    throw new RequestValidationError("Request body must be valid JSON.", 400);
  }
}

async function readUpstreamJSON(response) {
  const contentLength = response.headers.get("Content-Length");
  if (contentLength && /^\d+$/u.test(contentLength) && Number(contentLength) > MAX_UPSTREAM_RESPONSE_BYTES) {
    throw new Error("upstream_response_too_large");
  }
  const bytes = new Uint8Array(await response.arrayBuffer());
  if (bytes.byteLength > MAX_UPSTREAM_RESPONSE_BYTES) throw new Error("upstream_response_too_large");
  try {
    return JSON.parse(new TextDecoder().decode(bytes));
  } catch {
    throw new Error("invalid_upstream_response");
  }
}

function forwardedRateLimitResponse(response, respond = json) {
  const retryAfter = response.headers.get("Retry-After");
  return respond(429, { error: "rate_limited" }, retryAfter ? { "Retry-After": retryAfter } : {});
}

export function createWorker({ fetchImpl = globalThis.fetch, now = () => Date.now(), logger = console } = {}) {
  return {
    async fetch(request, env) {
      const requestID = `iareq_${crypto.randomUUID().replaceAll("-", "")}`;
      const startedAt = Date.now();
      let askLogContext = null;
      let logged = false;
      const respond = (status, value, extraHeaders = {}) => {
        if (askLogContext && !logged) {
          logged = true;
          logger.info({
            event: "relay_request",
            requestID,
            tier: askLogContext.tier,
            protocolVersion: askLogContext.protocolVersion,
            round: askLogContext.round,
            outcome: status < 400 ? "success" : "error",
            errorCode: typeof value?.error === "string" ? value.error : null,
            latencyMs: Math.max(0, Date.now() - startedAt),
          });
        }
        return json(status, value, { "X-iAgent-Request-ID": requestID, ...extraHeaders });
      };
      let reservation = null;
      let upstreamDispatched = false;
      let clientAborted = false;
      let upstreamTimedOut = false;
      try {
        const url = new URL(request.url);
        if (request.method === "GET" && url.pathname === "/" && !url.search) {
          return respond(200, {
            service: "iagent-ask-iagent-relay",
            protocolVersion: 1,
            status: serviceIsEnabled(env) ? "enabled" : "disabled",
            attestation: attestationExchangeIsEnabled(env) ? "enabled" : "disabled",
          });
        }
        const isChallenge = url.pathname === "/v1/attestation/challenge";
        const isExchange = url.pathname === "/v1/attestation/exchange";
        const isAsk = url.pathname === "/v1/ask";
        if (isAsk) {
          askLogContext = { tier: null, protocolVersion: null, round: null };
        }
        if (request.method !== "POST" || (!isAsk && !isChallenge && !isExchange) || url.search) {
          return respond(404, { error: "not_found" });
        }
        // Native URLSession does not need CORS. Refuse browser-originated requests and emit no CORS headers.
        if (request.headers.has("Origin")) return respond(403, { error: "browser_requests_not_allowed" });
        if (!(request.headers.get("Content-Type") ?? "").toLowerCase().startsWith("application/json")) {
          return respond(415, { error: "unsupported_media_type" });
        }
        if (request.headers.has("Content-Encoding")) {
          return respond(415, { error: "content_encoding_not_supported" });
        }

        if (isChallenge || isExchange) {
          if (!attestationExchangeIsEnabled(env)) return respond(503, { error: "attestation_unavailable" });
          if (request.headers.get("X-iAgent-Relay-Protocol") !== "1") {
            return respond(400, { error: "unsupported_protocol" });
          }
          const config = loadAttestationConfig(env);
          if (isChallenge) {
            const clientAddress = request.headers.get("CF-Connecting-IP");
            if (
              typeof clientAddress !== "string"
              || clientAddress.length > 64
              || !/^[0-9A-Fa-f:.]{3,64}$/u.test(clientAddress)
            ) {
              return respond(503, { error: "attestation_unavailable" });
            }
            const networkSubject = await deriveAnonymousInstallationSubject(
              `pre-attestation-network-v1\n${clientAddress}`,
              config.tokenHMACKey,
            );
            const permit = await requestGlobalAttestationPermit(config, networkSubject, now());
            if (!permit.ok) {
              return permit.status === 429
                ? forwardedRateLimitResponse(permit, respond)
                : respond(503, { error: "attestation_unavailable" });
            }
          }
          const decoded = await readJSON(request);
          if (isChallenge) {
            const body = validateChallengeRequest(decoded.value);
            return requestAttestationChallenge(config, body, now());
          }
          const body = validateExchangeRequest(decoded.value);
          return exchangeAttestation(config, body, now());
        }

        if (!serviceIsEnabled(env)) return respond(503, { error: "service_unavailable" });
        const relayProtocol = request.headers.get("X-iAgent-Relay-Protocol");
        if (relayProtocol !== "1" && relayProtocol !== "2") {
          return respond(400, { error: "unsupported_protocol" });
        }
        askLogContext.protocolVersion = Number(relayProtocol);

        const config = loadConfig(env);
        const decoded = await readJSON(request);
        if (String(decoded.value?.protocolVersion) !== relayProtocol) {
          return respond(400, { error: "unsupported_protocol" });
        }
        const auth = await verifyAnonymousInstallationToken(bearerTokenFromRequest(request), config, now());
        if (auth.requestHash !== await sha256Base64URL(decoded.bytes)) throw new AuthenticationError();
        const body = validateClientRequest(decoded.value, config.enabledTiers);
        askLogContext = {
          tier: body.tier,
          protocolVersion: body.protocolVersion,
          round: body.protocolVersion === 2 ? body.round : 0,
        };
        if (auth.attestation === "devicecheck" && !config.deviceCheckEnabledTiers.has(body.tier)) {
          throw new AuthenticationError();
        }
        const route = ROUTES[body.tier];
        const safetyIdentifier = await deriveSafetyIdentifier(
          auth.installationID,
          config.safetyIdentifierHMACKey,
        );
        const openAIRequest = buildOpenAIRequest(body, route, safetyIdentifier);
        const estimatedMicros = estimatedRequestCostMicros(openAIRequest, route, config.prices[body.tier]);
        const reserveResult = await reserveInstallationBudget(
          config,
          auth.installationID,
          estimatedMicros,
          now(),
          {
            tokenID: auth.tokenID,
            tokenExpiresAt: auth.expiresAt,
            attestation: auth.attestation,
          },
        );
        if (!reserveResult.ok) {
          return reserveResult.response.status === 401
            ? respond(401, { error: "unauthorized" })
            : reserveResult.response.status === 429
            ? forwardedRateLimitResponse(reserveResult.response, respond)
            : respond(503, { error: "service_unavailable" });
        }
        reservation = reserveResult;

        const controller = new AbortController();
        const abortFromClient = () => {
          clientAborted = true;
          controller.abort(new DOMException("Client disconnected.", "AbortError"));
        };
        if (request.signal.aborted) abortFromClient();
        request.signal.addEventListener("abort", abortFromClient, { once: true });
        const timeout = setTimeout(() => {
          upstreamTimedOut = true;
          controller.abort(new DOMException("Upstream timed out.", "AbortError"));
        }, body.tier === "pro" ? 235_000 : 85_000);
        let upstream;
        try {
          upstreamDispatched = true;
          upstream = await fetchImpl(OPENAI_RESPONSES_URL, {
            method: "POST",
            headers: {
              Authorization: `Bearer ${config.openAIAPIKey}`,
              "Content-Type": "application/json",
              "X-Client-Request-Id": requestID,
            },
            body: JSON.stringify(openAIRequest),
            signal: controller.signal,
          });
        } finally {
          clearTimeout(timeout);
          request.signal.removeEventListener("abort", abortFromClient);
        }
        const upstreamBody = await readUpstreamJSON(upstream);
        const actualMicros = actualRequestCostMicros(upstreamBody?.usage, config.prices[body.tier]);
        await finalizeInstallationBudget(reservation, upstream.ok ? (actualMicros ?? estimatedMicros) : actualMicros, now());
        reservation = null;
        if (!upstream.ok) {
          return upstream.status === 429
            ? respond(429, { error: "upstream_rate_limited" }, upstream.headers.get("Retry-After")
              ? { "Retry-After": upstream.headers.get("Retry-After") }
              : {})
            : respond(503, { error: "upstream_unavailable" });
        }
        let relayResponse;
        try {
          relayResponse = body.protocolVersion === 2
            ? extractV2RelayResponse(upstreamBody, body)
            : extractStructuredClaims(upstreamBody, body);
        } catch {
          // Keep grounding/contract failures distinct from network availability. The client may
          // perform one bounded repair attempt, but must never present this as a successful answer.
          return respond(502, { error: "invalid_upstream_output" });
        }
        return respond(200, relayResponse);
      } catch (error) {
        if (reservation) {
          try {
            await finalizeInstallationBudget(
              reservation,
              upstreamDispatched ? reservation.estimatedMicros : null,
              now(),
            );
          } catch {
            // The lease remains reserved until its Durable Object alarm expires; fail closed below.
          }
        }
        if (error instanceof AuthenticationError) return respond(401, { error: "unauthorized" });
        if (error instanceof AttestationError) {
          return respond(error.status, { error: error.status === 503 ? "attestation_unavailable" : "unauthorized" });
        }
        if (error instanceof RequestValidationError) {
          return respond(error.status, { error: error.status === 413 ? "request_too_large" : "invalid_request" });
        }
        if (error instanceof ConfigurationError) {
          return respond(503, { error: "service_unavailable" });
        }
        if (error?.name === "AbortError") {
          return clientAborted && !upstreamTimedOut
            ? respond(499, { error: "client_closed_request" })
            : respond(504, { error: "upstream_timeout" });
        }
        return respond(503, { error: "service_unavailable" });
      }
    },
  };
}

export { AttestationState, InstallationLimiter };
export default createWorker();
