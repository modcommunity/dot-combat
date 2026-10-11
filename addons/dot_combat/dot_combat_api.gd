extends RefCounted

## dot-combat's API level. The rule for bumping it is on [DotAddonApi].
##
## LEVEL rises by one for anything a game could call that did not exist before. OLDEST is
## raised to LEVEL when something a game could have called is removed or changes meaning,
## because every pack built before that no longer compiles against this addon.

# 1: everything before this file existed.
# 2: DotDamageRules.pass_through_team_mate_at_muzzle, DotCombatManager.pass_through_fn and
#    pass_through_sets(), DotDamageResolver.are_team_mates(), DotHitboxSet.contains_point().
# 3: DotDamageRules.pass_through_team_mates, PASS_THROUGH_* and pass_through_level() /
#    set_pass_through_level(); DotCombatManager.CVAR_TEAMMATE_PASSTHROUGH, cvar_specs(),
#    bind_cvars() and set_cvar() (the mp_teammate_passthrough server cvar).
const LEVEL := 3
const OLDEST := 1
