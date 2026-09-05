extends Node

## Exercises everything in dot-combat, offline and headless.
##
## [codeblock]
## godot --headless --path . res://examples/combat_selftest.tscn
## [/codeblock]
##
## Exits non-zero on any failure, so it works as a smoke test as-is.
##
## The cases that matter most are the ones where a mistake is a vulnerability or an
## invisible desync rather than a crash: a shot that damages through a wall, a spread
## pattern that differs between the client that predicted it and the server that
## re-ran it, a rewind that is never restored, and a client-reported muzzle that is
## taken at its word.

var _passed := 0
var _failed := 0
var _failures := PackedStringArray()

## Players built by [method _make_player], torn down between groups.
var _players: Array[Node3D] = []


## An arsenal whose shots are attributed to a chosen id rather than to its parent's
## instance id, which is what a real game does — a server keys damage on a session id.
class TestArsenal extends DotArsenal:
	var entity: int = 0

	func attacker_id() -> int:
		return entity


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	print("dot-combat self-test")
	print("")

	_test_damage_type()
	_test_recoil()
	_test_hit_groups()
	_test_health()
	_test_spread_determinism()
	_test_hitbox_geometry()
	_test_hitbox_precedence()
	_test_flat_trace()
	_test_arsenal_firing()
	_test_arsenal_reloading()
	_test_arsenal_switching()
	_test_resolver_rules()
	_test_manager_hitscan()
	_test_manager_walls()
	_test_manager_splash()
	_test_manager_validation()
	_test_lag_compensation()
	_test_net_sync()

	print("")
	print("%d passed, %d failed" % [_passed, _failed])

	for line in _failures:
		print("  FAIL  %s" % line)

	get_tree().quit(1 if _failed > 0 else 0)


# --- Assertions ------------------------------------------------------------

func _check(condition: bool, what: String, detail: String = "") -> bool:
	if condition:
		_passed += 1
		print("  ok    %s" % what)
	else:
		_failed += 1
		_failures.append(what if detail == "" else "%s — %s" % [what, detail])
		print("  FAIL  %s%s" % [what, "" if detail == "" else " — " + detail])
	return condition


func _close(a: float, b: float, what: String, epsilon: float = 0.01) -> bool:
	return _check(absf(a - b) <= epsilon, what, "%.4f vs %.4f" % [a, b])


func _group(title: String) -> void:
	print("")
	print("%s" % title)


# --- Fixtures --------------------------------------------------------------

func _bullet() -> DotDamageType:
	var type := DotDamageType.make(&"bullet", "Bullet")
	type.armour_share = 0.5
	type.armour_wear = 1.0
	type.falloff_start = 20.0
	type.falloff_end = 60.0
	type.falloff_floor = 0.5
	return type


func _rifle() -> DotWeapon:
	var weapon := DotWeapon.make(&"rifle", 25.0)
	weapon.fire_mode = DotWeapon.Fire.AUTO
	weapon.rpm = 600.0
	weapon.magazine = 30
	weapon.reserve = 90
	weapon.reload_sec = 2.0
	weapon.deploy_sec = 0.0
	weapon.holster_sec = 0.0
	weapon.spread_degrees = 0.0
	weapon.spread_bloom = 0.0
	weapon.damage_type = _bullet()
	weapon.max_range = 200.0
	return weapon


## A player: a body node with a [DotHealth] and a [DotHitboxSet] of three hitboxes.
##
## Built by hand rather than from a scene so the whole fixture is visible here — a
## self-test whose fixture is a .tscn is a self-test nobody can read.
func _make_player(position: Vector3, max_health: float = 100.0) -> Node3D:
	var body := Node3D.new()
	body.position = position

	var health := DotHealth.new()
	health.max_health = max_health
	health.regen_per_second = 0.0
	body.add_child(health)

	var set_node := DotHitboxSet.new()
	set_node.bounds_offset = Vector3(0.0, 0.9, 0.0)
	set_node.bounds_radius = 1.4

	var head := DotHitbox.new()
	head.group = DotHitGroup.HEAD
	head.shape = DotHitbox.Shape.SPHERE
	head.radius = 0.14
	head.position = Vector3(0.0, 1.62, 0.0)
	head.precedence = 10
	set_node.add_child(head)

	var chest := DotHitbox.new()
	chest.group = DotHitGroup.CHEST
	chest.shape = DotHitbox.Shape.CAPSULE
	chest.radius = 0.28
	chest.height = 1.1
	chest.position = Vector3(0.0, 1.0, 0.0)
	set_node.add_child(chest)

	var legs := DotHitbox.new()
	legs.group = DotHitGroup.LEG
	legs.shape = DotHitbox.Shape.CAPSULE
	legs.radius = 0.22
	legs.height = 0.9
	legs.position = Vector3(0.0, 0.45, 0.0)
	set_node.add_child(legs)

	body.add_child(set_node)
	add_child(body)
	set_node.refresh()

	_players.append(body)
	return body


func _health_of(body: Node3D) -> DotHealth:
	for child in body.get_children():
		if child is DotHealth:
			return child
	return null


func _hitboxes_of(body: Node3D) -> DotHitboxSet:
	for child in body.get_children():
		if child is DotHitboxSet:
			return child
	return null


func _clear_players() -> void:
	for body in _players:
		if is_instance_valid(body):
			body.queue_free()
			remove_child(body)
	_players.clear()


# --- Damage type -----------------------------------------------------------

func _test_damage_type() -> void:
	_group("damage types")

	var type := _bullet()

	_close(type.falloff_scale(0.0), 1.0, "full damage inside the falloff start")
	_close(type.falloff_scale(20.0), 1.0, "full damage at the falloff start")
	_close(type.falloff_scale(40.0), 0.75, "half way is half way down the curve")
	_close(type.falloff_scale(60.0), 0.5, "the floor at the falloff end")
	_close(type.falloff_scale(500.0), 0.5, "never below the floor")

	# A rewound hitbox can put the impact a few centimetres behind the muzzle. The
	# clamp is what stops that becoming more than full damage.
	_close(type.falloff_scale(-5.0), 1.0, "a negative distance is clamped, not extrapolated")

	var flat := DotDamageType.make(&"flat")
	_close(flat.falloff_scale(1000.0), 1.0, "no falloff configured means no falloff")


func _test_hit_groups() -> void:
	_group("hit groups")

	var groups := DotHitGroup.defaults()

	_close(groups.multiplier(DotHitGroup.HEAD), 4.0, "head multiplier")
	_close(groups.multiplier(DotHitGroup.LEG), 0.75, "leg multiplier")

	# The important one: a group nobody registered does normal damage. A typo costing
	# full damage is survivable; a typo costing none is a weapon that does nothing.
	_close(groups.multiplier(&"tail"), 1.0, "an unknown group does normal damage")
	_check(not groups.has(&"tail"), "an unknown group is still reported as unknown")


