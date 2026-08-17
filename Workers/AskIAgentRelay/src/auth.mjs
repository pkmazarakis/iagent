const encoder = new TextEncoder();
const decoder = new TextDecoder();

export class AuthenticationError extends Error {
  constructor(message = "unauthorized") {
    super(message);
    this.name = "AuthenticationError";
    this.status = 401;
  }
}

export function bytesToBase64URL(bytes) {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/u, "");
}

export function base64URLToBytes(value) {
  if (typeof value !== "string" || !/^[A-Za-z0-9_-]+$/u.test(value)) throw new AuthenticationError();
  const padded = value.replaceAll("-", "+").replaceAll("_", "/").padEnd(Math.ceil(value.length / 4) * 4, "=");
  let binary;
  try {
    binary = atob(padded);
  } catch {
    throw new AuthenticationError();
  }
  return Uint8Array.from(binary, (character) => character.charCodeAt(0));
}

function encodeJSON(value) {
  return bytesToBase64URL(encoder.encode(JSON.stringify(value)));
}

function decodeJSON(value) {
  try {
    return JSON.parse(decoder.decode(base64URLToBytes(value)));
  } catch {
    throw new AuthenticationError();
  }
}

async function hmacKey(secret, usage) {
  return crypto.subtle.importKey(
    "raw",
    encoder.encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    [usage],
  );
}

export function bearerTokenFromRequest(request) {
  const authorization = request.headers.get("Authorization");
  if (!authorization || authorization.length > 4_096 || !authorization.startsWith("Bearer ")) {
    throw new AuthenticationError();
  }
  const token = authorization.slice("Bearer ".length);
  if (!token || token.includes(" ")) throw new AuthenticationError();
  return token;
}

export async function verifyAnonymousInstallationToken(token, config, now = Date.now()) {
  const pieces = token.split(".");
  if (pieces.length !== 3) throw new AuthenticationError();
  const [encodedHeader, encodedClaims, encodedSignature] = pieces;
  const header = decodeJSON(encodedHeader);
  const claims = decodeJSON(encodedClaims);
  if (header?.alg !== "HS256" || header?.typ !== "JWT" || header?.kid !== "iagent-anonymous-v1") {
    throw new AuthenticationError();
  }
  const key = await hmacKey(config.tokenHMACKey, "verify");
  const verified = await crypto.subtle.verify(
    "HMAC",
    key,
    base64URLToBytes(encodedSignature),
    encoder.encode(`${encodedHeader}.${encodedClaims}`),
  );
  if (!verified) throw new AuthenticationError();

  const nowSeconds = Math.floor(now / 1_000);
  if (
    claims?.v !== 1 ||
    claims?.iss !== config.tokenIssuer ||
    claims?.aud !== config.tokenAudience ||
    typeof claims?.sub !== "string" ||
    !/^[A-Za-z0-9_-]{24,128}$/u.test(claims.sub) ||
    typeof claims?.jti !== "string" ||
    !/^[A-Za-z0-9_-]{16,128}$/u.test(claims.jti) ||
    typeof claims?.req !== "string" ||
    !/^[A-Za-z0-9_-]{43}$/u.test(claims.req) ||
    (claims?.attestation !== "app_attest" && claims?.attestation !== "devicecheck") ||
    !Number.isSafeInteger(claims?.iat) ||
    !Number.isSafeInteger(claims?.exp) ||
    claims.iat > nowSeconds + 30 ||
    claims.exp <= nowSeconds ||
    claims.exp - claims.iat > config.tokenMaxTTLSeconds
  ) {
    throw new AuthenticationError();
  }
  return {
    installationID: claims.sub,
    tokenID: claims.jti,
    attestation: claims.attestation,
    requestHash: claims.req,
    expiresAt: claims.exp * 1_000,
  };
}

export async function deriveSafetyIdentifier(installationID, secret) {
  const key = await hmacKey(secret, "sign");
  const signature = await crypto.subtle.sign("HMAC", key, encoder.encode(installationID));
  return `ia_${bytesToBase64URL(new Uint8Array(signature)).slice(0, 43)}`;
}

export async function deriveAnonymousInstallationSubject(stableIdentifier, secret) {
  const key = await hmacKey(secret, "sign");
  const signature = await crypto.subtle.sign(
    "HMAC",
    key,
    encoder.encode(`installation-subject-v1\n${stableIdentifier}`),
  );
  return bytesToBase64URL(new Uint8Array(signature));
}

export async function createAnonymousInstallationToken(
  installationID,
  requestHash,
  config,
  { now = Date.now(), ttlSeconds = 180, attestation = "app_attest", tokenID = crypto.randomUUID() } = {},
) {
  if (!/^[A-Za-z0-9_-]{43}$/u.test(requestHash)) throw new AuthenticationError();
  const issuedAt = Math.floor(now / 1_000);
  const header = { alg: "HS256", typ: "JWT", kid: "iagent-anonymous-v1" };
  const claims = {
    v: 1,
    iss: config.tokenIssuer,
    aud: config.tokenAudience,
    sub: installationID,
    jti: tokenID.replaceAll("-", "_"),
    req: requestHash,
    attestation,
    iat: issuedAt,
    exp: issuedAt + Math.min(ttlSeconds, config.tokenMaxTTLSeconds),
  };
  const signingInput = `${encodeJSON(header)}.${encodeJSON(claims)}`;
  const key = await hmacKey(config.tokenHMACKey, "sign");
  const signature = await crypto.subtle.sign("HMAC", key, encoder.encode(signingInput));
  return {
    token: `${signingInput}.${bytesToBase64URL(new Uint8Array(signature))}`,
    expiresAt: claims.exp * 1_000,
  };
}

// Development/test helper only. Production tokens must be minted after server-side Apple attestation.
export async function createLocalAnonymousToken(
  installationID,
  requestHash,
  config,
  { now = Date.now(), ttlSeconds = 300, attestation = "app_attest", tokenID = crypto.randomUUID() } = {},
) {
  return (await createAnonymousInstallationToken(installationID, requestHash, config, {
    now,
    ttlSeconds,
    attestation,
    tokenID,
  })).token;
}
