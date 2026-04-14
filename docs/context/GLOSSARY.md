# REVIA — Glossary

## Product terms

| Term | Meaning |
|---|---|
| REVIA | The product brand name. Region-agnostic, derived from "review". |
| Pilot | The first real client (Lou Lou) used to validate the product before sales. |
| Backfill | One-time import of all historical reviews for a new client, with AI analysis. |
| Initial Report | The onboarding message sent to the owner after backfill — historical insights + top unanswered negatives with draft replies. |
| Voice extraction | Process of analyzing a business's existing replies to learn their tone, structure, and characteristic phrases for AI to mimic. |
| Voice description | Structured JSON output of voice extraction, stored in `client_profiles.voice_description`. |
| Few-shot examples | 5 real review-reply pairs selected from client history, used as examples in the response generation prompt. |
| Daily digest | Automated Telegram summary sent at 09:00 and 21:00 with review stats and items needing attention. |
| Dead letter | A failed operation saved with full input payload for automatic retry later. Stored in `failed_operations` table. |

## Technical terms

| Term | Meaning |
|---|---|
| Sub-workflow | An n8n workflow called via Execute Workflow node from an orchestrator. Has defined input/output JSON contract. |
| Orchestrator | A workflow that chains sub-workflows (e.g. `revia_poll-reviews`, `revia_backfill-client`). Only orchestrators know the execution order. |
| Idempotent | A sub-workflow that can be called multiple times with the same input without creating duplicates or side effects. |
| Incremental scrape | Polling only reviews newer than `last_review_date`, via Apify's server-side date filter. |
| Stratified sampling | Selecting voice examples proportionally across sentiment categories (40% negative / 40% positive / 20% neutral) rather than randomly. |
| Prompt version | A string like `v1`, `v2` stored alongside every AI result, tracking which prompt text produced it. |

## Naming conventions

| Resource | Convention | Example |
|---|---|---|
| Database | `<brand>_<purpose>` | `revia_reviews_hub` |
| DB schema | `app` | `app.reviews` |
| n8n workflow | `revia_<name>` | `revia_poll-reviews` |
| n8n credential | `revia_<service>` | `revia_apify` |
| Project folder | `<brand>` | `c:\CursorDev\revia\` |

## Workflow inventory (12 workflows)

| # | Name | Type | Trigger |
|---|---|---|---|
| 1 | `revia_poll-reviews` | Orchestrator | Schedule (every 2h) |
| 2 | `revia_scrape-client` | Sub-workflow | Execute Workflow |
| 3 | `revia_analyze-review` | Sub-workflow | Execute Workflow |
| 4 | `revia_generate-response` | Sub-workflow | Execute Workflow |
| 5 | `revia_send-notification` | Sub-workflow | Execute Workflow |
| 6 | `revia_daily-digest` | Standalone | Schedule (09:00, 21:00) |
| 7 | `revia_backfill-client` | Orchestrator | Manual trigger |
| 8 | `revia_telegram-router` | Standalone | Webhook |
| 9 | `revia_extract-voice` | Sub-workflow | Execute Workflow |
| 10 | `revia_initial-report` | Sub-workflow | Execute Workflow |
| 11 | `revia_retry-failed-operations` | Standalone | Schedule (every 1h) |
| 12 | `revia_alert-developer` | Sub-workflow | Execute Workflow |
