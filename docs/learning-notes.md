# Learning notes

Claude uses this to calibrate explanations. Keep it honest and short, and update it as things click.

## Comfortable with

(Seeded from what the code shows. Correct anything that's wrong.)
- GDScript fundamentals: signals, exports, typed variables, setters, `@onready`
- Godot scene tree and lifecycle (`_ready`, `_process`, `_physics_process`)
- Procedural noise: layering `FastNoiseLite`, shaping output with `Curve` resources
- Octree and LOD concepts, chunk streaming
- Basic threading with `WorkerThreadPool`

## Learning / want deeper explanations

(Fill in.)
- Transvoxel details: transition cells, corner/edge seams (issue #5)
- Thread safety: sharing data between worker tasks and the main thread
- Performance profiling in Godot
- Multiplayer architecture: server-authoritative, one star system per server

## How I like to be taught

- Explain the *why* before the *how*, and connect it to my existing code.
- Point at file and line, and for design questions ask what I think should happen before giving the answer.
- Give me an exercise ("try this yourself") rather than a finished solution.

## Concepts already explained (log)

- (date) topic: one-line takeaway
