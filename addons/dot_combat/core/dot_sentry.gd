class_name DotSentry
extends RefCounted

## An automatic gun on a stand: picks a target, turns to it, fires when it is lined up.
##
## [b]Pure decision, no scene.[/b] A sentry knows where it is, how far it sees, how fast it turns,
## how often it fires and how long it lasts. The game gives it the candidates (any list of
## dictionaries with `id` and `at`) and a line-of-sight [Callable]; it answers "fire at this one"
## and the game turns that into a [DotShot] or a damage event. It is no [Node] because a server
## runs many of them with no tree to hang them on, and because a client draws its own model from
## the same numbers without needing the decision.
##
## [b]Server authority is the caller's.[/b] Only the authority calls [method step]; a client is
## told where the sentry is and when it fired and plays that back.
##
## Targets are kept until they die or leave sight rather than re-picked each tick: re-picking the
## nearest every tick makes a gun flick between two zombies at equal range and never settle.

## Seconds since [member born] after which [method expired] is true; 0 or less is forever.
var lifetime: float = 45.0
## Rounds it was loaded with; -1 never runs dry.
var ammo: int = 200
var reach: float = 22.0
## Degrees per second the barrel turns.
var turn_rate: float = 240.0
## Seconds between shots.
var interval: float = 0.12
## How near (degrees) the barrel must be to the target to fire.
var tolerance: float = 4.0
## Height of the muzzle above [member position].
var muzzle_height: float = 1.0
## Zombies closer than this are ignored (the barrel cannot depress that far).
var min_range: float = 0.8

var position: Vector3 = Vector3.ZERO
## Radians about +Y, 0 looking down -Z. Matches [code]Node3D.rotation.y[/code].
var yaw: float = 0.0
var pitch: float = 0.0
var born: float = 0.0
var shots: int = 0

## The id of the target held now, or -1.
var target_id: int = -1

var _ready_at: float = 0.0


func _init(p_position: Vector3 = Vector3.ZERO, p_now: float = 0.0, p_yaw: float = 0.0) -> void:
	position = p_position
	born = p_now
	_ready_at = p_now
	yaw = p_yaw


func muzzle() -> Vector3:
	return position + Vector3(0.0, muzzle_height, 0.0)


func expired(now: float) -> bool:
	return (lifetime > 0.0 and now - born >= lifetime) or ammo == 0


## Seconds left, or -1 when it does not run out by time.
func seconds_left(now: float) -> float:
	return maxf(born + lifetime - now, 0.0) if lifetime > 0.0 else -1.0


## One decision. [param candidates] are dictionaries `{id: int, at: Vector3}` (the point to hit);
## [param can_see] is `func(from: Vector3, to: Vector3) -> bool`. Returns `{}` or
## `{"fire": candidate, "from": muzzle, "to": point}`; the sentry has already spent the round.
func step(delta: float, now: float, candidates: Array, can_see: Callable) -> Dictionary:
	if expired(now):
		return {}

	var held := _find(candidates, target_id)

	if held.is_empty() or not _usable(held, can_see):
		held = _pick(candidates, can_see)

	if held.is_empty():
		target_id = -1
		return {}

	target_id = int(held["id"])
	var to := (held["at"] as Vector3) - muzzle()
	var want_yaw := atan2(-to.x, -to.z)
	var want_pitch := atan2(to.y, Vector2(to.x, to.z).length())
	var step_angle := deg_to_rad(turn_rate) * delta
	yaw += clampf(angle_difference(yaw, want_yaw), -step_angle, step_angle)
	pitch += clampf(want_pitch - pitch, -step_angle, step_angle)
	var off := rad_to_deg(maxf(absf(angle_difference(yaw, want_yaw)), absf(want_pitch - pitch)))

	if off > tolerance or now < _ready_at:
		return {}

	_ready_at = now + interval
	shots += 1

	if ammo > 0:
		ammo -= 1

	return {"fire": held, "from": muzzle(), "to": held["at"]}


func describe() -> Dictionary:
	return {"position": position, "yaw": snappedf(rad_to_deg(yaw), 0.1), "ammo": ammo, "shots": shots,
		"target": target_id, "lifetime": lifetime}


func _usable(c: Dictionary, can_see: Callable) -> bool:
	var d := (c["at"] as Vector3).distance_to(muzzle())
	return d <= reach and d >= min_range and bool(can_see.call(muzzle(), c["at"]))


func _pick(candidates: Array, can_see: Callable) -> Dictionary:
	var best: Dictionary = {}
	var best_d := INF

	for c: Dictionary in candidates:
		var d := (c["at"] as Vector3).distance_squared_to(muzzle())

		if d < best_d and _usable(c, can_see):
			best = c
			best_d = d

	return best


func _find(candidates: Array, id: int) -> Dictionary:
	if id < 0:
		return {}

	for c: Dictionary in candidates:
		if int(c["id"]) == id:
			return c

	return {}


## Whether a sentry may stand where [param from] looks along [param dir] up to [param reach]: the
## first thing the ray meets must be floor (its normal within [param max_tilt] degrees of up) with
## [param headroom] metres of nothing above, and room for the stand's radius [param footprint].
## Returns a [DotResult] holding `{position, normal}`; the failure's detail says why. The ray
## aims down from the end of the reach when the first meeting is a wall, so a sentry can be put
## "in front of me" without the caller finding the floor.
static func find_spot(space: PhysicsDirectSpaceState3D, from: Vector3, dir: Vector3, mask: int,
		reach_m: float = 2.5, headroom: float = 1.4, footprint: float = 0.35, max_tilt: float = 25.0,
		exclude: Array[RID] = []) -> DotResult:
	var ahead := from + dir.normalized() * reach_m
	var wall := PhysicsRayQueryParameters3D.create(from, ahead)
	wall.collision_mask = mask
	wall.exclude = exclude
	var wall_hit := space.intersect_ray(wall)

	if not wall_hit.is_empty():
		ahead = (wall_hit["position"] as Vector3) - dir.normalized() * footprint

	var down := PhysicsRayQueryParameters3D.create(ahead + Vector3.UP * 0.1, ahead + Vector3.DOWN * 3.0)
	down.collision_mask = mask
	down.exclude = exclude
	var floor_hit := space.intersect_ray(down)

	if floor_hit.is_empty():
		return DotResult.fail(DotError.CODE_INVALID, "No floor there.", "no_floor")

	var normal: Vector3 = floor_hit["normal"]

	if rad_to_deg(normal.angle_to(Vector3.UP)) > max_tilt:
		return DotResult.fail(DotError.CODE_INVALID, "Too steep.", "steep")

	var at: Vector3 = floor_hit["position"]
	var roof := PhysicsRayQueryParameters3D.create(at + Vector3.UP * 0.05, at + Vector3.UP * headroom)
	roof.collision_mask = mask
	roof.exclude = exclude

	if not space.intersect_ray(roof).is_empty():
		return DotResult.fail(DotError.CODE_INVALID, "No room above.", "headroom")

	var ring := PhysicsShapeQueryParameters3D.new()
	var sphere := SphereShape3D.new()
	sphere.radius = footprint
	ring.shape = sphere
	ring.transform = Transform3D(Basis.IDENTITY, at + Vector3.UP * (footprint + 0.1))
	ring.collision_mask = mask
	ring.exclude = exclude

	if not space.intersect_shape(ring, 1).is_empty():
		return DotResult.fail(DotError.CODE_INVALID, "Something is in the way.", "blocked")

	return DotResult.success({"position": at, "normal": normal})
