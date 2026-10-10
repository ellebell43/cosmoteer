extends SceneTree
## Flies the player along the surface and counts "holes": chunks that the exact horizon and far-plane tests (margin 0) at the player's current position say are visible, but that have no mesh because they are culled or still being generated after being culled. Zero holes means culling never showed a gap.
##   godot --headless --path . -s tools/bench/check_cull_flight.gd -- <octree_depth> <seconds> <m_per_s> [altitude]
var depth := 9
var move_seconds := 30.0
var speed := 30.0
var altitude := 2.0
var started := false
var phase := "load"
var t0 := 0
var last_t := 0
var noise
var player: Node3D
var mgr
var center: Vector3
var dir := Vector3(0.577, 0.577, 0.577).normalized()
var tangent: Vector3
var surface_r := 0.0
const RAMP_SECONDS := 3.0
var shown := 0
var hole_frames := 0
var max_holes := 0
var frames := 0
var culled_sum := 0

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
		if args.size() > 3: altitude = float(args[3])
		Engine.max_fps = 60
		root.get_node("Utils").debug = false
		var cont: Curve = load("res://environment/world-generation/slope_curves/default_continent_curve.tres")
		var mount: Curve = load("res://environment/world-generation/slope_curves/default_mountain_curve.tres")
		var volume := 16.0 * pow(2, depth)
		var floor_distance := int(volume / 2) - 500
		noise = load("res://environment/world-generation/world-noise.gd").new(1, volume, floor_distance, 0, cont, mount)
		center = Vector3(volume, volume, volume) / 2
		var r := floor_distance + 100.0
		while r > floor_distance - 100.0:
			var pp := center + dir * r
			if noise.sample(pp.x, pp.y, pp.z) < 0.0: surface_r = r; break
			r -= 0.25
		var ps := GDScript.new()
		ps.source_code = "extends \"res://actors/player.gd\"\nfunc _ready(): pass\nfunc _physics_process(_d): pass\nfunc _input(_e): pass\n"
		ps.reload()
		player = ps.new()
		root.add_child(player)
		player.global_position = center + dir * (surface_r + altitude)
		mgr = load("res://environment/world-generation/chunk-manager.gd").new(player, 1, depth, noise, true)
		root.add_child(mgr)
		tangent = dir.cross(Vector3.UP).normalized()
		t0 = now; last_t = now
		return false
	var dt := float(now - last_t) / 1e6
	last_t = now
	if phase == "load":
		if _idle(mgr): phase = "move"; t0 = now
		elif now - t0 > 120e6: print("TIMEOUT load"); quit()
	elif phase == "move":
		var p: Vector3 = player.global_position - center
		# speed up over the first RAMP_SECONDS like a player would, instead of starting at full speed
		var ramp := clampf(float(now - t0) / 1e6 / RAMP_SECONDS, 0.05, 1.0)
		p += tangent * speed * ramp * min(dt, 0.05)
		p = p.normalized() * (surface_r + altitude)
		player.global_position = center + p
		tangent = (tangent - p.normalized() * tangent.dot(p.normalized())).normalized()
		frames += 1
		var holes := 0
		var culled := 0
		var cull_distance: float = mgr._get_cull_distance()
		var pos: Vector3 = player.global_position
		for key in mgr.active_chunk_set:
			var c = mgr.active_chunk_set[key]
			if c.is_culled: culled += 1
			elif c.mesh_data != null or c.is_empty or c.thread_id == -1: continue
			if not (mgr.is_hidden(pos, key, 0.0) or mgr.is_beyond_view(pos, key, 0.0, cull_distance)):
				holes += 1
				if shown < 4:
					shown += 1
					print("  hole: lod %d, %.0f m from the player, culled=%s, task running=%s, margin %.0f m, speed estimate %.0f m/s, t=%.1f s" % [key.w, pos.distance_to(Vector3(key.x, key.y, key.z) + Vector3.ONE * key.w * 8.0), str(c.is_culled), str(c.thread_id != -1), mgr.last_cull_margin, mgr.player_speed, float(now - t0) / 1e6])
		culled_sum += culled
		if holes > 0: hole_frames += 1
		max_holes = max(max_holes, holes)
		if float(now - t0) / 1e6 >= move_seconds:
			print("check_cull_flight: depth %d, %.0f m/s, altitude %.0f m: hole frames %d/%d, max simultaneous holes %d, culled chunks (avg) %.0f, margin at end %.0f m (latency %.2f s) -> %s" % [depth, speed, altitude, hole_frames, frames, max_holes, float(culled_sum) / max(frames, 1), mgr.last_cull_margin, mgr.cull_latency, "OK" if hole_frames == 0 else "HOLES"])
			quit()
	return false
