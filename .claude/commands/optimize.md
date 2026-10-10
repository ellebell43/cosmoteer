---
description: Find performance hot spots in a file or system, then fix the best one
argument-hint: <file | function | system, e.g. chunk-manager.gd>
---

Optimize `$ARGUMENTS`.

Context: this game streams terrain for whole planets in one scene using an octree LOD + Transvoxel meshing, with mesh generation on `WorkerThreadPool` and mesh building on the main thread. Frame time on the main thread is the usual constraint. See `docs/world-generation.md`.

1. Read the target and `docs/world-generation.md`. Note the timing counters already available (`ChunkManager.get_timing_snapshot()`, the debug overlay).
2. Identify likely hot spots and rank them by expected payoff, not by how easy they are to fix.
3. Measure before changing anything. Use the existing counters, or add temporary timing, and record the baseline numbers. If a meaningful measurement needs the game running interactively and you can't get one, say so and ask me to capture a profile instead of guessing.
4. Implement the top-ranked fix only. Prefer the simplest kind of change (cache, batch, early-out, reduce allocation, move off-thread, change data structure), and watch for thread safety and memory trade-offs.
5. Re-measure and report before/after. If the change didn't help, revert it and say so.
6. Commit the fix on its own. Update `docs/world-generation.md` if the pipeline or its perf notes changed.
7. List the remaining candidates, and say which are not worth touching.

Don't speculate beyond the code or claim a speedup you didn't measure.
