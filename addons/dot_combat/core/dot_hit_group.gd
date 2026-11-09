class_name DotHitGroup
extends RefCounted

## The named regions a shot can land in, and the multiplier each carries.
##
## [b]Why this is a table and not an enum.[/b] A game with a four-legged enemy, a
## vehicle with a weak point, or a boss with a glowing core needs groups this addon
## has never heard of, and an enum would make adding one a fork. Groups are
## [StringName]s and the multipliers live in an instance a game replaces wholesale.
##
## The five built-in names exist because almost every shooter has them and a default
## that already works is worth more than a blank table.

const HEAD := &"head"
const CHEST := &"chest"
const STOMACH := &"stomach"
const ARM := &"arm"
const LEG := &"leg"
const NECK := &"neck"
const HAND := &"hand"
const FOOT := &"foot"
const KNEE := &"knee"

## Used when a hitbox declares no group, and when a trace hits a collider with no
## hitboxes at all. Multiplier 1.0 by construction — see [method multiplier].
const GENERIC := &"generic"

var _multipliers: Dictionary = {}


static func defaults() -> DotHitGroup:
	var groups := DotHitGroup.new()
	groups.set_multiplier(HEAD, 4.0)
	groups.set_multiplier(CHEST, 1.0)
	groups.set_multiplier(STOMACH, 1.25)
	groups.set_multiplier(ARM, 0.75)
	groups.set_multiplier(LEG, 0.75)
	groups.set_multiplier(NECK, 2.0)
	groups.set_multiplier(HAND, 0.5)
	groups.set_multiplier(FOOT, 0.5)
	groups.set_multiplier(KNEE, 0.75)
	return groups


## Overrides multipliers from data, e.g. the `hit_groups:` map of `cfg/addons/dot-combat/*.yml`. Returns how many applied.
func apply_dict(data: Dictionary) -> int:
	var applied := 0
	for key in data:
		var v: Variant = data[key]
		if (v is float or v is int) and is_finite(float(v)):
			set_multiplier(StringName(str(key)), float(v))
			applied += 1
	return applied

func set_multiplier(group: StringName, value: float) -> void:
	_multipliers[group] = maxf(0.0, value)


## The multiplier for [param group], or 1.0 when it is not in the table.
##
## Unknown groups deliberately do not fail: a hitbox named for a body part this table
## has never heard of should do normal damage, not zero. A typo costing full damage is
## survivable; a typo costing none is a weapon that mysteriously does nothing.
func multiplier(group: StringName) -> float:
	return float(_multipliers.get(group, 1.0))


func has(group: StringName) -> bool:
	return _multipliers.has(group)


func names() -> PackedStringArray:
	var out := PackedStringArray()
	for key in _multipliers.keys():
		out.append(String(key))
	out.sort()
	return out


func describe_lines() -> PackedStringArray:
	var out := PackedStringArray()
	for name_str in names():
		out.append("  %-10s x%.2f" % [name_str, multiplier(StringName(name_str))])
	return out


## The zones a server may tune, each with the cvar suffix it is set by: `<prefix>_head_mult` and so on.
const TUNABLE := {&"head": "head_mult", &"neck": "neck_mult", &"stomach": "stomach_mult", &"leg": "leg_mult"}


## Registers one server cvar per [constant TUNABLE] zone through [param add] ([code](name, default, description, flags) -> cvar[/code]), named `<prefix>_head_mult` and so on, and follows them live. The default is the multiplier this table holds now.
func bind_cvars(add: Callable, prefix: String, flags: int = 0) -> Array:
	var made: Array = []

	for group: StringName in TUNABLE:
		var name := "%s_%s" % [prefix, TUNABLE[group]]
		var help := "Damage multiplier on a %s hit (default %s)" % [group, str(multiplier(group))]
		var cv: Variant = add.call(name, str(multiplier(group)), help, flags)

		if not (cv is Object) or cv == null:
			continue

		var obj := cv as Object

		if obj.has_method(&"with_min"):
			obj.call(&"with_min", 0.0)

		if obj.has_signal(&"changed"):
			obj.connect(&"changed", func(_old: Variant, new_value: Variant) -> void:
				set_multiplier(group, str(new_value).to_float()))

		made.append(obj)

	return made
