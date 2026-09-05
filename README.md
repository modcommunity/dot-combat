This is the **combat** asset for TMC's **Dot** collection. It is what turns a movement demo into a shooter, and it is built so a client can predict its own fire while the server stays the authority.

This collection of assets provides modular building blocks for creating games and applications within the TMC ecosystem, ensuring consistency and interoperability across all `dot-*` assets. This includes core functionality, networking, authentication, cloud integration, and more.

**These assets are COMPLETELY OPEN SOURCE**. You are free to use, modify, and distribute them under the terms of the MIT license. The only thing not open source is the back-end web infrastructure. So if you opt into using your own authentication backend instead of integrating with TMC, you will need to build and integrate your own back-end infrastructure.

## From Maintainer & WARNING
This asset, along with all the others, was built initially with **Claude Code** and will continue to be maintained and extended using it. This is because I (`gamemann`) cannot build the entire TMC platform alone (I wish I could lol).

**Please treat this as partially tested.** Every asset has its own headless test suite and those suites pass, but very little of this has been in front of real players yet. Expect rough edges, and please report anything you run into.

I intend on reviewing code, testing, and editing documentation regularly. If you're interested in helping out, please let me know!

## Health, Damage and Weapons
Health, damage and weapons for a Godot 4 shooter. Analytic hitboxes, deterministic
spread, lag-compensated hit registration, and an arsenal that simulates from commands
so a client can predict its own fire and a server can re-run it authoritatively.

Part of the [dot-*](../NOTES.md) family. Needs **dot-core**. Works with **dot-net**
and **dot-fps-controller** without importing either.

## Install

Copy `addons/dot_combat/` and `addons/dot_core/` into your project and enable both in
*Project → Project Settings → Plugins*.

## Use

```gdscript
# Once, on the server.
var combat := DotCombatManager.new()
combat.trace = DotTracePhysics.for_world(get_world_3d())
combat.rules = DotDamageRules.strict()
add_child(combat)

# Per shootable entity.
hitbox_set.register_with(combat, player_id)
combat.register_health(player_id, health)

# Per simulated tick, on client and server alike.
arsenal.movement = velocity.length() / max_speed
arsenal.airborne = not grounded
for shot in arsenal.simulate_tick(tick, delta, command):
    if is_server:
        combat.resolve_shot(shot, client_view_tick)
```

## The idea

A weapon decides that a shot *happened*. Something else decides what it *hit*.

`DotArsenal.simulate_tick()` is a pure function of the command it is given and its own
state — no device, no clock, no other node, no damage. It produces `DotShot`s. The
owning client runs it optimistically and the server runs it authoritatively, and both
reach the same shot from the same command, because the spread is a hash of the shot
rather than a draw from a random stream.

`DotCombatManager.resolve_shot()` traces those shots and applies the damage, and runs
only where the game is authoritative. A client that resolved its own shots would be a
client that decides who dies.

## What is in the box

| | |
| --- | --- |
| `DotHealth` | Health, armour, regeneration, spawn protection. Counted in ticks, so it replays. |
| `DotDamage` | One damage event, carrying its own scaling trace so a surprising number can be explained. |
| `DotDamageType` | Falloff, armour share, self and friendly scales. A game adds its own. |
| `DotHitGroup` | Named regions and their multipliers. A table, not an enum. |
| `DotHitbox` / `DotHitboxSet` | Capsules, boxes and spheres tested analytically against a ray. |
| `DotTrace` | Where a shot goes. `DotTracePhysics` for a real world, `DotTraceFlat` for a headless one. |
| `DotWeapon` | The definition: rate, spread, recoil, magazine, reload, splash. Seconds in, ticks out. |
| `DotWeaponState` | One carrier's runtime state for one weapon. Integers throughout. |
| `DotArsenal` | What is held, and what the trigger does. The predicted part. |
| `DotSpread` | Deterministic scatter. The reason prediction works. |
| `DotDamageRules` / `DotDamageResolver` | Friendly fire, self damage, hit groups, falloff, clamping — in one order, once. |
| `DotCombatManager` | Tracing, lag compensation, damage application, kill reporting. |
| `DotCombatNetSync` | What to replicate, without naming a dot-net type. |

## Three failure modes it is built around

**A shot that agrees with itself.** Spread from a `RandomNumberGenerator` gives a
different pattern on the client that predicted the shot and the server that re-ran it,
and a third one on every reconciliation replay. `DotSpread` is a pure function of
(shooter, tick, shot, pellet), so all three agree.

**A shot through a wall.** World geometry and entity hitboxes are traced together, the
world hit shortens the search, and a tie between a hitbox and a wall surface goes to
the wall. A player hugging cover is not shot through it.

**A rewind that leaks.** Lag compensation moves every hitbox in the level into the
past. Every path out of `resolve_shot()` restores it, including the refusal paths,
because a rewind that is never undone leaves the world permanently in the past and the
symptom is that shots quietly start missing for everyone.

## Lag compensation

dot-combat does not depend on dot-net and does not name it. Two callables turn
compensation on:

```gdscript
combat.rewind_fn = func(view_tick: float) -> void:
    net.history.rewind(view_tick, net.registry.all())
combat.restore_fn = net.history.restore
```

Unset, shots resolve against the present, which is correct for a listen server and
wrong for anyone with latency.

## Validating

```bash
godot --headless --path . --import
find . -name '*.gd' -not -path './.godot/*' | while read f; do
    godot --headless --path . --check-only --script "res://${f#./}"
done
godot --headless --path . res://examples/combat_selftest.tscn
```

169 checks, all offline. Exits non-zero on any failure.
