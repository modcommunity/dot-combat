class_name DotDamageResolver
extends RefCounted

## Turns a raw hit into the number that will actually be applied.
##
## Everything that scales damage happens here, in one order, once — so that a
## surprising final number can be explained by reading
## [code]damage.describe()["scales"][/code] rather than by tracing four call sites.
##
## [b]The order is deliberate and is not commutative with clamping.[/b] Falloff and
## hit groups are properties of the shot; team and self scales are properties of the
## rules; the clamp is last so a game's stated maximum is a real maximum rather than
## a number three later multipliers can exceed.

const CHANNEL := "combat.resolve"

var rules: DotDamageRules = null

var hit_groups: DotHitGroup = null

## id -> team. Returns an int; anything falsy means "no team", and two entities with
## no team are never team-mates — a free-for-all must not accidentally become a truce.
##
## Left unset, nobody is on a team and friendly fire never applies.
var team_of: Callable = Callable()

## Called after the standard rules and before clamping, with the [DotDamage].
##
## The extension point for a game mode's own arithmetic: a damage boost pickup, a
## round-start immunity, a mode where the leader takes double. Mutating
## [member DotDamage.amount] or calling [method DotDamage.refuse] both work.
var adjust: Callable = Callable()


static func with_rules(p_rules: DotDamageRules) -> DotDamageResolver:
	var resolver := DotDamageResolver.new()
	resolver.rules = p_rules
	resolver.hit_groups = DotHitGroup.defaults()
	return resolver


## Applies every rule to [param damage] and returns it.
##
## The same object comes back, mutated. A refusal is an outcome, not a failure — see
## [member DotDamage.refused].
func resolve(damage: DotDamage) -> DotDamage:
	if damage == null:
		return null

	if rules == null:
		rules = DotDamageRules.new()

	var type := damage.type

	if type == null:
		damage.refuse("no damage type")
		return damage

	if damage.is_self_damage():
		if not rules.self_damage or type.self_scale <= 0.0:
			damage.refuse("self damage is off")
			return damage
		damage.scale_by(type.self_scale, "self")
	elif _same_team(damage.attacker, damage.victim):
		if not rules.friendly_fire:
			damage.refuse("friendly fire is off")
			return damage
		damage.scale_by(rules.friendly_scale * type.friendly_scale, "friendly")

	if rules.falloff and damage.distance > 0.0:
		damage.scale_by(type.falloff_scale(damage.distance), "falloff")

	if rules.hit_groups and type.uses_hit_groups and hit_groups != null:
		damage.scale_by(hit_groups.multiplier(damage.hit_group), "group")

	if adjust.is_valid():
		adjust.call(damage)

		if damage.refused:
			return damage

	if rules.maximum > 0.0 and damage.amount > rules.maximum:
		damage.scale_by(rules.maximum / damage.amount, "clamp")

	if rules.minimum > 0.0 and damage.amount < rules.minimum:
		damage.refuse("below the minimum of %.1f" % rules.minimum)

	return damage


## The damage an attacker takes back for hitting a team-mate, or null.
##
## Built from the resolved event rather than from the original, so a reflected hit
## reflects what actually landed. Deliberately not resolved again: running it back
## through [method resolve] would apply the friendly scale a second time, and would
## then be refused as self damage in any mode with self damage off.
func reflection(damage: DotDamage) -> DotDamage:
	if rules == null or rules.friendly_reflect <= 0.0:
		return null

	if damage.refused or damage.health_lost <= 0.0:
		return null

	if not _same_team(damage.attacker, damage.victim):
		return null

	if damage.is_self_damage():
		return null

	var back := DotDamage.make(
		damage.victim,
		damage.attacker,
		damage.health_lost * rules.friendly_reflect,
		damage.type
	)
	back.tick = damage.tick
	back.weapon_id = damage.weapon_id
	back.hit_group = DotHitGroup.GENERIC
	back.context["reflected_from"] = damage.attacker
	return back


func _same_team(a: int, b: int) -> bool:
	if a == 0 or b == 0 or a == b:
		return false

	if not team_of.is_valid():
		return false

	var team_a: Variant = team_of.call(a)
	var team_b: Variant = team_of.call(b)

	if typeof(team_a) != TYPE_INT or typeof(team_b) != TYPE_INT:
		return false

	# Team 0 is "no team". Two unassigned players in a free-for-all must not be
	# treated as allies, which is exactly what comparing zeroes would do.
	if int(team_a) == 0 or int(team_b) == 0:
		return false

	return int(team_a) == int(team_b)


func describe() -> Dictionary:
	return {
		"rules": rules.describe() if rules != null else {},
		"groups": Array(hit_groups.names()) if hit_groups != null else [],
		"teams": team_of.is_valid(),
		"adjust": adjust.is_valid(),
	}
