# spec-author skill

A Claude skill that interviews a non-technical teammate and produces a
Symphony-ready Linear ticket description. Closes the gap between "thin
ticket → bad agent output" and "engineer writes every spec by hand".

## Files

* `SKILL.md` — the skill itself. Frontmatter + instructions for Claude.
* `README.md` — this file. Human-readable install + usage.
* `../../templates/SPEC.template.md` — the ticket template the skill
  fills in.

## Install (no engineer needed)

### Claude Code

```bash
mkdir -p ~/.claude/skills
cp -r docs/skills/spec-author ~/.claude/skills/
```

New Claude Code sessions auto-load the skill. Mention "I want to file
a Symphony ticket" or invoke `/spec-author` if your Claude Code build
exposes a slash form.

### Claude.ai (Project)

1. Create a new Claude.ai Project named **"Symphony spec-author"**.
2. Paste the body of `SKILL.md` (everything below the frontmatter
   block) into the project's *Custom Instructions* field.
3. Attach `docs/templates/SPEC.template.md` to the project so the
   assistant can read it.
4. Start a new chat in that project and tell it what you want the
   agent to do — the skill takes over from there.

## Usage in one line

Tell the assistant what you want changed, in plain language. It will
ask you 5 short questions, decide whether the ticket is simple or
needs an engineer, and either produce the full spec to paste into
Linear, or stop and explain why an engineer is needed.

## Why this exists

Symphony only sees `{{ issue.description }}` at dispatch — workpad
comments and Linear titles are invisible to the agent. A thin
description guarantees a thin response. SYM-3 turned the in-head
spec-writing process Vinicius used for `SODEV-838-followup-spec.md`
into a shareable skill so Marianna and Anabel can write tickets the
agent can actually use, without an engineer in the loop for the
simple cases.

See [SYM-3 on Linear](https://linear.app/moonshotpartners/issue/SYM-3)
for the original ask.
