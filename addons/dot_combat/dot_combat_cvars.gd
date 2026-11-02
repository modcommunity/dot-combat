class_name DotCombatCvars
extends RefCounted
## The server settings of a [DotCombatManager]: the cvar table and how a value is written into its rules.

var m: DotCombatManager = null


func _init(manager: DotCombatManager) -> void:
	m = manager


func specs() -> Array[Dictionary]:
	var level := m.rules.pass_through_level() if m.rules != null else DotDamageRules.PASS_THROUGH_AT_MUZZLE
	var out: Array[Dictionary] = [
		{
			"name": DotCombatManager.CVAR_TEAMMATE_PASSTHROUGH,
			"value": str(level),
			"description": "Shots and team-mates: 0 a team-mate is hit and blocks the shot, 1 a shot passes through a team-mate standing at the muzzle, 2 shots pass through every team-mate in the line",
			"min": float(DotDamageRules.PASS_THROUGH_NONE),
			"max": float(DotDamageRules.PASS_THROUGH_ALWAYS),
		},
		{
			"name": DotCombatManager.CVAR_FRIENDLY_FIRE,
			"value": "1" if m.rules != null and m.rules.friendly_fire else "0",
			"description": "Friendly fire: 1 a shooter can damage a team-mate, 0 team-mates are immune to each other",
			"min": 0.0,
			"max": 1.0,
		},
		{
			"name": DotCombatManager.CVAR_HITZONES,
			"value": "1" if m.rules != null and m.rules.hitzones else "0",
			"description": "Hit zones: 1 neck, hands and feet have their own damage multipliers, 0 they count as chest, arm and leg",
			"min": 0.0,
			"max": 1.0,
		},
		{
			"name": DotCombatManager.CVAR_PENETRATION,
			"value": "1" if m.penetration_enabled else "0",
			"description": "Bullet penetration: 1 rounds with an ammo profile pass walls and bodies, 0 every wall stops them",
			"min": 0.0,
			"max": 1.0,
		},
		{
			"name": DotCombatManager.CVAR_PENETRATION_SCALE,
			"value": str(m.penetration_scale),
			"description": "Multiplier on every round's penetration power",
			"min": 0.0,
			"max": 10.0,
		},
		{
			"name": DotCombatManager.CVAR_PENETRATION_PLAYERS,
			"value": "1" if m.penetration_players else "0",
			"description": "1 a round passes through a player and can hurt the one behind, 0 a player stops it",
			"min": 0.0,
			"max": 1.0,
		},
		{
			"name": DotCombatManager.CVAR_RICOCHET,
			"value": "1" if m.ricochet_enabled else "0",
			"description": "Ricochet: 1 shallow hits on the hard materials an ammo profile lists bounce on, 0 they stop or pass as before",
			"min": 0.0,
			"max": 1.0,
		},
	]
	return out


## Applies one cvar by name. False for a name that is not the manager's or a value that is not a number.
func apply(cvar_name: String, value: String) -> bool:
	if cvar_name in [DotCombatManager.CVAR_PENETRATION, DotCombatManager.CVAR_PENETRATION_SCALE, DotCombatManager.CVAR_PENETRATION_PLAYERS, DotCombatManager.CVAR_RICOCHET]:
		return _apply_penetration(cvar_name, value)
	if cvar_name != DotCombatManager.CVAR_TEAMMATE_PASSTHROUGH and cvar_name != DotCombatManager.CVAR_FRIENDLY_FIRE and cvar_name != DotCombatManager.CVAR_HITZONES:
		return false

	var text := value.strip_edges().to_lower()
	if (cvar_name == DotCombatManager.CVAR_FRIENDLY_FIRE or cvar_name == DotCombatManager.CVAR_HITZONES) and text in ["true", "false"]:
		text = "1" if text == "true" else "0"

	if not text.is_valid_float():
		DotLog.warn(DotCombatManager.CHANNEL, "cvar is not a number; left as it was", {"cvar": cvar_name, "value": value})
		return false

	if m.rules == null:
		m.rules = DotDamageRules.new()

	if cvar_name == DotCombatManager.CVAR_HITZONES:
		m.rules.hitzones = text.to_float() != 0.0
		if m.resolver != null and m.resolver.rules != null and m.resolver.rules != m.rules:
			m.resolver.rules.hitzones = m.rules.hitzones
		return true

	if cvar_name == DotCombatManager.CVAR_FRIENDLY_FIRE:
		m.rules.friendly_fire = text.to_float() != 0.0
		if m.resolver != null and m.resolver.rules != null and m.resolver.rules != m.rules:
			m.resolver.rules.friendly_fire = m.rules.friendly_fire
		DotLog.debug(DotCombatManager.CHANNEL, "friendly fire set", {"on": m.rules.friendly_fire})
		return true

	m.rules.set_pass_through_level(roundi(text.to_float()))

	# One object in practice (setup() hands the resolver this one), but a game that
	# assigned the resolver its own after setup would otherwise keep the old rule there.
	if m.resolver != null and m.resolver.rules != null and m.resolver.rules != m.rules:
		m.resolver.rules.set_pass_through_level(m.rules.pass_through_level())

	DotLog.debug(DotCombatManager.CHANNEL, "team-mate pass-through set", {"level": m.rules.pass_through_level()})
	return true


func _apply_penetration(cvar_name: String, value: String) -> bool:
	var text := value.strip_edges().to_lower()
	if text in ["true", "false"]:
		text = "1" if text == "true" else "0"
	if not text.is_valid_float():
		DotLog.warn(DotCombatManager.CHANNEL, "cvar is not a number; left as it was", {"cvar": cvar_name, "value": value})
		return false
	var number := text.to_float()
	if cvar_name == DotCombatManager.CVAR_PENETRATION:
		m.penetration_enabled = number != 0.0
	elif cvar_name == DotCombatManager.CVAR_PENETRATION_PLAYERS:
		m.penetration_players = number != 0.0
	elif cvar_name == DotCombatManager.CVAR_RICOCHET:
		m.ricochet_enabled = number != 0.0
	else:
		m.penetration_scale = maxf(0.0, number)
	return true
