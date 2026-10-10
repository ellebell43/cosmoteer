extends SceneTree
# Does chunk generation scale across threads? Same fixed workload run on 1,2,4,8,13 concurrent tasks.
#   godot --headless --path <repo> -s bench_parallel.gd -- [variant]
# variant: "chunk" (default; full generate_mesh_data), "noise" (only WorldNoise.sample loop), "lut" (only LUT reads)

var jobs: Array = []
var variant := "chunk"
var noise
var lut_script
var priv := []
var privfn := []
var privfm := []
var privcurve := []

func _initialize() -> void:
	pass

var started := false
func _process(_d: float) -> bool:
	if started: return false
	started = true
	var args := OS.get_cmdline_user_args()
	if args.size() > 0: variant = args[0]
	root.get_node("Utils").debug = false
	noise = load("res://environment/world-generation/world-noise.gd").new(1, 2048.0, load("res://environment/world-generation/terrain-params.gd").new())
	lut_script = load("res://environment/world-generation/transvoxel-lut.gd")
	var ChunkS: GDScript = load("res://environment/world-generation/chunk.gd")
	var c := Vector3(1024, 1024, 1024)
	# 52 surface chunks at lod 1 spread over the sphere
	var rng := RandomNumberGenerator.new(); rng.seed = 5
	while jobs.size() < 52:
		var d := Vector3(rng.randf_range(-1, 1), rng.randf_range(-1, 1), rng.randf_range(-1, 1)).normalized()
		var prev := -1.0; var hit := Vector3.ZERO
		for r in range(480, 600):
			var p := c + d * r
			var s: float = noise.sample(p.x, p.y, p.z)
			if prev < 0.0 and s > 0.0: hit = p; break
			prev = s
		if hit == Vector3.ZERO: continue
		var off := Vector3(floor(hit.x / 16), floor(hit.y / 16), floor(hit.z / 16)) * 16
		jobs.append(ChunkS.new(16, noise, off, 1))
	for w in 16:
		priv.append(load("res://environment/world-generation/world-noise.gd").new(1, 2048.0, load("res://environment/world-generation/terrain-params.gd").new()))
		var f1 := FastNoiseLite.new(); f1.noise_type = FastNoiseLite.TYPE_PERLIN; f1.frequency = 0.005; f1.fractal_octaves = 4; f1.fractal_type = FastNoiseLite.FRACTAL_FBM
		var f2 := FastNoiseLite.new(); f2.noise_type = FastNoiseLite.TYPE_SIMPLEX; f2.frequency = 0.03; f2.fractal_octaves = 5; f2.fractal_type = FastNoiseLite.FRACTAL_RIDGED
		privfn.append(f1); privfm.append(f2)
		privcurve.append(_make_curve())
	print("[parallel] variant=%s jobs=%d cpus=%d" % [variant, jobs.size(), OS.get_processor_count()])
	var base := 0.0
	for n in [1, 2, 4, 8, 13]:
		var t := Time.get_ticks_usec()
		var ids: Array[int] = []
		for w in n:
			ids.append(WorkerThreadPool.add_task(_run.bind(w, n)))
		for id in ids: WorkerThreadPool.wait_for_task_completion(id)
		var wall := float(Time.get_ticks_usec() - t) / 1000.0
		if n == 1: base = wall
		print("  threads=%2d  wall=%8.1f ms  speedup=%.2fx  efficiency=%3.0f%%" % [n, wall, base / wall, 100.0 * base / wall / n])
	quit()
	return false

var shared_curve := _make_curve()

func _make_curve() -> Curve:
	var c := Curve.new()
	c.add_point(Vector2(0, 0)); c.add_point(Vector2(0.5, 1)); c.add_point(Vector2(1, 0.2))
	return c

func _run(w: int, n: int) -> void:
	var i := w
	while i < jobs.size():
		match variant:
			"chunk":
				jobs[i].generate_mesh_data(0)
			"noise":
				var off: Vector3 = jobs[i].offset
				for x in 17: for y in 17: for z in 17:
					noise.sample(off.x + x, off.y + y, off.z + z)
			"gd_pure":
				var a := 0.0
				for k in 17 * 17 * 17 * 40:
					a += sqrt(float(k)) * 0.5
			"noise_private":
				var wn = priv[w]
				var off0: Vector3 = jobs[i].offset
				for x in 17: for y in 17: for z in 17:
					wn.sample(off0.x + x, off0.y + y, off0.z + z)
			"native_noise_shared":
				var off1: Vector3 = jobs[i].offset
				var fn = noise.continent_noise
				var fm = noise.mountain_noise
				for x in 17: for y in 17: for z in 17:
					fn.get_noise_3d(off1.x + x, off1.y + y, off1.z + z)
					fm.get_noise_3d(off1.x + x, off1.y + y, off1.z + z)
			"native_noise_private":
				var off2: Vector3 = jobs[i].offset
				var fn2 = privfn[w]
				var fm2 = privfm[w]
				for x in 17: for y in 17: for z in 17:
					fn2.get_noise_3d(off2.x + x, off2.y + y, off2.z + z)
					fm2.get_noise_3d(off2.x + x, off2.y + y, off2.z + z)
			"curve_shared":
				var cc = shared_curve
				for k in 17 * 17 * 17:
					cc.sample(float(k % 100) / 200.0)
			"curve_private":
				var cp = privcurve[w]
				for k in 17 * 17 * 17:
					cp.sample(float(k % 100) / 200.0)
			"lut":
				# pure LUT/const-array reads like the mesher does
				var acc := 0
				for k in 4096:
					var ci := k & 255
					var cc: int = lut_script.REG_CELL_CLASS[ci]
					acc += lut_script.get_vertex_count(lut_script.REG_CELL_DATA[cc][0])
					for q in 4: acc += lut_script.REG_VERTEX_DATA[ci][q & 3]
		i += n
