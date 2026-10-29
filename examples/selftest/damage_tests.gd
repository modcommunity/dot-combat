extends "res://examples/selftest/selftest_base.gd"

## The limb, freed-hitbox and fall damage sections.


## A hit on a tagged hitbox resolves to limb, world point and impulse; a threshold gates it; the sink is duck-typed.
func _test_limbs() -> void:
	_section("limb tags")

	var manager := _make_manager(DotTraceFlat.with_floor(0.0), DotDamageRules.new())
	var victim := _make_player(Vector3(0.0, 0.0, -10.0), 1000.0)
	for box in _hitboxes_of(victim).get_children():
		if box is DotHitbox:
			box.limb = &"head" if box.group == DotHitGroup.HEAD else (&"leg" if box.group == DotHitGroup.LEG else &"")
	_hitboxes_of(victim).register_with(manager, 2)
	manager.register_health(2, _health_of(victim))
	manager.limb_min_damage = {"default": 10.0, "leg": 40.0}

	var seen: Array = []
	manager.limb_hit.connect(func(e: Node, l: StringName, p: Vector3, a: float, i: Vector3) -> void: seen.append([e, l, p, a, i]))
	var sink := _LimbSink.new()
	manager.limb_target_fn = func(_e: Node) -> Object: return sink

	var shot := _rifle_shot(1, 100, 1)
	shot.origin = Vector3(0.0, 1.62, 0.0)
	shot.direction = Vector3.FORWARD
	shot.scatter()
	manager.resolve_shot(shot)
	_check(seen.size() == 1 and seen[0][1] == &"head", "a head hit resolves to the head limb", str(seen.size()))
	_check(seen.size() == 1 and seen[0][0] == victim, "with the entity that owns the hitbox")
	_check(seen.size() == 1 and absf(seen[0][2].z + 9.86) < 0.05 and absf(seen[0][2].y - 1.62) < 0.01, "at the world point of the hit")
	_check(seen.size() == 1 and seen[0][4].z < 0.0, "and an impulse along the shot")
	_check(sink.calls.size() == 1 and sink.calls[0][0].is_equal_approx(seen[0][2]), "the duck-typed target got hit(point, amount, impulse)")
	_check(shot.damages[0].limb == &"head", "the damage event carries the limb")

	# A leg shot for 25 is under the leg's 40 threshold: it hurts, but is not a limb hit.
	var low := _rifle_shot(1, 101, 2)
	low.origin = Vector3(0.0, 0.3, 0.0)
	low.direction = Vector3.FORWARD
	low.scatter()
	manager.resolve_shot(low)
	_check(low.damages.size() == 1 and low.damages[0].amount > 0.0, "a sub-threshold leg hit still does damage")
	_check(seen.size() == 1 and sink.calls.size() == 1, "but does not count as a limb hit", str(seen.size()))

	manager.limb_min_damage = {"leg": 10.0}
	var again := _rifle_shot(1, 102, 3)
	again.origin = Vector3(0.0, 0.3, 0.0)
	again.direction = Vector3.FORWARD
	again.scatter()
	manager.resolve_shot(again)
	_check(seen.size() == 2 and seen[1][1] == &"leg", "a lower threshold lets the leg through")

	# A target that takes the tagged limb gets it, not a point to re-resolve.
	var tagged := _TaggedSink.new()
	manager.limb_target_fn = func(_e: Node) -> Object: return tagged
	var third := _rifle_shot(1, 103, 4)
	third.origin = Vector3(0.0, 1.62, 0.0)
	third.direction = Vector3.FORWARD
	third.scatter()
	manager.resolve_shot(third)
	_check(tagged.calls.is_empty() and tagged.limb_calls.size() == 1 and tagged.limb_calls[0][0] == &"head", "a hit_limb target is told the hitbox's limb", str(tagged.limb_calls))
	_check(tagged.limb_calls.size() == 1 and tagged.limb_calls[0][1].is_equal_approx(seen[seen.size() - 1][2]), "with the world point of the hit")
	manager.limb_target_fn = func(_e: Node) -> Object: return sink

	manager.limb_min_damage = {}
	_check(is_zero_approx(manager.limb_threshold(&"head")), "no thresholds means every tagged hit counts")
	_check(DotHitbox.new().limb == &"", "an untagged hitbox has no limb")
	_check(sink.calls.size() == 2, "the sink saw exactly the counted hits")
	_check(DotHitbox.new().describe().has("limb"), "describe names the limb")

	manager.queue_free()
	remove_child(manager)
	_clear_players()
	_done()


class _LimbSink extends RefCounted:
	var calls: Array = []

	func hit(point: Vector3, amount: float, impulse: Vector3) -> StringName:
		calls.append([point, amount, impulse])
		return &""


