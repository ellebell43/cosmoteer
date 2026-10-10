# World generation

Code lives in `environment/world-generation/`.

## Pipeline overview

1. `Planet._ready()` builds a `WorldNoise` from `world_seed`, volume size, `floor_distance`, `sea_level_modifier`, and the two `Curve` resources (`continent_curve`, `mountain_curve`; defaults in `slope_curves/`).
2. `ChunkManager` runs an **octree** over the noise volume. Cells near the player split into finer cells; far cells stay coarse. Each leaf is a chunk key `Vector4i(x, y, z, lod_step)`. The octree and each leaf's transition mask are computed on a **worker thread** into a fresh dictionary (`_compute_leaf_set()`); the main thread swaps it into `new_chunk_set` when done.
   After the masks, `_apply_cull()` flags every leaf that the planet hides from the player with `CULLED_BIT` (64, above the 6 mask bits) in the leaf's value. See "Culling" below.
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

Culled chunks are ACTIVE (see "Culling"). ChunkManager keeps one dictionary per stage (`pending_`, `active_`, `retiring_`, `ready_to_die_chunk_set`, plus `new_chunk_set` for the desired leaves from the latest octree pass).

- Player moves ≥ `player_movement_threshold` (10 m): start a **leaf job** on a worker (only one in flight; by the time it finishes the player has usually moved on, which simply starts the next one).
- A finished leaf set starts a **reconcile**, spread over frames with a `RECONCILE_BUDGET` (µs) per frame, in this order:
  1. `MARK` (`_mark_retiring_chunk`): active chunks no longer wanted become RETIRING. They keep rendering until replacements are ready, which prevents LOD "popping". This must run **before** `LOAD`: a retiree counts the volume of the replacements that become ACTIVE while it is RETIRING (`volume_counter`).
  2. `LOAD` (`_load_chunk`): revive retiring/ready-to-die chunks that are wanted again, update the desired mask of active/pending ones (and remesh when it differs from `built_transition_mask`), spawn brand-new ones.
  3. `CHECK` (`_check_retiring_chunk`): a retiree is released when any ancestor is ACTIVE (not just the parent: fast movement can skip LOD levels) or when active replacements fill its volume (`_iterate_through_parents`).
  4. `COVERAGE` (`_add_coverage`): only when nothing is generating and retirees are left. Recounts every retiree's covered volume exactly from the ACTIVE chunks, because the incremental counts can miss replacements that skipped levels.
  5. `KILL` (`_unload_octree_chunk`): fades the mesh out with a tween, then `queue_free()`s, but only after its worker task has been collected.
- A chunk becoming ACTIVE marks the manager "dirty"; a retire/kill pass (CHECK → COVERAGE → KILL) then runs at most every `CLEANUP_INTERVAL`, so retirees do not wait for the next 10 m of movement.
- A new chunk whose key is no longer in `new_chunk_set` when its task finishes is dropped instead of shown.

## Culling

Leaves the player can not see are flagged with `CULLED_BIT` in `new_chunk_set` (by `_apply_cull()` on the leaf-job worker, current world only; other planets keep their single root chunk). Two tests, both conservative on the leaf's bounding sphere:

- **Horizon** (`is_hidden(camera_pos, key, margin)`): the leaf lies wholly in the shadow of the planet's solid inner ball, radius `occluder_radius = sea_level - bias_threshold / FLOOR_BIAS` (the surface is never closer to the centre; 72 m below sea level with the default curves). It has to sit inside the cone of view rays that touch the ball, behind the circle where they touch it.
- **Far plane** (`is_beyond_view()`): the leaf is further than `_get_cull_distance()` from the camera. That is the distance to the *corners* of the far plane (`far * sqrt(1 + tan_x² + tan_y²)`, 7,429 m for the default camera at 16:9), because the camera can turn: a plain `far` would cull chunks that are visible in a corner of the screen. Read from `player.camera` (far, fov, keep-aspect) and the viewport; falls back to Camera3D's defaults when there is no camera. INF for a non-perspective camera.

Both tests assume the camera may be anywhere within `margin` of the player, and give up (cull nothing) when the camera is within the margin of the ball or of the leaf.

**The margin is dynamic** (`get_cull_margin()`): `player_movement_threshold + latency * player_speed * CULL_LATENCY_SAFETY (2)`.
- `player_speed` is measured on the main thread in the planet's frame (so planet rotation doesn't count). It rises at once and decays with a 2 s half-life.
- `latency` is the larger of: the slowest recently measured time for a chunk to come back into view (from the start of the leaf job that revealed it to its mesh being built; starts at 1 s, floor 0.5 s, 30 s half-life); the time since the leaf job started plus 0.25 s, for the slowest recent leaf set to be applied; and the time the chunks still waiting after being revealed have waited so far, so a backlog widens the margin before those chunks finish.
- Above `MAXIMUM_CULL_MARGIN` (300 m) nothing is culled: the player is too fast for culled chunks to be brought back in time. Near the surface the horizon test also stops by itself once the margin exceeds the ~72 m between the surface and the ball, so at ground level it works up to roughly 40–60 m/s; at altitude and for the far-plane test it works up to a few hundred m/s.

