//TODO: rewrite all of this to not be bad lol

#include <sourcemod>
#include <sdktools>
#include <cstrike>
#include <ripext>
#include <sqlmatches>

#pragma semicolon 1
#pragma newdecls required

#define PREFIX		"[SM]"
#define TEAM_CT 	0
#define TEAM_T 		1

bool g_bPugSetupAvailable;
bool g_bGet5Available;
bool g_bAlreadySwapped;

char g_sApiUrl[512];
char g_sApiKey[64];
char g_sMatchId[128];

ConVar g_cvApiUrl;
ConVar g_cvApiKey;

HTTPClient g_Client;

enum struct MatchUpdatePlayer
{
	int Index;
	char Username[42];
	char SteamID[64];
	int Team;
	bool Alive;
	int Ping;
	int Kills;
	int Headshots;
	int Assists;
	int Deaths;
	int ShotsFired;
	int ShotsHit;
	int MVPs;
	int Score;
	bool Disconnected;
}

MatchUpdatePlayer g_PlayerStats[MAXPLAYERS + 1];

public Plugin myinfo = 
{
	name = "SQLMatches",
	author = "The Doggy",
	description = "Match stats and demo recording system for CS:GO",
	version = "1.0.0",
	url = ""
};

public void OnAllPluginsLoaded()
{
	g_bPugSetupAvailable = LibraryExists("pugsetup");
	g_bGet5Available = LibraryExists("get5");
}

public void OnLibraryAdded(const char[] name)
{
	if(StrEqual(name, "pugsetup")) g_bPugSetupAvailable = true;
	if(StrEqual(name, "get5")) g_bGet5Available = true;
}

public void OnLibraryRemoved(const char[] name)
{
	if(StrEqual(name, "pugsetup")) g_bPugSetupAvailable = false;
	if(StrEqual(name, "get5")) g_bGet5Available = false;
}

public void OnPluginStart()
{
	//Hook Events
	HookEvent("round_end", Event_RoundEnd);
	HookEvent("weapon_fire", Event_WeaponFired);
	HookEvent("player_hurt", Event_PlayerHurt);
	HookEvent("announce_phase_end", Event_HalfTime);
	HookEvent("player_disconnect", Event_PlayerDisconnect, EventHookMode_Pre);
	HookEvent("cs_win_panel_match", Event_MatchEnd);

	// Register ConVars
	g_cvApiKey = CreateConVar("sm_sqlmatches_key", "<API KEY>", "API key for sqlmatches API", FCVAR_PROTECTED);
	g_cvApiKey.AddChangeHook(OnAPIChanged);
	g_cvApiUrl = CreateConVar("sm_sqlmatches_url", "https://sqlmatches.com/api/", "URL of sqlmatches base API route", FCVAR_PROTECTED);
	g_cvApiUrl.AddChangeHook(OnAPIChanged);

	g_cvApiKey.GetString(g_sApiKey, sizeof(g_sApiKey));
	g_cvApiUrl.GetString(g_sApiUrl, sizeof(g_sApiUrl));

	AutoExecConfig(true, "sqlmatches");

	// Create HTTP Client
	g_Client = new HTTPClient(g_sApiUrl);

	// Register commands
	RegConsoleCmd("sm_creatematch", Command_CreateMatch, "Creates a match");
	RegConsoleCmd("sm_endmatch", Command_EndMatch, "Ends a match");
}

public void OnAPIChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
	g_cvApiUrl.GetString(g_sApiUrl, sizeof(g_sApiUrl));
	g_cvApiKey.GetString(g_sApiKey, sizeof(g_sApiKey));

	// Add backslash to url if needed
	int len = strlen(g_sApiUrl);
	if(len > 0 && g_sApiUrl[len - 1] != '/')
		StrCat(g_sApiUrl, sizeof(g_sApiUrl), "/");

	// Recreate HTTP client with new url
	delete g_Client;
	g_Client = new HTTPClient(g_sApiUrl);
}

