extends "res://examples/selftest/manager_tests.gd"

## The spatial prefilter in DotTrace.ray and DotCombatManager.pass_through_sets must change nothing:
## random worlds and shots, new code against a verbatim copy of the code it replaced.


## DotTrace.ray as it was before the inline bounds test: may_be_hit alone rejects.
func _ref_ray(trace: DotTrace, from: Vector3, direction: Vector3, max_distance: float, sets: Array[DotHitboxSet]) -> DotHitbox.Hit:
	var world := trace._world_ray(from, direction, max_distance)

	if world.ok():
		world.blocked = true

	var limit := world.distance if world.ok() else max_distance
	var best := world

	for set_node in sets:
		if set_node == null or not is_instance_valid(set_node):
			continue

		if not set_node.may_be_hit(from, direction, limit):
			continue

		if trace._is_excluded(set_node):
			continue

		var hit := set_node.intersect_ray(from, direction, limit)

		if not hit.ok():
			continue

		if hit.distance > limit:
			continue

		if best.ok() and hit.distance >= best.distance:
			continue

		best = hit
		limit = hit.distance

	if best.ok() and not best.blocked and best.distance > DotTrace.WALL_RECHECK_MIN:
		var back := trace._world_ray(best.point, -direction, best.distance - DotTrace.WALL_RECHECK_MIN)
		if back.ok():
			back.blocked = true
			back.inside_start = true
			back.distance = best.distance - back.distance
			best = back

	return best


## DotCombatManager.pass_through_sets as it was before the inline bounds test.
func _ref_pass_through_sets(m: DotCombatManager, shot: DotShot) -> Array[DotHitboxSet]:
	var out: Array[DotHitboxSet] = []

	if shot == null:
		return out

	var use_rule := m.rules != null and m.rules.pass_through_team_mate_at_muzzle
	var everywhere := m.rules != null and m.rules.pass_through_team_mates and m.resolver != null

	if not m.pass_through_fn.is_valid() and not everywhere and (not use_rule or m.resolver == null):
		return out

	for set_node in m._set_list:
		if set_node == null or not is_instance_valid(set_node):
			continue

		if not everywhere and not set_node.contains_point(shot.origin):
			continue

		var entity_id := m._entity_id_of(set_node.entity_owner())

		if entity_id == shot.attacker:
			continue

		var passes := false

		if everywhere and m.resolver.are_team_mates(shot.attacker, entity_id):
			passes = true
		elif everywhere and not set_node.contains_point(shot.origin):
			continue
		elif m.pass_through_fn.is_valid():
			passes = bool(m.pass_through_fn.call(shot, set_node, entity_id))
		elif use_rule and m.resolver != null:
			passes = m.resolver.are_team_mates(shot.attacker, entity_id)

		if passes:
			out.append(set_node)

	return out


func _hit_key(hit: DotHitbox.Hit) -> String:
	return "%s|%s|%s|%s|%s|%s|%s" % [
		hit.distance, hit.point, hit.normal, hit.hitbox.get_instance_id() if hit.hitbox != null else 0,
		hit.entity.get_instance_id() if hit.entity != null else 0, hit.blocked, hit.inside_start,
	]


func _unit(rng: RandomNumberGenerator) -> Vector3:
	var v := Vector3(rng.randf_range(-1.0, 1.0), rng.randf_range(-0.5, 0.5), rng.randf_range(-1.0, 1.0))
	return v.normalized() if v.length() > 0.01 else Vector3.FORWARD


