extends "res://examples/selftest/selftest_base.gd"

## The defibrillator, sentry and damage immunity sections.


func _test_defib() -> void:
	_section("defibrillator")

	var d := DotDefib.new()
	d.charges = 2
	d.cooldown_seconds = 5.0
	d.reach = 2.0
	d.max_body_age = 30.0
	_check(d.check(10.0, 5.0, 1.0).ok, "a fresh body in reach may be shocked")
	_check(not d.check(10.0, 5.0, 3.0).ok, "one out of reach may not")
	_check(not d.check(10.0, 31.0, 1.0).ok, "nor one past the time limit")
	d.max_body_age = 0.0
	_check(d.check(10.0, 9999.0, 1.0).ok, "0 as the limit is never too late")
	d.spend(10.0)
	_check(d.charges == 1 and not d.check(12.0, 1.0, 1.0).ok, "a shock costs a charge and starts the cooldown")
	_check(d.check(15.0, 1.0, 1.0).ok, "and the cooldown ends")
	d.spend(15.0)
	_check(not d.check(99.0, 1.0, 1.0).ok, "a spent one refuses for good")
	_check(is_equal_approx(d.revive_health(100.0), 40.0), "the revived come back with the configured share")
	_done()


func _test_sentry() -> void:
	_section("sentry")

	var sentry := DotSentry.new(Vector3.ZERO, 0.0)
	sentry.interval = 0.5
	sentry.lifetime = 10.0
	sentry.ammo = 3
	var see_all := func(_a: Vector3, _b: Vector3) -> bool: return true
	var near := {"id": 7, "at": Vector3(0.0, 1.0, -6.0)}
	var far := {"id": 8, "at": Vector3(0.0, 1.0, -40.0)}

	_check(sentry.step(0.1, 0.1, [far], see_all).is_empty(), "a target beyond reach is not fired at")
	_check(sentry.target_id == -1, "and is not held")

	# Facing -Z already, so the first lined-up step fires.
	var shot := sentry.step(0.1, 0.2, [far, near], see_all)
	_check(not shot.is_empty() and int(shot["fire"]["id"]) == 7, "it fires at the one in reach")
	_check(sentry.ammo == 2 and sentry.shots == 1, "a shot costs a round", str(sentry.ammo))
	_check(sentry.step(0.1, 0.3, [near], see_all).is_empty(), "it waits out the interval")
	_check(not sentry.step(0.1, 0.8, [near], see_all).is_empty(), "and fires again after it")

	# A target behind it needs turning to: no shot until the barrel is on it.
	var behind := {"id": 9, "at": Vector3(0.0, 1.0, 6.0)}
	var turned := DotSentry.new(Vector3.ZERO, 0.0)
	turned.turn_rate = 90.0
	var first := turned.step(0.5, 1.0, [behind], see_all)
	_check(first.is_empty() and absf(turned.yaw) > 0.5, "it turns before it fires", str(turned.yaw))
	var fired_at := -1.0
	for i in 40:
		var t := 1.5 + 0.1 * i
		if not turned.step(0.1, t, [behind], see_all).is_empty():
			fired_at = t
			break
	_check(fired_at > 1.5, "and fires once it is round", str(fired_at))

	# Held target: stays on the first while a nearer one appears.
	var holder := DotSentry.new(Vector3.ZERO, 0.0)
	var _a := holder.step(0.1, 0.1, [near], see_all)
	var nearer := {"id": 10, "at": Vector3(0.0, 1.0, -2.0)}
	var _b := holder.step(0.1, 0.2, [near, nearer], see_all)
	_check(holder.target_id == 7, "it keeps its target while it is usable")
	_check(holder.step(0.1, 9.0, [near], func(_x, _y) -> bool: return false).is_empty() and holder.target_id == -1,
		"a target behind cover is dropped")

	var empty := DotSentry.new(Vector3.ZERO, 0.0)
	empty.ammo = 0
	_check(empty.expired(0.0), "no ammunition is expired")
	var timed := DotSentry.new(Vector3.ZERO, 5.0)
	timed.lifetime = 10.0
	_check(not timed.expired(14.0) and timed.expired(15.0), "a lifetime runs from its birth")
	_close(timed.seconds_left(12.0), 3.0, "and counts down")

	# Placement against a real floor, a wall and a low ceiling.
	var floor_body := StaticBody3D.new()
	var floor_shape := CollisionShape3D.new()
	var floor_box := BoxShape3D.new()
	floor_box.size = Vector3(40.0, 1.0, 40.0)
	floor_shape.shape = floor_box
	floor_body.add_child(floor_shape)
	floor_body.position = Vector3(0.0, -0.5, 0.0)
	add_child(floor_body)

	var wall := StaticBody3D.new()
	var wall_shape := CollisionShape3D.new()
	var wall_box := BoxShape3D.new()
	wall_box.size = Vector3(10.0, 4.0, 0.5)
	wall_shape.shape = wall_box
	wall.add_child(wall_shape)
	wall.position = Vector3(0.0, 2.0, -12.0)
	add_child(wall)

	var low := StaticBody3D.new()
	var low_shape := CollisionShape3D.new()
	var low_box := BoxShape3D.new()
	low_box.size = Vector3(4.0, 0.2, 4.0)
	low_shape.shape = low_box
	low.add_child(low_shape)
	low.position = Vector3(15.0, 1.2, 0.0)
	add_child(low)

	await get_tree().physics_frame
	await get_tree().physics_frame
	var space := floor_body.get_world_3d().direct_space_state
	var eye := Vector3(0.0, 1.6, 0.0)

	var ok := DotSentry.find_spot(space, eye, Vector3.FORWARD, 1, 2.5)
	_check(ok.ok and absf((ok.value["position"] as Vector3).y) < 0.05, "a spot on open floor is found")
	_close((ok.value["position"] as Vector3).z, -2.5, "about the reach ahead", 0.1)

	var by_wall := DotSentry.find_spot(space, Vector3(0.0, 1.6, -10.0), Vector3.FORWARD, 1, 4.0)
	_check(by_wall.ok and (by_wall.value["position"] as Vector3).z > -11.8, "a wall pulls the spot back in front of it")

	var under := DotSentry.find_spot(space, Vector3(15.0, 0.8, 3.0), Vector3.FORWARD, 1, 3.0)
	_check(not under.ok and under.error.detail == "headroom", "no room under a low ceiling", str(under.error.detail if not under.ok else ""))

	var off_edge := DotSentry.find_spot(space, Vector3(0.0, 1.6, 19.0), Vector3.BACK, 1, 4.0)
	_check(not off_edge.ok and off_edge.error.detail == "no_floor", "no floor past the edge")

	floor_body.queue_free()
	wall.queue_free()
	low.queue_free()
	_done()


