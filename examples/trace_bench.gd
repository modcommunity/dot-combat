extends "selftest/selftest_base.gd"

## Micro-benchmark: what one shot costs with many bodies registered. Prints microseconds per call of
## pass_through_sets and of a whole rifle trace for a crowd of N bodies at each pass-through level.
## Run: godot --headless --path . res://examples/trace_bench.tscn -- --n=350 --rounds=300

func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	var n := 350
	var rounds := 300
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--n="):
			n = int(arg.substr(4))
		elif arg.begins_with("--rounds="):
			rounds = int(arg.substr(9))

	var rules := DotDamageRules.new()
	var manager := _make_manager(DotTraceFlat.with_floor(0.0), rules)
	manager.resolver.team_of = func(id: int) -> int: return 1 if id % 3 == 0 else 2
	var rng := RandomNumberGenerator.new()
	rng.seed = 77

	for i in range(n):
		var body := _make_player(Vector3(rng.randf_range(-45.0, 45.0), 0.0, rng.randf_range(-45.0, 45.0)))
		_hitboxes_of(body).register_with(manager, i + 2)

	for level in [0, 1, 2]:
		rules.set_pass_through_level(level)
		var shot := _rifle_shot(1, 100, 1)
		shot.origin = Vector3(0.0, 1.5, 0.0)
		shot.direction = Vector3.FORWARD
		shot.scatter()
		var t0 := Time.get_ticks_usec()
		for i in range(rounds):
			var _s := manager.pass_through_sets(shot)
		var pass_us := float(Time.get_ticks_usec() - t0) / rounds
		t0 = Time.get_ticks_usec()
		for i in range(rounds):
			manager._trace_shot(shot)
		var trace_us := float(Time.get_ticks_usec() - t0) / rounds
		print("BENCH n=%d level=%d pass_through_sets %.1f us   _trace_shot %.1f us" % [n, level, pass_us, trace_us])

	get_tree().quit(0)
