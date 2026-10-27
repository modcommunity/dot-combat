extends "res://examples/selftest/support_tests.gd"

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

const CHECKS := 261

## Sections entered against sections that ran to their last line, and against this. A
## runtime error inside a section aborts that function and nothing says so; a section that
## bailed out early after a failed guard is counted as not finished on purpose. The CHECKS
## total is the other half — see docs/testing.md.
const SECTIONS := 22


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	print("dot-combat self-test")
	print("")

	_test_damage_type()
	_test_hit_groups()
	_test_health()
	_test_spread_determinism()
	_test_hitbox_geometry()
	_test_hitbox_precedence()
	_test_flat_trace()
	_test_resolver_rules()
	_test_criticals()
	_test_manager_hitscan()
	_test_muzzle_inside_body()
	_test_team_mate_pass_through_cvar()
	_test_client_follows_the_server_cvar()
	_test_manager_walls()
	_test_manager_splash()
	_test_manager_validation()
	_test_lag_compensation()
	_test_net_sync()
	_test_limbs()
	await _test_sentry()
	_test_defib()
	_test_fall_damage()

	print("")
	print("%d passed, %d failed" % [_passed, _failed])

	for line in _failures:
		print("  FAIL  %s" % line)

	print("%d of %d sections ran to their last line" % [_completed, _entered])
	if _entered != SECTIONS or _completed != _entered:
		print("ERROR: %d sections entered and %d completed, %d expected. One aborted or was skipped." % [
			_entered, _completed, SECTIONS
		])
		get_tree().quit(1)
		return
	# The total the section counter cannot be. A runtime error inside a section aborts
	# that function, and the counter is satisfied because the section had already
	# announced itself. See docs/testing.md.
	if _passed + _failed != CHECKS:
		print("ERROR: %d checks ran, %d expected. A section aborted part-way." % [
			_passed + _failed, CHECKS
		])
		get_tree().quit(1)
		return
	get_tree().quit(1 if _failed > 0 else 0)


# --- Assertions ------------------------------------------------------------

# --- Damage type -----------------------------------------------------------

func _test_damage_type() -> void:
	_section("damage types")

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
	_done()


func _test_hit_groups() -> void:
	_section("hit groups")

	var groups := DotHitGroup.defaults()

	_close(groups.multiplier(DotHitGroup.HEAD), 4.0, "head multiplier")
	_close(groups.multiplier(DotHitGroup.LEG), 0.75, "leg multiplier")

	# The important one: a group nobody registered does normal damage. A typo costing
	# full damage is survivable; a typo costing none is a weapon that does nothing.
	_close(groups.multiplier(&"tail"), 1.0, "an unknown group does normal damage")
	_check(not groups.has(&"tail"), "an unknown group is still reported as unknown")
	_done()


# --- Health ----------------------------------------------------------------

func _test_health() -> void:
	_section("health and armour")

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

	# Buddha: hurt, never killed, and the event says what was really lost.
	var buddha := DotHealth.new()
	buddha.cannot_die = true
	add_child(buddha)
	var nearly := DotDamage.make(1, 2, 1000.0, type)
	buddha.apply(nearly)
	_check(buddha.alive and not nearly.lethal, "cannot_die takes a fatal hit and survives it")
	_close(buddha.health, 1.0, "at its last stand")
	_close(nearly.health_lost, 99.0, "and the event records only what was lost")
	buddha.queue_free()

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
	_done()


# --- Spread ----------------------------------------------------------------

func _test_spread_determinism() -> void:
	_section("spread determinism")

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
	_done()


# --- Hitboxes --------------------------------------------------------------

func _test_hitbox_geometry() -> void:
	_section("hitbox geometry")

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
	_done()


func _test_hitbox_precedence() -> void:
	_section("hitbox precedence")

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
	_done()


# --- Tracing ---------------------------------------------------------------

func _test_flat_trace() -> void:
	_section("flat trace")

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
	_done()


# --- Arsenal ---------------------------------------------------------------

