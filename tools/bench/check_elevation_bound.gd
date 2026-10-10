extends SceneTree
## Sanity check for WorldNoise.bias_threshold: the largest |elevation| seen over many random points must stay below the derived bound.
##   godot --headless --path . -s tools/bench/check_elevation_bound.gd
var started := false
func _process(_d: float) -> bool:
	if started: return false
	started = true
	var cont: Curve = load("res://environment/world-generation/slope_curves/default_continent_curve.tres")
	var mount: Curve = load("res://environment/world-generation/slope_curves/default_mountain_curve.tres")
	var wn = load("res://environment/world-generation/world-noise.gd").new(1, 2048.0, 524, 0, cont, mount)
	var bound: float = wn.bias_threshold / wn.FLOOR_BIAS
	var rng := RandomNumberGenerator.new()
	rng.seed = 11
	var worst := 0.0
	for seed_value in [1, 7, 12345]:
		wn.continent_noise.seed = seed_value; wn.mountain_noise.seed = seed_value; wn.hill_noise.seed = seed_value; wn.detail_noise.seed = seed_value
		for i in 300000:
			var p := Vector3(rng.randf(), rng.randf(), rng.randf()) * 60000.0
			worst = maxf(worst, absf(wn.get_elevation_at_point(p)))
	print("derived elevation bound=%.2f  max |elevation| observed=%.2f  -> %s" % [bound, worst, "OK" if worst < bound else "VIOLATED"])
	quit()
	return false
