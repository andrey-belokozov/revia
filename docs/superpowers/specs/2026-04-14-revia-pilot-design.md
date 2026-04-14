# REVIA MVP Pilot — Design Specification

**Date:** 2026-04-14
**Status:** Approved through brainstorming
**Pilot client:** Lou Lou restaurant, Astana
**MVP horizon:** 1–2 weeks to working version

---

## 1. Product Summary

REVIA monitors online reviews for local businesses, analyzes them with AI, generates draft replies in the brand's own voice, and delivers real-time alerts and daily digests via Telegram.

The MVP serves a single pilot client (Lou Lou restaurant, Astana) to validate the product's value before scaling. All architectural decisions optimize for "working pilot in 1–2 weeks", not hypothetical scale.

---

## 2. High-Level Architecture

### Components

```
┌─────────────────────────────────────────────────────────────────┐
│                   External Services                              │
│  ┌──────────┐  ┌─────────────┐  ┌──────────┐  ┌──────────────┐  │
│  │  Apify   │  │  Anthropic  │  │  OpenAI  │  │  Telegram    │  │
│  │ (scraper)│  │   (Haiku)   │  │ (GPT-4o) │  │  Bot API     │  │
│  └────┬─────┘  └──────┬──────┘  └────┬─────┘  └──────┬───────┘  │
└───────┼───────────────┼──────────────┼───────────────┼──────────┘
        │               │              │               │
        ▼               ▼              ▼               ▼
┌─────────────────────────────────────────────────────────────────┐
│                  n8n (Azure Ubuntu VM)                           │
│                                                                  │
│   12 workflows with prefix revia_                                │
│   Micro-workflow architecture (Approach 2)                       │
│   Orchestrators chain sub-workflows via Execute Workflow         │
└──────────────────────────────┬──────────────────────────────────┘
                               │
                               ▼
┌─────────────────────────────────────────────────────────────────┐
│         Azure PostgreSQL PaaS — DB: revia_reviews_hub            │
│         Schema: app — 10 tables                                  │
└─────────────────────────────────────────────────────────────────┘
```

### Data Flow (happy path)

1. **Schedule every 2h** → `revia_poll-reviews` fires
2. Reads active clients from `app.clients`
3. For each client → `revia_scrape-client` calls Apify with `dateFrom` filter → new reviews saved to `app.reviews`
4. For each new review → `revia_analyze-review` calls Haiku → classification saved to `app.review_analyses`
5. If sentiment ∈ {negative, aggressive} or urgency ∈ {high, critical} → `revia_generate-response` calls GPT-4o → draft saved to `app.review_responses`
6. `revia_send-notification` formats and sends Telegram alert with draft reply
7. Pattern detection: SQL check for 3+ reviews with same category in 48h → cluster alert if found
8. Daily digests at 09:00 and 21:00 aggregate stats and send summary

### Onboarding Flow (one-time per client)

1. Manual → `revia_backfill-client` triggers
2. `revia_scrape-client` (mode=backfill) pulls all historical reviews
3. `revia_analyze-review` classifies each review
4. `revia_extract-voice` learns brand voice from existing business replies (if ≥15 replies)
5. `revia_initial-report` generates and sends insights summary + 5 top unanswered negatives with draft replies

---

## 3. Workflow Inventory (12 workflows)

### Hot Path (every 2 hours)

| # | Workflow | Role | Input | Output |
|---|---|---|---|---|
| 1 | `revia_poll-reviews` | Orchestrator | Schedule trigger | Poll results logged to `poll_runs` |
| 2 | `revia_scrape-client` | Sub-workflow | `{client_id, mode}` | `{client_id, new_review_ids[], total_scraped}` |
| 3 | `revia_analyze-review` | Sub-workflow | `{review_id}` | `{review_id, sentiment, urgency, category}` |
| 4 | `revia_generate-response` | Sub-workflow | `{review_id}` | `{review_id, response_text}` |
| 5 | `revia_send-notification` | Sub-workflow | `{review_id, include_response}` | `{notification_id, sent_at}` |

### Scheduled

| # | Workflow | Trigger | Purpose |
|---|---|---|---|
| 6 | `revia_daily-digest` | Cron 09:00, 21:00 Asia/Almaty | Morning/evening summary + trend alerts + weekly marketing highlights |
| 11 | `revia_retry-failed-operations` | Cron every 1h | Auto-retry dead-lettered operations |

### Manual / Onboarding

