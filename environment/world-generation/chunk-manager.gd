extends Node3D
class_name ChunkManager

## The size of each chunk in meters
const CHUNK_SIZE := 16
## The number of chunks on each axis. Determined from passed in _max_octree_depth in _init()
var chunk_count: int
## Scalar field that is used to determine the shape of the mesh along the chunks.
var noise: WorldNoise
## Reference to the player node
var player: Player
var player_pos: Vector3
var is_current_world := false

# ========== CHUNK MANAGEMENT VARIABLES ==========

## Stores all marching cube tasks waiting to be completed off the main thread. int is the task ID, Chunk is the actual Chunk node waiting on the task
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
var find_masks_task := -1

# ========== CHUNK SET DICTIONARIES ==========

# Dictionary[[Vec3(position), lod_level], chunk].
var new_chunk_set: Dictionary[Vector4i, int] = {} # value int is unimportant and never used
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

func get_timing_snapshot() -> String:
	return "
	ChunkManager process: %d
	Octree iterate: %d
	Load Chunks: %d
	Mark Retirees: %d 
	Check Retirees: %d: 
	Kill Chunks: %d
	Find Masks: %d <- not on main" % [
		process_time,
		octree_iterate_time,
		load_new_chunks_time,
		mark_retirees_time,
		check_retirees_time,
		kill_dead_chunks_time,
		find_masks_time, ]
# ========== PROCESS FUNCTION ==========

func _process(_delta: float) -> void:
	var start_time := Time.get_ticks_usec()
	# If a player position hasn't been recorded yet, iterate through the octree for the first time, compare leaf sets (loads new_chunk_set into current_chunk_set to load chunks in), and record player position
	if not first_iteration_complete:
		_octree_iterate()
		octree_iterate_time = Time.get_ticks_usec() - start_time
		_find_masks()
		_load_new_chunks()
		total_first_tasks = pending_tasks.size()
		if player.spawn_world == self.get_parent():
			Utils.emit_signal("chunk_task_count_found", total_first_tasks)
		prev_player_pos = to_local(player.global_position)
		first_iteration_complete = true
	# When the player passes the movement threshold, store the new position, clear the new leaf set, re-iterate through the octree, and compare leaf sets to update chunks
	if to_local(player.global_position).distance_to(prev_player_pos) >= player_movement_threshold and is_current_world:
		prev_player_pos = to_local(player.global_position)
		new_chunk_set.clear()
		if is_current_world: _octree_iterate()
		else: _octree_iterate(max_octree_depth - 2)
		octree_iterate_time = Time.get_ticks_usec() - start_time
		
		var start_time_a := Time.get_ticks_usec()
		if find_masks_task == -1:
			find_masks_task = WorkerThreadPool.add_task(_find_masks)
	
	if find_masks_task != -1 and WorkerThreadPool.is_task_completed(find_masks_task):
		WorkerThreadPool.wait_for_task_completion(find_masks_task)
		find_masks_task = -1
		
		var start_time_a := Time.get_ticks_usec()
		_load_new_chunks()
		load_new_chunks_time = Time.get_ticks_usec() - start_time_a
		
		start_time_a = Time.get_ticks_usec()
		_mark_retiring_chunks()
		mark_retirees_time = Time.get_ticks_usec() - start_time_a
		start_time_a = Time.get_ticks_usec()
		_check_retiring_chunks()
		check_retirees_time = Time.get_ticks_usec() - start_time_a
		start_time_a = Time.get_ticks_usec()
		_kill_dead_chunks()
		kill_dead_chunks_time = Time.get_ticks_usec() - start_time_a

	# Iterate through pending tasks (created from current_chunk_set chunks; see _load_octree_chunk()) but stop after 3ms
	const MAXIMUM_BUILD_TIME = 4000 # time in microseconds
	var current_build_time = 0
	var pending_keys = pending_tasks.keys()

	for id in pending_keys:
		if current_build_time >= MAXIMUM_BUILD_TIME:
			break

		# Once a thread in pending_taks is done, remove the thread reference from the chunk and build it's mesh
		if WorkerThreadPool.is_task_completed(id):
			if pending_tasks.get(id) == null:
				pending_tasks.erase(id)
				continue
				
			var chunk: Chunk = pending_tasks.get(id)
			
			if pending_chunk_set.size() > 0 and chunk.state != Chunk.chunk_state.PROCESSING:
				continue
			
			var thread_start_time = Time.get_ticks_usec()
			WorkerThreadPool.wait_for_task_completion(id)
			
			chunk.thread_id = -1
			if chunk.mesh_data != null: chunk.build_mesh()
		
			# if the chunk comes from pending chunks, move it to active and add it's volume to it's retiring ancestor (if applicable)
			if chunk.state == Chunk.chunk_state.PROCESSING:
					chunk.state = Chunk.chunk_state.ACTIVE
					var key := Vector4i(chunk.position.x, chunk.position.y, chunk.position.z, chunk.lod_step)
					active_chunk_set.set(key, chunk)
					pending_chunk_set.erase(key)
					# If first_iteration_complete, then search for a retiring parent. If found, add to retiree's volume counter (done in _iterate_through_parents).
					if first_iteration_complete:
						var chunk_axis_volume := chunk.size * chunk.lod_step
						var chunk_volume_to_add := chunk_axis_volume * chunk_axis_volume * chunk_axis_volume
						_iterate_through_parents(chunk_volume_to_add, chunk)

			# Remove the task from the set of pending tasks once it's finished
			pending_tasks.erase(id)
			current_build_time += Time.get_ticks_usec() - thread_start_time
			
			if tasks_emitted < total_first_tasks and player.spawn_world == self.get_parent():
				tasks_emitted += 1
				Utils.emit_signal("chunk_task_completed", tasks_emitted)
	
	process_time = Time.get_ticks_usec() - start_time

