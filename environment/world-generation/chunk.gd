class_name Chunk
extends Node3D

const WIREFRAME_MATERIAL := preload("res://assets/textures/wireframe-material.tres")

## Material shared by every chunk mesh. Created on first use (always on the main thread, in `build_mesh()`).
static var _shared_material: StandardMaterial3D

## Meshes are created on worker threads, one chunk per thread. Stress tests (tools/bench/stress_move.gd) crashed the engine inside `ArrayMesh.add_surface_from_arrays()` now and then when many threads created meshes at the same moment, so creation is serialized. It is a small part of generating a chunk, so generation itself stays parallel.
static var _mesh_creation_mutex := Mutex.new()

# ============ DEBUG PROPERTIES ============

var wireframe_mode = false

# ============ BASIC CHUNK CHARACTERISTICS ============

enum chunk_state {PROCESSING, ACTIVE, RETIRING, READY_TO_DIE}

## The amount of points along the x, y, and z axis
var size: int
## Seed of the terrain generation
var world_seed: int
## noise volume to use for generating mesh data
var scalar: WorldNoise = null
## The value of the scalar field that represents the surface of the mesh
var isosurface := 0.0
## Chunk space offset to apply to vertex positions
var offset := Vector3(0, 0, 0)
## The scale/resolution of the chunk. For use in octree traversal for LODs
var lod_step: int
## The data for the mesh of this chunk. Generated in _generate_mesh_data
var mesh_data: ArrayMesh
var transition_slab_width: float
## Field normals already computed while generating the current mesh, keyed by chunk-space position. Corners are shared by several cells, so they would otherwise be sampled repeatedly. Cleared at the start of every `generate_mesh_data()`.
var _normal_cache: Dictionary[Vector3, Vector3] = {}
## Is either PROCESSING, ACTIVE, or PENDING and is used to ensure that other chunks are loaded in before this chunk free itself to prevent LOD "popping"
var state := chunk_state.PROCESSING:
	set(new_state):
		state = new_state
		# If state is set to ACTIVE, reset volume counter
		if new_state == chunk_state.ACTIVE:
			volume_counter = 0
## When retiring, ACTIVE chunks will check to see if this chunk is a parent. If so, it will add to the volume counter. Once volume_counter == size * lod_step, then this chunk can be removed.
var volume_counter := 0
## A 6-bit value defining what faces need to implement transition cells to fix seams between chunks of different resolutions
var desired_transition_mask := -1
## A 6-bit value defining the faces that are currently implementing transition cells
var built_transition_mask := -1
## True while the planet hides this chunk from the player. A culled chunk is ACTIVE but has no mesh, collider or place in the tree, and is not remeshed until it is visible again.
var is_culled := false
## True once it is known that this chunk can never have a mesh (no surface crosses it). Empty chunks are never remeshed.
var is_empty := false
## The ID of the worker thread that is constructing the mesh data. When -1, there is no thread and therefore the chunk is not building any mesh data.
var thread_id := -1

var y_stride: int
var x_stride: int
var face_stride: int

## Used when calling values from `basis_table` so that the varialbes make sense. The index of the array item maps to the corresponding face using the same conventions as the transition mask: x,y,z,-x,-y,-z. `U_AXIS` and `V_AXIS` is the equivalent x and y axis for the given face derived from a Vector3 and represented as an int. `N_AXIS` is the global x, y, or z axis represnted as an int: 0 = x, 1 = y, 2 = z. `PLANE` defines where the face is located relative to the loop location on it's given axis
enum BASIS_TABLE {
	U_AXIS,
	V_AXIS,
	N_AXIS,
	PLANE
}

## Set of arrays defining values for specific transition faces. See the definition for `enum BASIS_TABLE` for details.
var basis_table: Array[PackedInt32Array] = []

