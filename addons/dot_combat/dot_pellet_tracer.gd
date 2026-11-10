class_name DotPelletTracer
extends RefCounted
## Walks one pellet through the world for a [DotCombatManager]: walls, panes, ricochets and bodies it passes spend the round's penetration power.
##
## Held by the manager and given back to it for every field it reads; it owns no state between pellets.

var m: DotCombatManager = null

var _shot: DotShot = null
var _pellet: int = 0
var _type: DotDamageType = null
var _pen: DotPenetration = null
var _direction: Vector3 = Vector3.ZERO
var _from: Vector3 = Vector3.ZERO
var _remaining: float = 0.0
var _power: float = 0.0
var _passes: int = 0
var _walls: int = 0
var _walked: float = 0.0
var _bounces: int = 0
var _skip: Array = []
var _skip_rids: Array[RID] = []


func _init(manager: DotCombatManager) -> void:
	m = manager


## One pellet: walls and (under [member DotCombatManager.penetration_players]) bodies it passes spend [param pen]'s power, damage falls with what is left.
func trace_pellet(shot: DotShot, pellet: int, type: DotDamageType, pen: DotPenetration, excluded: Array) -> void:
	var base_rids := m.trace.exclude_rids
	_begin(shot, pellet, type, pen, excluded, base_rids)
	_walk()
	m.trace.exclude_rids = base_rids


func _begin(shot: DotShot, pellet: int, type: DotDamageType, pen: DotPenetration, excluded: Array, base_rids: Array[RID]) -> void:
	_shot = shot
	_pellet = pellet
	_type = type
	_pen = pen
	_direction = shot.pellets[pellet]
	_from = shot.origin
	_remaining = shot.max_range
	_power = pen.power if pen != null else 0.0
	_passes = 0
	_walls = 0
	_walked = 0.0
	_bounces = 0
	_skip = excluded.duplicate()
	_skip_rids = base_rids.duplicate()


func _walk() -> void:
	while true:
		m.trace.exclude = _skip
		m.trace.exclude_rids = _skip_rids
		var hit := m.trace.ray(_from, _direction, _remaining, m._set_list)

		if not hit.ok():
			_shot.impacts.append(_shot.origin + _direction * _shot.max_range)
			return

		var can_pass := _pen != null and _passes < _pen.max_passes and _power > 0.0
		var again := _step_world(hit, can_pass) if (hit.blocked or hit.entity == null) else _step_body(hit, can_pass)
		if not again:
			return


## Moves on past a face; false (impact recorded) when the range is spent.
func _advance(to: Vector3, distance: float) -> bool:
	_walked += distance
	_from = to
	_remaining = _shot.max_range - _walked
	if _remaining <= 0.0:
		_shot.impacts.append(_from)
		return false
	return true


## A wall, pane or open sky hit. True to keep walking.
func _step_world(hit: DotHitbox.Hit, can_pass: bool) -> bool:
	# A pane (anything with hurt() and is_broken()) takes the shot's damage and lets it through once broken.
	var pane := hit.collider as Node
	if pane != null and pane.has_method(&"hurt") and pane.has_method(&"is_broken"):
		pane.call(&"hurt", _shot.damage * m.config.damage_scale, hit.point, &"bullet")
		if bool(pane.call(&"is_broken")):
			_skip.append(pane)
			if pane is CollisionObject3D:
				_skip_rids.append((pane as CollisionObject3D).get_rid())
			return _advance(hit.point + _direction * 0.01, hit.distance)

	if m._ricochets_off(hit, _direction, _pen, _bounces):
		return _ricochet(hit)

	var exit: DotHitbox.Hit = null
	if can_pass:
		exit = hit if hit.inside_start else wall_exit(hit, _direction, _pen)
	var sheet := false
	if can_pass and exit == null:
		exit = sheet_exit(hit, _direction)
		sheet = exit != null
	if exit == null:
		_shot.impacts.append(hit.point)
		return false

	var thickness: float = hit.point.distance_to(_from) if hit.inside_start else hit.point.distance_to(exit.point)
	_power -= _pen.wall_cost(thickness, hit.material, _pen.speed_factor(_power))
	if _power <= 0.0:
		_shot.impacts.append(hit.point)
		return false

	_shot.penetrations.append({
		"pellet": _pellet, "material": hit.material, "thickness": thickness,
		"entry": _from if hit.inside_start else hit.point, "exit": exit.point,
		"entry_normal": hit.normal, "exit_normal": exit.normal, "sheet": sheet,
	})
	_passes += 1
	_walls += 1
	return _advance(exit.point + _direction * 0.01, hit.distance if hit.inside_start else hit.distance + thickness)


