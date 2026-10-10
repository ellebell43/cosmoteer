extends SceneTree
# Macro benchmark: real ChunkManager + a player flying over the surface.
#   godot --headless --path <repo> -s bench_manager.gd -- <octree_depth> <move_seconds> <speed_m_per_s>
# Frame rate is capped at 60 so movement per frame is realistic.

var depth := 7
var MGR_PATH := "res://environment/world-generation/chunk-manager.gd"
var move_seconds := 20.0
var speed := 10.0

var mgr: Node3D
var player: Node3D
var noise
var phase := "load"
var frame := 0
var t_phase_start := 0
var last_frame_t := 0
var surface_r := 0.0
var center: Vector3
var dir := Vector3(0.577, 0.577, 0.577).normalized()
var tangent := Vector3.ZERO

# per-phase frame samples (usec)
var proc_us: Array[int] = []      # ChunkManager._process cost as it reports itself
var frame_us: Array[int] = []     # wall time between frames (includes everything incl. physics/render)
var stage := {}                   # stage name -> Array of observed values (recorded on change)
var prev_stage := {}
var peak_pending := 0
var load_report := {}
var n_leaves_hist: Array[int] = []

const STAGES := ["octree_iterate_time", "find_masks_time", "load_new_chunks_time", "mark_retirees_time", "check_retirees_time", "kill_dead_chunks_time"]

var setup_done := false
var gen_sum := 0
var gen_n := 0
var gen_max := 0
func _on_gen(us: int) -> void:
	gen_sum += us; gen_n += 1; gen_max = max(gen_max, us)
func _initialize() -> void:
	pass

func _setup() -> void:
	setup_done = true
	var args := OS.get_cmdline_user_args()
	if args.size() > 0: depth = int(args[0])
	if args.size() > 1: move_seconds = float(args[1])
	if args.size() > 2: speed = float(args[2])
	if args.size() > 3: MGR_PATH = args[3]
	Engine.max_fps = 60
	root.get_node("Utils").debug = true
	root.get_node("Utils").chunk_generated.connect(_on_gen)
	print("[setup] worker max_threads setting=", ProjectSettings.get_setting("threading/worker_pool/max_threads", "unset"), " cpus=", OS.get_processor_count())

	var cont: Curve = load("res://environment/world-generation/slope_curves/default_continent_curve.tres")
	var mount: Curve = load("res://environment/world-generation/slope_curves/default_mountain_curve.tres")
	var volume := 16.0 * pow(2, depth)
	var floor_distance := int(volume / 2) - 500
	noise = load("res://environment/world-generation/world-noise.gd").new(1, volume, floor_distance, 0, cont, mount)
	center = Vector3(volume, volume, volume) / 2

	# find surface along dir
	var prev := -1.0
	for r in range(floor_distance - 200, floor_distance + 300):
		var p := center + dir * r
		var s: float = noise.sample(p.x, p.y, p.z)
		if prev < 0.0 and s > 0.0:
			surface_r = r
			break
		prev = s
	print("[setup] depth=%d volume=%d surface_r=%.0f" % [depth, volume, surface_r])

	var ps := GDScript.new()
	ps.source_code = """extends "res://actors/player.gd"
func _ready(): pass
func _physics_process(_d): pass
func _input(_e): pass
"""
	ps.reload()
	player = ps.new()
	root.add_child(player)
	player.global_position = center + dir * (surface_r + 2.0)

	var mgr_script: GDScript = load(MGR_PATH)
	mgr = mgr_script.new(player, 1, depth, noise, true)
	root.add_child(mgr)   # manager origin at world origin, so volume coords == global coords

	tangent = dir.cross(Vector3.UP).normalized()
	t_phase_start = Time.get_ticks_usec()
	last_frame_t = t_phase_start
	for s_name in STAGES: stage[s_name] = []; prev_stage[s_name] = -1

