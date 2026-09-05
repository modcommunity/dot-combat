class_name DotTracePhysics
extends DotTrace

## Traces world geometry against Godot's 3D physics space.
##
## The backend a real game uses. Only world geometry goes through the physics server;
## entity hitboxes stay analytic — see [DotHitbox] for why that distinction is the
## whole point.

const CHANNEL := "combat.trace"

var _world: World3D = null

## Reused across queries. One allocation per shot, times twelve pellets, times a
## server full of players, is not free.
var _query := PhysicsRayQueryParameters3D.new()


static func for_world(world: World3D) -> DotTracePhysics:
	var trace := DotTracePhysics.new()
	trace.bind(world)
	return trace


## Binds to a world. The [World3D] is kept; its space state is not.
##
## [b]A [PhysicsDirectSpaceState3D] must not be cached across frames.[/b] Godot
## invalidates it at every physics step, and a stale one either answers from the
## previous step or pushes an error — and lag compensation is precisely the case that
## queries after moving things, so a stale state there is a shot that hits where the
## victim used to be twice over. Fetching it per query is a property read.
func bind(world: World3D) -> void:
	if world == null:
		DotLog.warn(CHANNEL, "bound to a null world; every trace will miss")
		return
	_world = world


func bind_from_node(node: Node3D) -> void:
	if node == null or not node.is_inside_tree():
		DotLog.warn(CHANNEL, "bind_from_node() on a node outside the tree")
		return
	bind(node.get_world_3d())


func _world_ray(
	from: Vector3,
	direction: Vector3,
	max_distance: float
) -> DotHitbox.Hit:
	var miss := DotHitbox.Hit.new()

	if _world == null:
		return miss

	var space := _world.direct_space_state

	if space == null:
		# Outside a physics step there is no space state at all. Reporting a miss
		# would make every wall transparent, so say so instead.
		DotLog.warn(CHANNEL, "no space state; trace ran outside a physics step")
		return miss

	_query.from = from
	_query.to = from + direction * max_distance
	_query.collision_mask = collision_mask
	_query.exclude = exclude_rids
	_query.collide_with_areas = false
	_query.collide_with_bodies = true
	_query.hit_from_inside = false

	var result := space.intersect_ray(_query)

	if result.is_empty():
		return miss

	var hit := DotHitbox.Hit.new()
	hit.point = result["position"]
	hit.normal = result["normal"]
	hit.distance = from.distance_to(hit.point)
	hit.blocked = true
	hit.group = DotHitGroup.GENERIC
	return hit


func is_bound() -> bool:
	return _world != null
