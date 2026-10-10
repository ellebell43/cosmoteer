extends Control

@export var player: Player

@onready var chunk_info_label := %ChunkInfo
@onready var coords_label := %Coords
@onready var gen_time_label := %GenTime
@onready var update_gen_time_timer := $UpdateGenTime 

# chunk generation variables
var total_generations := 0
var total_generation_time := 0
var average_generation := 0
var max_generation := 0
var chunk_manager: ChunkManager

func _ready() -> void:
	Utils.chunk_generated.connect(_on_chunk_generated)
	
func _process(_delta: float) -> void:
	if player == null or player.current_world == null: return
	set_chunk_info_label()
	set_coords_label()

## Gets the current chunk manager for the player's current world, then get's the key for the chunk the player is currently in. Sets the text of ChunkInfo to show that information on screen.
func set_chunk_info_label() -> void:
	chunk_manager = player.current_world.chunk_manager
	if chunk_manager == null:
		chunk_info_label.text = "chunk manager not found :("
	else:
		var player_chunk_key := chunk_manager.get_player_chunk_key()
		if player_chunk_key == Vector4i.ZERO:
			chunk_info_label.text = "Active Chunks: ???"
		else:
			chunk_info_label.text = "FPS: %d
			Active Chunks: %d" % [Engine.get_frames_per_second(), chunk_manager.active_chunk_set.size()]

func set_coords_label() -> void:
	var player_pos := Vector3i(player.global_position)
	var player_planet_pos := Vector3i(player.current_world.to_local(player.global_position))
	var current_world := player.current_world
	var world_center := current_world.global_position
	var player_height: int = world_center.distance_to(player_pos)
	coords_label.text = "Planet: %s\nDistance to Center: %s\nlocal_pos: %s" % [current_world.name, str(player_height), str(player_planet_pos)]

func _on_chunk_generated(gen_time: int) -> void:
	if gen_time > max_generation: max_generation = gen_time
	total_generation_time += gen_time
	total_generations += 1

func _on_update_gen_time_timeout() -> void:
	if total_generations > 0 and chunk_manager != null:
		#var octree_iterate_percent := float(chunk_manager.process_time)
		gen_time_label.text = "Avg. Chunk Gen: %d" % [total_generation_time / total_generations] + chunk_manager.get_timing_snapshot()
