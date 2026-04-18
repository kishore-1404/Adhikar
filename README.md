# Adhikar — Legal Literacy Platform for India

**Know your rights. Act with clarity.**

A deploy-ready single-page app that teaches Indian legal rights through real-world scenarios, backed by a full PostgreSQL schema for when you are ready to scale beyond static hosting.

---

## What's in this bundle

| File          | What it is                                                                 |
| ------------- | -------------------------------------------------------------------------- |
| `index.html`  | Complete self-contained app. Open it and it works — no build step.         |
| `schema.sql`  | PostgreSQL 15 schema with seed data for every law and scenario in the app. |
| `README.md`   | This file.                                                                 |

---

## Run it in 10 seconds (local)

```bash
# Option A — just double-click index.html. It runs entirely in the browser.

# Option B — serve it locally (any static server works):
python3 -m http.server 8000 --directory .
# then open http://localhost:8000
```

No npm install. No backend. No API keys. State persists in `localStorage` under the key `adhikar_state_v1`.

---

## Deploy to production (static)

The app is a single HTML file, so *any* static host works:

**Netlify** — drag the folder onto app.netlify.com/drop. Done.
**Vercel** — `vercel deploy` from this directory.
**Cloudflare Pages** — connect the repo or upload directly.
**AWS S3 + CloudFront** — `aws s3 cp index.html s3://your-bucket/ --acl public-read` then point CloudFront at the bucket.
**GitHub Pages** — drop it in a repo, enable Pages, done.

No build step. No environment variables. One file.

---

## What's actually implemented

This is not a mock. Everything below works end to end on the client.

**Learner experience**
- 20 legally-grounded scenarios across 6 domains (police, workplace, consumer, housing, cyber, education), each with 4 choices and per-choice explanations
- 26 law sections from CrPC, the Constitution, POSH Act, Maternity Benefit Act, CPA 2019 + E-Commerce Rules, IT Act, RTE Act, UGC anti-ragging regulations, TPA, Specific Relief Act — with simplified plain-language text and authoritative citations
- SM-2 spaced repetition, correctly implemented (quality 1–5 → next due date)
- Daily session queue: due items + never-attempted, capped at 5 per session
- Streak tracking, first-attempt mastery scoring, session-end summary
- Situation-first emergency mode: 6 Act Guides ("Police is at my door", "My employer is threatening me", etc.) with must-know / can-say / document / call-first sections and real helpline numbers (NALSA 15100, cybercrime 1930, consumer 1915, anti-ragging 1800-180-5522, emergency 112)
- Radar-chart progress view showing domain-by-domain mastery
- Full `localStorage` persistence — reload the tab, your state is still there

**Admin / legal reviewer tooling**
- Moderation queue with 4 pending contributions (scenario submissions, a statutory simplification edit, a Tier 2 escalation candidate)
- Automated pre-check results displayed per contribution: schema validation, citation existence, contradiction detection, duplicate detection, difficulty calibration (each pass/warn/fail)
- Rejection code vocabulary (R1 overstated right · R2 missing exception · R3 wrong actor · R4 citation mismatch · R5 misleading distractor · R6 language too complex)
- Four-option decision flow: approve / approve-with-edits / escalate to Tier 2 / reject
- Reviewed items log, content pipeline status view (8 stages from ingestion → published pool)
- Decisions persist in `localStorage` and survive reloads

**Data layer**
- Full PostgreSQL DDL in `schema.sql`: acts, law_sections, section_references, scenarios (with enum status), scenario_choices, scenario_law_links, act_guides, act_guide_items, user_profiles, user_attempts (monthly-partitioned), user_revision_schedule, user_bookmarks, contributions (with JSONB payload + auto-check result), review_decisions, contributor_reputation
- Constraint: exactly one correct answer per scenario, enforced via partial unique index
- `record_attempt()` stored procedure mirrors the client-side SM-2 algorithm
- Two read views: `v_scenario_full` (denormalized scenario + choices + laws) and `v_user_mastery` (first-attempt mastery by domain)
- Neo4j cypher schema included as comments at the end (constraints + relationship types for the knowledge graph)

---

## What's intentionally mocked

The original design doc describes a 6-microservice platform. This bundle gives you the parts that matter for demonstrating the product to users and legal reviewers. The infrastructure layers below are **documented in the pipeline view** but not stood up:

- **Ingestion pipeline** — the Admin → Pipeline tab shows an 8-stage status dashboard (source ingested → cleaned → entity-extracted → AI-drafted → pre-checked → Tier 1 → Tier 2 → published). The tab visualises real state a production system would show; it does not actually run an ingestion job.
- **LLM scenario drafting** — scenarios here are human-written. In production, the design calls for LLM drafts filtered through the auto-check gates and two tiers of human review. The contribution objects in the admin queue (`c1`–`c4`) are shaped to show how AI drafts and community submissions would flow through the same review UI.
- **Neo4j + Kafka** — referenced in the schema as comments. The cypher constraints and relationship types are documented; wire up a sync job from Postgres when you need graph queries.
- **Auth** — the app uses anonymous device-local state. For production, add phone/OTP auth and map the `user_profiles.phone_hash` or `anon_id` columns.

---

## Wire up a real backend

When you're ready to move off localStorage:

1. **Stand up Postgres.** Run `psql -f schema.sql`. All seed data loads on first run; subsequent runs are no-ops thanks to `ON CONFLICT DO NOTHING`.
2. **Build a thin API.** You need six endpoints to replace the client-only state:
   - `GET /api/scenarios?due=true&limit=5` — uses `v_scenario_full` + joins against `user_revision_schedule`
   - `POST /api/attempts` — calls the `record_attempt()` stored procedure
   - `GET /api/progress` — reads from `v_user_mastery`
   - `GET /api/act-guides/:id` — joins `act_guides` + `act_guide_items`
   - `GET /api/admin/queue` — `SELECT * FROM contributions WHERE status='pending'`
   - `POST /api/admin/decisions` — writes to `review_decisions` and updates `contributions.status`
3. **Replace `loadState`/`saveState`** in `index.html` with `fetch()` calls. The rest of the app keeps working without changes.

---

## Legal content provenance

Every scenario cites at least one section of a real Indian statute. Key judgments referenced include **D.K. Basu v. State of West Bengal (1997)** for arrest safeguards, **Arnesh Kumar v. State of Bihar (2014)** for §41A CrPC, **Maneka Gandhi v. Union of India (1978)** for Article 21, **Society for Unaided Private Schools v. Union of India (2012)** for RTE §12(1)(c), and **IMA v. V.P. Shantha (1995)** for medical services under consumer law.

**This is legal literacy, not legal advice.** Every view in the app surfaces this disclaimer. For urgent legal situations, users are directed to NALSA legal aid (15100) and emergency services (112).

---

## File structure

```
.
├── index.html    # the app (≈90 KB; React 18 + Tailwind + Babel via CDN; no build)
├── schema.sql    # Postgres 15 DDL + seed data for production
└── README.md     # this file
```

---

## Attributions

Typography: Inter (UI) and Crimson Pro (law text) from Google Fonts.
Design palette: warm paper (#faf8f4), slate ink (#0f172a), amber accent (#b45309).

---

Built as a demonstration that a well-scoped scenario-first legal literacy product can be put in users' hands today, and grow into a full backend-backed platform tomorrow without rewriting the learning layer.
# Adhikar
