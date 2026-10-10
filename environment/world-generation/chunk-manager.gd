extends Node3D
class_name ChunkManager

## The size of each chunk in meters
const CHUNK_SIZE := 16
## Maximum time in microseconds per frame spent turning finished worker results into meshes
const MAXIMUM_BUILD_TIME := 3000
## Maximum time in microseconds per frame spent reconciling the desired leaf set with the existing chunks (load / retire / kill passes)
const RECONCILE_BUDGET := 1500
## Minimum time in microseconds between retire/kill passes that are not triggered by a new leaf set
const CLEANUP_INTERVAL := 250000
## Bit order of the transition mask, matching `Chunk`: x, y, z, -x, -y, -z
const FACE_DIRECTIONS: Array[Vector3i] = [
	Vector3i(1, 0, 0), Vector3i(0, 1, 0), Vector3i(0, 0, 1),
	Vector3i(-1, 0, 0), Vector3i(0, -1, 0), Vector3i(0, 0, -1),
]

## The steps of bringing the existing chunks in line with `new_chunk_set`. They run one after the other, spread over as many frames as `RECONCILE_BUDGET` requires. MARK must come before LOAD: a retiring chunk counts the volume of the replacements that become ACTIVE while it is RETIRING (`volume_counter`), so it has to be retiring before any replacement can finish. COVERAGE recounts that volume exactly from the ACTIVE chunks, and only runs when nothing is generating and retirees are left over (the incremental counts can miss replacements that skipped LOD levels).
enum ReconcilePhase {IDLE, MARK, LOAD, CHECK, COVERAGE, KILL}

## The number of chunks on each axis. Determined from passed in _max_octree_depth in _init()
var chunk_count: int
## Scalar field that is used to determine the shape of the mesh along the chunks.
var noise: WorldNoise
## Reference to the player node
var player: Player
var player_pos: Vector3
var is_current_world := false

# ========== CHUNK MANAGEMENT VARIABLES ==========

## Stores all mesh generation tasks that have not been collected yet. int is the task ID, Chunk is the actual Chunk node waiting on the task
var pending_tasks: Dictionary[int, Chunk] = {}
## The number of chunks that will be generated after the first octree_iteration. Emitted out to loading screen to provide a target 100% value
var total_first_tasks: int
## The number of tasks actually completed. Emitted out and used by loading screen to determine 0% to 100%
var tasks_emitted := 0
## How eagerly chunks split into finer chunks. The higher the number, the greater the distance gate to determine how fine the chunk is.
var distance_factor := 2
## The total size of the noise volume, and therefore the size of the root octree node. Where the entire volume is treated as 1 CHUNK_SIZE chunk
var root_node_size: int
## The maximum depth that the octree will go to. Same as Planet.size. (20 * 2^size = WorldNoise.size)
var max_octree_depth: int
## The previously recorder player position. Used to only iterate through the octree when the player moves player_movement_threshold meters
var prev_player_pos: Vector3
## Used to determine when the octree should be iterated through to prevent a per-frame iteration.
var player_movement_threshold := 10
## Whether or not the first octree traversal has completed. When true, chunk life-cycle functions are called
var first_iteration_complete := false

# ========== LEAF SET JOB ==========

## Task ID of the worker task computing the next leaf set (octree + transition masks). -1 when none is running. At most one runs at a time.
var leaf_job_task := -1
## Output of the leaf set job. Only read on the main thread after the task has been waited on.
var _leaf_job_result: Dictionary[Vector4i, int] = {}
## True when `_leaf_job_result` holds a finished leaf set that has not been applied yet
var _leaf_result_ready := false
## Set when the manager leaves the tree. Tasks that have not started yet return immediately.
var _shutting_down := false

# ========== FINISHED CHUNK QUEUE ==========

