extends SceneTree
## Looks for floating rock and hollow air in the terrain. Samples a box of the field around the highest mountain found on a planet and flood-fills it: rock that is not connected to the ground (the sides and bottom of the box) is floating, air that is not connected to the sky (the top of the box) is a cave. With `overhang` 0 both must be 0. Raising `overhang` shows how much of each it carves, and how much overhanging rock there is (columns where the field changes sign more than once).
##   godot --headless --path . -s tools/bench/check_floating_rock.gd -- <overhang> [seed] [size] [step] [slice.png]
## With a file name it also saves a side view of the middle slice of the box (rock brown, air blue, floating rock red).
## The parameters are a mountainous preset with every other value at its default.
var started := false
const HALF_WIDTH := 150.0
func _process(_d: float) -> bool:
	if started: return false
	started = true
	var args := OS.get_cmdline_user_args()
	var overhang: float = float(args[0]) if args.size() > 0 else 0.0
	var seed_value: int = int(args[1]) if args.size() > 1 else 3
	var size: int = int(args[2]) if args.size() > 2 else 10
	var step: float = float(args[3]) if args.size() > 3 else 3.0
	var png: String = args[4] if args.size() > 4 else ""
	var params = load("res://environment/world-generation/terrain-params.gd").new()
	params.peak_height = 700.0; params.mountain_coverage = 1.0; params.mountain_scale = 1400.0; params.erosion = 0.2
	params.ridge_sharpness = 2.2; params.ocean_coverage = 0.2; params.overhang = overhang
	var wn = load("res://environment/world-generation/world-noise.gd").new(seed_value, 16.0 * pow(2, size), params)

	# the highest of many sampled points on the sea sphere is the center of the box, tilted to the +x axis so that the box is tangent to the surface
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	var best := -INF
	for i in 3000:
		var dir := Vector3(rng.randfn(), rng.randfn(), rng.randfn()).normalized()
		best = maxf(best, wn.get_elevation_at_point(wn.center + dir * wn.sea_level))
	# find the best direction again to know it, then rotate the field instead of the box: the box is simply placed around that point in world axes
	rng.seed = seed_value
	var best_dir := Vector3.RIGHT
	var best_e := -INF
	for i in 3000:
		var dir := Vector3(rng.randfn(), rng.randfn(), rng.randfn()).normalized()
		var e: float = wn.get_elevation_at_point(wn.center + dir * wn.sea_level)
		if e > best_e: best_e = e; best_dir = dir
	var up := best_dir
	var side_a := up.cross(Vector3(0.3, 0.9, 0.1)).normalized()
	var side_b := up.cross(side_a)
	var base_radius: float = wn.sea_level + wn.min_elevation * 0.3
	var height: float = wn.max_elevation - wn.min_elevation * 0.3 + 20.0
	var n_side := int(2.0 * HALF_WIDTH / step)
	var n_up := int(height / step)
	print("highest point %.0f m above sea; box %d x %d x %d cells of %.0f m, overhang %.2f (effective %.1f m)" % [best_e, n_side, n_side, n_up, step, overhang, wn.effective_overhang])

	# field in the box: index = (a * n_side + b) * n_up + u
	var rock := PackedByteArray()
	rock.resize(n_side * n_side * n_up)
	var multi_columns := 0
	for a in n_side:
		for b in n_side:
			var crossings := 0
			var previous := false
			for u in n_up:
				var pos: Vector3 = wn.center + up * (base_radius + u * step) + side_a * (a * step - HALF_WIDTH) + side_b * (b * step - HALF_WIDTH)
				var inside: bool = wn.sample(pos.x, pos.y, pos.z) < 0.0
				rock[(a * n_side + b) * n_up + u] = 1 if inside else 0
				if u > 0 and inside != previous: crossings += 1
				previous = inside
			if crossings > 1: multi_columns += 1

	if png != "": _save_slice(rock, n_side, n_up, png)
	var floating := _fill(rock, n_side, n_up, 1)
	var caves := _fill(rock, n_side, n_up, 0)
	print("columns with overhanging rock: %d of %d | floating rock cells: %d | enclosed air (cave) cells: %d -> %s" % [multi_columns, n_side * n_side, floating, caves, "CLEAN" if floating + caves == 0 else "has floating rock or caves"])
	quit()
	return false

## Number of cells of `kind` (1 = rock, 0 = air) in components that do not reach their anchor: rock must reach the bottom or the sides, air must reach the top. A flood fill from the anchor cells marks what is connected.
func _fill(grid: PackedByteArray, n_side: int, n_up: int, kind: int) -> int:
	var seen := PackedByteArray()
	seen.resize(grid.size())
	var stack := PackedInt32Array()
	for a in n_side:
		for b in n_side:
			for u in n_up:
				var anchored := (u == n_up - 1) if kind == 0 else (u == 0 or a == 0 or b == 0 or a == n_side - 1 or b == n_side - 1)
				var index := (a * n_side + b) * n_up + u
				if anchored and grid[index] == kind and seen[index] == 0:
					seen[index] = 1
					stack.append(index)
	var neighbours := [n_up, -n_up, n_side * n_up, -n_side * n_up, 1, -1]
	while stack.size() > 0:
		var index := stack[stack.size() - 1]
		stack.resize(stack.size() - 1)
		var u := index % n_up
		var b := (index / n_up) % n_side
		var a := index / (n_up * n_side)
		for direction in 6:
			var na := a; var nb := b; var nu := u
			match direction:
				0: nb += 1
				1: nb -= 1
				2: na += 1
				3: na -= 1
				4: nu += 1
				5: nu -= 1
			if na < 0 or nb < 0 or nu < 0 or na >= n_side or nb >= n_side or nu >= n_up: continue
			var next := (na * n_side + nb) * n_up + nu
			if grid[next] == kind and seen[next] == 0:
				seen[next] = 1
				stack.append(next)
	var lost := 0
	for i in grid.size():
		if grid[i] == kind and seen[i] == 0: lost += 1
	return lost

func _save_slice(grid: PackedByteArray, n_side: int, n_up: int, path: String) -> void:
	var scale := 4
	var img := Image.create(n_side * scale, n_up * scale, false, Image.FORMAT_RGB8)
	var a := n_side / 2
	for b in n_side:
		for u in n_up:
			var color := Color(0.42, 0.34, 0.28) if grid[(a * n_side + b) * n_up + u] == 1 else Color(0.62, 0.78, 0.95)
			for dx in scale:
				for dy in scale:
					img.set_pixel(b * scale + dx, (n_up - 1 - u) * scale + dy, color)
	img.save_png(path)
