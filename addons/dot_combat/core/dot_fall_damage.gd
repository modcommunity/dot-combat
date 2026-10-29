class_name DotFallDamage
extends Node
## Turns a controller's landing impact (any node with a [code]landed(impact)[/code] signal) into damage; one per player.
## Goes through [method DotCombatManager.apply_damage], which applies only on the authority, so a client never hurts anyone.

const CHANNEL := "combat.fall"

## The shared numbers. Assign the game's one [DotFallDamageRules].
var rules: DotFallDamageRules = null

## The controller to listen to.
@export var controller: DotNodeRef = DotNodeRef.new()

## The combat manager to apply damage through.
@export var combat: DotNodeRef = DotNodeRef.new()

## Entity id of the player taking the damage.
var victim: int = 0

## Emitted on the authority after a damaging landing when the rules set a leg slowdown;
## the host applies [param speed_scale] to the player's movement for [param seconds].
signal legs_broken(seconds: float, speed_scale: float)

## Optional [code]func() -> bool[/code]: true while the host stands in water.
var in_water: Callable = Callable()

## Optional [code]func() -> bool[/code] per [constant DotFallDamageRules.CONTEXTS] name
## (ladder, vehicle, noclip, protected, water): true while that situation applies. Whether it
## absorbs the landing is the rules' [member DotFallDamageRules.absorbs].
var context_checks: Dictionary = {}

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
	var active: Array = []

	for c: Variant in context_checks:
		var check: Callable = context_checks[c]

		if check.is_valid() and bool(check.call()):
			active.append(c)

	var amount := rules.damage_for(impact, surface, wet, active)
	amount *= 1.0 - _surface_damping(surface)

	if amount <= 0.0:
		return null

	var hit := DotDamage.make(0, victim, amount, _combat.damage_type(damage_type_id))
	hit.context = {"why": &"fall", "impact": impact}
	damaged += 1
	last_damage = amount
	DotLog.debug(CHANNEL, "fall damage", {"victim": victim, "impact": impact, "amount": amount})
	var result := _combat.apply_damage(hit)

	if rules.legs_seconds > 0.0 and not (result != null and result.refused):
		legs_broken.emit(rules.legs_seconds, rules.legs_speed)

	return result


## 0..1 of the landing the surface under the player takes away: its [code]fall_damping[/code]
## in the controller's surface set, when it has one.
func _surface_damping(surface: StringName) -> float:
	var set: Variant = _controller.get(&"surfaces") if _controller != null else null

	if set == null or surface == &"" or not (set as Object).has_method(&"get_surface"):
		return 0.0

	var def: Variant = (set as Object).call(&"get_surface", surface)

	if def == null or (def as Object).get(&"fall_damping") == null:
		return 0.0

	return clampf(float((def as Object).get(&"fall_damping")), 0.0, 1.0)


func describe() -> Dictionary:
	return {
		"victim": victim, "landings": landings, "damaged": damaged, "last_damage": last_damage,
		"attached": _controller != null and _combat != null,
		"rules": rules.describe() if rules != null else {},
	}
