import cbor from "cbor";
import { X509Certificate } from "node:crypto";
import { SignJWT, importPKCS8 } from "jose";
import { verifyAssertion, verifyAttestation } from "node-app-attest";

import { base64URLToBytes, bytesToBase64URL } from "./auth.mjs";

const encoder = new TextEncoder();

export const ATTESTATION_DIAGNOSTIC_CODES = Object.freeze({
  invalidRequest: "attestation_invalid_request",
  rejected: "attestation_rejected",
  unavailable: "attestation_unavailable",
  internalFailure: "attestation_internal_failure",
  certificateCBORInvalid: "app_attest_certificate_cbor_invalid",
  certificateDateInvalid: "app_attest_certificate_date_invalid",
  nodeAttestationVerificationFailed: "app_attest_node_verification_failed",
  nodeAttestationStructureInvalid: "app_attest_node_structure_invalid",
  nodeAttestationCertificateChainInvalid: "app_attest_node_certificate_chain_invalid",
  nodeAttestationNonceInvalid: "app_attest_node_nonce_invalid",
  nodeAttestationKeyIDInvalid: "app_attest_node_key_id_invalid",
  nodeAttestationAppIDInvalid: "app_attest_node_app_id_invalid",
  nodeAttestationCounterInvalid: "app_attest_node_counter_invalid",
  nodeAttestationAAGUIDInvalid: "app_attest_node_aaguid_invalid",
  nodeAttestationCredentialIDInvalid: "app_attest_node_credential_id_invalid",
  environmentMismatch: "app_attest_environment_mismatch",
  environmentInvalid: "app_attest_environment_invalid",
  extensionsDecodeFailed: "app_attest_extensions_decode_failed",
  extensionsAuthDataTypeInvalid: "app_attest_extensions_auth_data_type_invalid",
  extensionsAuthDataLengthInvalid: "app_attest_extensions_auth_data_length_invalid",
  extensionsAttestedCredentialFlagInvalid: "app_attest_extensions_attested_credential_flag_invalid",
  extensionsCredentialBoundsInvalid: "app_attest_extensions_credential_bounds_invalid",
  extensionsCOSEDecodeFailed: "app_attest_extensions_cose_decode_failed",
  extensionsCOSELengthInvalid: "app_attest_extensions_cose_length_invalid",
  extensionsDictionaryMissing: "app_attest_extensions_dictionary_missing",
  extensionsDictionaryDecodeFailed: "app_attest_extensions_dictionary_decode_failed",
  extensionsDictionaryTrailingData: "app_attest_extensions_dictionary_trailing_data",
  extensionsDictionaryShapeInvalid: "app_attest_extensions_dictionary_shape_invalid",
  validationCategoryMissing: "app_attest_validation_category_missing",
  validationCategoryInvalid: "app_attest_validation_category_invalid",
  bundleVersionMissing: "app_attest_bundle_version_missing",
  bundleVersionTypeInvalid: "app_attest_bundle_version_type_invalid",
  bundleVersionValueInvalid: "app_attest_bundle_version_value_invalid",
  assertionCBORInvalid: "app_attest_assertion_cbor_invalid",
  nodeAssertionVerificationFailed: "app_attest_assertion_verification_failed",
  stateInvalid: "attestation_state_invalid",
  settlementFailed: "attestation_settlement_failed",
});

const ALLOWED_DIAGNOSTIC_CODES = new Set(Object.values(ATTESTATION_DIAGNOSTIC_CODES));

export class AttestationError extends Error {
  constructor(
    message = "unauthorized",
    status = 401,
    diagnosticCode = status === 400
      ? ATTESTATION_DIAGNOSTIC_CODES.invalidRequest
      : status === 503
        ? ATTESTATION_DIAGNOSTIC_CODES.unavailable
        : ATTESTATION_DIAGNOSTIC_CODES.rejected,
  ) {
    super(message);
    this.name = "AttestationError";
    this.status = status;
    this.diagnosticCode = ALLOWED_DIAGNOSTIC_CODES.has(diagnosticCode)
      ? diagnosticCode
      : ATTESTATION_DIAGNOSTIC_CODES.internalFailure;
  }
}

