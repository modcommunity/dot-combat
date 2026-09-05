@tool
class_name DotWeapon
extends Resource

## Everything about a weapon that does not change while it is being fired.
##
## A pure description. It holds no ammunition, no cooldown and no owner — those live
## in a [DotWeaponState], one per carrier — so a single instance is shared by every
## player holding that weapon and a game can ship its arsenal as `.tres` files an
## artist edits without touching code.
##
## [b]Every duration here is in seconds and every rate is per minute, and both are
## converted to ticks once, at bind time.[/b] Designers think in seconds and
## simulations must count in ticks; doing the conversion at each use site is how a
## weapon ends up firing at a slightly different rate on a 128-tick server than on a
## 64-tick one.

## How the trigger behaves.
enum Fire {
	## One shot per press.
	SEMI,
	## Shots for as long as the button is held.
	AUTO,
	## A fixed count per press, at [member burst_rpm].
	BURST,
	## Damage accrues per tick while held. A beam, a flamethrower, a repair tool.
	BEAM,
}

## How the damage gets there.
enum Delivery {
	## Instantly, along a ray. Lag-compensated.
	HITSCAN,
	## As an entity with a speed and a lifetime. Not lag-compensated — see this
	## project's CLAUDE.md for why compensating a projectile is a different problem.
	PROJECTILE,
}

@export_group("Identity")

## Stable id. Travels on the wire, appears in kill feeds, keys the loadout.
@export var id: StringName = &"weapon"

@export var display_name: String = "Weapon"

## Preferred slot, 1-based. A loadout may override it; this is the default.
@export_range(1, 16, 1) var slot: int = 1

## Ammunition pool this draws its reserve from. Weapons sharing an id share reserve.
## Empty means the weapon has its own pool, keyed by [member id].
@export var ammo_type: StringName = &""

@export_group("Firing")

@export var fire_mode: Fire = Fire.AUTO

@export var delivery: Delivery = Delivery.HITSCAN

## Rounds per minute. The interval between shots is derived from this and the tick
## rate, and rounded to whole ticks — see [method fire_interval_ticks].
@export_range(1.0, 6000.0, 1.0) var rpm: float = 600.0

## Shots per burst, for [constant Fire.BURST].
@export_range(1, 10, 1) var burst_count: int = 3

## Rate within a burst. Usually faster than [member rpm], which then governs the gap
## between bursts.
@export_range(1.0, 6000.0, 1.0) var burst_rpm: float = 1200.0

## Projectiles per shot. Above one makes a shotgun and multiplies the ammunition cost
## by nothing — a shotgun shell is one round.
@export_range(1, 32, 1) var pellets: int = 1

## Whether the pellet pattern is random within the cone or a fixed ring.
##
## Fixed is what a competitive shotgun wants: a pattern a player can learn. Both are
## deterministic — see [DotSpread].
@export var fixed_pattern: bool = false

@export_group("Damage")

@export_range(0.0, 1000.0, 1.0) var damage: float = 20.0

## Damage type. Left null the weapon uses the manager's default.
@export var damage_type: DotDamageType = null

## Metres past which a hitscan shot stops. Also bounds the trace, so a large value on
## every weapon costs work on every shot.
@export_range(1.0, 10000.0, 1.0) var max_range: float = 200.0

@export_group("Accuracy")

## Cone half-angle, in degrees, standing still.
@export_range(0.0, 45.0, 0.05) var spread_degrees: float = 0.5

## Added to the cone at full movement speed.
@export_range(0.0, 45.0, 0.05) var spread_moving: float = 2.0

## Added to the cone while airborne.
@export_range(0.0, 45.0, 0.05) var spread_airborne: float = 4.0

## Multiplies the cone while crouched.
@export_range(0.0, 2.0, 0.05) var spread_crouched: float = 0.5

## Added to the cone per shot already fired in this burst of sustained fire, up to
## [member spread_bloom_max].
@export_range(0.0, 10.0, 0.05) var spread_bloom: float = 0.25

@export_range(0.0, 45.0, 0.1) var spread_bloom_max: float = 5.0

## Degrees of bloom shed per second once firing stops.
@export_range(0.0, 100.0, 0.5) var spread_recovery: float = 8.0

@export_group("Recoil")

## Degrees the view kicks up per shot.
@export_range(0.0, 20.0, 0.05) var recoil_pitch: float = 0.4

## Degrees the view kicks sideways per shot. The sign alternates.
@export_range(0.0, 20.0, 0.05) var recoil_yaw: float = 0.15

## Fraction of accumulated recoil shed per second. See [DotRecoil], which is
## what applies all three recoil fields — nothing did until it existed.
@export_range(0.0, 30.0, 0.1) var recoil_recovery: float = 6.0

@export_group("Ammunition")

## Rounds in a full magazine. Zero means the weapon draws straight from the reserve —
## a rocket launcher with no reload, a melee weapon.
@export_range(0, 500, 1) var magazine: int = 30

## Reserve rounds a full pickup grants.
@export_range(0, 9999, 1) var reserve: int = 90

## Reserve rounds the carrier may hold at once. Zero means [member reserve].
@export_range(0, 9999, 1) var reserve_max: int = 0

## Rounds consumed per shot.
@export_range(0, 100, 1) var cost: int = 1

## Never runs out. For a starting pistol and for a knife.
@export var infinite_reserve: bool = false

@export_group("Reloading")

@export_range(0.0, 30.0, 0.05) var reload_sec: float = 2.2

## Reload one round at a time. A pump shotgun. Interruptible by firing.
@export var reload_per_round: bool = false

