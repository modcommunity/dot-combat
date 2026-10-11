# History

Bugs worth recognising if they come back. The lessons that still apply are in [design.md](design.md).

## The half-moon spread

When `DotSpread` carried its own SplitMix64, the mixer output was masked to 63 bits and the float was taken with `>> 40`, which left 23 bits: `float(h >> 40 & 0xFFFFFF) / 2^24` was always below 0.5. Every pattern was a half-moon on one side of the aim, and the cone reached 1/√2 of its stated angle. Nothing failed; the shotgun threw its pellets to one side and "felt off". The fix at the time was a shift of 39; the mixing has since moved to dot-core's `DotRandomStream`, which keeps the full 64 bits and shifts by 40 with a zero-filling shift. The quadrant check in `_test_spread_determinism` stays, because a maximum-angle check alone passes for a half-moon.

## The hand-copied constants

The same local SplitMix64 had every published constant's top bit cleared, because GDScript reads a literal above 2^63 as a float. It still mixed, but it was no longer the algorithm it named. `DotRandomStream` now writes the constants once as their signed 64-bit values, so they wrap exactly as the reference does.

## `DotShot` held a `DotWeapon`

Before dot-weapon existed, the shot pointed at a weapon resource and the manager read damage, range and delivery off it, so nothing that was not a gun could be resolved. Weapons (`DotWeapon`, `DotArsenal`, `DotWeaponState`, `DotRecoil`, `DotCombatCommand`) moved to dot-weapon and the shot describes itself. `DotSpread` stayed here, because scatter is a property of a shot and putting the same hash in two addons is the duplication the family guards hardest against. `DotCombatNetSync` lost the slot, magazine and reserve at the same time.

## Stacked team-mates shot each other

A co-op horde game whose survivors do not collide lost rounds to friendly fire: four bots following one path stood inside each other, and since a ray starting inside a hitbox is a hit at 0 m, every shot from inside a friend hit that friend, aimed anywhere (200 to 500 friendly damage a minute). The game fixed it first in its own trace subclass; the rule moved here as `DotCombatManager.pass_through_sets` so every game with teams gets it without a fork. The suite's "a muzzle inside a body" section keeps both halves: the stacked friend is passed through, and an enemy holding the muzzle is still hit.
