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
const CVAR_LETHAL := "sv_falldamage_lethal"
const CVAR_POWER := "sv_falldamage_power"
const CVAR_MAX := "sv_falldamage_max"
const CVAR_LEGS_SECONDS := "sv_falldamage_legs_seconds"
const CVAR_LEGS_SPEED := "sv_falldamage_legs_speed"
const CVAR_ABSORB_PREFIX := "sv_falldamage_absorb_"

## Situations a game can say absorb a landing; each has a cvar `sv_falldamage_absorb_<name>`.
const CONTEXTS: Array[StringName] = [&"water", &"ladder", &"vehicle", &"noclip", &"protected"]

## Damage returned for a landing at or past the lethal speed: more than any health pool.
const LETHAL_DAMAGE := 100000.0

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
var curve_power: float = 1.0:
	set(value):
		curve_power = clampf(value, 0.1, 10.0)

## One landing never takes more than this (0: no cap).
var max_damage: float = 0.0:
	set(value):
		max_damage = maxf(0.0, value)

## A landing at or above this speed kills outright (0: no lethal speed).
var lethal_speed: float = 0.0:
	set(value):
		lethal_speed = maxf(0.0, value)

## After a damaging landing the legs are "broken" for this many seconds (0: off).
var legs_seconds: float = 0.0:
	set(value):
		legs_seconds = maxf(0.0, value)

## Movement speed multiplier while the legs are broken, for the host to apply.
var legs_speed: float = 0.6:
	set(value):
		legs_speed = clampf(value, 0.05, 1.0)

## Situations that absorb a landing (a subset of [constant CONTEXTS]). Water always did.
var absorbs: Dictionary = {&"water": true, &"ladder": true, &"vehicle": true, &"noclip": true, &"protected": true}

## Surface ids ([member DotFpsState.surface]) that absorb a landing: snow, mud, a mattress.
var soft_surfaces: Array[StringName] = []


## Health lost to a landing at [param impact] m/s downward; 0 when off, below the threshold,
## in water or on a soft surface. [param active] lists the [constant CONTEXTS] in effect.
func damage_for(impact: float, surface: StringName = &"", in_water: bool = false, active: Array = []) -> float:
	if not enabled or in_water or impact <= threshold or soft_surfaces.has(surface):
		return 0.0

	for c: Variant in active:
		if absorbs.get(c, false):
			return 0.0

	if lethal_speed > 0.0 and impact >= lethal_speed:
		return LETHAL_DAMAGE

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
		{"name": CVAR_LETHAL, "value": str(lethal_speed), "min": 0.0, "max": 500.0,
			"description": "Landing speed in m/s that kills outright; 0 for none"},
		{"name": CVAR_POWER, "value": str(curve_power), "min": 0.1, "max": 10.0,
			"description": "Damage curve exponent: 1 linear, above 1 punishes long falls more"},
		{"name": CVAR_MAX, "value": str(max_damage), "min": 0.0, "max": 100000.0,
			"description": "Most one landing can take (before the lethal speed); 0 for no cap"},
		{"name": CVAR_LEGS_SECONDS, "value": str(legs_seconds), "min": 0.0, "max": 60.0,
			"description": "Seconds of slowdown after a damaging landing; 0 for none"},
		{"name": CVAR_LEGS_SPEED, "value": str(legs_speed), "min": 0.05, "max": 1.0,
			"description": "Movement speed multiplier while the legs are broken"},
	] + _absorb_specs()


func _absorb_specs() -> Array[Dictionary]:
	var out: Array[Dictionary] = []

	for c in CONTEXTS:
		out.append({"name": CVAR_ABSORB_PREFIX + String(c), "value": "1" if absorbs.get(c, false) else "0",
			"min": 0.0, "max": 1.0, "description": "1: landing while '%s' does no fall damage" % c})

	return out


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
		CVAR_LETHAL:
			lethal_speed = text.to_float()
		CVAR_POWER:
			curve_power = text.to_float()
		CVAR_MAX:
			max_damage = text.to_float()
		CVAR_LEGS_SECONDS:
			legs_seconds = text.to_float()
		CVAR_LEGS_SPEED:
			legs_speed = text.to_float()
		_:
			if not cvar_name.begins_with(CVAR_ABSORB_PREFIX):
				return false

			var ctx := StringName(cvar_name.trim_prefix(CVAR_ABSORB_PREFIX))

			if not CONTEXTS.has(ctx):
				return false

			absorbs[ctx] = text.to_float() != 0.0

	DotLog.debug(CHANNEL, "fall damage rule set", {"cvar": cvar_name, "value": text})
	return true


func describe() -> Dictionary:
	return {
		"enabled": enabled, "threshold": threshold, "scale": scale,
		"curve_power": curve_power, "max_damage": max_damage, "lethal_speed": lethal_speed,
		"legs_seconds": legs_seconds, "absorbs": absorbs.duplicate(), "soft_surfaces": soft_surfaces.size(),
	}
