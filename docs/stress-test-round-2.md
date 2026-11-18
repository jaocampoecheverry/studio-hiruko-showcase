# Stress test round 2 (16 Nov 2026): summary


## How it was run

- **Test sink.** M0 Send email skips Resend when every recipient is on the reserved `.invalid` TLD and records the message as sent (`provider_message_id = sink:…`). That let 200+ enquiries run without touching the Resend free tier (100/day). Real addresses still go through Resend (checked before and after).
- **Studio `stress-sink`** (Growth, approval mode, two-person team with routing, all addresses `.invalid`). Removed after the test.
- Claude ran for real throughout.

## Results

| Test | Result |
| --- | --- |
| Volume: 200 enquiries in 54 min (50 burst at 16 at a time, then 1 every 21 s) + 10 double submissions | 200/200 leads, 0 lost, 0 non-200 responses, 0 failed of 860 n8n executions. Every check passed (29 scripted "failures" were drafts approved mid-run through the Desk, correctly `sent`). |
| Acknowledgement after capture | Paced: median 0.55 s, p95 0.74 s. Burst: median 5.4 s, max 6.8 s (single n8n process; revisit queue mode past ~20 studios, as in round 1). |
| Claude draft after capture | Paced: median 8.7 s. Burst: median 16.2 s, max 24.1 s. |
| Guardrails under load | Prompt injection, unicode, 9k-character, HTML, spam, duplicates, phone-only, commercial-to-director, kitchen/bathroom routed to the right person: all held. |
| Desk under load | 30 approvals + 30 notes + 5 outcomes through the desk_* RPCs in 40 ms; the outbox sent all 30 within 39 s (median 36 s). |
| Cal.com webhooks | Bad/missing signature 401; unknown studio 404; duplicate delivery stored once; 20 signed webhooks in 2.3 s, 20/20 recorded. |

## Found and fixed the same evening

1. **Forwarded enquiries arriving together were mostly dropped (serious).** The mailbox hands n8n several emails per run; M1 Capture – forwarded email captured all 20 but passed only the first lead of each run to Qualify, so 18 of 20 got no acknowledgement, score or draft. Fixed: "Lead for Qualify" now passes every lead and "Run M2 Qualify" runs once per lead. Re-run: 10/10 captured, acknowledged and scored within 34 s (2 IMAP batches).
2. **Claude down left enquiries unscored for good.** The enquirer still got the acknowledgement, but the lead stayed `new` with no draft and no retry. Fixed (migration 20261116160000_retries): `due_requalify` in M3 (every 15 min) re-runs M2 Qualify for such leads up to 3 times, 10+ minutes apart, within 24 hours; after the third try the lead owner gets one "Reply to … yourself" email with the enquiry. The acknowledgement is never sent twice (qualify_start is idempotent).
3. **Resend down meant lost acknowledgements.** A failed send stayed failed. Fixed: `messages.send_failures`; the M0 Outbox (every minute) now also claims failed acknowledgements, replies, follow-ups and hand-offs, up to 3 more attempts, 10+ minutes apart, within 24 hours.

Proved live: the sweep rescued all 18 dropped forwarded leads and the 3 Claude-drill leads on its first run (acknowledged, scored, drafted); the two acknowledgements that failed in the Resend drill were re-sent by the outbox. Tests: retries 16/16; desk 27, qualify 43, nurture 45, speed_pilot 64 unchanged.

## Backlog (not fixed)

- Cal.com: a cancellation that arrives before its booking is ignored, so the later "created" leaves the booking `scheduled`. Cal.com sends in order in practice; store a tombstone if it ever happens.
- Cal.com: a booking from someone who never enquired creates a new lead (by design; confirm with the first studio).
- Failed sends from before 16 Nov have `send_failures = 0` and are never retried (intended: no surprise re-sends of old mail).
- Burst latency (5–7 s acknowledgements at 16 parallel posts) is fine for now; queue mode when volume grows.