func _init(_size: int, _noise: WorldNoise, _offset: Vector3, _lod_step: int):
	self.size = _size
	self.scalar = _noise
	self.offset = _offset
	self.lod_step = _lod_step
	self.y_stride = size + 1
	self.x_stride = (size + 1) * (size + 1)
	self.face_stride = size + 1
	self.basis_table = [
		[1, 2, 0, size * lod_step],
		[2, 0, 1, size * lod_step],
		[0, 1, 2, size * lod_step],
		[2, 1, 0, 0],
		[0, 2, 1, 0],
		[1, 0, 2, 0],
	]
	self.transition_slab_width = lod_step / 2.0

func _determine_if_cell_is_empty() -> bool:
	var axis_length := size * lod_step
	var opposite_corner := offset + Vector3(axis_length, axis_length, axis_length)
	var minimum_distance: float = scalar.center.clamp(offset, opposite_corner).distance_to(scalar.center)
	var min_bias: float = scalar.get_bias_from_distance(minimum_distance)
	if min_bias > scalar.bias_threshold: mesh_data = null; return true

	var max_x: float = abs(offset.x - scalar.center.x)
	var min_x: float = abs((offset.x + (size) * lod_step) - scalar.center.x)
	var xm: float
	if max_x > min_x: xm = max_x
	else: xm = min_x

	var max_y: float = abs(offset.y - scalar.center.y)
	var min_y: float = abs((offset.y + (size) * lod_step) - scalar.center.y)
	var ym: float
	if max_y > min_y: ym = max_y
	else: ym = min_y

	var max_z: float = abs(offset.z - scalar.center.z)
	var min_z: float = abs((offset.z + (size) * lod_step) - scalar.center.z)
	var zm: float
	if max_z > min_z: zm = max_z
	else: zm = min_z

	var max_bias := scalar.get_bias_from_distance(sqrt(xm * xm + ym * ym + zm * zm))
	if max_bias < -scalar.bias_threshold: mesh_data = null; return true

	return false

## Specific return type for _construct_sample_set()
class SampleSetReturnType:
	var corner_samples: PackedFloat32Array
	var transition_samples: Array[PackedFloat32Array]

## Returns the scalar values needed to generate mesh data, or null when every on-grid sample is on the same side of the surface (no mesh needed). `corner_samples` holds one value per grid point: index = x * x_stride + y * y_stride + z. `transition_samples` holds one `face_stride * face_stride` slice of those values for each face whose bit is set in `mask` (x,y,z,-x,-y,-z); the other entries are empty.
func _construct_sample_set(mask: int = 0) -> SampleSetReturnType:
	var grid := scalar.sample_grid(offset, lod_step, size + 1)
	var corner_samples := grid.values

	# If every on-grid sample is on the same side of the surface, no mesh is needed
	if grid.lowest >= isosurface or grid.highest <= isosurface:
		return null

	var return_data := SampleSetReturnType.new()
	return_data.corner_samples = corner_samples
	# The samples on a transition face are the same grid points as the corner samples on that face of the chunk, so they are sliced out instead of being sampled again.
	return_data.transition_samples = [[], [], [], [], [], []]
	for face in 6:
		if (mask >> face) & 1 == 1: return_data.transition_samples[face] = _extract_face_samples(corner_samples, face)
	return return_data

## Copies the grid points on one chunk face out of `corner_samples`. Index = u * face_stride + v, where u and v follow the axes of `basis_table[face]` (see the CHUNK FACE LABEL REFERENCE: face order is x,y,z,-x,-y,-z).
func _extract_face_samples(corner_samples: PackedFloat32Array, face: int) -> PackedFloat32Array:
	var face_samples: PackedFloat32Array = []
	face_samples.resize(face_stride * face_stride)
	for u in face_stride:
		for v in face_stride:
			var index: int
			match face:
				0: index = size * x_stride + u * y_stride + v # x+: u = y, v = z
				1: index = v * x_stride + size * y_stride + u # y+: u = z, v = x
				2: index = u * x_stride + v * y_stride + size # z+: u = x, v = y
				3: index = v * y_stride + u # x-: u = z, v = y
				4: index = u * x_stride + v # y-: u = x, v = z
				_: index = v * x_stride + u * y_stride # z-: u = y, v = x
			face_samples[u * face_stride + v] = corner_samples[index]
	return face_samples

