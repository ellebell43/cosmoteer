extends SceneTree
## Compares the leaf set + transition masks of the current ChunkManager against a reference implementation (the original single-threaded code).
##   godot --headless --path . -s tools/bench/check_leaf_set.gd -- <path to reference chunk-manager.gd>
## The reference is `git show 14fa221:environment/world-generation/chunk-manager.gd` with the `class_name` line removed.
var started := false
func _process(_d: float) -> bool:
	if started: return false
	started = true
	var args := OS.get_cmdline_user_args()
	var ref_script: GDScript = load(args[0])
	var new_script: GDScript = load("res://environment/world-generation/chunk-manager.gd")
	var stub := GDScript.new()
	stub.source_code = "extends \"res://actors/player.gd\"\nfunc _ready(): pass\nfunc _physics_process(_d): pass\nfunc _input(_e): pass\n"
	stub.reload()
	var rng := RandomNumberGenerator.new()
	rng.seed = 3
	var mismatches := 0
	var total_leaves := 0
	for depth in [7, 9, 12]:
		var volume: int = 16 * (1 << depth)
		var player = stub.new()
		root.add_child(player)
		var ref = ref_script.new(player, 1, depth, null, true)
		var neu = new_script.new(player, 1, depth, null, true)
		root.add_child(ref)
		root.add_child(neu)
		for trial in 12:
			# positions inside the volume, near the surface radius, and a few outside it
			var p: Vector3 = Vector3(rng.randf(), rng.randf(), rng.randf()).normalized() * (volume * 0.5 - 500 + rng.randf_range(-40, 40)) + Vector3(volume, volume, volume) / 2
			if trial % 4 == 3: p = Vector3(rng.randf_range(-0.2, 1.2), rng.randf_range(-0.2, 1.2), rng.randf_range(-0.2, 1.2)) * volume
			player.global_position = p
			ref.new_chunk_set.clear()
			ref._octree_iterate()
			ref._find_masks()
			var a: Dictionary = ref.new_chunk_set
			var b: Dictionary = neu._compute_leaf_set(p, true)
			total_leaves += a.size()
			if a.size() != b.size():
				mismatches += 1
				print("SIZE mismatch depth=%d pos=%s ref=%d new=%d" % [depth, p, a.size(), b.size()])
				continue
			for k in a:
				if not b.has(k) or b[k] != a[k]:
					mismatches += 1
					print("MISMATCH depth=%d key=%s ref=%s new=%s" % [depth, k, a[k], b.get(k, "missing")])
					break
	print("leaf set check: %d leaves compared, %d mismatching trials -> %s" % [total_leaves, mismatches, "OK" if mismatches == 0 else "FAILED"])
	quit()
	return false
