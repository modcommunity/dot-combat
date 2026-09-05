@tool
class_name DotHitbox
extends Node3D

## One region of an entity that a shot can land in, tested analytically.
##
## [b]Why these are not [Area3D]s.[/b] Lag compensation rewinds the world to where a
## client saw it, tests one ray, and puts it back. Doing that with physics areas means
## moving colliders, flushing the physics server, querying, and moving them back —
## once per shot per victim, on the server, at tick rate. Godot's physics server is
## also a frame behind for the first query after a move, which is exactly the
## situation lag compensation puts it in.
##
## So a hitbox here is a capsule or a box with a transform, and the intersection is
## fifteen lines of arithmetic against a ray. It costs nothing, it is exact, and — the
## part that matters — it gives the same answer on a client predicting the shot and on
## a server re-running it, which two physics queries with different flush states do
## not.
##
## The physics world is still consulted, once, for the terrain the ray might hit on
## the way. See [DotTracePhysics].

enum Shape {
	## A capsule along local Y. The default; what a limb or a torso is.
	CAPSULE,
	## An axis-aligned box in local space.
	BOX,
	## A sphere at the origin, using [member radius].
	SPHERE,
}

## Which region this is, for [DotHitGroup]. Empty means
## [constant DotHitGroup.GENERIC].
@export var group: StringName = DotHitGroup.CHEST

@export var shape: Shape = Shape.CAPSULE

## Capsule and sphere radius.
@export_range(0.01, 10.0, 0.01) var radius: float = 0.2

## Capsule height, tip to tip, including the caps.
@export_range(0.02, 10.0, 0.01) var height: float = 0.6

## Box half-extents in local space.
@export var half_extents: Vector3 = Vector3(0.2, 0.3, 0.2)

## An extra multiplier on top of the hit group's, for this hitbox specifically.
##
## For the case where two hitboxes share a group but not a value — a weak point on an
## otherwise ordinary torso.
@export_range(0.0, 10.0, 0.05) var damage_scale: float = 1.0

## Off means the hitbox is not tested at all. For a limb that has been destroyed, or
## for a pose in which it should not be reachable.
@export var enabled: bool = true

## Priority when two hitboxes are hit at the same distance.
##
## Ties happen constantly with nested hitboxes: a head capsule inside a torso box
## shares a surface, and floating-point equality on the entry distance is common
## enough that leaving it to node order produces a game where headshots work about
## half the time. Higher wins.
@export_range(0, 100, 1) var precedence: int = 0

## The entity this belongs to, resolved once. Empty resolves to the nearest ancestor
## carrying a [DotHealth], which is what a player scene almost always wants.
@export var owner_ref: DotNodeRef = null

var _owner: Node = null


## What a ray found. Returned by [method intersect_ray] and by [DotTrace].
class Hit extends RefCounted:
	## Distance along the ray, in metres. Negative means no hit.
	var distance: float = -1.0
	var point: Vector3 = Vector3.ZERO
	var normal: Vector3 = Vector3.ZERO
	var hitbox: DotHitbox = null
	var group: StringName = DotHitGroup.GENERIC

	## The entity that owns whatever was hit. Null for world geometry.
	var entity: Node = null

	## Set when the ray stopped on world geometry rather than on a hitbox. A shot
	## that hits a wall in front of a player must not damage the player, and the only
	## thing that distinguishes the two is this flag.
	var blocked: bool = false

	func ok() -> bool:
		return distance >= 0.0

	func _to_string() -> String:
		if not ok():
			return "Hit(none)"
		return "Hit(%.3fm %s%s)" % [
			distance,
			group,
			", blocked" if blocked else "",
		]


func _ready() -> void:
	if Engine.is_editor_hint():
		return
	resolve_owner()


## Finds and caches the node this hitbox belongs to.
func resolve_owner() -> Node:
	if _owner != null and is_instance_valid(_owner):
		return _owner

	if owner_ref != null:
		_owner = owner_ref.resolve_or_null(self, "combat.hitbox")
		if _owner != null:
			return _owner

	# Nearest ancestor that has a DotHealth among its children. A player scene is
	# Player{DotHealth, Model{Hitbox...}}, so the hitbox is several levels below the
	# thing that owns the health, and "my parent" is the wrong answer more often than
	# it is the right one.
	var node: Node = get_parent()
	while node != null:
		for child in node.get_children():
			if child is DotHealth:
				_owner = node
				return _owner
		node = node.get_parent()

	_owner = get_parent()
	return _owner