# --- Health ----------------------------------------------------------------

func _test_health() -> void:
	_group("health and armour")

	var health := DotHealth.new()
	health.max_health = 100.0
	health.max_armour = 100.0
	add_child(health)

	var type := _bullet()

	var d1 := DotDamage.make(1, 2, 40.0, type)
	health.apply(d1)
	_close(health.health, 60.0, "damage with no armour comes straight off health")
	_close(d1.health_lost, 40.0, "the event records what actually landed")
	_check(not d1.lethal, "a survivable hit is not lethal")

	health.add_armour(100.0)
	var d2 := DotDamage.make(1, 2, 40.0, type)
	health.apply(d2)
	_close(d2.armour_absorbed, 20.0, "armour absorbs its share")
	_close(health.armour, 80.0, "armour wears by the absorbed amount at wear 1")
	_close(health.health, 40.0, "the rest lands on health")

	# Armour that runs out mid-hit must not absorb more than it has.
	health.armour = 5.0
	var d3 := DotDamage.make(1, 2, 40.0, type)
	health.apply(d3)
	_close(d3.armour_absorbed, 5.0, "armour absorbs no more than it holds")
	_close(health.armour, 0.0, "and is then gone")

	var lethal := DotDamage.make(1, 2, 1000.0, type)
	health.apply(lethal)
	_check(lethal.lethal, "a fatal hit is marked lethal")
	_check(not health.alive, "and the victim is dead")
	_close(health.health, 0.0, "health floors at zero rather than going negative")

	var posthumous := DotDamage.make(1, 2, 10.0, type)
	health.apply(posthumous)
	_check(posthumous.refused, "damage to a corpse is refused")

	health.reset(100)
	_check(health.alive, "reset brings the entity back")
	_close(health.health, 100.0, "at full health")
	_close(health.armour, 0.0, "with no armour")

	# Spawn protection, which is counted in ticks so a replay reaches the same answer.
	health.spawn_protection_ticks = 60
	health.reset(1000)
	var protected := DotDamage.make(1, 2, 50.0, type)
	protected.tick = 1030
	health.apply(protected)
	_check(protected.refused, "spawn protection refuses damage")
	var after := DotDamage.make(1, 2, 50.0, type)
	after.tick = 1060
	health.apply(after)
	_check(not after.refused, "and expires on schedule")

	# Effective health: the number a bot uses to decide whether a burst kills.
	health.reset(2000)
	health.add_armour(100.0)
	var effective := health.effective_health(type)
	_close(effective, 200.0, "effective health with armour that holds")

	health.armour = 10.0
	_close(
		health.effective_health(type),
		110.0,
		"effective health when the armour runs out first"
	)

	# Regeneration is tick-based and must not start before its delay.
	#
	# Spawn protection is cleared first: it is still set from the case above, and
	# reset() re-arms it from the exported value every time — which is correct, and is
	# exactly why a test that forgets it measures a refusal instead of a regeneration.
	health.spawn_protection_ticks = 0
	health.reset(3000)
	health.regen_per_second = 10.0
	health.regen_delay_sec = 1.0
	health.set_tick_rate(60)
	var hurt := DotDamage.make(1, 2, 50.0, type)
	hurt.tick = 3000
	health.apply(hurt)
	health.tick(3030, 0.5)
	_close(health.health, 50.0, "regeneration waits out its delay")
	health.tick(3100, 1.0)
	_close(health.health, 60.0, "then restores at its stated rate")

	health.queue_free()
	remove_child(health)


# --- Spread ----------------------------------------------------------------

func _test_spread_determinism() -> void:
	_group("spread determinism")

	var forward := Vector3.FORWARD

	var a := DotSpread.cone(forward, 5.0, 42, 1000, 3, 0)
	var b := DotSpread.cone(forward, 5.0, 42, 1000, 3, 0)
	_check(a == b, "the same shot scatters identically", "%s vs %s" % [a, b])

	# The whole reason this exists: a client and a server must agree, and a
	# reconciling client replays the same tick many times.
	var replayed := DotSpread.cone(forward, 5.0, 42, 1000, 3, 0)
	_check(a == replayed, "and identically again on a replay")

	var next_tick := DotSpread.cone(forward, 5.0, 42, 1001, 3, 0)
	_check(a != next_tick, "a different tick scatters differently")

	var next_pellet := DotSpread.cone(forward, 5.0, 42, 1000, 3, 1)
	_check(a != next_pellet, "a different pellet scatters differently")

	var other_player := DotSpread.cone(forward, 5.0, 43, 1000, 3, 0)
	_check(a != other_player, "a different shooter scatters differently")

	_check(
		DotSpread.cone(forward, 0.0, 1, 1, 1, 1) == forward,
		"zero spread is exactly the aim direction"
	)

	# Every pellet must stay inside the stated cone, and the cone must actually be
	# filled — in angle *and* in azimuth.
	#
	# The azimuth half of this is not academic. DotSpread.unit() once shifted by 40
	# rather than 39, which left it 23 bits of a 24-bit range and so returned values in
	# [0, 0.5) only. Every pattern was a half-moon on one side of the aim, and the cone
	# reached 1/sqrt(2) of its stated angle. Nothing failed; the shotgun simply threw
	# its pellets to one side.
	var worst := 0.0
	var quadrants := [0, 0, 0, 0]
	var right := Vector3.RIGHT
	var up := Vector3.UP

	for pellet in range(600):
		var direction := DotSpread.cone(forward, 3.0, 7, 500, 1, pellet)
		worst = maxf(worst, rad_to_deg(forward.angle_to(direction)))

		var offset := direction - forward * direction.dot(forward)
		quadrants[
			(1 if offset.dot(right) > 0.0 else 0) + (2 if offset.dot(up) > 0.0 else 0)
		] += 1

	_check(worst <= 3.0001, "every pellet stays inside the cone", "worst %.4f deg" % worst)
	_check(
		worst > 2.9,
		"and the cone is filled to its stated angle",
		"worst %.4f deg" % worst
	)

	var thinnest := 600
	for count in quadrants:
		thinnest = mini(thinnest, int(count))
	_check(
		thinnest > 90,
		"and the pattern surrounds the aim rather than favouring one side",
		str(quadrants)
	)

	# Straight up is the case a fixed up-vector basis gets wrong: every shot fired at
	# the sky comes out along one line.
	var up_a := DotSpread.cone(Vector3.UP, 4.0, 1, 1, 1, 0)
	var up_b := DotSpread.cone(Vector3.UP, 4.0, 1, 1, 1, 1)
	_check(up_a != up_b, "shots fired straight up still scatter")
	_check(
		rad_to_deg(Vector3.UP.angle_to(up_a)) <= 4.0001,
		"and stay inside the cone when they do"
	)

	# The fixed pattern must put one pellet dead centre, or a shotgun cannot hit
	# anything at range.
	var centre := DotSpread.fixed_cone(forward, 5.0, 0, 9)
	_check(centre == forward, "a fixed pattern has a centre pellet")
	var ring := DotSpread.fixed_cone(forward, 5.0, 4, 9)
	_close(rad_to_deg(forward.angle_to(ring)), 5.0, "and puts the rest on the ring")


