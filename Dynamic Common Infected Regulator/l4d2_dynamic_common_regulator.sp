#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <left4dhooks>

#define PLUGIN_VERSION "1.2.0"

#define TEAM_SURVIVOR            2
#define BASE_SURVIVORS           4      // Standard L4D2 survivor count; scaling starts above this.
#define SAFETY_RECOUNT_INTERVAL  3.0    // Seconds. Safety net in case an event is missed.

public Plugin myinfo =
{
    name = "[L4D2] Common Infected Regulator - Dynamic",
    author = "monnie",
    description = "Scales Director common infected settings from the map's own Director/VScript values based on living survivors.",
    version = PLUGIN_VERSION,
    url = "https://gitlab.com/iqrar99/l4d2-plugins"
};

// ---------------------------------------------------------------------------
// Director keys that get scaled.
// An integer index + StringMap keeps the hook lookup at a single native call
// (a hash lookup) instead of a chain of 7 StrEqual calls on every Director
// request.
// ---------------------------------------------------------------------------
enum
{
    KEY_COMMON_LIMIT = 0,
    KEY_CM_COMMON_LIMIT,
    KEY_MOB_SPAWN_SIZE,
    KEY_MEGA_MOB_SIZE,
    KEY_MOB_MIN_SIZE,
    KEY_MOB_MAX_SIZE,
    KEY_MOB_MAX_PENDING,
    KEY_COUNT
};

// Order MUST match the enum above.
char g_sKeyNames[][] =
{
    "CommonLimit",
    "cm_CommonLimit",
    "MobSpawnSize",
    "MegaMobSize",
    "MobMinSize",
    "MobMaxSize",
    "MobMaxPending"
};

// ---------------------------------------------------------------------------
// Cvar fallback for regular mob sizes.
// Testing showed that, at least on vanilla maps, the Director reads regular
// (natural) mob sizes straight from these cvars instead of through
// CDirector::GetScriptValue, so the hook alone never scales them. For these
// two settings only, the plugin writes a scaled value into the cvar and
// always keeps track of the real ("base") value so it can be restored.
// ---------------------------------------------------------------------------
enum
{
    MOBCVAR_MIN = 0,
    MOBCVAR_MAX,
    MOBCVAR_COUNT
};

char g_sMobCvarNames[][] =
{
    "z_mob_spawn_min_size",
    "z_mob_spawn_max_size"
};

// The Director key that represents the same setting. Used to avoid scaling
// twice if the Director passes our already-scaled cvar value into the hook
// as the default.
int g_iMobCvarKey[] =
{
    KEY_MOB_MIN_SIZE,
    KEY_MOB_MAX_SIZE
};

ConVar g_hMobCvar[MOBCVAR_COUNT];
int    g_iMobBase[MOBCVAR_COUNT];     // Real value set by configs/admins/maps.
int    g_iMobWritten[MOBCVAR_COUNT];  // Value this plugin last wrote.
bool   g_bMobApplied[MOBCVAR_COUNT];  // true while the cvar holds a scaled value.
bool   g_bWritingMobCvar;             // Guards our own writes in the change hook.

ConVar g_hEnabled;
ConVar g_hPercent;
ConVar g_hMaxMultiplier;
ConVar g_hValueCap;
ConVar g_hDebug;
ConVar g_hScaleMobCvars;

// ConVar values read inside the Director hook are cached in globals, because
// the hook runs very often and reading a ConVar is a native call.
bool  g_bEnabled;
bool  g_bDebug;
bool  g_bScaleMobCvars;
int   g_iValueCap;

int   g_iLivingSurvivors;
float g_fMultiplier = 1.0;

Handle g_hRecountTimer;   // One-shot recount timer (debounce).
Handle g_hSafetyTimer;    // Repeating recount timer (safety net).

StringMap g_hKeyIndex;    // "CommonLimit" -> KEY_COMMON_LIMIT, etc.