/// A cryptographically valid development App Attest key reached a relay that authorizes only
/// production keys. This is the sole verifier result a native client may heal by replacing its
/// anonymous installation/key pair. All pre-crypto, malformed, unknown-environment, and
/// configuration failures remain ordinary AttestationError values and receive generic responses.
export class AppAttestEnvironmentMismatchError extends AttestationError {
  constructor() {
    super(
      "unauthorized",
      401,
      ATTESTATION_DIAGNOSTIC_CODES.environmentMismatch,
    );
    this.name = "AppAttestEnvironmentMismatchError";
  }
}

function diagnosticError(code) {
  return new AttestationError("unauthorized", 401, code);
}

const NODE_ATTESTATION_ERROR_CODES = new Map([
  ["invalid attestation", ATTESTATION_DIAGNOSTIC_CODES.nodeAttestationStructureInvalid],
  [
    "number of decoded attestations is not 1",
    ATTESTATION_DIAGNOSTIC_CODES.nodeAttestationStructureInvalid,
  ],
  ["invalid certificate", ATTESTATION_DIAGNOSTIC_CODES.nodeAttestationCertificateChainInvalid],
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
]);

export function classifyNodeAttestationVerificationError(error) {
  const message = error && typeof error.message === "string" ? error.message : "";
  return NODE_ATTESTATION_ERROR_CODES.get(message)
    ?? ATTESTATION_DIAGNOSTIC_CODES.nodeAttestationVerificationFailed;
}

function exactObject(value, allowedKeys) {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new AttestationError("invalid_request", 400);
  const keys = Object.keys(value);
  if (keys.some((key) => !allowedKeys.has(key))) throw new AttestationError("invalid_request", 400);
  return value;
}

function boundedString(value, pattern, maximum) {
  if (typeof value !== "string" || value.length > maximum || !pattern.test(value)) {
    throw new AttestationError("invalid_request", 400);
  }
  return value;
}

function decodeBase64Artifact(value, maximumBytes = 48 * 1024) {
  boundedString(value, /^[A-Za-z0-9+/]+={0,2}$/u, Math.ceil(maximumBytes * 4 / 3) + 4);
  let bytes;
  try {
    bytes = Buffer.from(value, "base64");
  } catch {
    throw new AttestationError("invalid_request", 400);
  }
  if (bytes.byteLength === 0 || bytes.byteLength > maximumBytes || bytes.toString("base64") !== value) {
    throw new AttestationError("invalid_request", 400);
  }
  return bytes;
}

export function validateChallengeRequest(value) {
  const body = exactObject(value, new Set(["protocolVersion", "assurance", "installationID", "keyID", "requestHash"]));
  if (body.protocolVersion !== 1 || (body.assurance !== "app_attest" && body.assurance !== "devicecheck")) {
    throw new AttestationError("invalid_request", 400);
  }
  const installationID = boundedString(body.installationID, /^[A-Za-z0-9_-]{32,128}$/u, 128);
  const requestHash = boundedString(body.requestHash, /^[A-Za-z0-9_-]{43}$/u, 43);
  if (body.assurance === "app_attest") {
    return {
      protocolVersion: 1,
      assurance: body.assurance,
      installationID,
      requestHash,
      keyID: boundedString(body.keyID, /^[A-Za-z0-9+/]{43}=$/u, 44),
    };
  }
  if (body.keyID !== null && body.keyID !== undefined) throw new AttestationError("invalid_request", 400);
  return { protocolVersion: 1, assurance: body.assurance, installationID, requestHash, keyID: null };
}

export function validateExchangeRequest(value) {
  const body = exactObject(
    value,
    new Set(["protocolVersion", "challengeID", "assurance", "installationID", "keyID", "artifactType", "artifact"]),
  );
  if (body.protocolVersion !== 1 || (body.assurance !== "app_attest" && body.assurance !== "devicecheck")) {
    throw new AttestationError("invalid_request", 400);
  }
  const result = {
    protocolVersion: 1,
    challengeID: boundedString(body.challengeID, /^[A-Za-z0-9_-]{16,128}$/u, 128),
    assurance: body.assurance,
    installationID: boundedString(body.installationID, /^[A-Za-z0-9_-]{32,128}$/u, 128),
    artifact: decodeBase64Artifact(body.artifact),
  };
  if (body.assurance === "app_attest") {
    if (body.artifactType !== "attestation" && body.artifactType !== "assertion") {
      throw new AttestationError("invalid_request", 400);
    }
    return {
      ...result,
      keyID: boundedString(body.keyID, /^[A-Za-z0-9+/]{43}=$/u, 44),
      artifactType: body.artifactType,
    };
  }
  if (body.keyID !== null && body.keyID !== undefined) throw new AttestationError("invalid_request", 400);
  if (body.artifactType !== "devicecheck") throw new AttestationError("invalid_request", 400);
  return { ...result, keyID: null, artifactType: "devicecheck" };
}