func entity_owner() -> Node:
	return resolve_owner()


func effective_group() -> StringName:
	return group if group != &"" else DotHitGroup.GENERIC


## Intersects a world-space ray, returning the entry distance or -1.
##
## [param from] and [param direction] are world space; [param direction] must be unit
## length. [param max_distance] bounds the search.
##
## The ray is transformed into the hitbox's local space rather than the shape into
## the world, because a capsule with an arbitrary rotation has no closed form in world
## space and a local-space one is an axis-aligned problem.
func intersect_ray(
	from: Vector3,
	direction: Vector3,
	max_distance: float
) -> Hit:
	var miss := Hit.new()

	if not enabled:
		return miss

	var inverse := global_transform.affine_inverse()
	var local_from := inverse * from
	var local_dir := (inverse.basis * direction).normalized()

	var distance := -1.0

	match shape:
		Shape.SPHERE:
			distance = _ray_sphere(local_from, local_dir, Vector3.ZERO, radius)
		Shape.BOX:
			distance = _ray_box(local_from, local_dir, half_extents)
		_:
			distance = _ray_capsule(local_from, local_dir)

	if distance < 0.0:
		return miss

	# The local direction was renormalised after the inverse basis, which rescales it
	# whenever the hitbox is scaled. Converting the distance back through the same
	# scale is what keeps a scaled hitbox from reporting a distance in the wrong units
	# — and a scaled player model is the normal case, not an exotic one.
	var local_hit := local_from + local_dir * distance
	var world_hit := global_transform * local_hit
	var world_distance := from.distance_to(world_hit)

	if world_distance > max_distance:
		return miss

	var hit := Hit.new()
	hit.distance = world_distance
	hit.point = world_hit
	hit.normal = _normal_at(local_hit).normalized()
	hit.hitbox = self
	hit.group = effective_group()
	hit.entity = resolve_owner()
	return hit


## Whether a sphere of [param sphere_radius] at [param centre] overlaps this hitbox.
##
## What splash damage uses. Approximated by expanding the hitbox rather than by an
## exact shape-shape test: the error is under a radius and splash falls off with
## distance anyway, and an exact capsule-sphere test would still be an approximation
## of a body.
func overlaps_sphere(centre: Vector3, sphere_radius: float) -> bool:
	if not enabled:
		return false

	var local := global_transform.affine_inverse() * centre

	match shape:
		Shape.SPHERE:
			return local.length() <= radius + sphere_radius
		Shape.BOX:
			var clamped := Vector3(
				clampf(local.x, -half_extents.x, half_extents.x),
				clampf(local.y, -half_extents.y, half_extents.y),
				clampf(local.z, -half_extents.z, half_extents.z),
			)
			return local.distance_to(clamped) <= sphere_radius
		_:
			var half := maxf(0.0, height * 0.5 - radius)
			var on_axis := Vector3(0.0, clampf(local.y, -half, half), 0.0)
			return local.distance_to(on_axis) <= radius + sphere_radius


## The closest point on this hitbox to [param point], in world space.
func closest_point(point: Vector3) -> Vector3:
	var local := global_transform.affine_inverse() * point
	var out := local

	match shape:
		Shape.SPHERE:
			out = local.normalized() * radius if local.length() > radius else local
		Shape.BOX:
			out = Vector3(
				clampf(local.x, -half_extents.x, half_extents.x),
				clampf(local.y, -half_extents.y, half_extents.y),
				clampf(local.z, -half_extents.z, half_extents.z),
			)
		_:
			var half := maxf(0.0, height * 0.5 - radius)
			var on_axis := Vector3(0.0, clampf(local.y, -half, half), 0.0)
			var offset := local - on_axis
			if offset.length() > radius:
				out = on_axis + offset.normalized() * radius

	return global_transform * out


