class_name DotCombatNetSync
extends RefCounted

## What a networked fighter has to replicate of its [DotHealth], and how to move it in
## and out.
##
## [b]Health only.[/b] Until dot-weapon existed this also carried the slot, the
## magazine and the reserve, which made dot-combat's wire format describe a thing
## dot-combat no longer owns. The weapon half is now `DotWeaponNetSync` in dot-weapon,
## and a game that uses both concatenates the two spec lists. A game with health and no
## weapons — which is most co-operative and survival games before their first weapon —
## now replicates three properties instead of six.
##
## [b]dot-net is not a dependency and is not imported here.[/b] Only dot-core is a hard
## dependency in this family, and in GDScript that is not merely a preference: a script
## that [i]mentions[/i] a [code]class_name[/code] the project does not have fails to
## parse, and takes every script that references it down with it. The same reason
## [code]DotTransportENet[/code] reaches ENet through [method ClassDB.instantiate]
## rather than by name.
##
## So dot-combat compiles and runs with dot-core alone, and the bridge that joins the
## two lives in the host game. This class is everything that bridge would otherwise
## have to work out for itself.
##
## [codeblock]
## class_name PlayerCombat extends DotNetBehaviour
##
## @export var health: DotHealth
## @export var arsenal: DotWeaponArsenal
##
## var net_health: int
## var net_armour: int
## var net_alive: bool
##
## func _register_net_vars() -> void:
##     for spec in DotCombatNetSync.specs() + DotWeaponNetSync.specs():
##         var declaration := replicate(spec.property, DotNetVar.Type[spec.type])
##         if spec.bits > 0:
##             declaration.bits(spec.bits)
##         if spec.owner_only:
##             declaration.to_owner_only()
##
## func _net_simulate(tick: int, delta: float) -> void:
##     var outcome := arsenal.simulate_tick(_command, _context(tick))
##     if identity.is_authoritative:
##         for shot in outcome.shots:
##             _manager.resolve_shot(shot, _view_tick)
##     DotCombatNetSync.pull(health, self)
##     DotWeaponNetSync.pull(arsenal, self)
##
## func _net_state_applied(_tick: int) -> void:
##     DotCombatNetSync.push(self, health)
##     DotWeaponNetSync.push(self, arsenal)
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


## What a fighter replicates of its health.
##
## Types are named rather than referenced so this file never mentions
## [code]DotNetVar[/code]. A bridge resolves them with
## [code]DotNetVar.Type[spec.type][/code], which is an ordinary dictionary lookup on
## the enum.
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
static func pull(health: DotHealth, target: Object) -> void:
	if target == null or health == null:
		return

	# Ceil rather than round: a player on 0.4 health is alive, and rounding that to
	# zero shows a corpse's health bar on someone who is still shooting back.
	target.set(&"net_health", clampi(int(ceil(health.health)), 0, (1 << HEALTH_BITS) - 1))
	target.set(&"net_armour", clampi(int(ceil(health.armour)), 0, (1 << HEALTH_BITS) - 1))
	target.set(&"net_alive", health.alive)


## Copies received state back into the simulation, on a peer that is not authoritative.
##
## Health is written straight through: it is the server's alone, so the received value
## is the truth. Ammunition is not like that, which is why it lives in dot-weapon's
## sync and is corrected rather than overwritten.
static func push(source: Object, health: DotHealth) -> void:
	if source == null or health == null:
		return

	health.health = float(source.get(&"net_health"))
	health.armour = float(source.get(&"net_armour"))
	health.alive = bool(source.get(&"net_alive"))


## Bits one fighter's health costs. For a bandwidth estimate.
static func estimated_bits() -> int:
	return HEALTH_BITS * 2 + 1
