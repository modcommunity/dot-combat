@tool
class_name DotArsenal
extends Node

## What a carrier is holding, and what happens when they pull the trigger.
##
## [b]The whole of [method simulate_tick] is a pure function of its arguments and of
## this node's own state.[/b] It reads no device, no clock and no other node, it
## applies no damage, and it produces [DotShot]s rather than consequences. That is
## what makes a shot predictable: the owning client runs it optimistically, the server
## runs it authoritatively, and both reach the same shot from the same command.
##
## Resolving those shots — tracing them, rewinding the world, applying damage — is
## [DotCombatManager]'s job and happens only on the server. A client that resolved its
## own shots would be a client that decides who dies.
##
## [codeblock]
## # Once, at spawn.
## arsenal.tick_rate = 64
## arsenal.give(DotWeapon.make(&"rifle"), 1)
## arsenal.select(1, 0)
##
## # Every simulated tick, on both ends.
## arsenal.movement = velocity.length() / max_speed
## arsenal.airborne = not grounded
## var shots := arsenal.simulate_tick(tick, delta, command)
##
## # On the server only.
## for shot in shots:
##     manager.resolve_shot(shot)
## [/codeblock]

const CHANNEL := "combat.arsenal"

## A shot left the muzzle. Carries the [DotShot] before it has been resolved, so a
## client can spawn a tracer from it without waiting for the server.
##
## [b]Check [member DotShot.replayed] before doing anything irreversible.[/b] A
## reconciling client re-runs this signal for every tick it replays.
signal fired(shot: DotShot)

## The trigger was pulled and nothing came out.
signal dry_fired(slot: int)

signal reload_started(slot: int)
signal reload_finished(slot: int, rounds: int)

## The held slot changed. [param from] is 0 when nothing was held.
signal switched(from: int, to: int)

## The magazine or reserve of a slot changed for any reason.
signal ammo_changed(slot: int, ammo: int, reserve: int)

## A weapon was added or removed.
signal inventory_changed()

@export_group("Simulation")

## Must match whatever drives [method simulate_tick]. Every duration in every weapon
## is converted against it.
@export_range(1, 240, 1) var tick_rate: int = 60

## Highest slot number a command may select.
@export_range(1, 16, 1) var max_slots: int = 8

@export_group("Wiring")

## Where shots start. Resolves to a [Node3D]; its global origin is the muzzle and its
## transform is not otherwise used — the direction comes from the command, because the
## command is what replicates.
##
## Left unresolved, the parent is used when it is a [Node3D], and the world origin
## otherwise — which is visible immediately, and is the point: a muzzle silently at
## the world origin is a weapon that shoots the floor.
@export var muzzle_ref: DotNodeRef = null

@export_group("Rules")

## Switch to a weapon that has ammunition when the held one runs out entirely.
@export var auto_switch_on_empty: bool = true

## Refuse everything. Set while dead, in warmup, or in a no-combat zone.
@export var disabled: bool = false

## How fast the carrier is moving, 0 to 1, for spread.
##
## [b]Set from the simulated movement state, not from a rendered one.[/b] An
## interpolated render position differs between client and server by design, and
## feeding it in here makes the spread differ too — which is a mispredicted shot on
## every tick the player is moving.
var movement: float = 0.0

var airborne: bool = false

var crouched: bool = false

## slot -> [DotWeaponState].
var _slots: Dictionary = {}

## Currently held slot, or 0.
var _current: int = 0

## Slot held before this one, for [constant DotCombatCommand.BUTTON_LAST].
var _previous: int = 0

## Slot being switched to while a holster runs. 0 when not switching.
var _pending: int = 0

## Tick the pending switch completes on.
var _switch_tick: int = -1

## Reserve shared between weapons with the same [member DotWeapon.ammo_type].
var _pools: Dictionary = {}

var _last_command: DotCombatCommand = null
var _shot_index: int = 0
var _muzzle: Node3D = null
var _replaying: bool = false


func _ready() -> void:
	if Engine.is_editor_hint():
		return
	_resolve_muzzle()


