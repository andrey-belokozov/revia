# REVIA — Decision Log

Every locked-in design decision from the brainstorming phase, with rationale. This is the canonical "why" document — when in doubt about a technical choice, check here before re-asking.

---

## MVP Scope

**Decision:** Option A — single pilot client, 1–2 weeks, minimal feature set
**Why:** Founder has no business experience yet. The fastest path to learning is a real client, not a polished product. Features can be added after we know what sells.

**Decision:** Pilot client is Lou Lou restaurant, Astana
**Why:** Concrete client with ~900 reviews on 2GIS. Restaurants are ideal first niche: high review volume, emotional reviews, clear categories, and reputation directly impacts revenue.

---

## Naming & Brand

**Decision:** Product name is REVIA (domain revia.kz)
**Why:** Short, brandable, region-agnostic. No tie to KZ so the product can grow internationally.

**Decision:** Database name `revia_reviews_hub`
**Why:** Convention `<brand>_<purpose>`. Brand-prefixed to distinguish from personal/experimental/client DBs on the same server.

**Decision:** Timezone stored as `Etc/GMT-5`, not `Asia/Almaty`
**Why:** Kazakhstan moved to UTC+5 permanently in 2024. `Asia/Almaty` returns UTC+6 on older tzdata versions. `Etc/GMT-5` is a fixed POSIX offset — always UTC+5, no dependency on tzdata version on the server.

