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
| `check_cull.gd` | Culling is safe: rays through the real field from camera positions within the margin never see a horizon-culled leaf's surface, no point of a far-plane-culled leaf is inside the frustum of a camera within the margin, no near leaf is culled, masks are unchanged | `-s tools/bench/check_cull.gd` |
| `check_cull_flight.gd` | Fly along the surface (speeding up over 3 s) and count holes (visible chunks without a mesh because they were culled); must be 0. Prints the first few holes | `-s tools/bench/check_cull_flight.gd -- <depth> <seconds> <m_per_s> [altitude]` |
| `check_physics_hitches.gd` | Does the player's physics hitch on a planet of this size and day length? Real scene, player standing on the ground, frames measured; OK = no frame over 16.7 ms. Run several seeds: the cost depends on the terrain under the player | `-s tools/bench/check_physics_hitches.gd -- <size> <day minutes> [seconds] [seed]` |
| `bench_parallel.gd` | Thread scaling of chunk generation | `-s tools/bench/bench_parallel.gd -- chunk` |
| `bench_calls.gd` | Thread scaling of different call kinds (shows why call count matters) | `-s tools/bench/bench_calls.gd` |

Launch as `"$GODOT_BIN" --headless --path . <args>`. A crash/abort message at exit of `bench_manager.gd` is expected (it quits with worker tasks in flight).
