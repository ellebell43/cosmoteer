extends SceneTree
## Smoke test of the real game scene. Waits for the loading screen, then keeps the player flying (the game drops them to the ground, where, with the first octree pass made before the planet is flagged current, they fall through the coarse root chunk until they have moved 10 m), nudges them past the movement threshold, and measures how long it takes until a ray straight down (80 m) hits a LOD 1 collider (layer 2 "Planet").
##   godot --headless --path . -s tools/bench/check_game_scene.gd
var sys: Node
var frame := 0
var ready_frame := -1
var nudge_frame := -1
var hold_pos: Vector3
var hit_after := -1
var started_usec := 0

func _process(_d: float) -> bool:
	frame += 1
	if frame == 1:
		seed(7) # the planet picks its spawn direction and rotation axis with randf()
		sys = load("res://environment/system.tscn").instantiate()
		root.add_child(sys)
		return false
	if sys == null or not is_instance_valid(sys.player): return false
	var player = sys.player
	if ready_frame == -1:
		if sys.ready_for_player:
			ready_frame = frame
			print("loading screen finished at frame %d" % frame)
		return false
	player.fly_mode = true
	if frame == ready_frame + 5:
		# move 12 m along the surface to pass the 10 m movement threshold
		var up: Vector3 = (player.global_position - sys.get_node("Planet").global_position).normalized()
		var side: Vector3 = up.cross(Vector3.UP).normalized()
		player.global_position += side * 12.0
		nudge_frame = frame
		started_usec = Time.get_ticks_usec()
	if nudge_frame != -1 and hit_after == -1 and frame % 4 == 0:
		_probe(player)
	if hit_after != -1 or frame > ready_frame + 3000:
		var cm = sys.get_node("Planet").chunk_manager
		var with_body := 0
		for c in cm.active_chunk_set.values():
			if c.lod_step == 1 and c.mesh_data != null: with_body += 1
		print("collider under player: %s (%.2f s after the nudge); active chunks=%d, LOD 1 chunks with mesh=%d" % ["yes" if hit_after != -1 else "NO", float(hit_after) / 1e6, cm.active_chunk_set.size(), with_body])
		print("RESULT: ", "OK" if hit_after != -1 else "FAILED")
		quit()
	return false

func _probe(player: Node3D) -> void:
	var planet_pos: Vector3 = sys.get_node("Planet").global_position
	var down: Vector3 = (planet_pos - player.global_position).normalized()
	var query := PhysicsRayQueryParameters3D.create(player.global_position, player.global_position + down * 80.0, 2)
	var hit := player.get_world_3d().direct_space_state.intersect_ray(query)
	if not hit.is_empty(): hit_after = Time.get_ticks_usec() - started_usec
