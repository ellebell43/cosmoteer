extends SceneTree
## End-state correctness test for ChunkManager. Loads a planet, flies the player quickly, stops, waits for the manager to settle, then checks invariants and compares the result with a manager that was freshly loaded at the final position.
##   godot --headless --path . -s tools/bench/check_settle.gd -- <octree_depth> <move_seconds> <m_per_s> [manager script path]
var depth := 7
var move_seconds := 12.0
var speed := 30.0
var mgr_path := "res://environment/world-generation/chunk-manager.gd"
var started := false
var phase := "load"
var t0 := 0
var noise
var player: Node3D
var mgr
var fresh
var center: Vector3
var dir := Vector3(0.577, 0.577, 0.577).normalized()
var tangent: Vector3
var surface_r := 0.0
var last_t := 0

func _idle(m) -> bool:
	return m.first_iteration_complete and m.leaf_job_task == -1 and not m._leaf_result_ready and m._phase == 0 and m.pending_tasks.is_empty() and m._build_queue.is_empty() and m._finished_chunks.is_empty() and m.pending_chunk_set.is_empty() and m.retiring_chunk_set.is_empty() and m.ready_to_die_chunk_set.is_empty()

func _process(_d: float) -> bool:
	var now := Time.get_ticks_usec()
	if not started:
		started = true
		var args := OS.get_cmdline_user_args()
		if args.size() > 0: depth = int(args[0])
		if args.size() > 1: move_seconds = float(args[1])
		if args.size() > 2: speed = float(args[2])
		if args.size() > 3: mgr_path = args[3]
		Engine.max_fps = 60
		root.get_node("Utils").debug = false
		var cont: Curve = load("res://environment/world-generation/slope_curves/default_continent_curve.tres")
		var mount: Curve = load("res://environment/world-generation/slope_curves/default_mountain_curve.tres")
		var volume := 16.0 * pow(2, depth)
		var floor_distance := int(volume / 2) - 500
		noise = load("res://environment/world-generation/world-noise.gd").new(1, volume, floor_distance, 0, cont, mount)
		center = Vector3(volume, volume, volume) / 2
		var prev := -1.0
		for r in range(floor_distance - 200, floor_distance + 300):
			var p := center + dir * r
			if prev < 0.0 and noise.sample(p.x, p.y, p.z) > 0.0: surface_r = r; break
			prev = noise.sample(p.x, p.y, p.z)
		var ps := GDScript.new()
		ps.source_code = "extends \"res://actors/player.gd\"\nfunc _ready(): pass\nfunc _physics_process(_d): pass\nfunc _input(_e): pass\n"
		ps.reload()
		player = ps.new()
		root.add_child(player)
		player.global_position = center + dir * (surface_r + 2.0)
		mgr = load(mgr_path).new(player, 1, depth, noise, true)
		root.add_child(mgr)
		tangent = dir.cross(Vector3.UP).normalized()
		t0 = now; last_t = now
		return false
	var dt := float(now - last_t) / 1e6
	last_t = now
	match phase:
		"load":
			if _idle(mgr): phase = "move"; t0 = now; print("loaded in %.1f s" % [float(now - 0) / 1e6 if false else 0.0])
			if now - t0 > 120e6: print("TIMEOUT load"); quit()
		"move":
			var p: Vector3 = player.global_position - center
			p += tangent * speed * min(dt, 0.05)
			p = p.normalized() * (surface_r + 2.0)
			player.global_position = center + p
			tangent = (tangent - p.normalized() * tangent.dot(p.normalized())).normalized()
			if float(now - t0) / 1e6 >= move_seconds: phase = "settle"; t0 = now
		"settle":
			if _idle(mgr):
				phase = "fresh"; t0 = now
				# the settled leaf set belongs to the position of the last octree pass, so compare at that position
				player.global_position = mgr.prev_player_pos
				fresh = load(mgr_path).new(player, 1, depth, noise, true)
				root.add_child(fresh)
			elif now - t0 > 90e6:
				print("TIMEOUT settle: pending_tasks=%d pending_set=%d retiring=%d rtd=%d phase=%d job=%d ready=%s bq=%d" % [mgr.pending_tasks.size(), mgr.pending_chunk_set.size(), mgr.retiring_chunk_set.size(), mgr.ready_to_die_chunk_set.size(), mgr._phase, mgr.leaf_job_task, str(mgr._leaf_result_ready), mgr._build_queue.size()])
				_dump_stuck()
				quit()
		"fresh":
			if _idle(fresh): _compare(); quit()
			elif now - t0 > 120e6: print("TIMEOUT fresh"); quit()
	return false

