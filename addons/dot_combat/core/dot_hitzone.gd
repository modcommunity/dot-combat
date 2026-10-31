class_name DotHitzone
extends RefCounted

## Body zones finer than the five classic hit groups, and which side of the body a shot landed on.
##
## A zone is a [DotHitGroup] name on a [DotHitbox]. With [member DotDamageRules.hitzones] off (cvar
## `mp_hitzones` 0, the default) the resolver folds a fine zone back to its coarse group, so a game that
## tags hands and feet changes no damage until an operator turns zones on. Stats always see the fine zone.

## Every zone, head to feet.
const ZONES: Array[StringName] = [
	DotHitGroup.HEAD, DotHitGroup.NECK, DotHitGroup.CHEST, DotHitGroup.STOMACH,
	DotHitGroup.ARM, DotHitGroup.HAND, DotHitGroup.LEG, DotHitGroup.FOOT,
]

const SIDE_LEFT := &"left"
const SIDE_MIDDLE := &"middle"
const SIDE_RIGHT := &"right"

## Fraction of the body's half-width either side of centre that still counts as middle.
const MIDDLE_BAND := 0.33

const CONTEXT_SIDE := &"hit_side"


## The classic group a fine zone folds into when zones are off.
static func coarse(zone: StringName) -> StringName:
	match zone:
		DotHitGroup.NECK:
			return DotHitGroup.CHEST
		DotHitGroup.HAND:
			return DotHitGroup.ARM
		DotHitGroup.FOOT:
			return DotHitGroup.LEG
	return zone


## Left, middle or right of the body as the shooter sees it, from where the ray met it.
static func side_of(point: Vector3, centre: Vector3, direction: Vector3, half_width: float) -> StringName:
	var right := direction.cross(Vector3.UP)
	if right.length_squared() < 0.0001:
		return SIDE_MIDDLE
	var lateral := (point - centre).dot(right.normalized()) / maxf(0.01, half_width)
	if lateral < -MIDDLE_BAND:
		return SIDE_LEFT
	if lateral > MIDDLE_BAND:
		return SIDE_RIGHT
	return SIDE_MIDDLE


## Files the side of a hit on [param damage] (context `hit_side`); the hitbox's set gives the body centre and width.
static func annotate(damage: DotDamage, hit: DotHitbox.Hit, direction: Vector3) -> void:
	if hit.hitbox == null:
		return
	var set_node: Node = hit.hitbox.get_parent()
	while set_node != null and not (set_node is DotHitboxSet):
		set_node = set_node.get_parent()
	if set_node == null:
		return
	var set := set_node as DotHitboxSet
	damage.context[CONTEXT_SIDE] = side_of(hit.point, set.bounds_centre(), direction, set.bounds_radius * 0.25)
