class_name DotDamageImmunity
extends RefCounted

## Which damage kinds each entity ignores, by [member DotDamageType.id].
## Data a bridge writes once per spawn from a class profile; empty by default. The wildcard [constant ALL] covers every kind.

const ALL := &"all"

var _by_entity: Dictionary = {}


## Replaces [param entity]'s immunities with [param kinds]; an empty list clears them.
func set_immune(entity: int, kinds: Array) -> void:
	if kinds.is_empty():
		_by_entity.erase(entity)
		return
	var set := {}
	for k: Variant in kinds:
		set[StringName(str(k))] = true
	_by_entity[entity] = set


func clear(entity: int) -> void:
	_by_entity.erase(entity)


func is_immune(entity: int, kind: StringName) -> bool:
	var set: Variant = _by_entity.get(entity)
	if set == null:
		return false
	return set.has(kind) or set.has(ALL)


func kinds_of(entity: int) -> Array[StringName]:
	var out: Array[StringName] = []
	var set: Variant = _by_entity.get(entity)
	if set != null:
		for k: StringName in set:
			out.append(k)
	return out
