# REVIA — Feature Backlog

Features evaluated during MVP brainstorm (2026-04-14) and deferred to post-MVP iterations. Ordered by estimated impact vs effort. Revisit after the Lou Lou pilot produces feedback.

## Priority 1 — Add after first paying client

| Feature | Description | Effort | Cost/month | Trigger to add |
|---|---|---|---|---|
| Competitor monitoring | Same pipeline on competitor URLs + comparative report in weekly digest | +1 day | +$3/competitor | Upsell opportunity; client asks "how am I vs neighbors?" |
| Reply via Telegram | "Publish" button in Telegram copies response text + opens 2GIS link, reducing steps to publish | +4 hours | $0 | Feedback that owner wants fewer steps between draft and publish |
| Fake review detection | AI flags suspicious reviews (no specifics, new account, bulk posting) with recommendation to report to platform | +3 hours | $0 (added to classify-review prompt) | Client reports suspected fake reviews |

## Priority 2 — Add when product matures

| Feature | Description | Effort | Cost/month | Trigger to add |
|---|---|---|---|---|
| Photo analysis | GPT-4o Vision on review photos — detect dirty dishes, food presentation issues, ambiance problems | +4 hours | +$0.50 | Sales demos need wow-factor; client niche is visual (restaurants, hotels) |
| Smart silence mode | Mute notifications during configurable hours (e.g. busy service 12:00–14:00), queue and deliver later | +2 hours | $0 | Client complains about notifications during rush hours |
| Foreign guest translation | Auto-translate Booking/Google reviews (EN→RU) for owner + generate reply in original language | +2 hours | +$0.10 | When Booking or Google Maps sources are connected |
| Monthly PDF report | Beautiful PDF for management with trends, benchmarks, recommendations | +1 day | $0 | Premium tier clients with budget; need to justify 80K KZT/month |

## Priority 3 — Scale features

| Feature | Description | Effort | Cost/month | Trigger to add |
|---|---|---|---|---|
| Web dashboard | Simple web UI showing review history, analytics, response management | +2 weeks | hosting cost | 10+ clients; Telegram alone becomes limiting |
| Client self-service onboarding | Owner submits 2GIS URL via web form, system auto-provisions | +1 week | $0 | 20+ clients; manual onboarding becomes bottleneck |
| Multi-language admin | Category names, digest templates, UI in Russian + Kazakh + English | +3 days | $0 | Expansion beyond KZ or kazakh-speaking clients |
| Custom notification rules | Client sets own rules: "alert me only on 1-star", "ignore reviews without text" | +2 days | $0 | Clients request personalization |
| API for integrations | REST API so clients can pull review data into their own CRM/BI | +1 week | $0 | Enterprise clients with existing systems |

## Evaluated and rejected for now

| Feature | Why rejected |
|---|---|
| Self-hosted LLM (Llama/Mistral) | GPU server $200–500/month, worse quality than GPT-4o API. Only viable when API costs exceed $2000/month |
| Per-client n8n instance | Massive maintenance overhead, doesn't scale. One shared instance is correct until 100+ clients |
| Real-time websocket dashboard | Overkill for 3–5 reviews/day. Telegram push is sufficient |
| Automated reply publishing | Too risky — AI publishing directly to 2GIS without human review. Keep human-in-the-loop |
