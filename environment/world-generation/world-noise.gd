class_name WorldNoise
extends RefCounted

## Changes how much the continent/shell noise push/pulls the shape of the world. If the continent noise return 1, then the world is pushed this value of world units
const FLOOR_BIAS := .1
## Changes how much the mountain noise push/pulls the shape of the world. If the mountain noise return 1, then the world is pushed this value of world units
const MOUNTAIN_AMPLITUDE := 10.0
## Changes how much the hill noise push/pulls the shape of the world. If the hill noise return 1, then the world is pushed this value of world units
const HILL_AMPLITUDE := 0.2
## Changes how much the detail noise push/pulls the shape of the world. If the detail noise return 1, then the world is pushed this value of world units
const DETAIL_AMPLITUDE := .05

## Used in Chunk._determine_if_cell_is_empty() to precompute if a cell is empty before sampling.
const BIAS_THRESHOLD := 12.0

## center of the 3D volume
var center: Vector3
## The general radius of the planet
var sea_level: int
## How far to push the water level up or down in the terrain noise.
var sea_level_modifier: int
## Used as a noise mask to determine where land goes based on a given noise sample value ~[-0.5, 0.5].
var continent_curve: Curve
## Used as a noise mask to determine where mountains go based on a given elevation.
var mountain_curve: Curve

# ======== NOISE FUNCTIONS ========
var continent_noise := FastNoiseLite.new()
var mountain_noise := FastNoiseLite.new()
var hill_noise := FastNoiseLite.new()
var detail_noise := FastNoiseLite.new()

# ======== BIOME COLORS ========
## if true, land will be colored with a green -> blue gradient based directly on elevation values [WIP]
const USE_GRADIENT := false
var dark_blue := Color("#30618c")
var blue := Color("#5696cf")
var sand := Color("#f7f0b2")
var green := Color("#7ae451")
var gray := Color("#9c9c9c")

func _init(_seed: int, size: float, _sea_level, _sea_level_modifier: int, _continent_curve: Curve, _mountain_curve: Curve):
	# ======= CONTINENT NOISE PROPERTIES =======
	continent_noise.seed = _seed
	continent_noise.noise_type = FastNoiseLite.TYPE_PERLIN
	continent_noise.frequency = 0.005
	continent_noise.fractal_octaves = 4
	continent_noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	
	# ======= MOUNTAIN NOISE PROPERTIES =======
	mountain_noise.seed = _seed
	mountain_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	mountain_noise.frequency = 0.03
	mountain_noise.fractal_octaves = 5
	mountain_noise.fractal_type = FastNoiseLite.FRACTAL_RIDGED
	mountain_noise.domain_warp_enabled = false
	mountain_noise.domain_warp_frequency = 0.003
	mountain_noise.domain_warp_amplitude = 50.0

	# ======= HILL NOISE PROPERTIES =======
	hill_noise.seed = _seed
	hill_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	hill_noise.frequency = 0.1
	hill_noise.fractal_octaves = 5

	# ======= DETAIL NOISE PROPERTIES =======
	detail_noise.seed = _seed
	detail_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	detail_noise.frequency = 0.2
	detail_noise.fractal_octaves = 3
	detail_noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	
	center = Vector3(size / 2, size / 2, size / 2)
	sea_level = _sea_level
	sea_level_modifier = _sea_level_modifier
	continent_curve = _continent_curve
	mountain_curve = _mountain_curve

## Get a noise sample biased towards a world shape at a specific Vec3 of the noise volume
func sample(x: float, y: float, z: float) -> float:
	var pos := Vector3(x, y, z)
	var shell_bias := (pos.distance_to(center) - sea_level) * FLOOR_BIAS
	var elevation = get_elevation_at_point(Vector3(x, y, z))

	return shell_bias - elevation * FLOOR_BIAS

func get_bias_from_distance(distance: float) -> float:
	return (distance - sea_level) * FLOOR_BIAS

func get_elevation_at_point(_pos: Vector3) -> float:
	var continent_sample = continent_noise.get_noise_3dv(_pos)
	var mountain_sample = mountain_noise.get_noise_3dv(_pos)
	
	var base_elevation = continent_curve.sample(continent_sample)
	var mountain_mask = mountain_curve.sample(base_elevation)
	
	var mountain_modifier = mountain_sample * mountain_mask * MOUNTAIN_AMPLITUDE
	var hill_modifier = hill_noise.get_noise_3dv(_pos) * HILL_AMPLITUDE
	var detail_modifier = detail_noise.get_noise_3dv(_pos) * DETAIL_AMPLITUDE
	
	return base_elevation + mountain_modifier + hill_modifier + detail_modifier

func get_biome_color(_pos: Vector3) -> Color:
	var elevation: float = get_elevation_at_point(_pos)
	# NOTE: USE_GRADIENT is borked. I only put 5 seconds of thought into this. I'll think about it later and fix.
	if USE_GRADIENT:
		var _green := elevation + 60.0 / 120.0
		var _blue := 1.0 - _green
		return Color(0, _green, _blue, 1)
	if elevation < -20: return dark_blue
	elif elevation < 0: return blue
	elif elevation < .5: return sand
	elif elevation < 15: return green
	else: return gray
