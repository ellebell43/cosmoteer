extends SceneTree
## Mesh equivalence check. Generates chunks at fixed positions/LODs/masks and prints a hash of the mesh arrays.
## Run before and after an optimization that should not change terrain output: the hashes must match.
##   godot --headless --path . -s tools/bench/bench_hash.gd
## Pass `-- exact` to hash raw float bits (default); `-- tol` also prints vertex/triangle counts only.

var started := false

func _process(_d: float) -> bool:
	if started: return false
	started = true
	root.get_node("Utils").debug = false
	var noise = load("res://environment/world-generation/world-noise.gd").new(1, 2048.0, load("res://environment/world-generation/terrain-params.gd").new())
	var ChunkS: GDScript = load("res://environment/world-generation/chunk.gd")
	var dirs := [Vector3(0.577, 0.577, 0.577), Vector3(0.9, 0.3, 0.1), Vector3(0.1, 0.95, 0.3), Vector3(0.3, 0.2, 0.93), Vector3(-0.7, 0.5, 0.5), Vector3(0.2, -0.8, 0.5)]
	var total := PackedByteArray()
	var n_chunks := 0
	var n_tris := 0
	for d: Vector3 in dirs:
		d = d.normalized()
		var prev := -1.0
		var hit := Vector3.ZERO
		for r in range(400, 700):
			var p := Vector3(1024, 1024, 1024) + d * r
			var s: float = noise.sample(p.x, p.y, p.z)
			if prev < 0.0 and s > 0.0: hit = p; break
			prev = s
		for lod in [1, 2, 8, 32]:
			for mask in [0, 1, 6, 9, 63]:
				var span: float = 16.0 * lod
				var off: Vector3 = Vector3(floor(hit.x / span), floor(hit.y / span), floor(hit.z / span)) * span
				var ch = ChunkS.new(16, noise, off, lod)
				ch.generate_mesh_data(mask)
				if ch.mesh_data == null: continue
				var arrays: Array = ch.mesh_data.surface_get_arrays(0)
				for idx in [Mesh.ARRAY_VERTEX, Mesh.ARRAY_NORMAL, Mesh.ARRAY_COLOR]:
					total.append_array(var_to_bytes(arrays[idx]))
				n_chunks += 1
				n_tris += arrays[Mesh.ARRAY_VERTEX].size() / 3
	print("HASH chunks=%d tris=%d sha256=%s" % [n_chunks, n_tris, total.hex_encode().sha256_text()])
	quit()
	return false
