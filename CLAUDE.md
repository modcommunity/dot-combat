# dot-combat

Health, damage and hit registration. Read `../../CLAUDE.md` first for the family-wide
rules; this file is only what is specific to combat.

**Weapons are dot-weapon's, not this addon's.** `weapons/` is gone: `DotWeapon`,
`DotArsenal`, `DotWeaponState`, `DotRecoil` and `DotCombatCommand` moved out and became
a catalogue of documents naming behaviour scripts by path. `DotSpread` stayed, in
`core/`, because scatter is a property of a shot rather than of a weapon, and putting
the same integer hash in two addons is the duplication this family guards hardest
against.

## The one idea

**Deciding that a shot happened and deciding what it hit are two different jobs, and
they run in different places.**

Whatever produces the shot does the first, and it is dot-weapon in every game here. It
runs on the owning client *and* on the server, and both reach the same `DotShot`.

**A `DotShot` describes itself.** It used to hold a `DotWeapon` and the manager read
`weapon.damage`, `weapon.max_range` and `weapon.delivery` off it, which quietly made
"what can be resolved" the same question as "what that one resource can describe": a
bow, a thrown charge and a game's own weapon had no way to produce one without
pretending to be a gun. Six numbers on the shot cost a few bytes and buy a combat layer
that resolves anything, including a trap, a turret or a falling rock.

`DotCombatManager` does the second. It traces, it rewinds, it applies damage, and it
runs only where `is_authority` is true. A client instance still traces — for hit
markers and impact effects — but never touches a `DotHealth`.

Collapsing the two is the obvious simplification and it is wrong in a specific way: a
weapon that applied its own damage would be a client that decides who dies.

## Spread cannot come from a random number generator

This is the non-obvious constraint that shaped `DotSpread`.

A predicted shot is simulated at least twice — once on the firing client, once on the
server — and once more for every reconciliation replay after a correction. Anything
drawing from a stream (`RandomNumberGenerator`, `randf()`, a seeded generator whose
state advances) produces a different pattern on each of those runs. The client sees
pellets go one way and the server resolves them going another. Nothing errors. The
symptom is a shotgun that visibly hits and does nothing, reported as "hit registration
feels bad".

So the pattern is a pure function of `(shooter, tick, shot index, pellet index)`,
computed with integer arithmetic. Same inputs, same pattern, on every machine and on
every replay.

**Three things about the hash.** Its constants have their top bit cleared, because
GDScript integers are signed 64-bit and SplitMix64's published constants are all above
2^63 — they do not survive being written down. The float comes from the *top* bits, not
from a modulo, because the low bits of a multiply-based mixer are the least mixed.

And the shift is **39, not 40**. The mixer output is masked to 63 bits, so shifting by
40 leaves 23 — and `float(h >> 40 & 0xFFFFFF) / 2^24` is then always below 0.5. Every
pattern was a half-moon on one side of the aim, and the cone reached 1/√2 of its stated
angle. Nothing failed. The shotgun simply threw its pellets to one side, and the only
symptom was that it "felt off". `_test_spread_determinism` now checks the four
quadrants around the aim direction as well as the maximum angle, because a
maximum-angle check alone passes for a half-moon.

## Hitboxes are not `Area3D`s

Lag compensation rewinds the world, tests one ray, and puts it back — per shot, per
victim, on the server, at tick rate. Doing that with physics areas means moving
colliders, flushing the physics server, querying, and moving them back. Godot's space
state is also a frame behind for the first query after a move, which is exactly the
situation lag compensation puts it in.

So a `DotHitbox` is a capsule, box or sphere with a transform, and the intersection is
arithmetic. It costs nothing, it is exact, and it gives the same answer on a client
predicting the shot and a server re-running it.

World geometry still goes through the physics server, once, via `DotTracePhysics`. The
distinction is the whole design: **world geometry is the physics engine's business,
entity hitboxes are ours.**

## `DotTraceFlat` is not a toy

A headless server, a self-test and a deterministic replay all need to trace against a
world and none of them has a populated physics space. `DotTraceFlat` is analytic boxes
and a ground plane, the same role `DotFpsFlatBody` plays in dot-player-controller. Every
check in this project's self-test runs against one, and a deathmatch level made of
boxes is a deathmatch level.

## Ties go to the wall

`DotTrace.ray` compares a hitbox hit against the world hit with `>=`, not `>`. A
player standing flush against cover produces exactly this tie, and giving it to the
hitbox is how they get shot through the thing they are hugging. The self-test
constructs an exact 9.0-vs-9.0 tie rather than an approximate one, because a test
whose two distances merely happen to be close does not test the tie-break at all.