func _test_criticals() -> void:
	_section("criticals")

	var rules := DotDamageRules.new()
	var resolver := DotDamageResolver.with_rules(rules)
	var type := _bullet()

	var head := DotDamage.make(1, 3, 25.0, type)
	head.hit_group = DotHitGroup.HEAD
	resolver.resolve(head)
	_check(head.critical, "a headshot is a critical by default")
	_close(head.amount, 100.0, "and does exactly the head's damage: the default adds nothing")

	var body := DotDamage.make(1, 3, 25.0, type)
	body.hit_group = DotHitGroup.CHEST
	resolver.resolve(body)
	_check(not body.critical, "a body shot is not, with no chance set")

	rules.critical_scale = 1.5
	var harder := DotDamage.make(1, 3, 25.0, type)
	harder.hit_group = DotHitGroup.HEAD
	resolver.resolve(harder)
	_close(harder.amount, 150.0, "critical_scale multiplies a critical after the hit group")

	# A chance, rolled from the hit: over a thousand hits it lands near the chance, and the
	# same hit rolls the same every time.
	rules.critical_scale = 1.0
	rules.critical_headshots = false
	rules.critical_chance = 0.25
	var crits := 0
	for tick in range(1000):
		var hit := DotDamage.make(1, 3, 10.0, type)
		hit.tick = tick
		hit.weapon_id = &"rifle"
		resolver.resolve(hit)
		if hit.critical:
			crits += 1
	_check(crits > 200 and crits < 300, "a 25% chance lands near a quarter of hits",
		"%d of 1000" % crits)

	var again := DotDamage.make(1, 3, 10.0, type)
	again.tick = 77
	again.weapon_id = &"rifle"
	var twice := DotDamage.make(1, 3, 10.0, type)
	twice.tick = 77
	twice.weapon_id = &"rifle"
	_check(
		resolver.is_critical(again) == resolver.is_critical(twice)
			and DotDamageResolver.critical_roll(again) == DotDamageResolver.critical_roll(twice),
		"the same hit rolls the same, on any machine and any replay"
	)

	var own := DotDamage.make(1, 1, 10.0, type)
	rules.critical_chance = 1.0
	_check(not resolver.is_critical(own), "self damage is never a critical")
	_done()


func _test_resolver_rules() -> void:
	_section("damage rules")

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
	_done()


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
	_section("manager: hitscan")

	var trace := DotTraceFlat.with_floor(0.0)
	var manager := _make_manager(trace, DotDamageRules.new())

	var victim := _make_player(Vector3(0.0, 0.0, -10.0))
	_hitboxes_of(victim).register_with(manager, 2)
	manager.register_health(2, _health_of(victim))

	var kills: Array[int] = []
	manager.entity_killed.connect(func(id: int, _d: DotDamage) -> void: kills.append(id))

	var shot := _rifle_shot(1, 100, 1)
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
	var head_shot := _rifle_shot(1, 101, 2)
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
	var miss := _rifle_shot(1, 102, 3)
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

	var point_blank := _rifle_shot(1, 103, 4)
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
	_done()