# ========== PRIVATE FUNCTIONS ==========

## Iterate through the octree, starting at the root node, and determine what chunks need to be split until depth reaches max_octree_depth. Add chunks to new_chunk_set to be compared against current_chunk_set later
func _octree_iterate(depth: int = 0, parent_pos: Vector3 = Vector3.ZERO) -> void:
	player_pos = to_local(player.global_position)
	var player_pos_clamped: Vector3
	var cell_pos: Vector3
	var cell_size := int(root_node_size / pow(2, depth))
	# iterate through cells at this octree depth and either continue iterating, or append to new leaf set depending on distance to player
	# Each cell can be split into 8 cells, then each of those can be split into finer 8 cells depending on distance to player and distance_factor
	if is_current_world:
		for _x in 2:
			for _y in 2:
				for _z in 2:
					# Get distance to edge of cell and use that to determine if the cell should render or split
					cell_pos = parent_pos + Vector3(cell_size * _x, cell_size * _y, cell_size * _z)
					player_pos = to_local(player.global_position)
					player_pos_clamped = player_pos.clamp(cell_pos, Vector3(cell_size, cell_size, cell_size) + cell_pos)
					if player_pos_clamped.distance_to(player_pos) < cell_size * distance_factor and depth < max_octree_depth:
						_octree_iterate(depth + 1, cell_pos)
					else:
						@warning_ignore("integer_division")
						var lod_step := cell_size / CHUNK_SIZE
						new_chunk_set.set(Vector4i(cell_pos.x, cell_pos.y, cell_pos.z, lod_step), 0)
	else:
		new_chunk_set.set(Vector4i(0, 0, 0, root_node_size / CHUNK_SIZE), 0)

## Iterates through new_chunk_set and gives each key a 6-bit value. These are applied to pending and active chunks in reconcile_masks()
func _find_masks() -> void:
	var start_time := Time.get_ticks_usec()
	for key: Vector4i in new_chunk_set.keys():
		# mask is a 6-bit value. Each bit represents if a face should have transition cells or not (1 for yes, 0 for no). 
		# mask bits: x, y, z, -x, -y, -z
		var mask := 0
		if key.w == chunk_count: continue
		
		var pos: Vector3i = Vector3i(key.x, key.y, key.z)
		var lod: int = key.w

		var x_positive := _does_face_need_transition_cells(pos, lod, Vector3i(1, 0, 0))
		var x_negative := _does_face_need_transition_cells(pos, lod, Vector3i(-1, 0, 0))
		var y_positive := _does_face_need_transition_cells(pos, lod, Vector3i(0, 1, 0))
		var y_negative := _does_face_need_transition_cells(pos, lod, Vector3i(0, -1, 0))
		var z_positive := _does_face_need_transition_cells(pos, lod, Vector3i(0, 0, 1))
		var z_negative := _does_face_need_transition_cells(pos, lod, Vector3i(0, 0, -1))

		if x_positive: mask |= (1 << 0)
		if y_positive: mask |= (1 << 1)
		if z_positive: mask |= (1 << 2)
		if x_negative: mask |= (1 << 3)
		if y_negative: mask |= (1 << 4)
		if z_negative: mask |= (1 << 5)

		new_chunk_set.set(key, mask)
	find_masks_time = Time.get_ticks_usec() - start_time