## Chunks whose worker task has finished, pushed by the workers. Guarded by `_finished_mutex`. Deliberately an untyped Array: Godot validates the element type of a typed array by calling `get_script()` on the node, which is not allowed off the main thread.
var _finished_chunks: Array = []
var _finished_mutex := Mutex.new()
## Main-thread side of the queue: finished chunks waiting for their mesh to be built, and the index of the next one.
var _build_queue: Array = []
var _build_queue_index := 0

# ========== RECONCILE STATE ==========

var _phase := ReconcilePhase.IDLE
var _phase_keys: Array = []
var _phase_index := 0
var _phase_time := 0
## Set when a chunk became ACTIVE, meaning retiring chunks may now be replaceable
var _cleanup_dirty := false
var _last_cleanup_time := 0

# ========== CHUNK SET DICTIONARIES ==========

# Dictionary[[Vec3(position), lod_level], chunk].
## The desired leaves of the octree from the latest finished leaf job. The value is the 6-bit transition mask of the leaf.
var new_chunk_set: Dictionary[Vector4i, int] = {}
var pending_chunk_set: Dictionary[Vector4i, Chunk] = {}
var active_chunk_set: Dictionary[Vector4i, Chunk] = {}
var retiring_chunk_set: Dictionary[Vector4i, Chunk] = {}
var ready_to_die_chunk_set: Dictionary[Vector4i, Chunk] = {}

# ========== TIMING VARIABLES ==========

var process_time := 0
var total_chunk_gen_time := 0
var total_chunks := 0
var octree_iterate_time := 0
var find_masks_time := 0
var load_new_chunks_time := 0
var mark_retirees_time := 0
var check_retirees_time := 0
var kill_dead_chunks_time := 0

# ========== NODE INITIALIZATION ==========

func _init(_player: Player, _seed: int, _max_octree_depth: int, _noise: WorldNoise, _is_current_world := false) -> void:
	self.max_octree_depth = _max_octree_depth
	self.chunk_count = int(pow(2, max_octree_depth))
	self.noise = _noise
	self.player = _player
	self.root_node_size = int(CHUNK_SIZE * pow(2, max_octree_depth))
	self.is_current_world = _is_current_world

func _ready() -> void:
	# if global Util.debug is true, print total chunk count volume
	if Utils.debug: print("Chunk manager ready. Total chunk count: ", int(pow(chunk_count, 3)))

## Workers use this manager's members, so none may still run when it is freed.
func _exit_tree() -> void:
	_shutting_down = true
	for task_id in pending_tasks.keys():
		WorkerThreadPool.wait_for_task_completion(task_id)
	pending_tasks.clear()
	if leaf_job_task != -1:
		WorkerThreadPool.wait_for_task_completion(leaf_job_task)
		leaf_job_task = -1

func get_timing_snapshot() -> String:
	return "
	ChunkManager process: %d
	Octree iterate: %d <- not on main
	Find Masks: %d <- not on main
	Load Chunks: %d
	Mark Retirees: %d
	Check Retirees: %d
	Kill Chunks: %d" % [
		process_time,
		octree_iterate_time,
		find_masks_time,
		load_new_chunks_time,
		mark_retirees_time,
		check_retirees_time,
		kill_dead_chunks_time, ]

# ========== PROCESS FUNCTION ==========

