class_name Planet
extends Node3D

## Reference to the Player node. Used to find determine what LOD level to render chunks at.
@export var player: Player
## Determines the world that is generated
@export var world_seed: int = 1
## ChunkManager.CHUNK_SIZE * 2^size = total_volume. total_volume / 2 - 500 = surface radius. size = max_octree_depth in the ChunkManager. (ChunkManager.CHUNK_SIZE = 16). Max terrain height = 2000 above surface radius. The maximum is set by physics, not by chunk count: with a 20 minute day the surface of a size 14 planet moves at 684 m/s and walking on it stays smooth, while at size 15 (1,370 m/s) the player's `move_and_slide` against the moving colliders makes 4 of 10 test locations hitch, and by size 17 (5.5 km/s) it is unplayable. See `tools/bench/check_physics_hitches.gd`.
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
## how far above/below the "floor_distance" the sea level should be
@export var sea_level_modifier: int = 0

## Reference to the shape of the GravityArea Area3D node. Size is set to diameter * 2 in _ready()
@onready var gravity_shape := $GravityArea/GravityShape
## Curve the determines the overall shape of the land (continent shelves, beaches, deep ocean, etc.). Use to interpolate elevation from isovalue. Range should be [-1,1] and domain represents elevation
@export var continent_curve: Curve
## Curve that will apply the amplitude of the WorldNoise.mountain_noise. Domain is equivilent to elevation (value range of continent_curve), range is equivilent to noise amplitude to be applied (should be [0,1])
@export var mountain_curve: Curve
@onready var default_continent_curve: Curve = preload("res://environment/world-generation/slope_curves/default_continent_curve.tres")
@onready var default_mountain_slope: Curve = preload("res://environment/world-generation/slope_curves/default_mountain_curve.tres")

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
var floor_distance: int
var is_current_world := false:
	set(new_is_current_world):
		is_current_world = new_is_current_world
		if chunk_manager != null:
			chunk_manager.is_current_world = new_is_current_world

func _ready() -> void:
	# determine total volume, planet diameter, and gravity radius from self.size and chunk_manager.chunk_size
	var volume_length = ChunkManager.CHUNK_SIZE * pow(2, size)
	total_volume = Vector3(volume_length, volume_length, volume_length)
	floor_distance = (volume_length / 2) - 500
	# gravity extends 1000m beyond the surface of the planet
	gravity_shape.shape.radius = floor_distance + 1000
	if continent_curve == null: continent_curve = default_continent_curve
	if mountain_curve == null: mountain_curve = default_mountain_slope
	# initialize the world noise
	world_noise = WorldNoise.new(
		world_seed, 
		volume_length, 
		floor_distance, 
		sea_level_modifier, 
		continent_curve, 
		mountain_curve
	)
	# initialize the chunk_manager
	chunk_manager = ChunkManager.new(player, world_seed, size, world_noise, is_current_world)
	# set the chunk_manager position so that the planet mesh is center at the node origin
	chunk_manager.position = - total_volume / 2
	self.add_child(chunk_manager)
	print("Planet %s diameter: %dkm" % [self.name, volume_length - 1000])
	print("floor_distance: ", floor_distance)

## The number of tries there has been to find a valid spawn point.
var n_tries = 0
## Called by Player to find a valid spawn point on this planet that places them 1m above a random point on the planet. Will cause an infinite loop if player is loaded in first. Ensure player is loaded in below all Planet nodes
func get_valid_spawn_point() -> Vector3:
	if Utils.debug: print("spawn planet is ", self)
	n_tries += 1
	if Utils.debug: print("searching for spawn ", n_tries)
	# create WorldNoise object with the same seed and size as planet. Cannot use chunk_manager since player may load in before chunk_manager
	# get a random direction vector
	var direction := Vector3(randf(), randf(), randf()).normalized()
	# get a starting position that is at the center of the volume to start sampling + 1/4 of the way out of the volume
	var volume_center := total_volume / 2
	@warning_ignore("integer_division")
	var starting_pos = volume_center + direction * (floor_distance - 50) # start 50 steps below the median surface level
	
	# while loop variables
	var max_steps := 100 # don't sample beyond 50 steps past the median surface level, 100 steps total
	var prev_scalar: float
	var i := 1
	
	# sample scalars from the center of the volume, in random direction, to the edge of the volume and stop when the surface is found and return that value
	while i < max_steps:
		var sample_pos = starting_pos + direction * i
		var sample_scalar = world_noise.sample(sample_pos.x, sample_pos.y, sample_pos.z)
		if i != 1 and prev_scalar < 0 and sample_scalar > 0:
			if Utils.debug: print("spawn location found: ", sample_pos)
			return sample_pos - volume_center + direction * 2 + global_position # set spawn to be 2 meters above the point found to ensure player is above the mesh.
		prev_scalar = sample_scalar
		i += 1
	
	## If a spawn point could not be found after 5 tries, throw error and return Vector.ZERO as spawn point.
	if n_tries == 5:
		push_error("No valid spawn point found after 5 tries. Spawning player at 0, 0, 0")
		return Vector3.ZERO
	
	# if no valid spawn point is found, run the function again (which will choose a different random direction). This should never be run. Hopefully.
	return get_valid_spawn_point()

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
