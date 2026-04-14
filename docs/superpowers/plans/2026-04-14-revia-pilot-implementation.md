# REVIA MVP Pilot — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deploy a working REVIA pilot for Lou Lou restaurant — scrape 2GIS reviews every 2h, classify with AI, generate draft replies, deliver alerts and digests via Telegram.

**Architecture:** Micro-workflow architecture on n8n. 12 workflows with `revia_` prefix, orchestrators chain sub-workflows via Execute Workflow. Azure PostgreSQL PaaS (`revia_reviews_hub`, schema `app`). Prompts versioned in `prompts/registry.json`.

**Tech Stack:** n8n (self-hosted Azure VM), PostgreSQL, Apify (2GIS scraper), Claude Haiku 4.5 (classification), GPT-4o (response generation), Telegram Bot API.

**Design Spec:** `docs/superpowers/specs/2026-04-14-revia-pilot-design.md`

---

## Dependency Graph

```
Block 1: Local Artifacts ──────── no external deps
  ├─ Task 1: SQL migration file
  ├─ Task 2: Prompts registry.json
  └─ Task 3: Seed data SQL (Lou Lou)

Block 2: Database Setup ────────── needs: Postgres MCP
  └─ Task 4: Run migration + seed data + verify

Block 3: Utility Workflows ─────── needs: n8n MCP + Telegram bot token + dev chat ID
  ├─ Task 5: revia_alert-developer
  └─ Task 6: revia_telegram-router

Block 4: Scraping Pipeline ─────── needs: Apify API key + Lou Lou 2GIS URL
  ├─ Task 7: revia_scrape-client
  └─ Task 8: Dry-run scrape (5 reviews)

Block 5: Analysis Pipeline ─────── needs: Anthropic API key
  ├─ Task 9: revia_analyze-review
  └─ Task 10: Dry-run analyze (5 reviews)

Block 6: Response Generation ───── needs: OpenAI API key
  └─ Task 11: revia_generate-response

Block 7: Notifications ─────────── needs: Telegram (from Block 3)
  └─ Task 12: revia_send-notification

Block 8: Hot Path Orchestrator ─── needs: Blocks 4-7 confirmed
  ├─ Task 13: revia_poll-reviews
  └─ Task 14: End-to-end dry run

Block 9: Onboarding Workflows ──── needs: Block 8 confirmed
  ├─ Task 15: revia_extract-voice
  ├─ Task 16: revia_initial-report
  └─ Task 17: revia_backfill-client

Block 10: Scheduled Workflows ──── needs: Block 8 confirmed
  ├─ Task 18: revia_daily-digest
  └─ Task 19: revia_retry-failed-operations

Block 11: Go Live ──────────────── needs: all blocks + Lou Lou owner consent
  ├─ Task 20: Run backfill for Lou Lou
  ├─ Task 21: Activate all scheduled workflows
  └─ Task 22: Verify end-to-end + contact owner
```

---

## File Structure

```
revia/
├── CLAUDE.md                                          # (exists) project instructions
├── migrations/
│   └── 001_initial_schema.sql                         # CREATE schema, types, tables, indexes
├── seed/
│   └── lou-lou.sql                                    # INSERT client, source, profile for Lou Lou
├── prompts/
│   └── registry.json                                  # All 4 AI prompts with versions
└── docs/
    ├── context/
    │   ├── PROJECT_OVERVIEW.md                         # (exists)
    │   ├── DECISIONS.md                                # (exists)
    │   └── GLOSSARY.md                                 # (exists)
    └── superpowers/
        ├── specs/
        │   └── 2026-04-14-revia-pilot-design.md        # (exists) design spec
        └── plans/
            └── 2026-04-14-revia-pilot-implementation.md # this plan
```

n8n workflows (12) are created via MCP, not stored as files in the repo.

---

## Block 1: Local Artifacts (no external dependencies)

### Task 1: SQL Migration File

**Files:**
- Create: `migrations/001_initial_schema.sql`

- [ ] **Step 1: Create the migration file**

```sql
-- migrations/001_initial_schema.sql
-- REVIA MVP — Initial schema
-- Database: revia_reviews_hub
-- Schema: app

BEGIN;

CREATE SCHEMA IF NOT EXISTS app;

-- ============================================================
-- ENUM TYPES
-- ============================================================

CREATE TYPE app.client_status       AS ENUM ('active', 'paused', 'archived');
CREATE TYPE app.platform            AS ENUM ('2gis', 'flamp', 'booking');
CREATE TYPE app.source_status       AS ENUM ('active', 'error', 'paused');
CREATE TYPE app.sentiment           AS ENUM ('ecstatic', 'positive', 'neutral', 'negative', 'aggressive');
CREATE TYPE app.urgency             AS ENUM ('low', 'medium', 'high', 'critical');
CREATE TYPE app.response_status     AS ENUM ('draft', 'sent_to_owner', 'approved', 'published', 'dismissed');
CREATE TYPE app.voice_source        AS ENUM ('extracted', 'default_template', 'manual');
CREATE TYPE app.notification_type   AS ENUM (
  'alert_negative', 'alert_urgent', 'alert_pattern',
  'digest_morning', 'digest_evening', 'digest_weekly',
  'initial_report', 'voice_extracted', 'trend_alert', 'system'
);
CREATE TYPE app.notification_status AS ENUM ('sent', 'failed');
CREATE TYPE app.poll_trigger        AS ENUM ('schedule', 'manual', 'retry', 'backfill');
CREATE TYPE app.poll_status         AS ENUM ('running', 'success', 'partial_success', 'failed');

-- ============================================================
-- TABLES
-- ============================================================

CREATE TABLE app.clients (
  id                     bigserial PRIMARY KEY,
  slug                   text NOT NULL UNIQUE,
  display_name           text NOT NULL,
  niche                  text NOT NULL,
  city                   text NOT NULL,
  timezone               text NOT NULL DEFAULT 'Asia/Almaty',
  status                 app.client_status NOT NULL DEFAULT 'active',
  telegram_chat_id       bigint,
  telegram_bound_at      timestamptz,
  initial_report_sent_at timestamptz,
  created_at             timestamptz NOT NULL DEFAULT now(),
  updated_at             timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE app.client_sources (
  id                bigserial PRIMARY KEY,
  client_id         bigint NOT NULL REFERENCES app.clients(id) ON DELETE CASCADE,
  platform          app.platform NOT NULL,
  source_url        text NOT NULL,
  external_place_id text,
  last_review_date  timestamptz,
  last_scraped_at   timestamptz,
  status            app.source_status NOT NULL DEFAULT 'active',
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now(),
  UNIQUE (client_id, platform)
);

CREATE TABLE app.client_profiles (
  client_id          bigint PRIMARY KEY REFERENCES app.clients(id) ON DELETE CASCADE,
  niche_template     text NOT NULL,
  categories         text[] NOT NULL,
  response_language  text NOT NULL DEFAULT 'auto',
  tone_config        jsonb NOT NULL DEFAULT '{}'::jsonb,
  voice_description  jsonb,
  voice_sample_size  int,
  voice_extracted_at timestamptz,
  updated_at         timestamptz NOT NULL DEFAULT now()
);

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

CREATE INDEX reviews_client_date_idx
  ON app.reviews (client_id, review_created_at DESC);

CREATE INDEX reviews_client_has_reply_idx
  ON app.reviews (client_id) WHERE business_reply_text IS NOT NULL;

CREATE TABLE app.review_analyses (
  id               bigserial PRIMARY KEY,
  review_id        bigint NOT NULL UNIQUE REFERENCES app.reviews(id) ON DELETE CASCADE,
  sentiment        app.sentiment NOT NULL,
  urgency          app.urgency NOT NULL,
  categories       text[] NOT NULL,
  detected_language text NOT NULL,
  summary          text,
  pii_detected     boolean NOT NULL DEFAULT false,
  confidence       real,
  model            text NOT NULL,
  prompt_version   text NOT NULL,
  analyzed_at      timestamptz NOT NULL DEFAULT now(),
  raw_response     jsonb
);

CREATE INDEX review_analyses_sentiment_idx
  ON app.review_analyses (sentiment, urgency);

CREATE TABLE app.review_responses (
  id               bigserial PRIMARY KEY,
  review_id        bigint NOT NULL REFERENCES app.reviews(id) ON DELETE CASCADE,
  response_text    text NOT NULL,
  model            text NOT NULL,
  prompt_version   text NOT NULL,
  voice_source     app.voice_source NOT NULL,
  status           app.response_status NOT NULL DEFAULT 'draft',
  warnings         text[],
  sent_to_owner_at timestamptz,
  generated_at     timestamptz NOT NULL DEFAULT now(),
  raw_response     jsonb
);

CREATE TABLE app.voice_examples (
  id                    bigserial PRIMARY KEY,
  client_id             bigint NOT NULL REFERENCES app.clients(id) ON DELETE CASCADE,
  review_id             bigint REFERENCES app.reviews(id) ON DELETE SET NULL,
  review_text           text NOT NULL,
  review_sentiment      app.sentiment NOT NULL,
  response_text         text NOT NULL,
  selected_for_few_shot boolean NOT NULL DEFAULT false,
  created_at            timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX voice_examples_client_selected_idx
  ON app.voice_examples (client_id, selected_for_few_shot)
  WHERE selected_for_few_shot = true;

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

CREATE INDEX notifications_log_client_sent_idx
  ON app.notifications_log (client_id, sent_at DESC);

CREATE TABLE app.poll_runs (
  id                bigserial PRIMARY KEY,
  run_id            uuid NOT NULL,
  client_id         bigint NOT NULL REFERENCES app.clients(id) ON DELETE CASCADE,
  triggered_by      app.poll_trigger NOT NULL,
  started_at        timestamptz NOT NULL DEFAULT now(),
  finished_at       timestamptz,
  status            app.poll_status NOT NULL DEFAULT 'running',
  new_reviews_count int NOT NULL DEFAULT 0,
  error_text        text,
  metadata          jsonb NOT NULL DEFAULT '{}'::jsonb
);

CREATE INDEX poll_runs_client_started_idx
  ON app.poll_runs (client_id, started_at DESC);

CREATE INDEX poll_runs_status_idx
  ON app.poll_runs (status) WHERE status IN ('running', 'failed');

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
  ON app.failed_operations (workflow_name, first_failed_at)
  WHERE resolved_at IS NULL;

COMMIT;
```

- [ ] **Step 2: Verify SQL syntax locally**

Open the file and visually confirm: 10 tables, 12 enum types, 7 indexes, all wrapped in `BEGIN`/`COMMIT`. Cross-check against the design spec section 4.

