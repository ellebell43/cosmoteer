---
description: Identify performance hot spots in a file or system and suggest approaches (no edits)
argument-hint: <file | function | system, e.g. chunk-manager.gd>
allowed-tools: Read, Glob, Grep
---

Look for optimization opportunities in `$ARGUMENTS`.

Rules (from CLAUDE.md): suggest, don't implement. Do not edit files.

Context: this game streams terrain for whole planets in one scene using an octree LOD + Transvoxel meshing, with mesh generation on `WorkerThreadPool` and mesh building on the main thread. Frame time on the main thread is the usual constraint. See `docs/world-generation.md`.

1. Read the target and `docs/world-generation.md`. Note any timing counters already available (`ChunkManager.get_timing_snapshot()`, the debug overlay).
2. Identify the likely hot spots and rank them by expected payoff, not by how easy they are to fix. Say what you'd measure first to confirm each one.
3. For each: what's slow, why, and the *kind* of fix (cache, batch, move off-thread, early-out, reduce allocation, change data structure), including trade-offs and risks (thread safety, memory, added complexity).
4. Separate real wins from micro-optimizations. Say when something is not worth touching.
5. Don't speculate beyond the code. If the answer depends on a profile, tell me how to capture one (Godot profiler / monitors) instead of guessing.

Output: ranked list with `file:line` references, then the first thing I should measure.
