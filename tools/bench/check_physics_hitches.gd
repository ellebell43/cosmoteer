extends SceneTree
## Does the player's physics hitch on a planet of this size and day length? Loads the real game scene, puts the player on the ground, and measures the frames while it stands there with no input. The planet turns once per day, so the surface speed is angular_speed * radius; the larger the planet, the more `move_and_slide()` has to sweep per physics tick.
##   godot --headless --path . -s tools/bench/check_physics_hitches.gd -- <size> <day minutes> [seconds] [seed]
## A bare headless frame takes about 6.9 ms; a frame that contains a physics step takes that plus the step. "Step cost" is that excess. The verdict is OK when no frame is longer than 16.7 ms (misses 60 fps) and the player neither fell through the planet nor drifted off the surface point. The cost depends on the terrain under the player, so run several seeds (the seed picks the spawn point).
const BARE_FRAME_MS := 6.9
const BUDGET_MS := 16.7
var sys: Node
var planet: Node
var player: Node
var size := 7
var minutes := 20
var seconds := 10.0
var frame := 0
var ready_frame := -1
var started_load := 0
var t_ready := 0
var t_last := 0
var nudges := 0
var next_nudge := 0.2
var dropped_at := -1.0
var sample_start := -1.0
var start_local := Vector3.ZERO
var start_up := 0.0
var frames: Array[float] = []

func _process(_d: float) -> bool:
	frame += 1
	var now := Time.get_ticks_usec()
	if frame == 1:
		var args := OS.get_cmdline_user_args()
		size = int(args[0]); minutes = int(args[1])
		if args.size() > 2: seconds = float(args[2])
		seed(int(args[3]) if args.size() > 3 else 7) # the planet picks its spawn direction with randf()
		sys = load("res://environment/system.tscn").instantiate()
		planet = sys.get_node("Planet")
		planet.size = size
		planet.day_length_minutes = minutes
		root.add_child(sys)
		started_load = now
		return false
	player = sys.player
	if ready_frame == -1:
		if sys.ready_for_player: ready_frame = frame; t_ready = now; t_last = now
		elif now - started_load > 120e6: print("size %d: loading did not finish" % size); quit()
		return false
	var since := float(now - t_ready) / 1e6
	# The first octree pass only makes the root chunk (see docs/world-generation.md), so move the player past the movement threshold once the planet is the current world, and again every 4 s until there is ground
	if planet.is_current_world and dropped_at < 0.0 and since > next_nudge:
		var up: Vector3 = (player.global_position - planet.global_position).normalized()
		player.global_position += up.cross(Vector3.UP).normalized() * 30.0
		nudges += 1
		next_nudge = since + 4.0
	if dropped_at < 0.0 and since > 8.0 and _manager_idle():
		var ground := _ground_point()
		if ground != Vector3.INF:
			player.global_position = ground + (ground - planet.global_position).normalized() * 1.2
			player.velocity = Vector3.ZERO
			dropped_at = since
	player.fly_mode = dropped_at < 0.0
	if sample_start < 0.0 and dropped_at >= 0.0 and since > dropped_at + 4.0 and _manager_idle():
		sample_start = since
		start_local = planet.to_local(player.global_position)
		start_up = start_local.length()
	if sample_start >= 0.0: frames.append(float(now - t_last) / 1000.0)
	t_last = now
	if (sample_start >= 0.0 and since > sample_start + seconds) or since > 60.0: _report()
	return false

func _report() -> void:
	if sample_start < 0.0:
		print("size %d, %d min day: FAILED, the player never got onto the ground" % [size, minutes])
		quit(); return
	var step_cost: Array[float] = []
	var over_budget := 0
	for f in frames:
		if f > BARE_FRAME_MS + 1.6: step_cost.append(f - BARE_FRAME_MS)
		if f > BUDGET_MS: over_budget += 1
	step_cost.sort()
	var sum := 0.0
	for v in step_cost: sum += v
	var local_now: Vector3 = planet.to_local(player.global_position)
	var drift := local_now.distance_to(start_local)
	var stayed := drift < 10.0
	var verdict := "OK" if over_budget == 0 and stayed else "HITCHES" if stayed else "FELL OFF THE SURFACE"
	print("size %d, %d min day (surface speed %.0f m/s): step cost ms avg %.1f p95 %.1f max %.1f | frames over %.1f ms: %d of %d | drift %.1f m -> %s" % [size, minutes, planet.angular_speed * planet.floor_distance, sum / max(step_cost.size(), 1), step_cost[min(step_cost.size() - 1, int(0.95 * step_cost.size()))] if not step_cost.is_empty() else 0.0, step_cost[-1] if not step_cost.is_empty() else 0.0, BUDGET_MS, over_budget, frames.size(), drift, verdict])
	quit()

## The hit point of a ray from 60 m above the player to 120 m below it against the planet's colliders (layer 2), or Vector3.INF.
func _ground_point() -> Vector3:
	var up: Vector3 = (player.global_position - planet.global_position).normalized()
	var from: Vector3 = player.global_position + up * 60.0
	var query := PhysicsRayQueryParameters3D.create(from, from - up * 180.0, 2)
	var hit: Dictionary = player.get_world_3d().direct_space_state.intersect_ray(query)
	return hit.position if not hit.is_empty() else Vector3.INF

func _manager_idle() -> bool:
	var cm = planet.chunk_manager
	return cm.pending_tasks.is_empty() and cm._phase == 0 and cm.leaf_job_task == -1 and not cm._leaf_result_ready and cm._build_queue.is_empty()