| # | Workflow | Trigger | Purpose |
|---|---|---|---|
| 7 | `revia_backfill-client` | Manual | Full historical import + voice extraction + initial report |
| 9 | `revia_extract-voice` | Execute Workflow | Learn brand voice from existing replies |
| 10 | `revia_initial-report` | Execute Workflow | Generate and send onboarding insights message |

### Webhook

| # | Workflow | Trigger | Purpose |
|---|---|---|---|
| 8 | `revia_telegram-router` | Telegram webhook | Handle /start, /help, /status commands |

### Infrastructure

| # | Workflow | Trigger | Purpose |
|---|---|---|---|
| 12 | `revia_alert-developer` | Execute Workflow | Send technical alerts to developer's private Telegram chat |

### Architecture Rules

1. All sub-workflows accept and return JSON — no global state
2. Sub-workflows don't know about each other — only orchestrators chain them
3. All sub-workflows are idempotent (INSERT ON CONFLICT, check-before-create)
4. Every sub-workflow logs its execution for observability

---

## 4. Database Schema

**Database:** `revia_reviews_hub` on Azure PostgreSQL PaaS
**Schema:** `app`

### Enum Types

```sql
CREATE TYPE app.client_status       AS ENUM ('active', 'paused', 'archived');
CREATE TYPE app.platform            AS ENUM ('2gis', 'flamp', 'booking');
CREATE TYPE app.source_status       AS ENUM ('active', 'error', 'paused');
CREATE TYPE app.sentiment           AS ENUM ('ecstatic', 'positive', 'neutral', 'negative', 'aggressive');
CREATE TYPE app.urgency             AS ENUM ('low', 'medium', 'high', 'critical');
CREATE TYPE app.response_status     AS ENUM ('draft', 'sent_to_owner', 'approved', 'published', 'dismissed');
CREATE TYPE app.voice_source        AS ENUM ('extracted', 'default_template', 'manual');
CREATE TYPE app.notification_type   AS ENUM ('alert_negative', 'alert_urgent', 'alert_pattern', 'digest_morning', 'digest_evening', 'digest_weekly', 'initial_report', 'voice_extracted', 'trend_alert', 'system');
CREATE TYPE app.notification_status AS ENUM ('sent', 'failed');
CREATE TYPE app.poll_trigger        AS ENUM ('schedule', 'manual', 'retry', 'backfill');
CREATE TYPE app.poll_status         AS ENUM ('running', 'success', 'partial_success', 'failed');
```

### Tables

**`app.clients`**

```sql
CREATE TABLE app.clients (
  id                  bigserial PRIMARY KEY,
  slug                text NOT NULL UNIQUE,
  display_name        text NOT NULL,
  niche               text NOT NULL,
  city                text NOT NULL,
  timezone            text NOT NULL DEFAULT 'Asia/Almaty',
  status              app.client_status NOT NULL DEFAULT 'active',
  telegram_chat_id    bigint,
  telegram_bound_at   timestamptz,
  initial_report_sent_at timestamptz,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now()
);
```

**`app.client_sources`**

```sql
CREATE TABLE app.client_sources (
  id                  bigserial PRIMARY KEY,
  client_id           bigint NOT NULL REFERENCES app.clients(id) ON DELETE CASCADE,
  platform            app.platform NOT NULL,
  source_url          text NOT NULL,
  external_place_id   text,
  last_review_date    timestamptz,
  last_scraped_at     timestamptz,
  status              app.source_status NOT NULL DEFAULT 'active',
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now(),
  UNIQUE (client_id, platform)
);
```

**`app.client_profiles`**

```sql
CREATE TABLE app.client_profiles (
  client_id           bigint PRIMARY KEY REFERENCES app.clients(id) ON DELETE CASCADE,
  niche_template      text NOT NULL,
  categories          text[] NOT NULL,
  response_language   text NOT NULL DEFAULT 'auto',
  tone_config         jsonb NOT NULL DEFAULT '{}'::jsonb,
  voice_description   jsonb,
  voice_sample_size   int,
  voice_extracted_at  timestamptz,
  updated_at          timestamptz NOT NULL DEFAULT now()
);
```

**`app.reviews`**