public void OnConfigsExecuted()
{
	g_cvApiKey.GetString(g_sApiKey, sizeof(g_sApiKey));
	g_cvApiUrl.GetString(g_sApiUrl, sizeof(g_sApiUrl));

	// Recreate HTTP Client with new url
	delete g_Client;
	g_Client = new HTTPClient(g_sApiUrl);
}

public void OnClientPutInServer(int Client)
{
	ResetVars(Client);
	g_PlayerStats[Client].Index = Client;
}

void ResetVars(int Client)
{
	g_PlayerStats[Client].Index = 0;
	g_PlayerStats[Client].Username = "";
	g_PlayerStats[Client].SteamID = "";
	g_PlayerStats[Client].Team = 0;
	g_PlayerStats[Client].Alive = false;
	g_PlayerStats[Client].Ping = 0;
	g_PlayerStats[Client].Kills = 0;
	g_PlayerStats[Client].Headshots = 0;
	g_PlayerStats[Client].Assists = 0;
	g_PlayerStats[Client].Deaths = 0;
	g_PlayerStats[Client].ShotsFired = 0;
	g_PlayerStats[Client].ShotsHit = 0;
	g_PlayerStats[Client].MVPs = 0;
	g_PlayerStats[Client].Score = 0;
	g_PlayerStats[Client].Disconnected = false;
}

public Action Command_CreateMatch(int client, int args)
{
	CreateMatch();
}

public Action Command_EndMatch(int client, int args)
{
	EndMatch();
}

void CreateMatch()
{
	if(strlen(g_sApiUrl) == 0)
	{
		LogError("Failed to create match. Error: ConVar sm_sqlmatches_url cannot be empty.");
		return;
	}

	if(strlen(g_sApiKey) == 0)
	{
		LogError("Failed to create match. Error: ConVar sm_sqlmatches_key cannot be empty.");
		return;
	}

	// Format request
	char sUrl[1024];
	Format(sUrl, sizeof(sUrl), "%smatch/create?%s", g_sApiUrl, g_sApiKey);

	// Setup JSON data
	char sTeamNameCT[128];
	char sTeamNameT[128];
	char sMap[128];
	JSONObject json = new JSONObject();

	// Set names if pugsetup or get5 are available
	if(g_bGet5Available || g_bPugSetupAvailable)
	{
		FindConVar("mp_teamname_1").GetString(sTeamNameCT, sizeof(sTeamNameCT));
		FindConVar("mp_teamname_2").GetString(sTeamNameT, sizeof(sTeamNameT));
	}
	else // Otherwise just use garbage values
	{
		sTeamNameCT = "1";
		sTeamNameT = "2";
	}

	json.SetString("team_1_name", sTeamNameCT);
	json.SetString("team_2_name", sTeamNameT);

	// Set team sides
	json.SetInt("team_1_side", 0);
	json.SetInt("team_2_side", 1);

	// Set team score
	json.SetInt("team_1_score", 0);
	json.SetInt("team_2_score", 0);

	// Set map
	GetCurrentMap(sMap, sizeof(sMap));
	json.SetString("map_name", sMap);

	// Send request
	g_Client.Post(sUrl, json, HTTP_OnCreateMatch);

	// Delete handle
	delete json;
}

void HTTP_OnCreateMatch(HTTPResponse response, any value, const char[] error)
{
	if(strlen(error) > 0)
	{
		LogError("HTTP_OnCreateMatch Failed! Error: %s", error);
		return;
	}

	// Get response data
	JSONObject responseData = view_as<JSONObject>(response.Data);

	// Log errors if any occurred
	if(!responseData.IsNull("error"))
	{
		// Error string
		char errorInfo[1024];

		// Format errors into a single readable string
		FormatAPIError(responseData, errorInfo, sizeof(errorInfo));

		LogError("HTTP_OnCreateMatch Failed! Error: %s", errorInfo);
		return;
	}

	// Match waas created successfully, store match id and restart game
	JSONObject data = view_as<JSONObject>(responseData.Get("data"));
	data.GetString("match_id", g_sMatchId, sizeof(g_sMatchId));
	PrintToServer("Match %s created successfully.", g_sMatchId);
	PrintToChatAll("Match has been created, restarting game...");
	ServerCommand("tv_record \"%s\"", g_sMatchId);
	RestartGame(5);

	// Delete json handle
	delete responseData;
	delete data;
}