# --- Hitboxes --------------------------------------------------------------

func _test_hitbox_geometry() -> void:
	_group("hitbox geometry")

	var holder := Node3D.new()
	add_child(holder)

	var sphere := DotHitbox.new()
	sphere.shape = DotHitbox.Shape.SPHERE
	sphere.radius = 0.5
	sphere.position = Vector3(0.0, 0.0, -10.0)
	holder.add_child(sphere)

	var hit := sphere.intersect_ray(Vector3.ZERO, Vector3.FORWARD, 100.0)
	_check(hit.ok(), "a sphere in the way is hit")
	_close(hit.distance, 9.5, "at its near surface")

	var miss := sphere.intersect_ray(Vector3(2.0, 0.0, 0.0), Vector3.FORWARD, 100.0)
	_check(not miss.ok(), "and missed when the ray goes past it")

	var short := sphere.intersect_ray(Vector3.ZERO, Vector3.FORWARD, 5.0)
	_check(not short.ok(), "a ray that stops short does not reach it")

	# Point blank: a muzzle inside a hitbox is a shot, not a miss. Getting this wrong
	# is a shotgun pressed against a chest doing nothing.
	var inside := sphere.intersect_ray(Vector3(0.0, 0.0, -10.0), Vector3.FORWARD, 10.0)
	_check(inside.ok() and inside.distance == 0.0, "a ray starting inside hits at zero")

	var box := DotHitbox.new()
	box.shape = DotHitbox.Shape.BOX
	box.half_extents = Vector3(0.5, 0.5, 0.5)
	box.position = Vector3(0.0, 0.0, -20.0)
	holder.add_child(box)

	var box_hit := box.intersect_ray(Vector3.ZERO, Vector3.FORWARD, 100.0)
	_check(box_hit.ok(), "a box in the way is hit")
	_close(box_hit.distance, 19.5, "at its near face")
	_close(box_hit.normal.z, 1.0, "with the face normal pointing back at the shooter")

	var capsule := DotHitbox.new()
	capsule.shape = DotHitbox.Shape.CAPSULE
	capsule.radius = 0.3
	capsule.height = 2.0
	capsule.position = Vector3(0.0, 0.0, -30.0)
	holder.add_child(capsule)

	var mid := capsule.intersect_ray(Vector3.ZERO, Vector3.FORWARD, 100.0)
	_check(mid.ok(), "a capsule is hit through its body")
	_close(mid.distance, 29.7, "at the cylinder surface")

	var cap := capsule.intersect_ray(
		Vector3(0.0, 0.95, 0.0), Vector3.FORWARD, 100.0
	)
	_check(cap.ok(), "and through its cap")

	var over := capsule.intersect_ray(
		Vector3(0.0, 1.4, 0.0), Vector3.FORWARD, 100.0
	)
	_check(not over.ok(), "but not above it")

	# A rotated hitbox must be hit where it actually is, not where its untransformed
	# shape would be. Animated limbs are rotated constantly.
	capsule.rotation_degrees = Vector3(90.0, 0.0, 0.0)
	var rotated := capsule.intersect_ray(
		Vector3(0.0, 0.0, -30.9), Vector3.UP, 10.0
	)
	_check(rotated.ok(), "a rotated capsule is hit along its new axis")
	capsule.rotation_degrees = Vector3.ZERO

	# A scaled hitbox must report a distance in world metres. Reporting local units
	# puts every impact in the wrong place and breaks falloff.
	holder.scale = Vector3(2.0, 2.0, 2.0)
	var scaled := sphere.intersect_ray(Vector3.ZERO, Vector3.FORWARD, 100.0)
	_check(scaled.ok(), "a scaled hitbox is still hit")
	_close(scaled.distance, 19.0, "and reports world-space distance", 0.05)
	holder.scale = Vector3.ONE

	var disabled := DotHitbox.new()
	disabled.shape = DotHitbox.Shape.SPHERE
	disabled.radius = 1.0
	disabled.enabled = false
	disabled.position = Vector3(0.0, 0.0, -5.0)
	holder.add_child(disabled)
	_check(
		not disabled.intersect_ray(Vector3.ZERO, Vector3.FORWARD, 100.0).ok(),
		"a disabled hitbox is never hit"
	)

	_check(sphere.overlaps_sphere(Vector3(0.0, 0.0, -10.4), 0.1), "sphere overlap hits")
	_check(
		not sphere.overlaps_sphere(Vector3(0.0, 0.0, -12.0), 0.5),
		"and misses when it is out of reach"
	)

	holder.queue_free()
	remove_child(holder)


func _test_hitbox_precedence() -> void:
	_group("hitbox precedence")

	var body := _make_player(Vector3(0.0, 0.0, -10.0))
	var set_node := _hitboxes_of(body)

	# Head height, straight on. The head sphere and the chest capsule both lie along
	# this ray at nearly the same distance, and the head must win — a tie decided by
	# child order is a game where headshots land about half the time.
	var head := set_node.intersect_ray(
		Vector3(0.0, 1.62, 0.0), Vector3.FORWARD, 100.0
	)
	_check(head.ok(), "the head is reachable")
	_check(head.group == DotHitGroup.HEAD, "and wins at head height", String(head.group))

	var chest := set_node.intersect_ray(
		Vector3(0.0, 1.0, 0.0), Vector3.FORWARD, 100.0
	)
	_check(chest.group == DotHitGroup.CHEST, "the chest is hit at chest height")

	var legs := set_node.intersect_ray(
		Vector3(0.0, 0.45, 0.0), Vector3.FORWARD, 100.0
	)
	_check(legs.group == DotHitGroup.LEG, "the legs are hit at leg height")

	var over := set_node.intersect_ray(
		Vector3(0.0, 3.0, 0.0), Vector3.FORWARD, 100.0
	)
	_check(not over.ok(), "a shot over the head misses the whole set")

	_check(set_node.hitboxes().size() == 3, "the set collected every hitbox")
	_check(set_node.entity_owner() == body, "and knows which entity it belongs to")

	# The bounds sphere is a rejection, not an answer. Too small and it silently
	# drops hits, which is why it is tested rather than trusted.
	set_node.bounds_radius = 0.05
	_check(
		not set_node.intersect_ray(Vector3(0.0, 1.0, 0.0), Vector3.FORWARD, 100.0).ok(),
		"a bounds sphere that is too small does reject hits"
	)
	set_node.bounds_radius = 1.4

	_clear_players()


# --- Tracing ---------------------------------------------------------------