func _test_trace_prefilter() -> void:
	_section("the spatial prefilter changes no ray and no pass-through set")

	var rules := DotDamageRules.new()
	var flat := DotTraceFlat.with_floor(0.0)
	flat.add_box(AABB(Vector3(-4.0, 0.0, -30.0), Vector3(8.0, 3.0, 0.5)))
	flat.add_box(AABB(Vector3(10.0, 0.0, -5.0), Vector3(0.5, 3.0, 12.0)))
	var manager := _make_manager(flat, rules)
	var teams := {}
	manager.resolver.team_of = func(id: int) -> int: return int(teams.get(id, 0))

	var rng := RandomNumberGenerator.new()
	rng.seed = 91731
	var bodies := 70

	for i in range(bodies):
		var body := _make_player(Vector3(rng.randf_range(-25.0, 25.0), 0.0, rng.randf_range(-25.0, 25.0)))
		body.rotation = Vector3(rng.randf_range(-0.4, 0.4), rng.randf_range(0.0, TAU), rng.randf_range(-0.4, 0.4))
		body.scale = Vector3(rng.randf_range(0.6, 1.7), rng.randf_range(0.6, 1.7), rng.randf_range(0.6, 1.7))
		var set_node := _hitboxes_of(body)
		set_node.bounds_radius = rng.randf_range(0.3, 3.0)
		set_node.bounds_offset = Vector3(rng.randf_range(-0.5, 0.5), rng.randf_range(0.0, 1.5), rng.randf_range(-0.5, 0.5))
		set_node.enabled = rng.randf() > 0.1
		set_node.register_with(manager, i + 2)
		teams[i + 2] = rng.randi_range(0, 3)

		# A box freed under a set, and now and then every box: both are pruned lazily.
		var kept := set_node.hitboxes().duplicate()
		var freed := rng.randf()
		if freed < 0.1:
			for box in kept:
				box.free()
		elif freed < 0.25:
			kept[rng.randi_range(0, kept.size() - 1)].free()

	teams[1] = 1
	var sets: Array[DotHitboxSet] = manager._set_list
	var trials := 600
	var ray_diff := 0
	var ray_hits := 0
	var ray_walls := 0

	for t in range(trials):
		var from := Vector3(rng.randf_range(-28.0, 28.0), rng.randf_range(0.2, 2.2), rng.randf_range(-28.0, 28.0))

		# Often start inside some body's bounds, the case where the sphere test says "maybe".
		if t % 3 == 0:
			var host := _hitboxes_of(_players[rng.randi_range(0, _players.size() - 1)])
			from = host.bounds_centre() + _unit(rng) * rng.randf_range(0.0, host.bounds_radius * 1.3)

		var direction := _unit(rng)
		var reach := rng.randf_range(2.0, 90.0)
		manager.trace.exclude = [] if t % 2 == 0 else [_players[t % _players.size()]]
		var got := manager.trace.ray(from, direction, reach, sets)
		var want := _ref_ray(manager.trace, from, direction, reach, sets)

		if _hit_key(got) != _hit_key(want):
			ray_diff += 1
		if want.ok():
			ray_hits += 1
			if want.blocked:
				ray_walls += 1

	manager.trace.exclude = []
	_check(ray_diff == 0, "%d random rays return exactly what the unfiltered walk returned" % trials, "%d differ" % ray_diff)
	_check(ray_hits > 100 and ray_walls > 20 and ray_hits - ray_walls > 30, "and the rays cover bodies and walls", "%d hits, %d walls" % [ray_hits, ray_walls])

	var levels_diff := [0, 0, 0]
	var nonempty := 0

	for level in [0, 1, 2]:
		rules.set_pass_through_level(level)
		for t in range(trials):
			var shot := _rifle_shot(1 if t % 4 != 0 else 2, 100, 1)
			var host := _hitboxes_of(_players[rng.randi_range(0, _players.size() - 1)])
			shot.origin = host.bounds_centre() + _unit(rng) * rng.randf_range(0.0, host.bounds_radius * 1.5) if t % 2 == 0 \
				else Vector3(rng.randf_range(-28.0, 28.0), 1.4, rng.randf_range(-28.0, 28.0))
			var got := manager.pass_through_sets(shot)
			var want := _ref_pass_through_sets(manager, shot)

			if got != want:
				levels_diff[level] += 1
			if not want.is_empty():
				nonempty += 1

	_check(levels_diff[0] == 0 and levels_diff[1] == 0 and levels_diff[2] == 0, "pass_through_sets agrees at levels 0, 1 and 2 on %d shots each" % trials, str(levels_diff))
	_check(nonempty > 50, "and some of those shots pass through bodies", str(nonempty))

	rules.set_pass_through_level(0)
	manager.pass_through_fn = func(_s: DotShot, set_node: DotHitboxSet, id: int) -> bool: return id % 2 == 0 and set_node.enabled
	var fn_diff := 0
	for t in range(trials):
		var shot := _rifle_shot(1, 100, 1)
		var host := _hitboxes_of(_players[rng.randi_range(0, _players.size() - 1)])
		shot.origin = host.bounds_centre() + _unit(rng) * rng.randf_range(0.0, host.bounds_radius * 1.5)
		if manager.pass_through_sets(shot) != _ref_pass_through_sets(manager, shot):
			fn_diff += 1
	manager.pass_through_fn = Callable()
	_check(fn_diff == 0, "and with a pass_through_fn in place of the team rule", "%d differ" % fn_diff)

	_done()
