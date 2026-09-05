class_name DotSpread
extends RefCounted

## Deterministic shot scatter.
##
## [b]Spread cannot come from [RandomNumberGenerator].[/b] A predicted shot is
## simulated twice — once on the firing client, once on the server — and once more
## for every reconciliation replay. Anything drawing from a stream produces a
## different pattern each time, so the client sees pellets go one way and the server
## resolves them going another, and the mismatch is a shotgun that visibly hits and
## does nothing.
##
## So the pattern is a pure function of the shot: entity, tick, shot index and pellet
## index in, two angles out. Same inputs, same pattern, on every machine and on every
## replay — and a game that wants a fixed pattern rather than a random one overrides
## it wholesale with [method fixed_cone].
##
## The hash is integer arithmetic throughout. Floating-point hashing would be
## reproducible in practice and unprovable in principle, which is not a trade worth
## making for the one place in a shooter where a mismatch is invisible until someone
## complains that a weapon "feels off".

## 64-bit mask, so the mixing below stays inside GDScript's signed 64-bit ints
## without ever going negative and turning the shifts into sign-extension.
const _MASK := 0x7FFFFFFFFFFFFFFF


## Mixes four integers into one well-distributed value.
##
## SplitMix64's finaliser: a fixed sequence of shifts and multiplies with no table and
## no state, which is what makes it give the same answer on a desktop, a phone and a
## browser.
##
## [b]The constants have their top bit cleared.[/b] GDScript integers are signed
## 64-bit and its literals are parsed as such, so SplitMix64's published constants —
## every one of which is above 2^63 — do not survive being written down here. Clearing
## the top bit keeps them odd, which is the property the mixing actually depends on,
## and the result is no longer bit-identical to SplitMix64. That does not matter: what
## is needed is a stable scramble, not a specific published one.
static func hash4(a: int, b: int, c: int, d: int) -> int:
	var x := (a * 0x1E3779B97F4A7C15) & _MASK
	x = (x ^ (b * 0x3F58476D1CE4E5B9)) & _MASK
	x = (x ^ (c * 0x14D049BB133111EB)) & _MASK
	x = (x ^ (d * 0x56E8FEB86659FD93)) & _MASK

	x = (x ^ (x >> 30)) & _MASK
	x = (x * 0x3F58476D1CE4E5B9) & _MASK
	x = (x ^ (x >> 27)) & _MASK
	x = (x * 0x14D049BB133111EB) & _MASK
	x = (x ^ (x >> 31)) & _MASK
	return x


## A float in [0, 1) from a hash, using the top 24 bits.
##
## The top bits rather than a modulo: the low bits of a multiply-based mixer are the
## least mixed, and 24 is what a 32-bit float can represent exactly, so the same value
## comes back on a platform where GDScript floats are 64-bit and one where an
## intermediate is not.
static func unit(h: int) -> float:
	# h is masked to 63 bits, so shifting by 39 leaves exactly 24 -- the width a
	# 32-bit float represents exactly, and the whole range. Shifting by 40 leaves 23,
	# and every value then falls in [0, 0.5): a scatter field clustered into one
	# quadrant, and a spread cone that only ever covered half a circle.
	return float(h >> 39) / 16777216.0


## Rotates [param direction] by a scatter of at most [param angle_degrees].
##
## The offset is uniform over the cone's solid angle, not over its radius — sampling
## the radius uniformly clusters pellets in the middle, which reads as a weapon that
## is more accurate than its stated spread and then abruptly is not.
static func cone(
	direction: Vector3,
	angle_degrees: float,
	entity: int,
	tick: int,
	shot: int,
	pellet: int
) -> Vector3:
	if angle_degrees <= 0.0:
		return direction

	var h := hash4(entity, tick, shot, pellet)
	var azimuth := unit(h) * TAU
	# The second sample must not be correlated with the first, and re-mixing the hash
	# is cheaper than a second full hash of four inputs.
	var radial := unit(hash4(h & _MASK, pellet, shot, tick))

	var max_cos := cos(deg_to_rad(angle_degrees))
	var cos_theta := 1.0 - radial * (1.0 - max_cos)
	var sin_theta := sqrt(maxf(0.0, 1.0 - cos_theta * cos_theta))

	return _rotate_into(
		direction,
		Vector3(cos(azimuth) * sin_theta, sin(azimuth) * sin_theta, cos_theta)
	)


## A fixed pattern: [param pellet] of [param count] placed on a ring.
##
## For weapons whose spread should be learnable rather than random — which is most
## competitive shotguns. Still deterministic, and cheaper than the hash.
static func fixed_cone(
	direction: Vector3,
	angle_degrees: float,
	pellet: int,
	count: int
) -> Vector3:
	if angle_degrees <= 0.0 or count <= 1:
		return direction

	# One pellet dead centre, the rest on a ring. A ring with no centre pellet makes a
	# shotgun that cannot hit a distant target at all, which is a surprise the first
	# time someone tunes one.
	if pellet == 0:
		return direction

	var ring_count := count - 1
	var azimuth := TAU * float(pellet - 1) / float(ring_count)
	var theta := deg_to_rad(angle_degrees)

	return _rotate_into(
		direction,
		Vector3(cos(azimuth) * sin(theta), sin(azimuth) * sin(theta), cos(theta))
	)


## Maps a vector expressed around +Z onto one expressed around [param direction].
##
## Builds the basis from the axis furthest from [param direction] so the cross product
## never degenerates — picking a fixed up vector makes every shot fired straight up or
## straight down come out along a single line, which is a bug that only appears when
## someone shoots at the sky.
static func _rotate_into(direction: Vector3, local: Vector3) -> Vector3:
	var forward := direction.normalized()
	var helper := Vector3.UP if absf(forward.y) < 0.9 else Vector3.RIGHT
	var right := helper.cross(forward).normalized()
	var up := forward.cross(right)

	return (right * local.x + up * local.y + forward * local.z).normalized()
