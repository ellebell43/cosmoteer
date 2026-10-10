# World generation

Code lives in `environment/world-generation/`.

## Pipeline overview

1. `Planet._ready()` builds a `WorldNoise` from `world_seed`, volume size, `floor_distance`, `sea_level_modifier`, and the two `Curve` resources (`continent_curve`, `mountain_curve`; defaults in `slope_curves/`).
2. `ChunkManager` runs an **octree** over the noise volume. Cells near the player split into finer cells; far cells stay coarse. Each leaf is a chunk key `Vector4i(x, y, z, lod_step)`.
3. Each leaf becomes a `Chunk` whose mesh is generated on a `WorkerThreadPool` thread using **Transvoxel** (Marching Cubes + transition cells for LOD seams).
4. Finished tasks are drained on the main thread in `_process`, capped at `MAXIMUM_BUILD_TIME` (µs) per frame, and `build_mesh()` creates the actual mesh.

## WorldNoise: the scalar field

`sample(x, y, z)` returns `shell_bias - elevation * FLOOR_BIAS`. The surface is where it crosses 0.

- `shell_bias = (distance_from_center - sea_level) * FLOOR_BIAS`: turns the volume into a sphere.
- `get_elevation_at_point`:
  - `continent_noise` (Perlin FBM, low freq) → run through `continent_curve` → `base_elevation`
  - `mountain_noise` (ridged simplex) scaled by `mountain_curve.sample(base_elevation)` × `MOUNTAIN_AMPLITUDE`, so mountains only appear at elevations the curve allows
  - plus small `hill_noise` and `detail_noise` terms
- `get_biome_color` maps elevation bands to vertex colours (deep water → water → sand → grass → rock).
- `BIAS_THRESHOLD`: used by `Chunk._determine_if_cell_is_empty()` to skip sampling cells that are certainly all-air/all-solid.

Tuning knobs: noise frequencies/octaves in `WorldNoise._init`, the amplitude constants, and the two curves. Curve domains/ranges are documented on the `@export` vars in `planet.gd`.

## Chunk lifecycle

`Chunk.chunk_state`: `PROCESSING → ACTIVE → RETIRING → READY_TO_DIE → freed`

ChunkManager keeps one dictionary per stage (`pending_`, `active_`, `retiring_`, `ready_to_die_chunk_set`, plus `new_chunk_set` for the desired leaves from the latest octree pass).

- Player moves ≥ `player_movement_threshold` (10 m): re-run `_octree_iterate()` → new desired set.
- `_find_masks()` (on a worker thread) computes each leaf's 6-bit **transition mask**: which faces border a coarser neighbour and need transition cells.
- `_load_new_chunks()` reconciles desired vs. existing: revive retiring/ready-to-die chunks, update masks on active ones, spawn brand-new ones.
- `_mark_retiring_chunks()` moves active chunks no longer wanted to RETIRING; they keep rendering until replacements are ready, which prevents LOD "popping".
- `_check_retiring_chunks()` / `_iterate_through_parents()`: a retiree is released when its volume is covered by active replacements (`volume_counter`) or by an active parent.
- `_kill_dead_chunks()` fades the mesh out with a tween, then `queue_free()`s, but only after its worker task has finished.

## Transvoxel notes

- Lookup tables in `transvoxel-lut.gd` (large, vendored-style data. Don't read it unless the task is about it).
- `Chunk.basis_table` and `BASIS_TABLE` enum map each of the 6 faces to U/V/N axes and plane.
- Known gap: transition cells fix seams across *faces* only. Chunks of different LOD that share just a corner or edge can still leave cracks (issue #5).
- `Chunk.wireframe_mode` swaps the chunk material for `assets/textures/wireframe-material.tres` (shader: `assets/shaders/wireframe.gdshader`). It's the debug view for inspecting seams.
- Mask bit order: `x, y, z, -x, -y, -z` (bits 0–5).
- `built_transition_mask` vs. `desired_transition_mask`: a chunk remeshes when they differ and it has no running task.

## Performance notes / things to watch

- The ChunkManager keeps per-stage microsecond timers (`get_timing_snapshot()`), shown by the debug overlay. Measure before optimizing.
- Mesh generation is off-thread; mesh *building* and the retire/kill passes run on the main thread. Main-thread cost is the usual bottleneck.
- `_load_new_chunks()` repeats the "spawn a generate_mesh_data task" block four times (plus once in `_load_octree_chunk`); a candidate for consolidation (a refactor I should do myself).
- `_find_masks()` runs on a worker thread while reading `new_chunk_set`, which the main thread clears and refills in `_process`. Guarded only by the single `find_masks_task` handle, so worth reviewing for races.
- `Chunk.generate_mesh_data()` returns early for empty cells (`_determine_if_cell_is_empty`), so many chunks have `mesh_data == null` and never build a mesh.
- Non-current planets only keep a single root chunk (cheap), but check the transition when a planet becomes current.
- Scale: planets up to size 19 are allowed; large sizes stress float precision, which is why the project uses the double-precision Godot build.
