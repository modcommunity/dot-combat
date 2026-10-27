class_name DotFallDamageRules
extends RefCounted
## The numbers of fall damage, shared by every [DotFallDamage] in a game, as three server cvars.
##
## Off by default: a game opts in by setting [member enabled] or its cvar. Pure functions
## ([method damage_for]) so a selftest and the server agree without a scene.

signal changed

const CHANNEL := "combat.fall"
const CVAR_ENABLED := "sv_falldamage"
const CVAR_THRESHOLD := "sv_falldamage_threshold"
const CVAR_SCALE := "sv_falldamage_scale"

## Master switch (sv_falldamage 0/1).
var enabled: bool = false:
	set(value):
		if value != enabled:
			enabled = value
			changed.emit()

## Downward landing speed in m/s up to which nothing hurts (sv_falldamage_threshold).
var threshold: float = 12.0:
	set(value):
		value = maxf(0.0, value)
		if not is_equal_approx(value, threshold):
			threshold = value
			changed.emit()

## Health per m/s above the threshold, before [member curve_power] (sv_falldamage_scale).
var scale: float = 4.0:
	set(value):
		value = maxf(0.0, value)
		if not is_equal_approx(value, scale):
			scale = value
			changed.emit()

## 1 is linear; above 1 a long fall is punished more than the sum of short ones.
var curve_power: float = 1.0

## One landing never takes more than this (0: no cap).
var max_damage: float = 0.0

## Surface ids ([member DotFpsState.surface]) that absorb a landing: snow, mud, a mattress.
var soft_surfaces: Array[StringName] = []


## Health lost to a landing at [param impact] m/s downward; 0 when off, below the threshold,
## in water or on a soft surface.
func damage_for(impact: float, surface: StringName = &"", in_water: bool = false) -> float:
	if not enabled or in_water or impact <= threshold or soft_surfaces.has(surface):
		return 0.0

	var amount := scale * pow(impact - threshold, maxf(0.01, curve_power))

	if max_damage > 0.0:
		amount = minf(amount, max_damage)

	return amount


func cvar_specs() -> Array[Dictionary]:
	return [
		{"name": CVAR_ENABLED, "value": "1" if enabled else "0", "min": 0.0, "max": 1.0,
			"description": "Landing hard hurts: 0 off, 1 on (server-side; the damage is the server's)"},
		{"name": CVAR_THRESHOLD, "value": str(threshold), "min": 0.0, "max": 200.0,
			"description": "Downward landing speed in m/s below which a fall does no damage"},
		{"name": CVAR_SCALE, "value": str(scale), "min": 0.0, "max": 100.0,
			"description": "Health lost per m/s of landing speed above the threshold"},
	]


## Registers the cvars through [param add] (a server module's `add_cvar`, duck-typed like
## [method DotCombatManager.bind_cvars]) and follows them live. Returns the cvars made.
func bind_cvars(add: Callable, flags: int = 0) -> Array:
	var made: Array = []

	for spec in cvar_specs():
		var name: String = spec["name"]
		var cv: Variant = add.call(name, String(spec["value"]), String(spec["description"]), flags)

		if not (cv is Object) or cv == null:
			continue

		var obj := cv as Object

		if obj.has_method(&"with_range"):
			obj.call(&"with_range", float(spec["min"]), float(spec["max"]))

		if obj.has_signal(&"changed"):
			obj.connect(&"changed", func(_old: Variant, new_value: Variant) -> void:
				var _set := set_cvar(name, str(new_value)))

		if obj.has_method(&"get_string"):
			var _read := set_cvar(name, String(obj.call(&"get_string")))

		made.append(obj)

	return made


## Applies one cvar by name; false for another name or a non-number.
func set_cvar(cvar_name: String, value: String) -> bool:
	var text := value.strip_edges()

	if not text.is_valid_float():
		DotLog.warn(CHANNEL, "cvar is not a number; left as it was", {"cvar": cvar_name, "value": value})
		return false

	match cvar_name:
		CVAR_ENABLED:
			enabled = text.to_float() != 0.0
		CVAR_THRESHOLD:
			threshold = text.to_float()
		CVAR_SCALE:
			scale = text.to_float()
		_:
			return false

	DotLog.debug(CHANNEL, "fall damage rule set", {"cvar": cvar_name, "value": text})
	return true


func describe() -> Dictionary:
	return {
		"enabled": enabled, "threshold": threshold, "scale": scale,
		"curve_power": curve_power, "max_damage": max_damage, "soft_surfaces": soft_surfaces.size(),
	}
