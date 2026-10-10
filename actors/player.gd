class_name Player
extends CharacterBody3D

@export var spawn_world: Planet

const SPEED := 5.0
const JUMP_VELOCITY := 5.0
const ROTATION_SPEED := 3
const LOOK_SENSITIVITY := 0.005
const MAX_VELOCITY := Vector3(30, 30, 30)

var fly_mode := true
var current_world: Planet = null:
	set(new_world):
		current_world = new_world
		if new_world != null:
			new_world.is_current_world = true
var allow_inputs := true

@onready var camera: Camera3D = $Camera3D

func _ready() -> void:
	
	if spawn_world:
		global_position = spawn_world.get_valid_spawn_point()
		#global_position = Vector3(spawn_world.world_radius, spawn_world.world_radius, spawn_world.world_radius)

func _physics_process(delta):
	# if the player is at a world, calculate a tangential velocity (applied later) to lock the player to the planets rotation. Also rotate the player according to the planet's spin
	var planet_rotation_v: Vector3
	if current_world:
		var angular_velocity_vector := current_world.rotation_axis * current_world.rotation_speed
		var displacement_vector := self.global_position - current_world.global_position
		planet_rotation_v = angular_velocity_vector.cross(displacement_vector)
		self.global_rotate(current_world.rotation_axis, current_world.rotation_speed * delta)
	
	# orient player with planets surface
	var target_basis := get_planet_aligned_basis()
	up_direction = -get_gravity().normalized()
	global_transform.basis = global_transform.basis.slerp(target_basis, delta * ROTATION_SPEED).orthonormalized()
	
	# preserve vertical velocity from previous velocity to allow it to decay
	var vertical_velocity := up_direction * velocity.dot(up_direction)
	
	# get movement direction based on input
	var direction := Input.get_vector("move_forward", "move_back", "move_left", "move_right").normalized()
	# If we have an input direction, assign velocity relative to the players rotation. This handles relative horizontal movement. Verticle movement is handled separately to allow decay
	if direction: 
		var x_v := target_basis.x * direction.y
		var z_v := target_basis.z * direction.x
		if Input.is_action_pressed("sprint"): 
			z_v *= 2
		var v_sum = z_v + x_v
		if Input.is_action_pressed("sprint"): 
			velocity = (v_sum * SPEED * 2)
		else:
			velocity = (v_sum * SPEED)
		if planet_rotation_v: velocity += planet_rotation_v # apply tangential velocity if it was calculated
	else: 
		if planet_rotation_v: velocity = planet_rotation_v # apply tangential velocity if it was calculated
		else: velocity = Vector3(0, 0, 0)
	
	# Add back in the preserved vertical velocity unless flying
	if not fly_mode: velocity += vertical_velocity
	
	# only apply gravity if we're not on the floor and we're not in flight mode
	if not is_on_floor() and not fly_mode:
		velocity += get_gravity() * delta
	
	# handle jumping/ascending flight/descending flight
	if Input.is_action_just_pressed("jump") and not fly_mode:
		var jump_velocity := up_direction * JUMP_VELOCITY
		velocity += jump_velocity
	elif Input.is_action_pressed("jump") and fly_mode:
		velocity += up_direction * JUMP_VELOCITY
	elif Input.is_action_pressed("crouch") and fly_mode:
		velocity -= up_direction * JUMP_VELOCITY
	
	move_and_slide()

var current_rotation: float = 0 # for camera x-axis rotation
var ROTATION_LIMIT = deg_to_rad(90) # for camera x-axis rotation
func _input(event):
	if not allow_inputs: return
	# if F is pressed, toggle flight_mode
	if event.is_action_pressed("toggle_flight"):
		fly_mode = not fly_mode
	# if the game is clicked on, capture the mouse
	if event is InputEventMouseButton:
		Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
	# if "esc" is pressed, release the mouse
	elif event.is_action_pressed(("ui_cancel")):
		Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	# If the mouse is captured, accept mouse input for looking around
	if Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED:
		if event is InputEventMouseMotion:
			# store rotation for camera x-rotation and manually clamp it at ROTATION_LIMIT
			current_rotation += -event.relative.y * LOOK_SENSITIVITY
			if current_rotation > ROTATION_LIMIT: current_rotation = ROTATION_LIMIT; return
			if current_rotation < -ROTATION_LIMIT: current_rotation = - ROTATION_LIMIT; return
			camera.rotate_x(-event.relative.y * LOOK_SENSITIVITY)
			# rotate the player on the up_direction axis
			self.global_rotate(self.up_direction, -event.relative.x * LOOK_SENSITIVITY)
	

func get_planet_aligned_basis() -> Basis:	
	var new_y := -get_gravity().normalized()
	var new_x := new_y.cross(global_transform.basis.z).normalized()
	var new_z := new_x.cross(new_y).normalized()
	return Basis(new_x, new_y, new_z)