## A shot whose muzzle is already inside somebody.
##
## Found in a co-op game where team-mates do not collide: stacked players hit the friend
## they stood in with every shot, aimed anywhere, because a ray starting inside a hitbox is
## a hit at zero metres. Armed both ways: with [method DotCombatManager.pass_through_sets]
## returning nothing, five checks here fail; with it skipping every body at the muzzle
## (team-mate or not), the point-blank and the free-for-all checks fail.
func _test_muzzle_inside_body() -> void:
	_section("manager: a muzzle inside a body")

	var rules := DotDamageRules.new()
	rules.friendly_fire = true
	var manager := _make_manager(DotTraceFlat.with_floor(0.0), rules)
	var teams := {1: 1, 2: 1, 3: 2, 4: 2}
	manager.resolver.team_of = func(id: int) -> int: return int(teams.get(id, 0))

	# Shooter and a team-mate in the same place; an enemy ten metres ahead.
	var shooter := _make_player(Vector3.ZERO)
	var friend := _make_player(Vector3.ZERO)
	var enemy := _make_player(Vector3(0.0, 0.0, -10.0))
	for pair in [[shooter, 1], [friend, 2], [enemy, 3]]:
		_hitboxes_of(pair[0]).register_with(manager, pair[1])
		manager.register_health(pair[1], _health_of(pair[0]))

	var index := [0]
	var fire := func() -> DotShot:
		index[0] += 1
		var shot := _rifle_shot(1, 200 + index[0], index[0])
		shot.origin = Vector3(0.0, 1.4, 0.0)
		shot.direction = Vector3.FORWARD
		shot.scatter()
		return manager.resolve_shot(shot)

	var victims := func(shot: DotShot) -> Array:
		var out := []
		for damage in shot.damages:
			out.append(damage.victim)
		return out

	var stacked: DotShot = fire.call()
	_check(
		victims.call(stacked) == [3],
		"a shot from inside a team-mate goes on to the enemy it was aimed at",
		str(victims.call(stacked))
	)
	_close(_health_of(friend).health, 100.0, "and the team-mate takes nothing")

	# Friendly fire off is not enough on its own: the friend refuses the damage but still
	# eats the bullet, and the enemy is never reached.
	rules.friendly_fire = false
	var no_ff: DotShot = fire.call()
	_check(
		victims.call(no_ff) == [3] and not no_ff.damages[0].refused,
		"with friendly fire off the enemy is still reached, not lost to the friend",
		str(victims.call(no_ff))
	)
	rules.friendly_fire = true

	# The point-blank case the zero-distance rule exists for must survive.
	var hugger := _make_player(Vector3.ZERO)
	_hitboxes_of(hugger).register_with(manager, 4)
	manager.register_health(4, _health_of(hugger))
	var point_blank: DotShot = fire.call()
	_check(
		victims.call(point_blank) == [4] and is_zero_approx(point_blank.damages[0].distance),
		"an enemy holding the muzzle is still a point-blank hit at 0 m",
		str(victims.call(point_blank))
	)
	manager.forget(4)

	# A team-mate in the line, muzzle outside them, is friendly fire as the rules say.
	friend.position = Vector3(0.0, 0.0, -3.0)
	var in_line: DotShot = fire.call()
	_check(victims.call(in_line) == [2], "a team-mate merely in the line is still hit")
	friend.position = Vector3.ZERO

	# The policy is a rule, and can be turned off.
	rules.pass_through_team_mate_at_muzzle = false
	var old_way: DotShot = fire.call()
	_check(victims.call(old_way) == [2], "with the rule off the stacked team-mate is hit again")
	rules.pass_through_team_mate_at_muzzle = true

	# And replaced: a game whose overlap is not a team question.
	manager.pass_through_fn = func(_s: DotShot, _set: DotHitboxSet, id: int) -> bool:
		return id == 3
	friend.position = Vector3(0.0, 0.0, -10.0)
	enemy.position = Vector3.ZERO
	var custom: DotShot = fire.call()
	_check(
		victims.call(custom) == [2],
		"pass_through_fn replaces the team rule",
		str(victims.call(custom))
	)
	manager.pass_through_fn = Callable()

	# With no teams at all (a free-for-all) everyone holding the muzzle is an enemy.
	manager.resolver.team_of = Callable()
	var ffa: DotShot = fire.call()
	_check(victims.call(ffa) == [3], "without teams a body holding the muzzle is hit")

	manager.queue_free()
	remove_child(manager)
	_clear_players()
	_done()