// Last value seen per key, shown by sm_cge_debug.
bool g_bSeen[KEY_COUNT];
int  g_iLastOriginal[KEY_COUNT];
int  g_iLastScaled[KEY_COUNT];

// Last value printed per key, used to de-dup debug logs.
bool g_bLogged[KEY_COUNT];
int  g_iLoggedOriginal[KEY_COUNT];
int  g_iLoggedScaled[KEY_COUNT];

// ===========================================================================
// Lifecycle
// ===========================================================================

public void OnPluginStart()
{
    CreateConVar("commonregulator_version", PLUGIN_VERSION,
        "CommonRegulator plugin version.",
        FCVAR_NOTIFY | FCVAR_DONTRECORD);

    // Note: FCVAR_PLUGIN was removed back in Orange Box and has no effect,
    // so it is no longer used.
    g_hEnabled = CreateConVar("commonregulator", "1",
        "Enable dynamic common infected regulation. 1 = enabled, 0 = disabled.",
        FCVAR_NOTIFY, true, 0.0, true, 1.0);

    g_hPercent = CreateConVar("commonregulator_percent_per_survivor", "20",
        "Percentage increase for each living survivor above 4. 20 = +20% per additional survivor. Decimals allowed.",
        FCVAR_NONE, true, 0.0, true, 100.0);

    g_hMaxMultiplier = CreateConVar("commonregulator_max_multiplier", "2.5",
        "Hard ceiling for the multiplier, regardless of survivor count. Protects against edict/entity overload.",
        FCVAR_NONE, true, 1.0, true, 10.0);

    g_hValueCap = CreateConVar("commonregulator_value_cap", "120",
        "Maximum value any scaled Director key may reach. 0 = no cap. A map value already above the cap is kept as-is.",
        FCVAR_NONE, true, 0.0, true, 1000.0);

    g_hDebug = CreateConVar("commonregulator_debug", "0",
        "Print Director key changes to the server console. 1 = on, 0 = off.",
        FCVAR_NONE, true, 0.0, true, 1.0);

    g_hScaleMobCvars = CreateConVar("commonregulator_scale_mob_cvars", "1",
        "Also scale z_mob_spawn_min_size / z_mob_spawn_max_size (regular hordes). Original values are restored on map end and plugin unload.",
        FCVAR_NONE, true, 0.0, true, 1.0);

    AutoExecConfig(true, "l4d2_dynamic_common_regulator");

    // Change hooks: whenever a cvar changes (including when AutoExecConfig
    // runs), the cached globals and the multiplier are refreshed immediately.
    g_hEnabled.AddChangeHook(OnCvarChanged);
    g_hPercent.AddChangeHook(OnCvarChanged);
    g_hMaxMultiplier.AddChangeHook(OnCvarChanged);
    g_hValueCap.AddChangeHook(OnCvarChanged);
    g_hDebug.AddChangeHook(OnCvarChanged);
    g_hScaleMobCvars.AddChangeHook(OnCvarChanged);

    g_hKeyIndex = new StringMap();
    for (int i = 0; i < KEY_COUNT; i++)
        g_hKeyIndex.SetValue(g_sKeyNames[i], i);

    for (int i = 0; i < MOBCVAR_COUNT; i++)
    {
        g_hMobCvar[i] = FindConVar(g_sMobCvarNames[i]);
        if (g_hMobCvar[i] == null)
        {
            LogError("Cvar %s not found; regular mob size fallback disabled for it.", g_sMobCvarNames[i]);
            continue;
        }

        // At this point the plugin has not written anything yet, so the
        // current value is the real one.
        g_iMobBase[i] = g_hMobCvar[i].IntValue;
        g_hMobCvar[i].AddChangeHook(OnMobCvarChanged);
    }

    HookEvent("player_spawn",       Event_SurvivorSpawnOrDeath);
    HookEvent("player_death",       Event_SurvivorSpawnOrDeath);
    HookEvent("player_team",        Event_AlwaysRecount);
    HookEvent("survivor_rescued",   Event_AlwaysRecount);
    HookEvent("defibrillator_used", Event_AlwaysRecount);
    HookEvent("player_bot_replace", Event_AlwaysRecount);
    HookEvent("bot_player_replace", Event_AlwaysRecount);

    RegAdminCmd("sm_cge_debug", Command_Debug, ADMFLAG_GENERIC,
        "Show CommonRegulator survivor and Director debug state.");

    RefreshCvarCache();
    ResetState();

    // Covers plugin load/reload while a map is already running.
    StartSafetyTimer();
    QueueRecount(1.0);
}