class _TaggedSink extends _LimbSink:
	var limb_calls: Array = []

	func hit_limb(limb: StringName, point: Vector3, amount: float, impulse: Vector3) -> StringName:
		limb_calls.append([limb, point, amount, impulse])
		return &""


class FakeController extends Node:
	signal landed(impact: float)
	var state := FakeState.new()
	var surfaces: Object = null


class FakeSurface extends RefCounted:
	var fall_damping: float = 0.0


class FakeSurfaceSet extends RefCounted:
	var found: FakeSurface = null

	func get_surface(_id: StringName) -> FakeSurface:
		return found


class FakeState extends RefCounted:
	var surface: StringName = &""


func _fall_curve_checks() -> DotFallDamageRules:
	var rules := DotFallDamageRules.new()
	_check(rules.damage_for(40.0) == 0.0, "off by default: a huge fall does nothing")
	rules.enabled = true
	rules.threshold = 10.0
	rules.scale = 2.0
	_check(rules.damage_for(10.0) == 0.0, "at the threshold: none")
	_check(rules.damage_for(4.0) == 0.0, "below the threshold: none")
	_close(rules.damage_for(15.0), 10.0, "above it: scale times the excess")
	_close(rules.damage_for(20.0), 20.0, "twice the excess, twice the damage (linear)")
	rules.curve_power = 2.0
	_close(rules.damage_for(20.0), 200.0, "a power curve punishes a long fall more")
	rules.max_damage = 50.0
	_close(rules.damage_for(20.0), 50.0, "capped")
	rules.curve_power = 1.0
	rules.max_damage = 0.0
	_check(rules.damage_for(20.0, &"", true) == 0.0, "water landing: none")
	rules.soft_surfaces = [&"snow"]
	_check(rules.damage_for(20.0, &"snow") == 0.0, "soft surface: none")
	_check(rules.damage_for(20.0, &"concrete") > 0.0, "another surface still hurts")
	return rules


func _test_fall_damage() -> void:
	_section("fall damage: threshold, curve, water, soft surface, cvars, authority")

	var rules := _fall_curve_checks()

	var held := DotFallDamageRules.new()
	var made := held.bind_cvars(func(n: String, v: String, _d: String, f: int) -> Object:
		var cv := FakeCvar.new()
		cv.cvar_name = n
		cv.value = "1" if n == DotFallDamageRules.CVAR_ENABLED else v
		cv.flags = f
		return cv)
	_check(made.size() == 13 and held.enabled, "thirteen cvars; a value set before binding is read back")
	made[0].set_value("0")
	_check(not held.enabled, "sv_falldamage 0 turns it off live")
	made[1].set_value("8")
	_close(held.threshold, 8.0, "sv_falldamage_threshold is live")
	_check(not held.set_cvar(DotFallDamageRules.CVAR_SCALE, "lots"), "a non-number is refused")

	var manager := _make_manager(DotTraceFlat.with_floor(0.0), DotDamageRules.new())
	var health := DotHealth.new()
	health.max_health = 100.0
	health.health = 100.0
	add_child(health)
	manager.register_health(7, health)
	var ctl := FakeController.new()
	ctl.name = "Ctl"
	add_child(ctl)
	var fall := DotFallDamage.new()
	fall.rules = rules
	fall.rules.enabled = true
	fall.victim = 7
	fall.controller = DotNodeRef.of_path(ctl.get_path())
	fall.combat = DotNodeRef.of_path(manager.get_path())
	fall.controller.mode = DotNodeRef.Mode.ABSOLUTE
	fall.combat.mode = DotNodeRef.Mode.ABSOLUTE
	add_child(fall)
	_check(fall.describe()["attached"], "the node refs resolved and it attached")

	ctl.landed.emit(5.0)
	_close(health.health, 100.0, "a soft landing through the signal: no damage")
	ctl.landed.emit(15.0)
	_close(health.health, 90.0, "a hard landing through the signal hurts via the manager")
	rules.enabled = false
	ctl.landed.emit(30.0)
	_close(health.health, 90.0, "cvar off: no damage")
	rules.enabled = true
	manager.is_authority = false
	ctl.landed.emit(30.0)
	_close(health.health, 90.0, "not the authority (a client or a replay): no damage")
	manager.is_authority = true

	rules.lethal_speed = 30.0
	_close(rules.damage_for(29.0), 38.0, "just under the lethal speed it is the curve")
	_check(rules.damage_for(30.0) >= 1000.0, "at the lethal speed it kills")
	_check(held.set_cvar(DotFallDamageRules.CVAR_LETHAL, "25") and held.lethal_speed == 25.0, "sv_falldamage_lethal is live")
	_check(held.set_cvar(DotFallDamageRules.CVAR_POWER, "2") and held.curve_power == 2.0, "sv_falldamage_power is live")
	_check(held.set_cvar(DotFallDamageRules.CVAR_MAX, "40") and held.max_damage == 40.0, "sv_falldamage_max is live")
	_check(held.set_cvar("sv_falldamage_absorb_ladder", "0") and not held.absorbs[&"ladder"], "an absorb cvar turns one off")
	_check(not held.set_cvar("sv_falldamage_absorb_weather", "1"), "an unknown absorb context is refused")

	rules.lethal_speed = 0.0
	_check(rules.damage_for(20.0, &"", false, [&"ladder"]) == 0.0, "landing off a ladder absorbs by default")
	rules.absorbs[&"ladder"] = false
	_check(rules.damage_for(20.0, &"", false, [&"ladder"]) > 0.0, "a ladder that does not absorb hurts")
	_check(rules.damage_for(20.0, &"", false, [&"protected"]) == 0.0, "spawn protection absorbs")

	var flag := [false]
	fall.context_checks[&"noclip"] = func() -> bool: return flag[0]
	health.health = 100.0
	flag[0] = true
	ctl.landed.emit(30.0)
	_close(health.health, 100.0, "a host context that absorbs (noclip) means no damage")
	flag[0] = false

	var soft := FakeSurface.new()
	soft.fall_damping = 0.5
	var set := FakeSurfaceSet.new()
	set.found = soft
	ctl.surfaces = set
	ctl.state.surface = &"mattress"
	ctl.landed.emit(15.0)
	_close(health.health, 95.0, "a surface that damps a fall by half halves it")
	soft.fall_damping = 1.0
	ctl.landed.emit(30.0)
	_close(health.health, 95.0, "a surface that fully absorbs a fall does no damage")
	ctl.state.surface = &""

	rules.legs_seconds = 3.0
	rules.legs_speed = 0.5
	var got: Array = []
	fall.legs_broken.connect(func(sec: float, sc: float) -> void: got.append([sec, sc]))
	ctl.landed.emit(15.0)
	_check(got.size() == 1 and got[0][0] == 3.0 and got[0][1] == 0.5, "a damaging landing breaks the legs when the cvar says so")
	ctl.landed.emit(2.0)
	_check(got.size() == 1, "a soft landing leaves the legs alone")
	_done()