func _process(_delta: float) -> void:
	var start_time := Time.get_ticks_usec()
	var local_player_pos := to_local(player.global_position)

	# The first leaf set is computed right away and applied in full so that the loading screen knows how many tasks to wait for
	if not first_iteration_complete:
		new_chunk_set = _compute_leaf_set(local_player_pos, is_current_world)
		var load_start := Time.get_ticks_usec()
		_begin_phase(ReconcilePhase.LOAD, new_chunk_set.keys())
		_step_reconcile(-1)
		load_new_chunks_time = Time.get_ticks_usec() - load_start
		total_first_tasks = pending_tasks.size()
		if player.spawn_world == self.get_parent():
			Utils.emit_signal("chunk_task_count_found", total_first_tasks)
		prev_player_pos = local_player_pos
		first_iteration_complete = true

	# When the player passes the movement threshold, compute a new leaf set on a worker thread. Only one job runs at a time; by the time it is done the player has usually moved further, which simply starts the next one.
	if is_current_world and leaf_job_task == -1 and not _leaf_result_ready and local_player_pos.distance_to(prev_player_pos) >= player_movement_threshold:
		prev_player_pos = local_player_pos
		leaf_job_task = WorkerThreadPool.add_task(_leaf_job.bind(local_player_pos, is_current_world))

	if leaf_job_task != -1 and WorkerThreadPool.is_task_completed(leaf_job_task):
		WorkerThreadPool.wait_for_task_completion(leaf_job_task)
		leaf_job_task = -1
		_leaf_result_ready = true

	# Apply a finished leaf set as soon as the previous reconcile is done. new_chunk_set is only ever replaced here, on the main thread.
	if _leaf_result_ready and _phase == ReconcilePhase.IDLE:
		new_chunk_set = _leaf_job_result
		_leaf_job_result = {}
		_leaf_result_ready = false
		_begin_phase(ReconcilePhase.MARK, active_chunk_set.keys())
	elif _phase == ReconcilePhase.IDLE and _cleanup_dirty and start_time - _last_cleanup_time >= CLEANUP_INTERVAL and not (retiring_chunk_set.is_empty() and ready_to_die_chunk_set.is_empty()):
		_begin_phase(ReconcilePhase.CHECK, retiring_chunk_set.keys())

	_build_finished_chunks()
	if _phase != ReconcilePhase.IDLE: _step_reconcile(RECONCILE_BUDGET)

	process_time = Time.get_ticks_usec() - start_time

# ========== LEAF SET (WORKER THREAD) ==========

## Worker task body: computes the next leaf set into `_leaf_job_result`.
func _leaf_job(local_player_pos: Vector3, current_world: bool) -> void:
	if _shutting_down: return
	_leaf_job_result = _compute_leaf_set(local_player_pos, current_world)

## Builds the octree for the given player position and gives every leaf its transition mask. Returns a new dictionary and does not touch any manager state other than the timing variables, so it is safe to run on a worker thread.
func _compute_leaf_set(local_player_pos: Vector3, current_world: bool) -> Dictionary[Vector4i, int]:
	var start_time := Time.get_ticks_usec()
	var leaves: Dictionary[Vector4i, int] = {}
	if current_world: _octree_iterate(leaves, local_player_pos)
	else: leaves.set(Vector4i(0, 0, 0, root_node_size / CHUNK_SIZE), 0)
	octree_iterate_time = Time.get_ticks_usec() - start_time
	start_time = Time.get_ticks_usec()
	_find_masks(leaves)
	find_masks_time = Time.get_ticks_usec() - start_time
	return leaves

## Iterate through the octree, starting at the root node, and determine what chunks need to be split until depth reaches max_octree_depth. Leaves are added to `leaves` as Vector4i(x, y, z, lod_step) with a mask of 0.
func _octree_iterate(leaves: Dictionary[Vector4i, int], local_player_pos: Vector3, depth: int = 0, parent_pos: Vector3 = Vector3.ZERO) -> void:
	var cell_size := root_node_size >> depth
	var cell_extent := Vector3(cell_size, cell_size, cell_size)
	var split_distance := float(cell_size * distance_factor)
	@warning_ignore("integer_division")
	var lod_step := cell_size / CHUNK_SIZE
	# Each cell can be split into 8 cells, then each of those can be split into finer 8 cells depending on distance to player and distance_factor
	for _x in 2:
		for _y in 2:
			for _z in 2:
				# Get distance to edge of cell and use that to determine if the cell should render or split
				var cell_pos := parent_pos + Vector3(cell_size * _x, cell_size * _y, cell_size * _z)
				var player_pos_clamped := local_player_pos.clamp(cell_pos, cell_extent + cell_pos)
				if player_pos_clamped.distance_to(local_player_pos) < split_distance and depth < max_octree_depth:
					_octree_iterate(leaves, local_player_pos, depth + 1, cell_pos)
				else:
					leaves.set(Vector4i(cell_pos.x, cell_pos.y, cell_pos.z, lod_step), 0)