```sql
CREATE TABLE app.reviews (
  id                  bigserial PRIMARY KEY,
  client_id           bigint NOT NULL REFERENCES app.clients(id) ON DELETE CASCADE,
  source_id           bigint NOT NULL REFERENCES app.client_sources(id) ON DELETE CASCADE,
  platform            app.platform NOT NULL,
  external_review_id  text NOT NULL,
  author_name         text,
  author_external_id  text,
  rating              smallint,
  review_text         text,
  review_lang         text,
  photo_urls          text[],
  review_created_at   timestamptz NOT NULL,
  review_edited_at    timestamptz,
  business_reply_text text,
  business_reply_at   timestamptz,
  raw_payload         jsonb NOT NULL,
  ingested_at         timestamptz NOT NULL DEFAULT now(),
  UNIQUE (client_id, platform, external_review_id)
);

CREATE INDEX reviews_client_date_idx ON app.reviews (client_id, review_created_at DESC);
CREATE INDEX reviews_client_has_reply_idx ON app.reviews (client_id) WHERE business_reply_text IS NOT NULL;
```

**`app.review_analyses`**

```sql
CREATE TABLE app.review_analyses (
  id                  bigserial PRIMARY KEY,
  review_id           bigint NOT NULL UNIQUE REFERENCES app.reviews(id) ON DELETE CASCADE,
  sentiment           app.sentiment NOT NULL,
  urgency             app.urgency NOT NULL,
  categories          text[] NOT NULL,
  detected_language   text NOT NULL,
  summary             text,
  pii_detected        boolean NOT NULL DEFAULT false,
  confidence          real,
  model               text NOT NULL,
  prompt_version      text NOT NULL,
  analyzed_at         timestamptz NOT NULL DEFAULT now(),
  raw_response        jsonb
);

CREATE INDEX review_analyses_sentiment_idx ON app.review_analyses (sentiment, urgency);
```

**`app.review_responses`**

```sql
CREATE TABLE app.review_responses (
  id                  bigserial PRIMARY KEY,
  review_id           bigint NOT NULL REFERENCES app.reviews(id) ON DELETE CASCADE,
  response_text       text NOT NULL,
  model               text NOT NULL,
  prompt_version      text NOT NULL,
  voice_source        app.voice_source NOT NULL,
  status              app.response_status NOT NULL DEFAULT 'draft',
  warnings            text[],
  sent_to_owner_at    timestamptz,
  generated_at        timestamptz NOT NULL DEFAULT now(),
  raw_response        jsonb
);
```

**`app.voice_examples`**

```sql
CREATE TABLE app.voice_examples (
  id                  bigserial PRIMARY KEY,
  client_id           bigint NOT NULL REFERENCES app.clients(id) ON DELETE CASCADE,
  review_id           bigint REFERENCES app.reviews(id) ON DELETE SET NULL,
  review_text         text NOT NULL,
  review_sentiment    app.sentiment NOT NULL,
  response_text       text NOT NULL,
  selected_for_few_shot boolean NOT NULL DEFAULT false,
  created_at          timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX voice_examples_client_selected_idx
  ON app.voice_examples (client_id, selected_for_few_shot) WHERE selected_for_few_shot = true;
```

**`app.notifications_log`**

```sql
CREATE TABLE app.notifications_log (
  id                  bigserial PRIMARY KEY,
  client_id           bigint NOT NULL REFERENCES app.clients(id) ON DELETE CASCADE,
  review_id           bigint REFERENCES app.reviews(id) ON DELETE SET NULL,
  notification_type   app.notification_type NOT NULL,
  telegram_chat_id    bigint NOT NULL,
  telegram_message_id bigint,
  payload             text NOT NULL,
  status              app.notification_status NOT NULL,
  error_text          text,
  sent_at             timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX notifications_log_client_sent_idx ON app.notifications_log (client_id, sent_at DESC);
```

**`app.poll_runs`**

```sql
CREATE TABLE app.poll_runs (
  id                  bigserial PRIMARY KEY,
  run_id              uuid NOT NULL,
  client_id           bigint NOT NULL REFERENCES app.clients(id) ON DELETE CASCADE,
  triggered_by        app.poll_trigger NOT NULL,
  started_at          timestamptz NOT NULL DEFAULT now(),
  finished_at         timestamptz,
  status              app.poll_status NOT NULL DEFAULT 'running',
  new_reviews_count   int NOT NULL DEFAULT 0,
  error_text          text,
  metadata            jsonb NOT NULL DEFAULT '{}'::jsonb
);

CREATE INDEX poll_runs_client_started_idx ON app.poll_runs (client_id, started_at DESC);
CREATE INDEX poll_runs_status_idx ON app.poll_runs (status) WHERE status IN ('running', 'failed');
```

