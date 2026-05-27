# gbrain — Beyond Note Storage

Capabilities that turn the vault from passive storage into an active layer. All mapped to the actual vault shape.

---

## Synthesis across time

Daily-tracking and gratitude entries become queryable as patterns, not files.

- `gbrain think "what patterns show up in my morning routines when I feel best?"` — multi-hop synthesis across journals
- `gbrain query --salience` — surface emotionally-weighted entries
- `gbrain find_anomalies` — spot unusual patterns in tracking (energy, mood, productivity)

---

## Idea capture that preserves exact wording

`voice-note-ingest` skill captures **EXACT PHRASING** — voice memos stay retrievable in original voice, not paraphrased.

```bash
gbrain skillpack install voice-note-ingest
```

Then voice memos auto-route to concepts/people/ideas.

---

## Entity graph from wikilinks

Build the typed graph from existing `[[wikilinks]]`:

```bash
gbrain extract links
gbrain graph "Acme"                # everything connected to a topic
gbrain backlinks 2026-05-21        # who/what references that date
```

---

## Meeting / call intelligence

For folders that collect recurring meeting notes (e.g. `startup/<your-app>/meetings/`):

- Pipe transcripts → gbrain auto-extracts decisions, action items, who-said-what
- `gbrain query "what has anyone said about pricing?"` returns relevant moments

---

## Auto-enrichment of people/concepts

Write `[[Person Name]]` casually. With an enrichment pipeline:

- gbrain auto-creates `people/person-name.md` that grows over time
- Every future mention enriches it (when, in what context, themes)
- Becomes a "living relationship dossier" without manual upkeep

---

## Skillpacks (pre-built workflows)

```bash
gbrain skillpack list
gbrain skillpack install --all     # enable all bundled
```

Bundled skills:
- **academic-verify** — trace claims through publications
- **brain-pdf** — render brain pages to PDFs
- **voice-note-ingest** — exact-phrase voice capture

---

## Background autonomy (minions / jobs)

Scheduled deterministic jobs that ingest external data — no LLM cost.

- Daily Twitter/X mentions → brain
- Stripe metrics → brain (if shipping products)
- Calendar events → brain pages

```bash
gbrain jobs submit <name>
gbrain jobs list
```

---

## Compiled truth — synthesis as queries

- `gbrain query` — hybrid retrieval (vector + BM25)
- `gbrain think <q>` — multi-hop synthesis with citations to own files
- `gbrain think "what does my journaling say about smoking triggers?"` reasons across all dated entries

---

## Recommended next steps (in order)

1. `gbrain extract links` — free, immediate, builds graph from existing wikilinks
2. `gbrain extract timeline` — dated daily entries become timeline-queryable
3. `gbrain skillpack install voice-note-ingest` — capture voice ideas on the go
4. Try `gbrain think "..."` on gratitude entries — gauge synthesis quality
