class_name DotCombatNetSync
extends RefCounted

## What a networked fighter has to replicate, and how to move it in and out of a
## [DotHealth] and a [DotArsenal].
##
## [b]dot-net is not a dependency and is not imported here.[/b] Only dot-core is a
## hard dependency in this family, and in GDScript that is not merely a preference: a
## script that [i]mentions[/i] a [code]class_name[/code] the project does not have
## fails to parse, and takes every script that references it down with it. The same
## reason [code]DotTransportENet[/code] reaches ENet through
## [method ClassDB.instantiate] rather than by name.
##
## So dot-combat compiles and runs with dot-core alone, and the bridge that joins the
## two lives in the host game. This class is everything that bridge would otherwise
## have to work out for itself.
##
## [codeblock]
## class_name PlayerCombat extends DotNetBehaviour
##
## @export var health: DotHealth
## @export var arsenal: DotArsenal
##
## var net_health: int
## var net_armour: int
## var net_alive: bool
## var net_slot: int
## var net_ammo: int
## var net_reserve: int
##
## func _register_net_vars() -> void:
##     for spec in DotCombatNetSync.specs():
##         var declaration := replicate(spec.property, DotNetVar.Type[spec.type])
##         if spec.bits > 0:
##             declaration.bits(spec.bits)
##         if spec.owner_only:
##             declaration.to_owner_only()
##
## func _net_simulate(tick: int, delta: float) -> void:
##     var shots := arsenal.simulate_tick(tick, delta, _command)
##     if identity.is_authoritative:
##         for shot in shots:
##             _manager.resolve_shot(shot, _view_tick)
##     DotCombatNetSync.pull(health, arsenal, self)
##
## func _net_state_applied(_tick: int) -> void:
##     DotCombatNetSync.push(self, health, arsenal)
## [/codeblock]
##
## And the four lines that turn lag compensation on, given a [code]DotNetManager[/code]
## called [code]net[/code]:
##
## [codeblock]
## manager.rewind_fn = func(view_tick: float) -> void:
##     net.history.rewind(view_tick, net.registry.all())
## manager.restore_fn = net.history.restore
## [/codeblock]

## Quantisation for the replicated numbers.
##
## Health and armour are replicated as integers, not floats. A health bar is read at
## whole numbers, the wire cost is a third, and — the part that matters — an integer
## compares exactly, so a reconciling client does not see a correction on every tick
## because the server's 73.4001 differs from its own 73.4.
const HEALTH_BITS := 11
const AMMO_BITS := 9
const RESERVE_BITS := 11
const SLOT_BITS := 5


## What a fighter replicates.
##
## Types are named rather than referenced so this file never mentions
## [code]DotNetVar[/code]. A bridge resolves them with
## [code]DotNetVar.Type[spec.type][/code], which is an ordinary dictionary lookup on
## the enum.
##
## [code]owner_only[/code] is not a bandwidth optimisation. Exact ammunition and
## reserve are information an opponent should not have, and sending them to everyone
## is how a modified client knows when to push.
static func specs() -> Array[Dictionary]:
	return [
		{
			"property": &"net_health",
			"type": "UINT",
			"bits": HEALTH_BITS,
			"owner_only": false,
			"interpolated": false,
		},
		{
			"property": &"net_armour",
			"type": "UINT",
			"bits": HEALTH_BITS,
			"owner_only": false,
			"interpolated": false,
		},
		{
			"property": &"net_alive",
			"type": "BOOL",
			"bits": 0,
			"owner_only": false,
			"interpolated": false,
		},
		{
			"property": &"net_slot",
			"type": "UINT",
			"bits": SLOT_BITS,
			"owner_only": false,
			"interpolated": false,
		},
		{
			"property": &"net_ammo",
			"type": "UINT",
			"bits": AMMO_BITS,
			"owner_only": true,
			"interpolated": false,
		},
		{
			"property": &"net_reserve",
			"type": "UINT",
			"bits": RESERVE_BITS,
			"owner_only": true,
			"interpolated": false,
		},
	]


## Property names, in declaration order. For a bridge that builds its own.
static func properties() -> Array[StringName]:
	var out: Array[StringName] = []
	for spec in specs():
		out.append(spec["property"])
	return out


## Copies the simulation state onto a replicating object.
##
## [param target] is anything with settable properties — a [code]DotNetBehaviour[/code]
## in practice — which is why it is [Object] and not a named type.
static func pull(
	health: DotHealth,
	arsenal: DotArsenal,
	target: Object
) -> void:
	if target == null:
		return

	if health != null:
		# Ceil rather than round: a player on 0.4 health is alive, and rounding that
		# to zero shows a corpse's health bar on someone who is still shooting back.
		target.set(&"net_health", clampi(int(ceil(health.health)), 0, (1 << HEALTH_BITS) - 1))
		target.set(&"net_armour", clampi(int(ceil(health.armour)), 0, (1 << HEALTH_BITS) - 1))
		target.set(&"net_alive", health.alive)

	if arsenal != null:
		target.set(&"net_slot", clampi(arsenal.current_slot(), 0, (1 << SLOT_BITS) - 1))

		var state := arsenal.current()

		if state != null:
			target.set(&"net_ammo", clampi(state.ammo, 0, (1 << AMMO_BITS) - 1))
			target.set(&"net_reserve", clampi(state.reserve, 0, (1 << RESERVE_BITS) - 1))
		else:
			target.set(&"net_ammo", 0)
			target.set(&"net_reserve", 0)


## Copies received state back into the simulation, on a peer that is not authoritative.
##
## [b]Health is written straight through and ammunition is not.[/b] Health is the
## server's alone, so the received value is the truth. Ammunition is predicted
## locally, and overwriting it every snapshot would undo the prediction on every tick
## — the received value is only applied when it disagrees by more than the prediction
## could account for, which is what a correction is.
static func push(
	source: Object,
	health: DotHealth,
	arsenal: DotArsenal
) -> void:
	if source == null:
		return

	if health != null:
		health.health = float(source.get(&"net_health"))
		health.armour = float(source.get(&"net_armour"))
		health.alive = bool(source.get(&"net_alive"))

	if arsenal == null:
		return

	var slot := int(source.get(&"net_slot"))

	if slot > 0 and slot != arsenal.current_slot() and arsenal.has_slot(slot):
		arsenal.select(slot, 0)


## Applies an authoritative ammunition correction to a predicted arsenal.
##
## Called by the owning client when reconciliation says its prediction was wrong.
## Separate from [method push] because a non-owner has no prediction to correct and
## must not have its display overwritten by another player's ammunition.
static func correct_ammo(source: Object, arsenal: DotArsenal) -> void:
	if source == null or arsenal == null:
		return

	var state := arsenal.current()

	if state == null:
		return

	state.ammo = int(source.get(&"net_ammo"))
	state.reserve = int(source.get(&"net_reserve"))


## Bits one fighter's full state costs. For a bandwidth estimate.
static func estimated_bits() -> int:
	return HEALTH_BITS * 2 + 1 + SLOT_BITS + AMMO_BITS + RESERVE_BITS
