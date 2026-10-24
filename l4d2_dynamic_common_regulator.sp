#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <left4dhooks>

#define PLUGIN_VERSION "1.0.0"

public Plugin myinfo =
{
    name = "[L4D2] Common Infected Regulator - Dynamic",
    author = "monnie",
    description = "Scales Director common infected settings from the map's own Director/VScript values based on living survivors.",
    version = PLUGIN_VERSION,
    url = "https://gitlab.com/iqrar99/l4d2-plugins"
};

ConVar g_hEnabled;
ConVar g_hPercent;

int g_iLivingSurvivors;

// Per-map/per-multiplier debug cache. This prevents the Director hook from
// printing the same value every time the Director asks for it.
int g_iLastOriginalCommon = -999999;
int g_iLastOriginalMobSpawn = -999999;
int g_iLastOriginalMegaMob = -999999;
int g_iLastOriginalMobMin = -999999;
int g_iLastOriginalMobMax = -999999;
int g_iLastOriginalMobPending = -999999;
int g_iLastFinalCommon = -999999;
int g_iLastFinalMobSpawn = -999999;
int g_iLastFinalMegaMob = -999999;
int g_iLastFinalMobMin = -999999;
int g_iLastFinalMobMax = -999999;
int g_iLastFinalMobPending = -999999;

public void OnPluginStart()
{
    g_hEnabled = CreateConVar(
        "commonregulator",
        "1",
        "Enable dynamic common infected regulation. 1 = enabled, 0 = disabled.",
        FCVAR_PLUGIN | FCVAR_SPONLY | FCVAR_NOTIFY,
        true, 0.0,
        true, 1.0
    );

    g_hPercent = CreateConVar(
        "commonregulator_percent_per_survivor",
        "20",
        "Percentage increase for each living survivor above 4. 20 = +20% per additional survivor.",
        FCVAR_PLUGIN | FCVAR_SPONLY | FCVAR_NOTIFY,
        true, 0.0,
        true, 100.0
    );

    AutoExecConfig(true, "cge_l4d2_commonregulator");

    HookEvent("player_spawn", Event_PlayerSpawn);
    HookEvent("player_death", Event_PlayerDeath);
    HookEvent("survivor_rescued", Event_SurvivorRescued);
    HookEvent("player_team", Event_PlayerTeam);

    RegConsoleCmd("sm_cge_debug", Command_Debug, "Show CommonRegulator survivor and Director debug state.");

    ResetDebugState();

    // Covers plugin load/reload while a map is already running.
    CreateTimer(1.0, Timer_UpdateSurvivorCount, _, TIMER_FLAG_NO_MAPCHANGE);
}

public void OnMapStart()
{
    ResetDebugState();

    // Wait until the map's Director/VScript has initialized. We intentionally
    // do NOT read or overwrite z_* ConVars here. Those values can be leftovers
    // from our previous map and are not a reliable source of map Director data.
    CreateTimer(1.0, Timer_UpdateSurvivorCount, _, TIMER_FLAG_NO_MAPCHANGE);
}

public void OnConfigsExecuted()
{
    // MultiSlots/CreateSurvivorBot may create survivors after configs execute.
    CreateTimer(1.0, Timer_UpdateSurvivorCount, _, TIMER_FLAG_NO_MAPCHANGE);
}

public void OnClientPutInServer(int client)
{
    // Covers real players and server-created survivor bots.
    CreateTimer(0.5, Timer_UpdateSurvivorCount, _, TIMER_FLAG_NO_MAPCHANGE);
}

public void OnMapEnd()
{
    ResetDebugState();
}

