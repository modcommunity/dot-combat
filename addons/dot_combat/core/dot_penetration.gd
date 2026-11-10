class_name DotPenetration
extends RefCounted

## What one round can pass through: a power in metres of reference material, a resistance per surface material, a
## power cost per body. A [DotShot] carries it, so the manager reads nothing off a weapon; dot-weapon builds it from an ammo profile.

## Skull and neck are dense: a head hit costs several times the power of a chest hit, so a rifle round that crosses a torso stops in a head.
const DEFAULT_BODY_ZONES := {&"head": 8.0, &"neck": 3.0}

## Metres of resistance-1 material the round can cross at full strength. 0 passes nothing.
var power: float = 0.0
## Resistance per surface material id (power spent per metre of that material).
var materials: Dictionary = {}
## Resistance of a material not listed in [member materials].
var default_resistance: float = 1.0
## Farthest the round searches for the far side of a wall, in metres.
var max_depth: float = 1.0
## Power spent crossing a body.
var body_cost: float = 0.0
## Per hit-group multiplier on [member body_cost] (a limb costs less than the chest).
var body_zones: Dictionary = DEFAULT_BODY_ZONES.duplicate()
## Muzzle speed of the round in m/s. 0 turns the velocity pass off: costs are the plain ones.
var speed: float = 0.0
## Speed at which costs are the plain ones; a slower round pays more per metre and per body, a faster one less.
var reference_speed: float = 0.0
## Damage never falls below this share of the original after a pass, while power remains.
var min_damage: float = 0.0
## Most walls and bodies one pellet passes.
var max_passes: int = 4
## Materials a shallow hit bounces off (empty: no ricochet).
var ricochet_materials: PackedStringArray = PackedStringArray()
## Widest angle between ray and surface, in degrees, that still bounces.
var ricochet_angle: float = 0.0
## Share of power (and so of damage) a bounce keeps.
var ricochet_keep: float = 0.6
## Most bounces one pellet makes.
var max_ricochets: int = 1
## Per-metre damage lost to flight is not here: falloff is the damage type's.


func enabled() -> bool:
	return power > 0.0 and max_passes > 0


func resistance_of(material: StringName) -> float:
	return maxf(0.0, float(materials.get(material, materials.get(String(material), default_resistance))))


## Power spent crossing [param thickness] metres of [param material].
func wall_cost(thickness: float, material: StringName, speed_factor: float = 1.0) -> float:
	return thickness * resistance_of(material) * speed_factor


## Power spent crossing a body hit in [param group].
func body_cost_of(group: StringName, speed_factor: float = 1.0) -> float:
	return body_cost * float(body_zones.get(group, body_zones.get(String(group), 1.0))) * speed_factor


## Speed of the round with [param left] power remaining (kinetic energy goes with the square of speed), 0 when [member speed] is unset.
func speed_at(left: float) -> float:
	if speed <= 0.0 or power <= 0.0:
		return 0.0
	return speed * sqrt(clampf(left / power, 0.0, 1.0))


## Multiplier on wall and body costs for a round with [param left] power: [member reference_speed] over its current speed, within 0.25 to 4. 1 when the velocity pass is off.
func speed_factor(left: float) -> float:
	if speed <= 0.0 or reference_speed <= 0.0:
		return 1.0
	var now := speed_at(left)
	if now <= 0.0:
		return 4.0
	return clampf(reference_speed / now, 0.25, 4.0)


## Whether a ray meeting [param material] at [param grazing] degrees from the surface bounces.
func ricochets(material: StringName, grazing: float) -> bool:
	return ricochet_angle > 0.0 and max_ricochets > 0 and grazing <= ricochet_angle and ricochet_materials.has(String(material))


## Damage multiplier with [param left] power remaining.
func strength(left: float) -> float:
	if power <= 0.0 or left <= 0.0:
		return 0.0
	return maxf(clampf(left / power, 0.0, 1.0), min_damage)


func duplicate_scaled(scale: float) -> DotPenetration:
	var p := DotPenetration.new()
	p.power = power * scale
	p.materials = materials
	p.default_resistance = default_resistance
	p.max_depth = max_depth
	p.body_cost = body_cost
	p.body_zones = body_zones
	p.speed = speed
	p.reference_speed = reference_speed
	p.min_damage = min_damage
	p.max_passes = max_passes
	p.ricochet_materials = ricochet_materials
	p.ricochet_angle = ricochet_angle
	p.ricochet_keep = ricochet_keep
	p.max_ricochets = max_ricochets
	return p
