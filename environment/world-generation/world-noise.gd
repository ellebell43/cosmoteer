class_name WorldNoise
extends RefCounted

## The planet's scalar field. `sample()` is positive in air and negative in rock, and the surface is where it crosses 0, at `sea_level + elevation`. The shape is built from layers of 3D noise on top of a sphere:
##
## 1. continents: very low frequency noise, scaled with the planet, mapped to ocean floor and lowland
## 2. mountains: ridged noise placed in ranges by a separate low frequency noise, with a fixed feature size in meters. Ranges do not depend on the continents (a mask that follows the coast is steep on small continents and folds the surface), so some of them stand in the sea as islands
## 3. hills and detail: smaller noise that is always sampled at the true 3D point
## 4. overhang (optional): a bounded 3D term near the mountain surface that carves ledges and arches
##
## Continents and mountains are sampled at a point that is pulled radially towards the sea-level sphere by `TerrainParams.radial_coherence`. Without that, a tall feature is sampled at a different place on its flank than at its foot and the surface leans and folds over itself. Every layer is clamped to its declared range, so `min_elevation` and `max_elevation` are real bounds. The tunables are in `TerrainParams`.

## Scale of the field: the value of `sample()` is `(distance from the surface in meters) * FLOOR_BIAS`.
const FLOOR_BIAS := .1

## Tallest relief (peak height, ocean depth) as a fraction of the planet radius.
const RELIEF_RADIUS_FRACTION := 0.12
## Share of `peak_height` that the lowland under the mountains gets. The mountains get the rest.
const LAND_BASE_SHARE := 0.2
## The radial slope that the mountains may add, as a fraction of 1 (1 is where the surface starts to fold). Divided by how much of the radial gradient the coherence leaves, it caps the mountain height at that fraction of the ridge spacing.
const MOUNTAIN_RADIAL_SLOPE := 0.043
## Steepest slope (99.9th percentile, times the ridge spacing, per meter of mountain height) of the mountain shape at the default `erosion` and `ridge_sharpness`. `MOUNTAIN_RADIAL_SLOPE` was tuned for it; other settings scale the allowed height by `_mountain_gradient()` relative to it.
const MOUNTAIN_REFERENCE_GRADIENT := 11.5
## Highest the mountains may get relative to their ridge spacing, however high the coherence.
const MOUNTAIN_MAX_HEIGHT_RATIO := 0.3
## Largest slope (per meter) of the continent noise mapped to 0..1 by rank, times the continent wavelength. Measured on the real noise: 13 at most.
const CONTINENT_RANK_SLOPE := 12.0
## Radial slope the continent layer may add. Its radial slope is its tangential slope times (1 - radial_coherence).
const CONTINENT_RADIAL_SLOPE := 0.15
## Tangential slope the continent layer may have however high the coherence (a coast with this slope is a cliff of 45 degrees).
const CONTINENT_TANGENTIAL_SLOPE := 1.0
## How soft the edge of a mountain range or a plain is, as a fraction of the smaller of the share it covers and the rest. A sharp edge multiplies the mountain height by a quickly changing mask, which is steep and folds the surface.
const MASK_EDGE_SHARE := 0.25
## The slope allowances of the coherent layers shrink towards this share when `radial_coherence` is low, because their share of the radial slope is then larger and the layers add up more often (low coherence is where the rare folds showed up in the sweeps).
const LOW_COHERENCE_ALLOWANCE := 0.4
## Surface flatness (the up component of the surface normal, 1 = level ground, 0.5 = 60 degrees) at which the land is fully grass, and at which it is fully stone. Between the two the colors blend.
const FLATNESS_GRASS := 0.86
const FLATNESS_STONE := 0.66
## Height above the sea over which the water color fades into the land color, so the shore has no hard line.
const SHORE_BLEND := 1.0
## Stone starts at this share of the mountains' height above the sea and covers everything from `STONE_FULL_SHARE`.
const STONE_START_SHARE := 0.4
const STONE_FULL_SHARE := 0.7
## Highest the hills may get relative to their spacing (about 17 degrees at the steepest). Hills are full 3D, so unlike the mountains the coherence does not help them: at 0.1 their radial slope alone reached 0.6 for 1% of the points.
const HILL_MAX_HEIGHT_RATIO := 0.05
## Wavelength of the small rocky roughness.
const DETAIL_WAVELENGTH := 12.0
## Highest the detail may get relative to its wavelength.
const DETAIL_MAX_HEIGHT_RATIO := 0.05
## Ridge warp displacement for `mountain_warp` = 1, relative to the ridge spacing. With the warp fractal off it does not steepen the slopes (measured to 1), so `get_limits()` does not lower the mountains for it.
const MOUNTAIN_WARP_AMPLITUDE := 0.3
## The overhang term is at most this fraction of the mountain height.
const OVERHANG_MAX_SHARE := 0.6
## `TerrainParams.overhang` times this is the height of the overhang term relative to its wavelength. The surface starts to fold when the height is about 0.3 of the wavelength, so overhangs appear from `overhang` 0.15. The range of `overhang` stops at 0.3 because detached rock starts beyond it.
const OVERHANG_HEIGHT_RATIO := 2.0
## Wavelength of the overhang term relative to the height of the mountains, and its lower limit.
const OVERHANG_WAVELENGTH_RATIO := 0.6
const OVERHANG_MIN_WAVELENGTH := 30.0
## Added to the computed elevation bounds.
const ELEVATION_BOUND_MARGIN := 2.0
## Extra clearance between the highest possible terrain and the edge of the noise volume. The sea level offset can move the terrain by up to 100 m.
const VOLUME_EDGE_CLEARANCE := 200.0
## The volume always keeps at least this much room around the planet.
const MINIMUM_MARGIN := 500.0
## Noise samples used to measure each layer's value distribution at start-up.
const CALIBRATION_SAMPLES := 4096
## Entries of the tables that turn a noise value into a height or mask.
const TABLE_BINS := 1024

