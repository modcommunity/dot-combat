extends "res://examples/selftest/wall_tests.gd"

## Manager sections: hitscan, muzzle rules, splash, validation, lag compensation, net sync.


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

	_hitscan_never_self(manager)


func _hitscan_never_self(manager: DotCombatManager) -> void:
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


## A shot whose muzzle is already inside somebody. Stacked team-mates hit the friend they stood in with every shot,
## because a ray starting inside a hitbox is a hit at zero metres; pass_through_sets returning nothing fails five checks.
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

	_muzzle_rules_tail(manager, rules, friend, enemy, fire, victims)


func _muzzle_rules_tail(manager: DotCombatManager, rules: DotDamageRules, friend: Node3D, enemy: Node3D, fire: Callable, victims: Callable) -> void:
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


func _pass_through_levels() -> void:
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


## mp_teammate_passthrough: the server cvar over both pass-through rules, and the broad
## rule it alone reaches (2: a team-mate anywhere in the line never blocks the shot).
func _test_team_mate_pass_through_cvar() -> void:
	_section("manager: the team-mate pass-through cvar")
	_pass_through_levels()

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
		bound.size() == 7 and made[0].cvar_name == "mp_teammate_passthrough" and made[0].flags == 9,
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

	_pass_through_live_changes(manager, rules, friend, fire, made)


func _pass_through_live_changes(manager: DotCombatManager, rules: DotDamageRules, friend: Node3D, fire: Callable, made: Array[FakeCvar]) -> void:
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


func _test_explosion_cover() -> void:
	_section("explosions: walls and fences")

	var trace := DotTraceFlat.with_floor(0.0)
	trace.add_box(AABB(Vector3(2.0, 0.0, -12.0), Vector3(0.4, 3.0, 4.0)), &"concrete")
	trace.add_box(AABB(Vector3(-2.0, 0.0, -12.0), Vector3(0.02, 3.0, 4.0)), &"fence")
	var manager := _make_manager(trace, DotDamageRules.new())
	var centre := Vector3(0.0, 1.0, -10.0)

	var open := _make_player(Vector3(0.0, 0.0, -13.0))
	var walled := _make_player(Vector3(4.0, 0.0, -10.0))
	var fenced := _make_player(Vector3(-4.0, 0.0, -10.0))
	var in_open := _make_player(Vector3(0.0, 0.0, -7.0))
	var players := [open, walled, fenced, in_open]
	for i in players.size():
		_hitboxes_of(players[i]).register_with(manager, 10 + i)
		manager.register_health(10 + i, _health_of(players[i]))

	var out := manager.explode(centre, 6.0, 100.0, 1)
	_check(_health_of(open).health < 100.0, "an explosion hurts a player in the open", str(_health_of(open).health))
	_check(_health_of(in_open).health < 100.0, "and one the same distance on the other side")
	_close(_health_of(open).health, _health_of(in_open).health, "equal distance, equal damage", 0.5)
	_close(_health_of(walled).health, 100.0, "a player the same distance behind a solid wall takes nothing")
	_check(out.size() == 2, "and is not even in the damage list", str(out.size()))

	# The design: splash needs a clear line, any solid world hit blocks it (DotTrace.line_of_sight), fences included.
	# Only a shot's own pellets are penetration-aware (sheet_thickness), splash is not.
	_close(_health_of(fenced).health, 100.0, "a thin fence blocks splash entirely: splash does not use penetration")

	var rocket_type := DotDamageType.make(&"blast")
	rocket_type.uses_hit_groups = false
	rocket_type.armour_share = 0.0
	var shot := _rocket_shot(rocket_type, 1, 300, 1)
	shot.origin = Vector3(0.0, 2.0, -10.0)
	shot.direction = Vector3.DOWN
	shot.tick = 300
	shot.scatter()
	var before := _health_of(in_open).health
	manager.resolve_shot(shot)
	_check(_health_of(in_open).health < before, "a rocket's splash reaches the player in the open", str(_health_of(in_open).health))
	_close(_health_of(walled).health, 100.0, "and is shielded by the same wall")

	manager.queue_free()
	remove_child(manager)
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

	_validation_client_instance(manager)
	manager.queue_free()
	remove_child(manager)
	_clear_players()
	_done()


func _validation_client_instance(manager: DotCombatManager) -> void:
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
	client.queue_free()
	remove_child(client)



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

	_lag_refused_shots_restore(manager, rewinds, restores)


func _lag_refused_shots_restore(manager: DotCombatManager, rewinds: Array[float], restores: Array[int]) -> void:
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


## A stand-in for the DotNetBehaviour a game writes: plain properties, so dot-combat names no dot-net type.
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