func _test_flat_trace() -> void:
	_group("flat trace")

	var trace := DotTraceFlat.with_floor(0.0)

	var down := trace.ray(Vector3(0.0, 5.0, 0.0), Vector3.DOWN, 100.0)
	_check(down.ok() and down.blocked, "the floor blocks a downward ray")
	_close(down.distance, 5.0, "at the right distance")

	var up := trace.ray(Vector3(0.0, 5.0, 0.0), Vector3.UP, 100.0)
	_check(not up.ok(), "and not an upward one")

	trace.add_box(AABB(Vector3(-1.0, 0.0, -6.0), Vector3(2.0, 3.0, 0.5)))

	var wall := trace.ray(Vector3(0.0, 1.5, 0.0), Vector3.FORWARD, 100.0)
	_check(wall.ok() and wall.blocked, "a box blocks a ray")
	_close(wall.distance, 5.5, "at its near face")

	_check(
		not trace.line_of_sight(Vector3(0.0, 1.5, 0.0), Vector3(0.0, 1.5, -10.0)),
		"line of sight is broken by the box"
	)
	_check(
		trace.line_of_sight(Vector3(0.0, 4.0, 0.0), Vector3(0.0, 4.0, -10.0)),
		"and clear over the top of it"
	)

	var walled := DotTraceFlat.new()
	walled.add_wall(Vector3(-3.0, 0.0, -4.0), Vector3(3.0, 0.0, -4.0), 3.0, 0.4)
	var through := walled.ray(Vector3(0.0, 1.0, 0.0), Vector3.FORWARD, 100.0)
	_check(through.ok(), "a wall built from two points blocks a ray")
	_close(through.distance, 3.8, "on the near side of its thickness")


# --- Arsenal ---------------------------------------------------------------

func _test_arsenal_firing() -> void:
	_group("arsenal: firing")

	var arsenal := DotArsenal.new()
	arsenal.tick_rate = 60
	add_child(arsenal)

	var rifle := _rifle()
	arsenal.give(rifle, 1)
	arsenal.select(1, 0)

	var command := DotCombatCommand.new()
	command.set_button(DotCombatCommand.BUTTON_ATTACK, true)

	var shots := arsenal.simulate_tick(0, 1.0 / 60.0, command)
	_check(shots.size() == 1, "an automatic weapon fires on the first tick")
	_check(arsenal.current().ammo == 29, "and spends a round")

	# 600 rpm at 60 Hz is a shot every 6 ticks. Firing on tick 1 would be a weapon
	# with no rate of fire at all.
	var immediate := arsenal.simulate_tick(1, 1.0 / 60.0, command)
	_check(immediate.is_empty(), "and not again before its interval")

	var later := arsenal.simulate_tick(6, 1.0 / 60.0, command)
	_check(later.size() == 1, "then again on schedule")

	# Semi-automatic must be edge-triggered. Reading the level makes it automatic for
	# anyone holding the button.
	var pistol := DotWeapon.make(&"pistol", 30.0)
	pistol.fire_mode = DotWeapon.Fire.SEMI
	pistol.rpm = 600.0
	pistol.magazine = 12
	pistol.deploy_sec = 0.0
	pistol.holster_sec = 0.0
	arsenal.give(pistol, 2)
	arsenal.select(2, 10)

	# The trigger is released first. It has been held since the automatic weapon
	# above, and a semi-automatic that fired on a trigger already down would be an
	# automatic one — which is the behaviour being tested, from the other side.
	var idle := DotCombatCommand.new()
	arsenal.simulate_tick(10, 1.0 / 60.0, idle)

	var held := arsenal.simulate_tick(11, 1.0 / 60.0, command)
	_check(held.size() == 1, "a semi-automatic fires once on the press")
	var still_held := arsenal.simulate_tick(30, 1.0 / 60.0, command)
	_check(still_held.is_empty(), "and not again while the trigger is held")

	arsenal.simulate_tick(31, 1.0 / 60.0, idle)
	var repressed := arsenal.simulate_tick(32, 1.0 / 60.0, command)
	_check(repressed.size() == 1, "but does on the next press")

	# A burst fires its count and then stops, even while held.
	var burst := DotWeapon.make(&"burst", 20.0)
	burst.fire_mode = DotWeapon.Fire.BURST
	burst.burst_count = 3
	burst.burst_rpm = 1200.0
	burst.rpm = 300.0
	burst.magazine = 30
	burst.deploy_sec = 0.0
	burst.holster_sec = 0.0
	arsenal.give(burst, 3)
	arsenal.select(3, 100)
	arsenal.simulate_tick(100, 1.0 / 60.0, idle)

	var fired := 0
	for tick in range(101, 141):
		fired += arsenal.simulate_tick(tick, 1.0 / 60.0, command).size()
	_check(fired == 3, "a burst fires exactly its count while held", "fired %d" % fired)

	# Pellets: one round, several projectiles.
	var shotgun := DotWeapon.make(&"shotgun", 10.0)
	shotgun.pellets = 8
	shotgun.fire_mode = DotWeapon.Fire.SEMI
	shotgun.spread_degrees = 5.0
	shotgun.magazine = 6
	shotgun.deploy_sec = 0.0
	shotgun.holster_sec = 0.0
	arsenal.give(shotgun, 4)
	arsenal.select(4, 200)
	arsenal.simulate_tick(200, 1.0 / 60.0, idle)
	var blast := arsenal.simulate_tick(201, 1.0 / 60.0, command)
	_check(blast.size() == 1, "a shotgun fires one shot")
	_check(blast[0].pellets.size() == 8, "made of eight pellets")
	_check(arsenal.state_at(4).ammo == 5, "costing one round")

	arsenal.queue_free()
	remove_child(arsenal)


