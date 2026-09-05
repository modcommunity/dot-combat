@tool
class_name DotDamageRules
extends Resource

## The rules that turn a hit into a number, in one editable place.
##
## Separate from [DotCombatConfig] because these are a game-mode's decision rather
## than an installation's: warmup and the live round of the same match want different
## friendly fire, and swapping a resource is a cleaner way to say that than reaching
## into a config that also holds tick rates and log levels.

@export_group("Teams")

## Whether a shot may damage a team-mate at all. Off refuses it outright, which is
## different from scaling it to zero: refused damage produces no hit marker, no
## flinch and no kill credit.
@export var friendly_fire: bool = false

## Multiplies damage to a team-mate when [member friendly_fire] is on. Combined with
## the damage type's own [member DotDamageType.friendly_scale].
@export_range(0.0, 2.0, 0.05) var friendly_scale: float = 1.0

## Whether damage to a team-mate is mirrored back at the attacker. The classic
## deterrent, and the reason [member friendly_fire] is survivable in a public game.
@export_range(0.0, 2.0, 0.05) var friendly_reflect: float = 0.0

@export_group("Self")

## Whether a player can damage themselves at all. Rocket jumping needs this on.
@export var self_damage: bool = true

@export_group("Hit groups")

## Whether per-hit-group multipliers apply.
##
## Off makes every hit do body damage, which is what a game without headshots wants
## and what an explosion always wants — see [member DotDamageType.uses_hit_groups].
@export var hit_groups: bool = true

@export_group("Falloff")

@export var falloff: bool = true

@export_group("Clamping")

## Damage below this is refused. Zero means never.
##
## Above zero, a shot from the far edge of a falloff curve doing 0.4 damage stops
## producing a hit marker, which players read as a bug in the hit registration rather
## than as a weapon at its maximum range.
@export_range(0.0, 100.0, 0.5) var minimum: float = 0.0

## Damage above this is clamped. Zero means never.
##
## Worth setting on any server that accepts client-reported damage for anything: it
## turns a broken or hostile number into a large hit rather than into an instant kill
## of everyone in the level.
@export_range(0.0, 100000.0, 1.0) var maximum: float = 0.0


static func permissive() -> DotDamageRules:
	var rules := DotDamageRules.new()
	rules.friendly_fire = true
	rules.self_damage = true
	return rules


static func strict() -> DotDamageRules:
	var rules := DotDamageRules.new()
	rules.friendly_fire = false
	rules.self_damage = false
	rules.maximum = 1000.0
	return rules


func describe() -> Dictionary:
	return {
		"friendly_fire": friendly_fire,
		"friendly_scale": friendly_scale,
		"reflect": friendly_reflect,
		"self_damage": self_damage,
		"hit_groups": hit_groups,
		"falloff": falloff,
		"minimum": minimum,
		"maximum": maximum,
	}
