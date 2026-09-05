@tool
class_name DotCombatConfig
extends DotConfig

## Everything configurable about combat. Layered like every [DotConfig]: exported
## defaults, then a JSON file, then [code]DOT_COMBAT_*[/code] environment variables,
## then [code]--combat-*[/code] arguments.

@export_group("Simulation")

## Must match the rate the arsenals and the netcode run at. Every weapon duration is
## converted against it, so a mismatch makes every weapon in the game fire at the
## wrong rate — and the symptom is "the guns feel wrong", not an error.
@export_range(1, 240, 1) var tick_rate: int = 64

@export_group("Lag compensation")

## Rewind the world to what the shooter saw before resolving a hitscan shot.
##
## [b]Off is playable and on is correct.[/b] Without it a player has to lead their
## target by their own latency, which at 80 ms and normal movement speeds is more than
## a body width. With it, the victim occasionally dies behind cover — which is the
## trade every shooter that has ever shipped has made, in this direction.
@export var lag_compensation: bool = true

## Most milliseconds a shot may be rewound.
##
## The cap is a cheat bound, not a performance one: a client that reports an old view
## tick is asking the server to resolve its shot against a world that no longer
## exists, and without a cap it can ask for one arbitrarily far back.
@export_range(0.0, 1000.0, 5.0) var max_rewind_ms: float = 250.0

## Extra milliseconds allowed on top of a client's measured latency.
##
## Covers interpolation delay and jitter. Too small and legitimate shots on
## high-jitter connections are resolved against the wrong tick; too large and it is
## the cap that stops mattering.
@export_range(0.0, 500.0, 5.0) var rewind_slack_ms: float = 60.0

@export_group("Validation")

## Most metres a reported muzzle may be from where the server believes the shooter
## is. Beyond it the server uses its own position.
##
## Never trust a client's origin outright: a shot that starts wherever the client says
## is a shot through every wall in the level.
@export_range(0.0, 100.0, 0.1) var max_origin_error: float = 2.0

## Shots one entity may resolve per second before the rest are dropped.
##
## Above any legitimate weapon's rate on purpose. This catches a client sending a
## thousand fire commands a tick, not a client with a fast weapon.
@export_range(1.0, 1000.0, 1.0) var shots_per_second: float = 60.0

## Refuse a shot whose tick is in the server's future.
@export var reject_future_ticks: bool = true

@export_group("Damage")

## Applied when a weapon names no [DotDamageType]. Created on demand.
@export var default_damage_type: StringName = &"bullet"

## Multiplies all damage. For a mod, for a warmup round, and for testing.
@export_range(0.0, 10.0, 0.05) var damage_scale: float = 1.0

@export_group("Diagnostics")

## Log every resolved shot at debug level, with its scaling trace.
##
## Expensive and extremely noisy — one line per pellet — and the fastest way to answer
## "why did that shot do 14 damage".
@export var trace_shots: bool = false


func env_prefix() -> String:
	return "DOT_COMBAT_"


func cli_prefix() -> String:
	return "--combat-"


func validate() -> DotResult:
	if max_rewind_ms > 0.0 and not lag_compensation:
		DotLog.debug(
			"combat.config",
			"max_rewind_ms is set but lag compensation is off; it will not be used"
		)

	if max_origin_error <= 0.0:
		# Zero means "the client's origin must match the server's exactly", which no
		# real client achieves — its position is a tick ahead by construction. The
		# result is every shot being relocated to the server's origin, which is safe
		# and makes the game feel broken.
		DotLog.warn(
			"combat.config",
			"max_origin_error of 0 relocates every shot to the server's own position"
		)

	if damage_scale <= 0.0:
		return DotResult.fail(
			DotError.CODE_INVALID,
			"damage_scale of %.2f means no weapon can ever do damage." % damage_scale
		)

	return DotResult.success(null)


func rewind_slack_sec() -> float:
	return rewind_slack_ms * 0.001


func max_rewind_sec() -> float:
	return max_rewind_ms * 0.001


func describe_summary() -> String:
	return "%d Hz%s x%.2f" % [
		tick_rate,
		", lagcomp %dms" % int(max_rewind_ms) if lag_compensation else ", no lagcomp",
		damage_scale,
	]