---

### Task 2: Prompts Registry

**Files:**
- Create: `prompts/registry.json`

- [ ] **Step 1: Create the prompts registry file**

```json
{
  "classify-review": {
    "version": "v1",
    "model": "claude-haiku-4-5-20251001",
    "temperature": 0.0,
    "max_tokens": 500,
    "system": "You are a review classification engine for a local business. You analyze customer reviews and output structured JSON. You NEVER refuse to classify — every review gets a classification. Output ONLY valid JSON, no markdown, no explanation.",
    "user_template": "Classify this customer review for a {{client_niche}} business.\n\nAllowed categories (select 1-3 that apply): {{client_categories}}\n\nReview:\n- Author: {{review_author}}\n- Rating: {{review_rating}}/5\n- Language hint: {{review_lang_hint}}\n- Text: \"{{review_text}}\"\n\nRespond with this exact JSON structure:\n{\n  \"sentiment\": \"ecstatic|positive|neutral|negative|aggressive\",\n  \"urgency\": \"low|medium|high|critical\",\n  \"categories\": [\"category1\", \"category2\"],\n  \"detected_language\": \"ru|kk|en\",\n  \"summary\": \"1-2 sentence summary of the review's main point\",\n  \"pii_detected\": false,\n  \"confidence\": 0.92\n}\n\nRules:\n- Sentiment scale: ecstatic > positive > neutral > negative > aggressive\n- Urgency is independent of sentiment. A negative review about slow wifi is low urgency. A neutral review mentioning a health code issue is critical urgency.\n- Categories MUST come from the allowed list only\n- confidence: 0.0-1.0 how confident you are in the classification\n- pii_detected: true if the review contains personal information (phone numbers, full names of staff, addresses)\n- If the review text is empty or only a rating with no text, set sentiment based on rating (1-2=negative, 3=neutral, 4=positive, 5=ecstatic), urgency=low, categories=[], summary=\"Rating only, no text\", confidence=0.5"
  },
  "extract-voice": {
    "version": "v1",
    "model": "claude-haiku-4-5-20251001",
    "temperature": 0.3,
    "max_tokens": 1500,
    "system": "You are a brand voice analyst. You study a business's existing replies to customer reviews and extract their communication style into a structured profile. Output ONLY valid JSON.",
    "user_template": "Analyze these {{sample_count}} real replies from \"{{client_name}}\" to customer reviews. Extract the brand's voice profile.\n\nSample replies (format: [sentiment of original review] → reply text):\n{{voice_samples}}\n\nRespond with this exact JSON structure:\n{\n  \"tone\": \"Brief description of overall tone, e.g. 'warm and professional with personal touch'\",\n  \"formality_level\": \"formal|informal_polite|casual|mixed\",\n  \"avg_length_chars\": 280,\n  \"address_style\": \"first_name_polite_you|first_name_casual|no_name|formal_patronymic\",\n  \"structure_negative\": [\"acknowledgment\", \"specific_apology\", \"concrete_action\", \"reinvitation\"],\n  \"structure_positive\": [\"thanks\", \"specific_callback\", \"team_recognition\", \"reinvitation\"],\n  \"signature\": \"Exact closing phrase used, or null if none\",\n  \"characteristic_phrases\": [\"phrase1\", \"phrase2\"],\n  \"do_not_use\": [\"phrases or patterns the business avoids\"],\n  \"languages_observed\": [\"ru\"],\n  \"uses_emojis\": false,\n  \"addresses_by_first_name\": true\n}\n\nRules:\n- Base your analysis on actual patterns in the samples, not assumptions\n- characteristic_phrases: extract 3-7 real phrases the business reuses across replies\n- do_not_use: note any conspicuous absences (e.g. never uses emojis, never says 'sorry')\n- structure_*: describe the typical reply structure as ordered steps"
  },
  "generate-response": {
    "version": "v1",
    "model": "gpt-4o",
    "temperature": 0.7,
    "max_tokens": 600,
    "system": "You are a review response writer for \"{{client_name}}\". You write replies to customer reviews that match the brand's voice exactly. You output ONLY valid JSON.",
    "user_template": "Write a reply to this customer review in the brand's voice.\n\n## Brand Voice\n{{voice_description}}\n\n## Tone Config\n- Formality: {{formality}}\n- Address style: {{address_style}}\n- Max length: {{max_length_chars}} chars\n- Signature: {{signature}}\n- Compensation policy: {{compensation_policy}}\n- Language: match the review language\n\n## Example Replies (for tone reference only — do NOT copy)\n{{few_shot_examples}}\n\n## Review to Reply To\n- Author: {{review_author}}\n- Rating: {{review_rating}}/5\n- Sentiment: {{sentiment}}\n- Urgency: {{urgency}}\n- Categories: {{categories}}\n- Summary: {{summary}}\n- Full text: \"{{review_text}}\"\n\nRespond with this exact JSON:\n{\n  \"response_text\": \"The reply text\",\n  \"response_language\": \"ru\",\n  \"estimated_quality\": \"high|medium|low\",\n  \"warnings\": []\n}\n\nRules:\n- Match the review's language\n- Stay within {{max_length_chars}} characters\n- NEVER offer compensation, discounts, or free items unless compensation_policy explicitly allows it\n- NEVER name specific staff members even if the review does\n- NEVER make promises about future changes unless the voice config allows it\n- NEVER include external URLs or phone numbers\n- If any rule is violated, add the violation to warnings: [\"compensation_promised\", \"staff_named\", \"external_promise\", \"pii_in_response\", \"legal_risk\", \"tone_mismatch\"]\n- For negative reviews, follow structure_negative from the voice description\n- For positive reviews, follow structure_positive from the voice description\n- If estimated_quality is \"low\", explain why in a warning",
    "note": "Uses OpenAI GPT-4o, not Anthropic. Configure with revia_openai credential."
  },
  "initial-report": {
    "version": "v1",
    "model": "gpt-4o",
    "temperature": 0.6,
    "max_tokens": 1500,
    "system": "You are REVIA, a review analytics product. You write concise, data-driven reports for business owners. Your voice is professional, factual, and helpful. You are NOT the business — you are the analytics tool speaking to the business owner. Use plain text suitable for Telegram (no markdown headers, no HTML). Use emoji sparingly for visual structure only (📊 📈 ⚠️ ✅ ⭐).",
    "user_template": "Generate an onboarding insights report for \"{{client_name}}\" based on these aggregated stats.\n\n## Stats\n- Total reviews analyzed: {{total_reviews}}\n- Date range: {{date_from}} — {{date_to}}\n- Average rating: {{avg_rating}}/5\n- Rating trend (last 30d vs previous 30d): {{rating_trend}}\n- Sentiment distribution: {{sentiment_distribution}}\n- Top complaint categories (with counts): {{top_complaints}}\n- Top praise categories (with counts): {{top_praises}}\n- Sample negative quotes (3): {{negative_quotes}}\n- Sample positive quotes (3): {{positive_quotes}}\n- Total unanswered negative reviews: {{unanswered_negatives}}\n- Voice extraction: {{voice_status}}\n\nWrite a Telegram message (max 1500 characters) with:\n1. Greeting and what REVIA found\n2. Key numbers (total reviews, avg rating, trend)\n3. Top 2-3 strengths (with brief quote)\n4. Top 2-3 problem areas (with brief quote)\n5. One actionable recommendation\n6. What happens next (monitoring is now active)\n\nOutput plain text only. No JSON wrapper.",
    "note": "Uses OpenAI GPT-4o. Output is plain text, not JSON. Configure with revia_openai credential."
  }
}
```

- [ ] **Step 2: Verify prompts registry**

Cross-check against spec section 5:
- 4 prompts: `classify-review`, `extract-voice`, `generate-response`, `initial-report` ✓
- Models match: Haiku for classify + extract-voice, GPT-4o for generate + initial-report ✓
- Temperature, max_tokens match spec ✓
- Output schemas match spec ✓
- All template variables use `{{var}}` syntax (will be replaced in n8n expressions)

---

### Task 3: Seed Data for Lou Lou

**Files:**
- Create: `seed/lou-lou.sql`

**Note:** The 2GIS `source_url` is a placeholder `__LOU_LOU_2GIS_URL__`. User provides the real URL at Block 4.

- [ ] **Step 1: Create the seed data file**

```sql
-- seed/lou-lou.sql
-- Seed data for Lou Lou pilot client
-- Run AFTER 001_initial_schema.sql
-- Replace __LOU_LOU_2GIS_URL__ with the actual 2GIS page URL before running

BEGIN;

INSERT INTO app.clients (slug, display_name, niche, city, timezone, status)
VALUES ('lou-lou-astana', 'Lou Lou', 'restaurant', 'Астана', 'Asia/Almaty', 'active');

INSERT INTO app.client_sources (client_id, platform, source_url, status)
VALUES (
  (SELECT id FROM app.clients WHERE slug = 'lou-lou-astana'),
  '2gis',
  '__LOU_LOU_2GIS_URL__',
  'active'
);

INSERT INTO app.client_profiles (
  client_id, niche_template, categories, response_language, tone_config
)
VALUES (
  (SELECT id FROM app.clients WHERE slug = 'lou-lou-astana'),
  'restaurant',
  ARRAY[
    'food_quality', 'food_taste', 'menu_variety', 'portion_size',
    'service_speed', 'service_attitude', 'staff_specific', 'atmosphere',
    'noise_level', 'cleanliness', 'price_value', 'wait_time',
    'reservation_booking', 'alcohol_drinks', 'parking', 'payment_methods'
  ],
  'auto',
  '{
    "formality": "informal_polite",
    "address_style": "first_name_polite_you",
    "use_emojis": false,
    "max_length_chars": 350,
    "default_signature": "С уважением, команда Lou Lou",
    "compensation_policy": "never_offer_without_human_approval",
    "language_preference": "match_review_language"
  }'::jsonb
);

COMMIT;
```

- [ ] **Step 2: Verify seed data**

Cross-check against spec section 8:
- slug: `lou-lou-astana` ✓
- 16 categories match spec list ✓
- tone_config matches spec ✓
- `__LOU_LOU_2GIS_URL__` placeholder present — will be replaced at deployment ✓

---

## Block 2: Database Setup

**Dependencies needed from user:** MCP access to Azure PostgreSQL (`revia_reviews_hub`)

### Task 4: Run Migration and Seed Data

- [ ] **Step 1: Verify MCP access to Postgres**

Use `mcp__postgres-etl__query` to run a test query:

