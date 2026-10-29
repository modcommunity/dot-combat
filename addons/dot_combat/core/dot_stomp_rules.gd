class_name DotStompRules
extends RefCounted
## The numbers of the head stomp (landing on a player's head hurts them), as [code]sv_stomp_*[/code] cvars.
## Off by default. Pure data, so a selftest and the server agree without a scene.

const CVARS: Dictionary = {
	"sv_stomp": ["enabled", 0.0, 1.0, "Landing on a player's head hurts them: 0 off, 1 on"],
	"sv_stomp_damage": ["damage", 0.0, 100000.0, "Health a stomp takes; 0 kills outright"],
	"sv_stomp_min_speed": ["min_speed", 0.0, 200.0, "Downward speed in m/s needed for a stomp"],
	"sv_stomp_head_tolerance": ["head_tolerance", 0.0, 2.0, "Metres the feet may be above or below the head top"],
	"sv_stomp_same_team": ["same_team", 0.0, 1.0, "1: teammates can be stomped (ignores friendly fire)"],
	"sv_stomp_bounce": ["bounce", 0.0, 100.0, "Upward speed in m/s the stomper is thrown with"],
	"sv_stomp_cooldown": ["cooldown_sec", 0.0, 60.0, "Seconds before the same stomper can stomp again"],
}

var enabled: bool = false
## Health taken; 0 or less kills outright.
var damage: float = 0.0
var min_speed: float = 4.0
var head_tolerance: float = 0.35
var same_team: bool = false
var bounce: float = 8.0
var cooldown_sec: float = 0.5
## Ids the host's audio and fx catalogues know; the event carries them to clients.
var sound: StringName = &"stomp"
var effect: StringName = &"stomp_puff"


## Copies the numbers from [param other] (a game's own config).
func set_value(field: String, value: float) -> void:
	match field:
		"enabled", "same_team":
			set(field, value != 0.0)
		_:
			set(field, value)


func cvar_specs() -> Array[Dictionary]:
	var out: Array[Dictionary] = []

	for cv: String in CVARS:
		var spec: Array = CVARS[cv]
		var v: Variant = get(spec[0])
		out.append({"name": cv, "value": str(1 if v else 0) if v is bool else str(v),
			"min": spec[1], "max": spec[2], "description": spec[3]})

	return out


## Registers the cvars through [param add] and follows them live; same shape as [method DotFallDamageRules.bind_cvars].
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

	if not CVARS.has(cvar_name) or not text.is_valid_float():
		return false

	set_value(CVARS[cvar_name][0], text.to_float())
	return true