## center of the 3D volume
var center: Vector3
## Radius of the sea, in the same units as the volume. The zero of every elevation.
var sea_level: float
## Highest elevation `get_elevation_at_point()` can return. A bound, not a tuning knob.
var max_elevation: float
## Lowest elevation `get_elevation_at_point()` can return (negative). A bound, not a tuning knob.
var min_elevation: float
## Radius of the ball inside the planet that is always rock: no surface point is closer to the center.
var solid_radius: float:
	get: return sea_level + min_elevation
## Used in Chunk._determine_if_cell_is_empty() to know that no sample can cross the surface. A cell whose closest point is further than this (in `get_bias_from_distance()` units) from the sea sphere is all air.
var air_threshold: float:
	get: return max_elevation * FLOOR_BIAS
## Same for rock: a cell whose farthest point is closer than this (negative, `get_bias_from_distance()` units) is all rock.
var rock_threshold: float:
	get: return min_elevation * FLOOR_BIAS

# ======== EFFECTIVE VALUES ========
# The `TerrainParams` values after they were limited to what the planet and the feature size can carry.
var effective_peak_height: float
var effective_ocean_depth: float
var effective_land_base: float
var effective_mountain_height: float
var effective_hill_height: float
var effective_detail_height: float
var effective_overhang: float

# ======== NOISE FUNCTIONS ========
var continent_noise := FastNoiseLite.new()
var placement_noise := FastNoiseLite.new()
var mountain_noise := FastNoiseLite.new()
var ruggedness_noise := FastNoiseLite.new()
var hill_noise := FastNoiseLite.new()
var detail_noise := FastNoiseLite.new()
var overhang_noise := FastNoiseLite.new()

# ======== CALIBRATION ========
# Each noise value is turned into a height or mask through a table, measured at start-up from the layer's value distribution on the sea sphere. That gives exact control of how much of the surface is ocean, mountains or plains whatever the noise settings are, and costs one lookup instead of several calls. A table has `TABLE_BINS` + 1 entries covering [low, low + (TABLE_BINS - 1) / scale], read with linear interpolation.
# continent noise -> elevation of the ocean floor / lowland
var _base_table: PackedFloat32Array
var _base_low: float
var _base_scale: float
# placement noise -> 0..1 mountain mask
var _mask_table: PackedFloat32Array
var _mask_low: float
var _mask_scale: float
# ruggedness noise -> 0..1 share of the hills that is kept
var _rugged_table: PackedFloat32Array
var _rugged_low: float
var _rugged_scale: float
# mountain noise -> 0..1 ridge height (linear in the noise, then sharpened)
var _ridge_table: PackedFloat32Array
var _ridge_low: float
var _ridge_scale: float
# hill, detail and overhang noise -> [-1, 1]
var _hill_scale: float
var _detail_scale: float
var _overhang_scale: float