## Uses the scalar property and isosurface property to generate mesh vertices and normals. Assigns the generated data to mesh_vertices and mesh_data
func _generate_mesh_data(corner_samples: PackedFloat32Array, transition_mask: int, transition_samples: Array[PackedFloat32Array]) -> ArrayMesh:
	#    c6----------------------c7
	#    / |                     /|
	#   /  |                    / | 
	# c4----------------------c5  |
	#  |   |                   |  |
	#  |   |                   |  |  
	#  |   |                   |  |
	#  |   |                   |  |
	#  |  c2-------------------|-c3
	#  |  /                    | /
	#  | /                     |/ 
	# c0----------------------c1
	# Arrays for storing generated mesh data
	var mesh_vertices: PackedVector3Array = []
	var mesh_normals: PackedVector3Array = []
	var mesh_colors: PackedColorArray = []
	
	# Scratch arrays reused by every cell. A cell has at most 12 vertices.
	var corner_scalar_values: PackedFloat32Array = []
	corner_scalar_values.resize(8)
	var cell_corner_set: PackedVector3Array = []
	cell_corner_set.resize(8)
	var vertex_set: PackedVector3Array = []
	vertex_set.resize(12)
	var vertex_color_set: PackedColorArray = []
	vertex_color_set.resize(12)
	var iso := isosurface

	# Loop through each cube and generate vertices and normals for that cube
	for x in size:
		# Cells that touch a face flagged for transition cells are the only ones whose corners get shifted.
		var x_on_flagged_face := (x == 0 and (transition_mask >> 3) & 1 == 1) or (x == size - 1 and transition_mask & 1 == 1)
		var x_zero := x * x_stride
		var x_one := x_zero + x_stride
		for y in size:
			var y_on_flagged_face := x_on_flagged_face or (y == 0 and (transition_mask >> 4) & 1 == 1) or (y == size - 1 and (transition_mask >> 1) & 1 == 1)
			var y_zero := y * y_stride
			var y_one := y_zero + y_stride
			var index_00 := x_zero + y_zero
			var index_10 := x_one + y_zero
			var index_01 := x_zero + y_one
			var index_11 := x_one + y_one
			for z in size:
				# cube corner scalar values
				var s0 := corner_samples[index_00 + z]
				var s1 := corner_samples[index_10 + z]
				var s2 := corner_samples[index_00 + z + 1]
				var s3 := corner_samples[index_10 + z + 1]
				var s4 := corner_samples[index_01 + z]
				var s5 := corner_samples[index_11 + z]
				var s6 := corner_samples[index_01 + z + 1]
				var s7 := corner_samples[index_11 + z + 1]
				
				# determine regular class index
				var class_index := 0
				if s0 < iso: class_index |= 1
				if s1 < iso: class_index |= 2
				if s2 < iso: class_index |= 4
				if s3 < iso: class_index |= 8
				if s4 < iso: class_index |= 16
				if s5 < iso: class_index |= 32
				if s6 < iso: class_index |= 64
				if s7 < iso: class_index |= 128
				
				# Skip empty cells
				if class_index == 0 or class_index == 255:
					continue
				
				corner_scalar_values[0] = s0
				corner_scalar_values[1] = s1
				corner_scalar_values[2] = s2
				corner_scalar_values[3] = s3
				corner_scalar_values[4] = s4
				corner_scalar_values[5] = s5
				corner_scalar_values[6] = s6
				corner_scalar_values[7] = s7
				
				# cube corner positions in space
				cell_corner_set[0] = Vector3(x, y, z) * lod_step
				cell_corner_set[1] = Vector3((x + 1), y, z) * lod_step
				cell_corner_set[2] = Vector3(x, y, (z + 1)) * lod_step
				cell_corner_set[3] = Vector3((x + 1), y, (z + 1)) * lod_step
				cell_corner_set[4] = Vector3(x, (y + 1), z) * lod_step
				cell_corner_set[5] = Vector3((x + 1), (y + 1), z) * lod_step
				cell_corner_set[6] = Vector3(x, (y + 1), (z + 1)) * lod_step
				cell_corner_set[7] = Vector3((x + 1), (y + 1), (z + 1)) * lod_step
				
				if y_on_flagged_face or (z == 0 and (transition_mask >> 5) & 1 == 1) or (z == size - 1 and (transition_mask >> 2) & 1 == 1):
					for i in 8:
						cell_corner_set[i] = _apply_shift(cell_corner_set[i], transition_mask)

				# use class_index to determine the cell class, construct cell data, and get vertex count
				var cell_class: int = TransvoxelLUT.REG_CELL_CLASS[class_index]
				var vertex_count: int = TransvoxelLUT.REG_CELL_DATA[cell_class][0] >> 4 # high nibble of the geometry counts is the vertex count

				# Construct the vertices (and their colors, once each) used by this cell
				for i in vertex_count:
					var vertex_data: int = TransvoxelLUT.REG_VERTEX_DATA[class_index][i]
					# Use data in the low byte to construct an edge
					var low_byte := vertex_data & 0xFF
					var corner_a := low_byte >> 4
					var corner_b := low_byte & 0x0F

					# determine interpolation ratio
					var interpolation_ratio: float = (iso - corner_scalar_values[corner_a]) / (corner_scalar_values[corner_b] - corner_scalar_values[corner_a])
					var vertex: Vector3 = cell_corner_set[corner_a].lerp(cell_corner_set[corner_b], interpolation_ratio)

					vertex_set[i] = vertex
					vertex_color_set[i] = scalar.get_biome_color(vertex + offset)
				
				## Using the vertex set and cell_data append vertices to the mesh_vertices array to create triangles and calculate flat normals.
				var vertex_indices = TransvoxelLUT.REG_CELL_DATA[cell_class][1]
				var i := 0
				while i < vertex_indices.size():
					var index_a: int = vertex_indices[i]
					var index_b: int = vertex_indices[i + 1]
					var index_c: int = vertex_indices[i + 2]
					var vertex_a := vertex_set[index_a]
					var vertex_b := vertex_set[index_b]
					var vertex_c := vertex_set[index_c]

					# append vertices to vertices array
					mesh_vertices.append(vertex_a)
					mesh_vertices.append(vertex_b)
					mesh_vertices.append(vertex_c)

					# append colors to colors array
					mesh_colors.append(vertex_color_set[index_a])
					mesh_colors.append(vertex_color_set[index_b])
					mesh_colors.append(vertex_color_set[index_c])
					
					# determine normal and append to normals array
					var normal := - (vertex_b - vertex_a).cross(vertex_c - vertex_a).normalized()
					mesh_normals.append(normal)
					mesh_normals.append(normal)
					mesh_normals.append(normal)
					
					i += 3

	# transition faces
	for face in 6:
		if (transition_mask >> face) & 1 == 1:
			_construct_transition_data(transition_samples[face], face, mesh_vertices, mesh_normals, transition_mask, mesh_colors)

	var surface_arrays: Array = []
	surface_arrays.resize(Mesh.ARRAY_MAX)
	surface_arrays[Mesh.ARRAY_VERTEX] = mesh_vertices
	surface_arrays[Mesh.ARRAY_NORMAL] = mesh_normals
	surface_arrays[Mesh.ARRAY_COLOR] = mesh_colors
	
	# create the mesh and assign data to it
	_mesh_creation_mutex.lock()
	var array_mesh := ArrayMesh.new()
	array_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, surface_arrays)
	_mesh_creation_mutex.unlock()
	return array_mesh