## An engine error is the only symptom of a freed box still in a set's list: the query
## carries on with the survivors, so a value assertion alone passes unguarded.
class ErrorCatcher extends Logger:
	var errors: Array[String] = []

	func _log_error(function: String, _file: String, _line: int, code: String,
			rationale: String, _editor_notify: bool, _error_type: int,
			_script_backtraces: Array) -> void:
		errors.append("%s %s %s" % [code, rationale, function])


func _test_freed_hitbox() -> void:
	_section("a hitbox freed under a registered set")

	var manager := _make_manager(DotTraceFlat.with_floor(0.0), DotDamageRules.new())
	var victim := _make_player(Vector3(0.0, 0.0, -10.0), 1000.0)
	var set_node := _hitboxes_of(victim)
	set_node.register_with(manager, 2)
	manager.register_health(2, _health_of(victim))

	var legs: Node = set_node.hitboxes()[2]
	legs.free()

	var catcher := ErrorCatcher.new()
	OS.add_logger(catcher)
	var shot := _rifle_shot(1, 200, 1)
	shot.origin = Vector3(0.0, 1.62, 0.0)
	shot.direction = Vector3.FORWARD
	shot.scatter()
	manager.resolve_shot(shot)
	var ray_hit := set_node.intersect_ray(Vector3(0.0, 1.62, 0.0), Vector3.FORWARD, 100.0)
	var near := set_node.overlaps_sphere(Vector3(0.0, 1.62, -10.0), 0.5)
	var inside := set_node.contains_point(Vector3(0.0, 1.0, -10.0))
	var closest := set_node.closest_point(Vector3(0.0, 0.0, -9.0))
	var described: Dictionary = set_node.describe()
	OS.remove_logger(catcher)

	_check(shot.damages.size() == 1 and ray_hit.ok(), "a shot still hits the boxes that remain")
	_check(near and inside, "overlap and containment still see the survivors")
	_check(closest.is_finite() and int(described["count"]) == 2, "closest point and describe skip the freed box", str(described["count"]))
	_check(set_node.hitboxes().size() == 2, "the list drops the freed box", str(set_node.hitboxes().size()))
	_check(catcher.errors.is_empty(), "and none of that raised an engine error", str(catcher.errors))

	_done()
