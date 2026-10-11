# Design

Why dot-combat is shaped the way it is, and why the obvious alternative is wrong in each place. The one-line rules are in [CLAUDE.md](../CLAUDE.md).

## Two jobs, two places

**Deciding that a shot happened and deciding what it hit are two different jobs, and they run in different places.**

Whatever produces the shot does the first; in the games here that is dot-weapon. It runs on the owning client *and* on the server, and both reach the same `DotShot`.

`DotCombatManager` does the second. It traces, it rewinds, it applies damage, and it applies damage only where `is_authority` is true. A client instance still traces, for hit markers and impact effects, but never touches a `DotHealth`.

Collapsing the two is the obvious simplification and it is wrong in a specific way: a weapon that applied its own damage would be a client that decides who dies.

## A `DotShot` describes itself

It used to hold a `DotWeapon`, and the manager read `weapon.damage`, `weapon.max_range` and `weapon.delivery` off it. That quietly made "what can be resolved" the same question as "what that one resource can describe": a bow, a thrown charge and a game's own weapon had no way to produce one without pretending to be a gun. A few numbers on the shot (damage, type, range, pellets, splash) cost a few bytes and buy a combat layer that resolves anything, including a trap, a turret or a falling rock. Damage that comes from no shot at all goes through `apply_damage`.

A shot with `deferred = true` is an entity with a lifetime and is not resolved here: `_trace_shot` records each pellet's endpoint so a caller can launch along the right vector, and the shot does no damage of its own. dot-weapon's projectile behaviours produce a `DotWeaponSpawn` instead of a shot; compensating a thing that arrives 400 ms later is a different problem from compensating hitscan, and by the time it lands everybody already agrees where everybody is.

## Spread cannot come from a random number generator

A predicted shot is simulated at least twice (once on the firing client, once on the server) and once more for every reconciliation replay after a correction. Anything drawing from a stream (`RandomNumberGenerator`, `randf()`, a seeded generator whose state advances) produces a different pattern on each run. The client sees pellets go one way and the server resolves them going another. Nothing errors; the symptom is a shotgun that visibly hits and does nothing, reported as "hit registration feels bad".

So the pattern is a pure function of `(shooter, tick, shot index, pellet index)`, computed with integer arithmetic. Same inputs, same pattern, on every machine and every replay. `DotSpread.hash4` and `DotSpread.unit` are thin names over dot-core's `DotRandomStream.mix4` and `unit_from`: two implementations of one mixer is one too many when the point is that two machines agree. The float comes from the top 24 bits through a zero-filling shift, because the low bits of a multiply-based mixer are the least mixed and an arithmetic shift of a negative value keeps the sign bits.

The offset is uniform over the cone's solid angle, not its radius: sampling the radius uniformly clusters pellets in the middle. `fixed_cone` replaces the pattern wholesale for a game that wants a fixed one.

