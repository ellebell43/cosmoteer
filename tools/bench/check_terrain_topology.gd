extends SceneTree
## Is the terrain one clean surface over the planet? Casts radial rays through the real field and counts how often the field changes sign more than once along a ray (overhangs, caves and floating rock all show up that way, since a floating blob is crossed by a ray from outside three times or more). Also reports the steepest radial slope of the elevation: the surface can only fold where it exceeds 1.
## Parameter sets: the defaults, random ones, and the corners of every range (each value at one end of its range). With `overhang` forced to 0 every set must report 0 crossing problems.
##   godot --headless --path . -s tools/bench/check_terrain_topology.gd -- <default|random|corners> <sets> <rays> [size] [seed] [overhang]
## `overhang` overrides the value of TerrainParams.overhang in every set (default 0).
var started := false
func _process(_d: float) -> bool:
	if started: return false
	started = true
	var args := OS.get_cmdline_user_args()
	var mode: String = args[0] if args.size() > 0 else "default"
	var sets: int = int(args[1]) if args.size() > 1 else 1
	var rays: int = int(args[2]) if args.size() > 2 else 300
	var size: int = int(args[3]) if args.size() > 3 else 9
	var base_seed: int = int(args[4]) if args.size() > 4 else 1
	var overhang: float = float(args[5]) if args.size() > 5 else 0.0
	var noise_script: GDScript = load("res://environment/world-generation/world-noise.gd")
	var params_script: GDScript = load("res://environment/world-generation/terrain-params.gd")
	var rng := RandomNumberGenerator.new()
	rng.seed = base_seed
	var volume := 16.0 * pow(2, size)
	var bad_sets := 0
	for i in sets:
		var params = params_script.new()
		if mode != "default": params.randomize_values(rng, mode == "corners")
		params.overhang = overhang
		var wn = noise_script.new(base_seed + i, volume, params)
		var multi := 0
		var slopes := PackedFloat32Array()
		var step := 2.0
		for ray in rays:
			var dir := Vector3(rng.randfn(), rng.randfn(), rng.randfn()).normalized()
			var crossings := 0
			var previous := 0.0
			var previous_e := 0.0
			var r: float = wn.sea_level + wn.max_elevation
			var first := true
			while r > wn.sea_level + wn.min_elevation:
				var p: Vector3 = wn.center + dir * r
				var e: float = wn.get_elevation_at_point(p)
				var value: float = r - wn.sea_level - e
				if not first:
					if (previous < 0.0) != (value < 0.0): crossings += 1
					slopes.append(maxf(0.0, (previous_e - e) / step))   # dE/dr, r goes down
				previous = value; previous_e = e; first = false
				r -= step
			if crossings > 1: multi += 1
		slopes.sort()
		var p999: float = slopes[int(slopes.size() * 0.999)]
		var bad: bool = multi > 0
		if bad: bad_sets += 1
		print("set %2d size %d: rays with >1 crossing %3d/%d | radial dE/dr p99=%.2f p99.9=%.2f max=%.2f | effective: peak %.0f mountain %.0f hill %.0f ocean %.0f | %s" % [i, size, multi, rays, slopes[int(slopes.size() * 0.99)], p999, slopes[slopes.size() - 1], wn.effective_peak_height, wn.effective_mountain_height, wn.effective_hill_height, wn.effective_ocean_depth, "PROBLEM" if bad else "ok"])
		if bad and mode != "default": print("    params: ", _describe(params))
	print("sets with problems: %d of %d" % [bad_sets, sets])
	quit()
	return false

func _describe(params) -> String:
	var parts := PackedStringArray()
	for property in params.get_property_list():
		if property.hint == PROPERTY_HINT_RANGE and (property.usage & PROPERTY_USAGE_EDITOR):
			parts.append("%s=%.2f" % [property.name, params.get(property.name)])
	return ", ".join(parts)
