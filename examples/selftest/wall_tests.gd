extends "res://examples/selftest/support_tests.gd"

## Penetration, wall and pane sections.


func _pen_shot(tick: int, pen: DotPenetration) -> DotShot:
	var shot := _rifle_shot(1, tick, tick)
	shot.origin = Vector3(0.0, 1.0, 0.0)
	shot.direction = Vector3.FORWARD
	shot.tick = tick
	shot.penetration = pen
	shot.scatter()
	return shot


func _test_penetration() -> void:
	_section("penetration: walls and bodies")

	var trace := DotTraceFlat.with_floor(0.0)
	trace.add_box(AABB(Vector3(-3.0, 0.0, -5.2), Vector3(6.0, 3.0, 0.4)), &"wood")
	var manager := _make_manager(trace, DotDamageRules.new())
	var victim := _make_player(Vector3(0.0, 0.0, -10.0))
	_hitboxes_of(victim).register_with(manager, 2)
	manager.register_health(2, _health_of(victim))

	var pen := DotPenetration.new()
	pen.power = 1.0
	pen.materials = {&"wood": 1.0, &"steel": 10.0}
	pen.body_cost = 0.1

	var plain := _pen_shot(1, null)
	manager.resolve_shot(plain)
	_check(plain.damages.is_empty() and plain.penetrations.is_empty(), "no profile: the wall stops the round as before")

	var shot := _pen_shot(2, pen)
	manager.resolve_shot(shot)
	_check(shot.damages.size() == 1, "a round with power passes the wall and hits the player behind")
	_check(shot.penetrations.size() == 1, "one wall passed is recorded")
	_check(shot.penetrations[0]["material"] == &"wood", "the record names the material")
	_close(float(shot.penetrations[0]["thickness"]), 0.4, "and the thickness", 0.05)
	_close(shot.penetrations[0]["entry"].z, -4.8, "entry is on the near face", 0.05)
	_close(shot.penetrations[0]["exit"].z, -5.2, "exit is on the far face", 0.05)
	_close(float(shot.damages[0].amount), 25.0 * 0.6, "damage falls with the power the wall spent", 0.8)

	manager.penetration_scale = 0.2
	var weak := _pen_shot(3, pen)
	manager.resolve_shot(weak)
	_check(weak.damages.is_empty(), "sv_penetration_scale below the wall's cost stops it")
	manager.penetration_scale = 1.0

	manager.penetration_enabled = false
	var off := _pen_shot(4, pen)
	manager.resolve_shot(off)
	_check(off.damages.is_empty(), "sv_penetration 0 stops it")
	manager.penetration_enabled = true

	var steel := DotTraceFlat.with_floor(0.0)
	steel.add_box(AABB(Vector3(-3.0, 0.0, -5.2), Vector3(6.0, 3.0, 0.4)), &"steel")
	manager.trace = steel
	var blocked := _pen_shot(5, pen)
	manager.resolve_shot(blocked)
	_check(blocked.damages.is_empty() and blocked.penetrations.is_empty(), "a material that costs more than the power stops the round")
	manager.trace = trace

	_check(manager.set_cvar("sv_penetration_scale", "0.5") and is_equal_approx(manager.penetration_scale, 0.5), "the scale cvar applies")
	_check(manager.set_cvar("sv_penetration", "0") and not manager.penetration_enabled, "the switch cvar applies")
	_check(manager.set_cvar("sv_penetration_players", "0") and not manager.penetration_players, "the players cvar applies")
	manager.penetration_scale = 1.0
	manager.penetration_enabled = true
	var fast := DotPenetration.new()
	fast.power = 1.0
	fast.speed = 900.0
	fast.reference_speed = 600.0
	fast.body_cost = 0.1
	_check(is_equal_approx(fast.speed_factor(1.0), 600.0 / 900.0), "a round at full power is at muzzle speed, so it pays less than the plain cost")
	_check(fast.speed_factor(0.25) > fast.speed_factor(1.0), "a spent round is slower and pays more")
	_check(DotPenetration.new().speed_factor(0.5) == 1.0, "no speed set: the plain cost")
	_check(fast.body_cost_of(DotHitGroup.CHEST, fast.speed_factor(1.0)) < fast.body_cost_of(DotHitGroup.CHEST), "a fast round spends less power crossing a body")
	manager.penetration_players = true

	_penetration_bodies(manager, pen, victim)

	manager.queue_free()
	remove_child(manager)
	_clear_players()
	_done()