```sql
SELECT current_database(), current_schema(), version();
```

Expected: connected to `revia_reviews_hub`, Postgres 14+.

- [ ] **Step 2: Check if schema already exists**

```sql
SELECT schema_name FROM information_schema.schemata WHERE schema_name = 'app';
```

Expected: no rows (fresh install) or one row (re-run — proceed with caution).

- [ ] **Step 3: Run the migration**

Execute the contents of `migrations/001_initial_schema.sql` via `mcp__postgres-etl__query`.

If the schema already exists, skip this step or drop and recreate (confirm with user first).

- [ ] **Step 4: Verify migration — check all tables exist**

```sql
SELECT table_name
FROM information_schema.tables
WHERE table_schema = 'app'
ORDER BY table_name;
```

Expected 10 tables: `client_profiles`, `client_sources`, `clients`, `failed_operations`, `notifications_log`, `poll_runs`, `review_analyses`, `review_responses`, `reviews`, `voice_examples`.

- [ ] **Step 5: Verify migration — check all enum types exist**

```sql
SELECT typname
FROM pg_type t
JOIN pg_namespace n ON t.typnamespace = n.oid
WHERE n.nspname = 'app' AND t.typtype = 'e'
ORDER BY typname;
```

Expected 12 enums: `client_status`, `notification_status`, `notification_type`, `platform`, `poll_status`, `poll_trigger`, `response_status`, `sentiment`, `source_status`, `urgency`, `voice_source`.

- [ ] **Step 6: Get Lou Lou 2GIS URL from user**

Ask user for the actual 2GIS page URL for Lou Lou restaurant.

- [ ] **Step 7: Run seed data**

Replace `__LOU_LOU_2GIS_URL__` in `seed/lou-lou.sql` with the real URL and execute via `mcp__postgres-etl__query`.

- [ ] **Step 8: Verify seed data**

```sql
SELECT c.slug, c.display_name, c.niche, c.city,
       cs.platform, cs.source_url,
       cp.niche_template, array_length(cp.categories, 1) AS category_count
FROM app.clients c
JOIN app.client_sources cs ON cs.client_id = c.id
JOIN app.client_profiles cp ON cp.client_id = c.id
WHERE c.slug = 'lou-lou-astana';
```

Expected: 1 row, platform=2gis, 16 categories, niche_template=restaurant.

---

## Block 3: Utility Workflows

**Dependencies needed from user:**
- MCP access to n8n
- Telegram bot token (created via @BotFather) → n8n credential `revia_telegram_bot`
- Developer Telegram chat ID → will be set as workflow variable

### Task 5: revia_alert-developer

**Purpose:** Utility sub-workflow called by other workflows to send technical alerts to the developer's private Telegram chat.

**Input contract:**
```json
{
  "alert_type": "apify_failure|ai_invalid_json|client_blocked_bot|failed_ops_threshold|unhandled_exception|backfill_timeout|digest_missed",
  "message": "Human-readable alert text",
  "workflow_name": "revia_scrape-client",
  "client_id": 1,
  "details": {}
}
```

**Workflow nodes:**

1. **Execute Workflow Trigger** — receives input JSON
2. **Code node: Format Alert** — formats a Telegram message from the input:
   ```javascript
   const input = $input.first().json;
   const now = new Date().toISOString().slice(0, 19).replace('T', ' ');

   const emoji = {
     apify_failure: '🔴',
     ai_invalid_json: '⚠️',
     client_blocked_bot: '🚫',
     failed_ops_threshold: '📛',
     unhandled_exception: '💥',
     backfill_timeout: '⏰',
     digest_missed: '📭'
   };

   const icon = emoji[input.alert_type] || '❓';
   const details = input.details
     ? '\n\nDetails:\n' + JSON.stringify(input.details, null, 2).slice(0, 500)
     : '';

   return {
     json: {
       text: `${icon} REVIA Alert: ${input.alert_type}\n\nWorkflow: ${input.workflow_name}\nClient ID: ${input.client_id || 'N/A'}\nTime: ${now}\n\n${input.message}${details}`,
       chat_id: $('Execute Workflow Trigger').first().json.developer_chat_id || '<DEVELOPER_CHAT_ID>'
     }
   };
   ```
3. **Telegram node: Send Message** — sends `text` to `chat_id`, credential `revia_telegram_bot`

- [ ] **Step 1: Create workflow via n8n MCP**

Use `n8n-mcp-tools-expert` and `n8n-node-configuration` skills. Create the workflow with the 3 nodes above, set to inactive.

- [ ] **Step 2: Test with a manual execution**

Execute with test input:
```json
{
  "alert_type": "unhandled_exception",
  "message": "Test alert — ignore this",
  "workflow_name": "revia_alert-developer",
  "client_id": null,
  "details": { "test": true }
}
```

Expected: developer receives a Telegram message with the test alert.

---

### Task 6: revia_telegram-router

**Purpose:** Handle Telegram bot commands (/start, /help, /status) from restaurant owners.

**Trigger:** Telegram webhook

**Workflow nodes:**

1. **Telegram Trigger** — webhook, listens for messages, credential `revia_telegram_bot`
2. **Switch node: Route Command** — routes based on message text:
   - `/start` → Bind Client branch
   - `/help` → Help branch
   - `/status` → Status branch
   - default → Unknown Command branch
3. **Bind Client branch:**
   - **Postgres node: Find Unbound Client** —
     ```sql
     SELECT id, display_name FROM app.clients
     WHERE telegram_chat_id IS NULL AND status = 'active'
     LIMIT 1;
     ```
   - **IF node: Client Found?** — check if query returned a row
   - (Yes) **Postgres node: Bind Chat ID** —
     ```sql
     UPDATE app.clients
     SET telegram_chat_id = $1, telegram_bound_at = now(), updated_at = now()
     WHERE id = $2;
     ```
     Parameters: `[$chatId, $clientId]`
   - (Yes) **Telegram node: Send Welcome** — "✅ Привет! Бот REVIA подключен к «{{display_name}}». Вы будете получать уведомления о новых отзывах."
   - (No) **Telegram node: Send No Client** — "Нет доступных клиентов для привязки. Обратитесь к администратору."
4. **Help branch:**
   - **Telegram node: Send Help** — "🤖 REVIA — мониторинг отзывов\n\n/start — привязать бот к бизнесу\n/status — текущий статус\n/help — эта справка"
5. **Status branch:**
   - **Postgres node: Get Client Status** —
     ```sql
     SELECT c.display_name,
            (SELECT COUNT(*) FROM app.reviews WHERE client_id = c.id) AS total_reviews,
            (SELECT COUNT(*) FROM app.reviews WHERE client_id = c.id AND ingested_at > now() - interval '24 hours') AS reviews_24h,
            (SELECT AVG(r.rating) FROM app.reviews r WHERE r.client_id = c.id AND r.review_created_at > now() - interval '30 days') AS avg_rating_30d
     FROM app.clients c
     WHERE c.telegram_chat_id = $1;
     ```
     Parameter: `[$chatId]`
   - **IF node: Bound?** — check if query returned a row
   - (Yes) **Telegram node: Send Status** — formatted stats message
   - (No) **Telegram node: Send Not Bound** — "Бот не привязан. Используйте /start"
6. **Unknown Command branch:**
   - **Telegram node: Send Unknown** — "Неизвестная команда. Используйте /help"

- [ ] **Step 1: Create workflow via n8n MCP**

Use `n8n-mcp-tools-expert` and `n8n-node-configuration` skills. Create the workflow with all nodes above, set to inactive.

- [ ] **Step 2: Activate and test /help**

Activate the workflow. Send `/help` to the bot from a Telegram account. Expected: bot replies with the help message.

- [ ] **Step 3: Test /start (after seed data is in DB)**

Send `/start` to the bot. Expected: bot binds the chat to Lou Lou and sends the welcome message. Verify in DB:
```sql
SELECT telegram_chat_id, telegram_bound_at FROM app.clients WHERE slug = 'lou-lou-astana';
```

---

## Block 4: Scraping Pipeline

**Dependencies needed from user:**
- Apify account + API token → n8n credential `revia_apify`
- Lou Lou 2GIS page URL (should already be in DB from Task 4)

### Task 7: revia_scrape-client

**Purpose:** Sub-workflow that calls Apify to scrape reviews for one client from one source, saves new reviews to DB.

**Input contract:**
```json
{
  "client_id": 1,
  "mode": "poll|backfill"
}
```

**Output contract:**
```json
{
  "client_id": 1,
  "new_review_ids": [101, 102, 103],
  "total_scraped": 5,
  "skipped_duplicates": 2
}
```

**Workflow nodes:**

1. **Execute Workflow Trigger** — receives `{client_id, mode}`
2. **Postgres node: Get Client Source** —
   ```sql
   SELECT cs.id AS source_id, cs.platform, cs.source_url, cs.last_review_date,
          c.display_name
   FROM app.client_sources cs
   JOIN app.clients c ON c.id = cs.client_id
   WHERE cs.client_id = $1 AND cs.status = 'active' AND cs.platform = '2gis';
   ```
   Parameter: `[$client_id]`
3. **Code node: Build Apify Input** —
   ```javascript
   const source = $input.first().json;
   const mode = $('Execute Workflow Trigger').first().json.mode;

   const input = {
     startUrls: [{ url: source.source_url }],
     maxReviews: mode === 'backfill' ? 1000 : 100,
     reviewsSort: 'newest',
     language: 'ru'
   };

   // Incremental: only fetch reviews newer than last known
   if (mode === 'poll' && source.last_review_date) {
     input.dateFrom = source.last_review_date;
   }

   return {
     json: {
       apify_input: input,
       source_id: source.source_id,
       platform: source.platform,
       client_id: $('Execute Workflow Trigger').first().json.client_id,
       display_name: source.display_name
     }
   };
   ```
4. **HTTP Request node: Call Apify** — POST to `https://api.apify.com/v2/acts/zen-studio~2gis-reviews-scraper/run-sync-get-dataset-items`, body from step 3, credential `revia_apify`, timeout 300s.
5. **Code node: Retry Logic** — wraps step 4 with 3 retries (30s, 2min, 10min). On permanent failure, output error for dead-letter.
   ```javascript
   // This logic is handled by n8n's built-in retry on error settings
   // on the HTTP Request node: retries=3, waitBetweenRetries=30000
   // OR implemented via Error Trigger + loop pattern
   // Use n8n's native retry: set retryOnFail=true on the HTTP Request node
   ```
