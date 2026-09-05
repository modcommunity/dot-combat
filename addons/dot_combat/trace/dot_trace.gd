class_name DotTrace
extends RefCounted

## Where a shot goes. The single place a weapon asks "what did I hit".
##
## [b]Why this is an abstraction and not just a physics query.[/b] The same reason
## dot-fps-controller has [code]DotFpsBody[/code]: a headless server, a self-test and
## a deterministic replay all need to trace against a world, and only one of those
## three has a populated physics space. Subclass it and a game can trace against
## anything — a heightmap, a voxel grid, a set of analytic boxes — without weapons
## knowing.
##
## Subclasses implement [method _world_ray] only. The hitbox walk, the world-geometry
## precedence and the exclusion rules are here, because getting them wrong is how a
## shot damages a player through a wall and every backend would otherwise have to get
## them right independently.

## Layers world geometry lives on, for backends that have layers.
var collision_mask: int = 1

## Nodes whose hitboxes are never tested. The shooter, usually.
var exclude: Array = []

## Bodies the world query ignores, for backends that have RIDs.
var exclude_rids: Array[RID] = []


## The world-geometry hit, or a miss. Override this and nothing else.
##
## Must return the [i]nearest[/i] solid surface along the ray, with
## [member DotHitbox.Hit.blocked] set. Returning a farther one lets shots through
## walls; returning nothing at all makes every wall in the game transparent to
## gunfire, which is the failure this base class cannot detect for you.
func _world_ray(
	_from: Vector3,
	_direction: Vector3,
	_max_distance: float
) -> DotHitbox.Hit:
	return DotHitbox.Hit.new()


## Traces a ray against world geometry and a set of entities.
##
## Returns the nearest hit of either kind. A world hit that is nearer than every
## hitbox comes back with [member DotHitbox.Hit.blocked] set and no entity, which is
## how a caller tells "hit a wall" from "hit nobody" — the first should still spawn a
## decal and the second should not.
##
## [param direction] must be unit length; it is not normalised here because every
## caller already has a normalised aim vector and normalising twice per pellet of a
## twelve-pellet shotgun is measurable.
func ray(
	from: Vector3,
	direction: Vector3,
	max_distance: float,
	sets: Array[DotHitboxSet] = []
) -> DotHitbox.Hit:
	var world := _world_ray(from, direction, max_distance)

	if world.ok():
		world.blocked = true

	# The world hit shortens the search: a hitbox behind a wall cannot be hit, and
	# testing to the full range and comparing afterwards would walk every hitbox in
	# the level for a shot that stopped two metres away.
	var limit := world.distance if world.ok() else max_distance
	var best := world

	for set_node in sets:
		if set_node == null or not is_instance_valid(set_node):
			continue

		if _is_excluded(set_node):
			continue

		var hit := set_node.intersect_ray(from, direction, limit)

		if not hit.ok():
			continue

		if hit.distance > limit:
			continue

		# Strictly nearer, so a hitbox exactly level with a wall surface loses to the
		# wall. A player standing flush against cover is the common case and giving
		# the tie to the hitbox is how they get shot through it.
		if best.ok() and hit.distance >= best.distance:
			continue

		best = hit
		limit = hit.distance

	return best


## Whether nothing solid stands between two points.
##
## For interest management, for bot vision and for splash damage, which should not
## travel through a wall. Entity hitboxes deliberately do not block: a team-mate
## standing in a doorway does not stop an explosion.
func line_of_sight(from: Vector3, to: Vector3) -> bool:
	var offset := to - from
	var distance := offset.length()

	if distance <= 0.0001:
		return true

	var hit := _world_ray(from, offset / distance, distance)
	return not hit.ok()


## Every entity with a hitbox inside a sphere, nearest first.
##
## What splash damage is built on. [param require_line_of_sight] runs one
## [method line_of_sight] per candidate against its closest point, so a grenade on the
## other side of a wall does not damage through it.
func sphere_overlap(
	centre: Vector3,
	radius: float,
	sets: Array[DotHitboxSet] = [],
	require_line_of_sight: bool = true
) -> Array[DotHitboxSet]:
	var found: Array[DotHitboxSet] = []
	var distances: Array[float] = []

	for set_node in sets:
		if set_node == null or not is_instance_valid(set_node):
			continue

		if _is_excluded(set_node):
			continue

		if not set_node.overlaps_sphere(centre, radius):
			continue

		var closest := set_node.closest_point(centre)

		if require_line_of_sight and not line_of_sight(centre, closest):
			continue

		# Insertion sort: splash reaches a handful of entities and this avoids
		# building a parallel structure to sort.
		var distance := centre.distance_to(closest)
		var index := distances.size()
		while index > 0 and distances[index - 1] > distance:
			index -= 1
		found.insert(index, set_node)
		distances.insert(index, distance)

	return found


func _is_excluded(set_node: DotHitboxSet) -> bool:
	if exclude.is_empty():
		return false

	var entity := set_node.entity_owner()

	for node in exclude:
		if node == null:
			continue
		if node == entity or node == set_node:
			return true

	return false


func describe() -> Dictionary:
	return {
		"backend": get_script().resource_path.get_file(),
		"mask": collision_mask,
		"excluded": exclude.size(),
	}