# ======== SETTINGS COPIED FROM TerrainParams ========
var _ocean_coverage: float
var _coast_exponent: float
var _land_base: float
var _mountain_coverage: float
var _ridge_sharpness: float
var _terracing: float
var _terrace_step: float
var _plains_fraction: float
var _coherence: float

# ======== TERRAIN COLORS ========
# Placeholders until biomes exist. See `get_biome_color()`.
var dark_blue := Color("#30618c")
var blue := Color("#5696cf")
var sand := Color("#f7f0b2")
var green := Color("#7ae451")
var stone := Color("#9c9c9c")
# Heights in meters above the sea radius, derived from the terrain in `_init()`.
var _deep_water: float
var _sand_height: float
var _stone_start: float
var _stone_end: float

## Radius of the sea and the largest elevation for a planet with the noise volume `volume` and `params`, without building the noise. `WorldNoise` is built from the same numbers.
static func get_limits(volume: float, params: TerrainParams) -> Dictionary:
	var half := volume / 2.0
	var reference_radius := half - MINIMUM_MARGIN
	var cap := RELIEF_RADIUS_FRACTION * reference_radius
	var peak := minf(params.peak_height, cap)
	# The continent profile spans only a share of the noise (the ocean or the land) and is steeper for a sharp coast; short continent wavelengths (small planets) steepen it too.
	var continent_wavelength := TAU * reference_radius / params.continent_count
	var slope_room := minf(CONTINENT_TANGENTIAL_SLOPE, CONTINENT_RADIAL_SLOPE / maxf(1.0 - params.radial_coherence, 0.001)) * _coherence_allowance(params.radial_coherence)
	var coast := 1.0 + 3.0 * params.coast_sharpness
	var ocean := minf(params.ocean_depth, minf(cap, slope_room * continent_wavelength * params.ocean_coverage / (coast * CONTINENT_RANK_SLOPE)))
	var land_base := minf(LAND_BASE_SHARE * peak, slope_room * continent_wavelength * (1.0 - params.ocean_coverage) / (coast * CONTINENT_RANK_SLOPE))
	var mountain := _mountain_height_limit(peak, params)
	var hill := minf(params.hill_height, HILL_MAX_HEIGHT_RATIO * params.hill_scale)
	var detail := minf(params.detail_height, DETAIL_MAX_HEIGHT_RATIO * DETAIL_WAVELENGTH)
	var overhang := minf(params.overhang * OVERHANG_HEIGHT_RATIO * _overhang_wavelength(mountain), OVERHANG_MAX_SHARE * mountain)
	var max_e := land_base + mountain + hill + detail + overhang + ELEVATION_BOUND_MARGIN
	var min_e := -(ocean + hill + detail + overhang) - ELEVATION_BOUND_MARGIN
	var margin := maxf(MINIMUM_MARGIN, max_e + VOLUME_EDGE_CLEARANCE)
	return {
		"peak": peak, "ocean": ocean, "land_base": land_base, "mountain": mountain, "hill": hill, "detail": detail, "overhang": overhang,
		"max_elevation": max_e, "min_elevation": min_e, "sea_level": half - margin + params.sea_level_offset,
	}

## How many times steeper the risers of the terraces are than the mountain they are cut into. See `_terrace()`.
## Wavelength of the ledges, which follows the height of the mountains they are carved into.
static func _overhang_wavelength(mountain_height: float) -> float:
	return maxf(OVERHANG_MIN_WAVELENGTH, OVERHANG_WAVELENGTH_RATIO * mountain_height)

static func _terrace_steepening(terracing: float) -> float:
	return (1.0 - terracing) + terracing * 0.75 / (0.5 - 0.3 * terracing)

## Steepest slope of the mountain shape (see `MOUNTAIN_REFERENCE_GRADIENT`), measured for erosion 0, 0.4, 1 and sharpness 1, 1.8, 3: sharper ridges and less erosion are steeper.
static func _mountain_gradient(erosion: float, ridge_sharpness: float) -> float:
	return (6.6 + 2.7 * (1.0 - erosion)) * (0.5 + 0.5 * ridge_sharpness)

static func _coherence_allowance(coherence: float) -> float:
	return lerpf(LOW_COHERENCE_ALLOWANCE, 1.0, clampf(coherence / 0.75, 0.0, 1.0))

