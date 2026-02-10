---
name: vonage-voice
description: >
  Set up phone-based voice conversations with the agent via Vonage Voice API.
  Vonage handles the telephony, speech-to-text, and text-to-speech; the agent
  responds via OpenClaw's chat completions endpoint. Use when the user wants to
  talk to the agent by phone, set up a voice number, configure Vonage Voice
  webhooks, or troubleshoot voice call issues.
---

# Vonage Voice

Phone-based conversational interface using Vonage Voice API.

## Architecture

```
Phone call → Vonage → Express webhook server
                       ├── /webhooks/answer  → greeting + listen for speech
                       ├── /webhooks/speech  → transcript → OpenClaw → TTS reply → listen again
                       └── /webhooks/event   → call lifecycle tracking
```

Vonage handles STT and TTS. The webhook server bridges Vonage to OpenClaw's
`/v1/chat/completions` HTTP endpoint.

## Setup Steps

### 1. Vonage Account & Application

1. Create a [Vonage account](https://dashboard.vonage.com)
2. Create a Vonage Application with Voice capability
3. Rent a Voice-enabled number and link it to the application
4. Note: Application ID, private key, and phone number

### 2. OpenClaw Gateway

Enable the chat completions endpoint:

```bash
openclaw config set gateway.http.endpoints.chatCompletions.enabled true
```

Or patch the config:

```json
{ "gateway": { "http": { "endpoints": { "chatCompletions": { "enabled": true } } } } }
```

### 3. Deploy the Server

Run the setup script:

```bash
scripts/setup.sh ~/code/vonage-voice
```

This creates the project directory with `server.js`, `package.json`, and `.env`.

Then configure `.env`:

```
VONAGE_APP_ID=<your application id>
VONAGE_NUMBER=<your vonage number>
PUBLIC_URL=http://<your-public-ip>:3000
PORT=3000
OPENCLAW_GATEWAY_URL=http://127.0.0.1:18789
OPENCLAW_GATEWAY_TOKEN=<your gateway token>
```

Place your Vonage private key at `private.key` in the project directory.

### 4. Configure Vonage Webhooks

In the Vonage Dashboard, set your application's webhook URLs:

- **Answer URL:** `<PUBLIC_URL>/webhooks/answer` (POST)
- **Event URL:** `<PUBLIC_URL>/webhooks/event` (POST)

### 5. Firewall

Open the server port:

```bash
sudo ufw allow 3000/tcp
```

### 6. Start

```bash
cd ~/code/vonage-voice && node server.js
```

Health check: `curl http://localhost:3000/health`

## Tuning Speech Recognition

Edit `listenAction()` in `server.js`:

- `endOnSilence` (default 2s): Seconds of silence before ending capture. Lower = faster but may cut off pauses.
- `startTimeout` (default 20s): How long to wait for speech to begin before timing out.
- `maxDuration` (default 60s): Maximum seconds of speech per turn.
- `language`: BCP-47 code, default `en-GB`. Change to match caller's language.

## Troubleshooting

- **No webhook hits**: Check firewall, verify Vonage webhook URLs match your public IP and port
- **Call connects but no greeting**: Vonage may use GET for answer URL — the server handles both
- **Speech not recognised**: Check logs for timeout reasons; adjust `endOnSilence`/`startTimeout`
- **OpenClaw errors**: Verify gateway token and that `chatCompletions` endpoint is enabled
- **Port 80 needed**: Use a reverse proxy, or `sudo setcap cap_net_bind_service=+ep $(which node)`

## Logs

Server logs to stdout and `voice.log` with tagged entries:

| Tag | Meaning |
|-----|---------|
| `ANSWER` | Inbound call received |
| `SPEECH-IN` | Raw speech event from Vonage |
| `SPEECH-RESULT` | Transcript candidate with confidence |
| `TRANSCRIPT` | Final chosen transcript |
| `CLAW-REQ` | Request sent to OpenClaw |
| `CLAW-REPLY` | Response from OpenClaw (with latency) |
| `EVENT` | Call lifecycle event |

## References

- See [references/vonage-ncco.md](references/vonage-ncco.md) for NCCO action reference
