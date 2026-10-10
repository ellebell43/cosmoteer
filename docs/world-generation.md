# World generation

Code lives in `environment/world-generation/`.

## Pipeline overview

1. `Planet._ready()` builds a `WorldNoise` from `world_seed`, volume size, `floor_distance`, `sea_level_modifier`, and the two `Curve` resources (`continent_curve`, `mountain_curve`; defaults in `slope_curves/`).
2. `ChunkManager` runs an **octree** over the noise volume. Cells near the player split into finer cells; far cells stay coarse. Each leaf is a chunk key `Vector4i(x, y, z, lod_step)`. The octree and each leaf's transition mask are computed on a **worker thread** into a fresh dictionary (`_compute_leaf_set()`); the main thread swaps it into `new_chunk_set` when done.
3. Each leaf becomes a `Chunk`. Chunks that can never have a mesh (`Chunk.is_provably_empty()`, an O(1) bounds test) are ACTIVE immediately and never get a task or a scene node. For the others, mesh data is generated on a `WorkerThreadPool` thread using **Transvoxel** (Marching Cubes + transition cells for LOD seams).
4. A finishing worker pushes its chunk onto a mutex-guarded queue. The main thread drains it in `_process`, capped at `MAXIMUM_BUILD_TIME` (µs) per frame; `build_mesh()` creates the actual mesh. A chunk joins the scene tree only once it has a mesh.

## WorldNoise: the scalar field

`sample(x, y, z)` returns `shell_bias - elevation * FLOOR_BIAS`. The surface is where it crosses 0.

- `shell_bias = (distance_from_center - sea_level) * FLOOR_BIAS`: turns the volume into a sphere.
- `get_elevation_at_point`:
  - `continent_noise` (Perlin FBM, low freq) → run through `continent_curve` → `base_elevation`
  - `mountain_noise` (ridged simplex) scaled by `mountain_curve.sample(base_elevation)` × `MOUNTAIN_AMPLITUDE`, so mountains only appear at elevations the curve allows
  - plus small `hill_noise` and `detail_noise` terms
- `get_biome_color` maps elevation bands to vertex colours (deep water → water → sand → grass → rock).
- `bias_threshold`: derived in `WorldNoise._init()` from the curves and amplitudes (a bound on |elevation| × `FLOOR_BIAS`). Used by `Chunk._determine_if_cell_is_empty()` to skip sampling cells that are certainly all-air/all-solid. `sample_grid()` samples a whole chunk grid in one call.

Tuning knobs: noise frequencies/octaves in `WorldNoise._init`, the amplitude constants, and the two curves. Curve domains/ranges are documented on the `@export` vars in `planet.gd`.

## Chunk lifecycle

`Chunk.chunk_state`: `PROCESSING → ACTIVE → RETIRING → READY_TO_DIE → freed`

ChunkManager keeps one dictionary per stage (`pending_`, `active_`, `retiring_`, `ready_to_die_chunk_set`, plus `new_chunk_set` for the desired leaves from the latest octree pass).

- Player moves ≥ `player_movement_threshold` (10 m): start a **leaf job** on a worker (only one in flight; by the time it finishes the player has usually moved on, which simply starts the next one).
- A finished leaf set starts a **reconcile**, spread over frames with a `RECONCILE_BUDGET` (µs) per frame, in this order:
  1. `MARK` (`_mark_retiring_chunk`): active chunks no longer wanted become RETIRING. They keep rendering until replacements are ready, which prevents LOD "popping". This must run **before** `LOAD`: a retiree counts the volume of the replacements that become ACTIVE while it is RETIRING (`volume_counter`).
  2. `LOAD` (`_load_chunk`): revive retiring/ready-to-die chunks that are wanted again, update the desired mask of active/pending ones (and remesh when it differs from `built_transition_mask`), spawn brand-new ones.
  3. `CHECK` (`_check_retiring_chunk`): a retiree is released when any ancestor is ACTIVE (not just the parent: fast movement can skip LOD levels) or when active replacements fill its volume (`_iterate_through_parents`).
  4. `COVERAGE` (`_add_coverage`): only when nothing is generating and retirees are left. Recounts every retiree's covered volume exactly from the ACTIVE chunks, because the incremental counts can miss replacements that skipped levels.
  5. `KILL` (`_unload_octree_chunk`): fades the mesh out with a tween, then `queue_free()`s, but only after its worker task has been collected.
- A chunk becoming ACTIVE marks the manager "dirty"; a retire/kill pass (CHECK → COVERAGE → KILL) then runs at most every `CLEANUP_INTERVAL`, so retirees do not wait for the next 10 m of movement.
- A new chunk whose key is no longer in `new_chunk_set` when its task finishes is dropped instead of shown.

