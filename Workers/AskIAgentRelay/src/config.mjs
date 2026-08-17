import { ROUTES } from "./contract.mjs";

export class ConfigurationError extends Error {
  constructor(message = "service_unavailable") {
    super(message);
    this.name = "ConfigurationError";
    this.status = 503;
  }
}

function positiveInteger(raw, label, maximum = Number.MAX_SAFE_INTEGER) {
  if (!/^\d+$/u.test(String(raw ?? ""))) throw new ConfigurationError(`${label}_invalid`);
  const value = Number(raw);
  if (!Number.isSafeInteger(value) || value <= 0 || value > maximum) {
    throw new ConfigurationError(`${label}_invalid`);
  }
  return value;
}

function secret(raw, label) {
  if (typeof raw !== "string" || encoderLength(raw) < 32) {
    throw new ConfigurationError(`${label}_missing`);
  }
  return raw;
}

function encoderLength(value) {
  return new TextEncoder().encode(value).length;
}

export function serviceIsEnabled(env) {
  return env?.SERVICE_ENABLED === "true";
}

export function attestationExchangeIsEnabled(env) {
  return env?.ATTESTATION_EXCHANGE_ENABLED === "true";
}

function commaSeparatedSet(raw, label, parser = (value) => value) {
  const values = String(raw ?? "")
    .split(",")
    .map((value) => value.trim())
    .filter(Boolean)
    .map(parser);
  if (values.length === 0 || values.some((value) => value === null)) {
    throw new ConfigurationError(`${label}_invalid`);
  }
  return new Set(values);
}

function appAttestIdentity(env) {
  const teamIdentifier = typeof env.APP_ATTEST_TEAM_IDENTIFIER === "string"
    && /^[A-Z0-9]{10}$/u.test(env.APP_ATTEST_TEAM_IDENTIFIER)
    ? env.APP_ATTEST_TEAM_IDENTIFIER
    : (() => { throw new ConfigurationError("app_attest_team_invalid"); })();
  const bundleIdentifier = typeof env.APP_ATTEST_BUNDLE_IDENTIFIER === "string"
    && /^[A-Za-z0-9.-]{3,255}$/u.test(env.APP_ATTEST_BUNDLE_IDENTIFIER)
    ? env.APP_ATTEST_BUNDLE_IDENTIFIER
    : (() => { throw new ConfigurationError("app_attest_bundle_invalid"); })();
  return { teamIdentifier, bundleIdentifier };
}

export function loadAttestationConfig(env) {
  if (!env.ATTESTATION_STATE || typeof env.ATTESTATION_STATE.idFromName !== "function") {
    throw new ConfigurationError("attestation_binding_missing");
  }
  const identity = appAttestIdentity(env);
  const deviceCheckEnabled = env.DEVICECHECK_FALLBACK_ENABLED === "true";
  const allowedEnvironments = commaSeparatedSet(env.APP_ATTEST_ALLOWED_ENVIRONMENTS, "app_attest_environments");
  if ([...allowedEnvironments].some((value) => value !== "production" && value !== "development")) {
    throw new ConfigurationError("app_attest_environments_invalid");
  }
  const allowedBundleVersions = commaSeparatedSet(env.APP_ATTEST_ALLOWED_BUNDLE_VERSIONS, "app_attest_bundle_versions");
  if ([...allowedBundleVersions].some((value) => !/^\d+(?:\.\d+){0,2}$/u.test(value))) {
    throw new ConfigurationError("app_attest_bundle_versions_invalid");
  }
  return {
    ...identity,
    tokenHMACKey: secret(env.ANONYMOUS_TOKEN_HMAC_KEY, "anonymous_token_key"),
    tokenIssuer: typeof env.TOKEN_ISSUER === "string" && env.TOKEN_ISSUER.length > 0 && env.TOKEN_ISSUER.length <= 120
      ? env.TOKEN_ISSUER
      : (() => { throw new ConfigurationError("token_issuer_invalid"); })(),
    tokenAudience: typeof env.TOKEN_AUDIENCE === "string" && env.TOKEN_AUDIENCE.length > 0 && env.TOKEN_AUDIENCE.length <= 120
      ? env.TOKEN_AUDIENCE
      : (() => { throw new ConfigurationError("token_audience_invalid"); })(),
    tokenMaxTTLSeconds: positiveInteger(env.TOKEN_MAX_TTL_SECONDS, "token_ttl", 600),
    challengeTTLSeconds: positiveInteger(env.CHALLENGE_TTL_SECONDS, "challenge_ttl", 300),
    challengeRequestsPerMinute: positiveInteger(env.CHALLENGE_REQUESTS_PER_MINUTE, "challenge_rate", 30),
    attestationGlobalRequestsPerMinute: positiveInteger(
      env.ATTESTATION_GLOBAL_REQUESTS_PER_MINUTE,
      "attestation_global_rate",
      1_000,
    ),
    attestationNetworkRequestsPerMinute: positiveInteger(
      env.ATTESTATION_NETWORK_REQUESTS_PER_MINUTE,
      "attestation_network_rate",
      60,
    ),
    allowedEnvironments,
    allowedValidationCategories: commaSeparatedSet(
      env.APP_ATTEST_ALLOWED_VALIDATION_CATEGORIES,
      "app_attest_categories",
      (value) => /^\d+$/u.test(value) && Number(value) >= 1 && Number(value) <= 10
        ? Number(value)
        : null,
    ),
    allowedBundleVersions,
    requireIOS27Signals: env.APP_ATTEST_REQUIRE_IOS27_SIGNALS === "true",
    deviceCheckEnabled,
    deviceCheckReplayTTLSeconds: positiveInteger(
      env.DEVICECHECK_REPLAY_TTL_SECONDS,
      "devicecheck_replay_ttl",
      604_800,
    ),
    deviceCheckEnvironment: env.DEVICECHECK_ENVIRONMENT === "development" ? "development" : "production",
    deviceCheckKeyID: deviceCheckEnabled && typeof env.APPLE_DEVICECHECK_KEY_ID === "string"
      && /^[A-Z0-9]{10}$/u.test(env.APPLE_DEVICECHECK_KEY_ID)
      ? env.APPLE_DEVICECHECK_KEY_ID
      : "",
    deviceCheckPrivateKey: deviceCheckEnabled
      ? secret(env.APPLE_DEVICECHECK_PRIVATE_KEY, "devicecheck_private_key")
      : "",
    attestationNamespace: env.ATTESTATION_STATE,
  };
}