export async function sha256Base64URL(value) {
  const bytes = typeof value === "string" ? encoder.encode(value) : value;
  const digest = await crypto.subtle.digest("SHA-256", bytes);
  return bytesToBase64URL(new Uint8Array(digest));
}

function decodeSingleCBOR(value, diagnosticCode) {
  let decoded;
  try {
    decoded = cbor.decodeAllSync(value);
  } catch {
    throw diagnosticError(diagnosticCode);
  }
  if (decoded.length !== 1) throw diagnosticError(diagnosticCode);
  return decoded[0];
}

function mapValue(map, key) {
  if (map instanceof Map) return map.get(key);
  if (map && typeof map === "object") return map[key];
  return undefined;
}

function mapHas(map, key) {
  if (map instanceof Map) return map.has(key);
  return Boolean(map && typeof map === "object" && Object.prototype.hasOwnProperty.call(map, key));
}

function isExtensionDictionary(value) {
  return value instanceof Map || Boolean(
    value
    && typeof value === "object"
    && !Array.isArray(value)
    && !Buffer.isBuffer(value)
    && !(value instanceof Uint8Array),
  );
}

function decodeExtensions(authData, attestedCredentialData) {
  const decodeError = (code) => diagnosticError(code);
  if (!Buffer.isBuffer(authData)) {
    throw decodeError(ATTESTATION_DIAGNOSTIC_CODES.extensionsAuthDataTypeInvalid);
  }
  if (authData.length < 37) {
    throw decodeError(ATTESTATION_DIAGNOSTIC_CODES.extensionsAuthDataLengthInvalid);
  }
  const flags = authData[32];
  const hasAttestedCredentialData = (flags & 0x40) !== 0;
  const hasExtensions = (flags & 0x80) !== 0;
  // Apple's assertions in the field and node-app-attest's valid signed fixture can retain the AT
  // bit even though assertion authenticatorData contains only RP ID, flags, counter, and optional
  // extension bytes. The AT bit is therefore enforced only for an attestation object, whose
  // credential/COSE layout we actually parse below. Assertion extensions always begin at byte 37.
  if (attestedCredentialData && !hasAttestedCredentialData) {
    throw decodeError(ATTESTATION_DIAGNOSTIC_CODES.extensionsAttestedCredentialFlagInvalid);
  }

  let offset = 37;
  if (attestedCredentialData) {
    if (authData.length < 55) {
      throw decodeError(ATTESTATION_DIAGNOSTIC_CODES.extensionsCredentialBoundsInvalid);
    }
    const credentialLength = authData.readUInt16BE(53);
    offset = 55 + credentialLength;
    if (offset >= authData.length) {
      throw decodeError(ATTESTATION_DIAGNOSTIC_CODES.extensionsCredentialBoundsInvalid);
    }
    let cose;
    try {
      cose = cbor.decodeFirstSync(authData.subarray(offset), { extendedResults: true });
    } catch {
      throw decodeError(ATTESTATION_DIAGNOSTIC_CODES.extensionsCOSEDecodeFailed);
    }
    if (!cose || !Number.isSafeInteger(cose.length) || cose.length <= 0) {
      throw decodeError(ATTESTATION_DIAGNOSTIC_CODES.extensionsCOSELengthInvalid);
    }
    offset += cose.length;
  }
  // Apple's iOS 27 validation-guide fixture appends the extensions dictionary without setting
  // WebAuthn's ED flag. Treat trailing bytes as extensions as well as honoring the flag, otherwise
  // the new TestFlight/bundle-version signals are silently skipped. Conversely, an asserted ED bit
  // with no dictionary is malformed.
  if (offset === authData.length) {
    if (hasExtensions) {
      throw decodeError(ATTESTATION_DIAGNOSTIC_CODES.extensionsDictionaryMissing);
    }
    return null;
  }
  let decoded;
  try {
    decoded = cbor.decodeFirstSync(authData.subarray(offset), { extendedResults: true });
  } catch {
    throw decodeError(ATTESTATION_DIAGNOSTIC_CODES.extensionsDictionaryDecodeFailed);
  }
  if (!decoded || decoded.length !== authData.length - offset) {
    throw decodeError(ATTESTATION_DIAGNOSTIC_CODES.extensionsDictionaryTrailingData);
  }
  if (!isExtensionDictionary(decoded.value)) {
    throw decodeError(ATTESTATION_DIAGNOSTIC_CODES.extensionsDictionaryShapeInvalid);
  }
  return decoded.value;
}

