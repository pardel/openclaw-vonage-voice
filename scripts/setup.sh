#!/usr/bin/env bash
set -euo pipefail

# Usage: scripts/setup.sh <target-directory>
# Creates a Vonage Voice webhook server project.

TARGET="${1:?Usage: setup.sh <target-directory>}"

if [ -d "$TARGET/node_modules" ]; then
  echo "[skip] $TARGET already has node_modules — run 'node server.js' to start"
  exit 0
fi

mkdir -p "$TARGET"

# ── package.json ─────────────────────────────────────────────────────────
cat > "$TARGET/package.json" << 'PACKAGE_EOF'
{
  "name": "vonage-voice",
  "version": "1.0.0",
  "description": "Vonage Voice webhook server for OpenClaw",
  "main": "server.js",
  "scripts": { "start": "node server.js" },
  "dependencies": { "express": "^4.18.0" }
}
PACKAGE_EOF

# ── .env template ────────────────────────────────────────────────────────
if [ ! -f "$TARGET/.env" ]; then
cat > "$TARGET/.env" << 'ENV_EOF'
VONAGE_APP_ID=__SET_ME__
VONAGE_NUMBER=__SET_ME__
PUBLIC_URL=http://__YOUR_PUBLIC_IP__:3000
PORT=3000
OPENCLAW_GATEWAY_URL=http://127.0.0.1:18789
OPENCLAW_GATEWAY_TOKEN=__SET_ME__
ENV_EOF
  echo "[created] $TARGET/.env — edit with your credentials"
else
  echo "[skip] $TARGET/.env already exists"
fi

# ── .gitignore ───────────────────────────────────────────────────────────
cat > "$TARGET/.gitignore" << 'GIT_EOF'
node_modules/
.env
private.key
voice.log
GIT_EOF

# ── server.js ────────────────────────────────────────────────────────────
cat > "$TARGET/server.js" << 'SERVER_EOF'
const express = require('express');
const fs = require('fs');
const path = require('path');