void EndMatch()
{
	if(strlen(g_sApiUrl) == 0)
	{
		LogError("Failed to end match. Error: ConVar sm_sqlmatches_url cannot be empty.");
		return;
	}

	if(strlen(g_sApiKey) == 0)
	{
		LogError("Failed to end match. Error: ConVar sm_sqlmatches_key cannot be empty.");
		return;
	}

	// Format request
	char sUrl[1024];
	Format(sUrl, sizeof(sUrl), "%smatch/%s?%s", g_sApiUrl, g_sMatchId, g_sApiKey);

	// Send request
	g_Client.Delete(sUrl, HTTP_OnEndMatch);
}

void HTTP_OnEndMatch(HTTPResponse response, any value, const char[] error)
{
	if(strlen(error) > 0)
	{
		LogError("HTTP_OnEndMatch Failed! Error: %s", error);
		return;
	}

	// Get response data
	JSONObject responseData = view_as<JSONObject>(response.Data);

	// Log errors if any occurred
	if(!responseData.IsNull("error"))
	{
		// Error string
		char errorInfo[1024];

		// Format errors into a single readable string
		FormatAPIError(responseData, errorInfo, sizeof(errorInfo));

		LogError("HTTP_OnEndMatch Failed! Error: %s", errorInfo);
		return;
	}

	// End match
	PrintToServer("Match ended successfully.");
	PrintToChatAll("Match has ended, stats will no longer be recorded.");
	UploadDemo(g_sMatchId, sizeof(g_sMatchId));
	g_sMatchId = "";

	// Delete json handle
	delete responseData;
}

void UpdateMatch(int team_1_score = -1, int team_2_score = -1, const MatchUpdatePlayer[] players, int size = -1, bool dontUpdate = false, int team_1_side = -1, int team_2_side = -1, bool end = false)
{
	if(!InMatch() && end == false) return;

	if(strlen(g_sApiUrl) == 0)
	{
		LogError("Failed to update match. Error: ConVar sm_sqlmatches_url cannot be empty.");
		return;
	}

	if(strlen(g_sApiKey) == 0)
	{
		LogError("Failed to update match. Error: ConVar sm_sqlmatches_key cannot be empty.");
		return;
	}

	// Set scores if not passed in manually
	if(team_1_score == -1)
		team_1_score = CS_GetTeamScore(CS_TEAM_CT);
	if(team_2_score == -1)
		team_2_score = CS_GetTeamScore(CS_TEAM_T);

	// Create and set json data
	JSONObject json = new JSONObject();
	json.SetInt("team_1_score", team_1_score);
	json.SetInt("team_2_score", team_2_score);

	// Format and set players data
	if(!dontUpdate)
	{
		JSONArray playerData = GetPlayersJson(players, size);
		json.Set("players", playerData);
	}

	// Set optional data
	if(team_1_side != -1)
		json.SetInt("team_1_side", team_1_side);
	if(team_2_side != -1)
		json.SetInt("team_2_side", team_2_side);
	if(end)
		json.SetBool("end", end);

	// Format request
	char sUrl[1024];
	Format(sUrl, sizeof(sUrl), "%smatch/%s?%s", g_sApiUrl, g_sMatchId, g_sApiKey);

	// Send request
	g_Client.Post(sUrl, json, HTTP_OnUpdateMatch);
	delete json;
}

void HTTP_OnUpdateMatch(HTTPResponse response, any value, const char[] error)
{
	if(strlen(error) > 0)
	{
		LogError("HTTP_OnUpdateMatch Failed! Error: %s", error);
		return;
	}

	// Get response data
	JSONObject responseData = view_as<JSONObject>(response.Data);

	// Log errors if any occurred
	if(!responseData.IsNull("error"))
	{
		// Error string
		char errorInfo[1024];

		// Format errors into a single readable string
		FormatAPIError(responseData, errorInfo, sizeof(errorInfo));

		LogError("HTTP_OnUpdateMatch Failed! Error: %s", errorInfo);
		return;
	}

	PrintToServer("Match updated successfully.");

	// Delete json handle
	delete responseData;
}