func _compare() -> void:
	var problems := 0
	var a: Dictionary = mgr.active_chunk_set
	var b: Dictionary = fresh.active_chunk_set
	var stale_keys := 0
	for k in a:
		if not mgr.new_chunk_set.has(k): stale_keys += 1
	for k in mgr.new_chunk_set:
		if not a.has(k): problems += 1
	print("settled: active=%d leaves=%d (active not in leaf set: %d)  fresh active=%d" % [a.size(), mgr.new_chunk_set.size(), stale_keys, b.size()])
	var mesh_mismatch := 0; var mask_mismatch := 0; var missing := 0; var with_mesh := 0; var wrong_state := 0; var tree_nodes := 0
	var cull_differs := 0; var cull_inconsistent := 0
	# Culling depends on the margin, which depends on how fast the player was moving, so the settled and the fresh manager may cull different leaves. Each manager must be consistent with its own leaf set, and chunks visible in both must match.
	for k in a:
		var cc = a[k]
		# (empty chunks are never culled: they have nothing to drop)
		if "is_culled" in cc and not cc.is_empty:
			var flagged: bool = (mgr.new_chunk_set.get(k, 0) & 64) != 0
			if cc.is_culled != flagged: cull_inconsistent += 1
			if cc.is_culled and (cc.mesh_data != null or cc.get_parent() != null): cull_inconsistent += 1
		if cc.mesh_data != null: with_mesh += 1
	for k in b:
		if not a.has(k): missing += 1; continue
		var ca = a[k]; var cb = b[k]
		if ca.state != 1: wrong_state += 1
		if "is_culled" in ca and ca.is_culled != cb.is_culled: cull_differs += 1; continue
		var ma = ca.mesh_data; var mb = cb.mesh_data
		if (ma == null) != (mb == null): mesh_mismatch += 1
		elif ma != null:
			if ma.surface_get_array_len(0) != mb.surface_get_array_len(0): mesh_mismatch += 1
			if ca.built_transition_mask != cb.built_transition_mask: mask_mismatch += 1
			if ca.get_parent() == null: problems += 1
	for c in mgr.get_children():
		if c.has_method("build_mesh"): tree_nodes += 1
	print("compare vs fresh load: missing=%d mesh_mismatch=%d mask_mismatch=%d wrong_state=%d  chunks_with_mesh=%d chunk_nodes_in_tree=%d other_problems=%d  (culled in one manager only: %d, culled but inconsistent: %d)" % [missing, mesh_mismatch, mask_mismatch, wrong_state, with_mesh, tree_nodes, problems, cull_differs, cull_inconsistent])
	print("RESULT: ", "OK" if (missing + mesh_mismatch + mask_mismatch + wrong_state + problems + stale_keys + cull_inconsistent) == 0 and tree_nodes == with_mesh else "FAILED")

## Debug aid: classifies chunks that stay RETIRING after the manager went quiet.
func _dump_stuck() -> void:
	var kinds := {}
	var shown := 0
	for k in mgr.retiring_chunk_set:
		var chunk = mgr.retiring_chunk_set[k]
		# nearest active ancestor
		var anc := -1
		var key: Vector4i = k
		var depth_up := 0
		while key.w < mgr.chunk_count * 2:
			key = mgr.get_parent_key(null, key)
			depth_up += 1
			if mgr.active_chunk_set.has(key): anc = depth_up; break
		# active volume below
		var child_volume := 0
		for ak in mgr.active_chunk_set:
			if ak.w < k.w and _inside(ak, k):
				var side: int = ak.w * 16
				child_volume += side * side * side
		var side2: int = k.w * 16
		var kind := "ancestor_active_at_level_%d" % anc if anc != -1 else ("children_cover %d/%d" % [child_volume, side2 * side2 * side2])
		kinds[kind] = kinds.get(kind, 0) + 1
		if shown < 4:
			shown += 1
			print("  stuck key=%s in_new_set=%s volume_counter=%d %s" % [k, mgr.new_chunk_set.has(k), chunk.volume_counter, kind])
	print("stuck kinds: ", kinds)

func _inside(child: Vector4i, parent: Vector4i) -> bool:
	var ps: int = parent.w * 16
	return child.x >= parent.x and child.y >= parent.y and child.z >= parent.z and child.x < parent.x + ps and child.y < parent.y + ps and child.z < parent.z + ps
