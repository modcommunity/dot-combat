# dot-combat

Health, damage and hit registration: analytic hitboxes, deterministic spread, lag compensation, and a resolver that turns a `DotShot` into damage under one set of rules. Weapons are dot-weapon's; this addon does not know what a weapon is.

Read the family [CLAUDE.md](../../CLAUDE.md) first; this file is only what is specific to combat.

**The distributable is `addons/dot_combat/`.** It requires [dot-core](../dot-core) and nothing else (`ln -s ../../dot-core/addons/dot_core addons/dot_core`, gitignored). It works with dot-net, dot-weapon and dot-player-controller without naming any of their classes.

## Read before

| Read | Before |
| --- | --- |
| [docs/design.md](docs/design.md) | anything: the two jobs, the self-describing shot, spread, hitboxes, ties, rewinds, origin correction, team zero, criticals, wire form, coupling, what is not here |
| [docs/history.md](docs/history.md) | touching `DotSpread` or the shot: the half-moon spread, the hand-copied constants, the shot that held a weapon, stacked team-mates |

## Layout

| Path | What |
| --- | --- |
| `core/dot_shot.gd` | `DotShot`: a shot that describes itself (damage, type, range, pellets, splash, `deferred`) |
| `core/dot_spread.gd` | `DotSpread`: deterministic scatter over dot-core's `DotRandomStream` |
| `core/dot_hitbox.gd`, `dot_hitbox_set.gd`, `dot_hit_group.gd` | analytic capsule, box and sphere hitboxes; tie-break by precedence |
| `core/dot_health.gd`, `dot_damage.gd`, `dot_damage_type.gd` | health and armour, the damage event, falloff |
| `trace/` | `DotTrace` (world ray plus hitboxes), `DotTracePhysics` (world via the physics server), `DotTraceFlat` (analytic boxes and a ground plane) |
| `resolve/` | `DotDamageResolver`, `DotDamageRules`: teams, friendly fire, falloff, criticals |
| `net/dot_combat_net_sync.gd` | `DotCombatNetSync`: health, armour and alive as data specs |
| `dot_combat_manager.gd` | `DotCombatManager`: trace, rewind, resolve, apply |
| `dot_combat_config.gd` | `DotCombatConfig`: rate limits, `max_origin_error`, lag compensation |
| `examples/combat_selftest.tscn` | the suite, all offline |

Paths except `examples/` are in `addons/dot_combat/`.

## Running and testing

The family's two steps ([game-dev/CLAUDE.md](../../CLAUDE.md#validating-anything)), then `godot --headless --path . res://examples/combat_selftest.tscn` (exits non-zero on any failure). Run it after any change to the trace, the resolver or the manager: several checks exist because the obvious implementation is wrong (the wall tie, the leaked rewind, the zero-team truce, the point-blank ray, the team-mate at the muzzle, the pass-through cvar read back on bind, a client following the server's level).

## Rules that bite

- The manager resolves and applies damage only where `is_authority`; a client traces for effects and never touches a `DotHealth`. [design](docs/design.md#two-jobs-two-places)
- A `DotShot` carries its own numbers; never make the manager read them off a weapon resource. [design](docs/design.md#a-dotshot-describes-itself)
- Spread is a pure integer function of `(shooter, tick, shot, pellet)`; never `randf()` or a stream, or client and server disagree silently. [design](docs/design.md#spread-cannot-come-from-a-random-number-generator)
- Keep the quadrant check in `_test_spread_determinism`; a max-angle check passes for a half-moon pattern. [history](docs/history.md#the-half-moon-spread)
- Hitboxes are arithmetic, not `Area3D`; world geometry goes through the physics server once. [design](docs/design.md#hitboxes-are-not-area3ds)
- Ties go to the wall (a hitbox must be strictly nearer); within a set, ties go to `precedence`, then `damage_scale`. [design](docs/design.md#ties)
- Refuse a shot before `_begin_rewind`; nothing between it and `_end_rewind` may return early. [design](docs/design.md#every-rewind-is-restored)
- `_correct_origin` relocates, never refuses, and does nothing without `set_authoritative_origin()` per entity. [design](docs/design.md#never-trust-the-clients-muzzle)
- A shot passes through a team-mate whose hitboxes hold the muzzle (`pass_through_sets`), never an enemy: point-blank on an enemy stays a 0 m hit. [design](docs/design.md#a-team-mate-holding-the-muzzle-is-not-a-target)
- `mp_teammate_passthrough` (0 never, 1 at the muzzle, 2 every team-mate in the line) is the manager's cvar; a game binds it with `combat.bind_cvars(add_cvar, FLAG_NOTIFY | FLAG_REPLICATED)` on its authoritative manager, never with its own copy, and each client's manager calls `follow_cvars(link)`. [design](docs/design.md#the-operator-decides-mp_teammate_passthrough)
- register_hitboxes/register_health ignore entity id 0 or a null node with a warning and count it (describe()["registrations_refused"]); register after the entity has its network id.
- Team 0 is "no team" in `_same_team`, or a free-for-all with friendly fire off has nobody able to hurt anybody. [design](docs/design.md#zero-is-not-a-team)
- Critical defaults change no number; the roll is a hash of the hit, not a stream. [design](docs/design.md#a-critical-is-a-flag-before-it-is-a-number)
- Health replicates as integers; ammunition is dot-weapon's `DotWeaponNetSync`, not here. [design](docs/design.md#wire-form)
- Name no class outside dot-core; net types are strings resolved by the game's bridge. [design](docs/design.md#coupling-nothing-is-imported)

Deliberately not here: projectiles as entities, anything about what a player holds, ballistics, presentation, ammunition pickups, damage over time. [design](docs/design.md#deliberately-not-here)
