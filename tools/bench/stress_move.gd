extends SceneTree
## Crash stress test: loads a planet, flies the player fast for a while, prints DONE and quits. A run that dies before DONE is a crash in the chunk pipeline (a crash while quitting with tasks in flight is expected for managers that do not drain their tasks).
##   godot --headless --path . -s tools/bench/stress_move.gd -- <octree_depth> <seconds> <m_per_s> [manager script path]
var depth := 8
var seconds := 6.0
var speed := 100.0
var mgr_path := "res://environment/world-generation/chunk-manager.gd"
var started := false
var player: Node3D
var center: Vector3
var dir := Vector3(0.577, 0.577, 0.577).normalized()
var tangent: Vector3
var surface_r := 0.0
var t0 := 0
var last_t := 0

func _process(_d: float) -> bool:
	var now := Time.get_ticks_usec()
	if not started:
		started = true
		var args := OS.get_cmdline_user_args()
		if args.size() > 0: depth = int(args[0])
		if args.size() > 1: seconds = float(args[1])
		if args.size() > 2: speed = float(args[2])
		if args.size() > 3: mgr_path = args[3]
		Engine.max_fps = 60
		root.get_node("Utils").debug = false
		var cont: Curve = load("res://environment/world-generation/slope_curves/default_continent_curve.tres")
		var mount: Curve = load("res://environment/world-generation/slope_curves/default_mountain_curve.tres")
		var volume := 16.0 * pow(2, depth)
		var floor_distance := int(volume / 2) - 500
		var noise = load("res://environment/world-generation/world-noise.gd").new(1, volume, floor_distance, 0, cont, mount)
		center = Vector3(volume, volume, volume) / 2
		var prev := -1.0
		for r in range(floor_distance - 200, floor_distance + 300):
			var p := center + dir * r
			var s: float = noise.sample(p.x, p.y, p.z)
			if prev < 0.0 and s > 0.0: surface_r = r; break
			prev = s
		var ps := GDScript.new()
		ps.source_code = "extends \"res://actors/player.gd\"\nfunc _ready(): pass\nfunc _physics_process(_d): pass\nfunc _input(_e): pass\n"
		ps.reload()
		player = ps.new()
		root.add_child(player)
		player.global_position = center + dir * (surface_r + 2.0)
		root.add_child(load(mgr_path).new(player, 1, depth, noise, true))
		tangent = dir.cross(Vector3.UP).normalized()
		t0 = now; last_t = now
		return false
	var dt := float(now - last_t) / 1e6
	last_t = now
	var p: Vector3 = player.global_position - center
	p += tangent * speed * min(dt, 0.05)
	p = p.normalized() * (surface_r + 2.0)
	player.global_position = center + p
	tangent = (tangent - p.normalized() * tangent.dot(p.normalized())).normalized()
	if float(now - t0) / 1e6 >= seconds:
		print("DONE")
		quit()
	return false
