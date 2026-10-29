class_name DotStomp
extends RefCounted
## Finds who a falling player has landed on, by the numbers of [DotStompRules]. One per game.
## Pure over positions: the host feeds it feet, speeds and hulls each tick and applies the result.

const LETHAL_DAMAGE := 100000.0
const CHANNEL := "combat.stomp"

var rules: DotStompRules = DotStompRules.new()

var stomps: int = 0
var _last_tick: Dictionary = {}


## The id of the victim [param attacker] stomps this tick, or 0. [param fall_speed] is the downward speed (m/s, positive)
## the attacker had going into the tick; [param hulls] is an Array of {id, feet: Vector3, height, radius, team}.
## [param attacker_team] and each hull's team compare only when both are non-negative.
func find(attacker: int, feet: Vector3, radius: float, fall_speed: float, attacker_team: int,
		hulls: Array, tick: int, tick_rate: int) -> int:
	if not rules.enabled or fall_speed < rules.min_speed:
		return 0

	if tick - int(_last_tick.get(attacker, -1000000)) < int(rules.cooldown_sec * tick_rate):
		return 0

	var best := 0
	var best_gap := INF

	for hull: Dictionary in hulls:
		var id: int = hull["id"]

		if id == attacker:
			continue

		var team: int = hull.get("team", -1)

		if not rules.same_team and attacker_team >= 0 and team == attacker_team:
			continue

		var other: Vector3 = hull["feet"]
		var top := other.y + float(hull["height"])
		var gap := absf(feet.y - top)
		var reach := radius + float(hull["radius"])

		if gap > rules.head_tolerance:
			continue

		if Vector2(feet.x - other.x, feet.z - other.z).length() > reach:
			continue

		if gap < best_gap:
			best_gap = gap
			best = id

	if best != 0:
		_last_tick[attacker] = tick
		stomps += 1

	return best


## The damage of one stomp: a kill unless the rules name an amount.
func amount() -> float:
	return rules.damage if rules.damage > 0.0 else LETHAL_DAMAGE


func forget(attacker: int) -> void:
	var _gone := _last_tick.erase(attacker)