func _ricochet(hit: DotHitbox.Hit) -> bool:
	var grazing := rad_to_deg(asin(clampf(absf(_direction.dot(hit.normal)), 0.0, 1.0)))
	_direction = _direction.bounce(hit.normal).normalized()
	_power *= _pen.ricochet_keep
	_bounces += 1
	_shot.ricochets.append({
		"pellet": _pellet, "material": hit.material, "point": hit.point,
		"normal": hit.normal, "angle": grazing, "direction": _direction,
	})
	_walked += hit.distance
	_from = hit.point + hit.normal * 0.02
	_remaining = _shot.max_range - _walked
	if _power <= 0.0 or _remaining <= 0.0:
		_shot.impacts.append(hit.point)
		return false
	return true


## A body hit: damage it, and keep walking when the round can pass through. True to keep walking.
func _step_body(hit: DotHitbox.Hit, can_pass: bool) -> bool:
	var victim := m._entity_id_of(hit.entity)

	if victim == 0:
		_shot.impacts.append(hit.point)
		return false

	var strength := _pen.strength(_power) if _pen != null and (_passes > 0 or _bounces > 0) else 1.0
	var damage := DotDamage.make(
		_shot.attacker,
		victim,
		_shot.damage * m.config.damage_scale * strength,
		_type
	)
	damage.hit_group = hit.group
	damage.limb = hit.limb
	DotHitzone.annotate(damage, hit, _direction)
	damage.context["entity"] = hit.entity
	if _passes > 0:
		damage.context["penetrated"] = _passes
		damage.context["wallbang"] = _walls > 0
	if _bounces > 0:
		damage.context["ricochet"] = _bounces
	damage.point = hit.point
	damage.direction = _direction
	damage.distance = hit.distance + _walked
	damage.weapon_id = _shot.weapon_id
	damage.tick = _shot.tick

	if hit.hitbox != null:
		damage.scale_by(hit.hitbox.damage_scale, "hitbox")

	_shot.damages.append(m.resolver.resolve(damage))

	if not (can_pass and m.penetration_players):
		_shot.impacts.append(hit.point)
		return false

	_power -= _pen.body_cost_of(hit.group if m.rules.hitzones else DotHitzone.coarse(hit.group), _pen.speed_factor(_power))
	if _power <= 0.0:
		_shot.impacts.append(hit.point)
		return false

	var body_set := m._set_of(hit.entity)
	if body_set == null:
		_shot.impacts.append(hit.point)
		return false
	_skip.append(body_set)
	_passes += 1
	return _advance(hit.point + _direction * 0.01, hit.distance)


## The far face of the wall [param hit] is on: a ray from [member DotPenetration.max_depth] beyond it, back, against the world only. Null when there is none (a one-sided sheet, or thicker than the depth).
func wall_exit(hit: DotHitbox.Hit, direction: Vector3, pen: DotPenetration) -> DotHitbox.Hit:
	var far := hit.point + direction * pen.max_depth
	var saved := m.trace.exclude
	m.trace.exclude = m._set_list.duplicate()
	var back := m.trace.ray(far, -direction, pen.max_depth, m._set_list)
	m.trace.exclude = saved
	if not back.ok() or back.entity != null:
		return null
	return back


## A far face invented for a one-sided sheet: [member DotCombatManager.sheet_thickness] of the material beyond the entry, or null when its thickness is not known (then the round stops).
func sheet_exit(hit: DotHitbox.Hit, direction: Vector3) -> DotHitbox.Hit:
	var thickness := float(m.sheet_thickness.get(hit.material, m.sheet_thickness.get(String(hit.material), 0.0)))
	if thickness <= 0.0:
		return null
	var out := DotHitbox.Hit.new()
	out.distance = hit.distance + thickness
	out.point = hit.point + direction * thickness
	out.normal = -hit.normal
	out.material = hit.material
	out.blocked = true
	return out