func _resolve_muzzle() -> void:
	if muzzle_ref != null:
		_muzzle = muzzle_ref.resolve_or_null(self, CHANNEL) as Node3D

	if _muzzle == null:
		# An arsenal is a plain Node — it holds no transform of its own, so it cannot
		# be the muzzle. The parent usually is: the player, or the weapon model.
		_muzzle = get_parent() as Node3D


# --- Inventory -------------------------------------------------------------

## Adds a weapon, in its own slot or in [param slot].
##
## Giving a weapon that is already held tops up its reserve instead, which is what a
## pickup of a weapon you already have should do and is otherwise a special case every
## caller has to write.
func give(weapon: DotWeapon, slot: int = 0, full: bool = true) -> DotResult:
	if weapon == null:
		return DotResult.fail(DotError.CODE_INVALID, "give() with no weapon.")

	var target := slot if slot > 0 else weapon.slot
	target = clampi(target, 1, max_slots)

	var existing: DotWeaponState = _slots.get(target)

	if existing != null and existing.weapon() != null and existing.weapon().id == weapon.id:
		var taken := existing.add_reserve(weapon.reserve)
		if taken > 0:
			ammo_changed.emit(target, existing.ammo, existing.reserve)
		return DotResult.success(taken)

	var state := DotWeaponState.for_weapon(weapon, tick_rate, full)
	_slots[target] = state

	inventory_changed.emit()
	ammo_changed.emit(target, state.ammo, state.reserve)

	if _current == 0:
		select(target, 0)

	return DotResult.success(target)


## Removes whatever is in [param slot]. Switches away if it was held.
func take(slot: int) -> DotResult:
	if not _slots.has(slot):
		return DotResult.fail(DotError.CODE_INVALID, "Slot %d is empty." % slot)

	_slots.erase(slot)

	if _current == slot:
		_current = 0
		var next := _best_slot()
		if next > 0:
			select(next, 0)

	if _previous == slot:
		_previous = 0

	inventory_changed.emit()
	return DotResult.success(null)


## Empties the arsenal. What death does.
func clear() -> void:
	_slots.clear()
	_current = 0
	_previous = 0
	_pending = 0
	_switch_tick = -1
	_shot_index = 0
	_last_command = null
	inventory_changed.emit()


func has_slot(slot: int) -> bool:
	return _slots.has(slot)


func state_at(slot: int) -> DotWeaponState:
	return _slots.get(slot)


func current_slot() -> int:
	return _current


func current() -> DotWeaponState:
	return _slots.get(_current)


func current_weapon() -> DotWeapon:
	var state := current()
	return state.weapon() if state != null else null


func slots() -> Array[int]:
	var out: Array[int] = []
	for key in _slots.keys():
		out.append(int(key))
	out.sort()
	return out


func is_switching() -> bool:
	return _pending > 0


## Adds reserve ammunition to every weapon drawing on [param pool].
##
## Returns how much was actually taken across all of them. An ammunition pickup that
## nothing can hold should not disappear, and this is how a caller knows.
func add_ammo(pool: StringName, amount: int) -> int:
	var taken := 0

	for key in _slots.keys():
		var state: DotWeaponState = _slots[key]
		var weapon := state.weapon()

		if weapon == null or weapon.pool_id() != pool:
			continue

		var got := state.add_reserve(amount - taken)

		if got > 0:
			taken += got
			ammo_changed.emit(int(key), state.ammo, state.reserve)

		if taken >= amount:
			break

	return taken


# --- Switching -------------------------------------------------------------

## Begins switching to [param slot]. Returns false if it cannot.
##
## The switch is not instant: the current weapon holsters, then the new one deploys,
## and only then can it fire. Both durations come from the weapons themselves.
func select(slot: int, tick: int) -> bool:
	if disabled or slot == _current or not _slots.has(slot):
		return false

	if _pending == slot:
		return false

	var holster := 0
	var held := current()

	if held != null and held.weapon() != null:
		holster = held.weapon().holster_ticks(tick_rate)
		held.cancel_reload()

	if holster <= 0:
		_complete_switch(slot, tick)
		return true

	_pending = slot
	_switch_tick = tick + holster
	return true


func _complete_switch(slot: int, tick: int) -> void:
	var from := _current

	if from != slot:
		_previous = from

	_current = slot
	_pending = 0
	_switch_tick = -1

	var state := current()
	if state != null:
		state.deploy(tick)

	switched.emit(from, slot)