## Create the transitional data for cells on the transition face of a chunk
func _construct_transition_data(transition_samples: PackedFloat32Array, face_index: int, mesh_vertices: PackedVector3Array, mesh_normals: PackedVector3Array, transition_mask: int, mesh_colors: PackedColorArray) -> void:
	var values_arr: PackedFloat32Array = []
	values_arr.resize(13)
	var transition_data_vertices: PackedVector3Array = []
	transition_data_vertices.resize(13)
	var actual_vertices: PackedVector3Array = []
	actual_vertices.resize(12)
	var actual_colors: PackedColorArray = []
	actual_colors.resize(12)
	# The shifted position of every fine-grid point on this face is needed by up to 4 neighbouring cells, so each is only calculated once. Index = i * face_stride + j.
	var shifted_points: PackedVector3Array = []
	shifted_points.resize(face_stride * face_stride)
	var shifted_done: PackedByteArray = []
	shifted_done.resize(face_stride * face_stride)
	var iso := isosurface

	@warning_ignore("integer_division")
	for u in size / 2:
		@warning_ignore("integer_division")
		for v in size / 2:
			var u2 := 2 * u
			var v2 := 2 * v
			# 3x3 samples of this cell: index n sits at fine-grid point (2u + n % 3, 2v + n / 3)
			var k0 := u2 * face_stride + v2
			var k1 := k0 + face_stride
			var k2 := k1 + face_stride
			values_arr[0] = transition_samples[k0]
			values_arr[1] = transition_samples[k1]
			values_arr[2] = transition_samples[k2]
			values_arr[3] = transition_samples[k0 + 1]
			values_arr[4] = transition_samples[k1 + 1]
			values_arr[5] = transition_samples[k2 + 1]
			values_arr[6] = transition_samples[k0 + 2]
			values_arr[7] = transition_samples[k1 + 2]
			values_arr[8] = transition_samples[k2 + 2]
			values_arr[9] = values_arr[0]
			values_arr[10] = values_arr[2]
			values_arr[11] = values_arr[6]
			values_arr[12] = values_arr[8]

			# determine regular class index
			var class_index := 0
			if values_arr[0] < iso: class_index |= (1 << 0)
			if values_arr[1] < iso: class_index |= (1 << 1)
			if values_arr[2] < iso: class_index |= (1 << 2)
			if values_arr[5] < iso: class_index |= (1 << 3)
			if values_arr[8] < iso: class_index |= (1 << 4)
			if values_arr[7] < iso: class_index |= (1 << 5)
			if values_arr[6] < iso: class_index |= (1 << 6)
			if values_arr[3] < iso: class_index |= (1 << 7)
			if values_arr[4] < iso: class_index |= (1 << 8)
			
			# Skip empty cells
			if class_index == 0 or class_index == 511:
				continue
			
			# Define real position of transition data
			# Coarse chunk vertices
			for n in 9:
				var i := u2 + n % 3
				var j := v2 + n / 3
				var k := i * face_stride + j
				if shifted_done[k] == 0:
					shifted_points[k] = _apply_shift(_transition_point(i, j, face_index), transition_mask)
					shifted_done[k] = 1
				transition_data_vertices[n] = shifted_points[k]
			# Fine chunk vertices
			transition_data_vertices[9] = _transition_point(u2, v2, face_index)
			transition_data_vertices[10] = _transition_point(u2 + 2, v2, face_index)
			transition_data_vertices[11] = _transition_point(u2, v2 + 2, face_index)
			transition_data_vertices[12] = _transition_point(u2 + 2, v2 + 2, face_index)

			# use class_index to determine the cell class, construct cell data, and get vertex count
			var class_byte: int = TransvoxelLUT.TRANS_CELL_CLASS[class_index]
			var invert_value := (class_byte & 0x80) == 0
			var cell_class := class_byte & 0x7F
			var vertex_count: int = TransvoxelLUT.TRANS_CELL_DATA[cell_class][0] >> 4 # high nibble of the geometry counts is the vertex count
		
			# Construct the vertices (and their colors, once each) used by this cell
			for i in vertex_count:
				var vertex_data: int = TransvoxelLUT.TRANS_VERTEX_DATA[class_index][i]
				# Use data in the low byte to construct an edge
				var low_byte := vertex_data & 0xFF
				var corner_a := low_byte >> 4
				var corner_b := low_byte & 0x0F

				# determine interpolation ratio
				var interpolation_ratio: float = (iso - values_arr[corner_a]) / (values_arr[corner_b] - values_arr[corner_a])
				var vertex: Vector3 = transition_data_vertices[corner_a].lerp(transition_data_vertices[corner_b], interpolation_ratio)

				actual_vertices[i] = vertex
				actual_colors[i] = scalar.get_biome_color(vertex + offset)

			## Using the vertex set and cell_data append vertices to the mesh_vertices array to create triangles and calculate flat normals.
			var vertex_indices = TransvoxelLUT.TRANS_CELL_DATA[cell_class][1]
			var i := 0
			while i < vertex_indices.size():
				var index_a: int = vertex_indices[i]
				var index_b: int = vertex_indices[i + 1]
				var index_c: int = vertex_indices[i + 2]
				var vertex_a := actual_vertices[index_a]
				var vertex_b := actual_vertices[index_b]
				var vertex_c := actual_vertices[index_c]

				# append vertices to vertices array
				if not invert_value:
					mesh_vertices.append(vertex_a)
					mesh_vertices.append(vertex_b)
					mesh_vertices.append(vertex_c)
				else:
					mesh_vertices.append(vertex_a)
					mesh_vertices.append(vertex_c)
					mesh_vertices.append(vertex_b)

				# NOTE: colors keep the a, b, c order even when the winding is inverted (existing behavior).
				mesh_colors.append(actual_colors[index_a])
				mesh_colors.append(actual_colors[index_b])
				mesh_colors.append(actual_colors[index_c])
					
				# determine normal and append to normals array
				var normal: Vector3
				if not invert_value: normal = - (vertex_b - vertex_a).cross(vertex_c - vertex_a).normalized()
				else: normal = - (vertex_c - vertex_a).cross(vertex_b - vertex_a).normalized()
				mesh_normals.append(normal)
				mesh_normals.append(normal)
				mesh_normals.append(normal)
				
				i += 3