void UploadDemo(char[] demoName, int size)
{
	if(strlen(g_sApiUrl) == 0)
	{
		LogError("Failed to upload demo. Error: ConVar sm_sqlmatches_url cannot be empty.");
		return;
	}

	if(strlen(g_sApiKey) == 0)
	{
		LogError("Failed to upload demo. Error: ConVar sm_sqlmatches_key cannot be empty.");
		return;
	}

	StrCat(demoName, size, ".dem");
	if(!FileExists(demoName))
	{
		LogError("Failed to upload demo. Error: File \"%s\" does not exist.", demoName);
		return;
	}

	// Format request
	char sUrl[1024];
	Format(sUrl, sizeof(sUrl), "%smatch/%s/upload?%s", g_sApiUrl, g_sMatchId, g_sApiKey);

	// Send request
	g_Client.UploadFile(sUrl, demoName, HTTP_OnUploadDemo);

	PrintToServer("Uploading demo...");
}

void HTTP_OnUploadDemo(HTTPStatus status, DataPack pack, const char[] error)
{
	if(strlen(error) > 0 || status != HTTPStatus_OK)
	{
		LogError("HTTP_OnUploadDemo Failed! Error: %s", error);
		return;
	}

	PrintToServer("Demo uploaded successfully.");
}

public void Event_RoundEnd(Event event, const char[] name, bool dontBroadcast)
{
	UpdatePlayerStats(g_PlayerStats, sizeof(g_PlayerStats));
	UpdateMatch(.players = g_PlayerStats, .size = sizeof(g_PlayerStats));
}

public void Event_WeaponFired(Event event, const char[] name, bool dontBroadcast)
{
	int Client = GetClientOfUserId(event.GetInt("userid"));
	if(!InMatch() || !IsValidClient(Client)) return;

	int iWeapon = GetEntPropEnt(Client, Prop_Send, "m_hActiveWeapon");
	if(!IsValidEntity(iWeapon)) return;

	if(GetEntProp(iWeapon, Prop_Send, "m_iPrimaryAmmoType") != -1 && GetEntProp(iWeapon, Prop_Send, "m_iClip1") != 255) g_PlayerStats[Client].ShotsFired++; //should filter knife and grenades
}

public void Event_PlayerHurt(Event event, const char[] name, bool dontBroadcast)
{
	int Client = GetClientOfUserId(event.GetInt("attacker"));
	if(!InMatch() || !IsValidClient(Client)) return;

	if(event.GetInt("hitgroup") >= 0)
	{
		g_PlayerStats[Client].ShotsHit++;
		if(event.GetInt("hitgroup") == 1) g_PlayerStats[Client].Headshots++;
	}
}

/* This has changed  */
public void Event_HalfTime(Event event, const char[] name, bool dontBroadcast)
{
    if (!g_bAlreadySwapped)
    {
    	LogMessage("Event_HalfTime(): Starting team swap...");

    	UpdateMatch(.team_1_side = 1, .team_2_side = 0, .players = g_PlayerStats, .dontUpdate = true);

        g_bAlreadySwapped = true;
    }
    else
    	LogError("Event_HalfTime(): Teams have already been swapped!");
}

public Action Event_PlayerDisconnect(Event event, const char[] name, bool dontBroadcast)
{
	// If the client isn't valid or isn't currently in a match return
	int Client = GetClientOfUserId(event.GetInt("userid"));
	if(!IsValidClient(Client)) return Plugin_Handled;

	// If the client's steamid isn't valid return
	char sSteamID[64];
	event.GetString("networkid", sSteamID, sizeof(sSteamID));
	if(sSteamID[7] != ':') return Plugin_Handled;
	if(!GetClientAuthId(Client, AuthId_SteamID64, sSteamID, sizeof(sSteamID))) return Plugin_Handled;

	UpdatePlayerStats(g_PlayerStats, sizeof(g_PlayerStats));
	UpdateMatch(.players = g_PlayerStats, .size = sizeof(g_PlayerStats));

	// Reset client vars
	ResetVars(Client);
	
	return Plugin_Continue;
}