## Extra seconds the first shell of a per-round reload costs.
@export_range(0.0, 5.0, 0.05) var reload_start_sec: float = 0.35

## Reload automatically when the magazine empties.
@export var auto_reload: bool = true

@export_group("Handling")

## Seconds before a weapon just switched to can fire.
@export_range(0.0, 10.0, 0.05) var deploy_sec: float = 0.35

## Seconds before a switch away completes.
@export_range(0.0, 10.0, 0.05) var holster_sec: float = 0.2

@export_group("Projectile")

## Metres per second, for [constant Delivery.PROJECTILE].
##
## [b]dot-combat does not simulate projectiles.[/b] [DotCombatManager] records the
## launch vector and produces no damage of its own; a rocket or a grenade is a
## game's own moving body, and these four fields are the numbers it reads so a
## weapon stays one resource. Nothing in this addon reads them.
@export_range(1.0, 2000.0, 1.0) var projectile_speed: float = 45.0

## Gravity scale applied to the projectile. Zero flies straight.
@export_range(0.0, 4.0, 0.05) var projectile_gravity: float = 0.0

## Collision radius. Zero traces a ray between steps instead.
@export_range(0.0, 5.0, 0.01) var projectile_radius: float = 0.1

## Seconds before it expires. Also bounds how long the server tracks it.
@export_range(0.1, 60.0, 0.1) var projectile_life_sec: float = 6.0

@export_group("Splash")

## Metres. Zero means no splash.
@export_range(0.0, 50.0, 0.1) var splash_radius: float = 0.0

## Damage at the centre of the splash. Falls off linearly to zero at the edge.
@export_range(0.0, 1000.0, 1.0) var splash_damage: float = 0.0

## Splash type. Left null, [member damage_type] is used.
@export var splash_type: DotDamageType = null

## Whether splash damages the person who fired it. Rocket jumping needs this on, and
## [member DotDamageType.self_scale] decides how much it hurts.
@export var splash_hurts_owner: bool = true


static func make(p_id: StringName, p_damage: float = 20.0) -> DotWeapon:
	var weapon := DotWeapon.new()
	weapon.id = p_id
	weapon.display_name = String(p_id).capitalize()
	weapon.damage = p_damage
	return weapon


## Ticks between shots at [param tick_rate], never below one.
##
## Rounded rather than truncated, and clamped at one: a weapon whose rate exceeds the
## tick rate fires once per tick, and truncating to zero would make it fire in an
## infinite loop within a single tick.
func fire_interval_ticks(tick_rate: int) -> int:
	return maxi(1, int(round(60.0 / maxf(1.0, rpm) * float(tick_rate))))


func burst_interval_ticks(tick_rate: int) -> int:
	return maxi(1, int(round(60.0 / maxf(1.0, burst_rpm) * float(tick_rate))))


func reload_ticks(tick_rate: int) -> int:
	return maxi(1, int(round(reload_sec * float(tick_rate))))


func reload_start_ticks(tick_rate: int) -> int:
	return maxi(0, int(round(reload_start_sec * float(tick_rate))))


func deploy_ticks(tick_rate: int) -> int:
	return maxi(0, int(round(deploy_sec * float(tick_rate))))


func holster_ticks(tick_rate: int) -> int:
	return maxi(0, int(round(holster_sec * float(tick_rate))))


func projectile_life_ticks(tick_rate: int) -> int:
	return maxi(1, int(round(projectile_life_sec * float(tick_rate))))


func pool_id() -> StringName:
	return ammo_type if ammo_type != &"" else id


func reserve_cap() -> int:
	return reserve_max if reserve_max > 0 else reserve


func uses_magazine() -> bool:
	return magazine > 0


func is_beam() -> bool:
	return fire_mode == Fire.BEAM


## Damage a splash does at [param distance] from its centre.
##
## Linear to zero at the edge, and zero outside. Linear rather than quadratic because
## an inverse-square splash is almost all edge, which plays as a weapon that has to be
## a direct hit — at which point the splash is decoration.
func splash_at(distance: float) -> float:
	if splash_radius <= 0.0 or splash_damage <= 0.0:
		return 0.0

	if distance >= splash_radius:
		return 0.0

	return splash_damage * (1.0 - distance / splash_radius)


func validate() -> DotResult:
	if id == &"":
		return DotResult.fail(DotError.CODE_INVALID, "A weapon needs an id.")

	if cost > 0 and uses_magazine() and cost > magazine:
		return DotResult.fail(
			DotError.CODE_INVALID,
			"Weapon '%s' costs %d rounds but its magazine holds %d, so it can never fire."
				% [id, cost, magazine]
		)

	if fire_mode == Fire.BURST and burst_count < 1:
		return DotResult.fail(
			DotError.CODE_INVALID, "Weapon '%s' bursts zero shots." % id
		)

	if delivery == Delivery.PROJECTILE and projectile_speed <= 0.0:
		return DotResult.fail(
			DotError.CODE_INVALID, "Projectile weapon '%s' has no speed." % id
		)

	if splash_radius > 0.0 and splash_damage <= 0.0:
		DotLog.warn(
			"combat.weapon",
			"weapon has a splash radius and no splash damage",
			{"weapon": String(id)}
		)

	return DotResult.success(null)


func describe() -> Dictionary:
	return {
		"id": String(id),
		"slot": slot,
		"mode": Fire.keys()[fire_mode],
		"delivery": Delivery.keys()[delivery],
		"damage": damage,
		"pellets": pellets,
		"rpm": rpm,
		"magazine": magazine,
		"reserve": reserve,
		"range": max_range,
		"splash": splash_radius,
	}


func _to_string() -> String:
	return "DotWeapon(%s)" % id
