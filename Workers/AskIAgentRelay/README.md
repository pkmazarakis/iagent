# Ask iAgent Cloudflare Worker

Production-oriented relay for Ask iAgent Fast and Pro. It keeps the OpenAI key on the server,
requires no user account or sign-in, validates the native app anonymously with Apple App Attest,
and forwards only a bounded, grounded Ask iAgent contract. The committed configuration has the
service and attestation gates enabled; that does not prove which configuration is currently
deployed. Deployment and activation remain explicit release operations.

## Public protocol

All routes are JSON `POST`s. Attestation uses `X-iAgent-Relay-Protocol: 1`; `/v1/ask` accepts the
stable answer contract (`1`) and bounded agent-loop contract (`2`). The header and body protocol
must agree. Native `URLSession` needs no CORS; browser requests carrying `Origin` are rejected and
the Worker emits no CORS allow headers.

| Route | Purpose | Default state |
| --- | --- | --- |
| `GET /` | Non-sensitive health envelope showing whether service and attestation gates are enabled | Always available |
| `/v1/attestation/challenge` | Create a 32-byte, server-controlled, 120-second one-time challenge bound to the exact SHA-256 request-body hash | Controlled by the attestation gate |
| `/v1/attestation/exchange` | Verify App Attest or the explicitly weaker DeviceCheck fallback and mint a one-request bearer token | Controlled by the attestation gate |
| `/v1/ask` | Validate the request-bound bearer token, reserve spend, and call OpenAI | Controlled by the service gate |

The iOS client stores a random installation ID and its App Attest key ID in a non-synchronizing
Keychain item. There is no email, Apple identity, user record, or account gate.

### App Attest exchange

1. The client hashes the exact `/v1/ask` body and asks for a challenge with its installation ID and
   App Attest key ID.
2. A per-key Durable Object returns canonical client data containing the random challenge, body
   hash, assurance, installation ID, and key ID. Only one unexpired challenge can exist per key.
   Before any attacker-selected Durable Object name is resolved, one global Durable Object applies
   a hard 600 challenges/minute service cap and a 60/minute privacy-HMACed network cap. Per-key
   state additionally permits 12 challenges/minute. These gates cover one four-round turn, a retry,
   and another immediate turn without the relay rate-limiting its own loop. Challenge-only
   objects schedule an alarm and erase abandoned state after expiry.
3. On first use the client sends an attestation. Later requests send assertions.
4. The Worker verifies Apple's certificate chain and certificate dates, server challenge nonce,
   strict Team ID `625CGY297X`, bundle ID `com.platon.iagent.mobile`, key/public-key binding, RP ID,
   production AAGUID, initial counter, and the credential ID. Assertion counters must strictly
   increase. A challenge is persisted as consumed before verification, so failures and concurrent
   replays cannot reuse it.
5. When present, Apple's `apple_validation_category_01` and `apple_bundle_version_01` extensions
   must match TestFlight/App Store categories (`2,4`) and one of the explicitly staged builds
   (`18,24,25,26,27`). Absence is temporarily accepted
   for pre-iOS-27 artifacts; set `APP_ATTEST_REQUIRE_IOS27_SIGNALS=true` after the minimum supported
   installed base produces them.
6. The Worker derives an opaque installation subject with HMAC and returns a 180-second token bound
   to the exact body hash. Its `jti` can reserve once only in the limiter Durable Object.

Apple requires the App ID capability and the matching entitlement. Debug uses the App Attest
development environment; TestFlight and App Store builds always use production regardless of the
source entitlement.

### DeviceCheck fallback

DeviceCheck is explicitly lower assurance. The app attempts it only when
`DCAppAttestService.isSupported == false`, never when App Attest validation fails. The Worker keeps
it off with `DEVICECHECK_FALLBACK_ENABLED=false` until an Apple DeviceCheck key is installed. If it
is later approved, it is restricted to Fast, 2 requests/minute, one concurrent request, and
$0.15/day **across the entire DeviceCheck fallback**, because DeviceCheck does not expose a stable
server-verifiable installation identity. A global Durable Object also retains successful Apple
token hashes for 24 hours and rejects cross-installation replay. App Attest receives 12
requests/minute, one concurrent request, and
$1.00/install/day.

