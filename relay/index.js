'use strict';
const { onRequest } = require('firebase-functions/v2/https');
const { defineSecret } = require('firebase-functions/params');
const { initializeApp } = require('firebase-admin/app');
const { getMessaging } = require('firebase-admin/messaging');
const { parseRequest, sendPush } = require('./relay');

const relayKey = defineSecret('YOMI_RELAY_KEY');
initializeApp();

exports.notify = onRequest({ secrets: [relayKey], maxInstances: 2 }, async (req, res) => {
  if (req.method !== 'POST') {
    res.status(405).json({ error: 'use POST' });
    return;
  }
  const parsed = parseRequest({
    key: relayKey.value(),
    rawBody: req.rawBody,
    signature: req.get('X-Yomi-Signature'),
    now: Date.now(),
  });
  if (parsed.error) {
    res.status(parsed.status).json({ error: parsed.error });
    return;
  }
  try {
    const deadTokens = await sendPush(getMessaging(), parsed.tokens, parsed.conversationId);
    res.json({ deadTokens });
  } catch (error) {
    console.error('push failed', error.code ?? error.message);
    res.status(502).json({ error: 'push failed' });
  }
});