static func _mountain_height_limit(peak: float, params: TerrainParams) -> float:
	var slope_limit := params.mountain_scale * minf(MOUNTAIN_MAX_HEIGHT_RATIO, MOUNTAIN_RADIAL_SLOPE / maxf(1.0 - params.radial_coherence, 0.01)) * _coherence_allowance(params.radial_coherence)
	var steepening := _mountain_gradient(params.erosion, params.ridge_sharpness) / MOUNTAIN_REFERENCE_GRADIENT * _terrace_steepening(params.terracing)
	return minf((1.0 - LAND_BASE_SHARE) * peak, slope_limit / steepening)

func _init(_seed: int, volume: float, params: TerrainParams = null):
	if params == null: params = TerrainParams.new()
	var limits := get_limits(volume, params)
	center = Vector3(volume / 2, volume / 2, volume / 2)
	sea_level = limits.sea_level
	max_elevation = limits.max_elevation
	min_elevation = limits.min_elevation
	effective_peak_height = limits.peak
	effective_ocean_depth = limits.ocean
	effective_land_base = limits.land_base
	effective_mountain_height = limits.mountain
	effective_hill_height = limits.hill
	effective_detail_height = limits.detail
	effective_overhang = limits.overhang

	_ocean_coverage = params.ocean_coverage
	_coast_exponent = 1.0 + 3.0 * params.coast_sharpness
	_land_base = effective_land_base
	_mountain_coverage = params.mountain_coverage
	_ridge_sharpness = params.ridge_sharpness
	_terracing = params.terracing
	_terrace_step = maxf(effective_mountain_height / 6.0, 8.0)
	_plains_fraction = params.plains_fraction
	_coherence = params.radial_coherence

	# ======= CONTINENT NOISE =======
	var continent_wavelength := TAU * sea_level / params.continent_count
	_setup_noise(continent_noise, _seed, 0, FastNoiseLite.TYPE_SIMPLEX_SMOOTH, continent_wavelength, 4, FastNoiseLite.FRACTAL_FBM)

	# ======= MOUNTAIN NOISE =======
	_setup_noise(placement_noise, _seed, 1, FastNoiseLite.TYPE_SIMPLEX_SMOOTH, 4.0 * params.mountain_scale, 2, FastNoiseLite.FRACTAL_FBM)
	_setup_noise(mountain_noise, _seed, 2, FastNoiseLite.TYPE_SIMPLEX, params.mountain_scale, 5, FastNoiseLite.FRACTAL_RIDGED)
	mountain_noise.fractal_gain = lerpf(0.55, 0.25, params.erosion)
	mountain_noise.fractal_weighted_strength = lerpf(0.9, 0.1, params.erosion)
	if params.mountain_warp > 0.0:
		mountain_noise.domain_warp_enabled = true
		mountain_noise.domain_warp_type = FastNoiseLite.DOMAIN_WARP_SIMPLEX
		# Godot defaults to a progressive warp fractal of 5 octaves with lacunarity 6, which adds jitter of a couple of meters to the surface.
		mountain_noise.domain_warp_fractal_type = FastNoiseLite.DOMAIN_WARP_FRACTAL_NONE
		mountain_noise.domain_warp_amplitude = params.mountain_warp * MOUNTAIN_WARP_AMPLITUDE * params.mountain_scale
		mountain_noise.domain_warp_frequency = 1.0 / (3.0 * params.mountain_scale)

	# ======= HILL AND DETAIL NOISE =======
	_setup_noise(ruggedness_noise, _seed, 3, FastNoiseLite.TYPE_SIMPLEX_SMOOTH, maxf(4.0 * params.hill_scale, 400.0), 2, FastNoiseLite.FRACTAL_FBM)
	_setup_noise(hill_noise, _seed, 4, FastNoiseLite.TYPE_SIMPLEX_SMOOTH, params.hill_scale, 3, FastNoiseLite.FRACTAL_FBM)
	_setup_noise(detail_noise, _seed, 5, FastNoiseLite.TYPE_SIMPLEX_SMOOTH, DETAIL_WAVELENGTH, 2, FastNoiseLite.FRACTAL_FBM)

	# ======= OVERHANG NOISE =======
	_setup_noise(overhang_noise, _seed, 6, FastNoiseLite.TYPE_SIMPLEX_SMOOTH, _overhang_wavelength(effective_mountain_height), 1, FastNoiseLite.FRACTAL_NONE)

	_deep_water = maxf(0.6 * effective_ocean_depth, 2.0)
	_sand_height = clampf(0.012 * max_elevation, 1.5, 5.0)
	var mountain_top := effective_land_base + effective_mountain_height
	_stone_start = STONE_START_SHARE * mountain_top
	_stone_end = maxf(STONE_FULL_SHARE * mountain_top, _stone_start + 1.0)

	_calibrate(_seed)

