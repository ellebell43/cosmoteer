# CLAUDE.md

Untitled Sandbox Game: a voxel sandbox where an entire star system is one seamless scene (no loading screens between planets). Godot 4.7, GDScript, double-precision build, Forward Plus renderer. See [README.md](README.md) for the game vision.

## Your role: author, on an experiment

**This repo is an experiment in AI-driven development.** It is a copy of the original human-written project (the history was intentionally dropped), and you now have free rein to build the game: design, write, refactor, and run the code. Unlike the original repo, AI-written code is expected here and is the point.

- You may create and edit any project file: `.gd`, `.tscn`, `.tres`, `.gdshader`, `project.godot`, docs, and so on.
- Own the work end to end: plan it, implement it, run the game to check it, fix what breaks, and commit it.
- Make your own design decisions within the game vision in the README. When a choice is genuinely the human's to make (scope, art direction, anything irreversible or outward-facing), ask. Otherwise pick a sensible default and say what you chose.
- Commit in small, logical steps on feature branches. Don't push, open PRs, or create remotes unless asked.
- Keep the docs in `docs/` accurate as the code changes, so they stay a reliable map of the project.
- Ask before deleting large amounts of existing code or art, and don't modify `blender/` or `assets/` source art destructively.
- The README's "AI Disclaimer" has been rewritten to say this repo is AI-authored after commit `99e0e55`. Keep it accurate.

## Docs (read the one relevant to the task)

- @docs/architecture.md: scene/node hierarchy, ownership, signals, seamless-system constraints
- @docs/world-generation.md: noise, octree LOD, chunk lifecycle, transvoxel seams, perf notes
- @docs/conventions.md: GDScript style and naming from the original project; follow it unless there's a good reason not to, and update it if you change it
- @docs/learning-notes.md: written for the original mentor workflow (what the original author understood vs. was learning). Treat it as background on the code's origins, not as a guide for how to behave

## Commands

Set `GODOT_BIN` to the double-precision Godot 4.7 editor binary (the path is in my local, gitignored `.vscode/settings.json`).

```bash
# run the game
"$GODOT_BIN" --path .
```

There is currently no test suite on this branch (GUT and `test/` were removed in `c731cb5`; `.gutconfig.json` remains). The wireframe debug material now lives in `assets/textures/` and `assets/shaders/`.

Custom slash commands live in `.claude/commands/`: `/explain`, `/review`, `/optimize`, `/teach`.
## Layout

```
actors/        Player (CharacterBody3D) scene + script
environment/   System scene/script; world-generation/ (Planet, ChunkManager, Chunk, WorldNoise, transvoxel LUT, slope_curves/)
interface/     Start screen, debug overlay
assets/ blender/   Art sources (human-made originals; don't overwrite)
docs/          Topic docs (imported above)
.claude/       Custom slash commands (and settings, if present)
utils.gd       "Utils" autoload: global signals and the debug flag
```

## Gotchas

- Work happens on feature branches; `master` is the main branch. The remote is `origin` (https://github.com/ellebell43/cosmoteer.git). Still only push when asked.
- Every `.gd` has a committed `.uid` file (Godot generates them). Commit new ones alongside new scripts; never delete them by hand.
- Godot also writes `.import` files and edits `project.godot`/`.tscn` itself when the editor opens; expect those diffs.
- Ignore `.godot/` when searching; it's generated.
- `transvoxel-lut.gd` is ~900 lines of lookup tables. Don't read it unless the task is about it.
- Collision layers: 1 = Player, 2 = Planet.
