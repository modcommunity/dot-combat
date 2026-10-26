class_name DotDefib
extends RefCounted

## A defibrillator as data: what one may do, how many times, and why it refused.
## Pure decision, no scene; the game owns the hold, the body and the revive.

## Seconds the user holds the key at the body before the shock.
var charge_seconds: float = 4.0
## Metres from the user to the body.
var reach: float = 2.0
## Share of the revived one's maximum health they come back with.
var revive_fraction: float = 0.4
## Seconds the revived cannot be hurt.
var invulnerable_seconds: float = 2.0
## Revives one item holds.
var charges: int = 1
## Seconds after a shock before the item may be used again.
var cooldown_seconds: float = 8.0
## Seconds since death after which the body is past saving; 0 or less never.
var max_body_age: float = 60.0
## Metres the user may drift while holding before it is interrupted.
var move_tolerance: float = 0.6

## Time (the caller's clock) the item is next ready.
var ready_at: float = 0.0


## Ok when a try may start, or a [DotError.CODE_STATE] failure whose message says why.
func check(now: float, body_age: float, distance: float) -> DotResult:
	if charges <= 0:
		return DotResult.fail(DotError.CODE_STATE, "The defibrillator is spent.")

	if now < ready_at:
		return DotResult.fail(DotError.CODE_STATE, "The defibrillator is recharging.")

	if distance > reach:
		return DotResult.fail(DotError.CODE_STATE, "Too far from the body.")

	if max_body_age > 0.0 and body_age > max_body_age:
		return DotResult.fail(DotError.CODE_STATE, "Too late: the body is past saving.")

	return DotResult.success(true)


## Takes one charge and starts the cooldown, at [param now].
func spend(now: float) -> void:
	charges = maxi(charges - 1, 0)
	ready_at = now + cooldown_seconds


## The health a revived body with [param max_health] comes back with.
func revive_health(max_health: float) -> float:
	return maxf(max_health * revive_fraction, 1.0)


func describe() -> Dictionary:
	return {"charges": charges, "ready_at": ready_at, "reach": reach, "charge_seconds": charge_seconds,
		"revive_fraction": revive_fraction, "max_body_age": max_body_age}