## Gives each leaf a 6-bit value. Each bit represents if a face should have transition cells or not (1 for yes, 0 for no). Bits: x, y, z, -x, -y, -z
func _find_masks(leaves: Dictionary[Vector4i, int]) -> void:
	for key: Vector4i in leaves.keys():
		if key.w == chunk_count: continue
		var pos := Vector3i(key.x, key.y, key.z)
		var mask := 0
		for face in 6:
			if _does_face_need_transition_cells(leaves, pos, key.w, FACE_DIRECTIONS[face]): mask |= 1 << face
		leaves.set(key, mask)

## True when the leaf across the given face of the leaf at `pos` is one LOD level coarser, so this face needs transition cells.
func _does_face_need_transition_cells(leaves: Dictionary[Vector4i, int], pos: Vector3i, lod_step: int, direction: Vector3i) -> bool:
	var coarse_step := lod_step * 2
	var coarse_length := coarse_step * CHUNK_SIZE
	var fine_length := lod_step * CHUNK_SIZE
	# A point just across the face: on the face axis one step outside the leaf, on the other axes its own corner
	var probe := pos
	for axis in 3:
		if direction[axis] > 0: probe[axis] += fine_length
		elif direction[axis] < 0: probe[axis] -= 1
	# The octree is built from cells of root_node_size at 0 and root_node_size on every axis (see _octree_iterate), so leaves exist up to twice the volume size. Nothing exists below 0.
	var tree_size := root_node_size * 2
	if probe.x < 0 or probe.y < 0 or probe.z < 0 or probe.x >= tree_size or probe.y >= tree_size or probe.z >= tree_size:
		return false
	var origin := (probe / coarse_length) * coarse_length
	return leaves.has(Vector4i(origin.x, origin.y, origin.z, coarse_step))

# ========== RECONCILE ==========

## Starts a reconcile phase over the given keys. Call `_step_reconcile()` to run it.
func _begin_phase(phase: ReconcilePhase, keys: Array) -> void:
	# Cleared when a pass starts and not when it ends, so a chunk becoming ACTIVE during the pass schedules another one
	if _phase == ReconcilePhase.IDLE: _cleanup_dirty = false
	_phase = phase
	_phase_keys = keys
	_phase_index = 0
	_phase_time = 0

## Runs the current phase, and the phases that follow it, for at most `budget` microseconds. A negative budget runs until all phases are done.
func _step_reconcile(budget: int) -> void:
	var deadline := Time.get_ticks_usec() + budget
	while _phase != ReconcilePhase.IDLE:
		var slice_start := Time.get_ticks_usec()
		var finished := _run_phase(deadline if budget >= 0 else -1)
		_phase_time += Time.get_ticks_usec() - slice_start
		if not finished: return
		_end_phase()
		if budget >= 0 and Time.get_ticks_usec() >= deadline: return

## Processes keys of the current phase until they are all done (returns true) or the deadline passes (returns false). A negative deadline means no limit.
func _run_phase(deadline: int) -> bool:
	var count := _phase_keys.size()
	while _phase_index < count:
		var key: Vector4i = _phase_keys[_phase_index]
		_phase_index += 1
		match _phase:
			ReconcilePhase.LOAD: _load_chunk(key)
			ReconcilePhase.MARK: _mark_retiring_chunk(key)
			ReconcilePhase.CHECK: _check_retiring_chunk(key)
			ReconcilePhase.COVERAGE: _add_coverage(key)
			ReconcilePhase.KILL: _unload_octree_chunk(key)
		# Looking at the clock for every key would cost more than some of the keys do
		if deadline >= 0 and _phase_index & 15 == 0 and Time.get_ticks_usec() >= deadline:
			return _phase_index >= count
	return true