public void OnMapStart()
{
    ResetState();

    // Clear the handles here too (not only in OnMapEnd): a bot or player that
    // disconnects AFTER OnMapEnd can create a new timer that then gets killed
    // by the map change, leaving a stale handle that would block
    // QueueRecount/StartSafetyTimer forever. If an old timer turns out to be
    // still alive, its callback stops itself (see the identity checks in
    // Timer_Recount/Timer_Safety).
    g_hRecountTimer = null;
    g_hSafetyTimer = null;

    // Apart from the two regular mob size cvars (which are restored to their
    // base value on map end), no z_* ConVar is ever overwritten. Everything
    // else comes from the Director through the hook, so nothing leaks over
    // from the previous map.
    StartSafetyTimer();
    QueueRecount(1.0);
}

public void OnConfigsExecuted()
{
    // MultiSlots/CreateSurvivorBot may create survivors after configs execute.
    QueueRecount(1.0);
}

public void OnClientPutInServer(int client)
{
    QueueRecount(0.5);
}

public void OnClientDisconnect_Post(int client)
{
    // _Post: the client has fully left, so it is no longer counted.
    QueueRecount(0.2);
}

public void OnMapEnd()
{
    // Timers flagged TIMER_FLAG_NO_MAPCHANGE are killed automatically by
    // SourceMod on map change. Their handles must be cleared so they are not
    // treated as still active (and so StartSafetyTimer/QueueRecount will
    // create new ones).
    g_hRecountTimer = null;
    g_hSafetyTimer = null;

    ResetState();

    // Multiplier is back to 1.0 after ResetState, so this writes the base
    // values back. The next map then starts from the real values.
    ApplyMobCvars();
}

public void OnPluginEnd()
{
    // Never leave scaled values behind when the plugin is unloaded.
    g_fMultiplier = 1.0;
    ApplyMobCvars();
}

void ResetState()
{
    g_iLivingSurvivors = 0;
    g_fMultiplier = 1.0;

    for (int i = 0; i < KEY_COUNT; i++)
        g_bSeen[i] = false;

    ClearDebugLog();
}

// Forget what was last printed, so the next Director request for each key
// is logged again.
void ClearDebugLog()
{
    for (int i = 0; i < KEY_COUNT; i++)
        g_bLogged[i] = false;
}

// ===========================================================================
// ConVars
// ===========================================================================

public void OnCvarChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
    RefreshCvarCache();

    if (convar == g_hValueCap || convar == g_hDebug || convar == g_hScaleMobCvars)
    {
        // A new cap changes the scaled results, so logs should print again.
        ClearDebugLog();

        // Cap and the fallback toggle also change what the mob cvars should hold.
        ApplyMobCvars();
        return;
    }

    // enabled / percent / max_multiplier: recompute the multiplier.
    // The survivor count keeps updating even while the plugin is disabled,
    // so it is already correct when re-enabled.
    RecalculateMultiplier(true);
}

void RefreshCvarCache()
{
    g_bEnabled  = g_hEnabled.BoolValue;
    g_bDebug    = g_hDebug.BoolValue;
    g_bScaleMobCvars = g_hScaleMobCvars.BoolValue;
    g_iValueCap = g_hValueCap.IntValue;
}

// ===========================================================================
// Regular mob size cvar fallback
// ===========================================================================