func _does_face_need_transition_cells(pos: Vector3i, lod_step: int, direction: Vector3i) -> bool:
	var coarse_step := lod_step * 2
	var coarse_length := coarse_step * CHUNK_SIZE
	var fine_length := lod_step * CHUNK_SIZE
	# move to the face plane (add fine_length only on positive axes), then step just across it
	var face_point := Vector3(pos)
	for axis in 3:
		if direction[axis] > 0: face_point[axis] += fine_length
	var probe := face_point + Vector3(direction) * 0.5
	var origin := Vector3i(
		floor(probe.x / coarse_length) * coarse_length,
		floor(probe.y / coarse_length) * coarse_length,
		floor(probe.z / coarse_length) * coarse_length,
	)
	return new_chunk_set.has(Vector4i(origin.x, origin.y, origin.z, coarse_step))

## Compare new_chunk_set vs pending_chunk_set and active_chunk_set to determine chunks to load and then load them
func _load_new_chunks() -> void:
	for key: Vector4i in new_chunk_set.keys():
		# if new chunk already exists but is READY_TO_DIE or is RETIRING, set as ACTIVE and ensure that volume is removed from retiring parent volume counter if applicable
		if ready_to_die_chunk_set.has(key):
			active_chunk_set.set(key, ready_to_die_chunk_set[key])
			var chunk: Chunk = active_chunk_set.get(key)
			chunk.desired_transition_mask = new_chunk_set.get(key)
			chunk.state = Chunk.chunk_state.ACTIVE
			var chunk_volume_axis = chunk.size * chunk.lod_step
			var chunk_volume = chunk_volume_axis * chunk_volume_axis * chunk_volume_axis
			_iterate_through_parents(chunk_volume, chunk, Vector4i.ZERO, false)
			ready_to_die_chunk_set.erase(key)
			# use threads to generate mesh data
			var action = Callable(chunk, "generate_mesh_data")
			var task_id = WorkerThreadPool.add_task(action.bind(new_chunk_set.get(key)))
			chunk.thread_id = task_id
			pending_tasks.set(task_id, chunk)
		elif retiring_chunk_set.has(key):
			active_chunk_set.set(key, retiring_chunk_set[key])
			var chunk: Chunk = active_chunk_set.get(key)
			chunk.desired_transition_mask = new_chunk_set.get(key)
			chunk.state = Chunk.chunk_state.ACTIVE
			var chunk_volume_axis = chunk.size * chunk.lod_step
			var chunk_volume = chunk_volume_axis * chunk_volume_axis * chunk_volume_axis
			_iterate_through_parents(chunk_volume, chunk, Vector4i.ZERO, false)
			retiring_chunk_set.erase(key)
			# use threads to generate mesh data
			var action = Callable(chunk, "generate_mesh_data")
			var task_id = WorkerThreadPool.add_task(action.bind(new_chunk_set.get(key)))
			chunk.thread_id = task_id
			pending_tasks.set(task_id, chunk)
		# if key is in active chunk, reconcile a potentially new transition mask and relaod it's mesh if it's needed and the chunk is not already working
		elif active_chunk_set.has(key):
			var chunk: Chunk = active_chunk_set.get(key)
			chunk.desired_transition_mask = new_chunk_set.get(key)
			if chunk.desired_transition_mask != chunk.built_transition_mask and chunk.thread_id == -1:
				# use threads to generate mesh data
				var action = Callable(chunk, "generate_mesh_data")
				var task_id = WorkerThreadPool.add_task(action.bind(new_chunk_set.get(key)))
				chunk.thread_id = task_id
				pending_tasks.set(task_id, chunk)
		# if new chunk is in pending_chunk_set, update it's transition key, but do not regenerate it as it all pening chunks are working
		elif pending_chunk_set.has(key):
			var chunk: Chunk = pending_chunk_set.get(key)
			if new_chunk_set.get(key):
				chunk.desired_transition_mask = new_chunk_set.get(key)
		# Otherwise, load the chunk for the first time
		else:
			_load_octree_chunk(Vector3i(key.x, key.y, key.z), key.w)

