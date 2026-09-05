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
	return groups


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
