@tool
class_name DotHitboxSet
extends Node3D

## Every [DotHitbox] belonging to one entity, tested as a unit.
##
## Sits above the hitboxes in the scene — usually on the model root, so the whole set
## follows the animation without anything having to keep transforms in step. Testing
## goes through here rather than through the individual boxes so that the tie-break
## between a head inside a torso is decided once, in one place, the same way on every
## machine.
##
## Registering with a [DotCombatManager] is what makes an entity shootable at all:
## the manager keeps the set list that a trace walks. An entity with hitboxes and no
## registration is invisible to every weapon in the game and nothing reports it, which
## is why [method register_with] logs when it finds no hitboxes.

const CHANNEL := "combat.hitboxes"

## The entity these belong to. Defaults to this node's parent.
@export var owner_ref: DotNodeRef = null

## Skip the whole set. For a dead body, a spectator, or an entity out of play.
@export var enabled: bool = true

## Radius of a sphere centred on this node that contains every hitbox.
##
## A cheap rejection before testing the boxes themselves. Set generously: too small
## silently drops hits, and the symptom is a weapon that misses from some angles.
@export_range(0.1, 50.0, 0.1) var bounds_radius: float = 1.5

## Vertical offset of that sphere's centre from this node, in local space.
@export var bounds_offset: Vector3 = Vector3(0.0, 0.9, 0.0)

var _hitboxes: Array[DotHitbox] = []
var _owner: Node = null
var _manager: Node = null


func _ready() -> void:
	if Engine.is_editor_hint():
		return
	refresh()


func _exit_tree() -> void:
	if _manager != null and is_instance_valid(_manager):
		_manager.call(&"unregister_hitboxes", self)
		_manager = null


## Re-collects the hitboxes below this node. Call after adding or removing one.
func refresh() -> void:
	_hitboxes.clear()
	_collect(self)

	_owner = null
	if owner_ref != null:
		_owner = owner_ref.resolve_or_null(self, CHANNEL)
	if _owner == null:
		_owner = get_parent()


func _collect(node: Node) -> void:
	for child in node.get_children():
		if child is DotHitbox:
			_hitboxes.append(child)
		# Nested sets belong to a different entity — a turret mounted on a vehicle —
		# so the walk stops rather than stealing their boxes.
		if child is DotHitboxSet:
			continue
		_collect(child)


func hitboxes() -> Array[DotHitbox]:
	return _hitboxes


func entity_owner() -> Node:
	if _owner == null or not is_instance_valid(_owner):
		refresh()
	return _owner


## Registers with a [DotCombatManager] so traces can find this entity.
##
## [param manager] is typed as [Node] rather than as [DotCombatManager] only so that
## this file has no ordering requirement against it; the call is a plain method call
## either way.
func register_with(manager: Node, entity_id: int) -> void:
	if manager == null:
		return

	if _hitboxes.is_empty():
		refresh()

	if _hitboxes.is_empty():
		# Almost always a scene mistake: the set was added but the boxes were parented
		# somewhere else. Silence here means an entity nothing can shoot.
		DotLog.warn(
			CHANNEL,
			"hitbox set registered with no hitboxes under it",
			{"node": String(get_path()), "entity": entity_id}
		)

	_manager = manager
	manager.call(&"register_hitboxes", self, entity_id)


## The tightest hit among every enabled hitbox, or a miss.
##
## Nearest wins. Ties — which nested hitboxes produce constantly, because a head
## capsule inside a torso box shares a surface — go to the higher
## [member DotHitbox.precedence], then to the higher damage scale. Leaving the tie to
## child order gives a game where headshots land about half the time and nobody can
## say why.
func intersect_ray(
	from: Vector3,
	direction: Vector3,
	max_distance: float
) -> DotHitbox.Hit:
	var miss := DotHitbox.Hit.new()

	if not enabled or _hitboxes.is_empty():
		return miss

	if not _ray_hits_bounds(from, direction, max_distance):
		return miss

	var best: DotHitbox.Hit = miss

	for box in _hitboxes:
		var hit := box.intersect_ray(from, direction, max_distance)

		if not hit.ok():
			continue

		if not best.ok():
			best = hit
			continue

		if hit.distance < best.distance - 0.0001:
			best = hit
			continue

		if absf(hit.distance - best.distance) <= 0.0001:
			var challenger := box.precedence
			var incumbent := best.hitbox.precedence
			if challenger > incumbent:
				best = hit
			elif challenger == incumbent and box.damage_scale > best.hitbox.damage_scale:
				best = hit

	return best


## Whether any hitbox overlaps a sphere. What splash damage tests against.
func overlaps_sphere(centre: Vector3, radius: float) -> bool:
	if not enabled:
		return false

	if bounds_centre().distance_to(centre) > bounds_radius + radius:
		return false

	for box in _hitboxes:
		if box.overlaps_sphere(centre, radius):
			return true

	return false


## The closest point on any hitbox to [param point], and its distance.
##
## Splash uses this rather than the entity origin so that a rocket beside someone's
## feet is not measured to the middle of their chest — the difference is most of a
## body's worth of falloff.
func closest_point(point: Vector3) -> Vector3:
	var best := bounds_centre()
	var best_distance := INF

	for box in _hitboxes:
		if not box.enabled:
			continue
		var candidate := box.closest_point(point)
		var distance := candidate.distance_squared_to(point)
		if distance < best_distance:
			best_distance = distance
			best = candidate

	return best


func bounds_centre() -> Vector3:
	return global_transform * bounds_offset


func _ray_hits_bounds(
	from: Vector3,
	direction: Vector3,
	max_distance: float
) -> bool:
	var offset := from - bounds_centre()
	var b := offset.dot(direction)
	var c := offset.length_squared() - bounds_radius * bounds_radius

	if c <= 0.0:
		return true

	if b > 0.0:
		return false

	var discriminant := b * b - c

	if discriminant < 0.0:
		return false

	return -b - sqrt(discriminant) <= max_distance


func describe() -> Dictionary:
	var boxes := []
	for box in _hitboxes:
		boxes.append(box.describe())

	return {
		"node": name,
		"enabled": enabled,
		"count": _hitboxes.size(),
		"bounds": bounds_radius,
		"hitboxes": boxes,
	}