## Position of fine-grid point (`i`, `j`) on the face `face_index`, in chunk space. `i` and `j` run along the U and V axes of the face and count `lod_step` units each.
func _transition_point(i: int, j: int, face_index: int) -> Vector3:
	var vector := Vector3()
	var basis_data := basis_table[face_index]
	vector[basis_data[BASIS_TABLE.U_AXIS]] = i * lod_step
	vector[basis_data[BASIS_TABLE.V_AXIS]] = j * lod_step
	vector[basis_data[BASIS_TABLE.N_AXIS]] = basis_data[BASIS_TABLE.PLANE]
	return vector

## Take a surface vector and apply a shift to it to allow a transitional slab to be inserted at LOD resolution borders.
func _apply_shift(pos: Vector3, mask: int) -> Vector3:
	var cell_pos := pos / lod_step
	var shift_vector := Vector3.ZERO
	for axis in 3:
		var positive_flagged = (mask >> axis) & 1
		var negative_flagged = (mask >> (axis + 3)) & 1
		if negative_flagged and cell_pos[axis] < 1:
			shift_vector[axis] = ((1 - cell_pos[axis]) * transition_slab_width)
		elif positive_flagged and cell_pos[axis] > size - 1:
			shift_vector[axis] = ((size - 1 - cell_pos[axis]) * transition_slab_width)
	# Only points in the layer next to a flagged face are shifted. Everything else skips the (expensive) gradient lookup.
	if shift_vector == Vector3.ZERO: return pos
	# Get the normal of the scalar field gradient at pos and use that to slide the shift along the gradient.
	var field_normal: Vector3
	if _normal_cache.has(pos):
		field_normal = _normal_cache[pos]
	else:
		field_normal = _get_field_normal(pos + offset)
		_normal_cache[pos] = field_normal
	shift_vector -= field_normal * field_normal.dot(shift_vector)
	return pos + shift_vector