**`app.failed_operations`**

```sql
CREATE TABLE app.failed_operations (
  id              bigserial PRIMARY KEY,
  workflow_name   text NOT NULL,
  client_id       bigint REFERENCES app.clients(id) ON DELETE CASCADE,
  entity_type     text NOT NULL,
  entity_id       bigint,
  input_payload   jsonb NOT NULL,
  error_text      text NOT NULL,
  error_category  text,
  attempts        int NOT NULL,
  first_failed_at timestamptz NOT NULL DEFAULT now(),
  last_failed_at  timestamptz NOT NULL DEFAULT now(),
  resolved_at     timestamptz,
  resolved_by     text
);

CREATE INDEX failed_operations_unresolved_idx
  ON app.failed_operations (workflow_name, first_failed_at) WHERE resolved_at IS NULL;
```

---

## 5. AI Prompts Strategy

### Overview

| Prompt | Model | Temperature | Max tokens | Output |
|---|---|---|---|---|
| `classify-review` | Claude Haiku 4.5 | 0.0 | 500 | Structured JSON (sentiment, urgency, categories, summary, PII flag, confidence) |
| `extract-voice` | Claude Haiku 4.5 | 0.3 | 1500 | Structured JSON (tone, structure, phrases, restrictions) |
| `generate-response` | GPT-4o | 0.7 | 600 | JSON with response_text + warnings |
| `initial-report` | GPT-4o | 0.6 | 1500 | Plain text Telegram message |

### Prompt 1: classify-review

Input variables: `client_niche`, `client_categories[]`, `review_text`, `review_rating`, `review_author`, `review_lang_hint`

Output schema:
```json
{
  "sentiment": "negative",
  "urgency": "medium",
  "categories": ["service_speed", "food_quality"],
  "detected_language": "ru",
  "summary": "...",
  "pii_detected": false,
  "confidence": 0.92
}
```

Rules:
- Categories MUST come from the provided `client_categories` list only
- Confidence below 0.7 → review marked as "uncertain", skips response generation, goes to digest
- Sentiment scale: ecstatic > positive > neutral > negative > aggressive
- Urgency is independent of sentiment (negative + low urgency ≠ aggressive + critical urgency)

### Prompt 2: extract-voice

Input: 20–30 stratified sample replies (40% from negative reviews, 40% positive, 20% neutral, ordered by recency within each stratum)

Output schema:
```json
{
  "tone": "...",
  "formality_level": "informal_polite",
  "avg_length_chars": 280,
  "address_style": "first_name_polite_you",
  "structure_negative": ["acknowledgment", "specific_apology", "concrete_action", "reinvitation"],
  "structure_positive": ["thanks", "specific_callback", "team_recognition", "reinvitation"],
  "signature": "С уважением, команда Lou Lou",
  "characteristic_phrases": ["..."],
  "do_not_use": ["..."],
  "languages_observed": ["ru"],
  "uses_emojis": false,
  "addresses_by_first_name": true
}
```

Threshold: ≥ 15 business replies required. Below threshold → voice extraction skipped, fallback to `tone_config`.

Stratified sampling SQL:
```sql
WITH pools AS (
  SELECT r.id, r.review_text, r.business_reply_text, r.business_reply_at,
         ra.sentiment,
         CASE WHEN ra.sentiment IN ('negative','aggressive') THEN 'A'
              WHEN ra.sentiment IN ('positive','ecstatic') THEN 'B'
              ELSE 'C' END AS pool
  FROM app.reviews r
  JOIN app.review_analyses ra ON ra.review_id = r.id
  WHERE r.client_id = $1 AND r.business_reply_text IS NOT NULL
),
ranked AS (
  SELECT *, row_number() OVER (PARTITION BY pool ORDER BY business_reply_at DESC) AS rn
  FROM pools
)
SELECT * FROM ranked
WHERE (pool = 'A' AND rn <= 12) OR (pool = 'B' AND rn <= 12) OR (pool = 'C' AND rn <= 6);
```

### Prompt 3: generate-response

Input: `client_name`, `voice_description` (or `fallback_tone_config`), `few_shot_examples[5]`, review data + analysis

Output:
```json
{
  "response_text": "...",
  "response_language": "ru",
  "estimated_quality": "high",
  "warnings": []
}
```

Warning types: `compensation_promised`, `staff_named`, `external_promise`, `pii_in_response`, `legal_risk`, `tone_mismatch`