## Transvoxel notes

- Lookup tables in `transvoxel-lut.gd` (large, vendored-style data. Don't read it unless the task is about it).
- `Chunk.basis_table` and `BASIS_TABLE` enum map each of the 6 faces to U/V/N axes and plane.
- Known gap: transition cells fix seams across *faces* only. Chunks of different LOD that share just a corner or edge can still leave cracks (issue #5).
- `Chunk.wireframe_mode` swaps the chunk material for `assets/textures/wireframe-material.tres` (shader: `assets/shaders/wireframe.gdshader`). It's the debug view for inspecting seams.
- Mask bit order: `x, y, z, -x, -y, -z` (bits 0–5).
- `built_transition_mask` vs. `desired_transition_mask`: a chunk remeshes when they differ and it has no running task.

## Performance notes / things to watch

Benchmarks live in `tools/bench/` (see its README). Measure before optimizing. Numbers below: 14 cores, the editor/debug build, player flying at the surface at 10 m/s for 20 s (`bench_manager.gd`).

| | Before | After |
|---|---|---|
| Chunk generation, no transitions | 8.2 ms | 4.7 ms |
| Chunk generation, all 6 transition faces | 30.6 ms | 7.1 ms |
| Worker time per chunk during play (avg) | 44–61 ms | 12 ms |
| Initial load, size 7 (3,382 leaves, 502 meshes) | 11.8 s | 3.4 s |
| Initial load, size 11 (5,608 leaves, 1,025 meshes) | 24.0 s | 4.9 s |
| `ChunkManager._process` while moving, size 7: mean / p95 / max | 3.3 / 5.8 / 60 ms | 1.1 / 4.8 / 6.8 ms |
| Same, size 11: max | 94 ms | 9.7 ms |
| Longest frame interval while moving, size 7 | 61–76 ms | 17 ms |
| Octree passes applied (of those started) | 6 of 19 | all |
| Pending tasks, peak while moving | 2,100–2,300 | ~170 |
| `Node3D`s in the tree | ~5,300 | ~1,300 |

What mattered, in order:

- **Call count, not arithmetic, limits worker throughput.** In the debug build every GDScript/native call is contended across threads; chunk generation topped out at ~1.6× speedup no matter how many cores (`bench_parallel.gd`, `bench_calls.gd`). In a release build typed calls scale, untyped native-object calls still do not. So: batch (`WorldNoise.sample_grid()`), keep object variables typed, avoid per-vertex calls.
- Transition cells: `Chunk._apply_shift()` only does the (6-sample) field-normal lookup for points that are actually shifted, caches them, and `transition_samples` are slices of `corner_samples`, not new samples.
- Biome colour is computed once per cell vertex, not per triangle corner. (Winding-inverted transition triangles keep their colours in a, b, c order, as before.)
- The mountain noise is skipped where its mask is exactly 0. `WorldNoise.bias_threshold` is derived from the curves, so more empty chunks are rejected without sampling (`tools/bench/check_elevation_bound.gd` checks the bound).
- The main thread never polls pending tasks: cost scales with finished chunks. The leaf job and the reconcile are off the frame's critical path or time-sliced.
- Workers must not touch typed `Array`s of Nodes (type validation calls `get_script()`), so the finished-chunk queue is untyped. Physics-server calls (`create_trimesh_collision`) stay on the main thread: `physics/3d/run_on_separate_thread` is off.
- Mesh creation (`ArrayMesh.add_surface_from_arrays`) on workers is serialized behind a mutex: with many threads creating meshes at once, `stress_move.gd` crashed the engine in ~6% of runs (0 of 60 with the mutex). The rest of chunk generation is not serialized.
- `ChunkManager._exit_tree()` waits for its tasks; workers use the manager's members, so none may outlive it.

Still open:

- Even after batching, per-chunk cost is dominated by `WorldNoise` sampling (4–6 native calls per point) and per-vertex `get_biome_color()` (6 native calls). Deriving colour from the surface distance, a baked table for the `Curve`s, or a native/GPU noise pass would remove most of it, at the cost of slightly different values or a native toolchain.
- The first reconcile (the whole initial leaf set) is not time-sliced: ~100 ms behind the loading screen.
- Transition cells fix seams across *faces* only. Chunks of different LOD that share just a corner or edge can still leave cracks (issue #5).
- Non-current planets only keep a single root chunk (cheap), but check the transition when a planet becomes current.
- Scale: planets up to size 19 are allowed; large sizes stress float precision, which is why the project uses the double-precision Godot build.
