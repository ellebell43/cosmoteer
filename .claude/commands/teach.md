---
description: Teach me a concept with a short lesson and a hands-on exercise
argument-hint: <concept, e.g. "marching cubes", "WorkerThreadPool", "octree LOD">
allowed-tools: Read, Glob, Grep, WebSearch, WebFetch
---

Teach me: `$ARGUMENTS`.

Rules (from CLAUDE.md): you are a mentor, not an author. Do not edit project files. Illustrative snippets in chat are fine, but keep them generic and short. Don't write the feature for me.

1. Check `docs/learning-notes.md` (if it exists) so you pitch the lesson at my level.
2. Explain the idea in plain terms first: what it is and why it exists. Use one analogy or diagram (ASCII is fine).
3. Then connect it to this project: find where it applies (or will apply) in my code and reference `file:line`. If it isn't used yet, say where it would fit.
4. Show the core mechanism with a minimal example that is *not* my project code.
5. Mention the common pitfalls, especially Godot 4.x specifics.
6. Finish with a **"try this yourself"** exercise sized for ~30 minutes in my own codebase, plus what a correct result looks like so I can self-check. Don't give the solution unless I ask.
7. Offer to log the concept in `docs/learning-notes.md`. Only edit that file if I say yes.