## Records the timing of the finished phase and starts the next one.
func _end_phase() -> void:
	match _phase:
		ReconcilePhase.MARK:
			mark_retirees_time = _phase_time
			_begin_phase(ReconcilePhase.LOAD, new_chunk_set.keys())
		ReconcilePhase.LOAD:
			if first_iteration_complete: load_new_chunks_time = _phase_time
			_begin_phase(ReconcilePhase.CHECK, retiring_chunk_set.keys())
		ReconcilePhase.CHECK:
			check_retirees_time = _phase_time
			if pending_tasks.is_empty() and not retiring_chunk_set.is_empty():
				for retiree: Chunk in retiring_chunk_set.values(): retiree.volume_counter = 0
				_begin_phase(ReconcilePhase.COVERAGE, active_chunk_set.keys())
			else:
				_begin_phase(ReconcilePhase.KILL, ready_to_die_chunk_set.keys())
		ReconcilePhase.COVERAGE:
			for key: Vector4i in retiring_chunk_set.keys():
				var retiree: Chunk = retiring_chunk_set[key]
				if retiree.volume_counter >= _chunk_volume(retiree):
					retiree.state = Chunk.chunk_state.READY_TO_DIE
					ready_to_die_chunk_set.set(key, retiree)
					retiring_chunk_set.erase(key)
			_begin_phase(ReconcilePhase.KILL, ready_to_die_chunk_set.keys())
		ReconcilePhase.KILL:
			kill_dead_chunks_time = _phase_time
			_phase = ReconcilePhase.IDLE
			_phase_keys = []
			_last_cleanup_time = Time.get_ticks_usec()

## Compare one leaf of new_chunk_set against the existing chunks and load, revive or update the chunk for it.
func _load_chunk(key: Vector4i) -> void:
	var mask: int = new_chunk_set.get(key, 0)
	var chunk: Chunk = null
	# if new chunk already exists but is READY_TO_DIE or is RETIRING, set as ACTIVE and add its volume to the retiring ancestor's volume counter if applicable
	if ready_to_die_chunk_set.has(key):
		chunk = ready_to_die_chunk_set[key]
		ready_to_die_chunk_set.erase(key)
		_revive_chunk(key, chunk)
	elif retiring_chunk_set.has(key):
		chunk = retiring_chunk_set[key]
		retiring_chunk_set.erase(key)
		_revive_chunk(key, chunk)
	elif active_chunk_set.has(key):
		chunk = active_chunk_set[key]
	# if new chunk is in pending_chunk_set, update its transition mask. It is checked against the built one when its task finishes.
	elif pending_chunk_set.has(key):
		pending_chunk_set[key].desired_transition_mask = mask
		return
	# Otherwise, load the chunk for the first time
	else:
		_load_octree_chunk(Vector3i(key.x, key.y, key.z), key.w)
		return
	chunk.desired_transition_mask = mask
	_remesh_if_needed(chunk)

func _revive_chunk(key: Vector4i, chunk: Chunk) -> void:
	active_chunk_set.set(key, chunk)
	chunk.state = Chunk.chunk_state.ACTIVE
	_iterate_through_parents(_chunk_volume(chunk), chunk, Vector4i.ZERO, false)

## Starts a new mesh generation for an ACTIVE chunk if its built transition mask differs from the desired one and no task is running for it.
func _remesh_if_needed(chunk: Chunk) -> void:
	if chunk.is_empty or chunk.thread_id != -1: return
	if chunk.desired_transition_mask != chunk.built_transition_mask:
		_schedule_generation(chunk, chunk.desired_transition_mask)

## Moves an ACTIVE chunk that is no longer wanted to RETIRING.
func _mark_retiring_chunk(key: Vector4i) -> void:
	if new_chunk_set.has(key): return
	# Intentionally do not scan through pending chunks, as they most likely have a thread that cannot be killed part way through.
	var chunk: Chunk = active_chunk_set.get(key)
	if chunk == null: return
	active_chunk_set.erase(key)
	chunk.state = Chunk.chunk_state.RETIRING
	retiring_chunk_set.set(key, chunk)