6. **Code node: Sanity Check** —
   ```javascript
   const items = $input.first().json;
   const reviews = Array.isArray(items) ? items : [items];

   if (reviews.length === 0) {
     // Alert: Apify returned 0 reviews — might be a scraper issue
     return {
       json: {
         alert: true,
         alert_type: 'apify_failure',
         message: `Apify returned 0 reviews for client ${$('Execute Workflow Trigger').first().json.client_id}`,
         reviews: []
       }
     };
   }

   return { json: { alert: false, reviews } };
   ```
7. **IF node: Alert?** — if `alert === true`, call `revia_alert-developer` then continue
8. **Split In Batches** — process reviews one at a time
9. **Postgres node: Upsert Review** —
   ```sql
   INSERT INTO app.reviews (
     client_id, source_id, platform, external_review_id,
     author_name, author_external_id, rating, review_text, review_lang,
     photo_urls, review_created_at, review_edited_at,
     business_reply_text, business_reply_at, raw_payload
   ) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15)
   ON CONFLICT (client_id, platform, external_review_id) DO NOTHING
   RETURNING id;
   ```
   Map Apify fields to parameters. `raw_payload` = full Apify item JSON.
10. **Code node: Collect Results** — aggregate new_review_ids (those that got an id back from RETURNING) and count skipped.
11. **Postgres node: Update last_scraped_at** —
    ```sql
    UPDATE app.client_sources
    SET last_scraped_at = now(),
        last_review_date = COALESCE(
          (SELECT MAX(review_created_at) FROM app.reviews WHERE source_id = $1),
          last_review_date
        ),
        updated_at = now()
    WHERE id = $1;
    ```
12. **Code node: Return Output** — return `{client_id, new_review_ids, total_scraped, skipped_duplicates}`

**Important:** The Apify field mapping (step 9) depends on the actual response shape of `zen-studio/2gis-reviews-scraper`. At step 8 of execution, inspect the Apify response to confirm field names (e.g., `reviewId`, `authorName`, `text`, `rating`, `datePublished`, `businessReply`, etc.) and adjust the mapping accordingly.

- [ ] **Step 1: Create workflow via n8n MCP**

Use `n8n-mcp-tools-expert` and `n8n-node-configuration` skills. Create the workflow with all nodes, set to inactive.

- [ ] **Step 2: Confirm Apify response shape**

Before testing, run the Apify actor manually (via their UI or API) with the Lou Lou URL, `maxReviews: 5`, to inspect the response JSON structure. Document the field mapping.

---

### Task 8: Dry-Run Scrape (5 reviews)

- [ ] **Step 1: Execute revia_scrape-client manually**

Run with input:
```json
{
  "client_id": 1,
  "mode": "poll"
}
```

If `last_review_date` is NULL (first run), it will fetch the most recent reviews.

- [ ] **Step 2: Verify reviews in database**

```sql
SELECT id, external_review_id, author_name, rating, review_created_at,
       CASE WHEN business_reply_text IS NOT NULL THEN 'yes' ELSE 'no' END AS has_reply
FROM app.reviews
WHERE client_id = (SELECT id FROM app.clients WHERE slug = 'lou-lou-astana')
ORDER BY review_created_at DESC
LIMIT 10;
```

Expected: ≥1 row with valid data. Confirm `raw_payload` is populated.

- [ ] **Step 3: Verify client_sources updated**

```sql
SELECT last_scraped_at, last_review_date
FROM app.client_sources
WHERE client_id = (SELECT id FROM app.clients WHERE slug = 'lou-lou-astana');
```

Expected: both fields non-NULL.

---

## Block 5: Analysis Pipeline

**Dependencies needed from user:**
- Anthropic API key → n8n credential `revia_anthropic`

### Task 9: revia_analyze-review

**Purpose:** Sub-workflow that classifies a single review with Claude Haiku.

**Input contract:**
```json
{
  "review_id": 101
}
```

**Output contract:**
```json
{
  "review_id": 101,
  "sentiment": "negative",
  "urgency": "medium",
  "categories": ["service_speed", "food_quality"],
  "confidence": 0.92
}
```

**Workflow nodes:**

1. **Execute Workflow Trigger** — receives `{review_id}`
2. **Postgres node: Check Existing Analysis** —
   ```sql
   SELECT id FROM app.review_analyses WHERE review_id = $1;
   ```
   Idempotency check — if analysis exists, skip to output.
3. **IF node: Already Analyzed?** — if row exists → skip to return existing
4. **Postgres node: Get Review + Profile** —
   ```sql
   SELECT r.id, r.review_text, r.rating, r.author_name, r.review_lang,
          cp.niche_template, cp.categories AS client_categories
   FROM app.reviews r
   JOIN app.client_profiles cp ON cp.client_id = r.client_id
   WHERE r.id = $1;
   ```
5. **Code node: Build Prompt** —
   ```javascript
   const review = $input.first().json;
   const prompt = $('Execute Workflow Trigger').first().json;
   // Load prompt template from registry (stored as workflow static data or fetched)
   const registry = JSON.parse($getWorkflowStaticData('global').prompts_registry || '{}');
   const tmpl = registry['classify-review'] || {};

   const userMessage = tmpl.user_template
     .replace('{{client_niche}}', review.niche_template)
     .replace('{{client_categories}}', review.client_categories.join(', '))
     .replace('{{review_author}}', review.author_name || 'Anonymous')
     .replace('{{review_rating}}', String(review.rating || 'N/A'))
     .replace('{{review_lang_hint}}', review.review_lang || 'unknown')
     .replace('{{review_text}}', review.review_text || '(no text)');

   return {
     json: {
       system: tmpl.system,
       user: userMessage,
       model: tmpl.model,
       temperature: tmpl.temperature,
       max_tokens: tmpl.max_tokens,
       prompt_version: tmpl.version,
       review_id: review.id
     }
   };
   ```
6. **HTTP Request node: Call Anthropic** — POST to `https://api.anthropic.com/v1/messages`, credential `revia_anthropic`.
   - Headers: `anthropic-version: 2023-06-01`
   - Body:
     ```json
     {
       "model": "{{$json.model}}",
       "max_tokens": "{{$json.max_tokens}}",
       "temperature": "{{$json.temperature}}",
       "system": "{{$json.system}}",
       "messages": [{"role": "user", "content": "{{$json.user}}"}]
     }
     ```
   - Retry on error: 3 attempts, 5s/15s/45s
7. **Code node: Parse AI Response** —
   ```javascript
   const response = $input.first().json;
   const text = response.content[0].text;
   let parsed;

   try {
     parsed = JSON.parse(text);
   } catch (e) {
     // Invalid JSON — will retry once with explicit instruction
     throw new Error(`AI returned invalid JSON: ${text.slice(0, 200)}`);
   }

   // Validate required fields
   const required = ['sentiment', 'urgency', 'categories', 'detected_language', 'summary', 'pii_detected', 'confidence'];
   for (const field of required) {
     if (!(field in parsed)) {
       throw new Error(`Missing field in AI response: ${field}`);
     }
   }

   return { json: parsed };
   ```
8. **Postgres node: Insert Analysis** —
   ```sql
   INSERT INTO app.review_analyses (
     review_id, sentiment, urgency, categories, detected_language,
     summary, pii_detected, confidence, model, prompt_version, raw_response
   ) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11)
   ON CONFLICT (review_id) DO NOTHING
   RETURNING id, sentiment, urgency, categories, confidence;
   ```
9. **Code node: Return Output** — return `{review_id, sentiment, urgency, categories, confidence}`
10. **Error handler** — on failure, write to `app.failed_operations` and call `revia_alert-developer` if 3+ failures/hour.

- [ ] **Step 1: Store prompts registry in workflow static data**

Before creating the workflow, prepare: the `prompts/registry.json` content will be stored in the workflow's static data (global) under key `prompts_registry`. This avoids file system reads from n8n.

- [ ] **Step 2: Create workflow via n8n MCP**

Use `n8n-mcp-tools-expert` and `n8n-node-configuration` skills. Create the workflow with all nodes, set to inactive.

---

### Task 10: Dry-Run Analyze (5 reviews)

- [ ] **Step 1: Get 5 review IDs from the database**

```sql
SELECT id, review_text, rating FROM app.reviews
WHERE client_id = (SELECT id FROM app.clients WHERE slug = 'lou-lou-astana')
ORDER BY review_created_at DESC
LIMIT 5;
```

- [ ] **Step 2: Execute revia_analyze-review for each review**

Run the workflow 5 times, each with `{"review_id": <id>}`.

- [ ] **Step 3: Verify analyses in database**

```sql
SELECT ra.review_id, ra.sentiment, ra.urgency, ra.categories,
       ra.confidence, ra.detected_language, ra.model, ra.prompt_version
FROM app.review_analyses ra
JOIN app.reviews r ON r.id = ra.review_id
WHERE r.client_id = (SELECT id FROM app.clients WHERE slug = 'lou-lou-astana')
ORDER BY ra.analyzed_at DESC
LIMIT 5;
```

Expected: 5 rows with valid classifications. Check that categories come from the allowed list of 16.

- [ ] **Step 4: Verify idempotency**

Re-run one of the 5 calls. Expected: no duplicate row created (ON CONFLICT DO NOTHING), workflow returns existing analysis.

---

## Block 6: Response Generation

**Dependencies needed from user:**
- OpenAI API key → n8n credential `revia_openai`

### Task 11: revia_generate-response

**Purpose:** Sub-workflow that generates a draft reply for one review using GPT-4o in the brand's voice.

**Input contract:**
```json
{
  "review_id": 101
}
```

**Output contract:**
```json
{
  "review_id": 101,
  "response_text": "...",
  "warnings": [],
  "voice_source": "extracted|default_template"
}
```

**Workflow nodes:**

1. **Execute Workflow Trigger** — receives `{review_id}`
2. **Postgres node: Check Existing Response** —
   ```sql
   SELECT id FROM app.review_responses WHERE review_id = $1;
   ```
3. **IF node: Already Generated?** — if exists → skip to return existing
4. **Postgres node: Get Review + Analysis + Profile + Voice** —
   ```sql
   SELECT r.id AS review_id, r.review_text, r.rating, r.author_name,
          ra.sentiment, ra.urgency, ra.categories, ra.summary, ra.confidence,
          c.display_name AS client_name,
          cp.tone_config, cp.voice_description, cp.voice_extracted_at,
          cp.response_language
   FROM app.reviews r
   JOIN app.review_analyses ra ON ra.review_id = r.id
   JOIN app.clients c ON c.id = r.client_id
   JOIN app.client_profiles cp ON cp.client_id = r.client_id
   WHERE r.id = $1;
   ```