// Writes base * multiplier into each mob cvar, or the base value itself when
// scaling should not apply (plugin off, fallback off, or multiplier 1.0).
// Safe to call any time: it only writes when the value actually differs.
void ApplyMobCvars()
{
    bool active = g_bEnabled && g_bScaleMobCvars && g_fMultiplier != 1.0;

    for (int i = 0; i < MOBCVAR_COUNT; i++)
    {
        if (g_hMobCvar[i] == null)
            continue;

        int desired = active ? ScaleDirectorValue(g_iMobBase[i]) : g_iMobBase[i];

        g_iMobWritten[i] = desired;
        g_bMobApplied[i] = (desired != g_iMobBase[i]);

        if (g_hMobCvar[i].IntValue == desired)
            continue;

        // The flag tells OnMobCvarChanged that this change is ours, so it
        // must not be mistaken for a new base value.
        g_bWritingMobCvar = true;
        g_hMobCvar[i].IntValue = desired;
        g_bWritingMobCvar = false;
    }
}

// Someone other than this plugin (server.cfg, a map config, an admin, or a
// map's VScript via Convars.SetValue) changed a mob cvar. Treat the new value
// as the new base, then re-apply scaling on the next frame. Writing to a cvar
// from inside its own change hook risks recursion, hence RequestFrame.
public void OnMobCvarChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
    if (g_bWritingMobCvar)
        return;

    for (int i = 0; i < MOBCVAR_COUNT; i++)
    {
        if (convar != g_hMobCvar[i])
            continue;

        g_iMobBase[i] = StringToInt(newValue);
        RequestFrame(Frame_ApplyMobCvars);
        return;
    }
}

public void Frame_ApplyMobCvars(any data)
{
    ApplyMobCvars();
}

// ===========================================================================
// Survivor counting
// ===========================================================================

// player_spawn and player_death also fire for special infected, and
// player_death even fires for every common infected that dies (userid = 0,
// victim in the "entityid" field). Without this filter, every zombie killed
// would create a new timer.
public void Event_SurvivorSpawnOrDeath(Event event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(event.GetInt("userid"));

    if (client <= 0 || !IsClientInGame(client))
        return;

    if (GetClientTeam(client) != TEAM_SURVIVOR)
        return;

    QueueRecount(0.2);
}

// Rare events that are always relevant to survivors.
// (player_team: team change; defib/rescue: survivor comes back to life;
//  bot replace: bot <-> player takeover.)
public void Event_AlwaysRecount(Event event, const char[] name, bool dontBroadcast)
{
    QueueRecount(0.2);
}

// Debounce: if a recount is already pending, don't create another timer.
// Counting happens when the timer fires, so the pending recount is
// guaranteed to see the latest state.
void QueueRecount(float delay)
{
    if (g_hRecountTimer != null)
        return;

    g_hRecountTimer = CreateTimer(delay, Timer_Recount, _, TIMER_FLAG_NO_MAPCHANGE);
}

public Action Timer_Recount(Handle timer)
{
    // Only the tracked timer may clear the handle. An "orphan" timer from a
    // previous map may still count (harmless), but must not clear the handle
    // that belongs to the current timer.
    if (timer == g_hRecountTimer)
        g_hRecountTimer = null;

    UpdateSurvivorCount();
    return Plugin_Stop;
}