## Returns a normal of the scalar fields gradient at a specific world_vector
func _get_field_normal(world_vector: Vector3) -> Vector3:
	## TO DO: Replace .sample() with array look ups. We already have corner scalar values. Pass it into this function and use that instead.
	# distance to measure along the scalar to get the gradient
	var step := transition_slab_width
	# get gradient of the scalar field at the given vectors position.
	var scalar_gradient := Vector3(
		scalar.sample(world_vector.x + step, world_vector.y, world_vector.z) - scalar.sample(world_vector.x - step, world_vector.y, world_vector.z),
		scalar.sample(world_vector.x, world_vector.y + step, world_vector.z) - scalar.sample(world_vector.x, world_vector.y - step, world_vector.z),
		scalar.sample(world_vector.x, world_vector.y, world_vector.z + step) - scalar.sample(world_vector.x, world_vector.y, world_vector.z - step),
	)
	# If the gradient is greater than 0, return the gradient normalized. Otherwise return a ZERO vector.
	if scalar_gradient.length_squared() > 0.0: return scalar_gradient.normalized()
	else: return Vector3.ZERO

## Cheap check (no sampling) that the chunk is entirely above or below the surface, so it can never have a mesh. Only the chunk geometry is read, so this is safe to call on the main thread.
func is_provably_empty() -> bool:
	var empty := _determine_if_cell_is_empty()
	if empty: is_empty = true
	return empty