func _setup_noise(noise: FastNoiseLite, _seed: int, layer: int, type: FastNoiseLite.NoiseType, wavelength: float, octaves: int, fractal: FastNoiseLite.FractalType) -> void:
	# every layer gets its own seed, or their phases would line up
	noise.seed = (_seed * 31 + layer * 1013904223) & 0x7fffffff
	noise.noise_type = type
	noise.frequency = 1.0 / wavelength
	noise.fractal_type = fractal
	noise.fractal_octaves = octaves

## Measures the value distribution of each layer on the sea sphere, and builds the tables.
func _calibrate(_seed: int) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = _seed
	var points := PackedVector3Array()
	for i in CALIBRATION_SAMPLES:
		points.append(center + Vector3(rng.randfn(), rng.randfn(), rng.randfn()).normalized() * sea_level)

	var continent := _sorted_values(continent_noise, points)
	_base_low = continent[0]
	_base_scale = (TABLE_BINS - 1) / maxf(continent[continent.size() - 1] - _base_low, 0.000001)
	_base_table = _make_table(_base_low, _base_scale, func(value: float) -> float: return _base_elevation(_rank(continent, value)))

	var placement := _sorted_values(placement_noise, points)
	_mask_low = placement[0]
	_mask_scale = (TABLE_BINS - 1) / maxf(placement[placement.size() - 1] - _mask_low, 0.000001)
	_mask_table = _make_table(_mask_low, _mask_scale, func(value: float) -> float: return _top_share(_rank(placement, value), _mountain_coverage))

	var ruggedness := _sorted_values(ruggedness_noise, points)
	_rugged_low = ruggedness[0]
	_rugged_scale = (TABLE_BINS - 1) / maxf(ruggedness[ruggedness.size() - 1] - _rugged_low, 0.000001)
	_rugged_table = _make_table(_rugged_low, _rugged_scale, func(value: float) -> float: return _top_share(_rank(ruggedness, value), 1.0 - _plains_fraction))

	# The ridged noise keeps its shape (linear), from its 2nd to its 99.8th percentile.
	var mountain := _sorted_values(mountain_noise, points)
	_ridge_low = mountain[int(mountain.size() * 0.02)]
	var ridge_range := maxf(mountain[int(mountain.size() * 0.998)] - _ridge_low, 0.000001)
	_ridge_scale = (TABLE_BINS - 1) / ridge_range
	_ridge_table = _make_table(_ridge_low, _ridge_scale, func(value: float) -> float: return pow(clampf((value - _ridge_low) / ridge_range, 0.0, 1.0), _ridge_sharpness))

	_hill_scale = _symmetric_scale(_sorted_values(hill_noise, points))
	_detail_scale = _symmetric_scale(_sorted_values(detail_noise, points))
	_overhang_scale = _symmetric_scale(_sorted_values(overhang_noise, points))

## `fn` sampled at the `TABLE_BINS` noise values the table covers, plus a copy of the last entry so that interpolation can always read one past the index.
func _make_table(low: float, scale: float, fn: Callable) -> PackedFloat32Array:
	var table := PackedFloat32Array()
	table.resize(TABLE_BINS + 1)
	for i in TABLE_BINS:
		table[i] = fn.call(low + i / scale)
	table[TABLE_BINS] = table[TABLE_BINS - 1]
	return table

## Share (0..1) of `sorted` that lies below `value`.
func _rank(sorted: PackedFloat32Array, value: float) -> float:
	return float(sorted.bsearch(value)) / sorted.size()

func _sorted_values(noise: FastNoiseLite, points: PackedVector3Array) -> PackedFloat32Array:
	var values := PackedFloat32Array()
	values.resize(points.size())
	for i in points.size():
		values[i] = noise.get_noise_3dv(points[i])
	values.sort()
	return values