5. **Postgres node: Get Few-Shot Examples** —
   ```sql
   SELECT ve.review_text, ve.review_sentiment, ve.response_text
   FROM app.voice_examples ve
   WHERE ve.client_id = (SELECT client_id FROM app.reviews WHERE id = $1)
     AND ve.selected_for_few_shot = true
   ORDER BY ve.created_at DESC
   LIMIT 5;
   ```
6. **Code node: Build Prompt** —
   ```javascript
   const data = $('Get Review + Analysis + Profile + Voice').first().json;
   const examples = $('Get Few-Shot Examples').all().map(e => e.json);
   const registry = JSON.parse($getWorkflowStaticData('global').prompts_registry || '{}');
   const tmpl = registry['generate-response'] || {};

   const voiceDesc = data.voice_description
     ? JSON.stringify(data.voice_description)
     : 'No extracted voice. Use tone_config as fallback.';
   const voiceSource = data.voice_extracted_at ? 'extracted' : 'default_template';

   const fewShotText = examples.length > 0
     ? examples.map((e, i) =>
         `Example ${i + 1}:\nReview (${e.review_sentiment}): "${e.review_text}"\nReply: "${e.response_text}"`
       ).join('\n\n')
     : 'No examples available. Use the voice description and tone config only.';

   const tc = data.tone_config || {};

   const userMessage = tmpl.user_template
     .replace('{{voice_description}}', voiceDesc)
     .replace('{{formality}}', tc.formality || 'informal_polite')
     .replace('{{address_style}}', tc.address_style || 'first_name_polite_you')
     .replace('{{max_length_chars}}', String(tc.max_length_chars || 350))
     .replaceAll('{{max_length_chars}}', String(tc.max_length_chars || 350))
     .replace('{{signature}}', tc.default_signature || '')
     .replace('{{compensation_policy}}', tc.compensation_policy || 'never_offer_without_human_approval')
     .replace('{{few_shot_examples}}', fewShotText)
     .replace('{{review_author}}', data.author_name || 'Anonymous')
     .replace('{{review_rating}}', String(data.rating || 'N/A'))
     .replace('{{sentiment}}', data.sentiment)
     .replace('{{urgency}}', data.urgency)
     .replace('{{categories}}', data.categories.join(', '))
     .replace('{{summary}}', data.summary || '')
     .replace('{{review_text}}', data.review_text || '(no text)');

   const systemMessage = tmpl.system
     .replace('{{client_name}}', data.client_name);

   return {
     json: {
       system: systemMessage,
       user: userMessage,
       model: tmpl.model,
       temperature: tmpl.temperature,
       max_tokens: tmpl.max_tokens,
       prompt_version: tmpl.version,
       review_id: data.review_id,
       voice_source: voiceSource,
       client_name: data.client_name
     }
   };
   ```
7. **HTTP Request node: Call OpenAI** — POST to `https://api.openai.com/v1/chat/completions`, credential `revia_openai`.
   - Body:
     ```json
     {
       "model": "gpt-4o",
       "temperature": 0.7,
       "max_tokens": 600,
       "messages": [
         {"role": "system", "content": "{{$json.system}}"},
         {"role": "user", "content": "{{$json.user}}"}
       ]
     }
     ```
   - Retry on error: 3 attempts
8. **Code node: Parse Response** —
   ```javascript
   const response = $input.first().json;
   const text = response.choices[0].message.content;
   let parsed;

   try {
     parsed = JSON.parse(text);
   } catch (e) {
     throw new Error(`OpenAI returned invalid JSON: ${text.slice(0, 200)}`);
   }

   if (!parsed.response_text) {
     throw new Error('Missing response_text in OpenAI response');
   }

   return { json: parsed };
   ```
9. **Postgres node: Insert Response** —
   ```sql
   INSERT INTO app.review_responses (
     review_id, response_text, model, prompt_version, voice_source,
     status, warnings, raw_response
   ) VALUES ($1, $2, $3, $4, $5, 'draft', $6, $7)
   RETURNING id, response_text, warnings;
   ```
10. **Code node: Return Output** — return `{review_id, response_text, warnings, voice_source}`

- [ ] **Step 1: Create workflow via n8n MCP**

Use `n8n-mcp-tools-expert` and `n8n-node-configuration` skills. Create the workflow, set to inactive.

- [ ] **Step 2: Test with one negative review**

Pick a review with sentiment=negative from the dry-run analyses. Execute:
```json
{ "review_id": <id> }
```

Verify: response row created in `app.review_responses`, `voice_source='default_template'` (voice not yet extracted), reasonable draft text.

---

## Block 7: Notifications

### Task 12: revia_send-notification

**Purpose:** Sub-workflow that formats and sends a Telegram notification for one review.

**Input contract:**
```json
{
  "review_id": 101,
  "include_response": true,
  "notification_type": "alert_negative"
}
```

**Output contract:**
```json
{
  "notification_id": 501,
  "sent_at": "2026-04-15T10:00:00Z"
}
```

**Workflow nodes:**

1. **Execute Workflow Trigger** — receives input
2. **Postgres node: Check Already Sent** —
   ```sql
   SELECT id FROM app.notifications_log
   WHERE review_id = $1 AND notification_type = $2;
   ```
   Idempotency: skip if already sent for this review + type.
3. **IF node: Already Sent?** — if exists → return existing
4. **Postgres node: Get Review + Analysis + Response + Client** —
   ```sql
   SELECT r.review_text, r.rating, r.author_name, r.review_created_at,
          ra.sentiment, ra.urgency, ra.categories, ra.summary,
          rr.response_text, rr.warnings,
          c.display_name, c.telegram_chat_id
   FROM app.reviews r
   JOIN app.review_analyses ra ON ra.review_id = r.id
   LEFT JOIN app.review_responses rr ON rr.review_id = r.id
   JOIN app.clients c ON c.id = r.client_id
   WHERE r.id = $1;
   ```
5. **IF node: Has Telegram Chat?** — if `telegram_chat_id` is NULL → dead-letter, alert dev
6. **Code node: Format Message** —
   ```javascript
   const d = $input.first().json;
   const input = $('Execute Workflow Trigger').first().json;

   const sentimentEmoji = {
     ecstatic: '🌟', positive: '👍', neutral: '😐', negative: '👎', aggressive: '🔴'
   };
   const urgencyLabel = {
     low: '', medium: '', high: ' ❗', critical: ' 🚨'
   };

   const stars = d.rating ? '⭐'.repeat(d.rating) : 'Без оценки';
   const icon = sentimentEmoji[d.sentiment] || '📝';
   const urgent = urgencyLabel[d.urgency] || '';

   let msg = `${icon}${urgent} Новый отзыв — ${d.display_name}\n\n`;
   msg += `${stars} от ${d.author_name || 'Аноним'}\n`;
   msg += `📝 ${d.review_text ? d.review_text.slice(0, 400) : '(без текста)'}\n`;
   msg += `\n📊 ${d.categories.join(', ')}`;

   if (input.include_response && d.response_text) {
     msg += `\n\n💬 Черновик ответа:\n${d.response_text}`;
     if (d.warnings && d.warnings.length > 0) {
       msg += `\n\n⚠️ Внимание: ${d.warnings.join(', ')}`;
     }
   }

   return {
     json: {
       text: msg,
       chat_id: d.telegram_chat_id,
       review_id: input.review_id,
       notification_type: input.notification_type,
       client_id: d.client_id
     }
   };
   ```
7. **Telegram node: Send Message** — sends `text` to `chat_id`, credential `revia_telegram_bot`. Retry: 3 attempts.
8. **Code node: Handle Telegram Errors** —
   ```javascript
   // If Telegram returns 403 (blocked) → pause client
   // If 400 (chat not found) → clear chat_id, pause client
   // These are handled by error branch, not here
   const result = $input.first().json;
   return {
     json: {
       telegram_message_id: result.message_id || null,
       status: 'sent'
     }
   };
   ```
9. **Postgres node: Log Notification** —
   ```sql
   INSERT INTO app.notifications_log (
     client_id, review_id, notification_type, telegram_chat_id,
     telegram_message_id, payload, status
   ) VALUES ($1, $2, $3, $4, $5, $6, 'sent')
   RETURNING id, sent_at;
   ```
10. **Code node: Return Output** — return `{notification_id, sent_at}`
11. **Error branch** — on Telegram 403/400: update client status to 'paused', clear chat_id, alert developer.

- [ ] **Step 1: Create workflow via n8n MCP**

Use `n8n-mcp-tools-expert` skill. Create the workflow, set to inactive.

- [ ] **Step 2: Test with a review from dry-run**

Execute with a review that has an analysis and response:
```json
{
  "review_id": <id>,
  "include_response": true,
  "notification_type": "alert_negative"
}
```

Expected: Telegram message received by the bound owner chat. Row in `app.notifications_log`.

---

## Block 8: Hot Path Orchestrator

**Dependencies:** All sub-workflows from Blocks 4-7 must be confirmed working.

### Task 13: revia_poll-reviews

**Purpose:** Orchestrator that runs every 2 hours. Fetches new reviews for all active clients, analyzes them, generates responses for negative/urgent reviews, sends notifications, detects patterns.

**Trigger:** Schedule — every 2 hours

**Workflow nodes:**

1. **Schedule Trigger** — every 2 hours
2. **Code node: Generate Run ID** —
   ```javascript
   const crypto = require('crypto');
   return { json: { run_id: crypto.randomUUID() } };
   ```
3. **Postgres node: Get Active Clients** —
   ```sql
   SELECT id, slug, display_name FROM app.clients WHERE status = 'active';
   ```
4. **Split In Batches** — process clients one at a time (MVP scale)
5. **Postgres node: Log Poll Start** —
   ```sql
   INSERT INTO app.poll_runs (run_id, client_id, triggered_by, status)
   VALUES ($1::uuid, $2, 'schedule', 'running')
   RETURNING id;
   ```
6. **Execute Workflow: revia_scrape-client** — input: `{client_id, mode: "poll"}`
7. **IF node: New Reviews?** — check `new_review_ids.length > 0`
8. (Yes) **Split In Batches: Process Reviews** — for each `review_id` in `new_review_ids`:
   - **Execute Workflow: revia_analyze-review** — input: `{review_id}`
   - **IF node: Needs Response?** — `sentiment IN ('negative', 'aggressive') OR urgency IN ('high', 'critical')`
   - (Yes) **Execute Workflow: revia_generate-response** — input: `{review_id}`
   - (Yes) **Execute Workflow: revia_send-notification** — input: `{review_id, include_response: true, notification_type: sentiment === 'aggressive' || urgency === 'critical' ? 'alert_urgent' : 'alert_negative'}`
   - **IF node: Low Confidence?** — `confidence < 0.7` → skip response, will go to digest
