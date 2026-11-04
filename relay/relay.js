'use strict';
const crypto = require('node:crypto');

const MAX_AGE_MS = 5 * 60 * 1000;
const MAX_TOKENS = 8;
const MAX_ID_LENGTH = 64;
const DEAD_TOKEN_CODES = new Set([
  'messaging/registration-token-not-registered',
  'messaging/invalid-registration-token',
]);

function signatureOk(key, rawBody, signature) {
  if (typeof signature !== 'string') return false;
  const expected = crypto.createHmac('sha256', key).update(rawBody).digest();
  const given = Buffer.from(signature, 'hex');
  return given.length === expected.length && crypto.timingSafeEqual(given, expected);
}

/** Returns the parsed request, or an {error, status} explaining why it was refused. */
function parseRequest({ key, rawBody, signature, now }) {
  if (!key) return { error: 'relay is not configured', status: 500 };
  if (!signatureOk(key, rawBody, signature)) return { error: 'bad signature', status: 401 };
  let body;
  try {
    body = JSON.parse(rawBody.toString('utf8'));
  } catch {
    return { error: 'bad JSON', status: 400 };
  }
  const { tokens, conversationId, timestampMs } = body;
  if (typeof timestampMs !== 'number' || Math.abs(now - timestampMs) > MAX_AGE_MS) {
    return { error: 'stale request', status: 401 };
  }
  const validTokens =
    Array.isArray(tokens) &&
    tokens.length > 0 &&
    tokens.length <= MAX_TOKENS &&
    tokens.every((token) => typeof token === 'string' && token.length > 0);
  if (!validTokens) return { error: 'bad tokens', status: 400 };
  if (
    typeof conversationId !== 'string' ||
    conversationId.length === 0 ||
    conversationId.length > MAX_ID_LENGTH
  ) {
    return { error: 'bad conversation', status: 400 };
  }
  return { tokens, conversationId };
}

/** The push contains no message text: only that something arrived, and from which thread. */
function buildPush(tokens, conversationId) {
  return {
    tokens,
    notification: { title: 'Yomi', body: 'New message' },
    data: { conversationId },
    android: { priority: 'high' },
    apns: { headers: { 'apns-priority': '10' } },
  };
}

/** Sends, and returns tokens the push service says will never work again. */
async function sendPush(messaging, tokens, conversationId) {
  const result = await messaging.sendEachForMulticast(buildPush(tokens, conversationId));
  return result.responses.flatMap((response, index) =>
    !response.success && DEAD_TOKEN_CODES.has(response.error?.code) ? [tokens[index]] : [],
  );
}

module.exports = { parseRequest, buildPush, sendPush };