function uint32Value(value) {
  if (Number.isSafeInteger(value) && value >= 0 && value <= 0xffff_ffff) return value;
  if ((Buffer.isBuffer(value) || value instanceof Uint8Array) && value.byteLength === 4) {
    // Apple encodes ValidationCategory as a four-byte, little-endian UInt32 byte string.
    return Buffer.from(value).readUInt32LE(0);
  }
  return null;
}

function validateOptionalIOS27Signals(extensions, config) {
  if (!extensions) {
    if (config.requireIOS27Signals) {
      throw diagnosticError(ATTESTATION_DIAGNOSTIC_CODES.validationCategoryMissing);
    }
    return { validationCategory: null, bundleVersion: null };
  }

  const validationCategoryKey = "apple_validation_category_01";
  const bundleVersionKey = "apple_bundle_version_01";
  const hasValidationCategory = mapHas(extensions, validationCategoryKey);
  const hasBundleVersion = mapHas(extensions, bundleVersionKey);
  if (!hasValidationCategory && config.requireIOS27Signals) {
    throw diagnosticError(ATTESTATION_DIAGNOSTIC_CODES.validationCategoryMissing);
  }
  if (!hasBundleVersion && config.requireIOS27Signals) {
    throw diagnosticError(ATTESTATION_DIAGNOSTIC_CODES.bundleVersionMissing);
  }

  const validationCategory = hasValidationCategory
    ? uint32Value(mapValue(extensions, validationCategoryKey))
    : null;
  if (
    hasValidationCategory
    && (
      !Number.isSafeInteger(validationCategory)
      || !config.allowedValidationCategories.has(validationCategory)
    )
  ) {
    throw diagnosticError(ATTESTATION_DIAGNOSTIC_CODES.validationCategoryInvalid);
  }

  const bundleVersion = hasBundleVersion ? mapValue(extensions, bundleVersionKey) : null;
  if (hasBundleVersion && typeof bundleVersion !== "string") {
    throw diagnosticError(ATTESTATION_DIAGNOSTIC_CODES.bundleVersionTypeInvalid);
  }
  if (hasBundleVersion && !config.allowedBundleVersions.has(bundleVersion)) {
    throw diagnosticError(ATTESTATION_DIAGNOSTIC_CODES.bundleVersionValueInvalid);
  }
  return { validationCategory, bundleVersion };
}

export function validateAppAttestAuthenticatorSignals(authData, attestedCredentialData, config) {
  return validateOptionalIOS27Signals(decodeExtensions(authData, attestedCredentialData), config);
}

function validateCertificateDates(attestation, now) {
  const decoded = decodeSingleCBOR(
    attestation,
    ATTESTATION_DIAGNOSTIC_CODES.certificateCBORInvalid,
  );
  const x5c = decoded?.attStmt?.x5c;
  if (!Array.isArray(x5c) || x5c.length !== 2 || x5c.some((item) => !Buffer.isBuffer(item))) {
    throw diagnosticError(ATTESTATION_DIAGNOSTIC_CODES.certificateCBORInvalid);
  }
  let certificates;
  try {
    certificates = x5c.map((item) => new X509Certificate(item));
  } catch {
    throw diagnosticError(ATTESTATION_DIAGNOSTIC_CODES.certificateCBORInvalid);
  }
  const instant = new Date(now).getTime();
  if (certificates.some((certificate) => {
    const start = Date.parse(certificate.validFrom);
    const end = Date.parse(certificate.validTo);
    return !Number.isFinite(start) || !Number.isFinite(end) || instant < start || instant > end;
  })) {
    throw diagnosticError(ATTESTATION_DIAGNOSTIC_CODES.certificateDateInvalid);
  }
  return decoded;
}