**Decision:** Project folder `c:\CursorDev\revia\`
**Why:** Convention `<brand>` for commercial products. Clean and scalable when second product arrives.

**Decision:** n8n workflow prefix `revia_` (single underscore)
**Why:** Provisional for MVP. Will be aligned to formal N8N Governance document after first paying customer. Separates REVIA workflows from other automations on the shared n8n instance.

---

## Scraper

**Decision:** Apify actor `zen-studio/2gis-reviews-scraper` by Zen Studio
**Why:** Covers 2GIS + Flamp + Booking in one actor. Supports server-side date filter for incremental scraping. Pay-per-event pricing: $0.007/start + $0.001/review. Estimated ~$3/month for pilot.

**Decision:** Polling cadence every 2 hours
**Why:** Restaurant gets 3–5 reviews/day. 2-hour latency is acceptable for reputation monitoring (not emergency services). Balances cost ($2.64/month) vs responsiveness.

**Decision:** Retry strategy for Apify: 3 attempts with exponential backoff (30s → 2min → 10min)
**Why:** Apify actor has ~5% failure rate observed from public stats. Retries recover most transient failures.

---

## AI Models

**Decision:** Hybrid approach — Claude Haiku 4.5 for classification, GPT-4o for response generation
**Why:** Classification is a simple, high-volume task — cheap fast model is ideal. Response generation requires natural-sounding Russian text in the brand's voice — quality matters more than cost here. At pilot scale both cost pennies.

**Decision:** Voice extraction from existing business replies
**Why:** Founder's insight during brainstorm. If the business already has ≥15 historical replies, we analyze them to learn the brand's tone, structure, characteristic phrases, and then generate new replies that sound like the owner. Threshold: 15 replies minimum. Uses stratified sampling (40% negative / 40% positive / 20% neutral) of the most recent replies.

**Decision:** AI self-check warnings in response generation
**Why:** AI might promise compensation, name staff, or make external commitments on behalf of the business. `warnings` field in the response flags these risks. Owner sees a ⚠️ in Telegram before publishing. Cost: ~$0.06/month in extra tokens. Value: prevents embarrassing incidents.

**Decision:** Prompts stored in `prompts/registry.json` in repo, versioned as v1/v2/etc.
**Why:** On MVP, founder is the only one editing prompts. Git history provides versioning, code review, and rollback. DB-driven prompts with UI is a v2 feature.

---

## Database

**Decision:** Azure PostgreSQL PaaS, schema `app`, 10 tables + 1 dead-letter table
**Why:** Managed Postgres eliminates maintenance burden. Schema `app` isolates from `public`. Tables: clients, client_sources, client_profiles, reviews, review_analyses, review_responses, voice_examples, notifications_log, poll_runs, failed_operations.

**Decision:** Store `raw_payload` JSONB on every review
**Why:** Enables debugging and re-processing. ~3KB per review, ~3MB for 900 reviews. Negligible at pilot scale. Will add TTL cleanup (>90 days) when scaling past 50 clients.

**Decision:** One analysis per review (UNIQUE constraint on review_id in review_analyses)
**Why:** No A/B testing of prompts on MVP. Prevents duplicate analyses from retry bugs. Removing the UNIQUE is a one-line migration when needed.

**Decision:** Categories as `text[]` array, not normalized table
**Why:** 16 categories for restaurants, AI selects from the list in client_profiles. Validation via prompt instruction + code check. Normalization adds JOIN overhead for zero MVP benefit.

**Decision:** `niche_template` as text, not enum
**Why:** New niches added by INSERT, not by ALTER TYPE migration. Flexibility over strictness at this stage.

**Decision:** Hard-delete with CASCADE, not soft-delete
**Why:** `status` field handles pauses. Hard DELETE only for "erase all data" requests. Simpler queries (no `WHERE deleted_at IS NULL` everywhere). Azure PaaS has point-in-time recovery as safety net.

---

## n8n Workflow Architecture

**Decision:** Approach 2 — micro-workflows with sub-workflow calls
**Why:** Founder has n8n experience and prefers idiomatic sub-workflow patterns. Each workflow has one job, orchestrators chain them. Enables reuse (e.g. analyze-review used by both poll and backfill).

**Decision:** Single global cron (not per-client cron)
**Why:** On MVP with 1 client, per-client cron is pure overhead. Global cron scales to ~50 clients with Split In Batches parallelization. Different SLA tiers (per-client cadence) are a v2 feature.

**Decision:** Sub-workflows don't know about each other — only orchestrators chain them
**Why:** Enables reuse without side effects. `analyze-review` can be called from backfill (no notifications) or from poll (with notifications) without internal branching.

**Decision:** All sub-workflows are idempotent
**Why:** Safe retries. INSERT ON CONFLICT, check-before-create patterns. Critical for error recovery and backfill restarts.

---

## Telegram UX

**Decision:** Single multi-tenant bot, owner binds via /start
**Why:** +30 min setup vs per-client bot, but eliminates full rebuild when second client arrives.

**Decision:** Real-time alerts for negative/urgent reviews only; positive reviews go to daily digest
**Why:** Respects owner's attention. 3–5 reviews/day means 1–2 alerts max. Digest at 09:00 and 21:00 covers the rest.

**Decision:** Bot name is TBD, stored as environment variable
**Why:** Founder hasn't decided yet. Must not be hardcoded anywhere.

---

## Backfill & Onboarding

**Decision:** Full backfill of all ~900 historical reviews + AI classification on day 1
**Why:** $2.50 one-time cost. Produces the initial insights report — the strongest sales moment. Without it, day 1 is an empty dashboard.

**Decision:** Backfill does NOT generate responses or send notifications for historical reviews
**Why:** Generating 900 responses wastes money on unpublishable drafts. Sending 900 notifications would spam the owner and kill trust. Exception: the 5 most recent unanswered negatives DO get responses — they're still fresh and publishable.

**Decision:** Voice extraction happens during backfill, before initial report
**Why:** The initial report's sample responses should already use the learned voice. Order: scrape → analyze → extract-voice → initial-report.

**Decision:** Initial report uses SQL aggregates as input to AI, not raw reviews
**Why:** 900 reviews = too many tokens + incoherent output. SQL does the heavy lifting (counts, averages, top categories), AI just writes human-readable text from structured data.

---

## Error Handling

**Decision:** Dead letter table `failed_operations` + hourly retry workflow `revia_retry-failed-operations`
**Why:** No data loss. Failed operations are saved with full input payload and auto-retried up to 5 times. After that, marked abandoned + developer alert.

**Decision:** Developer alerts via separate Telegram chat, not Sentry/Grafana
**Why:** MVP doesn't need observability infra. Telegram is already wired up. Alerts cover: Apify failures, AI invalid JSON, blocked bots, unresolved failed_operations.

---

## Restaurant Categories (Lou Lou profile)

**Decision:** 16 categories for restaurant niche
**Why:** Granular enough for actionable analytics ("32% of complaints are specifically about wait_time") without being overwhelming. Categories: food_quality, food_taste, menu_variety, portion_size, service_speed, service_attitude, staff_specific, atmosphere, noise_level, cleanliness, price_value, wait_time, reservation_booking, alcohol_drinks, parking, payment_methods.
