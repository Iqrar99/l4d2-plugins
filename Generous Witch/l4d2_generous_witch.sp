/**
 * Generous Witch
 * --------------
 * Every Witch that dies (by any means) drops exactly one item:
 * a First Aid Kit, a Defibrillator, or a random pick between the two.
 *
 * ConVars (auto-generated in cfg/sourcemod/l4d2_generous_witch.cfg):
 *   l4d2_generous_witch_enable  "1"   - 0 = disabled, 1 = enabled
 *   l4d2_generous_witch_drop    "2"   - 0 = Medkit, 1 = Defib, 2 = Random
 *   l4d2_generous_witch_modes   ""    - Comma-separated list of gamemodes (e.g. "coop,realism").
 *                                       Empty = active in every gamemode.
 *   l4d2_generous_witch_lvfix   "1"   - 1 = treat a Witch removed while alive as killed
 *                                       (low violence fix). See below.
 *
 * Death detection:
 *   1. The witch_killed event (normal deaths).
 *   2. OnEntityDestroyed. In low violence mode ("-lv"), explosive ammo and
 *      explosions delete the Witch instantly, at full health, without any
 *      damage or death event. With lvfix on, a Witch removed while alive is
 *      counted as killed, unless:
 *        - the round or map is ending (normal entity cleanup), or
 *        - she incapped or killed a survivor (she flees and may despawn).
 * A per-Witch flag guarantees only one drop regardless of which path fires.
 */

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>

#define PLUGIN_VERSION "1.0.0"

#define ITEM_MEDKIT "weapon_first_aid_kit"
#define ITEM_DEFIB  "weapon_defibrillator"

#define DROP_MEDKIT 0
#define DROP_DEFIB  1
#define DROP_RANDOM 2

#define MAX_ENTS    2049

public Plugin myinfo =
{
	name        = "[L4D2] Generous Witch",
	author      = "monnie",
	description = "Witch drops a medkit or defibrillator when killed.",
	version     = PLUGIN_VERSION,
	url         = "https://gitlab.com/iqrar99/l4d2-plugins"
};

ConVar g_cvEnable;
ConVar g_cvDropType;
ConVar g_cvModes;
ConVar g_cvLvFix;
ConVar g_cvGameMode;

// Cached result of the enable + gamemode check
bool g_bAllowed;

// True while the round or map is shutting down; removals then are cleanup
bool g_bRoundEnding;

// Per-entity Witch state, indexed by entity index
bool g_bTracked[MAX_ENTS];    // Entity is a living Witch we are watching
bool g_bRetreating[MAX_ENTS]; // Witch incapped/killed a survivor and is fleeing

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
	if (GetEngineVersion() != Engine_Left4Dead2)
	{
		strcopy(error, err_max, "Generous Witch only supports Left 4 Dead 2.");
		return APLRes_SilentFailure;
	}
	return APLRes_Success;
}

public void OnPluginStart()
{
	CreateConVar("l4d2_generous_witch_version", PLUGIN_VERSION, "Generous Witch version",
		FCVAR_NOTIFY | FCVAR_DONTRECORD);

	g_cvEnable = CreateConVar("l4d2_generous_witch_enable", "1",
		"0 = Plugin disabled, 1 = Plugin enabled.",
		FCVAR_NOTIFY, true, 0.0, true, 1.0);

	g_cvDropType = CreateConVar("l4d2_generous_witch_drop", "2",
		"Item dropped by the Witch. 0 = First Aid Kit, 1 = Defibrillator, 2 = Random.",
		FCVAR_NOTIFY, true, 0.0, true, 2.0);

	g_cvModes = CreateConVar("l4d2_generous_witch_modes", "",
		"Comma-separated gamemodes where the plugin is active (e.g. \"coop,realism,versus\"). Empty = all gamemodes.",
		FCVAR_NOTIFY);

	g_cvLvFix = CreateConVar("l4d2_generous_witch_lvfix", "1",
		"Low violence fix. 1 = A Witch removed while alive counts as killed (except at round end or after she incaps/kills a survivor). 0 = Off.",
		FCVAR_NOTIFY, true, 0.0, true, 1.0);

	g_cvGameMode = FindConVar("mp_gamemode");

	g_cvEnable.AddChangeHook(OnCvarChanged);
	g_cvModes.AddChangeHook(OnCvarChanged);
	if (g_cvGameMode != null)
	{
		g_cvGameMode.AddChangeHook(OnCvarChanged);
	}

	AutoExecConfig(true, "l4d2_generous_witch");

	HookEvent("witch_killed", Event_WitchKilled);
	HookEvent("round_start", Event_RoundStart, EventHookMode_PostNoCopy);
	HookEvent("round_end", Event_RoundEnd, EventHookMode_PostNoCopy);
	HookEvent("player_incapacitated", Event_WitchAttacked);
	HookEvent("player_death", Event_WitchAttacked);

	// Late load: start tracking Witches that already exist
	int ent = -1;
	while ((ent = FindEntityByClassname(ent, "witch")) != -1)
	{
		TrackWitch(ent);
	}
}

