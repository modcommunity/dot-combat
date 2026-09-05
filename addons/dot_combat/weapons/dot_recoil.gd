class_name DotRecoil
extends RefCounted

## The view kick a [DotWeapon]'s recoil fields describe, accumulated and recovered.
##
## [DotWeapon] declared [member DotWeapon.recoil_pitch], [member DotWeapon.recoil_yaw]
## and [member DotWeapon.recoil_recovery] from the first version, game-arena set them
## on every weapon, and nothing applied them: a documented feel that did not exist.
## This is the missing half. It owns no view — it is a pure accumulator a game adds
## to its camera angles every frame, which keeps it predictable and lets a server
## reproduce a client's aim exactly.
##
## [codeblock]
## # on each shot
## recoil.kick(weapon)
## # every frame
## recoil.advance(delta)
## camera.rotation_degrees.x = base_pitch + recoil.offset().x
## camera.rotation_degrees.y = base_yaw + recoil.offset().y
## [/codeblock]

## Accumulated kick, in degrees: x is pitch (up is positive), y is yaw.
var _offset: Vector2 = Vector2.ZERO

## Which way the next sideways kick goes. Alternates, as the weapon's field says.
var _yaw_sign: float = 1.0

## Fraction of the accumulated kick shed per second, from the last weapon kicked.
var _recovery: float = 6.0

## Most pitch a burst may pile up, in degrees. Past it the view stops climbing,
## which is what every shooter does so a held trigger does not end at the ceiling.
var max_pitch: float = 30.0


func kick(weapon: DotWeapon) -> void:
	if weapon == null:
		return
	_offset.x = minf(_offset.x + weapon.recoil_pitch, max_pitch)
	_offset.y += weapon.recoil_yaw * _yaw_sign
	_yaw_sign = -_yaw_sign
	_recovery = weapon.recoil_recovery


## Sheds recoil. Frame-rate independent: two half-steps recover what one whole
## step does, which a naive `offset -= rate * delta` does not.
func advance(delta: float) -> void:
	if delta <= 0.0 or _offset == Vector2.ZERO:
		return
	var keep := exp(-maxf(_recovery, 0.0) * delta)
	_offset *= keep
	if _offset.length() < 0.001:
		_offset = Vector2.ZERO


func offset() -> Vector2:
	return _offset


func reset() -> void:
	_offset = Vector2.ZERO
	_yaw_sign = 1.0


func describe() -> Dictionary:
	return {"pitch": _offset.x, "yaw": _offset.y, "recovery": _recovery}
