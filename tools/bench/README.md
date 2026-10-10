# Chunk pipeline benchmarks

Headless scripts used to measure `chunk.gd` / `chunk-manager.gd`. Run from the repo root with the double-precision editor binary (`$GODOT_BIN`). They load game scripts at runtime because autoloads (`Utils`) are not registered when a `-s` script is compiled, so do not reference `Utils` or the `class_name` types statically in new bench scripts.

| Script | What it measures | Command |
|---|---|---|
| `bench_hash.gd` | SHA-256 of generated meshes for fixed chunks. Must be unchanged by "output-preserving" optimizations | `-s tools/bench/bench_hash.gd` |
| `bench_micro.gd` | Per-LOD chunk cost (sample set / meshing), with and without transition cells, plus call counts | `-s tools/bench/bench_micro.gd` |
| `bench_manager.gd` | Real `ChunkManager` with a player flying at the surface: load time, per-frame cost, per-stage hitches | `-s tools/bench/bench_manager.gd -- <octree_depth> <seconds> <m_per_s>` |
| `check_elevation_bound.gd` | `WorldNoise.bias_threshold` really bounds the elevation (what makes skipping empty chunks safe) | `-s tools/bench/check_elevation_bound.gd` |
| `check_leaf_set.gd` | Leaf set + transition masks equal a reference implementation (the original manager, see the script header) | `-s tools/bench/check_leaf_set.gd -- <reference chunk-manager.gd>` |
| `check_settle.gd` | End-state test: fly fast, stop, wait for the manager to settle, compare with a fresh load at the same spot | `-s tools/bench/check_settle.gd -- <depth> <seconds> <m_per_s>` |
| `stress_move.gd` | Crash stress: fly fast, print `DONE`; a run without `DONE` crashed | `-s tools/bench/stress_move.gd -- 8 6 100 [manager.gd]` |
| `check_game_scene.gd` | The real `system.tscn`: loading screen finishes, and a ray down from the player hits a LOD 1 collider; prints how long that took after moving 12 m | `-s tools/bench/check_game_scene.gd` |
| `bench_parallel.gd` | Thread scaling of chunk generation | `-s tools/bench/bench_parallel.gd -- chunk` |
| `bench_calls.gd` | Thread scaling of different call kinds (shows why call count matters) | `-s tools/bench/bench_calls.gd` |

Launch as `"$GODOT_BIN" --headless --path . <args>`. A crash/abort message at exit of `bench_manager.gd` is expected (it quits with worker tasks in flight).
