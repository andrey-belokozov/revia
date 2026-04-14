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
  timezone               text NOT NULL DEFAULT 'Etc/GMT-5',
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
  id                bigserial PRIMARY KEY,
  review_id         bigint NOT NULL UNIQUE REFERENCES app.reviews(id) ON DELETE CASCADE,
  sentiment         app.sentiment NOT NULL,
  urgency           app.urgency NOT NULL,
  categories        text[] NOT NULL,
  detected_language text NOT NULL,
  summary           text,
  pii_detected      boolean NOT NULL DEFAULT false,
  confidence        real,
  model             text NOT NULL,
  prompt_version    text NOT NULL,
  analyzed_at       timestamptz NOT NULL DEFAULT now(),
  raw_response      jsonb
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