9. **Code node: Pattern Detection** —
   ```javascript
   // After processing all reviews for a client, check for clusters
   const clientId = $('Split In Batches').first().json.id;
   return { json: { client_id: clientId } };
   ```
10. **Postgres node: Check Pattern** —
    ```sql
    SELECT category, COUNT(*) AS cnt
    FROM (
      SELECT unnest(ra.categories) AS category
      FROM app.review_analyses ra
      JOIN app.reviews r ON r.id = ra.review_id
      WHERE r.client_id = $1
        AND ra.analyzed_at > now() - interval '48 hours'
    ) sub
    GROUP BY category
    HAVING COUNT(*) >= 3
    ORDER BY cnt DESC
    LIMIT 1;
    ```
11. **IF node: Pattern Found?** — if row returned with cnt >= 3
12. (Yes) **Execute Workflow: revia_send-notification** — `{review_id: null, include_response: false, notification_type: 'alert_pattern'}` (special pattern alert message, adapt send-notification to handle null review_id for pattern alerts)
13. **Postgres node: Log Poll Complete** —
    ```sql
    UPDATE app.poll_runs
    SET finished_at = now(),
        status = 'success',
        new_reviews_count = $1
    WHERE run_id = $2::uuid AND client_id = $3;
    ```
14. **Error handler** — on any unhandled error: update poll_run to 'failed', write to failed_operations, call revia_alert-developer.

**Note on pattern alerts:** `revia_send-notification` needs a small extension to handle `notification_type = 'alert_pattern'` with no specific `review_id`. The message would say: "⚠️ Паттерн: {count} отзывов за 48ч упоминают «{category}» — проверьте системную проблему." This is a minor Code node branch in revia_send-notification (add an IF at the top: if notification_type === 'alert_pattern' → format pattern message instead of review message).

- [ ] **Step 1: Extend revia_send-notification for pattern alerts**

Add an IF node early in the workflow: if `notification_type === 'alert_pattern'`, route to a separate Code node that formats a pattern alert message (no review data needed), then to the same Telegram send + log nodes.

Pattern alert message format:
```javascript
const d = $input.first().json;
const msg = `⚠️ Паттерн обнаружен — ${d.display_name}\n\n` +
  `За последние 48 часов ${d.count} отзывов упоминают категорию «${d.category}».\n` +
  `Это может указывать на системную проблему. Проверьте!`;
```

- [ ] **Step 2: Create revia_poll-reviews workflow via n8n MCP**

Create the orchestrator workflow with all nodes. Set to **inactive** (will be activated at go-live).

---

### Task 14: End-to-End Dry Run

- [ ] **Step 1: Execute revia_poll-reviews manually (one-shot)**

Trigger the workflow manually. It should:
1. Find Lou Lou as active client
2. Call revia_scrape-client (may find 0 new reviews if recent scrape was just done)
3. Analyze any new reviews
4. Generate responses for negative/urgent ones
5. Send notifications

- [ ] **Step 2: Verify full pipeline**

```sql
-- Reviews
SELECT COUNT(*) AS total_reviews FROM app.reviews
WHERE client_id = (SELECT id FROM app.clients WHERE slug = 'lou-lou-astana');

-- Analyses
SELECT COUNT(*) AS total_analyses FROM app.review_analyses ra
JOIN app.reviews r ON r.id = ra.review_id
WHERE r.client_id = (SELECT id FROM app.clients WHERE slug = 'lou-lou-astana');

-- Responses
SELECT COUNT(*) AS total_responses FROM app.review_responses rr
JOIN app.reviews r ON r.id = rr.review_id
WHERE r.client_id = (SELECT id FROM app.clients WHERE slug = 'lou-lou-astana');

-- Notifications
SELECT COUNT(*) AS total_notifications FROM app.notifications_log
WHERE client_id = (SELECT id FROM app.clients WHERE slug = 'lou-lou-astana');

-- Poll run
SELECT * FROM app.poll_runs ORDER BY started_at DESC LIMIT 1;
```

Expected: poll_run with status='success', matching counts.

- [ ] **Step 3: Verify Telegram messages received**

Confirm the Lou Lou owner chat received any alert notifications from the dry run.

---

## Block 9: Onboarding Workflows

### Task 15: revia_extract-voice

**Purpose:** Sub-workflow that learns the brand's voice from existing business replies.

**Input contract:**
```json
{
  "client_id": 1
}
```

**Output contract:**
```json
{
  "client_id": 1,
  "voice_extracted": true,
  "sample_size": 24
}
```

**Workflow nodes:**

1. **Execute Workflow Trigger** — receives `{client_id}`
2. **Postgres node: Check Already Extracted** —
   ```sql
   SELECT voice_extracted_at FROM app.client_profiles WHERE client_id = $1;
   ```
   If `voice_extracted_at` is not NULL → skip, return existing.
3. **Postgres node: Count Business Replies** —
   ```sql
   SELECT COUNT(*) AS reply_count
   FROM app.reviews
   WHERE client_id = $1 AND business_reply_text IS NOT NULL;
   ```