Rules:
- Never offer compensation without explicit permission in `tone_config.compensation_policy`
- Response language matches review language
- Target length from `voice_description.avg_length_chars` or 200–300 chars default
- Voice source (extracted vs default_template) recorded in `review_responses.voice_source`

### Prompt 4: initial-report

Input: SQL-aggregated stats (NOT raw reviews) — total count, avg rating, trend, sentiment distribution, top complaint/praise categories with sample quotes, unanswered negatives count, voice extraction status

Output: plain text Telegram message, max ~1500 chars. Voice is REVIA (the product), not the client's brand. Facts, not judgments.

### Prompt Storage

All prompts stored in `prompts/registry.json` in the repository. Each AI call writes its `prompt_version` to the relevant DB table. Current versions managed as constants in the workflow.

---

## 6. Error Handling & Retries

### Retry Strategies

| Service | Retry count | Backoff | Notes |
|---|---|---|---|
| Apify | 3 | 30s → 2min → 10min | Sanity check: alert if 0 reviews returned when place has 100+ |
| Anthropic API | 3 | 5s → 15s → 45s + jitter | On invalid JSON: one retry with explicit schema instruction |
| OpenAI API | 3 | 5s → 15s → 45s + jitter | On refusal: mark as `blocked_by_safety`, notify owner to write manually |
| Telegram | 3 | 5s → 15s → 30s | On 403 (blocked): pause client. On 400 (chat not found): clear chat_id, pause |
| Postgres | 1 | Automatic reconnect | Duplicate key = not an error (INSERT ON CONFLICT) |

### Dead Letter Pattern

Failed operations after all retries → saved to `app.failed_operations` with full `input_payload`. `revia_retry-failed-operations` (hourly cron) retries up to 5 times. After 5 → `resolved_by='abandoned'` + developer alert.

### Idempotency

| Workflow | Mechanism |
|---|---|
| scrape-client | UNIQUE (client_id, platform, external_review_id) |
| analyze-review | UNIQUE (review_id) in review_analyses — check before calling AI |
| generate-response | Check existing response before calling AI |
| send-notification | Check notifications_log before sending |
| extract-voice | Check voice_extracted_at before running |
| initial-report | Check initial_report_sent_at before running |

### Developer Alerts

Separate private Telegram chat via `revia_alert-developer`. Triggers: Apify returns 0, failed_operations > 10, client blocked bot, AI invalid JSON 3+/hour, unhandled workflow exception, backfill > 1 hour, digest missed schedule.

---

## 7. MVP Bonus Features (Zero Extra API Cost)

### Pattern Detection (clusters)

SQL in `revia_poll-reviews` after processing new reviews: if 3+ reviews in last 48 hours share a category → send cluster alert instead of individual notifications.

### Marketing Asset Extraction

Weekly section in Sunday digest: top 3 reviews by rating + text length, suitable for Instagram/marketing use. Pure SQL selection.

### Trend Alerts

In evening digest: compare 7-day avg rating vs 30-day avg rating. If difference ≥ 0.3 → include trend warning with main driver category.

---

## 8. Lou Lou Configuration

### Client Record

```json
{
  "slug": "lou-lou-astana",
  "display_name": "Lou Lou",
  "niche": "restaurant",
  "city": "Астана",
  "timezone": "Asia/Almaty"
}
```

### Sources

- 2GIS: URL to be provided by founder
- Flamp: check availability, add if exists
- Booking: unlikely for KZ restaurant, skip

### Profile

Niche template: `restaurant`

16 categories: `food_quality`, `food_taste`, `menu_variety`, `portion_size`, `service_speed`, `service_attitude`, `staff_specific`, `atmosphere`, `noise_level`, `cleanliness`, `price_value`, `wait_time`, `reservation_booking`, `alcohol_drinks`, `parking`, `payment_methods`

Tone config:
```json
{
  "formality": "informal_polite",
  "address_style": "first_name_polite_you",
  "use_emojis": false,
  "max_length_chars": 350,
  "default_signature": "С уважением, команда Lou Lou",
  "compensation_policy": "never_offer_without_human_approval",
  "language_preference": "match_review_language"
}
```

---

## 9. Day-1 Runbook

### Pre-flight Checklist

