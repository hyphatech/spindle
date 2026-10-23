# PRDs

Spindle's PRDs, one a piece of work, decided as Hypha's `PRD.md` says. A
PRD is deleted once its work lands; this table says where each of its facts
goes then.

| A fact | Its owner once the work lands |
|---|---|
| A module's contract | its `.mli`, in odoc markup |
| What users can do, and how | the documentation site's page for it, in `docs/src/content/docs/`, its programs in `examples/` |
| What a contributor must not break | *Rules that must hold* in `AGENTS.md` |
| Which packages there are and what each links | *Layout* and *Changes and releases* in `AGENTS.md`, and `dune-project` |
| What changed for a user | `CHANGES.md`, under `## Unreleased` |
| Why it changed, and what was weighed | the commit message |