4. **IF node: Enough Replies?** — `reply_count >= 15`
5. (No) → Return `{client_id, voice_extracted: false, sample_size: 0, reason: "insufficient_replies"}`
6. (Yes) **Postgres node: Stratified Sample** —
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
   SELECT id AS review_id, review_text, business_reply_text, sentiment, pool
   FROM ranked
   WHERE (pool = 'A' AND rn <= 12) OR (pool = 'B' AND rn <= 12) OR (pool = 'C' AND rn <= 6);
   ```
7. **Code node: Build Voice Prompt** —
   ```javascript
   const samples = $input.all().map(item => item.json);
   const registry = JSON.parse($getWorkflowStaticData('global').prompts_registry || '{}');
   const tmpl = registry['extract-voice'] || {};

   const clientName = $('Execute Workflow Trigger').first().json.client_name || 'Client';

   const voiceSamples = samples.map(s =>
     `[${s.sentiment}] Review: "${s.review_text?.slice(0, 200) || '(no text)'}"\n→ Reply: "${s.business_reply_text}"`
   ).join('\n\n');

   const userMessage = tmpl.user_template
     .replace('{{sample_count}}', String(samples.length))
     .replace('{{client_name}}', clientName)
     .replace('{{voice_samples}}', voiceSamples);

   return {
     json: {
       system: tmpl.system,
       user: userMessage,
       model: tmpl.model,
       temperature: tmpl.temperature,
       max_tokens: tmpl.max_tokens,
       prompt_version: tmpl.version,
       sample_size: samples.length,
       sample_review_ids: samples.map(s => s.review_id)
     }
   };
   ```
8. **HTTP Request node: Call Anthropic** — same pattern as Task 9, step 6
9. **Code node: Parse Voice Description** — parse JSON, validate structure
10. **Postgres node: Save Voice Description** —
    ```sql
    UPDATE app.client_profiles
    SET voice_description = $1::jsonb,
        voice_sample_size = $2,
        voice_extracted_at = now(),
        updated_at = now()
    WHERE client_id = $3;
    ```
11. **Code node: Save Voice Examples** — insert samples into `app.voice_examples`, mark top 5 as `selected_for_few_shot = true` (2 negative, 2 positive, 1 neutral — the most recent of each).
    ```javascript
    // Build INSERT statements for each sample
    const samples = $('Stratified Sample').all().map(item => item.json);
    // Select few-shot: 2 from pool A, 2 from pool B, 1 from pool C — most recent
    const fewShot = [];
    const poolA = samples.filter(s => ['negative','aggressive'].includes(s.sentiment)).slice(0, 2);
    const poolB = samples.filter(s => ['positive','ecstatic'].includes(s.sentiment)).slice(0, 2);
    const poolC = samples.filter(s => s.sentiment === 'neutral').slice(0, 1);
    fewShot.push(...poolA, ...poolB, ...poolC);
    const fewShotIds = new Set(fewShot.map(s => s.review_id));

    return samples.map(s => ({
      json: {
        client_id: $('Execute Workflow Trigger').first().json.client_id,
        review_id: s.review_id,
        review_text: s.review_text,
        review_sentiment: s.sentiment,
        response_text: s.business_reply_text,
        selected_for_few_shot: fewShotIds.has(s.review_id)
      }
    }));
    ```
12. **Postgres node: Insert Voice Examples** (loop) —
    ```sql
    INSERT INTO app.voice_examples (
      client_id, review_id, review_text, review_sentiment, response_text, selected_for_few_shot
    ) VALUES ($1, $2, $3, $4, $5, $6)
    ON CONFLICT DO NOTHING;
    ```
13. **Code node: Return Output** — `{client_id, voice_extracted: true, sample_size}`

- [ ] **Step 1: Create workflow via n8n MCP**

- [ ] **Step 2: Defer testing to backfill (Task 17)**

Voice extraction requires analyzed reviews with business replies. This is tested as part of the full backfill flow.

---

### Task 16: revia_initial-report

**Purpose:** Sub-workflow that generates and sends the onboarding insights message after backfill.

**Input contract:**
```json
{
  "client_id": 1
}
```

**Workflow nodes:**

1. **Execute Workflow Trigger** — receives `{client_id}`
2. **Postgres node: Check Already Sent** —
   ```sql
   SELECT initial_report_sent_at FROM app.clients WHERE id = $1;
   ```
   If not NULL → skip.
3. **Postgres node: Aggregate Stats** —
   ```sql
   SELECT
     c.display_name,
     c.telegram_chat_id,
     COUNT(r.id) AS total_reviews,
     MIN(r.review_created_at)::date AS date_from,
     MAX(r.review_created_at)::date AS date_to,
     ROUND(AVG(r.rating)::numeric, 2) AS avg_rating,
     ROUND(AVG(CASE WHEN r.review_created_at > now() - interval '30 days' THEN r.rating END)::numeric, 2) AS avg_rating_30d,
     ROUND(AVG(CASE WHEN r.review_created_at BETWEEN now() - interval '60 days' AND now() - interval '30 days' THEN r.rating END)::numeric, 2) AS avg_rating_prev_30d,
     jsonb_object_agg(
       COALESCE(ra.sentiment::text, 'unknown'),
       sentiment_counts.cnt
     ) FILTER (WHERE sentiment_counts.cnt IS NOT NULL) AS sentiment_distribution
   FROM app.clients c
   JOIN app.reviews r ON r.client_id = c.id
   JOIN app.review_analyses ra ON ra.review_id = r.id
   LEFT JOIN LATERAL (
     SELECT ra2.sentiment, COUNT(*) AS cnt
     FROM app.review_analyses ra2
     JOIN app.reviews r2 ON r2.id = ra2.review_id
     WHERE r2.client_id = c.id
     GROUP BY ra2.sentiment
   ) sentiment_counts ON sentiment_counts.sentiment = ra.sentiment
   WHERE c.id = $1
   GROUP BY c.id, c.display_name, c.telegram_chat_id;
   ```
   Note: this query may need adjustment during implementation. The key aggregates are: total_reviews, avg_rating, date range, sentiment distribution.

4. **Postgres node: Top Complaints** —
   ```sql
   SELECT category, COUNT(*) AS cnt
   FROM (
     SELECT unnest(ra.categories) AS category
     FROM app.review_analyses ra
     JOIN app.reviews r ON r.id = ra.review_id
     WHERE r.client_id = $1 AND ra.sentiment IN ('negative', 'aggressive')
   ) sub
   GROUP BY category ORDER BY cnt DESC LIMIT 5;
   ```
5. **Postgres node: Top Praises** —
   ```sql
   SELECT category, COUNT(*) AS cnt
   FROM (
     SELECT unnest(ra.categories) AS category
     FROM app.review_analyses ra
     JOIN app.reviews r ON r.id = ra.review_id
     WHERE r.client_id = $1 AND ra.sentiment IN ('positive', 'ecstatic')
   ) sub
   GROUP BY category ORDER BY cnt DESC LIMIT 5;
   ```
6. **Postgres node: Sample Quotes (negative)** —
   ```sql
   SELECT r.review_text FROM app.reviews r
   JOIN app.review_analyses ra ON ra.review_id = r.id
   WHERE r.client_id = $1 AND ra.sentiment IN ('negative', 'aggressive')
     AND r.review_text IS NOT NULL AND length(r.review_text) > 30
   ORDER BY r.review_created_at DESC LIMIT 3;
   ```
7. **Postgres node: Sample Quotes (positive)** —
   ```sql
   SELECT r.review_text FROM app.reviews r
   JOIN app.review_analyses ra ON ra.review_id = r.id
   WHERE r.client_id = $1 AND ra.sentiment IN ('positive', 'ecstatic')
     AND r.review_text IS NOT NULL AND length(r.review_text) > 30
   ORDER BY r.review_created_at DESC LIMIT 3;
   ```
8. **Postgres node: Unanswered Negatives Count** —
   ```sql
   SELECT COUNT(*) AS cnt FROM app.reviews r
   JOIN app.review_analyses ra ON ra.review_id = r.id
   WHERE r.client_id = $1
     AND ra.sentiment IN ('negative', 'aggressive')
     AND r.business_reply_text IS NULL;
   ```
9. **Postgres node: Voice Status** —
   ```sql
   SELECT voice_extracted_at, voice_sample_size FROM app.client_profiles WHERE client_id = $1;
   ```
10. **Code node: Build Report Prompt** — assemble all aggregated data into the `initial-report` prompt template variables.
11. **HTTP Request node: Call OpenAI** — GPT-4o, same pattern as Task 11
12. **Code node: Extract Report Text** — parse response, get plain text (not JSON for this prompt)
13. **Telegram node: Send Report** — send report text to client's `telegram_chat_id`
14. **Postgres node: Mark Report Sent** —
    ```sql
    UPDATE app.clients SET initial_report_sent_at = now(), updated_at = now() WHERE id = $1;
    ```
15. **Postgres node: Log Notification** —
    ```sql
    INSERT INTO app.notifications_log (
      client_id, review_id, notification_type, telegram_chat_id,
      telegram_message_id, payload, status
    ) VALUES ($1, NULL, 'initial_report', $2, $3, $4, 'sent');
    ```
16. **5 Most Recent Unanswered Negatives** — after report, generate responses for the 5 freshest unanswered negatives:
    ```sql
    SELECT r.id FROM app.reviews r
    JOIN app.review_analyses ra ON ra.review_id = r.id
    LEFT JOIN app.review_responses rr ON rr.review_id = r.id
    WHERE r.client_id = $1
      AND ra.sentiment IN ('negative', 'aggressive')
      AND r.business_reply_text IS NULL
      AND rr.id IS NULL
    ORDER BY r.review_created_at DESC
    LIMIT 5;
    ```
17. For each → **Execute Workflow: revia_generate-response** then **Execute Workflow: revia_send-notification** with `notification_type: 'alert_negative'`

- [ ] **Step 1: Create workflow via n8n MCP**

- [ ] **Step 2: Defer testing to backfill (Task 17)**

---

### Task 17: revia_backfill-client

**Purpose:** Orchestrator for one-time client onboarding. Runs the full pipeline: scrape all → analyze all → extract voice → generate initial report.

**Input contract (manual trigger):**
```json
{
  "client_id": 1
}
```

**Workflow nodes:**

1. **Manual Trigger** — with input field `client_id`
2. **Postgres node: Verify Client** —
   ```sql
   SELECT id, slug, display_name, status, telegram_chat_id, initial_report_sent_at
   FROM app.clients WHERE id = $1 AND status = 'active';
   ```
3. **IF node: Valid Client?** — exists and active
4. **IF node: Already Backfilled?** — `initial_report_sent_at IS NOT NULL` → warn and stop (or allow re-run with confirmation)
5. **Postgres node: Log Backfill Start** —
   ```sql
   INSERT INTO app.poll_runs (run_id, client_id, triggered_by, status)
   VALUES (gen_random_uuid(), $1, 'backfill', 'running')
   RETURNING id, run_id;
   ```
6. **Execute Workflow: revia_scrape-client** — `{client_id, mode: "backfill"}`
7. **Code node: Log Scrape Results** — log `new_review_ids.length` reviews scraped
8. **Split In Batches: Analyze All Reviews** — for each `review_id`:
   - **Execute Workflow: revia_analyze-review** — `{review_id}`
   - Batch size: 10 (to avoid overwhelming the API)
9. **Execute Workflow: revia_extract-voice** — `{client_id}`
10. **Execute Workflow: revia_initial-report** — `{client_id}`
11. **Postgres node: Log Backfill Complete** —
    ```sql
    UPDATE app.poll_runs
    SET finished_at = now(), status = 'success', new_reviews_count = $1
    WHERE run_id = $2::uuid;
    ```
12. **Execute Workflow: revia_alert-developer** — success notification:
    ```json
    {
      "alert_type": "system",
      "message": "Backfill complete for client {display_name}. {count} reviews analyzed.",
      "workflow_name": "revia_backfill-client",
      "client_id": 1
    }
    ```
13. **Error handler** — on failure: update poll_run to 'failed', alert developer with error details. If backfill exceeds 1 hour, alert.

- [ ] **Step 1: Create workflow via n8n MCP**

- [ ] **Step 2: Test — will be the actual Lou Lou backfill in Block 11**

The backfill workflow is the main go-live action. It will be tested with real data in Task 20.

---

## Block 10: Scheduled Workflows

### Task 18: revia_daily-digest

**Purpose:** Send morning (09:00) and evening (21:00) digest summaries to each active client via Telegram.

**Trigger:** Schedule — cron `0 9,21 * * *` in `Asia/Almaty`

**Workflow nodes:**

1. **Schedule Trigger** — 09:00 and 21:00 Asia/Almaty
2. **Postgres node: Get Active Clients** —
   ```sql
   SELECT id, display_name, telegram_chat_id, timezone
   FROM app.clients
   WHERE status = 'active' AND telegram_chat_id IS NOT NULL;
   ```
3. **Split In Batches** — per client
4. **Code node: Determine Digest Type** —
   ```javascript
   const now = new Date();
   // Convert to client timezone to determine morning/evening
   const hour = parseInt(now.toLocaleString('en-US', {
     timeZone: $input.first().json.timezone || 'Asia/Almaty',
     hour: 'numeric', hour12: false
   }));
   const isMorning = hour < 15; // 09:00 trigger = morning, 21:00 trigger = evening
   const isSunday = now.toLocaleString('en-US', {
     timeZone: $input.first().json.timezone || 'Asia/Almaty',
     weekday: 'long'
   }) === 'Sunday';

   return {
     json: {
       ...($input.first().json),
       digest_type: isMorning ? 'morning' : 'evening',
       include_weekly: isSunday && !isMorning, // Sunday evening = weekly section
       notification_type: isMorning ? 'digest_morning' : 'digest_evening'
     }
   };
   ```
5. **Postgres node: Get 24h Stats** —
   ```sql
   SELECT
     COUNT(*) AS reviews_24h,
     ROUND(AVG(r.rating)::numeric, 2) AS avg_rating_24h,
     COUNT(*) FILTER (WHERE ra.sentiment IN ('negative', 'aggressive')) AS negative_24h,
     COUNT(*) FILTER (WHERE ra.sentiment IN ('positive', 'ecstatic')) AS positive_24h
   FROM app.reviews r
   JOIN app.review_analyses ra ON ra.review_id = r.id
   WHERE r.client_id = $1 AND r.ingested_at > now() - interval '24 hours';
   ```
6. **Postgres node: Trend Check** —
   ```sql
   SELECT
     ROUND(AVG(CASE WHEN r.review_created_at > now() - interval '7 days' THEN r.rating END)::numeric, 2) AS avg_7d,
     ROUND(AVG(CASE WHEN r.review_created_at > now() - interval '30 days' THEN r.rating END)::numeric, 2) AS avg_30d
   FROM app.reviews r
   WHERE r.client_id = $1;
   ```
7. **Postgres node: Low Confidence Reviews** —
   ```sql
   SELECT r.id, r.review_text, r.rating, ra.sentiment, ra.confidence
   FROM app.reviews r
   JOIN app.review_analyses ra ON ra.review_id = r.id
   WHERE r.client_id = $1 AND ra.confidence < 0.7
     AND ra.analyzed_at > now() - interval '24 hours';
   ```
8. **IF node: Include Weekly?** — if `include_weekly` is true:
   - **Postgres node: Marketing Assets** —
     ```sql
     SELECT r.review_text, r.author_name, r.rating
     FROM app.reviews r
     WHERE r.client_id = $1 AND r.rating >= 4
       AND r.review_text IS NOT NULL AND length(r.review_text) > 100
       AND r.review_created_at > now() - interval '7 days'
     ORDER BY r.rating DESC, length(r.review_text) DESC
     LIMIT 3;
     ```
9. **Code node: Format Digest** —
   ```javascript
   const stats = $('Get 24h Stats').first().json;
   const trend = $('Trend Check').first().json;
   const lowConf = $('Low Confidence Reviews').all().map(i => i.json);
   const digest = $('Determine Digest Type').first().json;
   const isMorning = digest.digest_type === 'morning';

   let msg = isMorning
     ? `☀️ Доброе утро, ${digest.display_name}!\n\n`
     : `🌙 Вечерний дайджест — ${digest.display_name}\n\n`;

   msg += `📊 За последние 24 часа:\n`;
   msg += `• Новых отзывов: ${stats.reviews_24h}\n`;
   msg += `• Средний рейтинг: ${stats.avg_rating_24h || 'N/A'}\n`;
   msg += `• 👍 ${stats.positive_24h} / 👎 ${stats.negative_24h}\n`;

   // Trend alert
   if (trend.avg_7d && trend.avg_30d) {
     const diff = parseFloat(trend.avg_7d) - parseFloat(trend.avg_30d);
     if (Math.abs(diff) >= 0.3) {
       msg += `\n${diff > 0 ? '📈' : '📉'} Тренд: рейтинг за 7 дней ${diff > 0 ? 'выше' : 'ниже'} среднего за 30 дней на ${Math.abs(diff).toFixed(1)}\n`;
     }
   }

   // Low confidence items
   if (lowConf.length > 0) {
     msg += `\n❓ Отзывы с низкой уверенностью ИИ (${lowConf.length}) — проверьте вручную\n`;
   }

   // Weekly marketing (Sunday evening only)
   if (digest.include_weekly) {
     const assets = $('Marketing Assets').all().map(i => i.json);
     if (assets.length > 0) {
       msg += `\n🏆 Лучшие отзывы недели (для маркетинга):\n`;
       assets.forEach((a, i) => {
         msg += `\n${i + 1}. ⭐${a.rating} ${a.author_name || 'Аноним'}: "${a.review_text.slice(0, 150)}..."\n`;
       });
     }
   }

   return {
     json: {
       text: msg,
       chat_id: digest.telegram_chat_id,
       client_id: digest.id,
       notification_type: digest.notification_type
     }
   };
   ```
10. **Telegram node: Send Digest** — send `text` to `chat_id`
11. **Postgres node: Log Notification** — insert into `notifications_log`
12. **Error handler** — on failure: alert developer with `digest_missed`

- [ ] **Step 1: Create workflow via n8n MCP**

Set to inactive. Will be activated at go-live.

- [ ] **Step 2: Test with manual trigger**

Run the digest manually once to verify formatting. Confirm Telegram message received.

---

### Task 19: revia_retry-failed-operations

**Purpose:** Hourly cron that retries dead-lettered operations.

**Trigger:** Schedule — every 1 hour

**Workflow nodes:**

1. **Schedule Trigger** — every 1 hour
2. **Postgres node: Get Unresolved Operations** —
   ```sql
   SELECT id, workflow_name, client_id, entity_type, entity_id,
          input_payload, error_text, attempts
   FROM app.failed_operations
   WHERE resolved_at IS NULL AND attempts < 5
   ORDER BY first_failed_at ASC
   LIMIT 20;
   ```
3. **IF node: Any to retry?** — if rows returned
4. **Split In Batches** — per failed operation
5. **Switch node: Route by Workflow** — based on `workflow_name`:
   - `revia_scrape-client` → Execute Workflow: revia_scrape-client with `input_payload`
   - `revia_analyze-review` → Execute Workflow: revia_analyze-review with `input_payload`
   - `revia_generate-response` → Execute Workflow: revia_generate-response with `input_payload`
   - `revia_send-notification` → Execute Workflow: revia_send-notification with `input_payload`
6. **On success:** Postgres node: Mark Resolved —
   ```sql
   UPDATE app.failed_operations
   SET resolved_at = now(), resolved_by = 'auto_retry'
   WHERE id = $1;
   ```
7. **On failure:** Postgres node: Increment Attempts —
   ```sql
   UPDATE app.failed_operations
   SET attempts = attempts + 1,
       last_failed_at = now(),
       error_text = $1
   WHERE id = $2;
   ```
8. **Postgres node: Check Abandoned** —
   ```sql
   UPDATE app.failed_operations
   SET resolved_at = now(), resolved_by = 'abandoned'
   WHERE resolved_at IS NULL AND attempts >= 5
   RETURNING id, workflow_name, client_id, error_text;
   ```
9. **IF node: Any Abandoned?** — if rows returned
10. (Yes) **Execute Workflow: revia_alert-developer** — alert about abandoned operations
11. **Postgres node: Check Threshold** —
    ```sql
    SELECT COUNT(*) AS unresolved FROM app.failed_operations WHERE resolved_at IS NULL;
    ```
12. **IF node: Threshold Exceeded?** — if `unresolved > 10`
13. (Yes) **Execute Workflow: revia_alert-developer** — `failed_ops_threshold` alert

- [ ] **Step 1: Create workflow via n8n MCP**

Set to inactive. Will be activated at go-live.

- [ ] **Step 2: Verify by manually inserting a test failed operation**

```sql
INSERT INTO app.failed_operations (
  workflow_name, client_id, entity_type, entity_id,
  input_payload, error_text, attempts
) VALUES (
  'revia_analyze-review',
  (SELECT id FROM app.clients WHERE slug = 'lou-lou-astana'),
  'review', 1,
  '{"review_id": 1}'::jsonb,
  'Test error — retry test', 0
);
```

Run the retry workflow. Check: if review 1 exists and can be analyzed, the failed operation should be resolved. If not, attempts should increment.

---

## Block 11: Go Live

**Dependencies needed from user:**
- All 12 workflows confirmed working (Blocks 3–10)
- Lou Lou owner consent
- Owner has /start'ed the Telegram bot (verified in Block 3, Task 6)

### Task 20: Run Backfill for Lou Lou

- [ ] **Step 1: Pre-flight check**

```sql
-- Verify client ready
SELECT c.slug, c.status, c.telegram_chat_id IS NOT NULL AS bot_bound,
       c.initial_report_sent_at IS NULL AS needs_backfill,
       cs.source_url