## Two players in a line, no wall: what a round does to bodies.
func _penetration_bodies(manager: DotCombatManager, pen: DotPenetration, victim: Node) -> void:
	var open := DotTraceFlat.with_floor(0.0)
	manager.trace = open
	var near := _make_player(Vector3(0.0, 0.0, -4.0))
	_hitboxes_of(near).register_with(manager, 3)
	manager.register_health(3, _health_of(near))
	var line := _pen_shot(6, pen)
	manager.resolve_shot(line)
	_check(line.damages.size() == 2, "a round passes the first player and hits the second")
	_check(line.damages[0].amount > line.damages[1].amount, "the second hit is weaker")
	_check(line.damages[1].context.get("penetrated", 0) == 1, "and is marked as penetrated")
	_check(_health_of(near).health < 100.0 and _health_of(victim).health < 100.0, "both are hurt")

	manager.penetration_players = false
	var stop := _pen_shot(7, pen)
	manager.resolve_shot(stop)
	_check(stop.damages.size() == 1, "sv_penetration_players 0 stops at the first body")
	manager.penetration_players = true

	var rifle_pen := DotPenetration.new()
	rifle_pen.power = 0.6
	rifle_pen.body_cost = 0.1
	var torso_shot := _pen_shot(9, rifle_pen)
	manager.resolve_shot(torso_shot)
	_check(torso_shot.damages.size() == 2, "a rifle round (power 0.6) crosses a torso and reaches the second player")
	var head_shot := _pen_shot(8, rifle_pen)
	head_shot.origin = Vector3(0.0, 1.7, 0.0)
	manager.resolve_shot(head_shot)
	_check(head_shot.damages.size() >= 1 and head_shot.damages[0].hit_group == DotHitGroup.HEAD, "the near player is shot in the head", String(head_shot.damages[0].hit_group) if head_shot.damages.size() >= 1 else "none")
	_check(head_shot.damages.size() == 1, "a headshot spends the round: nobody behind is hurt")

	var table := DotPenetration.new()
	table.body_cost = 0.1
	_check(table.body_cost_of(DotHitGroup.HEAD) > table.body_cost_of(DotHitGroup.CHEST) and table.body_cost_of(DotHitGroup.KNEE) > 0.0, "the default zone table makes a head cost more than a chest")
	manager.penetration_players = true


## A trace whose far faces are missing: a ray travelling toward +Z finds nothing, as with a one-sided collision sheet.
class OneSidedTrace extends DotTraceFlat:
	func _world_ray(from: Vector3, direction: Vector3, max_distance: float) -> DotHitbox.Hit:
		if direction.z > 0.0:
			return DotHitbox.Hit.new()
		return super._world_ray(from, direction, max_distance)


## A world ray that finds nothing when it starts inside a box, as a physics ray does.
class InsideBlindTrace extends DotTraceFlat:
	func _world_ray(from: Vector3, direction: Vector3, max_distance: float) -> DotHitbox.Hit:
		for box in boxes:
			if box.has_point(from):
				return DotHitbox.Hit.new()
		return super._world_ray(from, direction, max_distance)


func _test_muzzle_inside_wall() -> void:
	_section("a muzzle inside a wall cannot reach the far side")

	var trace := InsideBlindTrace.new()
	trace.floor_y = 0.0
	trace.add_box(AABB(Vector3(-3.0, 0.0, -5.2), Vector3(6.0, 3.0, 0.4)))
	var manager := _make_manager(trace, DotDamageRules.new())
	var victim := _make_player(Vector3(0.0, 0.0, -8.0))
	_hitboxes_of(victim).register_with(manager, 2)
	manager.register_health(2, _health_of(victim))

	var shot := _rifle_shot(1, 100, 1)
	shot.origin = Vector3(0.0, 1.0, -5.0)
	shot.direction = Vector3.FORWARD
	shot.tick = 100
	shot.scatter()
	manager.resolve_shot(shot)
	_check(shot.damages.is_empty(), "a shot from inside the wall does not hit the player behind it")
	_close(_health_of(victim).health, 100.0, "and the player is untouched")

	var open := _rifle_shot(1, 101, 2)
	open.origin = Vector3(0.0, 1.0, 0.0)
	open.direction = Vector3.BACK * -1.0
	open.tick = 101
	open.scatter()
	manager.resolve_shot(open)
	_check(open.damages.is_empty(), "the wall still stops a shot from outside")

	var clear := InsideBlindTrace.new()
	clear.floor_y = 0.0
	var free_manager := _make_manager(clear, DotDamageRules.new())
	var target := _make_player(Vector3(0.0, 0.0, -8.0))
	_hitboxes_of(target).register_with(free_manager, 2)
	free_manager.register_health(2, _health_of(target))
	var open_shot := _rifle_shot(1, 102, 1)
	open_shot.origin = Vector3(0.0, 1.0, 0.0)
	open_shot.direction = Vector3.FORWARD
	open_shot.tick = 102
	open_shot.scatter()
	free_manager.resolve_shot(open_shot)
	_check(open_shot.damages.size() == 1, "with no wall the same shot still hits")

	free_manager.queue_free()
	remove_child(free_manager)
	manager.queue_free()
	remove_child(manager)
	_clear_players()
	_done()


