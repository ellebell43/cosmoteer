extends SceneTree
## Spawn race test on the real game scene. The first octree pass must already be the full leaf set around the player (not just the coarse root chunk), and the player, released by the loading screen with gravity on, must not fall through the ground. Before the player claimed `current_world` in `_ready()`, the planet was only flagged current by the GravityArea's body_entered, which needs a physics step and could come after the first pass.
##   godot --headless --path . -s tools/bench/check_spawn_race.gd -- [seed] [seconds]
const FALL_LIMIT := 20.0
var sys: Node
var frame := 0
var first_pass_leaves := -1
var ready_frame := -1
var start_alt := 0.0
var min_alt := INF
var start_usec := 0
var seconds := 6.0

func _process(_d: float) -> bool:
	frame += 1
	if frame == 1:
		var args := OS.get_cmdline_user_args()
		seed(int(args[0]) if args.size() > 0 else 1) # the planet picks its spawn direction with randf()
		if args.size() > 1: seconds = float(args[1])
		sys = load("res://environment/system.tscn").instantiate()
		root.add_child(sys)
		return false
	var planet = sys.get_node("Planet")
	var cm = planet.chunk_manager
	var player = sys.player
	if first_pass_leaves == -1 and cm.first_iteration_complete:
		first_pass_leaves = cm.new_chunk_set.size()
		print("first octree pass: %d leaves (frame %d)" % [first_pass_leaves, frame])
	if ready_frame == -1:
		if sys.ready_for_player:
			ready_frame = frame
			start_usec = Time.get_ticks_usec()
			start_alt = player.global_position.distance_to(planet.global_position)
		return false
	min_alt = minf(min_alt, player.global_position.distance_to(planet.global_position))
	if float(Time.get_ticks_usec() - start_usec) / 1e6 > seconds:
		var fell: bool = start_alt - min_alt > FALL_LIMIT
		print("altitude from planet center: start %.1f m, lowest %.1f m over %.0f s" % [start_alt, min_alt, seconds])
		print("RESULT: ", "OK" if first_pass_leaves > 1 and not fell else "FAILED")
		quit()
	return false