How culled leaves are handled:
- **They stay in `new_chunk_set`** (value `mask | CULLED_BIT`). Dropping them instead leaves their parents RETIRING forever, because the parent's volume is never fully covered (tested). Read the value as `value & TRANSITION_MASK_BITS` (the mask) and `value & CULLED_BIT`.
- Masks are computed **before** culling, so a culled neighbour still decides whether the leaf next to it gets transition cells.
- A new culled leaf becomes an ACTIVE chunk with no task, mesh or node (like a provably empty one) and `is_culled = true`. `_cull_chunk()` does the same to an existing chunk: frees its `ChunkMesh` and collider, removes it from the tree, resets `built_transition_mask`. A chunk that is visible again (`is_culled` cleared in `_load_chunk`) is meshed through `_remesh_if_needed()`, which skips culled chunks. A chunk whose data arrives after it was culled drops the data in `_finish_chunk()`.
- A settled manager and a fresh load can cull different leaves, because their margins depend on how fast the player was going. `check_settle.gd` therefore checks each manager against its own leaf set and compares meshes only where both show the chunk.

Measured effect (meshable leaves culled, player at the surface / at 3 km altitude, margin 32 m):

| Planet size | Horizon | Far plane | Either |
|---|---|---|---|
| 9 | 6% / 15% | 0% / 10% | 6% / 18% |
| 10 | 7% / 13% | 3% / 31% | 7% / 31% |
| 12 | 8% / 18% | 12% / 59% | 12% / 59% |
| 14 | 8% / 18% | 19% / 73% | 19% / 73% |

At the surface the far hemisphere holds only ~3% of the meshable leaves (it is coarse); the rest is the fine ring around the player, which a worst-case ball can't prove hidden even though real terrain hides most of it at ground level. Not done: culling to the camera frustum (Godot already does that when rendering, and turning would force regeneration of the fine ring).

Checks: `check_cull.gd` (rays through the real field for the horizon test, frustum planes for the far-plane test, no near leaf culled, masks unchanged), `check_cull_flight.gd` (no holes while flying; verified at up to 100 m/s at the surface and 200 m/s at 1 km on size 10, and 300 m/s at 500 m on size 12, where culling switches itself off), `check_settle.gd`.

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

## Planet size and physics

The chunk pipeline scales to size 19: leaves grow by about 480 and meshes by about 125 per size step (the octree already makes chunks coarser with distance, so it is its own render distance), and rendering stays at about 540 draw calls. What does not scale is the player's physics on a rotating planet. A day lasts `day_length_minutes` (20–30) on every planet, so the surface speed is `angular_speed * radius` (684 m/s at size 14, 20 minute day; 21,959 m/s at size 19). The player is carried with the surface by adding that speed to its velocity, so `move_and_slide()` sweeps tens to hundreds of meters per physics tick against the trimesh colliders.

Measured in the real scene (`tools/bench/check_physics_hitches.gd`, headless, player standing on the ground, 20 minute day, 10 spawn locations per size; "step cost" is the time a frame containing a physics step takes beyond a bare frame, bare frame 6.9 ms):

| Size | Surface speed | Step cost, avg of runs | Worst p95 | Locations with frames over 16.7 ms |
|---|---|---|---|---|
| 12 | 169 m/s | 3.2–4.6 ms | 6.0 ms | 0 of 4 |
| 13 | 341 m/s | 3.0–4.2 ms | 5.2 ms | 0 of 4 |
| **14** | 684 m/s | 2.9–5.8 ms | 8.4 ms | **0 of 10** |
| 15 | 1,370 m/s | 3.8–10.0 ms | 16.5 ms | 4 of 10 (8–297 of 1,450 frames) |
| 16 | 2,743 m/s | 6.1–8.5 ms | 14.3 ms | 3 of 4 (48–193 frames) |
| 17 | 5,488 m/s | 8.0–138 ms | 177 ms | 3 of 3 (28 to all 70 frames) |
| 19 | 21,959 m/s | the test can't finish | | 332 ms per frame while hovering |

Without rotation a standing player costs about 4.3 ms per step at any size. Size 14 is the largest size without hitches at a 20 minute day, so that is the maximum of `Planet.size`. A 30 minute day lowers the surface speed by a third (size 15 at 30 minutes, 913 m/s, was borderline: 1 frame in 1,452 over budget at one location), but the limit is set for the shortest day. Walking costs more than hovering, and the cost depends on the terrain under the player (more triangles to sweep through), which is why the locations differ. Carrying the player by rotating its position instead of adding to its velocity roughly halved the cost at size 19 (332 → 153 ms) but did not fix it, so the real lever would be to stop moving colliders relative to the player (for example by simulating the player in the planet's frame).

Still open:

- Even after batching, per-chunk cost is dominated by `WorldNoise` sampling (4–6 native calls per point) and per-vertex `get_biome_color()` (6 native calls). Deriving colour from the surface distance, a baked table for the `Curve`s, or a native/GPU noise pass would remove most of it, at the cost of slightly different values or a native toolchain.
- The first reconcile (the whole initial leaf set) is not time-sliced: ~100 ms behind the loading screen.
- **Pre-existing:** the first octree pass runs before the planet is flagged `is_current_world`, so it produces only the coarse root chunk. The loading screen therefore finishes after one task and releases the player, who falls through the coarse chunk until they have moved 10 m and the detailed terrain starts. `tools/bench/check_game_scene.gd` works around it by keeping the player in fly mode. (After that, ground collision appears ~3 s later; it took ~11 s with the original manager.)
- Transition cells fix seams across *faces* only. Chunks of different LOD that share just a corner or edge can still leave cracks (issue #5).
- Non-current planets only keep a single root chunk (cheap), but check the transition when a planet becomes current.
- Scale: planets are limited to size 14 by physics, not by chunk count (see "Planet size and physics" below). Large sizes also stress float precision, which is why the project uses the double-precision Godot build.
