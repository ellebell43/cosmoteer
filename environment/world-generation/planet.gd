class_name Planet
extends Node3D

## Reference to the Player node. Used to find determine what LOD level to render chunks at.
@export var player: Player
## Determines the world that is generated
@export var world_seed: int = 1
## ChunkManager.CHUNK_SIZE * 2^size = total_volume. total_volume / 2 - margin = sea radius, where the margin is at least 500 m and grows with the tallest possible terrain (see `WorldNoise.get_limits()`). size = max_octree_depth in the ChunkManager. (ChunkManager.CHUNK_SIZE = 16). The maximum is set by physics, not by chunk count: with a 20 minute day the surface of a size 14 planet moves at 684 m/s and walking on it stays smooth, while at size 15 (1,370 m/s) the player's `move_and_slide` against the moving colliders makes 4 of 10 test locations hitch, and by size 17 (5.5 km/s) it is unplayable. See `tools/bench/check_physics_hitches.gd`.
@export_range(7, 14) var size := 7
# |  size | volume in meters | True  diameter | Surface speed, 20 min day |
# | ----- | =================| ===============| ========================= |
# | 5     | 512              | -              | -                         |
# | 6     | 1,024            | 24             | -                         |
# | 7     | 2,048            | 1,048 <-min    | 2.7 m/s                   |
# | 8     | 4,096            | 3,096          | 8 m/s                     |
# | 9     | 8,192            | 7,196          | 19 m/s                    |
# | 10    | 16,384           | 15,384         | 42 m/s                    |
# | 11    | 32,769           | 31,769         | 83 m/s                    |
# | 12    | 65,536           | 64,536         | 169 m/s                   |
# | 13    | 131,072          | 130,072        | 341 m/s                   |
# | 14    | 262,144          | 261,144        | 684 m/s <-max             |
# | 15    | 524,288          | 523,288        | 1,370 m/s                 |
# | 20    | 16,777,216       | <- Earth is ~12,756,000

## Real-time minutes for one full day/night cycle: the planet makes one turn in this time. The turn rate is the same on every planet, so the surface speed (`angular_speed * radius`) grows with the planet's size. Physics gets into trouble when that gets too high (see `size`).
@export_range(20, 30) var day_length_minutes: int = 25
## The axis that the planet spins on
@export var rotation_axis := Vector3(randf(), randf(), randf()).normalized()
## The shape of the terrain: continents, mountains, hills. Every planet should have its own resource (or share a saved preset). Left empty, the defaults are used.
@export var terrain: TerrainParams

## Reference to the shape of the GravityArea Area3D node. Size is set to diameter * 2 in _ready()
@onready var gravity_shape := $GravityArea/GravityShape
## Reference to the local ChunkManager for this planet.
var chunk_manager: ChunkManager
var world_noise: WorldNoise
## How quickly the planet rotates in radians/sec, derived from `day_length_minutes`
var angular_speed: float:
	get: return TAU / (day_length_minutes * 60.0)
## The size of the total noise volume on each axis. Determined by size: Vector3(20 * 2^size)
var total_volume: Vector3
## The general diameter of the planet mesh: (20 * 2^size) / 2
var diameter: int
## The radius of the sea, where elevation 0 is. Terrain goes up to `world_noise.max_elevation` above and down to `world_noise.min_elevation` below it.
var floor_distance: int
var is_current_world := false:
	set(new_is_current_world):
		is_current_world = new_is_current_world
		if chunk_manager != null:
			chunk_manager.is_current_world = new_is_current_world

func _ready() -> void:
	# determine total volume from self.size and chunk_manager.chunk_size
	var volume_length = ChunkManager.CHUNK_SIZE * pow(2, size)
	total_volume = Vector3(volume_length, volume_length, volume_length)
	if terrain == null: terrain = TerrainParams.new()
	# initialize the world noise. It decides the sea radius, since the volume has to leave room for the tallest terrain.
	world_noise = WorldNoise.new(world_seed, volume_length, terrain)
	floor_distance = int(world_noise.sea_level)
	# gravity extends 1000m beyond the sea radius
	gravity_shape.shape.radius = floor_distance + 1000
	# initialize the chunk_manager
	chunk_manager = ChunkManager.new(player, world_seed, size, world_noise, is_current_world)
	# set the chunk_manager position so that the planet mesh is center at the node origin
	chunk_manager.position = - total_volume / 2
	self.add_child(chunk_manager)
	print("Planet %s diameter: %dkm" % [self.name, volume_length - 1000])
	print("floor_distance: ", floor_distance)

## How many random directions `get_valid_spawn_point()` tries before it gives up. Most of a planet can be ocean, so this is generous.
const MAX_SPAWN_TRIES := 100
## The spawn point has to be at least this far above the sea radius.
const MIN_SPAWN_ELEVATION := 2.0
## Step of the downward search for the surface in `_find_surface_radius()`. Bisection refines the result.
const SPAWN_SEARCH_STEP := 4.0

## Called by Player to find a valid spawn point on this planet that places them 2m above a random point on dry land. Uses `world_noise`, so it works before the chunk_manager has generated anything. Requires the planet's _ready() to have run (Player loads in below all Planet nodes).
func get_valid_spawn_point() -> Vector3:
	for attempt in MAX_SPAWN_TRIES:
		# a random direction, uniform over the sphere
		var direction := Vector3(randfn(0.0, 1.0), randfn(0.0, 1.0), randfn(0.0, 1.0)).normalized()
		var radius := _find_surface_radius(direction)
		if radius - world_noise.sea_level < MIN_SPAWN_ELEVATION: continue
		if Utils.debug: print("spawn location found after %d tries, elevation %.1f" % [attempt + 1, radius - world_noise.sea_level])
		# set spawn to be 2 meters above the point found to ensure player is above the mesh.
		return direction * (radius + 2.0) + global_position
	push_error("No valid spawn point found after %d tries. Spawning player at 0, 0, 0" % MAX_SPAWN_TRIES)
	return Vector3.ZERO

## Radius of the highest surface along `direction` from the center, or -1.0 if there is none. Walks down from above the highest possible terrain to the first rock, then bisects.
func _find_surface_radius(direction: Vector3) -> float:
	var volume_center := total_volume / 2
	var top := world_noise.sea_level + world_noise.max_elevation
	var bottom := world_noise.sea_level + world_noise.min_elevation
	var above := top
	var radius := top
	while radius > bottom:
		radius = maxf(radius - SPAWN_SEARCH_STEP, bottom)
		var pos := volume_center + direction * radius
		if world_noise.sample(pos.x, pos.y, pos.z) < 0.0:
			# rock at `radius`, air at `above`: the surface is between them
			var low := radius
			var high := above
			for i in 24:
				var middle := (low + high) / 2.0
				var middle_pos := volume_center + direction * middle
				if world_noise.sample(middle_pos.x, middle_pos.y, middle_pos.z) < 0.0: low = middle
				else: high = middle
			return low
		above = radius
	return -1.0

func _physics_process(delta: float) -> void:
	# Rotate planet along the rotation_axis by the angular_speed
	self.global_rotate(rotation_axis, angular_speed * delta)

func _on_gravity_area_body_entered(body: Node3D) -> void:
	if body is Player:
		body.current_world = self
		self.is_current_world = true

func _on_gravity_area_body_exited(body: Node3D) -> void:
	if body is Player:
		body.current_world = null
		self.is_current_world = false