## If a retiring chunk's space is filled by an ACTIVE ancestor, move it to ready_to_die_chunk_set. Any ancestor will do, not just the parent: when the player moves fast, the leaf set can skip LOD levels.
func _check_retiring_chunk(key: Vector4i) -> void:
	var retiree: Chunk = retiring_chunk_set.get(key)
	if retiree == null: return
	var ancestor_key := get_parent_key(retiree)
	while true:
		if active_chunk_set.has(ancestor_key):
			retiree.state = Chunk.chunk_state.READY_TO_DIE
			ready_to_die_chunk_set.set(key, retiree)
			retiring_chunk_set.erase(key)
			return
		if ancestor_key.w * CHUNK_SIZE >= root_node_size: return
		ancestor_key = get_parent_key(null, ancestor_key)

## Adds the volume of an ACTIVE chunk to every RETIRING ancestor of it. Active chunks never overlap, so afterwards a retiree's volume_counter is the exact volume of its space that is covered.
func _add_coverage(key: Vector4i) -> void:
	var chunk: Chunk = active_chunk_set.get(key)
	if chunk == null: return
	var volume := _chunk_volume(chunk)
	var ancestor_key := get_parent_key(chunk)
	while true:
		if retiring_chunk_set.has(ancestor_key): retiring_chunk_set[ancestor_key].volume_counter += volume
		if ancestor_key.w * CHUNK_SIZE >= root_node_size: return
		ancestor_key = get_parent_key(null, ancestor_key)

func _chunk_volume(chunk: Chunk) -> int:
	var chunk_axis_volume := chunk.size * chunk.lod_step
	return chunk_axis_volume * chunk_axis_volume * chunk_axis_volume

## Looks at parent one cell_size up, constructs it's key, and see if that key is in the retiring chunk set. If not, goes to the next parent up, or stops at root_node_size. If neither a chunk or a key are passed, an error is thrown.
func _iterate_through_parents(volume_to_add: int, chunk: Chunk = null, key: Vector4i = Vector4i.ZERO, decrease_count: bool = false) -> void:
	var parent_key: Vector4i

	if chunk != null: parent_key = get_parent_key(chunk)
	elif key != Vector4i.ZERO: parent_key = get_parent_key(null, key)
	else: push_error("_iterate_through_parents was not given a chunk or key!"); return

	# Check to see if parent_key is in retiring_chunk_set and if so, add volume_to_add to it's volume counter
	if retiring_chunk_set.has(parent_key):
		var retiring_parent: Chunk = retiring_chunk_set.get(parent_key)

		if decrease_count: retiring_parent.volume_counter -= volume_to_add
		if not decrease_count: retiring_parent.volume_counter += volume_to_add

		# If retiree's volume is now filled, move to READY_TO_DIE
		if retiring_parent.volume_counter >= _chunk_volume(retiring_parent):
			retiring_parent.state = Chunk.chunk_state.READY_TO_DIE
			ready_to_die_chunk_set.set(parent_key, retiring_parent)
			retiring_chunk_set.erase(parent_key)
			return
	elif chunk != null and root_node_size == CHUNK_SIZE * chunk.lod_step: return
	elif key != Vector4i.ZERO and root_node_size == CHUNK_SIZE * key.w: return
	else:
		_iterate_through_parents(volume_to_add, null, parent_key)