// ── Load .env ───────────────────────────────────────────────────────────
const envPath = path.join(__dirname, '.env');
if (fs.existsSync(envPath)) {
  for (const line of fs.readFileSync(envPath, 'utf8').split('\n')) {
    const m = line.match(/^\s*([^#=]+?)\s*=\s*(.*)\s*$/);
    if (m && !process.env[m[1]]) process.env[m[1]] = m[2];
  }
}

const PORT = parseInt(process.env.PORT || '3000', 10);
const PUBLIC_URL = process.env.PUBLIC_URL || `http://127.0.0.1:${PORT}`;
const OPENCLAW_URL = process.env.OPENCLAW_GATEWAY_URL || 'http://127.0.0.1:18789';
const OPENCLAW_TOKEN = process.env.OPENCLAW_GATEWAY_TOKEN;

const app = express();
app.use(express.json());

// ── Logging ─────────────────────────────────────────────────────────────
const LOG_FILE = path.join(__dirname, 'voice.log');

function log(tag, ...args) {
  const ts = new Date().toISOString();
  const msg = args.map(a => typeof a === 'string' ? a : JSON.stringify(a)).join(' ');
  const line = `[${ts}] [${tag}] ${msg}`;
  console.log(line);
  fs.appendFileSync(LOG_FILE, line + '\n');
}

app.use((req, res, next) => {
  log('HTTP', `${req.method} ${req.url}`);
  next();
});

// ── Conversation state (in-memory) ─────────────────────────────────────
const conversations = new Map();

setInterval(() => {
  const cutoff = Date.now() - 3600_000;
  for (const [id, conv] of conversations) {
    if (conv.updatedAt < cutoff) conversations.delete(id);
  }
}, 600_000);

// ── OpenClaw integration ────────────────────────────────────────────────
async function askClaw(conversationId, userText) {
  let conv = conversations.get(conversationId);
  if (!conv) {
    conv = {
      messages: [
        {
          role: 'system',
          content:
            'You are speaking on a phone call. Keep responses concise and conversational — this is voice, not text. No markdown, no bullet points. Speak naturally. If the caller says goodbye, respond briefly and end warmly.',
        },
      ],
      updatedAt: Date.now(),
    };
    conversations.set(conversationId, conv);
  }

  conv.messages.push({ role: 'user', content: userText });
  conv.updatedAt = Date.now();

  log('CLAW-REQ', `conversation=${conversationId} user="${userText}" messages=${conv.messages.length}`);

  const startMs = Date.now();
  const res = await fetch(`${OPENCLAW_URL}/v1/chat/completions`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      Authorization: `Bearer ${OPENCLAW_TOKEN}`,
    },
    body: JSON.stringify({ model: 'openclaw', messages: conv.messages }),
  });

  const elapsed = Date.now() - startMs;

  if (!res.ok) {
    const body = await res.text();
    log('CLAW-ERR', `status=${res.status} elapsed=${elapsed}ms body=${body}`);
    return "Sorry, I'm having trouble thinking right now. Try again in a moment.";
  }

  const data = await res.json();
  const reply = data.choices?.[0]?.message?.content || "Sorry, I didn't catch that.";
  conv.messages.push({ role: 'assistant', content: reply });
  log('CLAW-REPLY', `conversation=${conversationId} elapsed=${elapsed}ms reply="${reply}"`);
  return reply;
}

// ── NCCO helpers ────────────────────────────────────────────────────────
function listenAction() {
  return {
    action: 'input',
    type: ['speech'],
    speech: {
      language: 'en-GB',
      endOnSilence: 2,
      startTimeout: 20,
      maxDuration: 60,
    },
    eventUrl: [`${PUBLIC_URL}/webhooks/speech`],
  };
}

function talkAction(text) {
  return { action: 'talk', text, language: 'en-GB', style: 2 };
}

// ── Webhooks ────────────────────────────────────────────────────────────
const GREETING = "Hello! What can I help you with?";

app.post('/webhooks/answer', (req, res) => {
  log('ANSWER', `from=${req.body.from} to=${req.body.to} conv=${req.body.conversation_uuid}`);
  res.json([talkAction(GREETING), listenAction()]);
});

app.get('/webhooks/answer', (req, res) => {
  log('ANSWER', `from=${req.query.from} to=${req.query.to} conv=${req.query.conversation_uuid}`);
  res.json([talkAction(GREETING), listenAction()]);
});

app.post('/webhooks/speech', async (req, res) => {
  const body = req.body;
  const convId = body.conversation_uuid;
  const speechResults = body.speech?.results;
  const timeoutReason = body.speech?.timeout_reason;

  log('SPEECH-IN', `conv=${convId} timeout=${timeoutReason || 'none'} results=${speechResults?.length || 0}`);

  if (speechResults?.length) {
    speechResults.forEach((r, i) => {
      log('SPEECH-RESULT', `#${i} confidence=${r.confidence} text="${r.text}"`);
    });
  }

  if (!speechResults || speechResults.length === 0 || timeoutReason === 'start_timeout') {
    return res.json([listenAction()]);
  }

  const transcript = speechResults[0]?.text || '';
  if (!transcript) {
    return res.json([talkAction("Sorry, I didn't catch that. Could you say it again?"), listenAction()]);
  }

  log('TRANSCRIPT', `conv=${convId} "${transcript}"`);

  const goodbyePhrases = ['goodbye', 'bye', 'see you', 'hang up', 'end call', "that's all"];
  const isGoodbye = goodbyePhrases.some((p) => transcript.toLowerCase().includes(p));

  try {
    const reply = await askClaw(convId, transcript);

    if (isGoodbye) {
      log('GOODBYE', `conv=${convId}`);
      conversations.delete(convId);
      return res.json([talkAction(reply)]);
    }

    log('RESPONSE-OUT', `conv=${convId}`);
    return res.json([talkAction(reply), listenAction()]);
  } catch (err) {
    log('ERROR', `conv=${convId} ${err.message}`);
    return res.json([talkAction("Sorry, something went wrong. Let me try again."), listenAction()]);
  }
});

app.post('/webhooks/event', (req, res) => {
  const { status, conversation_uuid, direction, from, to } = req.body || {};
  log('EVENT', `status=${status} conv=${conversation_uuid} dir=${direction} from=${from} to=${to}`);
  if (['completed', 'failed', 'rejected', 'busy', 'cancelled'].includes(status)) {
    conversations.delete(conversation_uuid);
  }
  res.status(200).end();
});

app.get('/health', (req, res) => {
  res.json({ status: 'ok', conversations: conversations.size });
});

// ── Start ───────────────────────────────────────────────────────────────
app.listen(PORT, '0.0.0.0', () => {
  log('START', `Listening on port ${PORT}`);
  log('START', `Public URL: ${PUBLIC_URL}`);
  log('START', `Answer: ${PUBLIC_URL}/webhooks/answer`);
  log('START', `Event: ${PUBLIC_URL}/webhooks/event`);
});
SERVER_EOF

# ── Install dependencies ─────────────────────────────────────────────────
cd "$TARGET" && npm install

echo ""
echo "✅ Vonage Voice server created at $TARGET"
echo ""
echo "Next steps:"
echo "  1. Edit $TARGET/.env with your credentials"
echo "  2. Place your Vonage private key at $TARGET/private.key"
echo "  3. Set Vonage webhook URLs to your PUBLIC_URL"
echo "  4. Run: cd $TARGET && node server.js"
