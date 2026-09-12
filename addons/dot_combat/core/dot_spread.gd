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
##
## [b]The mixing itself is dot-core's.[/b] This file used to carry its own splitmix64,
## with every published constant's top bit cleared so GDScript would parse it as an
## [int] rather than a float -- a mixer that still mixed but was no longer the
## algorithm it named. [DotRandomStream] writes those constants once, as their signed
## 64-bit values, so they wrap exactly as the reference does. Two implementations of
## one algorithm is one too many when the whole point is that two machines agree.

## Mixes four integers into one well-distributed value.
##
## Kept as a named entry point on [DotSpread] rather than having callers reach for
## [DotRandomStream] directly: what a weapon wants is "the scatter for this pellet of
## this shot", and the four arguments in this order are that question. The mixing is
## dot-core's -- see [method DotRandomStream.mix4].
static func hash4(a: int, b: int, c: int, d: int) -> int:
	return DotRandomStream.mix4(a, b, c, d)


## A float in [0, 1) from a hash, using the top 24 bits.
##
## See [method DotRandomStream.unit_from] for why the top bits and why exactly 24.
## This once shifted by one bit too many, which left every value in [0, 0.5) and made
## a spread cone that only ever covered half a circle -- the suite still checks for
## that, because the check is cheap and the symptom is not obviously a bug.
static func unit(h: int) -> float:
	return DotRandomStream.unit_from(h)


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
	var radial := unit(hash4(h, pellet, shot, tick))

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
