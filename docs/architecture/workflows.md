# REVIA — Workflow Architecture

## System Overview

```mermaid
architecture-beta
    group triggers[Triggers]
    group pipeline[Core Pipeline]
    group support[Support Workflows]
    group external[External Services]
    group db[Database]

    service sched(server)[Scheduler 6h] in triggers
    service dsched(server)[Digest 9am+9pm] in triggers
    service rsched(server)[Retry 1h] in triggers
    service tg_in(internet)[Telegram In] in triggers
    service manual(user)[Manual Backfill] in triggers

    service poll(server)[poll-reviews] in pipeline
    service scrape(server)[scrape-client] in pipeline
    service analyze(server)[analyze-review] in pipeline
    service generate(server)[generate-response] in pipeline
    service notify(server)[send-notification] in pipeline
    service router(server)[telegram-router] in pipeline

    service backfill(server)[backfill-client] in support
    service digest(server)[daily-digest] in support
    service retry(server)[retry-failed] in support
    service extract(server)[extract-voice] in support
    service report(server)[initial-report] in support

    service apify(cloud)[Apify 2gis] in external
    service claude(cloud)[Claude Haiku] in external
    service gpt(cloud)[GPT-4o] in external
    service tgbot(internet)[Telegram Bot] in external

    service reviews(database)[reviews] in db
    service analyses(database)[analyses] in db
    service responses(database)[responses] in db
    service logs(database)[notifications_log] in db
    service sources(database)[client_sources] in db
    service voice(database)[voice_examples] in db

    sched:R -- L:poll
    dsched:R -- L:digest
    rsched:R -- L:retry
    tg_in:R -- L:router
    manual:R -- L:backfill

    poll:R -- L:scrape
    scrape:R -- L:apify
    scrape:B -- T:reviews
    scrape:B -- T:sources

    poll:B -- T:analyze
    analyze:R -- L:claude
    analyze:B -- T:analyses

    generate:R -- L:gpt
    generate:B -- T:responses

    notify:R -- L:tgbot
    notify:B -- T:logs

    router:B -- T:responses

    backfill:R -- L:scrape
    backfill:B -- T:extract
    backfill:B -- T:report

    extract:R -- L:claude
    extract:B -- T:voice

    digest:R -- L:tgbot
    digest:B -- T:logs

    retry:B -- T:analyze
```

---

## Core Pipeline Step by Step

```mermaid
architecture-beta
    group step1[Step 1 - Scrape]
    group step2[Step 2 - Analyze]
    group step3[Step 3 - Generate]
    group step4[Step 4 - Notify]

    service scrape(server)[scrape-client] in step1
    service apify(cloud)[Apify 2gis] in step1
    service reviews(database)[reviews] in step1

    service analyze(server)[analyze-review] in step2
    service claude(cloud)[Claude Haiku] in step2
    service analyses(database)[analyses] in step2

    service generate(server)[generate-response] in step3
    service gpt(cloud)[GPT-4o] in step3
    service responses(database)[responses draft] in step3

    service notify(server)[send-notification] in step4
    service tg(internet)[Telegram Bot] in step4
    service logs(database)[notifications_log] in step4

    scrape:R -- L:apify
    scrape:B -- T:reviews
    reviews:R -- L:analyze
    analyze:R -- L:claude
    analyze:B -- T:analyses
    analyses:R -- L:generate
    generate:R -- L:gpt
    generate:B -- T:responses
    responses:R -- L:notify
    notify:R -- L:tg
    notify:B -- T:logs
```

---

## Workflow Registry

| Workflow | ID | Active | Trigger | Purpose |
|---|---|---|---|---|
| revia_scheduler | 1bzmpoL6GdMLHlAr | yes | Every 6h | Calls poll-reviews |
| revia_poll-reviews | t327SLYCaZgZG4MB | yes | Sub-workflow | Scrape, Analyze, Generate, Notify |
| revia_scrape-client | aIqrdTjyIm2gwgui | yes | Sub-workflow | Apify to DB upsert |
| revia_analyze-review | PiMpRkygBWlQY9rx | yes | Sub-workflow | Claude Haiku analysis |
| revia_generate-response | oe39wGipYMPt06ZG | yes | Sub-workflow | GPT-4o draft response |
| revia_send-notification | WOtxSuh5irqgdaZ6 | yes | Sub-workflow | Telegram + log |
| revia_telegram-router | 5Kk80kmGOZPXPpOH | yes | Webhook | /start /help /status + callbacks |
| revia_alert-developer | 8N0KQRBX4rV7zJNY | no | Sub-workflow | System alerts to Telegram |
| revia_extract-voice | k0KPm6lHIZ1apa1F | no | Sub-workflow | Brand voice extraction |
| revia_initial-report | 18LA57nPvAmX7PQ0 | no | Sub-workflow | First-time client report |
| revia_backfill-client | Ag0L9Jee3lqMOktp | no | Manual | One-time full backfill |
| revia_daily-digest | GvmwMjjEJHT3rMXz | yes | 09:00 + 21:00 | Morning/evening digest |
| revia_retry-failed-ops | kyz3Fdu0UYWWQIxh | no | Every 1h | Retry broken pipeline items |

---

## Key Design Decisions

- **Micro-workflows**: each step is an isolated sub-workflow, callable independently and safe to retry
- **Dedup**: `ON CONFLICT (client_id, platform, external_review_id) DO NOTHING` prevents duplicate reviews
- **batchMode: single**: Execute Workflow nodes call sub-workflows one item at a time
- **alwaysOutputData**: Postgres nodes that may return 0 rows use this flag to keep pipeline running
- **Timezone**: all schedules in Asia/Almaty (UTC+5), stored as timestamptz in DB