void ResetDebugState()
{
    g_iLivingSurvivors = 0;

    g_iLastOriginalCommon = -999999;
    g_iLastOriginalMobSpawn = -999999;
    g_iLastOriginalMegaMob = -999999;
    g_iLastOriginalMobMin = -999999;
    g_iLastOriginalMobMax = -999999;
    g_iLastOriginalMobPending = -999999;

    g_iLastFinalCommon = -999999;
    g_iLastFinalMobSpawn = -999999;
    g_iLastFinalMegaMob = -999999;
    g_iLastFinalMobMin = -999999;
    g_iLastFinalMobMax = -999999;
    g_iLastFinalMobPending = -999999;
}

public void Event_PlayerSpawn(Event event, const char[] name, bool dontBroadcast)
{
    CreateTimer(0.5, Timer_UpdateSurvivorCount, _, TIMER_FLAG_NO_MAPCHANGE);
}

public void Event_PlayerDeath(Event event, const char[] name, bool dontBroadcast)
{
    CreateTimer(0.2, Timer_UpdateSurvivorCount, _, TIMER_FLAG_NO_MAPCHANGE);
}

public void Event_SurvivorRescued(Event event, const char[] name, bool dontBroadcast)
{
    CreateTimer(0.2, Timer_UpdateSurvivorCount, _, TIMER_FLAG_NO_MAPCHANGE);
}

public void Event_PlayerTeam(Event event, const char[] name, bool dontBroadcast)
{
    CreateTimer(0.2, Timer_UpdateSurvivorCount, _, TIMER_FLAG_NO_MAPCHANGE);
}

public Action Timer_UpdateSurvivorCount(Handle timer)
{
    if (!g_hEnabled.BoolValue)
        return Plugin_Stop;

    int count = CountLivingSurvivors();

    if (count != g_iLivingSurvivors)
    {
        g_iLivingSurvivors = count;

        // Clear the debug cache so the next Director request prints the
        // original and scaled value for the new multiplier.
        ResetValueDebugCache();

        PrintToServer(
            "[CommonRegulator] Survivors=%d multiplier=%.2fx",
            count,
            GetMultiplier()
        );
    }

    return Plugin_Stop;
}

public Action Command_Debug(int client, int args)
{
    if (!g_hEnabled.BoolValue)
    {
        ReplyToCommand(client, "[CommonRegulator] Disabled (commonregulator=0).");
        return Plugin_Handled;
    }

    int actual = CountLivingSurvivors();

    ReplyToCommand(client, "[CommonRegulator] DEBUG");
    ReplyToCommand(client, "[CommonRegulator] Enabled=1 | LivingSurvivors=%d | CachedSurvivors=%d | Multiplier=%.2fx", actual, g_iLivingSurvivors, GetMultiplierForCount(actual));
    ReplyToCommand(client, "[CommonRegulator] PercentPerSurvivor=%.2f", g_hPercent.FloatValue);
    ReplyToCommand(client, "[CommonRegulator] Director hook=active; tracked keys: CommonLimit, MobSpawnSize, MegaMobSize, MobMinSize, MobMaxSize, MobMaxPending");
    ReplyToCommand(client, "[CommonRegulator] Director key logs appear only when L4D2 requests a tracked script value.");

    return Plugin_Handled;
}

float GetMultiplierForCount(int survivors)
{
    int extraSurvivors = survivors - 4;

    if (extraSurvivors <= 0)
        return 1.0;

    // Calculate the percentage using integers first so values such as
    // 20% per survivor are deterministic: 4=100%, 5=120%, 6=140%, etc.
    int percent = RoundToNearest(g_hPercent.FloatValue);
    int totalPercent = 100 + (extraSurvivors * percent);

    return float(totalPercent) / 100.0;
}

int CountLivingSurvivors()
{
    int count;

    for (int client = 1; client <= MaxClients; client++)
    {
        if (!IsClientInGame(client))
            continue;

        if (GetClientTeam(client) != 2)
            continue;

        if (!IsPlayerAlive(client))
            continue;

        count++;
    }

    return count;
}

float GetMultiplier()
{
    return GetMultiplierForCount(g_iLivingSurvivors);
}

