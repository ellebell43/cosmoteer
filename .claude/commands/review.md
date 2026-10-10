---
description: Review my uncommitted changes (or a given file/branch) and give feedback without applying anything
argument-hint: [file | branch | blank for working-tree changes]
allowed-tools: Read, Glob, Grep, Bash(git status:*), Bash(git diff:*), Bash(git log:*), Bash(git show:*)
---

Review my code. Target: `$ARGUMENTS` (if blank, review `git diff` plus `git diff --staged`; if it names a branch, diff it against `master`).

Rules (from CLAUDE.md): I wrote this code myself and it stays that way. **Do not edit files or paste corrected versions.** Describe the problem and the fix in words, and point at the line.

Check, in priority order:
1. **Bugs**: logic errors, off-by-one, wrong units, null/freed-node access, signal connect/disconnect mismatches.
2. **Threading**: anything touching scene-tree state or shared dictionaries from a `WorkerThreadPool` task; races between worker tasks and `_process`.
3. **Godot gotchas**: `@onready` timing, `queue_free` while tasks are pending, setter side effects, typed-collection misuse.
4. **Performance**: per-frame allocation, work on the main thread that could move off it, repeated sampling.
5. **Conventions**: deviations from `docs/conventions.md`.
6. **Docs drift**: does this change make anything in `docs/` or `CLAUDE.md` wrong? List the sections to update.

Output: a short list grouped by severity (must-fix / should-fix / nit), each with `file:line`, what's wrong, and why it matters. If nothing is wrong, say so plainly rather than inventing issues.
