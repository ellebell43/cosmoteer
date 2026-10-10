extends SceneTree
# What kind of call scales across worker threads? 400k iterations per task, 1/4/13 tasks, each task has its OWN objects.
var started := false
var variant := ""
const ITER := 400000
var objs := []

class Dummy:
	var v := 0
	func bump() -> int:
		v += 1
		return v

func _process(_d: float) -> bool:
	if started: return false
	started = true
	for w in 16:
		var cu: Curve = load("res://environment/world-generation/slope_curves/default_continent_curve.tres").duplicate()
		var fn := FastNoiseLite.new(); fn.frequency = 0.01
		objs.append({"curve": cu, "noise": fn, "ref": RefCounted.new(), "dummy": Dummy.new(), "node": Node3D.new()})
	for v in ["builtin_vec3", "gd_self_call", "gd_obj_call", "native_refcounted_trivial", "native_node_trivial", "native_curve_untyped", "native_curve_typed", "native_noise_typed"]:
		variant = v
		var base := 0.0
		var line := "%-28s" % v
		for n in [1, 4, 13]:
			var t := Time.get_ticks_usec()
			var ids: Array[int] = []
			for w in n: ids.append(WorkerThreadPool.add_task(_run.bind(w)))
			for id in ids: WorkerThreadPool.wait_for_task_completion(id)
			var wall := float(Time.get_ticks_usec() - t) / 1000.0
			# each task does the same ITER work => ideal wall time is constant as n grows
			if n == 1: base = wall
			line += "  n=%2d: %6.1f ms (x%.2f slower than ideal)" % [n, wall, wall / base]
		print(line)
	quit()
	return false

func _self_trivial(x: int) -> int:
	return x + 1

func _run(w: int) -> void:
	var o: Dictionary = objs[w]
	match variant:
		"builtin_vec3":
			var v := Vector3(1, 2, 3); var a := 0.0
			for i in ITER: a += v.distance_to(Vector3(i, 2, 3)) 
		"gd_self_call":
			var a := 0
			for i in ITER: a = _self_trivial(a)
		"gd_obj_call":
			var d = o.dummy; var a := 0
			for i in ITER: a = d.bump()
		"native_refcounted_trivial":
			var r = o.ref; var a := 0
			for i in ITER: a += r.get_reference_count()
		"native_node_trivial":
			var nd = o.node; var a := 0.0
			for i in ITER: a += nd.get_rotation_order()
		"native_curve_untyped":
			var c = o.curve; var a := 0.0
			for i in ITER: a += c.sample(0.3)
		"native_curve_typed":
			var c: Curve = o.curve; var a := 0.0
			for i in ITER: a += c.sample(0.3)
		"native_noise_typed":
			var f: FastNoiseLite = o.noise; var a := 0.0
			for i in ITER: a += f.get_noise_3d(i, 1.0, 2.0)