## constructs ArrayMesh data for building a MeshInstance3D for this chunk. mesh_data will be null if no data is/should be generated. Should be done off the main game thread.
func generate_mesh_data(transition_mask: int) -> void:
	built_transition_mask = transition_mask
	_normal_cache.clear()
	if _determine_if_cell_is_empty(): is_empty = true; return
	var start_time := Time.get_ticks_usec()
	var sample_data := _construct_sample_set(transition_mask)
	if sample_data == null: mesh_data = null; is_empty = true; return
	mesh_data = _generate_mesh_data(sample_data.corner_samples, transition_mask, sample_data.transition_samples)
	_normal_cache.clear()
	if Utils.debug == true:
		Utils.call_deferred("emit_signal", "chunk_generated", Time.get_ticks_usec() - start_time)

## Creates a MeshInstance3D from given ArrayMesh, adds it to the tree, and creates collisions for it. Must run on the main thread, and the chunk must already be in the tree.
func build_mesh() -> void:
	for child in get_children():
		if child is MeshInstance3D and child.name == "ChunkMesh":
			child.name = "ChunkMeshOld"
			child.queue_free()
			break

	# create the mesh instance, assign the mesh to it, and add it to the scene
	var mesh_instance := MeshInstance3D.new()
	self.add_child(mesh_instance)
	mesh_instance.name = "ChunkMesh"
	mesh_instance.mesh = mesh_data
	if wireframe_mode: mesh_instance.material_override = WIREFRAME_MATERIAL
	else:
		if _shared_material == null:
			_shared_material = StandardMaterial3D.new()
			_shared_material.vertex_color_use_as_albedo = true
		mesh_instance.material_override = _shared_material
	
	# Only the finest chunks have collision. Physics server calls are not thread-safe with this project's physics settings, so the shape is created here on the main thread.
	if lod_step == 1:
		mesh_instance.create_trimesh_collision()
		var collision_instance: StaticBody3D = mesh_instance.get_child(-1)
		collision_instance.set_collision_layer_value(2, true) # planet collision layer
		collision_instance.set_collision_mask_value(1, true) # player collisions