## Find and return the parent key from a given chunk or key. Must pass either a chunk or a key. If neither are passed, and error is thrown.
func get_parent_key(chunk: Chunk = null, key: Vector4i = Vector4i.ZERO) -> Vector4i:
	if chunk != null:
		var parent_cell_lod_step := chunk.lod_step * 2
		var parent_cell_size := CHUNK_SIZE * parent_cell_lod_step
		var parent_pos_x: int = floor(chunk.position.x / parent_cell_size) * parent_cell_size # using floor() drops the decimal, giving us parent grid space position when we re-multiply by parent_cell_size
		var parent_pos_y: int = floor(chunk.position.y / parent_cell_size) * parent_cell_size
		var parent_pos_z: int = floor(chunk.position.z / parent_cell_size) * parent_cell_size
		var parent_key := Vector4i(parent_pos_x, parent_pos_y, parent_pos_z, parent_cell_lod_step)

		return parent_key

	elif key != Vector4i.ZERO:
		var parent_cell_lod_step: int = key.w * 2
		var parent_cell_size := CHUNK_SIZE * parent_cell_lod_step
		var parent_pos_x: int = floor(key.x / parent_cell_size) * parent_cell_size # using floor() drops the decimal, giving us parent grid space position when we re-multiply by parent_cell_size
		var parent_pos_y: int = floor(key.y / parent_cell_size) * parent_cell_size
		var parent_pos_z: int = floor(key.z / parent_cell_size) * parent_cell_size
		var parent_key := Vector4i(parent_pos_x, parent_pos_y, parent_pos_z, parent_cell_lod_step)

		return parent_key
	else: push_error("get_parent_key was not given a chunk or key!"); return Vector4i.ZERO;

# ========== CHUNK LIFE CYCLE ==========

## Create a new Chunk. Chunks that can never have a mesh are ACTIVE right away; the others get a worker task for their mesh data and join the scene tree once they have a mesh.
func _load_octree_chunk(chunk_pos: Vector3i, lod_step: int) -> void:
	var new_chunk := Chunk.new(CHUNK_SIZE, noise, chunk_pos, lod_step)
	var chunk_key := Vector4i(chunk_pos.x, chunk_pos.y, chunk_pos.z, lod_step)
	var mask: int = new_chunk_set.get(chunk_key, 0)
	new_chunk.desired_transition_mask = mask
	new_chunk.position = chunk_pos

	if new_chunk.is_provably_empty():
		new_chunk.built_transition_mask = mask
		new_chunk.state = Chunk.chunk_state.ACTIVE
		active_chunk_set.set(chunk_key, new_chunk)
		_chunk_became_active(new_chunk)
		return

	pending_chunk_set.set(chunk_key, new_chunk)
	_schedule_generation(new_chunk, mask)

## Starts a worker task that generates the mesh data of the chunk for the given transition mask.
func _schedule_generation(chunk: Chunk, mask: int) -> void:
	var task_id := WorkerThreadPool.add_task(_generate_chunk_task.bind(chunk, mask))
	chunk.thread_id = task_id
	pending_tasks.set(task_id, chunk)

## Worker task body: generates the mesh data, then hands the chunk to the main thread.
func _generate_chunk_task(chunk: Chunk, mask: int) -> void:
	if _shutting_down: return
	chunk.generate_mesh_data(mask)
	_finished_mutex.lock()
	_finished_chunks.append(chunk)
	_finished_mutex.unlock()

## Takes chunks whose worker task has finished and builds their meshes, for at most MAXIMUM_BUILD_TIME. Cost scales with the number of finished chunks, not the number of pending ones.
func _build_finished_chunks() -> void:
	_finished_mutex.lock()
	if not _finished_chunks.is_empty():
		_build_queue.append_array(_finished_chunks)
		_finished_chunks.clear()
	_finished_mutex.unlock()

	var start_time := Time.get_ticks_usec()
	while _build_queue_index < _build_queue.size():
		if Time.get_ticks_usec() - start_time >= MAXIMUM_BUILD_TIME: break
		var chunk: Chunk = _build_queue[_build_queue_index]
		_build_queue_index += 1
		_finish_chunk(chunk)
		if tasks_emitted < total_first_tasks and player.spawn_world == self.get_parent():
			tasks_emitted += 1
			Utils.emit_signal("chunk_task_completed", tasks_emitted)

	if _build_queue_index >= _build_queue.size():
		_build_queue.clear()
		_build_queue_index = 0