# --- Intersection ----------------------------------------------------------

static func _ray_sphere(
	from: Vector3,
	direction: Vector3,
	centre: Vector3,
	sphere_radius: float
) -> float:
	var offset := from - centre
	var b := offset.dot(direction)
	var c := offset.length_squared() - sphere_radius * sphere_radius

	# Starting inside counts as a hit at zero. A muzzle inside someone's hitbox is a
	# point-blank shot, and reporting a miss there is how a shotgun pressed against a
	# chest does nothing.
	if c <= 0.0:
		return 0.0

	var discriminant := b * b - c

	if discriminant < 0.0:
		return -1.0

	var t := -b - sqrt(discriminant)
	return t if t >= 0.0 else -1.0


static func _ray_box(
	from: Vector3,
	direction: Vector3,
	extents: Vector3
) -> float:
	var t_min := -INF
	var t_max := INF

	for axis in range(3):
		var d := direction[axis]
		var o := from[axis]

		if absf(d) < 0.000001:
			if o < -extents[axis] or o > extents[axis]:
				return -1.0
			continue

		var t1 := (-extents[axis] - o) / d
		var t2 := (extents[axis] - o) / d

		if t1 > t2:
			var swap := t1
			t1 = t2
			t2 = swap

		t_min = maxf(t_min, t1)
		t_max = minf(t_max, t2)

		if t_min > t_max:
			return -1.0

	if t_max < 0.0:
		return -1.0

	return maxf(0.0, t_min)


func _ray_capsule(from: Vector3, direction: Vector3) -> float:
	var half := maxf(0.0, height * 0.5 - radius)

	# Cylinder body, in the XZ plane, bounded to the segment on Y.
	var dx := direction.x
	var dz := direction.z
	var a := dx * dx + dz * dz

	var best := -1.0

	if a > 0.000001:
		var ox := from.x
		var oz := from.z
		var b := ox * dx + oz * dz
		var c := ox * ox + oz * oz - radius * radius
		var discriminant := b * b - a * c

		if discriminant >= 0.0:
			var root := sqrt(discriminant)
			# Typed so the loop variable is a float and not a Variant: assigning a
			# Variant to `best` is an unsafe assignment, which these projects'
			# warning settings promote to an error.
			var roots: Array[float] = [(-b - root) / a, (-b + root) / a]
			for t in roots:
				if t < 0.0:
					continue
				var y := from.y + direction.y * t
				if y >= -half and y <= half:
					best = t if best < 0.0 else minf(best, t)
					break

	# Caps.
	var caps: Array[float] = [-half, half]
	for cap_y in caps:
		var t := _ray_sphere(from, direction, Vector3(0.0, cap_y, 0.0), radius)
		if t >= 0.0:
			best = t if best < 0.0 else minf(best, t)

	# Starting inside: distance zero, like the sphere case and for the same reason.
	if best < 0.0:
		var on_axis := Vector3(0.0, clampf(from.y, -half, half), 0.0)
		if from.distance_to(on_axis) <= radius:
			return 0.0

	return best


func _normal_at(local_point: Vector3) -> Vector3:
	match shape:
		Shape.SPHERE:
			return global_transform.basis * local_point
		Shape.BOX:
			var scaled := Vector3(
				local_point.x / maxf(0.0001, half_extents.x),
				local_point.y / maxf(0.0001, half_extents.y),
				local_point.z / maxf(0.0001, half_extents.z),
			)
			var axis := 0
			for i in range(1, 3):
				if absf(scaled[i]) > absf(scaled[axis]):
					axis = i
			var normal := Vector3.ZERO
			normal[axis] = signf(scaled[axis])
			return global_transform.basis * normal
		_:
			var half := maxf(0.0, height * 0.5 - radius)
			var on_axis := Vector3(0.0, clampf(local_point.y, -half, half), 0.0)
			return global_transform.basis * (local_point - on_axis)


func describe() -> Dictionary:
	return {
		"node": name,
		"group": String(effective_group()),
		"shape": Shape.keys()[shape],
		"enabled": enabled,
		"scale": damage_scale,
		"precedence": precedence,
	}