`_test_spread_determinism` checks the four quadrants around the aim direction as well as the maximum angle, because a maximum-angle check alone passes for a half-moon pattern ([history](history.md#the-half-moon-spread)).

## Hitboxes are not `Area3D`s

Lag compensation rewinds the world, tests one ray and puts it back, per shot, per victim, on the server, at tick rate. With physics areas that means moving colliders, flushing the physics server, querying and moving them back, and Godot's space state is a frame behind for the first query after a move, which is exactly the situation lag compensation creates.

So a `DotHitbox` is a capsule, box or sphere with a transform, and the intersection is arithmetic: free, exact, and the same answer on a predicting client and a re-running server. World geometry still goes through the physics server, once, via `DotTracePhysics`. **World geometry is the physics engine's business; entity hitboxes are ours.**

`DotTraceFlat` (analytic boxes and a ground plane) is not a toy. A headless server, a self-test and a deterministic replay all need to trace against a world without a populated physics space. It plays the role `DotFpsFlatBody` plays in dot-player-controller, and the whole self-test runs against one.

## Ties

`DotTrace.ray` takes a hitbox hit only when it is **strictly** nearer than the best so far (`hit.distance >= best.distance` skips it). A player standing flush against cover produces exactly this tie, and giving it to the hitbox is how they get shot through the thing they are hugging. The self-test builds an exact 9.0-vs-9.0 tie (`_test_cover_tie`), because two distances that merely happen to be close do not test the tie-break.

Inside `DotHitboxSet.intersect_ray`, a head capsule inside a torso box shares a surface, and floating-point equality on the entry distance is common enough that leaving the tie to child order makes headshots land about half the time. It is broken by `precedence`, then by `damage_scale`.

A ray that starts inside a hitbox reports a hit at distance zero, not a miss.

## Every rewind is restored

`resolve_shot()` refuses shots (rate limits, dead shooters, negative ticks) **before** `_begin_rewind`, and nothing between `_begin_rewind` and `_end_rewind` returns early. A leaked rewind leaves every hitbox in the past permanently, and the symptom is not an error: shots quietly start missing for everyone. `_test_lag_compensation` asserts `rewinds.size() == restores.size()` across a run that is mostly refusals.

## Never trust the client's muzzle

`_correct_origin` relocates a shot whose reported origin is more than `config.max_origin_error` from where the server believes the shooter is. **Relocating, not refusing**: a legitimate client's origin is always slightly wrong (it is a tick ahead by construction), and refusing those shots makes the game unplayable for everyone to stop a cheat that clamping already stops. Without `set_authoritative_origin()` per entity it does nothing, and the client's claim is taken as given.

## A team-mate holding the muzzle is not a target

`DotHitbox` counts a ray that starts inside it as a hit at 0 m, which is right for a shotgun pressed against an enemy's chest. Where team-mates do not collide (most networked games, since player-player collision is what makes prediction disagree), two can stand in one place; then every shot, aimed anywhere, hits the friend at 0 m and nothing else. With friendly fire off it is no better: the friend refuses the damage but still eats the bullet. So `DotCombatManager._trace_shot` excludes, along with the shooter, every set from `pass_through_sets(shot)`: the sets that contain the muzzle (`DotHitboxSet.contains_point`, judged inside the rewind) and belong to a team-mate (`DotDamageResolver.are_team_mates`). An enemy holding the muzzle is still a point-blank hit; a team-mate merely in the line is still friendly fire. `DotDamageRules.pass_through_team_mate_at_muzzle` (default on) turns it off; `DotCombatManager.pass_through_fn` replaces the rule for a game whose overlap is not a team question.

It lives in the manager because that is the only place that holds the attacker, the victim's id and `team_of` together: the hitbox is right on its own terms, and the trace knows geometry but not teams. Code that traces outside `resolve_shot` (a hit marker, a bot's friend-in-line check) calls `pass_through_sets` itself.

## Zero is not a team

`DotDamageResolver._same_team` returns false when either side is team 0. Two unassigned players in a free-for-all comparing `0 == 0` would be allies, and with friendly fire off that is a mode where nobody can damage anybody. It is invisible until someone plays a deathmatch, so the suite covers it.

## A critical is a flag before it is a number

`DotDamageRules.critical_headshots` (on), `critical_chance` (0) and `critical_scale` (1) decide `DotDamage.critical`. **With the defaults no damage number changes**: a headshot is flagged and does the head's damage. The flag is what a game rewards (coins out of the body, a health drop, a meter, a marker), so the payoff is the game's and the judgement is here, once. The chance is rolled from the hit (`DotDamageResolver.critical_roll`: attacker, victim, tick and weapon id, hashed as text) for the same reason spread is: a random stream is a seed somebody has to share. Only health replicates, so a client learns a hit was critical from the game's own hit event.

## Wire form

`DotCombatNetSync` replicates health, armour and alive, and health and armour as integers: an integer compares exactly, so a reconciling client does not see a correction every tick because the server's `73.4001` differs from its own `73.4`. It carries health alone; the slot, magazine and reserve are dot-weapon's `DotWeaponNetSync` (which keeps ammunition `owner_only`, since exact ammunition is information an opponent should not have). A game using both concatenates the two spec lists.

## Coupling: nothing is imported

dot-combat names no class outside dot-core: not dot-net, dot-weapon, dot-player-controller or dot-server. A script that *mentions* a missing `class_name` fails to parse and takes every script referencing it down with it (the same reason `DotWeaponCommand.write` / `read` in dot-weapon take `Variant`).

- `DotCombatNetSync` describes what to replicate as data, with type names as strings (`"UINT"`, `"BOOL"`), which a bridge resolves with `DotNetVar.Type[spec.type]`. The ~30-line `DotNetBehaviour` that joins it to dot-net belongs in the game; the worked example is in `DotCombatNetSync`'s class documentation.
- Lag compensation is two `Callable`s.
- Movement state is pushed into dot-weapon's `DotWeaponContext` by the host rather than read out of a controller. An interpolated position differs between client and server by design, and feeding it to the spread would make the spread differ too.

## Deliberately not here

- **Projectiles as entities.** A projectile is a replicated entity with a lifetime: dot-net's to carry, dot-weapon's (`DotWeaponProjectile`, `DotWeaponSpawn`) and the game's to model.
- **Anything about what a player holds.** Rate of fire, magazines, reloading, switching, recoil and melee arcs are dot-weapon's; a `DotShot` is the seam.
- **Ballistics.** No drag, wind, penetration or ricochet. `DotDamageType` has the falloff a shooter needs and nothing a simulation would want.
- **Hit markers, tracers, decals, sounds.** `DotShot.impacts` and the signals carry what a presentation layer needs; no art, no audio.
- **Ammunition as pickups.** `DotWeaponArsenal.add_ammo` is the API in dot-weapon; the world entity that calls it belongs to dot-loadout or the game.
- **Damage over time.** No burning, bleeding or poison: `apply_damage` per tick from a game's own timer is the whole implementation, and there is no shared piece worth extracting yet.