### Stateless V2 agent loop

Protocol 2 is a client-carried, maximum-four-round loop (rounds 0 through 3), with at most four
calls per round, eight total calls, and three proposal repair attempts. The Worker stores no prompt,
conversation, evidence, tool result, model response, or turn state. Every round is independently
authenticated and request-hash-bound.

- The client returns canonical `toolHistory`; the Worker reconstructs actual Responses API
  `function_call` and `function_call_output` items. Tool results are not embedded as inert prose.
- Each function output contains the exact bounded receipt and only the evidence IDs named by that
  receipt. Empty searches replay an empty evidence array. Final claims must still cite exact
  excerpts from cumulative evidence.
- OpenAI receives `store: false`. Pro tool rounds return a client-carried opaque
  `modelContinuation` with the exact reasoning item ID, encrypted content, round, and ordered call
  IDs. The Worker never decodes or logs it. The client keeps at most three items/24 KiB in memory,
  and the Worker replays each reasoning item before its matching call/output group. There is no
  `previous_response_id`, `store: true`, or server-side personal turn state.
- Read tools return bounded local queries. Action tools can only prepare a native review proposal.
  After a successful proposal receipt, the model returns one concise `actionMessage`; the relay
  rejects execution claims. The app still requires a single-use native confirmation before any
  write.
- Each bearer token can reserve only once. A replay cannot dispatch another model request. A retry
  obtains fresh attestation and therefore remains fully authenticated and charged conservatively;
  the relay deliberately does not cache personal responses by request hash.
- A client disconnect aborts the upstream fetch where the Workers runtime exposes request signals,
  settles the reservation conservatively, and releases the concurrency lease for an immediate
  authenticated retry.

## Privacy and failure boundaries

- `OPENAI_API_KEY`, `ANONYMOUS_TOKEN_HMAC_KEY`, `SAFETY_IDENTIFIER_HMAC_KEY`, and any Apple `.p8`
  key are Cloudflare secrets only. None belongs in source, Xcode settings, Info.plist, analytics,
  screenshots, or the app bundle.
- Prompts, evidence, tool arguments/results, tokens, installation IDs, encrypted continuations,
  model output, API keys, and upstream responses are never logged. The sole application trace is
  `requestID`, tier, protocol, round, outcome, error code, and latency. The same opaque request ID is
  returned as `X-iAgent-Request-ID` and sent upstream as `X-Client-Request-Id`. Cloudflare
  observability and invocation logs are enabled only for this privacy-safe trace. Responses use
  `Cache-Control: no-store`.
- Requests are limited to 64 KiB and 16 bounded evidence records. Unknown fields, client-selected
  models/reasoning, malformed data, replay, expiry, budget failure, or missing config fail closed.
- OpenAI receives `store: false`, a server-derived privacy-preserving `safety_identifier`, and a
  strict JSON Schema response request. Returned support must cite allowed evidence IDs and exact
  excerpts before the Worker responds.
- Each installation has an isolated SQLite-backed Durable Object for authentication/rate/spend
  metadata only; it never receives personal content. It atomically consumes the token
  ID, limits rate/concurrency, reserves worst-case spend before dispatch, reconciles actual usage,
  and expires abandoned reservations by alarm.

## Routes, prices, and limits

Official prices were verified on 2026-08-08 against the OpenAI model and pricing documentation:

| Tier | OpenAI route | Input | Cached input | Cache write | Output |
| --- | --- | ---: | ---: | ---: | ---: |
| Fast | `gpt-5.6-luna`, `reasoning.effort: low`, max 4,000 output tokens | $1.00/M | $0.10/M | $1.25/M | $6.00/M |
| Pro | `gpt-5.6-sol`, `reasoning.mode: pro`, `effort: medium`, max 8,000 output tokens | $5.00/M | $0.50/M | $6.25/M | $30.00/M |

