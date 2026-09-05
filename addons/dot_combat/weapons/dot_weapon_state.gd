class_name DotWeaponState
extends RefCounted

## One carrier's runtime state for one weapon, advanced a tick at a time.
##
## Everything here is an integer tick or an integer count. Nothing is a wall-clock
## duration and nothing is a float accumulator, because this state is replayed: a
## client that mispredicts a shot rewinds to the last acknowledged tick and re-runs
## every tick since, and a float accumulator does not land on the same value twice.
##
## Bloom and recoil are the two exceptions and they are quantised on purpose — see
## [member bloom] .

## Rounds in the magazine.
var ammo: int = 0

## Rounds held outside the magazine.
var reserve: int = 0

## Earliest tick this weapon may fire on.
var next_fire_tick: int = 0

## Tick a reload completes on. -1 when not reloading.
var reload_end_tick: int = -1

## Shots left in the current burst. Zero when not bursting.
var burst_remaining: int = 0

## Tick the weapon finishes deploying on. Fire is refused before it.
var deploy_end_tick: int = -1

## Shots fired since the trigger was last released, for bloom and for recoil.
var consecutive_shots: int = 0

## Tick of the most recent shot, for bloom recovery.
var last_fire_tick: int = -1000000

## Accumulated inaccuracy, in hundredths of a degree.
##
## [b]An integer, deliberately.[/b] Bloom is state that survives across ticks and gets
## replayed on every reconciliation, so a float that decays by a per-tick fraction
## drifts apart between the client's replay and the server's original run. Hundredths
## of a degree is finer than any weapon is tuned to and it replays exactly.
var bloom: int = 0

## Total rounds this weapon has ever fired, for a scoreboard. Not replay-safe and
## deliberately not used by anything in the simulation.
var shots_total: int = 0

var _weapon: DotWeapon = null
var _tick_rate: int = 60


static func for_weapon(
	weapon: DotWeapon,
	tick_rate: int = 60,
	full: bool = true
) -> DotWeaponState:
	var state := DotWeaponState.new()
	state.bind(weapon, tick_rate)
	if full:
		state.fill()
	return state


func bind(weapon: DotWeapon, tick_rate: int) -> void:
	_weapon = weapon
	_tick_rate = maxi(1, tick_rate)


func weapon() -> DotWeapon:
	return _weapon


## Fills the magazine and the reserve. What a spawn does.
func fill() -> void:
	if _weapon == null:
		return
	ammo = _weapon.magazine
	reserve = _weapon.reserve
	reload_end_tick = -1
	burst_remaining = 0
	consecutive_shots = 0
	bloom = 0


## Whether the trigger would produce a shot on [param tick].
##
## Deliberately does not consider the trigger itself — that is the arsenal's job, and
## keeping the two apart is what lets a HUD grey out a weapon without simulating it.
func can_fire(tick: int) -> bool:
	if _weapon == null:
		return false

	if tick < next_fire_tick:
		return false

	if deploy_end_tick >= 0 and tick < deploy_end_tick:
		return false

	if is_reloading(tick):
		return false

	return has_ammo()


func has_ammo() -> bool:
	if _weapon == null:
		return false

	if _weapon.infinite_reserve:
		return true

	if not _weapon.uses_magazine():
		return reserve >= _weapon.cost

	return ammo >= _weapon.cost


func is_reloading(tick: int) -> bool:
	return reload_end_tick >= 0 and tick < reload_end_tick


## Consumes a shot's worth of ammunition and sets the cooldown.
##
## Returns false when it could not, which the caller must treat as "no shot happened"
## rather than as an error: a client predicting a shot it did not have ammunition for
## is a normal consequence of a reserve pickup arriving late.
func consume(tick: int) -> bool:
	if _weapon == null or not has_ammo():
		return false

	if not _weapon.infinite_reserve:
		if _weapon.uses_magazine():
			ammo -= _weapon.cost
		else:
			reserve -= _weapon.cost

	shots_total += 1
	consecutive_shots += 1
	last_fire_tick = tick

	bloom = mini(
		int(round(_weapon.spread_bloom_max * 100.0)),
		bloom + int(round(_weapon.spread_bloom * 100.0))
	)

	if _weapon.fire_mode == DotWeapon.Fire.BURST and burst_remaining > 0:
		burst_remaining -= 1
		next_fire_tick = tick + (
			_weapon.burst_interval_ticks(_tick_rate)
			if burst_remaining > 0
			else _weapon.fire_interval_ticks(_tick_rate)
		)
	else:
		next_fire_tick = tick + _weapon.fire_interval_ticks(_tick_rate)

	return true


## Starts a reload, or returns false if one is pointless or impossible.
func begin_reload(tick: int) -> bool:
	if _weapon == null or not _weapon.uses_magazine():
		return false

	if is_reloading(tick):
		return false

	if ammo >= _weapon.magazine:
		return false

	if not _weapon.infinite_reserve and reserve <= 0:
		return false

	if _weapon.reload_per_round:
		var first := reload_end_tick < 0
		reload_end_tick = tick + _weapon.reload_ticks(_tick_rate) + (
			_weapon.reload_start_ticks(_tick_rate) if first else 0
		)
	else:
		reload_end_tick = tick + _weapon.reload_ticks(_tick_rate)

	return true


