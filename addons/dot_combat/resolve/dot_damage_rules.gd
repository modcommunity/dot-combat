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

## Whether a shot passes through a team-mate whose hitboxes already hold the muzzle.
##
## A ray that starts inside a hitbox hits it at distance zero, which is right for a
## shotgun pressed against an enemy's chest. In a game where team-mates do not collide
## (most networked ones: player-player collision is what makes prediction disagree), two
## of them can stand in one place, and then every shot, aimed anywhere, hits the friend
## at zero metres and nothing else. That friend was never aimed at. On, the manager
## leaves such a team-mate out of the shot and it goes on to what it was aimed at; an
## enemy holding the muzzle is still a point-blank hit, and a team-mate merely in the
## line (muzzle outside them) is still hit under [member friendly_fire].
##
## On regardless of [member friendly_fire]: with friendly fire off the stacked friend
## does not take damage, but still eats the bullet, so the shot that should have reached
## the enemy is lost. Off restores the old geometry-only behaviour. For a rule this flag
## cannot express, assign [member DotCombatManager.pass_through_fn].
@export var pass_through_team_mate_at_muzzle: bool = true

## Whether a shot passes through every team-mate, wherever they stand in the line.
##
## The broad form of [member pass_through_team_mate_at_muzzle]: a team-mate between the
## shooter and the target never blocks the shot and is never hit by it, so with this on
## [member friendly_fire] only reaches team-mates through splash. Off by default, because
## "a friend in your line of fire takes the bullet" is the rule most team modes want and
## the deterrent that makes players mind where they shoot; an operator who would rather
## crowded doorways stopped eating shots turns it on. An enemy is always hit.
##
## Rays only: an explosion's splash is a separate trace and still reaches team-mates under
## [member friendly_fire]. Implies the muzzle rule. See [method set_pass_through_level].
@export var pass_through_team_mates: bool = false

@export_group("Self")

## Whether a player can damage themselves at all. Rocket jumping needs this on.
@export var self_damage: bool = true

@export_group("Hit groups")

## Whether per-hit-group multipliers apply.
##
## Off makes every hit do body damage, which is what a game without headshots wants
## and what an explosion always wants — see [member DotDamageType.uses_hit_groups].
@export var hit_groups: bool = true

@export_group("Criticals")

## Whether a headshot is a critical hit.
##
## [b]A flag, not a number.[/b] With [member critical_scale] at 1 a critical does exactly
## the damage it did before; what changes is [member DotDamage.critical], which is what a
## game hangs its rewards on — a burst of coins out of the body, a health drop, a meter
## filling, a marker over the victim. The head's own multiplier is still the hit group's.
@export var critical_headshots: bool = true

## Chance, 0 to 1, that any other hit is a critical too. 0 for none.
##
## [b]Rolled from the hit itself, never from a random stream[/b] — attacker, victim, tick
## and weapon hashed — so the server, a client predicting the marker, and a replay of the
## same hit all agree about it, and a seed nobody shares cannot make them disagree.
@export_range(0.0, 1.0, 0.01) var critical_chance: float = 0.0

## Extra damage multiplier on a critical, applied after the hit group. 1 for none.
@export_range(0.0, 10.0, 0.05) var critical_scale: float = 1.0

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


## The two pass-through rules as one number, which is what a server cvar holds:
## [code]0[/code] team-mates are hit and block like anybody else, [code]1[/code] a shot
## passes through a team-mate holding the muzzle (the default), [code]2[/code] a shot
## passes through every team-mate in its line.
const PASS_THROUGH_NONE := 0
const PASS_THROUGH_AT_MUZZLE := 1
const PASS_THROUGH_ALWAYS := 2


## [member pass_through_team_mate_at_muzzle] and [member pass_through_team_mates] as one
## of the PASS_THROUGH_* levels.
func pass_through_level() -> int:
	if pass_through_team_mates:
		return PASS_THROUGH_ALWAYS
	return PASS_THROUGH_AT_MUZZLE if pass_through_team_mate_at_muzzle else PASS_THROUGH_NONE


## Sets both pass-through rules from a PASS_THROUGH_* level, clamped to 0..2.
func set_pass_through_level(level: int) -> void:
	var clamped := clampi(level, PASS_THROUGH_NONE, PASS_THROUGH_ALWAYS)
	pass_through_team_mates = clamped == PASS_THROUGH_ALWAYS
	pass_through_team_mate_at_muzzle = clamped >= PASS_THROUGH_AT_MUZZLE


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
		"pass_through_team_mate_at_muzzle": pass_through_team_mate_at_muzzle,
		"pass_through_team_mates": pass_through_team_mates,
		"self_damage": self_damage,
		"hit_groups": hit_groups,
		"falloff": falloff,
		"minimum": minimum,
		"maximum": maximum,
	}
