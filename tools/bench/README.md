# Chunk pipeline benchmarks

Headless scripts used to measure `chunk.gd` / `chunk-manager.gd`. Run from the repo root with the double-precision editor binary (`$GODOT_BIN`). They load game scripts at runtime because autoloads (`Utils`) are not registered when a `-s` script is compiled, so do not reference `Utils` or the `class_name` types statically in new bench scripts.

| Script | What it measures | Command |
|---|---|---|
| `bench_hash.gd` | SHA-256 of generated meshes for fixed chunks. Must be unchanged by "output-preserving" optimizations | `-s tools/bench/bench_hash.gd` |
| `bench_micro.gd` | Per-LOD chunk cost (sample set / meshing), with and without transition cells, plus call counts | `-s tools/bench/bench_micro.gd` |
| `bench_manager.gd` | Real `ChunkManager` with a player flying at the surface: load time, per-frame cost, per-stage hitches | `-s tools/bench/bench_manager.gd -- <octree_depth> <seconds> <m_per_s>` |
| `bench_parallel.gd` | Thread scaling of chunk generation | `-s tools/bench/bench_parallel.gd -- chunk` |
| `bench_calls.gd` | Thread scaling of different call kinds (shows why call count matters) | `-s tools/bench/bench_calls.gd` |

Launch as `"$GODOT_BIN" --headless --path . <args>`. A crash/abort message at exit of `bench_manager.gd` is expected (it quits with worker tasks in flight).