## mp_teammate_passthrough: the server cvar over both pass-through rules, and the broad
## rule it alone reaches (2: a team-mate anywhere in the line never blocks the shot).
func _test_team_mate_pass_through_cvar() -> void:
	_section("manager: the team-mate pass-through cvar")

	var levels := DotDamageRules.new()
	_check(levels.pass_through_level() == 1, "the default is 1: through a team-mate at the muzzle only")
	levels.set_pass_through_level(0)
	_check(
		not levels.pass_through_team_mate_at_muzzle and not levels.pass_through_team_mates,
		"level 0 turns both rules off"
	)
	levels.set_pass_through_level(2)
	_check(
		levels.pass_through_team_mate_at_muzzle and levels.pass_through_team_mates,
		"level 2 turns both on"
	)
	levels.set_pass_through_level(7)
	_check(levels.pass_through_level() == 2, "a level past 2 is clamped to 2")

	var rules := DotDamageRules.new()
	rules.friendly_fire = true
	var manager := _make_manager(DotTraceFlat.with_floor(0.0), rules)
	var teams := {1: 1, 2: 1, 3: 2, 4: 2}
	manager.resolver.team_of = func(id: int) -> int: return int(teams.get(id, 0))

	# A team-mate three metres ahead in the line, an enemy at ten: the shape the broad rule
	# is for. The muzzle is outside the friend, so the muzzle rule never applies.
	var shooter := _make_player(Vector3.ZERO)
	var friend := _make_player(Vector3(0.0, 0.0, -3.0))
	var enemy := _make_player(Vector3(0.0, 0.0, -10.0))
	for pair in [[shooter, 1], [friend, 2], [enemy, 3]]:
		_hitboxes_of(pair[0]).register_with(manager, pair[1])
		manager.register_health(pair[1], _health_of(pair[0]))

	var index := [0]
	var fire := func() -> Array:
		index[0] += 1
		var shot := _rifle_shot(1, 400 + index[0], index[0])
		shot.origin = Vector3(0.0, 1.4, 0.0)
		shot.direction = Vector3.FORWARD
		shot.scatter()
		var out := []
		for damage in manager.resolve_shot(shot).damages:
			out.append(damage.victim)
		return out

	# An operator's value set before the manager bound the cvar (argv, content.yml) wins.
	var made: Array[FakeCvar] = []
	var add := func(n: String, value: String, _help: String, flags: int) -> FakeCvar:
		var cv := FakeCvar.new()
		cv.cvar_name = n
		cv.value = "2" if n == DotCombatManager.CVAR_TEAMMATE_PASSTHROUGH else value
		cv.flags = flags
		made.append(cv)
		return cv
	var bound := manager.bind_cvars(add, 9)
	_check(
		bound.size() == 1 and made[0].cvar_name == "mp_teammate_passthrough" and made[0].flags == 9,
		"bind_cvars registers mp_teammate_passthrough with the caller's flags",
		str(made.map(func(c: FakeCvar) -> String: return c.cvar_name))
	)
	_check(made[0].low == 0.0 and made[0].high == 2.0, "ranged 0 to 2 where the cvar offers a range")
	_check(rules.pass_through_level() == 2, "the value already set is read back when it binds")

	_check(fire.call() == [3], "at 2 a team-mate in the line does not block: the enemy is hit", "")
	_close(_health_of(friend).health, 100.0, "and the team-mate takes nothing")

	# An enemy in the line still blocks: the rule is about team-mates only.
	var second := _make_player(Vector3(0.0, 0.0, -6.0))
	_hitboxes_of(second).register_with(manager, 4)
	manager.register_health(4, _health_of(second))
	_check(fire.call() == [4], "at 2 an enemy in the line is still hit first")
	manager.forget(4)

	# A game's own muzzle policy does not undo what the operator set.
	manager.pass_through_fn = func(_s: DotShot, _set: DotHitboxSet, _id: int) -> bool: return false
	_check(fire.call() == [3], "pass_through_fn replaces the muzzle rule, not level 2")
	manager.pass_through_fn = Callable()

	# Live: the next shot after a change uses it.
	made[0].set_value("1")
	_check(fire.call() == [2], "changed to 1 at runtime, a team-mate in the line is friendly fire again")
	_check(rules.pass_through_team_mate_at_muzzle, "and the muzzle rule stays on")

	made[0].set_value("0")
	friend.position = Vector3.ZERO
	_check(fire.call() == [2], "at 0 a team-mate holding the muzzle is hit, as before the rule")

	made[0].set_value("lots")
	_check(rules.pass_through_level() == 0, "a value that is not a number changes nothing")

	_check(not manager.set_cvar("mp_other", "1"), "set_cvar refuses a name that is not its own")

	manager.queue_free()
	remove_child(manager)
	_clear_players()
	_done()