func _test_muzzle_inside_wall_penetration() -> void:
	_section("a muzzle inside a wall pays for the wall it is in")

	var trace := InsideBlindTrace.new()
	trace.floor_y = 0.0
	trace.add_box(AABB(Vector3(-3.0, 0.0, -5.2), Vector3(6.0, 3.0, 0.4)), &"wood")
	var manager := _make_manager(trace, DotDamageRules.new())
	var victim := _make_player(Vector3(0.0, 0.0, -9.0))
	_hitboxes_of(victim).register_with(manager, 2)
	manager.register_health(2, _health_of(victim))

	var pen := DotPenetration.new()
	pen.power = 1.0
	pen.materials = {&"wood": 1.0, &"steel": 10.0}
	pen.body_cost = 0.1

	var shot := _pen_shot(1, pen)
	shot.origin = Vector3(0.0, 1.0, -4.9)
	manager.resolve_shot(shot)
	_check(shot.penetrations.size() >= 1, "the round leaves the wall it starts in with a record")
	if shot.penetrations.size() >= 1:
		_close(float(shot.penetrations[0]["thickness"]), 0.3, "and the thickness is the metres of wall in front of the muzzle", 0.05)

	var thick := InsideBlindTrace.new()
	thick.floor_y = 0.0
	thick.add_box(AABB(Vector3(-3.0, 0.0, -5.2), Vector3(6.0, 3.0, 0.4)), &"steel")
	var stop_manager := _make_manager(thick, DotDamageRules.new())
	var target := _make_player(Vector3(0.0, 0.0, -9.0))
	_hitboxes_of(target).register_with(stop_manager, 2)
	stop_manager.register_health(2, _health_of(target))
	var stopped := _pen_shot(2, pen)
	stopped.origin = Vector3(0.0, 1.0, -4.9)
	stop_manager.resolve_shot(stopped)
	_check(stopped.damages.is_empty(), "a wall that costs more than the power stops a shot from inside it")

	stop_manager.queue_free()
	remove_child(stop_manager)
	manager.queue_free()
	remove_child(manager)
	_clear_players()
	_done()


class TestPane extends StaticBody3D:
	var broken := false
	var hurts := 0
	func hurt(_amount: float, _point: Vector3, _kind: StringName) -> void:
		hurts += 1
		broken = true
	func is_broken() -> bool:
		return broken


## A world with one pane whose collider outlives its breaking, as a real one can.
class PaneTrace extends DotTraceFlat:
	var pane: TestPane
	var pane_box := AABB(Vector3(-3.0, 0.0, -3.05), Vector3(6.0, 3.0, 0.1))
	func _world_ray(from: Vector3, direction: Vector3, max_distance: float) -> DotHitbox.Hit:
		var best := super._world_ray(from, direction, max_distance)
		if pane.get_rid() in exclude_rids:
			return best
		var t := _ray_aabb(from, direction, pane_box, max_distance)
		if t >= 0.0 and (not best.ok() or t < best.distance):
			best = _make_hit(from + direction * t, _box_normal(pane_box, from + direction * t), t)
			best.collider = pane
		return best