void StartSafetyTimer()
{
    if (g_hSafetyTimer != null)
        return;

    g_hSafetyTimer = CreateTimer(SAFETY_RECOUNT_INTERVAL, Timer_Safety, _,
        TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
}

// Safety net: catches changes that have no event (or events we don't hook).
// Cost is small: one MaxClients loop every 3 seconds.
public Action Timer_Safety(Handle timer)
{
    // Prevent duplicates: if this is not the tracked safety timer (a leftover
    // from a map transition), stop it.
    if (timer != g_hSafetyTimer)
        return Plugin_Stop;

    UpdateSurvivorCount();
    return Plugin_Continue;
}

void UpdateSurvivorCount()
{
    int count = CountLivingSurvivors();

    if (count == g_iLivingSurvivors)
        return;

    g_iLivingSurvivors = count;
    RecalculateMultiplier(false);
}

int CountLivingSurvivors()
{
    int count;

    for (int client = 1; client <= MaxClients; client++)
    {
        if (!IsClientInGame(client))
            continue;

        // Team 2 only. The L4D1 survivors in The Passing are on team 4
        // and are intentionally not counted.
        if (GetClientTeam(client) != TEAM_SURVIVOR)
            continue;

        // Incapacitated survivors are still "alive", so they still count.
        if (!IsPlayerAlive(client))
            continue;

        count++;
    }

    return count;
}

// ===========================================================================
// Multiplier & scaling
// ===========================================================================

float ComputeMultiplier(int survivors)
{
    int extraSurvivors = survivors - BASE_SURVIVORS;

    if (extraSurvivors <= 0)
        return 1.0;

    // The percentage is used as a float, so 12.5 really means 12.5%
    float multiplier = 1.0 + float(extraSurvivors) * g_hPercent.FloatValue / 100.0;

    // Upper bound: without it, 12 survivors x 100% = 9x commons -> edict crash risk.
    float maxMultiplier = g_hMaxMultiplier.FloatValue;
    if (multiplier > maxMultiplier)
        multiplier = maxMultiplier;

    return multiplier;
}

void RecalculateMultiplier(bool forceLog)
{
    float oldMultiplier = g_fMultiplier;
    g_fMultiplier = ComputeMultiplier(g_iLivingSurvivors);

    bool changed = (oldMultiplier != g_fMultiplier);

    // A new multiplier changes every scaled result, so Director logs should
    // print again for each key.
    if (changed)
        ClearDebugLog();

    if (changed || forceLog)
    {
        PrintToServer("[CommonRegulator] Enabled=%d Survivors=%d multiplier=%.2fx",
            g_bEnabled, g_iLivingSurvivors, g_fMultiplier);
    }

    // Enabled state or multiplier may have changed: keep the mob cvars in sync.
    ApplyMobCvars();
}

int ScaleDirectorValue(int original)
{
    // Negative = special/"default" Director value; 0 = the map deliberately
    // disabled it (e.g. no mobs). Neither should be changed.
    if (original <= 0)
        return original;

    int scaled = RoundToNearest(float(original) * g_fMultiplier);

    if (g_iValueCap > 0 && scaled > g_iValueCap)
    {
        // If the map's own value is already above the cap, keep it: this
        // plugin may only INCREASE values, never shrink the map's tuning.
        scaled = (original > g_iValueCap) ? original : g_iValueCap;
    }

    // Note on MobMinSize vs MobMaxSize: this function is monotonic (a larger
    // original never produces a smaller result), so if the map has
    // Min <= Max, the result also keeps Min <= Max. No cross-clamp needed.
    return scaled;
}

// ===========================================================================
// Director hook (left4dhooks)
// ===========================================================================

// Hooks CDirector::GetScriptValue(const char*, int), which is how the Director
// reads its own options (CommonLimit, MobMaxSize, ...) from DirectorOptions,
// falling back to the matching z_* cvar when the map does not set one.
//
// Do NOT use L4D2_OnGetScriptValueInt(key, retVal, hScope) for this: that
// forward fires on the VScript VM value getter (Squirrel code reading a
// value), not on Director option lookups, so it never sees these keys.
//
// Called VERY often by the Director. Checks are ordered cheapest first so the
// common case (4 players / plugin off) exits as fast as possible.
public Action L4D_OnGetScriptValueInt(const char[] key, int &retVal)
{
    // Fast path: a 1.0 multiplier means nothing needs to change.
    // The exact float comparison is safe because 1.0 is assigned directly,
    // not computed.
    if (!g_bEnabled || g_fMultiplier == 1.0)
        return Plugin_Continue;

    int index;
    if (!g_hKeyIndex.GetValue(key, index))
        return Plugin_Continue;

    int original = retVal;
    int scaled = ScaleDirectorValue(original);

    // Double-scale guard: when the map's DirectorOptions does not define
    // MobMinSize/MobMaxSize, the Director may pass the cvar value in as the
    // default. If that equals the value our fallback just wrote, it is
    // already scaled, so leave it alone. (A map script value that happens to
    // equal our written value would also be skipped; that is a rare and
    // harmless miss compared to scaling twice.)
    for (int i = 0; i < MOBCVAR_COUNT; i++)
    {
        if (g_iMobCvarKey[i] == index && g_bMobApplied[i] && original == g_iMobWritten[i])
        {
            scaled = original;
            break;
        }
    }

    g_bSeen[index] = true;
    g_iLastOriginal[index] = original;
    g_iLastScaled[index] = scaled;

    if (scaled == original)
        return Plugin_Continue;

    if (g_bDebug)
        DebugDirectorValue(index, original, scaled);

    retVal = scaled;

    // IMPORTANT: the forward's documentation states the override value is
    // only used when returning Plugin_Handled. v1.1.0 returned Plugin_Changed,
    // which risks being ignored. Plugin_Handled here does NOT block anything;
    // it just means "use the retVal I modified".
    return Plugin_Handled;
}

void DebugDirectorValue(int index, int original, int scaled)
{
    // Only print when the value differs from the last one printed for this
    // key. The Director asks for the same key many times per second, so
    // without this the console would be flooded.
    if (g_bLogged[index]
        && g_iLoggedOriginal[index] == original
        && g_iLoggedScaled[index] == scaled)
    {
        return;
    }

    g_bLogged[index] = true;
    g_iLoggedOriginal[index] = original;
    g_iLoggedScaled[index] = scaled;

    PrintToServer(
        "[CommonRegulator] Director key=%s original=%d -> scaled=%d (multiplier=%.2fx)",
        g_sKeyNames[index], original, scaled, g_fMultiplier);
}

// ===========================================================================
// Admin command
// ===========================================================================

public Action Command_Debug(int client, int args)
{
    int actual = CountLivingSurvivors();

    ReplyToCommand(client, "[CommonRegulator] DEBUG v%s", PLUGIN_VERSION);
    ReplyToCommand(client, "[CommonRegulator] Enabled=%d | LivingSurvivors=%d | CachedSurvivors=%d",
        g_bEnabled, actual, g_iLivingSurvivors);
    ReplyToCommand(client, "[CommonRegulator] Multiplier=%.2fx (percent=%.2f, max=%.2fx) | ValueCap=%d | Debug=%d",
        g_fMultiplier, g_hPercent.FloatValue, g_hMaxMultiplier.FloatValue, g_iValueCap, g_bDebug);

    // This data is only filled while the multiplier is above 1.0, because the
    // hook's fast path returns before recording anything at 1.0.
    for (int i = 0; i < KEY_COUNT; i++)
    {
        if (!g_bSeen[i])
        {
            ReplyToCommand(client, "  %s : (not requested by the Director since multiplier > 1.0)", g_sKeyNames[i]);
            continue;
        }

        ReplyToCommand(client, "  %s : %d -> %d",
            g_sKeyNames[i], g_iLastOriginal[i], g_iLastScaled[i]);
    }

    ReplyToCommand(client, "[CommonRegulator] Mob cvar fallback=%d", g_bScaleMobCvars);
    for (int i = 0; i < MOBCVAR_COUNT; i++)
    {
        if (g_hMobCvar[i] == null)
        {
            ReplyToCommand(client, "  %s : (cvar not found)", g_sMobCvarNames[i]);
            continue;
        }

        ReplyToCommand(client, "  %s : base=%d -> current=%d",
            g_sMobCvarNames[i], g_iMobBase[i], g_hMobCvar[i].IntValue);
    }

    return Plugin_Handled;
}