func _test_damage_immunity() -> void:
	_section("damage immunity: per kind, wildcard, default none")

	var imm := DotDamageImmunity.new()
	_check(not imm.is_immune(5, &"fall"), "nobody is immune by default")
	imm.set_immune(5, [&"fall", "fire"])
	_check(imm.is_immune(5, &"fall") and imm.is_immune(5, &"fire"), "listed kinds are ignored (strings too)")
	_check(not imm.is_immune(5, &"bullet") and not imm.is_immune(6, &"fall"), "other kinds and other entities are not")
	imm.set_immune(5, [DotDamageImmunity.ALL])
	_check(imm.is_immune(5, &"bullet"), "the wildcard covers every kind")
	imm.set_immune(5, [])
	_check(not imm.is_immune(5, &"fall") and imm.kinds_of(5).is_empty(), "an empty list clears it")

	var rules := DotDamageRules.new()
	var res := DotDamageResolver.with_rules(rules)
	var fall := DotDamageType.new()
	fall.id = &"fall"
	var bullet := DotDamageType.new()
	bullet.id = &"bullet"
	var plain := res.resolve(DotDamage.make(0, 5, 30.0, fall))
	_check(not plain.refused, "no immunity object: damage lands")
	res.immunity = DotDamageImmunity.new()
	res.immunity.set_immune(5, [&"fall"])
	var blocked := res.resolve(DotDamage.make(0, 5, 30.0, fall))
	_check(blocked.refused and blocked.refusal.contains("immune"), "an immune victim refuses that kind")
	_check(not res.resolve(DotDamage.make(0, 5, 30.0, bullet)).refused, "the same victim still takes another kind")
	_check(not res.resolve(DotDamage.make(0, 6, 30.0, fall)).refused, "another victim still takes it")