func _test_broken_pane_stays_open() -> void:
	_section("a broken pane whose collider remains does not block")

	var trace := PaneTrace.new()
	trace.floor_y = 0.0
	trace.pane = TestPane.new()
	var manager := _make_manager(trace, DotDamageRules.new())
	var victim := _make_player(Vector3(0.0, 0.0, -8.0))
	_hitboxes_of(victim).register_with(manager, 2)
	manager.register_health(2, _health_of(victim))

	var first := _rifle_shot(1, 100, 1)
	first.origin = Vector3(0.0, 1.0, 0.0)
	first.direction = Vector3.FORWARD
	first.tick = 100
	first.scatter()
	manager.resolve_shot(first)
	_check(first.damages.size() == 1, "the shot that breaks the pane carries on to the player behind it")
	_check(trace.pane.hurts == 1, "and hurts the pane once")

	var second := _rifle_shot(1, 101, 2)
	second.origin = Vector3(0.0, 1.0, 0.0)
	second.direction = Vector3.FORWARD
	second.tick = 101
	second.scatter()
	manager.resolve_shot(second)
	_check(second.damages.size() == 1, "the next shot through the broken pane hits too")
	_check(trace.pane.hurts == 2, "and hurts it again only on its own pass, not on the reverse ray")

	manager.queue_free()
	remove_child(manager)
	trace.pane.free()
	_clear_players()
	_done()


func _test_ricochet_and_sheets() -> void:
	_section("penetration: ricochet and one-sided sheets")

	var trace := OneSidedTrace.new()
	trace.floor_y = 0.0
	trace.add_box(AABB(Vector3(-3.0, 0.0, -4.81), Vector3(6.0, 3.0, 0.01)), &"glass")
	trace.add_box(AABB(Vector3(-3.0, 0.0, -8.2), Vector3(6.0, 3.0, 0.4)), &"concrete")
	var manager := _make_manager(trace, DotDamageRules.new())
	var victim := _make_player(Vector3(0.0, 0.0, -6.5))
	_hitboxes_of(victim).register_with(manager, 2)
	manager.register_health(2, _health_of(victim))

	var pen := DotPenetration.new()
	pen.power = 1.0
	pen.materials = {&"glass": 1.0, &"concrete": 5.0}
	pen.body_cost = 0.1

	var sheet := _pen_shot(1, pen)
	manager.resolve_shot(sheet)
	_check(sheet.penetrations.size() == 1 and sheet.penetrations[0]["sheet"] == true, "a one-sided glass sheet is passed on the material's thickness")
	_check(sheet.damages.size() == 1, "and the player behind it is hit")
	_close(float(sheet.penetrations[0]["thickness"]), 0.01, "the sheet's thickness is the per-material fallback", 0.001)

	var saved: Dictionary = manager.sheet_thickness
	manager.sheet_thickness = {}
	var stopped := _pen_shot(2, pen)
	manager.resolve_shot(stopped)
	_check(stopped.penetrations.is_empty() and stopped.damages.is_empty(), "a material with no known thickness stops at a one-sided sheet")
	manager.sheet_thickness = saved

	var floor_pen := DotPenetration.new()
	floor_pen.power = 1.0
	floor_pen.ricochet_materials = PackedStringArray(["concrete"])
	floor_pen.ricochet_angle = 15.0
	floor_pen.ricochet_keep = 0.5
	var grazing := _pen_shot(3, floor_pen)
	grazing.origin = Vector3(0.0, 1.0, 0.0)
	grazing.direction = Vector3(0.0, -0.05, -1.0).normalized()
	grazing.scatter()
	manager.resolve_shot(grazing)
	_check(grazing.ricochets.is_empty(), "sv_ricochet is off by default: nothing bounces")

	var wall_trace := OneSidedTrace.new()
	wall_trace.floor_y = 0.0
	wall_trace.add_box(AABB(Vector3(-30.0, 0.0, -5.2), Vector3(60.0, 3.0, 0.4)), &"concrete")
	var m2 := _make_manager(wall_trace, DotDamageRules.new())
	m2.ricochet_enabled = true
	var shallow := _pen_shot(4, floor_pen)
	shallow.origin = Vector3(-20.0, 1.0, 0.0)
	shallow.direction = Vector3(1.0, 0.0, -0.1).normalized()
	shallow.scatter()
	m2.resolve_shot(shallow)
	_check(shallow.ricochets.size() == 1 and shallow.ricochets[0]["direction"].z > 0.0, "a shallow hit on a listed material bounces off")
	_check(shallow.penetrations.is_empty(), "and does not pass the wall")
	var steep := _pen_shot(5, floor_pen)
	m2.resolve_shot(steep)
	_check(steep.ricochets.is_empty(), "a square-on hit does not bounce")
	var soft := DotPenetration.new()
	soft.power = 1.0
	soft.ricochet_angle = 15.0
	var other := _pen_shot(6, soft)
	other.origin = Vector3(-20.0, 1.0, 0.0)
	other.direction = Vector3(1.0, 0.0, -0.1).normalized()
	other.scatter()
	m2.resolve_shot(other)
	_check(other.ricochets.is_empty(), "a material the profile does not list does not bounce")
	_check(m2.set_cvar("sv_ricochet", "0") and not m2.ricochet_enabled and m2.set_cvar("sv_ricochet", "1") and m2.ricochet_enabled, "the sv_ricochet cvar applies")

	m2.queue_free()
	manager.queue_free()
	remove_child(manager)
	_clear_players()
	_done()


