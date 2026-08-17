#!/usr/bin/env node

import { createLocalAnonymousToken } from "../src/auth.mjs";
import { sha256Base64URL } from "../src/attestation.mjs";
import { readFile } from "node:fs/promises";

const installationID = process.argv[2];
const requestBodyPath = process.argv[3];
const tokenHMACKey = process.env.ANONYMOUS_TOKEN_HMAC_KEY;
if (!installationID || !/^[A-Za-z0-9_-]{24,128}$/u.test(installationID) || !requestBodyPath) {
  process.stderr.write("Usage: npm run token:local -- <opaque-installation-id> <request-body.json>\n");
  process.exit(2);
}
if (!tokenHMACKey || new TextEncoder().encode(tokenHMACKey).length < 32) {
  process.stderr.write("ANONYMOUS_TOKEN_HMAC_KEY must be set in this terminal (at least 32 bytes).\n");
  process.exit(2);
}

const requestBody = await readFile(requestBodyPath);
const requestHash = await sha256Base64URL(requestBody);
const token = await createLocalAnonymousToken(installationID, requestHash, {
  tokenHMACKey,
  tokenIssuer: process.env.TOKEN_ISSUER || "iagent-anonymous-attestation",
  tokenAudience: process.env.TOKEN_AUDIENCE || "ask-iagent-relay",
  tokenMaxTTLSeconds: 600,
});
process.stdout.write(`${token}\n`);
