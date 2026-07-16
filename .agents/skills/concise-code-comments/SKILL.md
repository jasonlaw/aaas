---
name: concise-code-comments
description: >
  Apply whenever writing or editing comments in code (any language). Use
  this to decide what a comment should say and how long it should be —
  covers install.sh, skills, scripts, and any other source file. Trigger
  on requests to "add a comment," "explain this in the code," "document
  this function," or when writing a comment as part of a larger change.
---

# Concise Code Comments

## Rule

A comment explains **why**, briefly. Never explain **what** the code
already says, and never narrate how it got there.

## Don't: self-explanatory comments

If a comment just restates the line below it in prose, delete it.

```bash
# increment the counter
counter=$((counter + 1))
```

The code is not hard to read. A comment here adds nothing.

## Don't: comment as change history

Comments are not commit messages. Don't write "we tried X, it failed
because Y, so we switched to Z" or "previously this used A; changed to B
because of bug #123." That belongs in git history or a changelog, not in
the source. A future reader needs to know the current reasoning, not the
sequence of edits that produced it.

```bash
# OLD: used to call hermes gateway restart directly, but that failed
# because of the wrapper-vs-root conflict, so we tried sudo hermes
# gateway restart, which also failed, so eventually we switched to
# systemctl directly, which is what's below now.
sudo systemctl restart "$unit_name"
```

Cut all of that down to the one fact a reader actually needs:

```bash
# hermes gateway restart needs root; the hermes CLI's guard wrapper
# blocks root. systemctl bypasses both via the unit's own User= directive.
sudo systemctl restart "$unit_name"
```

## Do: state the non-obvious reasoning, once, briefly

Keep a comment only if it answers a question the code can't answer by
itself — a constraint, a gotcha, a reason a simpler approach won't work.
Aim for one to three lines. If it's running longer, it's probably drifting
into history or restating the obvious — cut it back down.

```bash
# awk's early "exit" can close the pipe before systemctl finishes
# writing, killing it with SIGPIPE — a false failure under pipefail.
# Capture output first to avoid the race.
unit_files="$(systemctl list-unit-files --type=service --no-legend)"
```

## Applying this when editing existing comments

When asked to add a comment to code that already has verbose or
historical comments nearby, don't match that style — write the concise
version and, if asked to clean up the file more broadly, trim the
surrounding ones too rather than adding a new comment in a different
style next to old ones.