FROM app.clients c
JOIN app.client_sources cs ON cs.client_id = c.id
WHERE c.slug = 'lou-lou-astana';
```

Expected: status=active, bot_bound=true, needs_backfill=true, valid source_url.

- [ ] **Step 2: Execute revia_backfill-client**

Run with `{"client_id": 1}`. This will:
1. Scrape all ~900 historical reviews (est. 5-15 min)
2. Analyze each review with Haiku (est. 15-30 min for 900 reviews)
3. Extract voice from business replies (if ≥15 replies exist)
4. Generate and send initial report
5. Generate responses for 5 most recent unanswered negatives
6. Send those 5 responses as notifications

**Monitor progress:** Check poll_runs table and developer Telegram for alerts.

- [ ] **Step 3: Verify backfill results**

```sql
SELECT
  (SELECT COUNT(*) FROM app.reviews WHERE client_id = 1) AS total_reviews,
  (SELECT COUNT(*) FROM app.review_analyses ra JOIN app.reviews r ON r.id = ra.review_id WHERE r.client_id = 1) AS total_analyses,
  (SELECT COUNT(*) FROM app.review_responses rr JOIN app.reviews r ON r.id = rr.review_id WHERE r.client_id = 1) AS total_responses,
  (SELECT voice_extracted_at IS NOT NULL FROM app.client_profiles WHERE client_id = 1) AS voice_extracted,
  (SELECT initial_report_sent_at IS NOT NULL FROM app.clients WHERE id = 1) AS report_sent,
  (SELECT COUNT(*) FROM app.failed_operations WHERE client_id = 1 AND resolved_at IS NULL) AS unresolved_errors;
```

Expected: ~900 reviews, ~900 analyses, 5 responses, voice_extracted=true (if ≥15 replies), report_sent=true, unresolved_errors=0.

---

### Task 21: Activate Scheduled Workflows

- [ ] **Step 1: Activate revia_poll-reviews**

Via n8n MCP: set active=true. Confirm cron is every 2 hours.

- [ ] **Step 2: Activate revia_daily-digest**

Via n8n MCP: set active=true. Confirm cron is 09:00, 21:00 Asia/Almaty.

- [ ] **Step 3: Activate revia_retry-failed-operations**

Via n8n MCP: set active=true. Confirm cron is every 1 hour.

- [ ] **Step 4: Verify all active workflows**

List all workflows via n8n MCP. Confirm exactly these are active:
- `revia_poll-reviews` (every 2h)
- `revia_daily-digest` (09:00, 21:00)
- `revia_retry-failed-operations` (every 1h)
- `revia_telegram-router` (webhook)

All others should be inactive (they run via Execute Workflow from orchestrators).

---

### Task 22: Verify End-to-End and Contact Owner

- [ ] **Step 1: Wait for next poll cycle**

After activation, wait for the next 2-hour poll. Verify:
```sql
SELECT * FROM app.poll_runs ORDER BY started_at DESC LIMIT 1;
```
Expected: status='success'.

- [ ] **Step 2: Verify first digest**

After 09:00 or 21:00, check:
```sql
SELECT * FROM app.notifications_log
WHERE notification_type IN ('digest_morning', 'digest_evening')
ORDER BY sent_at DESC LIMIT 1;
```

- [ ] **Step 3: Contact Lou Lou owner**

Confirm they received:
- The initial report
- Any real-time alerts for negative reviews
- The first digest

Ask for feedback. Schedule follow-up in 5 days for success criteria evaluation.

- [ ] **Step 4: Monitor first 24 hours**

Check:
```sql
-- Any failures?
SELECT * FROM app.failed_operations WHERE resolved_at IS NULL;

-- Poll runs healthy?
SELECT status, COUNT(*) FROM app.poll_runs GROUP BY status;

-- Review volume as expected?
SELECT DATE(ingested_at), COUNT(*) FROM app.reviews WHERE client_id = 1 GROUP BY DATE(ingested_at) ORDER BY 1 DESC;
```

---

## Success Criteria (from spec — Day 5 check)

After 5 days of operation, verify:
- [ ] ≥ 1 real-time notification delivered with reasonable draft reply
- [ ] ≥ 5 daily digests delivered
- [ ] ≥ 1 response published by owner (even heavily edited)
- [ ] Failed operations < 5%
- [ ] Apify cost < $5/week
- [ ] AI cost < $5/week
- [ ] Owner expresses interest in continuing