public void OnConfigsExecuted()
{
	UpdateAllowed();
}

void OnCvarChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
	UpdateAllowed();
}

/**
 * Recomputes whether the plugin should act, based on the enable cvar
 * and whether the current mp_gamemode is in the allowed list.
 */
void UpdateAllowed()
{
	if (!g_cvEnable.BoolValue)
	{
		g_bAllowed = false;
		return;
	}

	char modes[256];
	g_cvModes.GetString(modes, sizeof(modes));
	ReplaceString(modes, sizeof(modes), " ", "");

	// Empty list = active in every gamemode
	if (modes[0] == '\0' || g_cvGameMode == null)
	{
		g_bAllowed = true;
		return;
	}

	char mode[64];
	g_cvGameMode.GetString(mode, sizeof(mode));

	// Wrap both in commas so "versus" does not match "teamversus"
	Format(modes, sizeof(modes), ",%s,", modes);
	Format(mode, sizeof(mode), ",%s,", mode);

	g_bAllowed = (StrContains(modes, mode, false) != -1);
}

// ---------------------------------------------------------------------------
// Round / map state
// ---------------------------------------------------------------------------

public void OnMapStart()
{
	g_bRoundEnding = false;
}

public void OnMapEnd()
{
	g_bRoundEnding = true;
}

void Event_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
	g_bRoundEnding = false;
}

void Event_RoundEnd(Event event, const char[] name, bool dontBroadcast)
{
	g_bRoundEnding = true;
}

/**
 * A Witch that incaps or kills a survivor runs away and can despawn on her
 * own. Mark her so that removal is not mistaken for a kill.
 */
void Event_WitchAttacked(Event event, const char[] name, bool dontBroadcast)
{
	int attacker = event.GetInt("attackerentid");
	if (IsTrackableIndex(attacker) && g_bTracked[attacker])
	{
		g_bRetreating[attacker] = true;
	}
}

// ---------------------------------------------------------------------------
// Witch tracking
// ---------------------------------------------------------------------------

bool IsTrackableIndex(int entity)
{
	return (entity > MaxClients && entity < MAX_ENTS);
}

public void OnEntityCreated(int entity, const char[] classname)
{
	if (StrEqual(classname, "witch"))
	{
		TrackWitch(entity);
	}
}

void TrackWitch(int witch)
{
	if (IsTrackableIndex(witch))
	{
		g_bTracked[witch]    = true;
		g_bRetreating[witch] = false;
	}
}

/**
 * Normal death path.
 */
void Event_WitchKilled(Event event, const char[] name, bool dontBroadcast)
{
	TryDrop(event.GetInt("witchid"));
}

/**
 * Catches Witches deleted without a death event (low violence mode).
 * The entity is still valid here, so her position can be read directly.
 * A Witch that already dropped is no longer tracked, so this is a no-op then.
 */
public void OnEntityDestroyed(int entity)
{
	if (!IsTrackableIndex(entity) || !g_bTracked[entity])
	{
		return;
	}

	if (g_cvLvFix.BoolValue && !g_bRoundEnding && !g_bRetreating[entity])
	{
		TryDrop(entity);
	}

	g_bTracked[entity] = false;
}

// ---------------------------------------------------------------------------
// Dropping
// ---------------------------------------------------------------------------

/**
 * Drops the item once per Witch, at her current position.
 * Untracking her first guarantees no second drop from another path.
 */
void TryDrop(int witch)
{
	if (!IsTrackableIndex(witch) || !g_bTracked[witch])
	{
		return;
	}
	g_bTracked[witch] = false;

	if (!g_bAllowed || !IsValidEntity(witch))
	{
		return;
	}

	float pos[3];
	GetEntPropVector(witch, Prop_Data, "m_vecAbsOrigin", pos);
	pos[2] += 15.0; // Lift slightly so the item does not clip into the floor

	// Spawn on the next frame instead of inside an event or entity callback
	DataPack dp = new DataPack();
	dp.WriteFloatArray(pos, sizeof(pos));
	RequestFrame(Frame_SpawnDrop, dp);
}

/**
 * Picks the item according to l4d2_generous_witch_drop and spawns it
 * at the stored position.
 */
void Frame_SpawnDrop(DataPack dp)
{
	float pos[3];
	dp.Reset();
	dp.ReadFloatArray(pos, sizeof(pos));
	delete dp;

	int dropType = g_cvDropType.IntValue;
	if (dropType == DROP_RANDOM)
	{
		dropType = GetRandomInt(DROP_MEDKIT, DROP_DEFIB);
	}

	int item = CreateEntityByName(dropType == DROP_DEFIB ? ITEM_DEFIB : ITEM_MEDKIT);
	if (item == -1)
	{
		LogError("Generous Witch: failed to create the drop item.");
		return;
	}

	TeleportEntity(item, pos, NULL_VECTOR, NULL_VECTOR);
	DispatchSpawn(item);
	ActivateEntity(item);
}
