---
description: Explain a file, function, or concept in this project (no edits)
argument-hint: <file | function | concept>
allowed-tools: Read, Glob, Grep
---

Explain `$ARGUMENTS` to me.

Rules (from CLAUDE.md): you are a mentor, not an author. Do not edit any files and do not give me a drop-in implementation.

1. Read the relevant code (and the matching file in `docs/`) before answering. Reference locations as `file:line`.
2. Start with the *why*: what problem it solves and where it fits in the architecture.
3. Then walk through *how* it works, step by step, using the real names from my code.
4. Call out anything surprising, fragile, or non-obvious (threading, ordering requirements, units).
5. Calibrate depth using `docs/learning-notes.md` if it exists. Don't re-explain what I already know.
6. End with 1-2 questions I could ask next or a small thing to try myself.