## Factor that maps the 1st..99th percentile of `sorted` to [-1, 1].
func _symmetric_scale(sorted: PackedFloat32Array) -> float:
	var extent := maxf(absf(sorted[int(sorted.size() * 0.01)]), absf(sorted[int(sorted.size() * 0.99)]))
	return 1.0 / maxf(extent, 0.000001)

## Ocean floor and lowland as a function of the share of the planet that lies below the continent noise.
func _base_elevation(rank: float) -> float:
	if rank < _ocean_coverage:
		var x := 1.0 - rank / _ocean_coverage
		return -effective_ocean_depth * (1.0 - pow(1.0 - x, _coast_exponent))
	var y := (rank - _ocean_coverage) / (1.0 - _ocean_coverage)
	return _land_base * (1.0 - pow(1.0 - y, _coast_exponent))

## 1 for the top `share` of `rank`, 0 for the rest, with a soft edge.
func _top_share(rank: float, share: float) -> float:
	if share <= 0.0: return 0.0
	if share >= 1.0: return 1.0
	var edge := 1.0 - share
	var width := MASK_EDGE_SHARE * minf(share, edge) + 0.03
	return smoothstep(edge - width, edge + width, rank)

func _terrace(height: float) -> float:
	if _terracing <= 0.0: return height
	var t := height / _terrace_step
	var floored := floorf(t)
	var width := 0.5 - 0.3 * _terracing
	var stepped := (floored + smoothstep(0.5 - width, 0.5 + width, t - floored)) * _terrace_step
	return lerpf(height, stepped, _terracing)

## Computes `count` points in a row along z, starting at (x, y, z0) with spacing `step`, and writes them to `out` from index `start`: the value of `sample()` if `as_field`, otherwise the elevation (meters above the sea radius) of the surface layers. Returns the lowest and the highest value written. This is the one implementation of the terrain; it does a whole row per call and keeps everything in locals, because the per-point cost of GDScript calls and member reads is what limits generation speed, not the noise.
func _compute_row(x: float, y: float, z0: float, step: float, count: int, out: PackedFloat32Array, start: int, as_field: bool) -> Vector2:
	var continent := continent_noise
	var placement := placement_noise
	var mountain := mountain_noise
	var ruggedness := ruggedness_noise
	var hill := hill_noise
	var detail := detail_noise
	var overhang := overhang_noise
	var base_table := _base_table
	var mask_table := _mask_table
	var rugged_table := _rugged_table
	var ridge_table := _ridge_table
	var middle := center
	var sea := sea_level
	var coherence := _coherence
	var radial_keep := 1.0 - coherence
	var last_bin := float(TABLE_BINS - 1)
	var mountain_height := effective_mountain_height if _mountain_coverage > 0.0 else 0.0
	var hill_height := effective_hill_height
	var detail_height := effective_detail_height
	var overhang_height := effective_overhang
	var plains := _plains_fraction > 0.0
	var terraced := _terracing > 0.0
	var lowest := INF
	var highest := -INF
	for i in count:
		var pos := Vector3(x, y, z0 + i * step)
		var offset := pos - middle
		var dist := offset.length()
		# The large features are sampled on a point pulled towards the sea sphere along the radius, see the class comment.
		var macro := pos
		if coherence > 0.0 and dist > 1.0:
			macro = middle + offset * (radial_keep + coherence * sea / dist)

		# ocean floor and lowland
		var t := clampf((continent.get_noise_3dv(macro) - _base_low) * _base_scale, 0.0, last_bin)
		var k := int(t)
		var entry := base_table[k]
		var elevation := entry + (base_table[k + 1] - entry) * (t - k)

		# mountains: everything below is exactly 0 where its mask is 0, so the noise behind it is only sampled where it can matter
		var ridge := 0.0
		if mountain_height > 0.0:
			t = clampf((placement.get_noise_3dv(macro) - _mask_low) * _mask_scale, 0.0, last_bin)
			k = int(t)
			entry = mask_table[k]
			var mask := entry + (mask_table[k + 1] - entry) * (t - k)
			if mask > 0.0:
				t = clampf((mountain.get_noise_3dv(macro) - _ridge_low) * _ridge_scale, 0.0, last_bin)
				k = int(t)
				entry = ridge_table[k]
				ridge = mask * (entry + (ridge_table[k + 1] - entry) * (t - k))
				if terraced: elevation += _terrace(mountain_height * ridge)
				else: elevation += mountain_height * ridge

		# hills, only where the terrain is not flattened into plains
		if hill_height > 0.0:
			var rugged := 1.0
			if plains:
				t = clampf((ruggedness.get_noise_3dv(macro) - _rugged_low) * _rugged_scale, 0.0, last_bin)
				k = int(t)
				entry = rugged_table[k]
				rugged = entry + (rugged_table[k + 1] - entry) * (t - k)
			if rugged > 0.0:
				elevation += hill_height * rugged * clampf(hill.get_noise_3dv(pos) * _hill_scale, -1.0, 1.0)

		if detail_height > 0.0:
			elevation += detail_height * clampf(detail.get_noise_3dv(pos) * _detail_scale, -1.0, 1.0)

		# Ledges and arches: only near the surface so that nothing can float away from it.
		if overhang_height > 0.0 and ridge > 0.0:
			var distance_to_surface := absf(dist - sea - elevation)
			if distance_to_surface < overhang_height:
				var fade := 1.0 - smoothstep(0.0, overhang_height, distance_to_surface)
				elevation += overhang_height * ridge * fade * clampf(overhang.get_noise_3dv(pos) * _overhang_scale, -1.0, 1.0)

		var value := (dist - sea - elevation) * FLOOR_BIAS if as_field else elevation
		out[start + i] = value
		if value < lowest: lowest = value
		if value > highest: highest = value
	return Vector2(lowest, highest)

