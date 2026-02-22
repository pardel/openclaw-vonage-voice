# OBSOLETE Vonage Voice Skill

## It has been merged into [https://github.com/pardel/vonage-unofficial-skill](https://github.com/pardel/vonage-unofficial-skill)

Phone-based voice conversations with your agent via the Vonage Voice API. Vonage handles telephony, STT, and TTS; the agent responds through OpenClaw's chat completions endpoint.

```
Phone call → Vonage → Express webhook server → OpenClaw gateway → Agent
```

## Setup

See [SKILL.md](SKILL.md) for full setup instructions, configuration, tuning, and troubleshooting.

## Files

| File | Purpose |
|------|---------|
| `SKILL.md` | Detailed setup, configuration, and troubleshooting guide |
| `scripts/setup.sh` | Scaffolds the webhook server project |
| `references/vonage-ncco.md` | Vonage NCCO action reference |