## The slot with the most usable ammunition, for auto-switching. 0 when none has any.
func _best_slot() -> int:
	var best := 0
	var best_rounds := 0

	for key in _slots.keys():
		var state: DotWeaponState = _slots[key]

		if not state.has_ammo() and state.missing() <= 0:
			continue

		var rounds := state.ammo + state.reserve

		if state.weapon() != null and state.weapon().infinite_reserve:
			# An infinite weapon is the fallback, never the preference: switching to
			# the starting pistol over a rifle with rounds left is not what running
			# out of shotgun shells should do.
			rounds = 1

		if rounds > best_rounds:
			best_rounds = rounds
			best = int(key)

	return best


# --- Simulation ------------------------------------------------------------

## Marks the following ticks as a reconciliation replay.
##
## Signals still fire — a game may want to re-run a purely visual consequence — but
## every [DotShot] produced carries [member DotShot.replayed], and the shot index does
## not advance, so a replayed shot scatters exactly as the original did.
func begin_replay() -> void:
	_replaying = true


func end_replay() -> void:
	_replaying = false


func is_replaying() -> bool:
	return _replaying


## Advances one tick and returns the shots it produced.
##
## The order matters and is not arbitrary: switching resolves first so a command that
## both switches and fires does not fire the old weapon, reloading advances before
## firing so a reload finishing this tick makes its rounds available, and the trigger
## is read last.
func simulate_tick(
	tick: int,
	delta: float,
	command: DotCombatCommand
) -> Array[DotShot]:
	var shots: Array[DotShot] = []

	if command == null:
		command = _last_command if _last_command != null else DotCombatCommand.new()

	_advance_switch(tick)
	_apply_selection(tick, command)

	var state := current()

	if state == null:
		_last_command = command.duplicate_command()
		return shots

	var rounds := state.advance_reload(tick)

	if rounds > 0:
		reload_finished.emit(_current, rounds)
		ammo_changed.emit(_current, state.ammo, state.reserve)

	if disabled:
		_last_command = command.duplicate_command()
		return shots

	if command.just_pressed(DotCombatCommand.BUTTON_RELOAD, _last_command):
		if state.begin_reload(tick):
			reload_started.emit(_current)

	shots = _run_trigger(tick, command, state)

	state.decay(tick, delta)

	if not command.is_pressed(DotCombatCommand.BUTTON_ATTACK):
		state.release_trigger()

	_maybe_auto_reload(tick, state)
	_maybe_auto_switch(tick, state)

	_last_command = command.duplicate_command()
	return shots


func _advance_switch(tick: int) -> void:
	if _pending > 0 and tick >= _switch_tick:
		_complete_switch(_pending, tick)


func _apply_selection(tick: int, command: DotCombatCommand) -> void:
	var pressed := command.pressed_since(_last_command)

	if command.slot > 0 and command.slot != _current:
		select(command.slot, tick)
		return

	if (pressed & DotCombatCommand.BUTTON_LAST) != 0 and _previous > 0:
		select(_previous, tick)
		return

	if (pressed & DotCombatCommand.BUTTON_NEXT) != 0:
		select(_adjacent_slot(1), tick)
		return

	if (pressed & DotCombatCommand.BUTTON_PREVIOUS) != 0:
		select(_adjacent_slot(-1), tick)


func _adjacent_slot(step: int) -> int:
	var order := slots()

	if order.is_empty():
		return 0

	var index := order.find(_current)

	if index < 0:
		return order[0]

	return order[wrapi(index + step, 0, order.size())]


