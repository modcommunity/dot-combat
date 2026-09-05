class_name DotCombatCommand
extends RefCounted

## What a player asked their weapon to do on one tick.
##
## The combat half of dot-fps-controller's [code]DotFpsCommand[/code], and separate
## from it for the same reason movement is separate from input sampling: the
## simulation must be a pure function of these, so that a client predicting a shot and
## a server re-running it reach the same answer. Nothing below reads a device, a
## clock, or a node.
##
## A game using both copies [member yaw] and [member pitch] across from the movement
## command rather than sampling the mouse twice — the two must agree exactly or the
## shot leaves the muzzle at a different angle than the one the player was looking
## along.

const BUTTON_ATTACK := 1 << 0
const BUTTON_ALT := 1 << 1
const BUTTON_RELOAD := 1 << 2
const BUTTON_USE := 1 << 3

## Cycle to the next or previous slot. Applied after [member slot], so a command
## carrying both is a slot selection.
const BUTTON_NEXT := 1 << 4
const BUTTON_PREVIOUS := 1 << 5

## Swap to the slot held before the current one. The Q key in every shooter.
const BUTTON_LAST := 1 << 6

## Drop the current weapon.
const BUTTON_DROP := 1 << 7

## Free for a game's own actions. Reserved here so a game adding one does not collide
## with a button dot-combat adds later.
const BUTTON_USER_0 := 1 << 8
const BUTTON_USER_1 := 1 << 9
const BUTTON_USER_2 := 1 << 10
const BUTTON_USER_3 := 1 << 11

const BUTTON_BITS := 12

## Slot the player selected directly, 1-based. Zero means "no change" — not slot
## zero, which is why slots are 1-based on the wire and in this field.
var slot: int = 0

var buttons: int = 0

## Where the player is looking, in degrees. The shot's direction comes from these and
## from nothing else.
var yaw: float = 0.0
var pitch: float = 0.0


func is_pressed(button: int) -> bool:
	return (buttons & button) != 0


func set_button(button: int, pressed: bool) -> void:
	if pressed:
		buttons |= button
	else:
		buttons &= ~button


## Buttons pressed on this command that were not pressed on [param previous].
##
## Semi-automatic fire, reload and slot switching are all edge-triggered, and reading
## the level instead is how a semi-automatic weapon fires like an automatic one for
## anyone holding the button.
func pressed_since(previous: DotCombatCommand) -> int:
	if previous == null:
		return buttons
	return buttons & ~previous.buttons


func just_pressed(button: int, previous: DotCombatCommand) -> bool:
	return (pressed_since(previous) & button) != 0


## The unit direction the player is aiming along.
##
## Godot is -Z forward, and yaw increases anticlockwise about +Y. Deriving this here
## rather than at each call site is what keeps a client and a server from disagreeing
## by a sign.
func aim_direction() -> Vector3:
	var yaw_rad := deg_to_rad(yaw)
	var pitch_rad := deg_to_rad(pitch)
	var cos_pitch := cos(pitch_rad)
	return Vector3(
		-sin(yaw_rad) * cos_pitch,
		sin(pitch_rad),
		-cos(yaw_rad) * cos_pitch,
	).normalized()


func duplicate_command() -> DotCombatCommand:
	var copy := DotCombatCommand.new()
	copy.slot = slot
	copy.buttons = buttons
	copy.yaw = yaw
	copy.pitch = pitch
	return copy


func equals(other: DotCombatCommand) -> bool:
	if other == null:
		return false
	return (
		slot == other.slot
		and buttons == other.buttons
		and is_equal_approx(yaw, other.yaw)
		and is_equal_approx(pitch, other.pitch)
	)


## Clamps everything a hostile client could send out of range.
##
## Called on the server for every received command. A pitch of 400 degrees is not a
## crash, it is a shot along an axis no legitimate client can aim at, and a slot index
## of two billion is an array access.
func sanitise(max_slots: int = 16, pitch_limit: float = 89.0) -> void:
	slot = clampi(slot, 0, max_slots)
	buttons &= (1 << BUTTON_BITS) - 1
	yaw = wrapf(yaw, -180.0, 180.0)
	pitch = clampf(pitch, -pitch_limit, pitch_limit)

	if is_nan(yaw):
		yaw = 0.0
	if is_nan(pitch):
		pitch = 0.0


## Writes to a [code]DotNetWriter[/code].
##
## [param writer] is [Variant] so this file never mentions a dot-net class name — a
## script that does fails to parse in a project without dot-net, and takes every
## script that references it down with it. See this project's CLAUDE.md.
func write(writer: Variant) -> void:
	writer.write_uint(slot, 5)
	writer.write_uint(buttons, BUTTON_BITS)
	writer.write_angle(yaw, 12)
	writer.write_float_range(pitch, -90.0, 90.0, 11)


func read(reader: Variant) -> void:
	slot = reader.read_uint(5)
	buttons = reader.read_uint(BUTTON_BITS)
	yaw = reader.read_angle(12)
	pitch = reader.read_float_range(-90.0, 90.0, 11)


static func estimated_bits() -> int:
	return 5 + BUTTON_BITS + 12 + 11


static func button_names(mask: int) -> PackedStringArray:
	var names := PackedStringArray()
	var table := {
		BUTTON_ATTACK: "attack",
		BUTTON_ALT: "alt",
		BUTTON_RELOAD: "reload",
		BUTTON_USE: "use",
		BUTTON_NEXT: "next",
		BUTTON_PREVIOUS: "previous",
		BUTTON_LAST: "last",
		BUTTON_DROP: "drop",
	}
	for bit in table.keys():
		if (mask & int(bit)) != 0:
			names.append(str(table[bit]))
	return names


func describe() -> Dictionary:
	return {
		"slot": slot,
		"buttons": Array(button_names(buttons)),
		"yaw": yaw,
		"pitch": pitch,
	}


func _to_string() -> String:
	return "DotCombatCommand(slot %d, %s, %.1f/%.1f)" % [
		slot,
		"+".join(button_names(buttons)) if buttons != 0 else "-",
		yaw,
		pitch,
	]
