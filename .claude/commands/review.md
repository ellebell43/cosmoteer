---
description: Review uncommitted changes (or a file/branch), then fix what's wrong
argument-hint: [file | branch | blank for working-tree changes] [report-only]
---

Review the code at `$ARGUMENTS`. If blank, review `git diff` plus `git diff --staged`; if it names a branch, diff it against `master`. If the arguments include `report-only`, don't change anything.

Check, in priority order:
1. **Bugs**: logic errors, off-by-one, wrong units, null/freed-node access, signal connect/disconnect mismatches.
2. **Threading**: anything touching scene-tree state or shared dictionaries from a `WorkerThreadPool` task; races between worker tasks and `_process`.
3. **Godot gotchas**: `@onready` timing, `queue_free` while tasks are pending, setter side effects, typed-collection misuse.
4. **Performance**: per-frame allocation, work on the main thread that could move off it, repeated sampling.
5. **Conventions**: deviations from `docs/conventions.md`.
6. **Docs drift**: does this change make anything in `docs/` or `CLAUDE.md` wrong?

Then act:
- Fix must-fix and should-fix issues, and update any drifted docs. Run the game headless or in the editor where practical to confirm the fix. Leave nits as a list unless they are trivial.
- Commit the fixes separately from the work being reviewed, so the review is visible in history.

Output: a short list grouped by severity (must-fix / should-fix / nit), each with `file:line`, what was wrong, and whether you fixed it. If nothing is wrong, say so plainly rather than inventing issues.