## Compare active_chunk_set with new_chunk_set and move chunks from active to retiring.
func _mark_retiring_chunks() -> void:
	var keys_to_move = []

	# Intentionally do not scan through pending chunks, as they most likely have a thread that cannot be killed part way through.
	for key: Vector4i in active_chunk_set.keys():
		var stay_active := new_chunk_set.has(key)
		if not stay_active and active_chunk_set[key].state != Chunk.chunk_state.RETIRING:
			keys_to_move.append(key)
	
	for key: Vector4i in keys_to_move:
		var chunk: Chunk = active_chunk_set.get(key)
		active_chunk_set.erase(key)
		chunk.state = Chunk.chunk_state.RETIRING
		retiring_chunk_set.set(key, chunk)

## Look through retiring chunks and see if their space is filled by a parent ACTIVE chunks. If so, move to ready_to_die_chunk_set
func _check_retiring_chunks() -> void:
	# Keep track of chunks that will need to be removed
	var chunks_to_remove: Array = []
	# For each retiring chunk, see if it's inside an active chunk or if it contains 8 active chunks. If so, add to chunks_to_remove
	for key: Vector4i in retiring_chunk_set.keys():
		# retiree variables
		var retiree: Chunk = retiring_chunk_set.get(key)

		var parent_key: Vector4i = get_parent_key(retiree)

		# If the parent is active, the retiree can be killed
		if active_chunk_set.has(parent_key):
			ready_to_die_chunk_set.set(key, retiree)
			chunks_to_remove.append(key)
	
	for key in chunks_to_remove:
		retiring_chunk_set.erase(key)

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

		var retiring_parent_volume_axis = retiring_parent.size * retiring_parent.lod_step
		var retiring_parent_volume = retiring_parent_volume_axis * retiring_parent_volume_axis * retiring_parent_volume_axis
		# If retiree's volume is now filled, move to READY_TO_DIE
		if retiring_parent.volume_counter >= retiring_parent_volume:
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
			
## Unload chunks in ready_to_die
func _kill_dead_chunks() -> void:
	for key in ready_to_die_chunk_set.keys():
		_unload_octree_chunk(key)

## Create a new Chunk node, add it to the tree, then set its mesh generation to be outside the main thread.
func _load_octree_chunk(chunk_pos: Vector3i, lod_step: int) -> void:
	var new_chunk := Chunk.new(CHUNK_SIZE, noise, chunk_pos, lod_step)
	var chunk_key := Vector4i(chunk_pos.x, chunk_pos.y, chunk_pos.z, lod_step)
	if new_chunk_set.get(chunk_key):
		new_chunk.desired_transition_mask = new_chunk_set.get(chunk_key)
	self.add_child(new_chunk)
	new_chunk.position = chunk_pos

	pending_chunk_set.set(chunk_key, new_chunk)
	
	# use threads to generate mesh data
	var action := Callable(new_chunk, "generate_mesh_data")
	var task_id := WorkerThreadPool.add_task(action.bind(new_chunk_set.get(chunk_key)))
	new_chunk.thread_id = task_id
	pending_tasks.set(task_id, new_chunk)

## Ensure a Chunks pending thread task is completed, then remove the chunk from the scene and the leaf set. Remove the task id from pending tasks as well.
func _unload_octree_chunk(key: Vector4i) -> void:
	var chunk_to_unload: Chunk = ready_to_die_chunk_set.get(key)
	
	# ensure thread task is complete before removing the chunk
	var task_id := chunk_to_unload.thread_id
	if task_id != -1 and WorkerThreadPool.is_task_completed(task_id):
		WorkerThreadPool.wait_for_task_completion(task_id)
		pending_tasks.erase(task_id)
	elif task_id != -1: return
		
	# remove chunk from leaf set and remove Chunk from scene tree if possible.
	ready_to_die_chunk_set.erase(key)
	if chunk_to_unload:
		var mesh_instance := chunk_to_unload.find_child("ChunkMesh", true, false)
		#print(chunk_to_unload.get_children(true))
		if mesh_instance:
			var tween := create_tween()
			tween.tween_property(mesh_instance, "transparency", 1, 1)
			tween.tween_callback(chunk_to_unload.queue_free)
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
