# Conventions

These describe the style the existing code already follows. When reviewing my code, flag deviations; when explaining, use these names.

## GDScript

- Godot 4 syntax; indent with tabs.
- Static typing where practical: `var x := 5`, `func f(a: int) -> void`, typed collections (`Dictionary[Vector4i, Chunk]`, `Array[PackedInt32Array]`). Flag untyped signatures as review feedback, but don't treat them as bugs.
- `class_name` on scripts other code references (`Player`, `Planet`, `ChunkManager`, `Chunk`, `WorldNoise`).
- Doc comments use `##` above exported/important members; `#` for inline notes. Use `# ====== SECTION ======` banners to group large scripts.
- `@export` for designer-tunable values, `@onready` for node refs (prefer `%UniqueName` nodes).
- Private helpers prefixed with `_`; unused params prefixed `_` (and `@warning_ignore(...)` where intentional).
- Signals: global events go through the `Utils` autoload bus; local parent/child communication uses direct signals or calls.
- Debug output is gated by `Utils.debug`.

## Naming

- Scripts and scene files: existing mix of `kebab-case` (`chunk-manager.gd`, `world-noise.gd`) and `snake_case` (`start_screen.tscn`, `slope_curves/`). Pick one for new files. **Decision pending:** note it here once decided (Godot's own convention is snake_case).
- Constants: `UPPER_SNAKE_CASE`. Variables/functions: `snake_case`. Classes/enums types: `PascalCase`. Note `Chunk.chunk_state` is lowercase, an inconsistency to fix eventually.

## Repo

- Feature branches off `master`; small focused commits with short imperative messages.
- Every `.gd` has a committed `.uid` file.
- Units: 1 Godot unit = 1 meter. Time-measuring code uses microseconds (`Time.get_ticks_usec()`).
- Human-made code, art, and music only. See the README AI disclaimer and CLAUDE.md.