## Main thread part of a finished mesh generation: reclaim the task, build the mesh, and make the chunk ACTIVE if it was still PROCESSING.
func _finish_chunk(chunk: Chunk) -> void:
	var task_id := chunk.thread_id
	WorkerThreadPool.wait_for_task_completion(task_id)
	pending_tasks.erase(task_id)
	chunk.thread_id = -1

	# A new chunk that the latest leaf set no longer wants (the player moved on while it was generating) is dropped instead of being shown. Nothing depends on it yet, and no pass would retire it later.
	if chunk.state == Chunk.chunk_state.PROCESSING:
		var pending_key := Vector4i(chunk.position.x, chunk.position.y, chunk.position.z, chunk.lod_step)
		if not new_chunk_set.has(pending_key):
			pending_chunk_set.erase(pending_key)
			chunk.free()
			return

	if chunk.mesh_data != null:
		# Chunks only join the scene tree once they have something to show
		if chunk.get_parent() == null: add_child(chunk)
		chunk.build_mesh()

	# if the chunk comes from pending chunks, move it to active and add it's volume to it's retiring ancestor (if applicable)
	if chunk.state == Chunk.chunk_state.PROCESSING:
		var key := Vector4i(chunk.position.x, chunk.position.y, chunk.position.z, chunk.lod_step)
		chunk.state = Chunk.chunk_state.ACTIVE
		active_chunk_set.set(key, chunk)
		pending_chunk_set.erase(key)
		_chunk_became_active(chunk)

	# The desired mask may have changed while the task was running
	if chunk.state == Chunk.chunk_state.ACTIVE: _remesh_if_needed(chunk)
	# A chunk that was waiting for this task before it could be unloaded can go now
	else: _cleanup_dirty = true

## Bookkeeping for a chunk that just became ACTIVE: add its volume to a retiring ancestor (not needed during the first load) and request a retire/kill pass.
func _chunk_became_active(chunk: Chunk) -> void:
	_cleanup_dirty = true
	if first_iteration_complete: _iterate_through_parents(_chunk_volume(chunk), chunk)

## Remove a READY_TO_DIE chunk from the scene and the sets, once no worker task is using it anymore.
func _unload_octree_chunk(key: Vector4i) -> void:
	var chunk_to_unload: Chunk = ready_to_die_chunk_set.get(key)
	if chunk_to_unload == null: return
	# a chunk with a running or uncollected task stays until the task has been collected
	if chunk_to_unload.thread_id != -1: return

	ready_to_die_chunk_set.erase(key)
	var mesh_instance := chunk_to_unload.find_child("ChunkMesh", true, false)
	if mesh_instance:
		var tween := create_tween()
		tween.tween_property(mesh_instance, "transparency", 1, 1)
		tween.tween_callback(chunk_to_unload.queue_free)
	elif chunk_to_unload.get_parent() == null:
		# never joined the scene tree (no mesh)
		chunk_to_unload.free()
	else:
		chunk_to_unload.queue_free()

# ========== PUBLIC FUNCTIONS ==========

## Returns an Vector4i value which is the key of the active chunk that player is in. If no active chunk is found, Vector4i.ZERO is returned instead.
func get_player_chunk_key() -> Vector4i:
	var player_pos := to_local(player.global_position)
	# convert player position to chunk coords
	var player_chunk_pos := Vector3i(player_pos / CHUNK_SIZE) * CHUNK_SIZE
	var lod_step := 1
	var key := Vector4i(player_chunk_pos.x, player_chunk_pos.y, player_chunk_pos.z, lod_step)
	var key_found := false
	if active_chunk_set.has(key): return key
	else:
		while not key_found:
			key = get_parent_key(null, key)
			if active_chunk_set.has(key): key_found = true
			elif key.w == pow(2, max_octree_depth):
				key = Vector4i.ZERO
				key_found = true

	return key