The same reasoning inside `DotHitboxSet.intersect_ray`: a head capsule inside a torso
box shares a surface, and floating-point equality on the entry distance is common
enough that leaving the tie to child order gives a game where headshots land about
half the time and nobody can say why. It is broken by `precedence`, then by
`damage_scale`.

## Every rewind is restored, including on the paths that refuse

`resolve_shot()` refuses shots — rate limits, dead shooters, negative ticks. Those
refusals happen *before* the rewind, deliberately, and nothing between `_begin_rewind`
and `_end_rewind` returns early. A rewind that leaks leaves every hitbox in the level
in the past permanently, and the symptom is not an error: shots quietly start missing
for everyone. The self-test asserts `rewinds.size() == restores.size()` across a run
that is mostly refusals.

## Integers on the wire, and integers in the state

`DotCombatNetSync` replicates health and armour as integers: an
integer compares exactly, so a reconciling client does not see a correction on every
single tick because the server's `73.4001` differs from its own `73.4`.

Ammunition and reserve are `owner_only`. That is not bandwidth — it is that exact
ammunition is information an opponent should not have.

## Never trust the client's muzzle

`_correct_origin` relocates a shot whose reported origin is more than
`max_origin_error` from where the server believes the shooter is. **Relocating, not
refusing**: a legitimate client's origin is always slightly wrong — it is a tick ahead
by construction — and refusing those shots makes the game unplayable for everyone in
order to stop a cheat that clamping already stops.

Call `set_authoritative_origin()` for each entity or this does nothing
and the client's claim is taken as given.

## Zero is not a team

`DotDamageResolver._same_team` treats team 0 as "no team" and returns false when
either side has it. Two unassigned players in a free-for-all comparing `0 == 0` would
be allies, and with friendly fire off that is a mode where nobody can damage anybody.
The self-test covers it because it is invisible until someone plays a deathmatch.

## Coupling: nothing is imported

dot-combat names no class outside dot-core. Not dot-net, not dot-player-controller, not
dot-server.

- Nothing here names a dot-net type. A script that *mentions* a missing `class_name`
  fails to parse and takes every script that references it down with it, which is why
  `DotWeaponCommand.write` / `read` in dot-weapon take `Variant`.
- `DotCombatNetSync` describes what to replicate as data — property names and *type
  names as strings* — which a bridge resolves with `DotNetVar.Type[spec.type]`.
- Lag compensation is two `Callable`s.
- Movement state is *pushed into* a `DotWeaponContext` by the host rather than read out
  of a controller. An interpolated position differs between client and server by
  design, and feeding it to the spread makes the spread differ too.
- `DotCombatNetSync` carries health alone. The slot, the magazine and the reserve are
  `DotWeaponNetSync`'s; a game using both concatenates the two spec lists.

The ~30-line `DotNetBehaviour` that joins dot-combat to dot-net belongs in the game.
The worked example is in `DotCombatNetSync`'s class documentation.

## Validating changes

```bash
cd godot/dot-combat
ln -s ../../dot-core/addons/dot_core addons/dot_core   # gitignored
godot --headless --path . --import
find . -name '*.gd' -not -path './.godot/*' | while read f; do
    godot --headless --path . --check-only --script "res://${f#./}"
done
godot --headless --path . res://examples/combat_selftest.tscn
```

169 checks, all offline. Exits non-zero on any failure.

**Run it after any change to the trace, the resolver or the manager.** Four of the
checks exist because the obvious implementation of that code is wrong: the wall tie,
the leaked rewind, the zero-team truce, and the point-blank ray that starts inside a
hitbox and must report a hit at distance zero rather than a miss.

## Things deliberately not here

- **Projectiles as entities.** `DotWeapon.Delivery.PROJECTILE` is declared, its
  parameters exist, and `_trace_shot` records the launch vector — but nothing spawns,
  simulates or collides one. A projectile is a replicated entity with a lifetime, and
  that is dot-net's job to carry and a game's to model. Compensating a projectile is
  also a genuinely different problem from compensating a hitscan shot: you cannot
  rewind for a thing that will arrive in 400 ms.
- **Anything about what a player is holding.** Rate of fire, magazines, reloading,
  switching, recoil and melee arcs are all dot-weapon's, and a `DotShot` is the seam.
- **Ballistics.** No drag, no wind, no penetration through materials, no ricochet.
  `DotDamageType` has the falloff a shooter needs and nothing a simulation would want.
- **Hit markers, tracers, decals, sounds.** `DotShot.impacts` and the signals carry
  everything a presentation layer needs. dot-combat ships no art and no audio.
- **Ammunition as pickups.** `DotWeaponArsenal.add_ammo` is the API in dot-weapon; the
  world entity that calls it belongs in dot-loadout.
- **Damage over time.** No burning, no bleeding, no poison. `apply_damage` per tick
  from a game's own timer is the whole implementation and there is no shared piece
  worth extracting yet.