1. MCP access to n8n and Postgres
2. N8N Governance document (optional, provisional naming used without it)
3. Apify account + API token → n8n credential `revia_apify`
4. Anthropic API key → n8n credential `revia_anthropic`
5. OpenAI API key → n8n credential `revia_openai`
6. Telegram bot created via @BotFather → n8n credential `revia_telegram_bot`
7. Developer Telegram chat created → env var `REVIA_DEVELOPER_CHAT_ID`
8. n8n webhook URL accessible externally
9. Lou Lou owner agreement + 2GIS page URL
10. Owner's Telegram (they will /start the bot)

### Launch Steps

| Step | Action | Time |
|---|---|---|
| 1 | Apply DB migration (schema `app`, all tables and types) | 5 min |
| 2 | Import 12 workflows into n8n (all inactive) | 10 min |
| 3 | Load `prompts/registry.json` | 5 min |
| 4 | INSERT Lou Lou client + sources + profile | 5 min |
| 5 | Dry run: scrape 5 reviews | 10 min |
| 6 | Dry run: analyze 5 reviews | 10 min |
| 7 | Activate `revia_telegram-router`, test /start | 5 min |
| 8 | Run `revia_backfill-client` (scrape → analyze → voice → report) | 30–60 min |
| 9 | Activate `revia_poll-reviews` (every 2h) | 5 min |
| 10 | Activate `revia_daily-digest` (09:00, 21:00) | 5 min |
| 11 | Activate `revia_retry-failed-operations` (every 1h) | 5 min |
| 12 | Contact Lou Lou owner, confirm receipt, schedule feedback | async |

**Total active time:** ~2.5 hours + 30–60 min backfill wait

### Success Criteria

**After 5 days:**
- ≥ 1 real-time notification delivered with reasonable draft reply
- ≥ 5 daily digests delivered
- ≥ 1 response published by owner (even heavily edited)
- Failed operations < 5%
- Apify cost < $5/week
- AI cost < $5/week
- Owner expresses interest in continuing

**After 2 weeks:**
- Convert pilot to paying client OR clear product lesson from rejection

---

## 10. Cost Estimate (Monthly, One Pilot Client)

| Item | Cost |
|---|---|
| Apify (2h polling, ~120 reviews/month) | ~$3 |
| Anthropic Haiku (classification, ~120 calls) | ~$0.10 |
| OpenAI GPT-4o (responses, ~30 calls) | ~$0.50 |
| Azure VM (shared, existing) | $0 marginal |
| Azure Postgres (shared, existing) | $0 marginal |
| **Total marginal cost per client** | **~$3.60/month** |
| **Client pays** | **30,000–80,000 KZT/month** |
| **Margin** | **~95%** |

One-time backfill cost: ~$2.50

---

## 11. Implementation Process Rules

### n8n Skills

When building any n8n workflow, invoke the relevant n8n skills before designing or configuring nodes:
- `n8n-workflow-patterns` — for architectural patterns and webhook/API/data processing structures
- `n8n-node-configuration` — for node setup, required fields, property dependencies
- `n8n-code-javascript` — for Code node JavaScript ($input, $json, $node syntax, HTTP helpers)
- `n8n-expression-syntax` — for expressions in {{ }}, $json/$node variables, webhook data
- `n8n-validation-expert` — for interpreting and fixing validation errors
- `n8n-mcp-tools-expert` — for using n8n MCP tools (create, update, validate workflows)

### Step-by-Step Execution

Implementation proceeds **one block at a time**:
1. Before each block: state what will be done, what external dependencies are needed from the user
2. User provides the required dependencies (API keys, MCP access, URLs, credentials) at the moment each block needs them — not upfront
3. Execute the block
4. After each block: state what was completed, verify it works, show the result
5. Do NOT proceed to the next block until the current one is confirmed working by the user
6. The user must always understand: what is already done, what is happening now, what comes next

This ensures the user stays in control, provides credentials just-in-time, and can catch issues early.

---

## 12. External Dependencies

| Dependency | Status | Blocker? |
|---|---|---|
| MCP access to n8n | Pending | Yes — cannot deploy workflows |
| MCP access to Postgres | Pending | Yes — cannot run migrations |
| N8N Governance document | Pending | No — provisional naming used |
| Apify account + API key | Pending | Yes — cannot scrape |
| Anthropic API key | Pending | Yes — cannot classify |
| OpenAI API key | Pending | Yes — cannot generate responses |
| Telegram bot token | Pending | Yes — cannot send notifications |
| Lou Lou 2GIS URL | Pending | Yes — cannot configure pilot |
| Lou Lou owner consent | Pending | Yes — cannot run backfill |
