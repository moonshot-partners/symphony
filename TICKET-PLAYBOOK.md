# Ticket playbook

How to hand work to the Symphony agent, how to send a ticket back for
another pass, and how to tell whether a ticket is ready for the agent at
all. Written for the person who manages the Linear board, not for
engineers.

## Dispatch a ticket

1. Move the card into the **Scheduled** column.
2. Add the **agent** label.

That is the whole operation. Symphony picks the card up on its next
poll, moves it to **In Development**, and works it through to an open
pull request.

## The one rule that explains everything

**The agent reads the ticket description and nothing else.**

It does not read comments on the ticket. It does not read the live
progress notes Symphony posts back. Each run starts fresh with no memory
of earlier runs. So anything the agent needs to know has to be in the
description before you dispatch.

This is why the steps below all come back to editing the description.

## Send a ticket back for another pass

A ticket needs another pass when the pull request is incomplete, a
reviewer asked for changes, the agent shipped the right code in the
wrong place, or the work stopped in **On Hold / Blocked**. To
re-dispatch:

1. **Edit the description.** Add a short section at the bottom saying
   what is still wrong and what you want changed. Be concrete. The agent
   will not see the reviewer's comments or the previous discussion, so
   restate the request here in plain words.
2. Move the card back into **Scheduled**.

That is the whole procedure. Same ticket, edited description, back to
Scheduled.

What does **not** work: replying in the ticket comments and expecting
the agent to read them, or moving the card without updating the
description. The agent will just repeat the same run.

### What carries from one run to the next

A re-dispatch starts the agent over. Concretely:

- **A new agent session.** Symphony opens a fresh agent thread per
  dispatch. The agent has no memory of what it did in the previous run.
- **A clean working directory.** Symphony wipes the agent's workspace
  before each new run. Any uncommitted scratch from a prior run is gone.
- **The same pull-request branch, if one already exists.** When
  Symphony sees an open PR for the ticket, the agent is told to check
  that PR out instead of opening a second one. The commits from the
  prior run survive — the new run continues on top of them.
- **The ticket description.** That is the only context the agent
  reads. The description you edited in step 1 above is what the agent
  sees.

So a re-dispatch is **a fresh agent, on the same branch (if a PR
exists), with the latest description.** What changes between runs is
whatever you put in the description.

### Worked example — code in the wrong place

A teammate files a ticket asking the agent to add a "filter by child"
control on the parents dashboard. The agent ships the right filter
logic, but mounts the control in the wrong component — the dropdown
appears, but not where the user expected it.

To redirect:

1. Open the ticket description and append a short re-dispatch note.
   For this case it would read something like:

   > Re-dispatch: the filter component should live in the dashboard
   > toolbar, not in the page-level layout. Move it there and keep the
   > filter logic you already wrote.

2. Move the ticket back to **Scheduled**.

The agent starts a fresh session, checks out the existing PR branch,
and reads the updated description. It sees both the original request
and the redirect note, finds the filter code already on the branch,
and applies the move. Same ticket, same branch, same PR — corrected
work on top.

## What makes a good ticket

The agent does well on small, well-defined work and badly on vague or
oversized requests. Before you add the agent label, check the
description against this list:

- **It has a description.** An empty ticket is stopped on arrival and
  parked for a human. The agent never runs on it.
- **You can tell when it is done.** The description states a clear,
  checkable outcome ("the page title reads X", "the broken link points
  to Y"), not a direction ("improve the search").
- **It is one thing.** One fix or one small change. Bundled requests
  should be separate tickets.
- **It names the area.** If the work touches a specific page, feature,
  or repository, say which one. The agent does not have to guess.
- **It needs no decision from you mid-way.** If finishing the ticket
  depends on a judgement call only a person can make, make that call
  first and write the answer into the description.

A ticket that fails this list is not a Symphony ticket yet. Tighten the
description, or hand it to an engineer to shape first. That boundary is
a feature, not a limitation.

## Where information belongs

Three kinds of information, three homes. Keeping them separate is what
keeps runs predictable.

- **This ticket, this run** — goes in the Linear ticket description.
  The request, the acceptance criteria, any re-dispatch notes.
- **How this project works in general** — goes in the repository's
  `AGENTS.md` file (conventions, where things live, how to test). This
  is durable and applies to every ticket, so it does not belong on any
  single ticket. Engineers maintain it.
- **How Symphony itself behaves** — lives in this repository. Operators
  and engineers do not edit it per ticket.

When in doubt: if it is true for one ticket only, it goes in the
description; if it is true for the whole project, it goes in `AGENTS.md`.
