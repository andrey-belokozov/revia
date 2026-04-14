# REVIA — Reviews Monitoring SaaS

REVIA is a B2B SaaS for monitoring online reviews of local businesses, analyzing them with AI, generating draft replies, and pushing notifications and digests to owners via Telegram. The first pilot client is the Lou Lou restaurant in Astana, Kazakhstan. The brand is region-agnostic so the product can grow beyond Kazakhstan.

## How to work in this repository

The user (founder) is an n8n automation engineer with solid n8n experience. He has not run a business before and explicitly asked Claude to act as **PM / Product Manager** for this project — plan steps, recommend, push back on scope creep, ask the right questions, keep focus on shipping a sellable pilot.

When you start a session in this repo, **before doing anything else**, read:
1. `docs/context/PROJECT_OVERVIEW.md` — what REVIA is and the business context
2. `docs/context/DECISIONS.md` — log of every locked-in design decision with rationale
3. `docs/context/GLOSSARY.md` — terms, conventions, naming standards
4. The most recent file in `docs/superpowers/specs/` — current design spec
5. The most recent file in `docs/superpowers/plans/` — current implementation plan if any

These are the canonical source of truth for project context. Local Claude memory (under `.claude/projects/`) is a cache — when in doubt, re-read the docs above.

## Implementation process

- **Use n8n skills** (n8n-code-javascript, n8n-expression-syntax, n8n-mcp-tools-expert, n8n-node-configuration, n8n-validation-expert, n8n-workflow-patterns) when building n8n workflows. Always invoke the relevant skill before designing or configuring nodes.
- **Step-by-step execution plan, one block at a time.** Present each implementation block clearly: what it does, what it needs from the user (API keys, MCP access, URLs, etc.), and what "done" looks like. Do NOT proceed to the next block until the current one is confirmed working. The user provides external dependencies (credentials, access, URLs) at the moment each block needs them — not upfront.
- **Transparency at every step.** Before starting a block, state what will happen. After completing it, state what was done and what comes next. The user must always understand what is done and what is happening now.

## Critical conventions (apply without asking)

- **n8n workflows** use the `revia_` prefix, single underscore (e.g. `revia_poll-reviews`)
- **n8n credentials** use the `revia_` prefix (e.g. `revia_apify`, `revia_anthropic`)
- **Database**: `revia_reviews_hub` on Azure PostgreSQL PaaS, schema `app`
- **Workflow architecture**: micro-workflows with sub-workflow calls (Approach 2 — sub-workflows are isolated, only orchestrators chain them)
- **Idempotency**: every sub-workflow must be safe to retry with the same inputs
- **Prompt versioning**: every AI call writes its `prompt_version` to the relevant table; prompts live in `prompts/registry.json`

## Pending external dependencies

- **N8N Governance document** — the user will provide a formal n8n standards doc later. Current naming is provisional and will be aligned to that doc after the pilot lands a paying customer. Ask the user before finalizing any workflow design whether the doc is now available.
- **MCP access** to n8n and to Azure Postgres — pending. Until it lands, treat all schema and workflow work as design-only.

## Critical constraints

- All architectural decisions are made in service of the **Lou Lou pilot, 1–2 week MVP**, not hypothetical scale. Do not add abstractions for imagined future clients.
- Multi-tenancy beyond a single client is deferred. The schema supports multiple clients but the deployment workflows do not yet.
- Universal architecture, niche-specific config: code is one product; tone, categories, voice are per-client.