## Completes whatever part of a reload is due on [param tick].
##
## Called every tick. A per-round reload finishes one round and starts the next, so
## the same call drives both kinds and the arsenal does not branch on the weapon.
func advance_reload(tick: int) -> int:
	if _weapon == null or reload_end_tick < 0 or tick < reload_end_tick:
		return 0

	var wanted := _weapon.magazine - ammo

	if wanted <= 0:
		reload_end_tick = -1
		return 0

	var moved := 0

	if _weapon.reload_per_round:
		moved = 1
	else:
		moved = wanted

	if not _weapon.infinite_reserve:
		moved = mini(moved, reserve)
		reserve -= moved

	ammo += moved
	reload_end_tick = -1

	# A per-round reload continues on its own until the magazine is full or the
	# trigger interrupts it. Restarting here rather than making the arsenal notice
	# keeps "reload" a single decision at the point the player made it.
	if _weapon.reload_per_round and ammo < _weapon.magazine:
		if _weapon.infinite_reserve or reserve > 0:
			begin_reload(tick)

	return moved


## Stops a reload in progress. A per-round reload keeps what it has already loaded.
func cancel_reload() -> void:
	reload_end_tick = -1


## Starts a burst if the weapon bursts and one is not already running.
func begin_burst() -> void:
	if _weapon == null or _weapon.fire_mode != DotWeapon.Fire.BURST:
		return

	if burst_remaining > 0:
		return

	burst_remaining = _weapon.burst_count


## Called on the tick the trigger is released.
func release_trigger() -> void:
	consecutive_shots = 0


## Sheds bloom for one tick of not firing.
func decay(tick: int, delta: float) -> void:
	if _weapon == null or bloom <= 0:
		return

	if tick <= last_fire_tick:
		return

	bloom = maxi(
		0, bloom - int(round(_weapon.spread_recovery * delta * 100.0))
	)


## Marks the weapon as just drawn.
func deploy(tick: int) -> void:
	if _weapon == null:
		return
	deploy_end_tick = tick + _weapon.deploy_ticks(_tick_rate)
	burst_remaining = 0
	consecutive_shots = 0
	cancel_reload()


## The cone half-angle for a shot right now, in degrees.
##
## [param movement] is 0 standing still and 1 at full speed; [param airborne] and
## [param crouched] are the obvious things. All three come from the movement
## simulation, which is why this takes them rather than looking them up: dot-combat
## does not depend on dot-fps-controller either.
func spread_degrees(
	movement: float = 0.0,
	airborne: bool = false,
	crouched: bool = false
) -> float:
	if _weapon == null:
		return 0.0

	var cone := _weapon.spread_degrees
	cone += _weapon.spread_moving * clampf(movement, 0.0, 1.0)

	if airborne:
		cone += _weapon.spread_airborne

	cone += float(bloom) * 0.01

	if crouched:
		cone *= _weapon.spread_crouched

	return maxf(0.0, cone)


## Rounds a full reload could still add. For a HUD and for a bot deciding to reload.
func missing() -> int:
	if _weapon == null or not _weapon.uses_magazine():
		return 0
	if _weapon.infinite_reserve:
		return _weapon.magazine - ammo
	return mini(_weapon.magazine - ammo, reserve)


## Adds reserve rounds, respecting the cap. Returns what was taken.
func add_reserve(amount: int) -> int:
	if _weapon == null or amount <= 0:
		return 0

	if _weapon.infinite_reserve:
		return 0

	var taken := mini(amount, maxi(0, _weapon.reserve_cap() - reserve))
	reserve += taken
	return taken


## A copy that shares the weapon definition but no runtime state.
##
## Reconciliation needs this: the predictor snapshots the state before replaying and
## restores it if the replay diverges.
func duplicate_state() -> DotWeaponState:
	var copy := DotWeaponState.new()
	copy.bind(_weapon, _tick_rate)
	copy.ammo = ammo
	copy.reserve = reserve
	copy.next_fire_tick = next_fire_tick
	copy.reload_end_tick = reload_end_tick
	copy.burst_remaining = burst_remaining
	copy.deploy_end_tick = deploy_end_tick
	copy.consecutive_shots = consecutive_shots
	copy.last_fire_tick = last_fire_tick
	copy.bloom = bloom
	copy.shots_total = shots_total
	return copy


## Whether two states would produce the same simulation from here.
##
## [member shots_total] is excluded: it is a statistic, it never affects an outcome,
## and including it would make every reconciliation report a mismatch.
func equals(other: DotWeaponState) -> bool:
	if other == null:
		return false
	return (
		ammo == other.ammo
		and reserve == other.reserve
		and next_fire_tick == other.next_fire_tick
		and reload_end_tick == other.reload_end_tick
		and burst_remaining == other.burst_remaining
		and deploy_end_tick == other.deploy_end_tick
		and bloom == other.bloom
	)


func describe() -> Dictionary:
	return {
		"weapon": String(_weapon.id) if _weapon != null else "<none>",
		"ammo": ammo,
		"reserve": reserve,
		"next_fire": next_fire_tick,
		"reloading": reload_end_tick,
		"burst": burst_remaining,
		"bloom": float(bloom) * 0.01,
		"shots": shots_total,
	}


func _to_string() -> String:
	if _weapon == null:
		return "DotWeaponState(unbound)"
	return "DotWeaponState(%s %d/%d)" % [_weapon.id, ammo, reserve]
