'use strict';
const test = require('node:test');
const assert = require('node:assert');
const crypto = require('node:crypto');
const { parseRequest, buildPush, sendPush } = require('./relay');

const key = 'test-key';
const now = 1_000_000_000;

function signed(fields) {
  const rawBody = Buffer.from(JSON.stringify(fields));
  const signature = crypto.createHmac('sha256', key).update(rawBody).digest('hex');
  return { key, rawBody, signature, now };
}

const good = { tokens: ['t1'], conversationId: 'keli', timestampMs: now };

test('accepts a correctly signed request', () => {
  assert.deepStrictEqual(parseRequest(signed(good)), { tokens: ['t1'], conversationId: 'keli' });
});

test('refuses a wrong or missing signature', () => {
  const request = signed(good);
  assert.strictEqual(parseRequest({ ...request, signature: 'ab'.repeat(32) }).status, 401);
  assert.strictEqual(parseRequest({ ...request, signature: undefined }).status, 401);
  assert.strictEqual(parseRequest({ ...request, signature: 'short' }).status, 401);
});

test('a rotated key cuts off the old one', () => {
  assert.strictEqual(parseRequest({ ...signed(good), key: 'new-key' }).status, 401);
});

test('refuses tampering after signing', () => {
  const request = signed(good);
  const tampered = Buffer.from(JSON.stringify({ ...good, tokens: ['other'] }));
  assert.strictEqual(parseRequest({ ...request, rawBody: tampered }).status, 401);
});

test('refuses a replayed old request', () => {
  const old = signed({ ...good, timestampMs: now - 6 * 60 * 1000 });
  assert.strictEqual(parseRequest(old).status, 401);
});

test('refuses bad fields', () => {
  for (const fields of [
    { ...good, tokens: [] },
    { ...good, tokens: 'x' },
    { ...good, tokens: Array(9).fill('t') },
    { ...good, conversationId: '' },
    { ...good, conversationId: 'x'.repeat(65) },
  ]) {
    assert.strictEqual(parseRequest(signed(fields)).status, 400);
  }
});

test('refuses to run without a key', () => {
  assert.strictEqual(parseRequest({ ...signed(good), key: '' }).status, 500);
});

test('the push carries no message text', () => {
  const push = buildPush(['t1'], 'keli');
  assert.strictEqual(push.notification.body, 'New message');
  assert.deepStrictEqual(push.data, { conversationId: 'keli' });
});

test('reports only tokens that are permanently dead', async () => {
  const messaging = {
    sendEachForMulticast: async () => ({
      responses: [
        { success: true },
        { success: false, error: { code: 'messaging/registration-token-not-registered' } },
        { success: false, error: { code: 'messaging/internal-error' } },
      ],
    }),
  };
  assert.deepStrictEqual(await sendPush(messaging, ['a', 'b', 'c'], 'keli'), ['b']);
});