func _run_trigger(
	tick: int,
	command: DotCombatCommand,
	state: DotWeaponState
) -> Array[DotShot]:
	var shots: Array[DotShot] = []
	var weapon := state.weapon()

	if weapon == null:
		return shots

	var held := command.is_pressed(DotCombatCommand.BUTTON_ATTACK)
	var pressed := command.just_pressed(DotCombatCommand.BUTTON_ATTACK, _last_command)

	if pressed and weapon.fire_mode == DotWeapon.Fire.BURST:
		state.begin_burst()

	# Firing interrupts a per-round reload rather than being refused by it. That is
	# the whole point of loading a pump shotgun one shell at a time.
	if (pressed or held) and weapon.reload_per_round and state.is_reloading(tick):
		if state.ammo > 0:
			state.cancel_reload()

	var wants := false

	match weapon.fire_mode:
		DotWeapon.Fire.SEMI:
			wants = pressed
		DotWeapon.Fire.BURST:
			wants = state.burst_remaining > 0
		_:
			wants = held

	if not wants:
		return shots

	if not state.can_fire(tick):
		# Only an edge produces the click. A held trigger on an empty weapon that
		# reported every tick would be sixty clicks a second.
		if pressed and not state.has_ammo():
			dry_fired.emit(_current)
		return shots

	# A weapon whose rate exceeds the tick rate fires more than once per tick. The
	# loop is bounded by the interval rather than trusted to terminate: a
	# misconfigured rpm should be a fast weapon, not a hang.
	var produced := 0

	while state.can_fire(tick) and produced < 8:
		if not state.consume(tick):
			break

		var shot := _build_shot(tick, command, state, weapon)
		shots.append(shot)
		produced += 1

		ammo_changed.emit(_current, state.ammo, state.reserve)
		fired.emit(shot)

		if weapon.fire_mode == DotWeapon.Fire.SEMI:
			break

		if state.next_fire_tick > tick:
			break

	return shots


func _build_shot(
	tick: int,
	command: DotCombatCommand,
	state: DotWeaponState,
	weapon: DotWeapon
) -> DotShot:
	if not _replaying:
		_shot_index += 1

	var shot := DotShot.make(weapon, attacker_id(), tick, _shot_index)
	shot.replayed = _replaying
	shot.origin = muzzle_position()
	shot.direction = command.aim_direction()
	shot.spread = state.spread_degrees(movement, airborne, crouched)
	shot.scatter()
	return shot


func _maybe_auto_reload(tick: int, state: DotWeaponState) -> void:
	var weapon := state.weapon()

	if weapon == null or not weapon.auto_reload:
		return

	if state.ammo > 0 or state.is_reloading(tick):
		return

	if state.begin_reload(tick):
		reload_started.emit(_current)


func _maybe_auto_switch(tick: int, state: DotWeaponState) -> void:
	if not auto_switch_on_empty or _pending > 0:
		return

	if state.has_ammo() or state.missing() > 0 or state.is_reloading(tick):
		return

	var next := _best_slot()

	if next > 0 and next != _current:
		select(next, tick)


# --- Geometry --------------------------------------------------------------

## Where the current weapon's shots start.
func muzzle_position() -> Vector3:
	if _muzzle == null or not is_instance_valid(_muzzle):
		_resolve_muzzle()

	if _muzzle != null and _muzzle.is_inside_tree():
		return _muzzle.global_position

	return Vector3.ZERO


## The id this arsenal's shots are attributed to.
##
## Overridden by a game that keys damage on something other than the carrier node's
## instance id — a session id or a network id, which is what a server actually wants.
## Defaults to the parent's instance id so an arsenal works with no wiring at all.
func attacker_id() -> int:
	return get_parent().get_instance_id() if get_parent() != null else 0


# --- Diagnostics -----------------------------------------------------------

func describe() -> Dictionary:
	var inventory := []

	for slot in slots():
		var state: DotWeaponState = _slots[slot]
		var entry := state.describe()
		entry["slot"] = slot
		entry["held"] = slot == _current
		inventory.append(entry)

	return {
		"current": _current,
		"previous": _previous,
		"pending": _pending,
		"switch_tick": _switch_tick,
		"disabled": disabled,
		"movement": movement,
		"slots": inventory,
	}


func describe_lines() -> PackedStringArray:
	var out := PackedStringArray()

	if _slots.is_empty():
		out.append("  (empty)")
		return out

	for slot in slots():
		var state: DotWeaponState = _slots[slot]
		var weapon := state.weapon()
		out.append("  %s%d %-14s %3d/%-4d%s" % [
			"*" if slot == _current else " ",
			slot,
			weapon.id if weapon != null else &"?",
			state.ammo,
			state.reserve,
			"  reloading" if state.reload_end_tick >= 0 else "",
		])

	return out
