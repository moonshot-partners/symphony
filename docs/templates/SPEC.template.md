# [<TICKET-ID>] <One-line goal in plain language>

> Template for a Symphony-ready ticket body. Copy this into the Linear
> issue description and fill every section. Sections marked
> **(non-technical)** must be readable by someone who has never touched
> the code. Sections marked **(engineer)** can be skipped for a "simple"
> ticket — see the complexity check below.
>
> The reference is `docs/skills/spec-author/SKILL.md`. The gold-standard
> hand-written examples are
> `SODEV-838-followup-spec.md`, `symphony-discovery-phase-spec.md`, and
> `symphony-agent-gate-discipline-spec.md` in the schoolsout repo.

---

## TL;DR (non-technical)

<!-- 2-4 sentences. What's broken or missing today, what we want
     instead, who notices the difference. No jargon. -->

## Complexity check — simple or needs an engineer?

A ticket is **simple** and safe to self-serve if every box below is
yes:

- [ ] Only the visual surface or the text of one or two screens changes.
- [ ] The exact pages and the exact strings/components are nameable in
      this ticket (e.g. "the 'Narrow your search' link on the city
      page").
- [ ] No new API field, no database column, no auth/permissions change.
- [ ] No cross-system coordination — only one frontend repo or only one
      backend repo touched.

If any box is **no**, stop and tag an engineer in the ticket. The
spec-author skill (`docs/skills/spec-author/SKILL.md`) escalates
automatically and refuses to produce the engineer sections.

## Goal (non-technical)

<!-- One paragraph. The outcome a user or operator sees. Not a
     to-do list. -->

## Non-negotiable constraints

<!-- 3-6 short rules. Things the agent must not do. Examples that
     came up in real Symphony tickets:
     - "dev branch only — never push to main"
     - "frontend must tolerate a backend that has not shipped yet"
     - "no blank links ever" -->

1.
2.
3.

## In scope

<!-- Bulleted list of the exact files, screens, or endpoints
     touched. Be specific — file paths if you know them, screen names
     if you don't. -->

-

## Out of scope

<!-- Bulleted list of things that are "right there" but explicitly
     not touched. This is the most important section for a simple
     ticket — it stops the agent from drive-by refactors. -->

-

## Repos and branches (engineer)

<!-- Skip for a simple ticket — let the engineer fill this in. -->

| Repo | Branch off | PR target |
|------|-----------|-----------|
| <org/repo> | `origin/dev` | `dev` |

## Backend changes (engineer)

<!-- Skip for a simple ticket. -->

## Frontend changes (engineer)

<!-- Skip for a simple ticket. -->

## Acceptance criteria

<!-- 3-8 numbered, testable statements. Each AC must be a thing the
     agent or a reviewer can verify by looking at the running system,
     not a goal or a feeling.

     GOOD: "children[].anchor_text is present and equals
       '{Activity} Camps in {City}' for a single-facet template."
     BAD: "children links look better." -->

1.
2.
3.

## Verification after merge

<!-- One concrete step per AC: a curl command, a URL to open, a
     screenshot to take. The QA agent and the reviewer use this
     section verbatim. -->

1.
2.

## Decisions and assumptions

<!-- Anything where the original request was ambiguous and this
     spec picked an answer. The agent will follow these — flag
     them if you'd rather the agent ask. -->

-
