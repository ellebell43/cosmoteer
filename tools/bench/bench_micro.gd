extends SceneTree
# Micro benchmark of Chunk / WorldNoise. Run:
#   godot --headless --path <repo> -s bench_micro.gd
# Game scripts are loaded dynamically because autoloads (Utils) are not registered at -s compile time.

const WN := "res://environment/world-generation/world-noise.gd"
const CH := "res://environment/world-generation/chunk.gd"

var WorldNoiseS: GDScript
var ChunkS: GDScript
var CountingChunkS: GDScript

func _initialize() -> void:
	WorldNoiseS = load(WN)
	ChunkS = load(CH)
	root.get_node("Utils").debug = false  # don't spam deferred signals

	# runtime subclass of Chunk that counts the hot helpers
	CountingChunkS = GDScript.new()
	CountingChunkS.source_code = """extends "%s"
var n_apply_shift := 0
var n_field_normal := 0
var n_vertices := 0
func _apply_shift(pos, mask):
	n_apply_shift += 1
	return super._apply_shift(pos, mask)
func _get_field_normal(v):
	n_field_normal += 1
	return super._get_field_normal(v)
""" % CH
	CountingChunkS.reload()

	var cont: Curve = load("res://environment/world-generation/slope_curves/default_continent_curve.tres")
	var mount: Curve = load("res://environment/world-generation/slope_curves/default_mountain_curve.tres")
	var volume := 2048.0
	var noise = WorldNoiseS.new(1, volume, 524, 0, cont, mount)

	# ---------- 1. raw cost of noise calls ----------
	var pts := PackedVector3Array()
	for i in 20000:
		pts.append(Vector3(randf(), randf(), randf()) * volume)
	var t := Time.get_ticks_usec()
	for p in pts: noise.sample(p.x, p.y, p.z)
	var us_sample := float(Time.get_ticks_usec() - t) / pts.size()
	t = Time.get_ticks_usec()
	for p in pts: noise.get_biome_color(p)
	var us_color := float(Time.get_ticks_usec() - t) / pts.size()
	print("[noise] sample(): %.2f us/call   get_biome_color(): %.2f us/call" % [us_sample, us_color])

	# ---------- 2. surface chunks per LOD ----------
	var dirs := [Vector3(0.577, 0.577, 0.577), Vector3(0.9, 0.3, 0.1), Vector3(0.1, 0.95, 0.3), Vector3(0.3, 0.2, 0.93), Vector3(-0.7, 0.5, 0.5), Vector3(0.2, -0.8, 0.5)]
	var surface_pts: Array[Vector3] = []
	for d: Vector3 in dirs:
		d = d.normalized()
		var c := Vector3(volume, volume, volume) / 2
		var prev := -1.0
		for r in range(400, 700):
			var p := c + d * r
			var s: float = noise.sample(p.x, p.y, p.z)
			if prev < 0.0 and s > 0.0:
				surface_pts.append(p)
				break
			prev = s
	print("[setup] %d surface points found" % surface_pts.size())

	print("\nlod | mask |  tris | sample_set ms | mesh_gen ms | total ms | samples | apply_shift | field_normal | biome_color")
	for lod in [1, 2, 4, 8, 16, 32]:
		for mask in [0, 63]:
			var sum_set := 0.0; var sum_mesh := 0.0; var tris := 0; var n := 0
			for sp in surface_pts:
				var span: float = 16.0 * lod
				var off := Vector3(floor(sp.x / span), floor(sp.y / span), floor(sp.z / span)) * span
				var chunk = ChunkS.new(16, noise, off, lod)
				if chunk._determine_if_cell_is_empty(): continue
				var reps := 3 if lod <= 2 else 5
				var best_set := 1e12; var best_mesh := 1e12
				var mesh: ArrayMesh = null
				var empty := false
				for r in reps:
					if "_normal_cache" in chunk: chunk._normal_cache.clear()
					var t0 := Time.get_ticks_usec()
					var sd = chunk._construct_sample_set(mask)
					var t1 := Time.get_ticks_usec()
					if sd == null: empty = true; break
					mesh = chunk._generate_mesh_data(sd.corner_samples, mask, sd.transition_samples)
					var t2 := Time.get_ticks_usec()
					best_set = min(best_set, t1 - t0); best_mesh = min(best_mesh, t2 - t1)
				if empty or mesh == null: continue
				sum_set += best_set; sum_mesh += best_mesh; n += 1
				tris += mesh.surface_get_array_len(0) / 3
			if n == 0: continue
			# call counts on one chunk with the counting noise/chunk
			var cn = _counting_noise(cont, mount, volume)
			var sp0: Vector3 = surface_pts[0]
			var span0: float = 16.0 * lod
			var off0 := Vector3(floor(sp0.x / span0), floor(sp0.y / span0), floor(sp0.z / span0)) * span0
			var cc = CountingChunkS.new(16, cn, off0, lod)
			var counts := "-"
			if not cc._determine_if_cell_is_empty():
				var sd2 = cc._construct_sample_set(mask)
				if sd2 != null:
					cc._generate_mesh_data(sd2.corner_samples, mask, sd2.transition_samples)
					counts = "%d | %d | %d | %d" % [cn.n_sample, cc.n_apply_shift, cc.n_field_normal, cn.n_color]
			print("%3d | %4d | %5d | %13.2f | %11.2f | %8.2f | %s" % [lod, mask, tris / n, sum_set / n / 1000.0, sum_mesh / n / 1000.0, (sum_set + sum_mesh) / n / 1000.0, counts])
	quit()

func _counting_noise(cont, mount, volume):
	var s := GDScript.new()
	s.source_code = """extends "%s"
var n_sample := 0
var n_color := 0
func sample(x, y, z):
	n_sample += 1
	return super.sample(x, y, z)
func get_biome_color(p):
	n_color += 1
	return super.get_biome_color(p)
""" % WN
	s.reload()
	return s.new(1, volume, 524, 0, cont, mount)
