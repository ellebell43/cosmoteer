extends SceneTree
## Sanity check for WorldNoise.min_elevation / max_elevation: the elevation seen over many random points must stay inside the derived bounds, for the defaults and for random and extreme TerrainParams. The bounds are what makes skipping empty chunks and the horizon culling safe.
##   godot --headless --path . -s tools/bench/check_elevation_bound.gd
var started := false
func _process(_d: float) -> bool:
	if started: return false
	started = true
	var noise_script: GDScript = load("res://environment/world-generation/world-noise.gd")
	var params_script: GDScript = load("res://environment/world-generation/terrain-params.gd")
	var rng := RandomNumberGenerator.new()
	rng.seed = 11
	var violations := 0
	for trial in 18:
		var params = params_script.new()
		if trial >= 1: params.randomize_values(rng, trial >= 10)
		var volume: float = 16.0 * pow(2, [7, 8, 9, 10, 12, 14][trial % 6])
		var wn = noise_script.new(trial + 1, volume, params)
		var low := INF
		var high := -INF
		for i in 20000:
			var dir := Vector3(rng.randfn(), rng.randfn(), rng.randfn()).normalized()
			var e: float = wn.get_elevation_at_point(wn.center + dir * (wn.sea_level + rng.randf_range(wn.min_elevation, wn.max_elevation)))
			low = minf(low, e); high = maxf(high, e)
		var ok: bool = low >= wn.min_elevation and high <= wn.max_elevation
		if not ok: violations += 1
		print("%s volume %6d: elevation %8.1f .. %8.1f  bounds %8.1f .. %8.1f  -> %s" % ["default" if trial == 0 else ("random " if trial < 10 else "corners"), volume, low, high, wn.min_elevation, wn.max_elevation, "OK" if ok else "VIOLATED"])
	print("violations: %d" % violations)
	quit()
	return false
