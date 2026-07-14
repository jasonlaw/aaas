---
name: invoke-opencode
description: Use this whenever Hermes admin needs to hand a task off to OpenCode for any reason — writing a report it can't write itself, escalating something it can't fix, delegating a task better suited to OpenCode's tools. OpenCode only has platform context (skills, reports directory, config) when its working directory is the platform root, and files it creates only get correct ownership when it runs as the aaas user — either one being wrong fails silently, with no error at invocation time. Always consult this before shelling out to `opencode run`.
---

# Invoke OpenCode

OpenCode reads its skills, config, and project context from its current working directory. It does not error or warn if launched from the wrong place — it just runs with none of the platform context loaded, and nothing about the output makes that obvious after the fact.

The same silent-degradation shape applies to the user OpenCode runs as. Everything under the platform tree (`/opt/aaas/platform`, including `reports/`) is owned `aaas:aaas` with the setgid bit set, so files created by anything running as the `aaas` user land with correct ownership automatically. If OpenCode ever gets invoked as a different user — root via an unguarded `sudo`, a cron job, some other elevated context — the files it creates come out owned wrong, and nothing errors at creation time. It just quietly breaks `aaas`'s ability to write, read, or rotate that file later.

## Rules

Always set the working directory to the platform root before invoking it. Don't invoke `opencode run ...` bare from whatever directory the current shell happens to be in.

```bash
cd /opt/aaas/platform && opencode run "<task description>"
```

If invoking through a language/tool that doesn't let you `cd` first (e.g. a subprocess call), pass the working directory as an explicit parameter to that call instead — whatever mechanism guarantees OpenCode's cwd is the platform root at launch, not just at the time the command was written.

If a Hermes admin session is itself running as `aaas` (the normal case — Hermes will only run as `aaas` in the first place), a direct child-process invocation from within that session inherits `aaas` automatically and needs no extra handling. Only add explicit user-checking if the invocation path doesn't obviously inherit the calling session's user — e.g. going through `sudo`, a scheduled job, or any other indirection where the effective user isn't guaranteed to already be `aaas`. In those cases, confirm the target user is `aaas` before invoking, the same way you'd confirm the working directory.

## If you can't confirm the working directory or user

If there's no way to verify or control the working directory or the user OpenCode will launch as, don't invoke it — say so instead of guessing. A "successful" OpenCode run with no platform context, or one that silently leaves misowned files behind, is worse than an explicit failure, since it looks like it worked.

## This is itself a reportable gap

If you ever find OpenCode was invoked without the platform root as its working directory, or as the wrong user, and it ran with degraded context or left misowned files behind as a result — by anything, not just yourself — that's a setup-level issue: write it up using the write-report skill rather than just noting it in passing.