## A client's manager on the server's mp_teammate_passthrough, through its link. What it
## guards: a client left on the default 1 against a server on 2 drew its tracer into the
## team-mate the server's shot went through (and at 0, through one the server's shot hit).
func _test_client_follows_the_server_cvar() -> void:
	_section("manager: a client follows the server's pass-through cvar")

	var rules := DotDamageRules.new()
	rules.friendly_fire = true
	var manager := _make_manager(DotTraceFlat.with_floor(0.0), rules)
	manager.is_authority = false
	var teams := {1: 1, 2: 1, 3: 2}
	manager.resolver.team_of = func(id: int) -> int: return int(teams.get(id, 0))

	var shooter := _make_player(Vector3.ZERO)
	var friend := _make_player(Vector3(0.0, 0.0, -3.0))
	var enemy := _make_player(Vector3(0.0, 0.0, -10.0))
	for pair in [[shooter, 1], [friend, 2], [enemy, 3]]:
		_hitboxes_of(pair[0]).register_with(manager, pair[1])
		manager.register_health(pair[1], _health_of(pair[0]))

	var index := [0]
	var predicted := func() -> Array:
		index[0] += 1
		var shot := _rifle_shot(1, 900 + index[0], index[0])
		shot.origin = Vector3(0.0, 1.4, 0.0)
		shot.direction = Vector3.FORWARD
		shot.scatter()
		var out := []
		for damage in manager.resolve_shot(shot).damages:
			out.append(damage.victim)
		return out

	_check(predicted.call() == [2], "on its own default a client predicts the team-mate in the line is hit")

	_check(not manager.follow_cvars(RefCounted.new()), "a source that cannot replicate (an older link) is refused")
	_check(rules.pass_through_level() == 1, "and the manager keeps its default")

	# The server said 2 before this client's world was built: the table is already there.
	var link := FakeLink.new()
	add_child(link)
	link.replicated_cvars["mp_teammate_passthrough"] = "2"
	_check(manager.follow_cvars(link), "a link with replicated cvars is followed")
	_check(rules.pass_through_level() == 2, "the value the link already holds is applied at once")
	_check(predicted.call() == [3], "so the client's predicted shot goes through the team-mate, as the server's does")
	_close(_health_of(friend).health, 100.0, "and a client's manager still applies no damage")

	link.tell("mp_teammate_passthrough", "0")
	_check(rules.pass_through_level() == 0, "a live change on the server reaches the client's rules")
	friend.position = Vector3.ZERO
	_check(predicted.call() == [2], "at 0 the client predicts the team-mate at the muzzle is hit, as the server does")

	_check(manager.follow_cvars(link) and link.get_signal_connection_list(&"replicated_cvar_changed").size() == 1,
		"following the same link twice connects once")
	link.tell("sv_cheats", "1")
	_check(rules.pass_through_level() == 0, "another cvar on the link changes nothing here")

	manager.queue_free()
	remove_child(manager)
	link.queue_free()
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


func _test_manager_splash() -> void:
	_section("manager: splash")

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

	var splash_type := DotDamageType.make(&"blast")
	splash_type.uses_hit_groups = false
	splash_type.armour_share = 0.0
	splash_type.self_scale = 0.5

	var shot := _rocket_shot(splash_type, 1, 100, 1)
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

	var blast := _rocket_shot(splash_type, 1, 101, 2)
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
	_done()


