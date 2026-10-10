extends SceneTree
## Invariants of culling (`ChunkManager.is_hidden()`, `is_beyond_view()`, `_apply_cull()`), on the real field.
##   godot --headless --path . -s tools/bench/check_cull.gd
## 1. Safety, horizon: from camera positions anywhere within the margin of the player, a ray to a real surface point inside a leaf culled by the horizon test is blocked by the real terrain.
## 1b. Safety, far plane: no point of a leaf culled by the far-plane test is inside the frustum of a camera anywhere within the margin, however it is turned.
## 2. No leaf near the player is culled, nothing is culled with the camera inside the occluding ball, and culling does not change the leaves or their transition masks.
const CHUNK := 16
var started := false

func _process(_d: float) -> bool:
	if started: return false
	started = true
	var NoiseScript: GDScript = load("res://environment/world-generation/world-noise.gd")
	var mgr_script: GDScript = load("res://environment/world-generation/chunk-manager.gd")
	var stub := GDScript.new()
	stub.source_code = "extends \"res://actors/player.gd\"\nfunc _ready(): pass\nfunc _physics_process(_d): pass\nfunc _input(_e): pass\n"
	stub.reload()
	var rng := RandomNumberGenerator.new()
	rng.seed = 11
	var failures := 0
	var far_points := 0
	var far_culled_total := 0
	var camera := Camera3D.new()
	camera.far = 4000.0
	root.add_child(camera)
	var rays := 0
	var culled_total := 0
	for depth in [7, 9, 12]:
		var volume: float = 16.0 * pow(2, depth)
		var floor_distance := int(volume / 2) - 500
		var noise = NoiseScript.new(1, volume, load("res://environment/world-generation/terrain-params.gd").new())
		var center := Vector3(volume, volume, volume) / 2
		var max_e: float = maxf(noise.max_elevation, -noise.min_elevation)
		var player = stub.new()
		root.add_child(player)
		var mgr = mgr_script.new(player, 1, depth, noise, true)
		root.add_child(mgr)
		var depth_rays := 0
		var depth_target := 400 if depth <= 9 else 40
		for trial in 40:
			var dir := Vector3(rng.randf_range(-1, 1), rng.randf_range(-1, 1), rng.randf_range(-1, 1)).normalized()
			var altitude: float = [2.0, 2.0, 50.0, 400.0, -0.7 * floor_distance][trial % 5]
			var surface := _surface_radius(noise, center, dir, floor_distance, max_e)
			var p: Vector3 = center + dir * (surface + altitude if altitude > 0.0 else floor_distance + altitude)
			# every other trial pretends the player is flying fast, which widens the margin
			mgr.player_speed = 0.0 if trial % 2 == 0 else 40.0
			var margin: float = mgr.get_cull_margin()
			var cull_distance: float = mgr._get_cull_distance()
			var leaves: Dictionary = mgr._compute_leaf_set(p, true, margin, cull_distance)
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
				if altitude < 0.0 and mgr.is_hidden(p, key, margin):
					failures += 1; print("FAIL depth %d: leaf hidden by the horizon with the camera inside the planet" % depth); break
				if mgr.is_beyond_view(p, key, margin, cull_distance):
					far_culled_total += 1
					if rng.randf() < 0.3:
						# the corner of the frustum is the furthest it reaches: aim the camera so that the point is near it
						var view_size := root.get_visible_rect().size
						var tan_y := tan(deg_to_rad(camera.fov) / 2.0)
						var tan_x := tan_y * view_size.x / view_size.y
						var corner_angle := atan(sqrt(tan_x * tan_x + tan_y * tan_y))
						var cam_pos := p + Vector3(rng.randf_range(-1, 1), rng.randf_range(-1, 1), rng.randf_range(-1, 1)).normalized() * margin * rng.randf()
						var box_min := Vector3(key.x, key.y, key.z)
						var nearest := cam_pos.clamp(box_min, box_min + Vector3(side, side, side))
						for k in 12:
							var q := nearest if k < 6 else box_min + Vector3(rng.randf(), rng.randf(), rng.randf()) * side
							if q.distance_to(cam_pos) < 1.0: continue
							var to_q := (q - cam_pos).normalized()
							var turn_axis := to_q.cross(Vector3(rng.randf_range(-1, 1), rng.randf_range(-1, 1), rng.randf_range(-1, 1))).normalized()
							var forward := to_q.rotated(turn_axis, corner_angle * rng.randf_range(0.6, 1.0))
							var up := forward.cross(Vector3(rng.randf_range(-1, 1), rng.randf_range(-1, 1), rng.randf_range(-1, 1))).normalized()
							camera.global_transform = Transform3D(Basis.looking_at(forward, up), cam_pos)
							far_points += 1
							var inside := true
							for plane in camera.get_frustum():
								if plane.is_point_over(q): inside = false; break
							if inside:
								failures += 1; print("FAIL depth %d: far-culled leaf %s has a point %s inside the frustum of a camera at %s" % [depth, key, q, cam_pos])
				# real surface points inside the horizon-culled leaf, seen from the player and from positions up to the margin away
				if not mgr.is_hidden(p, key, margin): continue
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
	print("check_cull: %d culled leaves seen (%d by the far plane, %d points checked against the frustum), %d rays, %d failures -> %s" % [culled_total, far_culled_total, far_points, rays, failures, "OK" if failures == 0 and culled_total > 0 and far_points > 0 else "FAILED"])
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