export function verifyAppAttestAttestation({ artifact, clientData, keyID, config, now = Date.now() }) {
  const decoded = validateCertificateDates(artifact, now);
  let result;
  try {
    result = verifyAttestation({
      attestation: artifact,
      challenge: clientData,
      keyId: keyID,
      bundleIdentifier: config.bundleIdentifier,
      teamIdentifier: config.teamIdentifier,
      // Ask the dependency to validate either Apple AAGUID so the wrapper can distinguish a
      // cryptographically valid development key from an otherwise-invalid artifact. The strict
      // allowlist immediately below remains the authorization boundary and still rejects a
      // development key when production is the only configured environment.
      allowDevelopmentEnvironment: true,
    });
  } catch (error) {
    // node-app-attest uses stable, fixed messages for each verifier stage. Convert exact known
    // values to bounded categories; never include the raw exception text in logs or responses.
    throw diagnosticError(classifyNodeAttestationVerificationError(error));
  }
  const productionOnly = config.allowedEnvironments.size === 1
    && config.allowedEnvironments.has("production");
  if (result.environment === "development" && productionOnly) {
    throw new AppAttestEnvironmentMismatchError();
  }
  if (!config.allowedEnvironments.has(result.environment)) {
    throw diagnosticError(ATTESTATION_DIAGNOSTIC_CODES.environmentInvalid);
  }
  const signals = validateAppAttestAuthenticatorSignals(decoded.authData, true, config);
  return {
    publicKey: result.publicKey,
    receipt: bytesToBase64URL(new Uint8Array(result.receipt)),
    environment: result.environment,
    signCount: 0,
    ...signals,
  };
}

export function verifyAppAttestAssertion({ artifact, clientData, publicKey, signCount, config }) {
  const decoded = decodeSingleCBOR(artifact, ATTESTATION_DIAGNOSTIC_CODES.assertionCBORInvalid);
  if (!Buffer.isBuffer(decoded?.signature) || !Buffer.isBuffer(decoded?.authenticatorData)) {
    throw diagnosticError(ATTESTATION_DIAGNOSTIC_CODES.assertionCBORInvalid);
  }
  let result;
  try {
    result = verifyAssertion({
      assertion: artifact,
      payload: clientData,
      publicKey,
      bundleIdentifier: config.bundleIdentifier,
      teamIdentifier: config.teamIdentifier,
      signCount,
    });
  } catch {
    throw diagnosticError(ATTESTATION_DIAGNOSTIC_CODES.nodeAssertionVerificationFailed);
  }
  const signals = validateAppAttestAuthenticatorSignals(decoded.authenticatorData, false, config);
  return { signCount: result.signCount, ...signals };
}

export async function validateDeviceCheckToken({ token, transactionID, config, now = Date.now(), fetchImpl = fetch }) {
  if (!config.deviceCheckEnabled) throw new AttestationError("attestation_unavailable", 503);
  let privateKey;
  try {
    privateKey = await importPKCS8(config.deviceCheckPrivateKey, "ES256");
  } catch {
    throw new AttestationError("attestation_unavailable", 503);
  }
  const nowSeconds = Math.floor(now / 1_000);
  const appleToken = await new SignJWT({})
    .setProtectedHeader({ alg: "ES256", kid: config.deviceCheckKeyID })
    .setIssuer(config.teamIdentifier)
    .setIssuedAt(nowSeconds)
    .setExpirationTime(nowSeconds + 300)
    .sign(privateKey);
  const baseURL = config.deviceCheckEnvironment === "development"
    ? "https://api.development.devicecheck.apple.com"
    : "https://api.devicecheck.apple.com";
  let response;
  try {
    response = await fetchImpl(`${baseURL}/v1/validate_device_token`, {
      method: "POST",
      headers: { Authorization: `Bearer ${appleToken}`, "Content-Type": "application/json" },
      body: JSON.stringify({
        device_token: token.toString("base64"),
        transaction_id: transactionID,
        timestamp: now,
      }),
    });
  } catch {
    throw new AttestationError("attestation_unavailable", 503);
  }
  if (!response.ok) {
    throw new AttestationError(response.status >= 500 ? "attestation_unavailable" : "unauthorized", response.status >= 500 ? 503 : 401);
  }
  return { ok: true };
}

export function decodeClientData(value) {
  return Buffer.from(base64URLToBytes(value));
}
