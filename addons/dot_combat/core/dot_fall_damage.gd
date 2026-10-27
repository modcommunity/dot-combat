class_name DotFallDamage
extends Node
## Turns a controller's landing impact into damage through the combat manager.
##
## One per player. [member controller] is anything with a [code]landed(impact)[/code] signal
## (dot-player-controller's DotFpsController; duck-typed, this addon names no other addon).
## Damage goes through [method DotCombatManager.apply_damage], which applies only on the
## authority, so a client (including a prediction replay of the same landing) never hurts
## anyone; the server's health reaches clients the usual way.

const CHANNEL := "combat.fall"

## The shared numbers. Assign the game's one [DotFallDamageRules].
var rules: DotFallDamageRules = null

## The controller to listen to.
@export var controller: DotNodeRef = DotNodeRef.new()

## The combat manager to apply damage through.
@export var combat: DotNodeRef = DotNodeRef.new()

## Entity id of the player taking the damage.
var victim: int = 0

## Optional [code]func() -> bool[/code]: true while the host stands in water.
var in_water: Callable = Callable()

## Damage type id; the game registers it ([code]fall[/code] by default).
var damage_type_id: StringName = &"fall"

var _controller: Node = null
var _combat: DotCombatManager = null
var landings: int = 0
var damaged: int = 0
var last_damage: float = 0.0


func _ready() -> void:
	var _ok := attach()


## Resolves both refs and connects. False (and a warning) when either is missing.
func attach() -> bool:
	_controller = controller.resolve_or_null(self, CHANNEL)
	_combat = combat.resolve_or_null(self, CHANNEL) as DotCombatManager

	if _controller == null or _combat == null or not _controller.has_signal(&"landed"):
		DotLog.warn(CHANNEL, "fall damage has no controller or combat manager; inert", {})
		return false

	if not _controller.is_connected(&"landed", on_landed):
		_controller.connect(&"landed", on_landed)

	return true


## A landing at [param impact] m/s. Public so a host without the signal can call it.
func on_landed(impact: float) -> DotDamage:
	landings += 1

	if rules == null or _combat == null or not _combat.is_authority or victim == 0:
		return null

	var surface := &""

	if _controller != null and _controller.get(&"state") != null:
		surface = _controller.get(&"state").get(&"surface") as StringName

	var wet := in_water.is_valid() and bool(in_water.call())
	var amount := rules.damage_for(impact, surface, wet)

	if amount <= 0.0:
		return null

	var hit := DotDamage.make(0, victim, amount, _combat.damage_type(damage_type_id))
	hit.context = {"why": &"fall", "impact": impact}
	damaged += 1
	last_damage = amount
	DotLog.debug(CHANNEL, "fall damage", {"victim": victim, "impact": impact, "amount": amount})
	return _combat.apply_damage(hit)


func describe() -> Dictionary:
	return {
		"victim": victim, "landings": landings, "damaged": damaged, "last_damage": last_damage,
		"attached": _controller != null and _combat != null,
		"rules": rules.describe() if rules != null else {},
	}
