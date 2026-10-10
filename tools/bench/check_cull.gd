extends SceneTree
## Invariants of horizon culling (`ChunkManager.is_hidden()` / `_apply_cull()`), on the real field.
##   godot --headless --path . -s tools/bench/check_cull.gd
## 1. Safety: from camera positions anywhere within CULL_MARGIN of the player, a ray to a real surface point inside a culled leaf is blocked by the real terrain.
## 2. No leaf near the player is culled, nothing is culled with the camera inside the occluding ball, and culling does not change the leaves or their transition masks.
const CHUNK := 16
var started := false

func _process(_d: float) -> bool:
	if started: return false
	started = true
	var NoiseScript: GDScript = load("res://environment/world-generation/world-noise.gd")
	var mgr_script: GDScript = load("res://environment/world-generation/chunk-manager.gd")
	var cont: Curve = load("res://environment/world-generation/slope_curves/default_continent_curve.tres")
	var mount: Curve = load("res://environment/world-generation/slope_curves/default_mountain_curve.tres")
	var stub := GDScript.new()
	stub.source_code = "extends \"res://actors/player.gd\"\nfunc _ready(): pass\nfunc _physics_process(_d): pass\nfunc _input(_e): pass\n"
	stub.reload()
	var rng := RandomNumberGenerator.new()
	rng.seed = 11
	var failures := 0
	var rays := 0
	var culled_total := 0
	for depth in [7, 9, 12]:
		var volume: float = 16.0 * pow(2, depth)
		var floor_distance := int(volume / 2) - 500
		var noise = NoiseScript.new(1, volume, floor_distance, 0, cont, mount)
		var center := Vector3(volume, volume, volume) / 2
		var max_e: float = noise.bias_threshold / NoiseScript.FLOOR_BIAS
		var player = stub.new()
		root.add_child(player)
		var mgr = mgr_script.new(player, 1, depth, noise, true)
		root.add_child(mgr)
		var margin: float = mgr.CULL_MARGIN
		var depth_rays := 0
		var depth_target := 400 if depth <= 9 else 40
		for trial in 40:
			var dir := Vector3(rng.randf_range(-1, 1), rng.randf_range(-1, 1), rng.randf_range(-1, 1)).normalized()
			var altitude: float = [2.0, 2.0, 50.0, 400.0, -0.7 * floor_distance][trial % 5]
			var surface := _surface_radius(noise, center, dir, floor_distance, max_e)
			var p: Vector3 = center + dir * (surface + altitude if altitude > 0.0 else floor_distance + altitude)
			var leaves: Dictionary = mgr._compute_leaf_set(p, true)
			# the same octree and masks without culling
			var plain: Dictionary[Vector4i, int] = {}
			mgr._octree_iterate(plain, p)
			mgr._find_masks(plain)
			if plain.size() != leaves.size(): failures += 1; print("FAIL depth %d: culling changed the number of leaves (%d vs %d)" % [depth, plain.size(), leaves.size()])
			for key: Vector4i in leaves:
				if not plain.has(key) or plain[key] != (leaves[key] & mgr.TRANSITION_MASK_BITS):
					failures += 1; print("FAIL depth %d: transition mask of %s changed by culling" % [depth, key]); break
			for key: Vector4i in leaves:
				if not (leaves[key] & mgr.CULLED_BIT): continue
				culled_total += 1
				var side: float = CHUNK * key.w
				var corner_center := Vector3(key.x, key.y, key.z) + Vector3(side, side, side) / 2.0
				if p.distance_to(corner_center) - side * 0.8660254 < 2 * CHUNK:
					failures += 1; print("FAIL depth %d: culled leaf %s within %d m of the player" % [depth, key, 2 * CHUNK])
				if altitude < 0.0:
					failures += 1; print("FAIL depth %d: leaf culled with the camera inside the planet" % depth); break
				# real surface points inside the culled leaf, seen from the player and from positions up to the margin away
				if depth_rays >= depth_target or rng.randf() > 0.1: continue
				for k in 4:
					var q := Vector3(key.x, key.y, key.z) + Vector3(rng.randf(), rng.randf(), rng.randf()) * side
					var s_pt := _surface_point(noise, center, (q - center).normalized(), floor_distance, max_e)
					if s_pt == Vector3.INF: continue
					if s_pt.x < key.x or s_pt.x > key.x + side or s_pt.y < key.y or s_pt.y > key.y + side or s_pt.z < key.z or s_pt.z > key.z + side: continue
					for j in 4:
						var cam := p
						if j > 0: cam += Vector3(rng.randf_range(-1, 1), rng.randf_range(-1, 1), rng.randf_range(-1, 1)).normalized() * margin * rng.randf()
						depth_rays += 1
						if not _blocked(noise, cam, s_pt):
							failures += 1; print("FAIL depth %d: culled leaf %s has a visible surface point %s from %s" % [depth, key, s_pt, cam])
		rays += depth_rays
		mgr.queue_free(); player.queue_free()
	print("check_cull: %d culled leaves seen, %d rays, %d failures -> %s" % [culled_total, rays, failures, "OK" if failures == 0 and culled_total > 0 else "FAILED"])
	quit()
	return false

## Radius of the outermost surface crossing along `dir`, marching inward from the highest possible terrain.
func _surface_radius(noise, center: Vector3, dir: Vector3, floor_distance: float, max_e: float) -> float:
	var r := floor_distance + max_e
	while r > floor_distance - max_e:
		var pp := center + dir * r
		if noise.sample(pp.x, pp.y, pp.z) < 0.0: return r
		r -= 0.25
	return floor_distance

func _surface_point(noise, center: Vector3, dir: Vector3, floor_distance: float, max_e: float) -> Vector3:
	var r := floor_distance - max_e
	var pp := center + dir * r
	var prev: float = noise.sample(pp.x, pp.y, pp.z)
	while r < floor_distance + max_e:
		r += 0.5
		pp = center + dir * r
		var s: float = noise.sample(pp.x, pp.y, pp.z)
		if prev < 0.0 and s >= 0.0: return pp
		prev = s
	return Vector3.INF

## True when real terrain lies between `cam` and `target` (the last 4 m before the target are ignored).
func _blocked(noise, cam: Vector3, target: Vector3) -> bool:
	var to := target - cam
	var length := to.length()
	var t := 0.0
	while t < length - 4.0:
		var pp := cam + to * (t / length)
		if noise.sample(pp.x, pp.y, pp.z) < 0.0: return true
		t += 2.0
	return false