Sources: [GPT-5.6 Luna](https://developers.openai.com/api/docs/models/gpt-5.6-luna),
[GPT-5.6 Sol](https://developers.openai.com/api/docs/models/gpt-5.6-sol), and
[OpenAI API pricing](https://openai.com/api/pricing/).

The committed microdollar values encode those prices. Estimation charges all possible input at the
higher normal/cache-write rate; actual settlement distinguishes uncached, cached, cache-written,
and output tokens when OpenAI returns those counters. The request-body cap keeps this service below
the long-context pricing threshold.

## Automated verification

Use Node 22 or later:

```sh
cd Workers/AskIAgentRelay
npm install
npm run check
npm test
npx wrangler deploy --dry-run
```

Tests use no real credentials or external network. They cover model/field tampering, exact-body token
binding, token expiry/signature/replay, an Apple production certificate fixture, assertion counter
advance/replay, DeviceCheck token reuse, challenge expiry/consumption, attestation
global/network caps, abandoned-state cleanup, DeviceCheck global budget identity,
gate/schema/response contract, service kill switch, browser rejection, request size, exact
function-call/output reconstruction, zero-result searches, Pro encrypted reasoning replay,
action-message truthfulness, strict grounded output, upstream failure accounting, cancellation,
retry/replay, request-ID observability, rate/concurrency, and daily budget stops.

For local Worker startup copy `dev.vars.example` to `.dev.vars`; the latter is ignored. The helper
token is for local development only and now requires the exact JSON request body to bind:

```sh
npm run token:local -- installation_0123456789abcdef ./request.json
```

Debug iOS remains configured for `http://127.0.0.1:8787/ask` and does not invoke App Attest. Release
uses the production `/v1/ask` endpoint, while the server-side service and attestation gates remain
the authoritative activation controls.

## Secret configuration

Set secrets interactively or through a protected stdin file; never place values in an argument:

```sh
npx wrangler secret put OPENAI_API_KEY
npx wrangler secret put ANONYMOUS_TOKEN_HMAC_KEY
npx wrangler secret put SAFETY_IDENTIFIER_HMAC_KEY
```

Generate the two HMAC values independently with at least 32 random bytes. DeviceCheck additionally
requires `APPLE_DEVICECHECK_KEY_ID` and `APPLE_DEVICECHECK_PRIVATE_KEY`, but leave them absent while
the fallback flag is false.

## Activation checklist

These steps are intentionally separate so a partial configuration cannot spend money:

1. In Apple Certificates, Identifiers & Profiles, enable App Attest for
   `com.platon.iagent.mobile`; regenerate Debug and distribution provisioning profiles and confirm
   they contain `com.apple.developer.devicecheck.appattest-environment`.
2. Confirm all three Worker secret names exist. Use a separate kill-switch configuration while
   changing authentication or routing; do not infer deployed state from this repository alone.
3. Compute the next TestFlight build once. Before incrementing Xcode, stage that exact value in
   `APP_ATTEST_ALLOWED_BUNDLE_VERSIONS` and run
   `node Scripts/check-ask-iagent-release-readiness.mjs --candidate-build <build>` from the repository
   root. Build 27 is currently staged, so candidate 27 passes while the project is still build 26.
4. Deploy the reviewed Worker/configuration before uploading that new build. After Xcode is bumped,
   rerun the readiness checker without `--candidate-build`; it validates the current app/widget
   build only and does not chase `current + 1` indefinitely.
5. With paid traffic disabled via the deployment kill switch, verify first-use attestation, a later
   assertion, body binding, expiration, and replay rejection with the production-signed candidate.
6. Release is already configured for the approved production `/v1/ask` endpoint, while Debug stays
   loopback. The Worker gates—not a missing URL—keep Release fail-closed until preflight succeeds.
7. Before paid activation, use the dedicated `iAgent Production` OpenAI project, allow only Luna
   and Sol, set the lowest practical model rate limits, configure an enforced hard spend limit,
   and add alerts at conservative thresholds. Do not rely on a soft monthly budget: OpenAI notes
   that a monitoring-only threshold can continue serving requests after it is crossed. Configure
   Cloudflare usage alerts and, as defense in depth, an account-level WAF/Rate Limiting rule for the
   two unauthenticated attestation routes if the selected plan supports it. The Worker-level global
   gate remains mandatory regardless of plan.
8. Obtain a final explicit approval, then and only then enable paid traffic. Verify one
   bounded request and immediately restore the kill switch if cost, auth, or grounding differs from
   expectation.

Do not enable DeviceCheck, service traffic, or a paid plan automatically. Billing, plan, hard-limit,
and payment decisions remain user-owned.