func _test_arsenal_reloading() -> void:
	_group("arsenal: reloading")

	var arsenal := DotArsenal.new()
	arsenal.tick_rate = 60
	add_child(arsenal)

	var rifle := _rifle()
	rifle.auto_reload = false
	arsenal.give(rifle, 1)
	arsenal.select(1, 0)

	var state := arsenal.current()
	state.ammo = 10

	var reload := DotCombatCommand.new()
	reload.set_button(DotCombatCommand.BUTTON_RELOAD, true)

	arsenal.simulate_tick(0, 1.0 / 60.0, reload)
	_check(state.is_reloading(1), "the reload starts")

	var idle := DotCombatCommand.new()
	for tick in range(1, 119):
		arsenal.simulate_tick(tick, 1.0 / 60.0, idle)
	_check(state.ammo == 10, "and takes its full duration")

	arsenal.simulate_tick(120, 1.0 / 60.0, idle)
	_check(state.ammo == 30, "then fills the magazine")
	_check(state.reserve == 70, "from the reserve")

	# Firing during a reload must be refused, or the reload duration means nothing.
	var attack := DotCombatCommand.new()
	attack.set_button(DotCombatCommand.BUTTON_ATTACK, true)
	state.ammo = 5
	arsenal.simulate_tick(200, 1.0 / 60.0, reload)
	var during := arsenal.simulate_tick(210, 1.0 / 60.0, attack)
	_check(during.is_empty(), "firing during a reload is refused")

	# A per-round reload is interruptible by firing, which is the whole point.
	var pump := DotWeapon.make(&"pump", 60.0)
	pump.fire_mode = DotWeapon.Fire.SEMI
	pump.magazine = 6
	pump.reserve = 24
	pump.reload_per_round = true
	pump.reload_sec = 0.4
	pump.reload_start_sec = 0.0
	pump.rpm = 90.0
	pump.deploy_sec = 0.0
	pump.holster_sec = 0.0
	pump.auto_reload = false
	arsenal.give(pump, 2)
	arsenal.select(2, 300)

	var pump_state := arsenal.state_at(2)
	pump_state.ammo = 0

	arsenal.simulate_tick(300, 1.0 / 60.0, reload)
	for tick in range(301, 350):
		arsenal.simulate_tick(tick, 1.0 / 60.0, idle)
	_check(pump_state.ammo >= 2, "a per-round reload loads shells one at a time",
		"ammo %d" % pump_state.ammo)
	_check(pump_state.ammo < 6, "and is not finished yet", "ammo %d" % pump_state.ammo)

	var loaded := pump_state.ammo
	arsenal.simulate_tick(350, 1.0 / 60.0, attack)
	_check(
		pump_state.ammo == loaded - 1,
		"firing interrupts it and spends what was loaded"
	)
	_check(not pump_state.is_reloading(351), "leaving the reload cancelled")

	# Auto-reload on an empty magazine.
	var auto := _rifle()
	auto.auto_reload = true
	arsenal.give(auto, 3)
	arsenal.select(3, 400)
	var auto_state := arsenal.state_at(3)
	auto_state.ammo = 1
	arsenal.simulate_tick(400, 1.0 / 60.0, attack)
	_check(auto_state.ammo == 0, "the last round is fired")
	arsenal.simulate_tick(401, 1.0 / 60.0, idle)
	_check(auto_state.is_reloading(402), "and an empty magazine reloads itself")

	arsenal.queue_free()
	remove_child(arsenal)


func _test_arsenal_switching() -> void:
	_group("arsenal: switching")

	var arsenal := DotArsenal.new()
	arsenal.tick_rate = 60
	add_child(arsenal)

	var first := _rifle()
	first.holster_sec = 0.2
	first.deploy_sec = 0.2

	var second := DotWeapon.make(&"smg", 15.0)
	second.magazine = 25
	second.holster_sec = 0.2
	second.deploy_sec = 0.2
	second.rpm = 900.0
	second.damage_type = _bullet()

	arsenal.give(first, 1)
	arsenal.give(second, 2)
	arsenal.select(1, 0)
	_check(arsenal.current_slot() == 1, "the first weapon is held")

	var pick := DotCombatCommand.new()
	pick.slot = 2
	arsenal.simulate_tick(100, 1.0 / 60.0, pick)
	_check(arsenal.current_slot() == 1, "a switch does not complete instantly")
	_check(arsenal.is_switching(), "it holsters first")

	var idle := DotCombatCommand.new()
	for tick in range(101, 125):
		arsenal.simulate_tick(tick, 1.0 / 60.0, idle)
	_check(arsenal.current_slot() == 2, "then completes")

	# Deploy: the new weapon cannot fire immediately.
	var attack := DotCombatCommand.new()
	attack.set_button(DotCombatCommand.BUTTON_ATTACK, true)
	var early := arsenal.simulate_tick(115, 1.0 / 60.0, attack)
	_check(early.is_empty(), "and cannot fire while deploying")

	for tick in range(126, 160):
		arsenal.simulate_tick(tick, 1.0 / 60.0, idle)
	var ready := arsenal.simulate_tick(160, 1.0 / 60.0, attack)
	_check(ready.size() == 1, "then fires normally")

	# Last-weapon swap.
	var last := DotCombatCommand.new()
	last.set_button(DotCombatCommand.BUTTON_LAST, true)
	arsenal.simulate_tick(200, 1.0 / 60.0, last)
	for tick in range(201, 240):
		arsenal.simulate_tick(tick, 1.0 / 60.0, idle)
	_check(arsenal.current_slot() == 1, "the last-weapon button goes back")

	# Cycling.
	var next := DotCombatCommand.new()
	next.set_button(DotCombatCommand.BUTTON_NEXT, true)
	arsenal.simulate_tick(300, 1.0 / 60.0, next)
	for tick in range(301, 340):
		arsenal.simulate_tick(tick, 1.0 / 60.0, idle)
	_check(arsenal.current_slot() == 2, "next cycles forward")

	# Shared ammunition pools: two weapons, one reserve.
	var pooled_a := DotWeapon.make(&"pooled_a", 10.0)
	pooled_a.ammo_type = &"shared"
	pooled_a.reserve = 10
	pooled_a.reserve_max = 60
	var pooled_b := DotWeapon.make(&"pooled_b", 10.0)
	pooled_b.ammo_type = &"shared"
	pooled_b.reserve = 10
	pooled_b.reserve_max = 60

	arsenal.give(pooled_a, 5)
	arsenal.give(pooled_b, 6)
	var taken := arsenal.add_ammo(&"shared", 30)
	_check(taken == 30, "ammunition is spread across a shared pool", "took %d" % taken)

	var overflow := arsenal.add_ammo(&"shared", 10000)
	_check(overflow < 10000, "and a pickup nobody can hold is not silently eaten",
		"took %d" % overflow)

	arsenal.queue_free()
	remove_child(arsenal)


# --- Rules -----------------------------------------------------------------