func _test_manager_validation() -> void:
	_section("manager: validating what a client claims")

	var trace := DotTraceFlat.with_floor(0.0)
	var manager := _make_manager(trace, DotDamageRules.new())
	manager.config.max_origin_error = 1.0
	manager.config.shots_per_second = 10.0

	var victim := _make_player(Vector3(0.0, 0.0, -10.0))
	_hitboxes_of(victim).register_with(manager, 2)
	manager.register_health(2, _health_of(victim))

	# A registration that can never work is counted (and warned), not silently dropped.
	manager.register_health(0, _health_of(victim))
	manager.register_health(5, null)
	manager.register_hitboxes(null, 5)
	_check(manager.describe()["registrations_refused"] == 3, "bad registrations are counted")
	_check(manager.health_of(0) == null, "an id-0 health is not stored")
	_check(manager.entity_ids().size() == 1, "and no ghost entity appears", str(manager.entity_ids()))

	var shooter := _make_player(Vector3(0.0, 0.0, 0.0))
	_hitboxes_of(shooter).register_with(manager, 1)
	manager.register_health(1, _health_of(shooter))
	manager.set_authoritative_origin(1, Vector3(0.0, 1.0, 0.0))

	# A client claiming a muzzle on the far side of the level is claiming a shot
	# through every wall between here and there.
	var teleported := _rifle_shot(1, 100, 1)
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
		var spam := _rifle_shot(1, 200 + i, i)
		spam.origin = Vector3(0.0, 1.0, 0.0)
		spam.direction = Vector3.FORWARD
		spam.tick = 200 + i
		spam.scatter()
		manager.resolve_shot(spam)

	_check(refusals.size() > 0, "a flood of shots is rate limited",
		"%d refused" % refusals.size())

	# A dead player cannot shoot.
	_health_of(shooter).alive = false
	var posthumous := _rifle_shot(1, 400, 1)
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

	var predicted := _rifle_shot(6, 500, 1)
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
	_done()


func _test_lag_compensation() -> void:
	_section("lag compensation")

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

	var shot := _rifle_shot(1, 100, 1)
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
	var ancient := _rifle_shot(1, 1000, 2)
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
		var spam := _rifle_shot(1, 2000 + i, i)
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
	_done()


# --- Net sync --------------------------------------------------------------

## A stand-in for the DotNetBehaviour a game writes. Plain properties, because that
## is all [DotCombatNetSync] requires — the point of the bridge is that dot-combat
## never names a dot-net type.
class FakeBehaviour extends Object:
	var net_health: int = 0
	var net_armour: int = 0
	var net_alive: bool = false


func _test_net_sync() -> void:
	_section("net sync")

	var specs := DotCombatNetSync.specs()
	# Three, not six: the slot, the magazine and the reserve moved to dot-weapon's own
	# sync when the weapon layer left this addon. A game with health and no weapons
	# replicates three properties rather than six.
	_check(specs.size() == 3, "the bridge describes every replicated health property")

	for spec in specs:
		_check(
			not bool(spec["owner_only"]),
			"health is public: everyone draws everyone's health bar",
			String(spec["property"])
		)

	var health := DotHealth.new()
	health.max_health = 100.0
	add_child(health)
	health.health = 73.4
	health.armour = 12.0

	var behaviour := FakeBehaviour.new()
	DotCombatNetSync.pull(health, behaviour)

	# Ceil, not round: a player on 0.4 health is alive, and rounding to zero shows a
	# corpse's health bar on someone still shooting back.
	_check(behaviour.net_health == 74, "health rounds up", str(behaviour.net_health))
	_check(behaviour.net_armour == 12, "and armour", str(behaviour.net_armour))
	_check(behaviour.net_alive, "alive replicates")

	health.health = 0.4
	DotCombatNetSync.pull(health, behaviour)
	_check(behaviour.net_health == 1, "a player on a sliver of health is not shown dead")

	var receiver_health := DotHealth.new()
	receiver_health.max_health = 100.0
	add_child(receiver_health)
	DotCombatNetSync.push(behaviour, receiver_health)
	_close(receiver_health.health, 1.0, "received health is written straight through")

	behaviour.free()
	health.queue_free()
	remove_child(health)
	receiver_health.queue_free()
	remove_child(receiver_health)
	_done()



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


func _test_fall_damage() -> void:
	_section("fall damage: threshold, curve, water, soft surface, cvars, authority")

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
