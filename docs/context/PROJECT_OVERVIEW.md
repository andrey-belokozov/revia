# REVIA — Project Overview

## What is REVIA

REVIA is a B2B SaaS product that monitors online reviews for local businesses, analyzes them with AI, generates draft replies in the brand's own voice, and delivers real-time alerts and daily digests via Telegram.

## Brand

- **Name:** REVIA
- **Domain:** revia.kz (verified available 2026-04-11)
- **Region-agnostic:** the name was chosen specifically to avoid tying the product to Kazakhstan, enabling future expansion

## Business context

The founder is an n8n automation engineer in Kazakhstan, experienced with n8n but launching his first business. REVIA is his first commercial SaaS product.

The KZ market is ripe for this: businesses rely on 2GIS and Google Maps reviews, but almost nobody monitors them systematically. n8n specialists in KZ are extremely rare. AI + automation is the hottest sell in 2026. The competitive window is open.

## Business model

SaaS subscription via Telegram:
- **Setup fee:** 50–100K KZT per client (one-time)
- **Monthly tiers:** 30K / 50K / 80K KZT (basic / standard / premium)
- **Unit economics:** ~2–4K KZT cost per client → 85–95% margin
- **Infrastructure:** one VPS hosts 30–50 clients at ~15K KZT/month total

## Current state

**Phase:** MVP brainstorm complete, design spec being written (2026-04-14)

**Pilot client:** Lou Lou restaurant, Astana (~900 existing reviews on 2GIS)

**MVP scope:** single client, 2GIS only (+ Flamp if available), 1–2 weeks to working version

## Technology stack

| Component | Choice |
|---|---|
| Automation platform | n8n (self-hosted on Azure Ubuntu VM) |
| Database | Azure PostgreSQL PaaS, db `revia_reviews_hub`, schema `app` |
| Scraper | Apify actor `zen-studio/2gis-reviews-scraper` |
| Classification AI | Claude Haiku 4.5 |
| Response generation AI | GPT-4o |
| Client interface | Telegram Bot |
| Prompt storage | File `prompts/registry.json` in repo |

## Key product differentiators

1. **Voice extraction** — learns the brand's reply style from historical business replies and generates responses that sound like the owner, not like a generic bot
2. **Initial insights report** — on day 1 of onboarding, delivers a full reputation snapshot with historical analysis, not a blank dashboard
3. **Pattern detection** — detects clusters of similar complaints and alerts the owner about systemic issues, not just individual reviews
4. **Marketing asset extraction** — automatically identifies the best positive reviews for marketing use