func _test_resolver_rules() -> void:
	_group("damage rules")

	var rules := DotDamageRules.new()
	rules.friendly_fire = false
	rules.self_damage = true

	var resolver := DotDamageResolver.with_rules(rules)
	var teams := {1: 1, 2: 1, 3: 2, 4: 0, 5: 0}
	resolver.team_of = func(id: int) -> int: return int(teams.get(id, 0))

	var type := _bullet()

	var friendly := DotDamage.make(1, 2, 50.0, type)
	resolver.resolve(friendly)
	_check(friendly.refused, "friendly fire off refuses damage to a team-mate")

	var enemy := DotDamage.make(1, 3, 50.0, type)
	resolver.resolve(enemy)
	_check(not enemy.refused, "and permits it to an enemy")

	# The one that silently breaks a free-for-all: two players with no team must not
	# be treated as allies because their team ids are both zero.
	var unassigned := DotDamage.make(4, 5, 50.0, type)
	resolver.resolve(unassigned)
	_check(not unassigned.refused, "two unassigned players are not team-mates")

	rules.friendly_fire = true
	rules.friendly_scale = 0.5
	var scaled := DotDamage.make(1, 2, 50.0, type)
	resolver.resolve(scaled)
	_close(scaled.amount, 25.0, "friendly fire on scales instead of refusing")

	rules.friendly_reflect = 0.5
	scaled.health_lost = 25.0
	var back := resolver.reflection(scaled)
	_check(back != null, "a reflection is produced")
	_close(back.amount, 12.5, "at the configured fraction of what landed")
	_check(back.attacker == 2 and back.victim == 1, "and points the other way")

	rules.self_damage = false
	var suicide := DotDamage.make(1, 1, 50.0, type)
	resolver.resolve(suicide)
	_check(suicide.refused, "self damage off refuses it")

	rules.self_damage = true
	var rocket_jump := DotDamage.make(1, 1, 50.0, type)
	resolver.resolve(rocket_jump)
	_close(rocket_jump.amount, 25.0, "self damage on applies the type's own scale")

	# Hit groups and falloff compose, and the clamp is last.
	rules.maximum = 100.0
	var headshot := DotDamage.make(1, 3, 50.0, type)
	headshot.hit_group = DotHitGroup.HEAD
	resolver.resolve(headshot)
	_close(headshot.amount, 100.0, "a headshot is clamped by the stated maximum")

	rules.maximum = 0.0
	var far := DotDamage.make(1, 3, 50.0, type)
	far.distance = 60.0
	resolver.resolve(far)
	_close(far.amount, 25.0, "falloff applies at range")

	rules.minimum = 30.0
	var grazing := DotDamage.make(1, 3, 50.0, type)
	grazing.distance = 60.0
	resolver.resolve(grazing)
	_check(grazing.refused, "damage under the minimum is refused")
	rules.minimum = 0.0

	# The scaling trace is what makes a surprising number explainable.
	var traced := DotDamage.make(1, 3, 50.0, type)
	traced.hit_group = DotHitGroup.HEAD
	traced.distance = 40.0
	resolver.resolve(traced)
	var scales: Array = traced.context.get("scales", [])
	_check(scales.size() >= 2, "every scale is recorded", str(scales))

	# The game-mode hook can veto.
	resolver.adjust = func(damage: DotDamage) -> void:
		if damage.victim == 3:
			damage.refuse("test hook")
	var vetoed := DotDamage.make(1, 3, 50.0, type)
	resolver.resolve(vetoed)
	_check(vetoed.refused and vetoed.refusal == "test hook", "and a hook can veto")
	resolver.adjust = Callable()


# --- Manager ---------------------------------------------------------------

func _make_manager(trace: DotTrace, rules: DotDamageRules) -> DotCombatManager:
	var manager := DotCombatManager.new()
	manager.register_service = false
	manager.trace = trace
	manager.rules = rules
	manager.config = DotCombatConfig.new()
	manager.config.tick_rate = 60
	add_child(manager)
	return manager


func _test_manager_hitscan() -> void:
	_group("manager: hitscan")

	var trace := DotTraceFlat.with_floor(0.0)
	var manager := _make_manager(trace, DotDamageRules.new())

	var victim := _make_player(Vector3(0.0, 0.0, -10.0))
	_hitboxes_of(victim).register_with(manager, 2)
	manager.register_health(2, _health_of(victim))

	var kills: Array[int] = []
	manager.entity_killed.connect(func(id: int, _d: DotDamage) -> void: kills.append(id))

	var weapon := _rifle()

	var shot := DotShot.make(weapon, 1, 100, 1)
	shot.origin = Vector3(0.0, 1.0, 0.0)
	shot.direction = Vector3.FORWARD
	shot.tick = 100
	shot.scatter()
	manager.resolve_shot(shot)

	_check(shot.damages.size() == 1, "a shot at a player produces one damage event")
	_check(shot.damages[0].victim == 2, "attributed to the right victim")
	_check(
		shot.damages[0].hit_group == DotHitGroup.CHEST,
		"in the right hit group",
		String(shot.damages[0].hit_group)
	)
	_close(_health_of(victim).health, 75.0, "and takes health off")
	_check(shot.impacts.size() == 1, "the impact point is recorded for effects")

	# A headshot goes through the group multiplier.
	var head_shot := DotShot.make(weapon, 1, 101, 2)
	head_shot.origin = Vector3(0.0, 1.62, 0.0)
	head_shot.direction = Vector3.FORWARD
	head_shot.tick = 101
	head_shot.scatter()
	manager.resolve_shot(head_shot)
	_check(head_shot.damages[0].is_headshot(), "a shot at the head is a headshot")
	_close(head_shot.damages[0].amount, 100.0, "doing the multiplied amount")
	_check(kills.size() == 1 and kills[0] == 2, "and the kill is reported")
	_check(not _health_of(victim).alive, "the victim is dead")

	# A shot at nothing must still report an endpoint, or there is no tracer.
	var miss := DotShot.make(weapon, 1, 102, 3)
	miss.origin = Vector3(0.0, 1.0, 0.0)
	miss.direction = Vector3.RIGHT
	miss.tick = 102
	miss.scatter()
	manager.resolve_shot(miss)
	_check(miss.damages.is_empty(), "a miss does no damage")
	_check(miss.impacts.size() == 1, "but still reports where it ended")

	# A shooter cannot shoot themselves with a hitscan weapon by aiming at their feet.
	var shooter := _make_player(Vector3(0.0, 0.0, 0.0))
	_hitboxes_of(shooter).register_with(manager, 1)
	manager.register_health(1, _health_of(shooter))

	var point_blank := DotShot.make(weapon, 1, 103, 4)
	point_blank.origin = Vector3(0.0, 1.6, 0.0)
	point_blank.direction = Vector3.DOWN
	point_blank.tick = 103
	point_blank.scatter()
	manager.resolve_shot(point_blank)
	_check(
		point_blank.damages.is_empty(),
		"a hitscan shot never hits its own shooter"
	)

	manager.queue_free()
	remove_child(manager)
	_clear_players()


func _test_manager_walls() -> void:
	_group("manager: walls")

	var trace := DotTraceFlat.with_floor(0.0)
	# A wall between the shooter and the victim, at 5 m.
	trace.add_box(AABB(Vector3(-3.0, 0.0, -5.2), Vector3(6.0, 3.0, 0.4)))

	var manager := _make_manager(trace, DotDamageRules.new())

	var victim := _make_player(Vector3(0.0, 0.0, -10.0))
	_hitboxes_of(victim).register_with(manager, 2)
	manager.register_health(2, _health_of(victim))

	var shot := DotShot.make(_rifle(), 1, 100, 1)
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

	var second := DotShot.make(_rifle(), 1, 101, 2)
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