int ScaleDirectorValue(int original)
{
    // Director uses negative values for some "unlimited/default" settings.
    // Never turn -1 into -2, etc.
    if (original < 0)
        return original;

    return RoundToNearest(float(original) * GetMultiplier());
}

bool IsTrackedDirectorKey(const char[] key)
{
    return StrEqual(key, "CommonLimit")
        || StrEqual(key, "cm_CommonLimit")
        || StrEqual(key, "MobSpawnSize")
        || StrEqual(key, "MegaMobSize")
        || StrEqual(key, "MobMinSize")
        || StrEqual(key, "MobMaxSize")
        || StrEqual(key, "MobMaxPending");
}

public Action L4D2_OnGetScriptValueInt(const char[] key, int &retVal, int hScope)
{
    if (!g_hEnabled.BoolValue || g_iLivingSurvivors <= 0)
        return Plugin_Continue;

    if (!IsTrackedDirectorKey(key))
        return Plugin_Continue;

    int original = retVal;
    int scaled = ScaleDirectorValue(original);

    // A mob's min size should never exceed its max size. We cannot know the
    // final max here if the Director asks for the values in another order, so
    // leave the individual Director value untouched apart from the multiplier.
    retVal = scaled;

    DebugDirectorValue(key, original, scaled, hScope);

    return Plugin_Changed;
}

void DebugDirectorValue(const char[] key, int original, int scaled, int hScope)
{
    bool changed = false;

    if (StrEqual(key, "CommonLimit") || StrEqual(key, "cm_CommonLimit"))
    {
        changed = (original != g_iLastOriginalCommon || scaled != g_iLastFinalCommon);
        g_iLastOriginalCommon = original;
        g_iLastFinalCommon = scaled;
    }
    else if (StrEqual(key, "MobSpawnSize"))
    {
        changed = (original != g_iLastOriginalMobSpawn || scaled != g_iLastFinalMobSpawn);
        g_iLastOriginalMobSpawn = original;
        g_iLastFinalMobSpawn = scaled;
    }
    else if (StrEqual(key, "MegaMobSize"))
    {
        changed = (original != g_iLastOriginalMegaMob || scaled != g_iLastFinalMegaMob);
        g_iLastOriginalMegaMob = original;
        g_iLastFinalMegaMob = scaled;
    }
    else if (StrEqual(key, "MobMinSize"))
    {
        changed = (original != g_iLastOriginalMobMin || scaled != g_iLastFinalMobMin);
        g_iLastOriginalMobMin = original;
        g_iLastFinalMobMin = scaled;
    }
    else if (StrEqual(key, "MobMaxSize"))
    {
        changed = (original != g_iLastOriginalMobMax || scaled != g_iLastFinalMobMax);
        g_iLastOriginalMobMax = original;
        g_iLastFinalMobMax = scaled;
    }
    else if (StrEqual(key, "MobMaxPending"))
    {
        changed = (original != g_iLastOriginalMobPending || scaled != g_iLastFinalMobPending);
        g_iLastOriginalMobPending = original;
        g_iLastFinalMobPending = scaled;
    }

    if (!changed)
        return;

    PrintToServer(
        "[CommonRegulator] Director key=%s original=%d -> scaled=%d (scope=%d, multiplier=%.2fx)",
        key,
        original,
        scaled,
        hScope,
        GetMultiplier()
    );
}

void ResetValueDebugCache()
{
    g_iLastOriginalCommon = -999999;
    g_iLastOriginalMobSpawn = -999999;
    g_iLastOriginalMegaMob = -999999;
    g_iLastOriginalMobMin = -999999;
    g_iLastOriginalMobMax = -999999;
    g_iLastOriginalMobPending = -999999;

    g_iLastFinalCommon = -999999;
    g_iLastFinalMobSpawn = -999999;
    g_iLastFinalMegaMob = -999999;
    g_iLastFinalMobMin = -999999;
    g_iLastFinalMobMax = -999999;
    g_iLastFinalMobPending = -999999;
}