func _process(_delta: float) -> bool:
	if not setup_done:
		_setup()
		return false
	frame += 1
	var now := Time.get_ticks_usec()
	var fdt := now - last_frame_t
	last_frame_t = now

	if phase == "load":
		proc_us.append(mgr.process_time); frame_us.append(fdt)
		peak_pending = max(peak_pending, mgr.pending_tasks.size())
		_poll_stages()
		if mgr.first_iteration_complete and mgr.pending_tasks.is_empty() and mgr.pending_chunk_set.is_empty():
			load_report = {
				"wall_s": float(now - t_phase_start) / 1e6,
				"frames": frame,
				"leaves": mgr.new_chunk_set.size(),
				"active": mgr.active_chunk_set.size(),
				"with_mesh": _count_meshes(),
				"peak_pending": peak_pending,
				"nodes": _count_nodes(mgr),
			}
			var math_empty := 0; var sample_empty := 0
			for k in mgr.active_chunk_set:
				var c = mgr.active_chunk_set[k]
				if c.mesh_data == null:
					if c._determine_if_cell_is_empty(): math_empty += 1
					else: sample_empty += 1
			load_report["empty_decidable_by_O1_bounds_test"] = math_empty
			load_report["empty_needing_sampling"] = sample_empty
			_print_stats("LOAD PHASE", load_report)
			phase = "move"
			proc_us = []; frame_us = []; stage = {}; prev_stage = {}
			for s_name in STAGES: stage[s_name] = []; prev_stage[s_name] = -1
			peak_pending = 0
			t_phase_start = now
			frame = 0
		elif now - t_phase_start > 240_000_000:
			print("LOAD TIMEOUT"); quit()
	elif phase == "move":
		var dt := float(fdt) / 1e6
		# move along tangent, then re-project to constant radius so we hold altitude
		var p: Vector3 = player.global_position - center
		p += tangent * speed * min(dt, 0.05)
		p = p.normalized() * (surface_r + 2.0)
		player.global_position = center + p
		tangent = (tangent - p.normalized() * tangent.dot(p.normalized())).normalized()
		proc_us.append(mgr.process_time); frame_us.append(fdt)
		peak_pending = max(peak_pending, mgr.pending_tasks.size())
		n_leaves_hist.append(mgr.new_chunk_set.size())
		_poll_stages()
		if float(now - t_phase_start) / 1e6 >= move_seconds:
			var rep := {
				"wall_s": float(now - t_phase_start) / 1e6,
				"frames": frame,
				"leaves(avg)": _avg(n_leaves_hist),
				"active": mgr.active_chunk_set.size(),
				"retiring": mgr.retiring_chunk_set.size(),
				"ready_to_die": mgr.ready_to_die_chunk_set.size(),
				"peak_pending": peak_pending,
				"nodes": _count_nodes(mgr),
				"travelled_m": 0,
			}
			_print_stats("MOVE PHASE (%.0f m/s)" % speed, rep)
			quit()
	return false

func _poll_stages() -> void:
	for s_name in STAGES:
		var v: int = mgr.get(s_name)
		if v != prev_stage[s_name]:
			prev_stage[s_name] = v
			stage[s_name].append(v)

func _count_meshes() -> int:
	var n := 0
	for k in mgr.active_chunk_set:
		if mgr.active_chunk_set[k].mesh_data != null: n += 1
	return n

func _count_nodes(n: Node) -> int:
	var c := 1
	for ch in n.get_children(): c += _count_nodes(ch)
	return c

func _avg(a: Array) -> float:
	if a.is_empty(): return 0.0
	var s := 0.0
	for v in a: s += v
	return s / a.size()

func _pct(sorted: Array, q: float) -> float:
	if sorted.is_empty(): return 0.0
	return sorted[min(sorted.size() - 1, int(q * sorted.size()))]

func _arr_stats(name: String, a: Array) -> String:
	if a.is_empty(): return "%-22s (no samples)" % name
	var s := a.duplicate(); s.sort()
	return "%-22s n=%4d  mean=%8.0f  p50=%8.0f  p95=%8.0f  max=%8.0f  (us)" % [name, a.size(), _avg(a), _pct(s, 0.5), _pct(s, 0.95), s[-1]]

func _print_stats(title: String, rep: Dictionary) -> void:
	print("\n===== %s =====" % title)
	print("  worker gen: n=%d  sum=%.0f ms  avg=%.1f ms  max=%.1f ms" % [gen_n, gen_sum / 1000.0, float(gen_sum) / max(gen_n, 1) / 1000.0, gen_max / 1000.0])
	gen_sum = 0; gen_n = 0; gen_max = 0
	for k in rep: print("  %s: %s" % [k, str(rep[k])])
	if "acc" in mgr:
		print("  ACC(us/counts since last reset): ", mgr.acc)
		for k in mgr.acc: mgr.acc[k] = 0
	print(_arr_stats("ChunkManager._process", proc_us))
	print(_arr_stats("frame interval", frame_us))
	var over := 0
	for v in proc_us: if v > 4000: over += 1
	print("  frames where manager._process > 4ms: %d / %d" % [over, proc_us.size()])
	for s_name in STAGES:
		print(_arr_stats(s_name, stage[s_name]))
