class_name TerrainParams
extends Resource

## Everything that shapes a planet's terrain, tweakable from the inspector. Assign one to `Planet.terrain`; a fresh resource per planet (or a saved .tres preset shared between planets) gives each planet its own landscape. Only the base shape lives here, biomes will come later.
##
## Every value has an explicit range and `WorldNoise` additionally clamps the derived heights to what the planet and the feature size can carry (see `WorldNoise.effective_*`), so no combination of sliders can tear the terrain. Heights are meters above the sea radius. Continents scale with the planet; mountains, hills and detail keep a fixed size in meters, so ground level looks the same on every planet.

@export_group("Planet")
## Moves the sea radius up or down. The 'zero' elevation of every other value in this resource.
@export_range(-100.0, 100.0, 1.0, "suffix:m") var sea_level_offset := 0.0

@export_group("Continents")
## Roughly how many land masses fit around the equator. The continent wavelength is the planet circumference divided by this, so it follows the planet size.
@export_range(1.0, 8.0, 0.5) var continent_count := 3.0
## Fraction of the surface that is below sea level.
@export_range(0.05, 0.9, 0.01) var ocean_coverage := 0.55
## Depth of the deepest ocean floor.
@export_range(10.0, 800.0, 1.0, "suffix:m") var ocean_depth := 80.0
## 0 = long gentle beaches and shelves, 1 = the land drops off in cliffs at the coast.
@export_range(0.0, 1.0, 0.01) var coast_sharpness := 0.35

@export_group("Mountains")
## Height of the tallest peaks above sea level (the lowland under them adds about a fifth of it, hills and detail come on top). Limited to about 12% of the planet radius, and to what `mountain_scale` can hold at a sane slope.
@export_range(20.0, 1000.0, 1.0, "suffix:m") var peak_height := 150.0
## Fraction of the surface covered by mountain ranges. 0 = no mountains at all.
@export_range(0.0, 1.0, 0.01) var mountain_coverage := 0.3
## Distance between neighbouring ridges.
@export_range(150.0, 4000.0, 10.0, "suffix:m") var mountain_scale := 700.0
## 1 = broad rounded crests, 3 = few narrow peaks on wide flat feet.
@export_range(1.0, 3.0, 0.05) var ridge_sharpness := 1.8
## 0 = young, jagged and rough mountains. 1 = old, smooth and worn down.
@export_range(0.0, 1.0, 0.01) var erosion := 0.4
## How much the ridges meander instead of running straight.
@export_range(0.0, 1.0, 0.01) var mountain_warp := 0.4
## Quantises the mountain height into steps, for mesas and plateaus. 0 = off.
@export_range(0.0, 1.0, 0.01) var terracing := 0.0

@export_group("Hills and detail")
## Height of the rolling hills.
@export_range(0.0, 30.0, 0.5, "suffix:m") var hill_height := 8.0
## Distance between neighbouring hills. Limits `hill_height` to a twentieth of itself.
@export_range(20.0, 400.0, 1.0, "suffix:m") var hill_scale := 150.0
## Fraction of the land that is flattened into plains (hills fade out there).
@export_range(0.0, 0.9, 0.01) var plains_fraction := 0.3
## Height of the small rocky roughness (wavelength 12 m, so at most 0.6 m of it is used).
@export_range(0.0, 1.0, 0.05, "suffix:m") var detail_height := 0.5

@export_group("Shape")
## How much the large features (continents, mountain ranges) ignore height. 1 = the noise is sampled on the sea-level sphere, so a mountain stands straight up. 0 = sampled where the point really is, which is pure 3D noise but makes tall features lean and fold, so peaks have to stay much lower. Hills, detail and overhangs are always full 3D.
@export_range(0.0, 1.0, 0.01) var radial_coherence := 0.75
## Ledges and arches on mountains, carved near the mountain surface only. 0 guarantees the terrain is one surface over the planet, with nothing floating or hollow. Overhangs appear from about 0.15. Up to 0.25 the rock stays in one piece; at 0.3 a tiny hollow pocket shows up now and then (`tools/bench/check_floating_rock.gd`). Stronger values leave detached rock.
@export_range(0.0, 0.3, 0.01) var overhang := 0.0

## Sets every value to a random one inside its range. With `corners`, each value is one of the two ends of its range instead, which is where the terrain is under the most stress. For tests and for rolling a new planet.
func randomize_values(rng: RandomNumberGenerator, corners := false) -> void:
	for property in get_property_list():
		if property.hint != PROPERTY_HINT_RANGE or not (property.usage & PROPERTY_USAGE_EDITOR): continue
		var bounds: PackedStringArray = property.hint_string.split(",")
		var low := float(bounds[0])
		var high := float(bounds[1])
		if corners: set(property.name, low if rng.randf() < 0.5 else high)
		else: set(property.name, rng.randf_range(low, high))