public Action Event_MatchEnd(Event event, const char[] name, bool dontBroadcast)
{
	EndMatch();
}

stock void RestartGame(int delay)
{
	ServerCommand("mp_restartgame %d", delay);
}

stock bool InWarmup()
{
  return GameRules_GetProp("m_bWarmupPeriod") != 0;
}

stock void FormatAPIError(JSONObject responseData, char[] buffer, int size)
{
	JSONObject errorData = view_as<JSONObject>(responseData.Get("error")); // Object that contains the errors
	char key[32]; // The key that the error message references
	char value[128]; // The error message

	// Iterate over json object/array to get all the errors that occurred
	JSONObjectKeys keys = errorData.Keys();
	while(keys.ReadKey(key, sizeof(key)))
	{
		JSONArray currentError = view_as<JSONArray>(errorData.Get(key));
		for(int i = 0; i < currentError.Length; i++)
		{
			currentError.GetString(i, value, sizeof(value));
			Format(buffer, size, "%s %s: %s", buffer, key, value);
		}
		delete currentError;
	}

	delete keys;
	delete errorData;
	delete responseData;
}

stock bool InMatch()
{
	return !StrEqual(g_sMatchId, "") && !InWarmup();
}

stock void UpdatePlayerStats(MatchUpdatePlayer[] players, int size)
{
	int ent = FindEntityByClassname(-1, "cs_player_manager");

	// Iterate over players array and update values for every client
	for(int i = 0; i < size; i++)
	{
		int Client = players[i].Index;
		if(!IsValidClient(Client)) continue;

		players[Client].Team = GetEntProp(ent, Prop_Send, "m_iTeam", _, Client);
		players[Client].Alive = view_as<bool>(GetEntProp(ent, Prop_Send, "m_bAlive", _, Client));
		players[Client].Ping = GetEntProp(ent, Prop_Send, "m_iPing", _, Client);
		players[Client].Kills = GetEntProp(ent, Prop_Send, "m_iKills", _, Client);
		players[Client].Assists = GetEntProp(ent, Prop_Send, "m_iAssists", _, Client);
		players[Client].Deaths = GetEntProp(ent, Prop_Send, "m_iDeaths", _, Client);
		players[Client].MVPs = GetEntProp(ent, Prop_Send, "m_iMVPs", _, Client);
		players[Client].Score = GetEntProp(ent, Prop_Send, "m_iScore", _, Client);

		GetClientName(Client, players[Client].Username, sizeof(MatchUpdatePlayer::Username));
		GetClientAuthId(Client, AuthId_SteamID64, players[Client].SteamID, sizeof(MatchUpdatePlayer::SteamID));
	}
}

stock JSONArray GetPlayersJson(const MatchUpdatePlayer[] players, int size)
{
	JSONArray json = new JSONArray();

	for(int i = 0; i < size; i++)
	{
		JSONObject player = new JSONObject();
		if(!IsValidClient(players[i].Index)) continue;

		player.SetString("name", players[i].Username);
		player.SetString("steam_id", players[i].SteamID);
		player.SetInt("team", players[i].Team);
		player.SetBool("alive", players[i].Alive);
		player.SetInt("ping", players[i].Ping);
		player.SetInt("kills", players[i].Kills);
		player.SetInt("headshots", players[i].Headshots);
		player.SetInt("assists", players[i].Assists);
		player.SetInt("deaths", players[i].Deaths);
		player.SetInt("shots_fired", players[i].ShotsFired);
		player.SetInt("shots_hit", players[i].ShotsHit);
		player.SetInt("mvps", players[i].MVPs);
		player.SetInt("score", players[i].Score);
		player.SetBool("disconnected", IsClientInGame(players[i].Index));

		json.Push(player);
	}

	return json;
}

stock bool IsValidClient(int client)
{
	if (client >= 1 && 
	client <= MaxClients && 
	IsClientConnected(client) && 
	IsClientInGame(client) &&
	!IsFakeClient(client) &&
	(GetClientTeam(client) == CS_TEAM_CT || GetClientTeam(client) == CS_TEAM_T))
		return true;
	return false;
}