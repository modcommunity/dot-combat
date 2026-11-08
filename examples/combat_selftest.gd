extends "res://examples/selftest/prefilter_tests.gd"

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

const CHECKS := 365

## Sections entered against sections that ran to their last line, and against this. A
## runtime error inside a section aborts that function and nothing says so; a section that
## bailed out early after a failed guard is counted as not finished on purpose. The CHECKS
## total is the other half — see docs/testing.md.
const SECTIONS := 34


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
	_test_muzzle_inside_wall()
	_test_muzzle_inside_wall_penetration()
	_test_broken_pane_stays_open()
	_test_penetration()
	_test_ricochet_and_sheets()
	_test_manager_splash()
	_test_explosion_cover()
	_test_manager_validation()
	_test_lag_compensation()
	_test_net_sync()
	_test_limbs()
	_test_hitzones()
	_test_freed_hitbox()
	await _test_sentry()
	_test_defib()
	_test_fall_damage()
	_test_stomp()
	_test_damage_immunity()
	_test_space_query_audit()
	_test_trace_prefilter()

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

	_health_timed(health, type)

	health.queue_free()
	remove_child(health)
	_done()


func _health_timed(health: DotHealth, type: DotDamageType) -> void:
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

	_spread_poles_and_fixed(forward)
	_done()


func _spread_poles_and_fixed(forward: Vector3) -> void:
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

	_hitbox_transforms(holder, sphere, capsule)

	holder.queue_free()
	remove_child(holder)
	_done()


func _hitbox_transforms(holder: Node3D, sphere: DotHitbox, capsule: DotHitbox) -> void:
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

	_resolver_clamps_and_hook(rules, resolver, type)
	_done()


func _resolver_clamps_and_hook(rules: DotDamageRules, resolver: DotDamageResolver, type: DotDamageType) -> void:
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