## A hitbox surface at exactly the same distance as a wall face.
##
## Not a contrived case: it is a player hugging cover, and it is the one the tie-break
## in [method DotTrace.ray] exists for. Giving the tie to the hitbox is how someone
## gets shot through the wall they are pressed against, and the numbers here are
## chosen so both distances come out as exactly 9.0 rather than as two values that
## happen to be close.
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

	var shot := DotShot.make(_rifle(), 1, 100, 1)
	shot.origin = Vector3.ZERO
	shot.direction = Vector3.FORWARD
	shot.tick = 100
	shot.scatter()
	manager.resolve_shot(shot)
	_check(shot.damages.is_empty(), "so a player flush against cover is not shot through it")

	manager.queue_free()
	remove_child(manager)
	_clear_players()


func _test_manager_splash() -> void:
	_group("manager: splash")

	var trace := DotTraceFlat.with_floor(0.0)
	var rules := DotDamageRules.new()
	rules.self_damage = true
	var manager := _make_manager(trace, rules)

	var near := _make_player(Vector3(1.0, 0.0, -10.0))
	_hitboxes_of(near).register_with(manager, 2)
	manager.register_health(2, _health_of(near))

	var far := _make_player(Vector3(4.5, 0.0, -10.0))
	_hitboxes_of(far).register_with(manager, 3)
	manager.register_health(3, _health_of(far))

	var rocket := DotWeapon.make(&"rocket", 0.0)
	rocket.fire_mode = DotWeapon.Fire.SEMI
	rocket.splash_radius = 5.0
	rocket.splash_damage = 100.0
	rocket.splash_hurts_owner = true
	rocket.magazine = 4
	rocket.max_range = 100.0

	var splash_type := DotDamageType.make(&"blast")
	splash_type.uses_hit_groups = false
	splash_type.armour_share = 0.0
	splash_type.self_scale = 0.5
	rocket.damage_type = splash_type
	rocket.splash_type = splash_type

	var shot := DotShot.make(rocket, 1, 100, 1)
	shot.origin = Vector3(0.0, 1.0, 0.0)
	shot.direction = Vector3(0.0, -0.0995, -0.995).normalized()
	shot.tick = 100
	shot.scatter()
	manager.resolve_shot(shot)

	var near_damage := 100.0 - _health_of(near).health
	var far_damage := 100.0 - _health_of(far).health

	_check(near_damage > 0.0, "splash reaches a nearby player", "%.1f" % near_damage)
	_check(far_damage > 0.0, "and a farther one", "%.1f" % far_damage)
	_check(
		near_damage > far_damage,
		"doing less at a distance",
		"%.1f near vs %.1f far" % [near_damage, far_damage]
	)

	# Splash must not travel through a wall.
	var walled := DotTraceFlat.with_floor(0.0)
	walled.add_box(AABB(Vector3(2.0, 0.0, -12.0), Vector3(0.4, 3.0, 4.0)))
	var manager2 := _make_manager(walled, rules)

	var sheltered := _make_player(Vector3(4.0, 0.0, -10.0))
	_hitboxes_of(sheltered).register_with(manager2, 4)
	manager2.register_health(4, _health_of(sheltered))

	var blast := DotShot.make(rocket, 1, 101, 2)
	blast.origin = Vector3(0.0, 1.0, 0.0)
	blast.direction = Vector3(0.0, -0.0995, -0.995).normalized()
	blast.tick = 101
	blast.impacts = [Vector3(0.0, 0.0, -10.0)]
	blast.pellets = [blast.direction]
	manager2.resolve_shot(blast)
	_close(
		_health_of(sheltered).health,
		100.0,
		"splash does not travel through a wall"
	)

	manager.queue_free()
	remove_child(manager)
	manager2.queue_free()
	remove_child(manager2)
	_clear_players()


func _test_manager_validation() -> void:
	_group("manager: validating what a client claims")

	var trace := DotTraceFlat.with_floor(0.0)
	var manager := _make_manager(trace, DotDamageRules.new())
	manager.config.max_origin_error = 1.0
	manager.config.shots_per_second = 10.0

	var victim := _make_player(Vector3(0.0, 0.0, -10.0))
	_hitboxes_of(victim).register_with(manager, 2)
	manager.register_health(2, _health_of(victim))

	var shooter := _make_player(Vector3(0.0, 0.0, 0.0))
	_hitboxes_of(shooter).register_with(manager, 1)
	manager.register_health(1, _health_of(shooter))
	manager.set_authoritative_origin(1, Vector3(0.0, 1.0, 0.0))

	# A client claiming a muzzle on the far side of the level is claiming a shot
	# through every wall between here and there.
	var teleported := DotShot.make(_rifle(), 1, 100, 1)
	teleported.origin = Vector3(0.0, 1.0, -9.0)
	teleported.direction = Vector3.FORWARD
	teleported.tick = 100
	teleported.scatter()
	manager.resolve_shot(teleported)
	_close(
		teleported.origin.z,
		0.0,
		"an impossible muzzle is relocated to where the server believes the shooter is"
	)

	# The rate limit catches a client sending a thousand fire commands a tick.
	var refusals: Array[String] = []
	manager.shot_refused.connect(
		func(_s: DotShot, reason: String) -> void: refusals.append(reason)
	)

	for i in range(40):
		var spam := DotShot.make(_rifle(), 1, 200 + i, i)
		spam.origin = Vector3(0.0, 1.0, 0.0)
		spam.direction = Vector3.FORWARD
		spam.tick = 200 + i
		spam.scatter()
		manager.resolve_shot(spam)

	_check(refusals.size() > 0, "a flood of shots is rate limited",
		"%d refused" % refusals.size())

	# A dead player cannot shoot.
	_health_of(shooter).alive = false
	var posthumous := DotShot.make(_rifle(), 1, 400, 1)
	posthumous.origin = Vector3(0.0, 1.0, 0.0)
	posthumous.direction = Vector3.FORWARD
	posthumous.tick = 400
	posthumous.scatter()
	manager.resolve_shot(posthumous)
	_check(posthumous.damages.is_empty(), "a dead player's shots are refused")

	# A client instance traces but never applies damage.
	var client := _make_manager(DotTraceFlat.with_floor(0.0), DotDamageRules.new())
	client.is_authority = false
	var target := _make_player(Vector3(0.0, 0.0, -10.0))
	_hitboxes_of(target).register_with(client, 5)
	client.register_health(5, _health_of(target))

	var predicted := DotShot.make(_rifle(), 6, 500, 1)
	predicted.origin = Vector3(0.0, 1.0, 0.0)
	predicted.direction = Vector3.FORWARD
	predicted.tick = 500
	predicted.scatter()
	client.resolve_shot(predicted)
	_check(predicted.damages.size() == 1, "a client still traces its own shot")
	_close(
		_health_of(target).health,
		100.0,
		"but never applies damage"
	)

	manager.queue_free()
	remove_child(manager)
	client.queue_free()
	remove_child(client)
	_clear_players()