export function loadConfig(env) {
  if (env.PRICING_CONFIGURED !== "true") {
    throw new ConfigurationError("pricing_not_configured");
  }
  const enabledTiers = new Set(
    String(env.ENABLED_TIERS ?? "")
      .split(",")
      .map((tier) => tier.trim())
      .filter(Boolean),
  );
  if (enabledTiers.size === 0 || [...enabledTiers].some((tier) => !ROUTES[tier])) {
    throw new ConfigurationError("enabled_tiers_invalid");
  }
  if (!env.INSTALLATION_LIMITER || typeof env.INSTALLATION_LIMITER.idFromName !== "function") {
    throw new ConfigurationError("limiter_binding_missing");
  }
  const deviceCheckEnabledTiers = commaSeparatedSet(env.DEVICECHECK_ENABLED_TIERS, "devicecheck_enabled_tiers");
  if ([...deviceCheckEnabledTiers].some((tier) => !ROUTES[tier] || !enabledTiers.has(tier))) {
    throw new ConfigurationError("devicecheck_enabled_tiers_invalid");
  }
  return {
    openAIAPIKey: typeof env.OPENAI_API_KEY === "string" && env.OPENAI_API_KEY.length > 10
      ? env.OPENAI_API_KEY
      : (() => { throw new ConfigurationError("openai_key_missing"); })(),
    tokenHMACKey: secret(env.ANONYMOUS_TOKEN_HMAC_KEY, "anonymous_token_key"),
    safetyIdentifierHMACKey: secret(env.SAFETY_IDENTIFIER_HMAC_KEY, "safety_identifier_key"),
    tokenIssuer: typeof env.TOKEN_ISSUER === "string" && env.TOKEN_ISSUER.length > 0 && env.TOKEN_ISSUER.length <= 120
      ? env.TOKEN_ISSUER
      : (() => { throw new ConfigurationError("token_issuer_invalid"); })(),
    tokenAudience: typeof env.TOKEN_AUDIENCE === "string" && env.TOKEN_AUDIENCE.length > 0 && env.TOKEN_AUDIENCE.length <= 120
      ? env.TOKEN_AUDIENCE
      : (() => { throw new ConfigurationError("token_audience_invalid"); })(),
    tokenMaxTTLSeconds: positiveInteger(env.TOKEN_MAX_TTL_SECONDS, "token_ttl", 600),
    enabledTiers,
    requestsPerMinute: positiveInteger(env.REQUESTS_PER_MINUTE, "requests_per_minute", 1_000),
    maxConcurrentRequests: positiveInteger(env.MAX_CONCURRENT_REQUESTS, "max_concurrent_requests", 20),
    dailySpendLimitMicros: positiveInteger(env.DAILY_SPEND_LIMIT_MICRODOLLARS, "daily_spend_limit"),
    deviceCheckRequestsPerMinute: positiveInteger(env.DEVICECHECK_REQUESTS_PER_MINUTE, "devicecheck_requests_per_minute", 100),
    deviceCheckMaxConcurrentRequests: positiveInteger(env.DEVICECHECK_MAX_CONCURRENT_REQUESTS, "devicecheck_concurrent_requests", 5),
    deviceCheckDailySpendLimitMicros: positiveInteger(env.DEVICECHECK_DAILY_SPEND_LIMIT_MICRODOLLARS, "devicecheck_daily_spend_limit"),
    deviceCheckEnabledTiers,
    reservationLeaseMilliseconds: positiveInteger(env.RESERVATION_LEASE_MILLISECONDS, "reservation_lease", 600_000),
    prices: {
      fast: {
        inputPerMillionMicros: positiveInteger(env.FAST_INPUT_MICRODOLLARS_PER_MILLION, "fast_input_price"),
        cachedInputPerMillionMicros: positiveInteger(env.FAST_CACHED_INPUT_MICRODOLLARS_PER_MILLION, "fast_cached_input_price"),
        cacheWritePerMillionMicros: positiveInteger(env.FAST_CACHE_WRITE_MICRODOLLARS_PER_MILLION, "fast_cache_write_price"),
        outputPerMillionMicros: positiveInteger(env.FAST_OUTPUT_MICRODOLLARS_PER_MILLION, "fast_output_price"),
      },
      pro: {
        inputPerMillionMicros: positiveInteger(env.PRO_INPUT_MICRODOLLARS_PER_MILLION, "pro_input_price"),
        cachedInputPerMillionMicros: positiveInteger(env.PRO_CACHED_INPUT_MICRODOLLARS_PER_MILLION, "pro_cached_input_price"),
        cacheWritePerMillionMicros: positiveInteger(env.PRO_CACHE_WRITE_MICRODOLLARS_PER_MILLION, "pro_cache_write_price"),
        outputPerMillionMicros: positiveInteger(env.PRO_OUTPUT_MICRODOLLARS_PER_MILLION, "pro_output_price"),
      },
    },
    limiterNamespace: env.INSTALLATION_LIMITER,
  };
}