## Get a noise sample biased towards a world shape at a specific Vec3 of the noise volume
func sample(x: float, y: float, z: float) -> float:
	var out := PackedFloat32Array([0.0])
	_compute_row(x, y, z, 1.0, 1, out, 0, true)
	return out[0]

## Result of `sample_grid()`. `lowest` and `highest` are the extreme sample values, so callers can tell whether the grid crosses the surface without scanning it.
class GridSamples:
	var values: PackedFloat32Array
	var lowest: float
	var highest: float

## Samples `count`^3 points of a regular grid in one call. Point (x, y, z) is at `origin + Vector3(x, y, z) * step` and sits at index `x * count * count + y * count + z`. Equal to calling `sample()` for every point, but avoids the per-point call overhead, which dominates when many threads sample at once.
func sample_grid(origin: Vector3, step: int, count: int) -> GridSamples:
	var result := GridSamples.new()
	var values := PackedFloat32Array()
	values.resize(count * count * count)
	var lowest := INF
	var highest := -INF
	var index := 0
	for x in count:
		var x_value := x * step + origin.x
		for y in count:
			var row_range := _compute_row(x_value, y * step + origin.y, origin.z, step, count, values, index, true)
			index += count
			if row_range.x < lowest: lowest = row_range.x
			if row_range.y > highest: highest = row_range.y
	result.values = values
	result.lowest = lowest
	result.highest = highest
	return result

func get_bias_from_distance(distance: float) -> float:
	return (distance - sea_level) * FLOOR_BIAS

## Elevation of the surface layers above the sea radius at the 3D point `_pos` (the surface itself is where the elevation equals the distance from the sea radius).
func get_elevation_at_point(_pos: Vector3) -> float:
	var out := PackedFloat32Array([0.0])
	_compute_row(_pos.x, _pos.y, _pos.z, 1.0, 1, out, 0, false)
	return out[0]

## Color for a point on the surface, from its elevation and how flat the surface is there (`flatness`: the component of the unit surface normal along the local up, 1 = level, 0 = a vertical wall). Below the sea it is blue, fading to dark blue with depth, whatever the slope. On land it is sand at the shore, otherwise grass, and stone on steep slopes and at high elevations. Every change is a gradient. A surface point sits at `sea_level + elevation`, so the elevation comes from the distance to the center and needs no noise.
func get_biome_color(pos: Vector3, flatness := 1.0) -> Color:
	var elevation := pos.distance_to(center) - sea_level
	if elevation <= 0.0:
		return blue.lerp(dark_blue, smoothstep(0.0, _deep_water, -elevation))
	var color := green.lerp(sand, 1.0 - smoothstep(0.5 * _sand_height, 1.5 * _sand_height, elevation))
	var stone_weight := maxf(1.0 - smoothstep(FLATNESS_STONE, FLATNESS_GRASS, flatness), smoothstep(_stone_start, _stone_end, elevation))
	color = color.lerp(stone, stone_weight)
	return blue.lerp(color, smoothstep(0.0, SHORE_BLEND, elevation))