func _test_lag_compensation() -> void:
	_group("lag compensation")

	var trace := DotTraceFlat.with_floor(0.0)
	var manager := _make_manager(trace, DotDamageRules.new())
	manager.config.lag_compensation = true
	manager.config.max_rewind_ms = 200.0

	var victim := _make_player(Vector3(0.0, 0.0, -10.0))
	_hitboxes_of(victim).register_with(manager, 2)
	manager.register_health(2, _health_of(victim))

	# The bridge a game writes. Captured Arrays rather than counters: a GDScript
	# lambda captures locals by value, so an incremented int stays zero outside the
	# lambda and the assertion reports a failure for a hook that fired perfectly.
	var rewinds: Array[float] = []
	var restores: Array[int] = []

	manager.rewind_fn = func(tick: float) -> void:
		rewinds.append(tick)
		victim.position = Vector3(0.0, 0.0, -10.0)
	manager.restore_fn = func() -> void:
		restores.append(1)
		victim.position = Vector3(3.0, 0.0, -10.0)

	# The victim has since moved out of the line of fire; the shooter saw them in it.
	victim.position = Vector3(3.0, 0.0, -10.0)

	var shot := DotShot.make(_rifle(), 1, 100, 1)
	shot.origin = Vector3(0.0, 1.0, 0.0)
	shot.direction = Vector3.FORWARD
	shot.tick = 100
	shot.scatter()
	manager.resolve_shot(shot, 94.0)

	_check(rewinds.size() == 1, "the world is rewound once per shot")
	_check(restores.size() == 1, "and restored exactly once")
	_check(shot.damages.size() == 1, "the shot hits where the shooter saw them")
	_close(victim.position.x, 3.0, "and the world is left where it was")

	# The rewind cap is a cheat bound: a client asking to go back further than the
	# window must be clamped, not obeyed.
	rewinds.clear()
	restores.clear()
	var ancient := DotShot.make(_rifle(), 1, 1000, 2)
	ancient.origin = Vector3(0.0, 1.0, 0.0)
	ancient.direction = Vector3.FORWARD
	ancient.tick = 1000
	ancient.scatter()
	manager.resolve_shot(ancient, 0.0)
	_check(rewinds.size() == 1, "a shot with an ancient view tick still rewinds")
	_check(
		rewinds[0] >= 1000.0 - 0.2 * 60.0 - 0.001,
		"clamped to the configured window",
		"rewound to %.1f" % rewinds[0]
	)

	# A refused shot must still not leak a rewind.
	rewinds.clear()
	restores.clear()
	manager.config.shots_per_second = 1.0
	for i in range(6):
		var spam := DotShot.make(_rifle(), 1, 2000 + i, i)
		spam.origin = Vector3(0.0, 1.0, 0.0)
		spam.direction = Vector3.FORWARD
		spam.tick = 2000 + i
		spam.scatter()
		manager.resolve_shot(spam, float(2000 + i - 6))
	_check(
		rewinds.size() == restores.size(),
		"every rewind is restored, including on refused shots",
		"%d rewinds, %d restores" % [rewinds.size(), restores.size()]
	)

	manager.queue_free()
	remove_child(manager)
	_clear_players()


# --- Net sync --------------------------------------------------------------

## A stand-in for the DotNetBehaviour a game writes. Plain properties, because that
## is all [DotCombatNetSync] requires — the point of the bridge is that dot-combat
## never names a dot-net type.
class FakeBehaviour extends Object:
	var net_health: int = 0
	var net_armour: int = 0
	var net_alive: bool = false
	var net_slot: int = 0
	var net_ammo: int = 0
	var net_reserve: int = 0


func _test_net_sync() -> void:
	_group("net sync")

	var specs := DotCombatNetSync.specs()
	_check(specs.size() == 6, "the bridge describes every replicated property")

	var owner_only := 0
	for spec in specs:
		if bool(spec["owner_only"]):
			owner_only += 1
	_check(owner_only == 2, "ammunition is owner-only, so opponents cannot read it")

	var health := DotHealth.new()
	health.max_health = 100.0
	add_child(health)
	health.health = 73.4
	health.armour = 12.0

	var arsenal := DotArsenal.new()
	arsenal.tick_rate = 60
	add_child(arsenal)
	arsenal.give(_rifle(), 1)
	arsenal.select(1, 0)

	var behaviour := FakeBehaviour.new()
	DotCombatNetSync.pull(health, arsenal, behaviour)

	# Ceil, not round: a player on 0.4 health is alive, and rounding to zero shows a
	# corpse's health bar on someone still shooting back.
	_check(behaviour.net_health == 74, "health rounds up", str(behaviour.net_health))
	_check(behaviour.net_alive, "alive replicates")
	_check(behaviour.net_slot == 1, "the held slot replicates")
	_check(behaviour.net_ammo == 30, "and the magazine")

	health.health = 0.4
	DotCombatNetSync.pull(health, arsenal, behaviour)
	_check(behaviour.net_health == 1, "a player on a sliver of health is not shown dead")

	var receiver_health := DotHealth.new()
	receiver_health.max_health = 100.0
	add_child(receiver_health)
	DotCombatNetSync.push(behaviour, receiver_health, null)
	_close(receiver_health.health, 1.0, "received health is written straight through")

	behaviour.free()
	health.queue_free()
	remove_child(health)
	receiver_health.queue_free()
	remove_child(receiver_health)
	arsenal.queue_free()
	remove_child(arsenal)


func _test_recoil() -> void:
	print("recoil")
	var weapon := DotWeapon.new()
	weapon.recoil_pitch = 2.0
	weapon.recoil_yaw = 0.5
	weapon.recoil_recovery = 4.0

	var recoil := DotRecoil.new()
	recoil.kick(weapon)
	_check(recoil.offset().x == 2.0 and recoil.offset().y == 0.5, "a shot kicks the view by the weapon's numbers", str(recoil.offset()))
	recoil.kick(weapon)
	_check(recoil.offset().x == 4.0 and recoil.offset().y == 0.0, "the sideways kick alternates", str(recoil.offset()))

	var whole := DotRecoil.new()
	whole.kick(weapon)
	whole.advance(0.5)
	var halves := DotRecoil.new()
	halves.kick(weapon)
	halves.advance(0.25)
	halves.advance(0.25)
	_check(absf(whole.offset().x - halves.offset().x) < 0.0001, "recovery is frame-rate independent")
	_check(whole.offset().x < 2.0 and whole.offset().x > 0.0, "and sheds a fraction per second rather than all at once", str(whole.offset().x))
	whole.advance(10.0)
	_check(whole.offset() == Vector2.ZERO, "and settles to exactly zero")

	var burst := DotRecoil.new()
	burst.max_pitch = 5.0
	for _i in range(20):
		burst.kick(weapon)
	_check(burst.offset().x == 5.0, "a held trigger stops at max_pitch")