func _test_manager_walls() -> void:
	_section("manager: walls")

	var trace := DotTraceFlat.with_floor(0.0)
	# A wall between the shooter and the victim, at 5 m.
	trace.add_box(AABB(Vector3(-3.0, 0.0, -5.2), Vector3(6.0, 3.0, 0.4)))

	var manager := _make_manager(trace, DotDamageRules.new())

	var victim := _make_player(Vector3(0.0, 0.0, -10.0))
	_hitboxes_of(victim).register_with(manager, 2)
	manager.register_health(2, _health_of(victim))

	var shot := _rifle_shot(1, 100, 1)
	shot.origin = Vector3(0.0, 1.0, 0.0)
	shot.direction = Vector3.FORWARD
	shot.tick = 100
	shot.scatter()
	manager.resolve_shot(shot)

	_check(shot.damages.is_empty(), "a wall stops a shot")
	_close(_health_of(victim).health, 100.0, "and the player behind it is untouched")
	# The box spans z from -5.2 to -4.8, so the face a shot travelling along -Z meets
	# is the one at -4.8. Getting this backwards in a test is how a "wall" ends up
	# being tested from inside itself.
	_close(shot.impacts[0].z, -4.8, "the impact is on the near face of the wall", 0.05)

	var behind := _make_player(Vector3(0.0, 0.0, -8.0))
	_hitboxes_of(behind).register_with(manager, 3)
	manager.register_health(3, _health_of(behind))

	var second := _rifle_shot(1, 101, 2)
	second.origin = Vector3(0.0, 1.0, 0.0)
	second.direction = Vector3.FORWARD
	second.tick = 101
	second.scatter()
	manager.resolve_shot(second)
	_check(second.damages.is_empty(), "and a second player behind it is safe too")

	manager.queue_free()
	remove_child(manager)
	_clear_players()

	_test_cover_tie()
	_done()


## A hitbox surface at exactly the same distance as a wall face: a player hugging cover, the case the tie-break in [method DotTrace.ray] exists for.
## The numbers make both distances exactly 9.0, not two close values, so the tie is real.
func _test_cover_tie() -> void:
	var trace := DotTraceFlat.new()
	trace.add_box(AABB(Vector3(-3.0, -3.0, -9.4), Vector3(6.0, 6.0, 0.4)))

	var manager := _make_manager(trace, DotDamageRules.new())

	var body := Node3D.new()
	body.position = Vector3(0.0, 0.0, -10.0)

	var health := DotHealth.new()
	health.max_health = 100.0
	body.add_child(health)

	var set_node := DotHitboxSet.new()
	set_node.bounds_offset = Vector3.ZERO
	set_node.bounds_radius = 2.0

	var sphere := DotHitbox.new()
	sphere.shape = DotHitbox.Shape.SPHERE
	sphere.radius = 1.0
	set_node.add_child(sphere)

	body.add_child(set_node)
	add_child(body)
	set_node.refresh()
	_players.append(body)

	set_node.register_with(manager, 2)
	manager.register_health(2, health)

	var probe := trace.ray(Vector3.ZERO, Vector3.FORWARD, 100.0, [set_node])
	_close(probe.distance, 9.0, "the wall face and the hitbox surface coincide", 0.0001)
	_check(probe.blocked, "and the tie goes to the wall, not to the player")

	var shot := _rifle_shot(1, 100, 1)
	shot.origin = Vector3.ZERO
	shot.direction = Vector3.FORWARD
	shot.tick = 100
	shot.scatter()
	manager.resolve_shot(shot)
	_check(shot.damages.is_empty(), "so a player flush against cover is not shot through it")

	manager.queue_free()
	remove_child(manager)
	_clear_players()
