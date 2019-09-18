/* Headers */
#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <cstrike>

/* Preprocessor directives */
#pragma semicolon 1 // Enforce the usage of semicolons
#pragma newdecls required // Enforce the new syntax

#define PLUGIN_VERSION "1.0.2" // Using semantic versioning: https://semver.org/
#define MAX_LEVELS 2 // Main, bonus. Be careful with that.
#define MAX_STYLES 6 // N, SW, HSW, etc. Styles should match the KV file at {STYLES_CFG}
#define MAX_GHOSTS 2 // 1 which previews normal WR and 1 which allows players to replay a specific style.
#define NORMAL_GHOST 0 // The index of the standard replay ghost which previews normal WR
#define CUSTOM_GHOST 1 // The index of the +use / !replay custom replay ghost
#define BACKUP_REPLAYS // Uncomment to keep a backup of the last WRs
#define TEAM_GHOST "CT" // Replay bots team. "any", "T" or "CT"
#define STYLES_CFG "configs/timer/bots.cfg" // Path to the styles KV cfg file
#define REPLAYS_PATH "data/ghostrecords" // Path to where replays are stored
#define CORRECT_POSITION_DIST 100.0 // Teleport using position if replay goes out of sync.
#define MAX_WEAPONS 48 // Max weapon slots that the m_hMyWeapons array holds
#define PLAYBACK_DELAY 3.0 // Delay before the playback begins
#define MAX_ALLOWED_NAME 12 // Max chars allowed of a name
#define MAX_STYLETAG_LEN 16 // Max number of characters a style tag can hold
#define MAX_LEVELNAME_LEN 16 // Max number of characters a level name can hold
#define MEME "(⌐■_■)" // Custom ghost's clantag when inactive
#define SPECMODE_FIRSTPERSON 4 // Observer mode constant indicating firstperson
#define SPECMODE_3RDPERSON 5 // Observer mode constant indicating thirdperson
#define PLAYBACK_RENDER RENDERFX_NONE // RENDERFX_NONE or RENDERFX_HOLOGRAM is a good choice

/* Global variables */
enum
{
	RUNDATA_POSITION_X, 
	RUNDATA_POSITION_Y, 
	RUNDATA_POSITION_Z, 
	RUNDATA_PITCH, 
	RUNDATA_YAW, 
	RUNDATA_BUTTONS, 
	RUNDATA_IMPULSE, 
	RUNDATA_WEAPONID, 
	RUNDATA_MAX
}

// Replays
ArrayList g_arrayReplay[MAX_LEVELS][MAX_STYLES]; //Replays
float g_fReplayTimes[MAX_LEVELS][MAX_STYLES]; //Time of the replays
int g_iReplayJumps[MAX_LEVELS][MAX_STYLES]; //Number of jumps of the replays
char g_sReplayNames[MAX_LEVELS][MAX_STYLES][MAX_NAME_LENGTH]; //Names of the players on the replays
bool g_bNoRecord[MAX_LEVELS][MAX_STYLES]; //Does it have a record?

// Ghosts
int g_iGhost[MAX_GHOSTS]; //Indexes of the two ghosts, (0 = invalid ghost)
int g_iGhostFrame[MAX_GHOSTS]; //What frame is it going, (-1 = ghost is not in motion)
char g_sGhostName[MAX_GHOSTS][MAX_NAME_LENGTH];
char g_sGhostClanTag[MAX_GHOSTS][MAX_NAME_LENGTH];
int g_iGhostLevel[MAX_GHOSTS]; //What level the ghost is replaying
int g_iGhostStyle[MAX_GHOSTS]; //What style the ghost is replaying
int g_iNumBotsConnected = 0; //Keeps track of the number of connected bots
float g_fGhostLastAngles[MAX_GHOSTS][3];
float g_fGhostTime[MAX_GHOSTS];
float g_fLastUsed; // Time since the custom ghost has been last used by a player
float g_fSpawnPoint[3];

// Humans
ArrayList g_arrayRun[MAXPLAYERS + 1]; //Current runs
bool g_bPaused[MAXPLAYERS + 1]; //Is player active?

// Others
char g_sMapName[64]; //Current map name
int g_iGhostStylesCount = 0; //Number of styles found in the KV file
char g_sStyleNames[MAX_STYLES][MAX_NAME_LENGTH]; //Style names
char g_sStyleTags[MAX_STYLES][MAX_STYLETAG_LEN]; //Style tags
char g_sLevelNames[MAX_LEVELS][MAX_LEVELNAME_LEN] =  { "main", "bonus" };
float g_fTickrate; // Used to cache the tickrate of the server

// Offsets (netprops)
int m_vecOrigin; // CBaseEntity::m_vecOrigin
int m_hActiveWeapon; // CBaseCombatCharacter::m_hActiveWeapon
int m_hObserverTarget; // CCSPlayer::m_hObserverTarget
int m_iObserverMode; // CCSPlayer::m_iObserverMode
int m_hMyWeapons; // CBaseCombatCharacter::m_hMyWeapons
int m_vecVelocity; // CBaseEntity::m_vecVelocity

/**
 * Plugin public information.
 */
public Plugin myinfo = 
{
	name = "[Timer] Replay Bots", 
	author = "Pan32, ici", 
	description = "Shows a bot that replays the top times", 
	version = PLUGIN_VERSION, 
	url = ""
};

/**
 * Called when the plugin is fully initialized and all known external references 
 * are resolved. This is only called once in the lifetime of the plugin, and is 
 * paired with OnPluginEnd().
 *
 * If any run-time error is thrown during this callback, the plugin will be marked 
 * as failed.
 */
public void OnPluginStart()
{
	GetOffsets();
	g_iGhostStylesCount = LoadStyles();
	CheckDirectories( g_iGhostStylesCount );
	g_fTickrate = 1.0 / GetTickInterval();
	
	// Handle timer communication
	RegServerCmd("sm_startrecord", SM_StartRecord);
	RegServerCmd("sm_endrecord", SM_EndRecord);
	RegServerCmd("sm_timerpause", SM_TimerPause);
	RegServerCmd("sm_timerunpause", SM_TimerResume);
	
	HookEvent("player_spawn", Event_PlayerSpawn_Post, EventHookMode_Post);
	HookEvent("player_death", Event_PlayerDeath_Post, EventHookMode_Post);
	
	HookUserMessage(GetUserMessageId("SayText2"), SayText2, true);
	
	RegConsoleCmd("sm_replay", SM_Replay, "Choose a WR on the map to replay.");
	RegAdminCmd("sm_reloadreplays", SM_ReloadReplays, ADMFLAG_GENERIC, "Reloads replays");
	RegAdminCmd("sm_unloadreplays", SM_UnloadReplays, ADMFLAG_GENERIC, "Unloads replays");
	
	// Late plugin load
	for (int i = 1; i <= MaxClients; ++i)
	{
		if (IsClientInGame(i))
		{
			OnClientConnected(i);
			OnClientPutInServer(i);
		}
	}

	CreateTimer(0.1, Timer_HudLoop, 0, TIMER_REPEAT);											   									  
}

/**
 * Retrieves and caches offsets for future use.
 */
void GetOffsets()
{
	m_vecOrigin = FindSendPropInfo("CBaseEntity", "m_vecOrigin");
	
	if (m_vecOrigin == -1)
	{
		SetFailState("Couldn't find CBaseEntity::m_vecOrigin");
	}
	if (m_vecOrigin == 0)
	{
		SetFailState("No offset available for CBaseEntity::m_vecOrigin");
	}
	
	m_hActiveWeapon = FindSendPropInfo("CBaseCombatCharacter", "m_hActiveWeapon");
	
	if (m_hActiveWeapon == -1)
	{
		SetFailState("Couldn't find CBaseCombatCharacter::m_hActiveWeapon");
	}
	if (m_hActiveWeapon == 0)
	{
		SetFailState("No offset available for CBaseCombatCharacter::m_hActiveWeapon");
	}
	
	m_hObserverTarget = FindSendPropInfo("CCSPlayer", "m_hObserverTarget");
	
	if (m_hObserverTarget == -1)
	{
		SetFailState("Couldn't find CCSPlayer::m_hObserverTarget");
	}
	if (m_hObserverTarget == 0)
	{
		SetFailState("No offset available for CCSPlayer::m_hObserverTarget");
	}

	m_iObserverMode = FindSendPropInfo("CCSPlayer", "m_iObserverMode");
	
	if (m_iObserverMode == -1)
	{
		SetFailState("Couldn't find CCSPlayer::m_iObserverMode");
	}
	if (m_iObserverMode == 0)
	{
		SetFailState("No offset available for CCSPlayer::m_iObserverMode");
	}

	m_hMyWeapons = FindSendPropInfo("CBaseCombatCharacter", "m_hMyWeapons");
	
	if (m_hMyWeapons == -1)
	{
		SetFailState("Couldn't find CBaseCombatCharacter::m_hMyWeapons");
	}
	if (m_hMyWeapons == 0)
	{
		SetFailState("No offset available for CBaseCombatCharacter::m_hMyWeapons");
	}
	
	m_vecVelocity = FindSendPropInfo("CBasePlayer", "m_vecVelocity[0]");
	
	if (m_vecVelocity == -1)
	{
		SetFailState("Couldn't find CBasePlayer::m_vecVelocity[0]");
	}
	if (m_vecVelocity == 0)
	{
		SetFailState("No offset available for CBasePlayer::m_vecVelocity[0]");
	}
}

public Action SayText2(UserMsg msg_id, BfRead msg, const int[] players, int playersNum, bool reliable, bool init)
{
	if (!reliable)
	{
		return Plugin_Continue;
	}

	char buffer[25];

	if (GetUserMessageType() == UM_BitBuf)
	{
		msg.ReadChar();
		msg.ReadChar();
		msg.ReadString(buffer, sizeof(buffer));

		if (StrEqual(buffer, "#Cstrike_Name_Change"))
		{
			return Plugin_Handled;
		}
	}
	return Plugin_Continue;
}

/**
 * Caches style names stored at configs/timer/bots.cfg
 * 
 * @return int 	The number of styles found
 */
int LoadStyles()
{
	// Create the path to the KV file
	char path[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, path, sizeof(path), STYLES_CFG);
	
	if (!FileExists(path))
	{
		SetFailState("ERROR: KV configuration file \"%s\" does not exist, unloading", path);
	}
	
	KeyValues kv = new KeyValues("styles");
	if (!kv.ImportFromFile(path))
	{
		SetFailState("ERROR: Couldn't import keyvalues from file");
	}
	
	// Iry to get the first style
	if (!kv.GotoFirstSubKey(true))
	{
		SetFailState("ERROR: KV configuration file \"%s\" is empty or with formating errors, unloading", path);
	}
	
	int numStyles = 0;
	do
	{
		if (numStyles == MAX_STYLES)
		{
			SetFailState("The plugin supports only up to %d styles.", MAX_STYLES);
		}
		
		//Get Style name and tag
		kv.GetString("name", g_sStyleNames[numStyles], MAX_NAME_LENGTH);
		kv.GetString("tag", g_sStyleTags[numStyles], MAX_STYLETAG_LEN);
		
		++numStyles;
		
	} while (kv.GotoNextKey(true));
	
	delete kv;
	return numStyles;
}

/*
 * Checks if directories exist and creates them if they don't.
 * 
 * @param int numStyles		The number of styles to create subfolders for.
 * @noreturn
 */
void CheckDirectories(int numStyles)
{
	char path[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, path, sizeof(path), REPLAYS_PATH);
	
	if (!DirExists(path))
		CreateDirectory(path, 711);
	
	for (int i = 0; i < MAX_LEVELS; ++i)
	{
		BuildPath(Path_SM, path, sizeof(path), "%s/%s", REPLAYS_PATH, g_sLevelNames[i]);
		if (!DirExists(path))
			CreateDirectory(path, 711);
		
		for (int s = 0; s < numStyles; ++s)
		{
			BuildPath(Path_SM, path, sizeof(path), "%s/%s/%d", REPLAYS_PATH, g_sLevelNames[i], s);
			if (!DirExists(path))
				CreateDirectory(path, 711);
		}
	}
}

/**
 * Adjusts convars so that bots work properly
 * 
 * @noreturn
 */
void SetConVars()
{
	ConVar cvar = FindConVar("bot_stop");
	cvar.SetBool(true);
	
	cvar = FindConVar("bot_quota");
	cvar.SetInt(MAX_GHOSTS);
	
	cvar = FindConVar("bot_quota_mode");
	cvar.SetString("normal");
	
	cvar = FindConVar("mp_autoteambalance");
	cvar.SetBool(false);
	
	cvar = FindConVar("mp_limitteams");
	cvar.SetInt(0);
	
	cvar = FindConVar("bot_join_after_player");
	cvar.SetBool(false);
	
	cvar = FindConVar("bot_chatter");
	cvar.SetString("off");

  	cvar = FindConVar("bot_join_team");
	cvar.SetString(TEAM_GHOST);
	
	cvar = FindConVar("bot_auto_vacate");
	cvar.SetBool(false);
	
	cvar = FindConVar("bot_mimic");
	cvar.SetInt(0);
	
	cvar = FindConVar("bot_zombie");
	cvar.Flags = FCVAR_GAMEDLL | FCVAR_REPLICATED;
	cvar.SetBool(true);
	
	// Fixes a crash if you spam +use to spec the custom ghost
	cvar = FindConVar("sv_disablefreezecam");
	cvar.SetBool(true);
}

/**
 * Called when the map is loaded.
 *
 * @note This used to be OnServerLoad(), which is now deprecated.
 * Plugins still using the old forward will work.
 */
public void OnMapStart()
{
	g_fLastUsed = GetGameTime();
	GetCurrentMap(g_sMapName, sizeof(g_sMapName));
	CreateTimer(0.1, Timer_HudLoop, 0, TIMER_REPEAT|TIMER_FLAG_NO_MAPCHANGE);
}

/**
 * Called when the map has loaded, servercfgfile (server.cfg) has been 
 * executed, and all plugin configs are done executing.  This is the best
 * place to initialize plugin functions which are based on cvar data.  
 *
 * @note This will always be called once and only once per map.  It will be 
 * called after OnMapStart().
 */
public void OnConfigsExecuted()
{
	SetConVars();
	UnloadReplays();
	CacheReplays();
	CreateGhosts();
}

/**
 * Called right before a map ends.
 */
public void OnMapEnd()
{
	RemoveGhosts();
}

/**
 * Called when the plugin is about to be unloaded.
 *
 * It is not necessary to close any handles or remove hooks in this function.  
 * SourceMod guarantees that plugin shutdown automatically and correctly releases 
 * all resources.
 */
public void OnPluginEnd()
{
	RemoveGhosts();
}

/**
 * Called when a client is entering the game.
 *
 * Whether a client has a steamid is undefined until OnClientAuthorized
 * is called, which may occur either before or after OnClientPutInServer.
 * Similarly, use OnClientPostAdminCheck() if you need to verify whether 
 * connecting players are admins.
 *
 * GetClientCount() will include clients as they are passed through this 
 * function, as clients are already in game at this point.
 *
 * @param client		Client index.
 */
public void OnClientPutInServer(int client)
{
	if (IsFakeClient(client))
	{
		if (g_iNumBotsConnected == MAX_GHOSTS)
		{
			OnGhostsPutInServer( g_iNumBotsConnected );
		}
	}
	else // Human
	{
		if (g_arrayRun[client] != null)
		{
			delete g_arrayRun[client];
		}
		g_arrayRun[client] = new ArrayList( RUNDATA_MAX );
		
		g_bPaused[client] = true; // avoids unnecessary saving of data
	}
}

/**
 * Called once a client successfully connects.  This callback is paired with OnClientDisconnect.
 *
 * @param client		Client index.
 */
public void OnClientConnected(int client)
{
	if (IsFakeClient(client) && !IsClientSourceTV(client))
	{
		++g_iNumBotsConnected;
		//PrintToServer("g_iNumBotsConnected: %d", g_iNumBotsConnected);
	}
}

/**
 * Called when a client is disconnecting from the server.
 *
 * @param client		Client index.
 */
public void OnClientDisconnect(int client)
{
	if (IsFakeClient(client) && !IsClientSourceTV(client))
	{
		--g_iNumBotsConnected;
		//PrintToServer("g_iNumBotsConnected: %d", g_iNumBotsConnected);
		
		for (int i = 0; i < MAX_GHOSTS; ++i)
		{
			if (client == g_iGhost[i])
			{
				g_iGhost[i] = 0;
				ResetGhost(i);
				return;
			}
		}
	}
	else // Human
	{
		if (g_arrayRun[client] != null)
		{
			delete g_arrayRun[client];
			g_arrayRun[client] = null;
		}
	}
}

/**
 * Caches replays for all levels and styles on the current map so that they 
 * can be played back later by the ghosts.
 *
 * @return int 		The total number of replays cached.
 */
int CacheReplays()
{
	int numReplays = 0;
	
	for (int level = 0; level < MAX_LEVELS; ++level)
	{
		for (int style = 0; style < MAX_STYLES; ++style)
		{
			g_bNoRecord[level][style] = !LoadRecord(level, style);
			
			if ( !g_bNoRecord[level][style] )
				++numReplays;
		}
	}
	return numReplays;
}

/**
 * Unloads the cached replays.
 * 
 * @return int 	The total number of replays unloaded.
 */
int UnloadReplays()
{
	int numReplays = 0;
	
	for (int level = 0; level < MAX_LEVELS; ++level)
	{
		for (int style = 0; style < MAX_STYLES; ++style)
		{
			if (g_arrayReplay[level][style] != null)
			{
				delete g_arrayReplay[level][style];
				g_arrayReplay[level][style] = null;
				g_bNoRecord[level][style] = true;
				++numReplays;
				
				OnReplayUnloaded(level, style);
			}
		}
	}
	return numReplays;
}

/*
 * Loads a replay that is stored on the hard disk at data/ghostrecords/
 *
 * @param int level 	Main / bonus?
 * @param int style 	Style ID
 * @return bool 		True on success, false otherwise.
 */
bool LoadRecord(int level, int style)
{
	if (level < 0 || level > MAX_LEVELS)
	{
		LogError("Level out of bounds: %d", level);
		return false;
	}
	if (style < 0 || style > MAX_STYLES)
	{
		LogError("Style out of bounds: %d", style);
		return false;
	}
	
	char path[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, path, sizeof(path), "%s/%s/%d/%s.meme", REPLAYS_PATH, g_sLevelNames[level], style, g_sMapName);
	
	if (!FileExists(path))
	{
		return false;
	}
	
	File file = OpenFile(path, "rb");
	if (file)
	{
		file.ReadString(g_sReplayNames[level][style], MAX_NAME_LENGTH, -1);
		file.ReadInt32(view_as<int>(g_fReplayTimes[level][style]));
		file.ReadInt16(g_iReplayJumps[level][style]);
		
		if (g_arrayReplay[level][style] != null)
			g_arrayReplay[level][style].Clear();
		else
			g_arrayReplay[level][style] = new ArrayList( RUNDATA_MAX );
		
		int values[RUNDATA_MAX];
		
		while (!file.EndOfFile())
		{
			// Read up until the weaponid since it's only 1 byte.
			file.Read(values, RUNDATA_MAX-1, 4);
			file.ReadInt8(values[RUNDATA_WEAPONID]);
			
			g_arrayReplay[level][style].PushArray(values, RUNDATA_MAX);
		}
		file.Close();
		OnReplayCached(level, style);
		return true;
	}
	LogError("Could not open file \"%s\" for reading", path);
	return false;
}

/**
 * Stores a binary representation of player's rundata at data/ghostrecords/
 * 
 * @param int client 	The client index
 * @param float time 	Time of player's run
 * @param int jumps 	Number of jumps
 * @param int level		Main / bonus?
 * @param int style		Style ID provided by the timer
 * @return bool			True on success, false otherwise.
 */
bool SaveRecord(int client, float time, int jumps, int level, int style)
{
	if (level < 0 || level > MAX_LEVELS)
	{
		LogError("Level out of bounds: %d", level);
		return false;
	}
	if (style < 0 || style > MAX_STYLES)
	{
		LogError("Style out of bounds: %d", style);
		return false;
	}
	if ( !IsValidClientIndex(client) )
	{
		LogError("Client index out of bounds: %d", client);
		return false;
	}
	if ( !IsClientInGame(client) )
	{
		LogError("Client %d is not in game", client);
		return false;
	}
	
	char path[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, path, sizeof(path), "%s/%s/%d/%s.meme", REPLAYS_PATH, g_sLevelNames[level], style, g_sMapName);
	
	if (FileExists(path))
	{
		#if defined BACKUP_REPLAYS
		BackupRecord(path);
		#endif
		
		DeleteFile(path); // Kinda unnecessary? Opening the file later will truncate it.
	}
	
	File file = OpenFile(path, "wb");
	if (file)
	{
		int size = g_arrayRun[client].Length;
		if (!size)
		{
			LogError("Couldn't save record. Run array is empty.");
			return false;
		}
		
		GetClientName(client, g_sReplayNames[level][style], MAX_NAME_LENGTH);
		file.WriteString(g_sReplayNames[level][style], true);
		
		g_fReplayTimes[level][style] = time;
		file.WriteInt32(view_as<int>(time));
		
		g_iReplayJumps[level][style] = jumps;
		file.WriteInt16(jumps);
		
		if (g_arrayReplay[level][style] != null)
			g_arrayReplay[level][style].Clear();
		else
			g_arrayReplay[level][style] = new ArrayList( RUNDATA_MAX );
		
		int values[RUNDATA_MAX];
		
		for (int i = 0; i < size; ++i)
		{
			g_arrayRun[client].GetArray(i, values, RUNDATA_MAX);
			
			file.Write(values, RUNDATA_MAX-1, 4);
			file.WriteInt8(values[RUNDATA_WEAPONID]);
			
			g_arrayReplay[level][style].PushArray(values, RUNDATA_MAX);
		}
		file.Close();
		OnReplayCached(level, style);
		return true;
	}
	LogError("Could not open the file \"%s\" for writing.", path);
	return false;
}

/**
 * Called whenever a recording gets cached.
 *
 * @param int level 	Main / bonus?
 * @param int style 	Style id
 * @noreturn
 */
void OnReplayCached(int level, int style)
{
	g_bNoRecord[level][style] = false;
	
	// Are any of the ghosts already replaying this record?
	for (int i = 0; i < MAX_GHOSTS; ++i)
	{
		if (i == CUSTOM_GHOST)
			continue;
		
		if (g_iGhostLevel[i] == level && g_iGhostStyle[i] == style)
		{
			// Double check the ghost exists
			if (IsValidClientIndex(g_iGhost[i]) && IsClientInGame(g_iGhost[i]))
			{
				if ( SetGhostReplay(i, level, style) )
				{
					StartPlayback(i, PLAYBACK_DELAY, true);
				}
			}
		}
	}
	
	// If the custom ghost is currently replaying the old record
	if ( IsValidClientIndex(g_iGhost[CUSTOM_GHOST])
		&& IsClientInGame(g_iGhost[CUSTOM_GHOST])
		&& IsPlayerAlive(g_iGhost[CUSTOM_GHOST])
		&& g_iGhostLevel[CUSTOM_GHOST] == level
		&& g_iGhostStyle[CUSTOM_GHOST] == style
		&& g_iGhostFrame[CUSTOM_GHOST] != -1)
	{
		if ( SetGhostReplay(CUSTOM_GHOST, level, style) )
		{
			StartPlayback(CUSTOM_GHOST, PLAYBACK_DELAY, true);
		}
	}
	else // Check if the custom ghost needs respawning
	{
		SetupCustomGhost();
	}
}

/**
 * Called when a cached recording gets unloaded.
 *
 * @param int level 	Main / bonus
 * @param int style 	Style id
 * @noreturn
 */
void OnReplayUnloaded(int level, int style)
{
	g_bNoRecord[level][style] = true;
	
	// Was any of the bots replaying this record before it was unloaded?
	for (int i = 0; i < MAX_GHOSTS; ++i)
	{
		if (g_iGhostLevel[i] == level && g_iGhostStyle[i] == style)
		{
			ResetGhost(i);
		}
	}
}

/**
 * Stores a backup of the old record at data/ghostrecords/
 * 
 * @param char recordPath 	Path to the file to be backed up
 * @noreturn
 */
void BackupRecord(char[] recordPath)
{
	char sPath[PLATFORM_MAX_PATH];
	FormatEx(sPath, sizeof(sPath), "%s_old", recordPath);
	
	// Delete the last backup
	if (FileExists(sPath))
	{
		DeleteFile(sPath);
	}
	
	RenameFile(sPath, recordPath);
}

/*
 * Creates ghosts for the current map.
 *
 * @param int numGhosts		The number of ghosts to create.
 * @noreturn
 */
bool CreateGhosts(int numGhosts = MAX_GHOSTS)
{
	CreateTimer(1.0, Timer_CheckIfGhostsExist, numGhosts, TIMER_FLAG_NO_MAPCHANGE|TIMER_REPEAT);
}

/**
 * Kicks ghosts and resets vars.
 *
 * @noreturn
 */
void RemoveGhosts()
{	
	ConVar cvar = FindConVar("bot_quota");
	cvar.SetInt(0);
	
	ServerCommand("bot_kick");
	
	for (int i = 0; i < MAX_GHOSTS; ++i)
	{
		g_iGhost[i] = 0;
		ResetGhost(i);
	}
}

/**
 * Called when the timer interval has elapsed.
 * 
 * @param timer			Handle to the timer object.
 * @param hndl			Handle passed to CreateTimer() when timer was created.
 * @return				Plugin_Stop to stop a repeating timer, any other value for
 *						default behavior.
 */
public Action Timer_CheckIfGhostsExist(Handle timer, int numGhosts)
{
	ConVar cvar = FindConVar("bot_quota");
	
	if (cvar.IntValue != numGhosts)
	{
		cvar.SetInt(numGhosts);
		return Plugin_Continue;
	}
	return Plugin_Stop;
}

/**
 * Called when all ghosts have joined the server.
 *
 * @param int numGhosts 	The total number of ghosts that have joined the server
 * @noreturn
 */
void OnGhostsPutInServer(int numGhosts)
{
	CreateTimer(1.0, Timer_SetupGhosts, numGhosts, TIMER_FLAG_NO_MAPCHANGE);
}

/**
 * Called when the timer interval has elapsed.
 * 
 * @param timer			Handle to the timer object.
 * @param hndl			Handle passed to CreateTimer() when timer was created.
 * @return				Plugin_Stop to stop a repeating timer, any other value for
 *						default behavior.
 */
public Action Timer_SetupGhosts(Handle timer, any numGhosts)
{
	// Assign ghost client indexes
	int ghostID = 0;
	for (int i = 1; i <= MaxClients; ++i)
	{
		if (IsClientInGame(i) && IsFakeClient(i) && !IsClientSourceTV(i))
		{
			g_iGhost[ghostID] = i;
			g_iGhostFrame[ghostID] = -1;
			++ghostID;
			
			SetEntProp(i, Prop_Data, "m_iFrags", 1337);
			SetEntProp(i, Prop_Data, "m_iDeaths", 1337);
		}
		if (ghostID == numGhosts)
		{
			break;
		}
	}
	if (ghostID != numGhosts)
	{
		return Plugin_Stop; // Couldn't find enough bots.
	}
	
	if ( SetGhostReplay(NORMAL_GHOST, 0, 0) )
	{
		StartPlayback(NORMAL_GHOST, PLAYBACK_DELAY);
	}
	
	// Remember initial spawn position
	// The player_spawn event couldn't pick it up because
	// the bots had already been spawned and no g_iGhost were assigned before that.
	if ( IsPlayerAlive(g_iGhost[CUSTOM_GHOST]) )
	{
		RememberSpawnPoint(g_iGhost[CUSTOM_GHOST]);
	}
	SetupCustomGhost();
	return Plugin_Stop;
}

/**
 * Checks if there is an available record given the level and style passed,
 * respawns the ghost if there is and binds the recording to it.
 *
 * @param int ghostID 	The ghost ID. NORMAL_GHOST / CUSTOM_GHOST
 * @param int level 	Main / bonus?
 * @param int style 	Style ID provided by the timer.
 * @return bool 		True on success, false otherwise.
 */
bool SetGhostReplay(int ghostID, int level, int style)
{
	if (ghostID < 0 || ghostID > MAX_GHOSTS)
	{
		LogError("Ghost ID out of bounds: %d", ghostID);
		return false;
	}
	if (level < 0 || level > MAX_LEVELS)
	{
		LogError("Level out of bounds: %d", level);
		return false;
	}
	if (style < 0 || style > MAX_STYLES)
	{
		LogError("Style out of bounds: %d", style);
		return false;
	}
	if ( !IsValidClientIndex(g_iGhost[ghostID]) )
	{
		LogError("Ghost's client index is invalid.");
		return false;
	}
	if ( !IsClientInGame(g_iGhost[ ghostID ]) )
	{
		LogError("The ghost appears to be not in game.");
		return false;
	}
	
	if (ghostID != CUSTOM_GHOST)
	{
		if (g_bNoRecord[level][style])
		{
			// No recording found for this level and style.
			ResetGhost( ghostID );
			return false;
		}
	}
	else
	{
		// Is there even any available record for the custom bot to replay?
		if ( !IsAnyRecordAvailable() )
		{
			// No recordings available for the custom bot to replay.
			ResetGhost( ghostID );
			return false;
		}
	}
	
	if (!IsPlayerAlive(g_iGhost[ ghostID ]))
	{
		CS_RespawnPlayer(g_iGhost[ ghostID ]);
	}
	else
	{
		ApplyGhostFX( ghostID, false );
	}
	
	// Prepare and set bot name
	char time[16];
	char smallName[MAX_ALLOWED_NAME];
	
	TimerFormat(g_fReplayTimes[level][style], time, sizeof(time), true, false);
	strcopy(smallName, sizeof(smallName), g_sReplayNames[level][style]);
	
	FormatEx(g_sGhostName[ghostID], MAX_NAME_LENGTH, "%s - %s, %d Jumps", smallName, time, g_iReplayJumps[level][style]);
	SetClientName(g_iGhost[ghostID], g_sGhostName[ghostID]);
	
	// Prepare and set bot tag
	if (level == 1)
		FormatEx(g_sGhostClanTag[ghostID], MAX_NAME_LENGTH, "B - %s", g_sStyleTags[style]);
	else
		strcopy(g_sGhostClanTag[ghostID], MAX_NAME_LENGTH, g_sStyleTags[style]);
	
	CS_SetClientClanTag(g_iGhost[ghostID], g_sGhostClanTag[ghostID]);
	
	// Bind the recording
	g_iGhostLevel[ ghostID ] = level;
	g_iGhostStyle[ ghostID ] = style;
	return true;
}

/**
 * Sets up the custom ghost. It either becomes in a state waiting for someone to 
 * tell it to replay something or goes inactive and dead indicating there are
 * no available records to playback.
 *
 * @return bool 	True if it's gone into an active waiting state, false otherwise.
 */
bool SetupCustomGhost()
{
	if ( IsAnyRecordAvailable() )
	{
		if ( IsValidClientIndex(g_iGhost[CUSTOM_GHOST]) && IsClientInGame(g_iGhost[CUSTOM_GHOST]) )
		{
			FormatEx(g_sGhostClanTag[CUSTOM_GHOST], MAX_NAME_LENGTH, MEME);
			FormatEx(g_sGhostName[CUSTOM_GHOST], MAX_NAME_LENGTH, "!replay / +use");
			
			SetClientName(g_iGhost[CUSTOM_GHOST], g_sGhostName[CUSTOM_GHOST]);
			CS_SetClientClanTag(g_iGhost[CUSTOM_GHOST], g_sGhostClanTag[CUSTOM_GHOST]);
			
			if (!IsPlayerAlive(g_iGhost[CUSTOM_GHOST]))
			{
				CS_RespawnPlayer(g_iGhost[CUSTOM_GHOST]);
			}
			else
			{
				ApplyGhostFX( CUSTOM_GHOST, false );
			}
			return true;
		}
	}
	// else
	ResetGhost( CUSTOM_GHOST );
	return false;
}

/**
 * Suicides the ghost, resets its name and clan tag and other vars.
 *
 * @param int ghostID 	The ghost id. NORMAL_GHOST / CUSTOM_GHOST
 * @return bool 		True on success, false otherwise.
 */
bool ResetGhost(int ghostID)
{
	if (ghostID < 0 || ghostID > MAX_GHOSTS)
	{
		LogError("Ghost ID out of bounds: %d", ghostID);
		return false;
	}
	
	g_iGhostFrame[ ghostID ] = -1;
	g_iGhostLevel[ ghostID ] = 0;
	g_iGhostStyle[ ghostID ] = 0;
	
	if (ghostID != CUSTOM_GHOST)
	{
		if (ghostID >= MAX_STYLES)
		{
			LogError("Can't have more ghosts than styles.");
			return false;
		}
		FormatEx(g_sGhostClanTag[ghostID], MAX_NAME_LENGTH, g_sStyleTags[ghostID]);
		FormatEx(g_sGhostName[ghostID], MAX_NAME_LENGTH, "No replay available");
	}
	else
	{
		FormatEx(g_sGhostClanTag[ghostID], MAX_NAME_LENGTH, MEME);
		FormatEx(g_sGhostName[ghostID], MAX_NAME_LENGTH, "No replays available");
	}
	
	if ( IsValidClientIndex(g_iGhost[ghostID]) && IsClientInGame(g_iGhost[ghostID]) )
	{
		SetClientName(g_iGhost[ghostID], g_sGhostName[ghostID]);
		CS_SetClientClanTag(g_iGhost[ghostID], g_sGhostClanTag[ghostID]);
		
		if (IsPlayerAlive(g_iGhost[ghostID]))
		{
			ForcePlayerSuicide(g_iGhost[ghostID]);
		}
	}
	return true;
}

/**
 * Applies FX to a ghost.
 *
 * @param int ghostID	The ghost ID (NORMAL_GHOST / CUSTOM_GHOST)
 * @param bool active 	Is the ghost in motion?
 * @return bool 		True on success, false otherwise
 */
bool ApplyGhostFX(int ghostID, bool active)
{
	if (ghostID < 0 || ghostID > MAX_GHOSTS)
	{
		LogError("Ghost ID out of bounds: %d", ghostID);
		return false;
	}
	if ( !IsValidClientIndex(g_iGhost[ghostID]) )
	{
		LogError("Ghost's client index is invalid.");
		return false;
	}
	if ( !IsClientInGame(g_iGhost[ ghostID ]) )
	{
		LogError("The ghost appears to be not in game.");
		return false;
	}
	if ( !IsPlayerAlive(g_iGhost[ ghostID ]) )
	{
		// The FX we apply require the bot to be alive.
		return false;
	}
	
	MoveType mt = active ? MOVETYPE_NOCLIP : MOVETYPE_NONE;
	RenderFx fx = active ? PLAYBACK_RENDER : RENDERFX_PULSE_SLOW_WIDE;
	
	SetEntityRenderFx(g_iGhost[ ghostID ], fx);
	SetEntityMoveType(g_iGhost[ ghostID ], mt);
	return true;
}

/**
 * Teleports the ghost to the start zone and starts the playback.
 *
 * @param int ghostID 	The ghost id. NORMAL_GHOST / CUSTOM_GHOST
 * @param float delay	Time to delay before the playback starts.
 * @param bool restart	True to restart the playback if it's already running.
 * @return bool 		True if the playback succeeds, false otherwise.
 */
bool StartPlayback(int ghostID, float delay, bool restart = false)
{
	if (ghostID < 0 || ghostID > MAX_GHOSTS)
	{
		LogError("Ghost ID out of bounds: %d", ghostID);
		return false;
	}
	if ( !IsValidClientIndex(g_iGhost[ ghostID ]) )
	{
		LogError("Ghost's client index is invalid.");
		return false;
	}
	if ( !IsClientInGame(g_iGhost[ ghostID ]) )
	{
		LogError("The ghost appears to be not in game.");
		return false;
	}
	if ( !IsPlayerAlive(g_iGhost[ ghostID ]) )
	{
		LogError("The ghost is not alive. Can't start the playback.");
		return false;
	}
	
	int level = g_iGhostLevel[ghostID];
	int style = g_iGhostStyle[ghostID];
	
	if (level < 0 || level > MAX_LEVELS)
	{
		LogError("g_iGhostLevel[%d] out of bounds: %d", ghostID, level);
		return false;
	}
	if (style < 0 || style > MAX_STYLES)
	{
		LogError("g_iGhostStyle[%d] out of bounds: %d", ghostID, style);
		return false;
	}
	if (g_bNoRecord[level][style])
	{
		LogMessage("No record available for level: %d and style: %d", level, style);
		return false;
	}
	if (g_arrayReplay[level][style] == null)
	{
		LogError("g_arrayReplay[%d][%d] is null.", level, style);
		return false;
	}
	if (!g_arrayReplay[level][style].Length)
	{
		LogError("The array is empty.");
		return false;
	}
	
	if (!restart)
	{
		if (g_iGhostFrame[ghostID] != -1)
		{
			// The ghost is already in playback
			return false;
		}
	}
	else
	{
		// Stop the playback, freeze the ghost.
		g_iGhostFrame[ghostID] = -1;
	}
	
	g_fGhostTime[ ghostID ] = 0.0;
	
	// Teleport the ghost to the start zone (first frame)
	int values[RUNDATA_MAX];
	g_arrayReplay[level][style].GetArray(0, values, RUNDATA_MAX);

	float replayPos[3], replayAngles[3];
	
	copyArray( values[RUNDATA_POSITION_X], replayPos, 3 );
	copyArray( values[RUNDATA_PITCH], replayAngles, 2 );
	copyArray( replayAngles, g_fGhostLastAngles[ghostID], 3 );
	
	TeleportEntity(g_iGhost[ghostID], replayPos, replayAngles, view_as<float>({0.0, 0.0, 0.0}));
	
	// Create a timer that sets ghost's frame counter to 0 to begin the playback.
	DataPack pack = new DataPack();
	pack.WriteCell( GetClientSerial(g_iGhost[ghostID]) );
	pack.WriteCell( ghostID );
	
	SetEntityRenderFx(g_iGhost[ ghostID ], RENDERFX_SOLID_SLOW);
	CreateTimer(delay, Timer_StartPlayback, pack, TIMER_FLAG_NO_MAPCHANGE|TIMER_DATA_HNDL_CLOSE);
	return true;
}

/**
 * Called when the timer interval has elapsed.
 * 
 * @param timer			Handle to the timer object.
 * @param hndl			Handle passed to CreateTimer() when timer was created.
 * @return				Plugin_Stop to stop a repeating timer, any other value for
 *						default behavior.
 */
public Action Timer_StartPlayback(Handle timer, DataPack pack)
{
	pack.Reset();
	int ghost = GetClientFromSerial( pack.ReadCell() );
	
	if (!ghost)
	{
		// This exact ghost is no longer on the server.
		return Plugin_Stop; // playback request no longer valid
	}
	
	if (!IsPlayerAlive(ghost))
	{
		// The ghost was killed. Possible reasons for this to happen:
		// 1. The recording was deleted.
		// 2. The array containing the rundata was cleared/deleted.
		// Either way, we shouldn't be starting the playback if the ghost is dead.
		return Plugin_Stop;
	}
	
	int ghostID = pack.ReadCell();
	
	ApplyGhostFX( ghostID, true );
	g_iGhostFrame[ ghostID ] = 0; // Starts the playback
	g_fGhostTime[ ghostID ] = GetGameTime();
	return Plugin_Stop;
}

/**
 * Called when a ghost reaches the end of a recording.
 *
 * @param int ghostID	The ghost id. NORMAL_GHOST / CUSTOM_GHOST
 * @param bool replay 	If set to true, replays the recording
 * @param float delay	If replay is true, time to delay before the playback starts over
 * @noreturn
 */
void OnPlaybackEnd(int ghostID, bool replay = true, float delay = PLAYBACK_DELAY)
{
	if (ghostID < 0 || ghostID > MAX_GHOSTS)
	{
		LogError("Ghost ID out of bounds: %d", ghostID);
		return;
	}
	
	// Stop the ghost.
	g_iGhostFrame[ghostID] = -1;
	g_fGhostTime[ ghostID ] = GetGameTime() - g_fGhostTime[ ghostID ];
	ApplyGhostFX( ghostID, false );
	
	if (ghostID == CUSTOM_GHOST)
	{
		DataPack pack = new DataPack();
		pack.WriteCell( GetClientSerial(g_iGhost[ghostID]) );
		pack.WriteCell( ghostID );
		
		CreateTimer(delay, Timer_OnCustomGhostPlaybackEnd, pack, TIMER_FLAG_NO_MAPCHANGE|TIMER_DATA_HNDL_CLOSE);
	}
	else // all other bots (NORMAL_GHOST only for now)
	{
		if (replay)
		{
			SetEntityRenderFx(g_iGhost[ ghostID ], RENDERFX_FADE_SLOW);
			
			DataPack pack = new DataPack();
			pack.WriteCell( GetClientSerial(g_iGhost[ghostID]) );
			pack.WriteCell( ghostID );
			
			CreateTimer(delay, Timer_RestartPlayback, pack, TIMER_FLAG_NO_MAPCHANGE|TIMER_DATA_HNDL_CLOSE);
		}
	}
}

/**
 * Called when the custom ghost's playback ends. This is just used to delay 
 * the ghost from going into inactive / waiting state when the playback ends.
 */
public Action Timer_OnCustomGhostPlaybackEnd(Handle timer, DataPack pack)
{
	pack.Reset();
	int ghost = GetClientFromSerial( pack.ReadCell() );
	
	if (!ghost)
	{
		// The ghost is no longer on the server.
		return Plugin_Stop;
	}
	
	// Teleport the ghost to the start
	if ( IsPlayerAlive(ghost) )
	{
		TeleportEntity(g_iGhost[CUSTOM_GHOST], g_fSpawnPoint, NULL_VECTOR, NULL_VECTOR);
	}
	
	// Re-setup the custom ghost
	SetupCustomGhost();
	return Plugin_Stop;
}

/**
 * Called when the timer interval has elapsed.
 * 
 * @param timer			Handle to the timer object.
 * @param hndl			Handle passed to CreateTimer() when timer was created.
 * @return				Plugin_Stop to stop a repeating timer, any other value for
 *						default behavior.
 */
public Action Timer_RestartPlayback(Handle timer, DataPack pack)
{
	pack.Reset();
	int ghost = GetClientFromSerial( pack.ReadCell() );
	
	if (!ghost)
	{
		// This exact ghost is no longer on the server.
		return Plugin_Stop; // restart playback request no longer valid
	}
	
	if (!IsPlayerAlive(ghost))
	{
		// The ghost was killed. Possible reasons for this to happen:
		// 1. The recording was deleted.
		// 2. The array containing the rundata was cleared/deleted.
		// Either way, we shouldn't be starting the playback if the ghost is dead.
		return Plugin_Stop;
	}
	
	StartPlayback(pack.ReadCell(), PLAYBACK_DELAY);
	return Plugin_Stop;
}

/**
 * Returns whether there's ANY record available for playback.
 *
 * @return bool		True if there is, false otherwise.
 */
bool IsAnyRecordAvailable()
{
	for (int i = 0; i < MAX_LEVELS; ++i)
	{
		for (int k = 0; k < MAX_STYLES; ++k)
		{
			// Ignore Main Normal
			if (i == 0 && k == 0)
			{
				continue;
			}
			if ( !g_bNoRecord[i][k] )
			{
				return true;
			}
		}
	}
	return false;
}

// Called when a game event is fired.
//
// @param event			Handle to event. This could be INVALID_HANDLE if every plugin hooking 
//						this event has set the hook mode EventHookMode_PostNoCopy.
// @param name			String containing the name of the event.
// @param dontBroadcast	True if event was not broadcast to clients, false otherwise.
// @return				Ignored for post hooks. Plugin_Handled will block event if hooked as pre.
//
public Action Event_PlayerSpawn_Post(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId( event.GetInt("userid") );
	
	if (IsFakeClient(client))
	{
		for (int i = 0; i < MAX_GHOSTS; ++i)
		{
			if (client == g_iGhost[i])
			{
				SetEntProp(client, Prop_Data, "m_iFrags", 1337);
				SetEntProp(client, Prop_Data, "m_iDeaths", 1337);
				
				if (i == CUSTOM_GHOST)
				{
					RememberSpawnPoint(client);
					TeleportEntity(client, g_fSpawnPoint, NULL_VECTOR, NULL_VECTOR);
				}
				
				ApplyGhostFX( i, false );
				break;
			}
		}
	}
}

/**
 * Remembers custom ghost's spawnpoint
 *
 * @param int client 	The client index
 * @noreturn
 */
void RememberSpawnPoint(int client)
{
	float origin[3];
	GetEntDataVector(client, m_vecOrigin, origin);
	
	float vTemp[3];
	copyArray(origin, vTemp, 3);
	vTemp[2] -= 8192.0;
	
	float vClientMins[3];
	GetClientMins(client, vClientMins);
	
	float vClientMaxs[3];
	GetClientMaxs(client, vClientMaxs);
	
	Handle trace = TR_TraceHullFilterEx(origin, vTemp, vClientMins, vClientMaxs, MASK_PLAYERSOLID_BRUSHONLY, TraceRayBrushOnly, client);
	TR_GetEndPosition(g_fSpawnPoint, trace);
	
	delete trace;
}

public bool TraceRayBrushOnly(int entity, int mask, any data)
{
	return entity != data && !(0 < entity <= MaxClients);
}

// Called when a game event is fired.
//
// @param event			Handle to event. This could be INVALID_HANDLE if every plugin hooking 
//						this event has set the hook mode EventHookMode_PostNoCopy.
// @param name			String containing the name of the event.
// @param dontBroadcast	True if event was not broadcast to clients, false otherwise.
// @return				Ignored for post hooks. Plugin_Handled will block event if hooked as pre.
//
public Action Event_PlayerDeath_Post(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId( event.GetInt("userid") );
	
	if (IsFakeClient(client))
	{
		for (int i = 0; i < MAX_GHOSTS; ++i)
		{
			if (client == g_iGhost[i])
			{
				SetEntProp(client, Prop_Data, "m_iFrags", 1337);
				SetEntProp(client, Prop_Data, "m_iDeaths", 1337);
				break;
			}
		}
	}
}

/**
 * @brief Called when a clients movement buttons are being processed
 *
 * @param client	Index of the client.
 * @param buttons	Copyback buffer containing the current commands (as bitflags - see entity_prop_stocks.inc).
 * @param impulse	Copyback buffer containing the current impulse command.
 * @param vel		Players desired velocity.
 * @param angles	Players desired view angles.
 * @param weapon	Entity index of the new weapon if player switches weapon, 0 otherwise.
 * @param subtype	Weapon subtype when selected from a menu.
 * @param cmdnum	Command number. Increments from the first command sent.
 * @param tickcount	Tick count. A client's prediction based on the server's GetGameTickCount value.
 * @param seed		Random seed. Used to determine weapon recoil, spread, and other predicted elements.
 * @param mouse		Mouse direction (x, y).
 * @return 			Plugin_Handled to block the commands from being processed, Plugin_Continue otherwise.
 *
 * @note			To see if all 11 params are available, use FeatureType_Capability and
 *					FEATURECAP_PLAYERRUNCMD_11PARAMS.
 */
public Action OnPlayerRunCmd(int client, int &buttons, int &impulse, float vel[3], float angles[3], int &weapon, int &subtype, int &cmdnum, int &tickcount, int &seed, int mouse[2])
{
	// Handle humans
	if (!IsFakeClient(client))
	{
		if (IsPlayerAlive(client))
		{
			// Is the player running?
			if (!g_bPaused[client])
			{
				// Record run data
				int values[RUNDATA_MAX];
				
				float origin[3];
				GetEntDataVector(client, m_vecOrigin, origin);
				
				values[RUNDATA_POSITION_X] = view_as<int>(origin[0]);
				values[RUNDATA_POSITION_Y] = view_as<int>(origin[1]);
				values[RUNDATA_POSITION_Z] = view_as<int>(origin[2]);
				values[RUNDATA_PITCH] = view_as<int>(angles[0]);
				values[RUNDATA_YAW] = view_as<int>(angles[1]);
				values[RUNDATA_BUTTONS] = buttons;
				values[RUNDATA_IMPULSE] = impulse;
				values[RUNDATA_WEAPONID] = view_as<int>( GetWeaponID(client) );
				
				g_arrayRun[client].PushArray(values, RUNDATA_MAX);
			}
		}
		else
		{
			static int lastbuttons[MAXPLAYERS + 1];
			if (buttons & IN_USE && !(lastbuttons[client] & IN_USE))
			{
				// Is the player spectating the custom replay bot?
				int target = GetEntDataEnt2(client, m_hObserverTarget);
				if (target == g_iGhost[CUSTOM_GHOST])
				{
					int mode = GetEntData(client, m_iObserverMode);
					if ( mode != SPECMODE_FIRSTPERSON )
					{
						SetEntData(client, m_iObserverMode, SPECMODE_FIRSTPERSON, 4, true);
					}
					// Send the replay menu to the player
					ReplaysMenu(client);
				}
				else
				{
					// Attempt to switch to the custom replay ghost
					if ( IsValidClientIndex(g_iGhost[CUSTOM_GHOST])
						&& IsClientInGame(g_iGhost[CUSTOM_GHOST])
						&& IsPlayerAlive(g_iGhost[CUSTOM_GHOST]) )
					{
						SetEntDataEnt2(client, m_hObserverTarget, g_iGhost[CUSTOM_GHOST], true);
						
						int mode = GetEntData(client, m_iObserverMode);
						if ( mode != SPECMODE_FIRSTPERSON )
						{
							SetEntData(client, m_iObserverMode, SPECMODE_FIRSTPERSON, 4, true);
						}
					}
				}
			}
			lastbuttons[client] = buttons;
		}
	}
	else // Handle ghosts
	{
		for (int ghostID = 0; ghostID < MAX_GHOSTS; ++ghostID)
		{
			if (client == g_iGhost[ghostID] && IsPlayerAlive(client))
			{
				int level = g_iGhostLevel[ghostID];
				int style = g_iGhostStyle[ghostID];
				
				if (g_iGhostFrame[ghostID] == -1 || g_bNoRecord[level][style])
				{
					// The bot is paused / inactive.
					TeleportEntity(client, NULL_VECTOR, g_fGhostLastAngles[ghostID], NULL_VECTOR);
					return Plugin_Continue;
				}
				
				/*if (GetEntityFlags(client) & FL_ONGROUND)
					SetEntityMoveType(client, MOVETYPE_WALK);
				else
					SetEntityMoveType(client, MOVETYPE_NOCLIP);*/
				
				int values[RUNDATA_MAX];
				g_arrayReplay[level][style].GetArray(g_iGhostFrame[ghostID], values, RUNDATA_MAX);
				
				// Teleport the ghost, apply velocity.
				float pos[3], replayPos[3], replayAngles[3];
				GetEntDataVector(client, m_vecOrigin, pos);
				
				copyArray( values[RUNDATA_POSITION_X], replayPos, 3 );
				copyArray( values[RUNDATA_PITCH], replayAngles, 2 );
				
				if (GetVectorDistance(pos, replayPos, false) > CORRECT_POSITION_DIST)
				{
					//PrintToChatAll("Fixed position.");
					TeleportEntity(client, replayPos, replayAngles, NULL_VECTOR);
				}
				else
				{
					//	(newPos - curPos) * tickrate = velocity
					//	newPos = velocity/tickrate + curPos
					float velocity[3];
					MakeVectorFromPoints(pos, replayPos, velocity);
					ScaleVector(velocity, g_fTickrate);
					TeleportEntity(client, NULL_VECTOR, replayAngles, velocity);
				}
				
				buttons = values[RUNDATA_BUTTONS];
				buttons &= ~(IN_ATTACK | IN_ATTACK2);
				impulse = values[RUNDATA_IMPULSE];
				
				static CSWeaponID lastWeaponID[MAX_GHOSTS] = {CSWeapon_NONE, ...};
				CSWeaponID weaponID = view_as<CSWeaponID>( values[RUNDATA_WEAPONID] );
				
				if (weaponID != lastWeaponID[ghostID])
				{
					StripPlayerWeapons(client);
					if (weaponID != CSWeapon_NONE)
					{
						static char weaponAlias[64];
						static char weaponName[64];
						
						CS_WeaponIDToAlias(weaponID, weaponAlias, sizeof(weaponAlias));
						CS_GetTranslatedWeaponAlias(weaponAlias, weaponName, sizeof(weaponName));
						Format(weaponName, sizeof(weaponName), "weapon_%s", weaponName);

						GivePlayerItem(client, weaponName);
					}
				}
				
				lastWeaponID[ghostID] = weaponID;
				++g_iGhostFrame[ghostID];
				
				if (g_iGhostFrame[ghostID] == g_arrayReplay[level][style].Length)
				{
					OnPlaybackEnd(ghostID);
				}
				copyArray(replayAngles, g_fGhostLastAngles[ghostID], 3);
				
				vel[2] = 0.0;
				return Plugin_Changed;
			}
		}
	}
	return Plugin_Continue;
}

/**
 * Returns the CSWeaponID of player's current active weapon.
 *
 * @return CSWeaponID	The weapon id
 */
CSWeaponID GetWeaponID(int client)
{
	CSWeaponID weaponID = CSWeapon_NONE;
	
	int weaponIndex = GetEntDataEnt2(client, m_hActiveWeapon);
	if (weaponIndex != -1)
	{
		static char classname[64];
		GetEdictClassname(weaponIndex, classname, sizeof(classname));
		ReplaceString(classname, sizeof(classname), "weapon_", "");
		
		static char wepAlias[64];
		CS_GetTranslatedWeaponAlias(classname, wepAlias, sizeof(wepAlias));
		weaponID = CS_AliasToWeaponID(wepAlias);
	}
	return weaponID;
}

/**
 * Called by the timer plugin when the player is in the start zone.
 */
public Action SM_StartRecord(int args)
{
	char sArg[16];
	GetCmdArg(1, sArg, sizeof(sArg));
	
	int client = GetClientOfUserId(StringToInt(sArg));
	if (!client)
	{
		LogError("Invalid client during SM_StartRecord. Client index is 0.");
		return Plugin_Handled;
	}
	
	g_arrayRun[client].Clear();
	g_bPaused[client] = false;
	
	return Plugin_Handled;
}

/**
 * Called by the timer plugin when the player enters the end zone.
 */
public Action SM_EndRecord(int args)
{
	char sArg[160];
	GetCmdArg(1, sArg, 160);
	
	char sArgs[5][32];
	ExplodeString(sArg, " ", sArgs, 5, 32);
	
	int client = GetClientOfUserId(StringToInt(sArgs[0]));
	if (!client)
	{
		LogError("Invalid client during SM_EndRecord. Client index is 0.");
		return Plugin_Handled;
	}
	
	float time = StringToFloat(sArgs[1]);
	int jumps = StringToInt(sArgs[2]);
	int style = StringToInt(sArgs[3]);
	int level = StringToInt(sArgs[4]);
	
	g_bPaused[client] = true;
	SaveRecord(client, time, jumps, level, style);
	return Plugin_Handled;
}

/*
 * Called by the timer plugin when the player pauses his timer.
 */
public Action SM_TimerPause(int args)
{
	char sArg[16];
	GetCmdArg(1, sArg, sizeof(sArg));
	
	int client = GetClientOfUserId(StringToInt(sArg));
	if (!client)
	{
		LogError("Invalid client during SM_TimerPause. Client index is 0.");
		return Plugin_Handled;
	}
	
	g_bPaused[client] = true;
	return Plugin_Handled;
}

/*
 * Called by the timer plugin when the player resumes his timer.
 */
public Action SM_TimerResume(int args)
{
	char sArg[16];
	GetCmdArg(1, sArg, sizeof(sArg));
	
	int client = GetClientOfUserId(StringToInt(sArg));
	if (!client)
	{
		LogError("Invalid client during SM_TimerResume. Client index is 0.");
		return Plugin_Handled;
	}
	
	g_bPaused[client] = false;
	return Plugin_Handled;
}

/**
 * @brief When an entity is created
 *
 * @param		entity		Entity index
 * @param		classname	Class name
 */
public void OnEntityCreated(int entity, const char[] classname)
{
	if (StrEqual(classname, "func_button"))
	{
		SDKHook(entity, SDKHook_Use, OnBotActivate);
	}
	else if (StrContains(classname, "trigger_") != -1)
	{
		SDKHook(entity, SDKHook_StartTouch, OnBotActivate);
		SDKHook(entity, SDKHook_EndTouch, OnBotActivate);
		SDKHook(entity, SDKHook_Touch, OnBotActivate);
	}
}

/**
 * Ignore bot interacting with triggers and buttons
 */
public Action OnBotActivate(int entity, int other)
{
	for (int i = 0; i < MAX_GHOSTS; ++i)
	{
		if (g_iGhost[i] == other)
		{
			return Plugin_Handled;
		}
	}
	return Plugin_Continue;
}

/**
 * Copies an array.
 *
 * @param any src 	The source array to copy from.
 * @param any dest 	The destination array to copy to.
 * @param int size 	The size of the arrays.
 * @noreturn
 */
stock void copyArray(const any[] src, any[] dest, int size)
{
	for (int i = 0; i < size; ++i)
	{
		dest[i] = src[i];
	}
}

/**
 * Strips player's weapons
 *
 * @param client	The client index
 * @return 			Number of weapons removed
 */
int StripPlayerWeapons(int client)
{
	int numOfWeaponsRemoved = 0;
	
	// Go through every possible weapon /offset math/
	for (int i = 0; i < MAX_WEAPONS; ++i)
	{
		int weaponIndex = GetEntDataEnt2(client, m_hMyWeapons + i*4);
		if (weaponIndex == -1)
		{
			continue; // no entity at this location
		}
		
		if ( !IsValidEdict(weaponIndex) )
		{
			continue; // this weapon must have been destroyed or unnetworked?
		}
		
		if ( RemovePlayerItem(client, weaponIndex) )
		{
			// Managed to remove this weapon from the player
			// Time to completely delete it now
			AcceptEntityInput(weaponIndex, "Kill");
			++numOfWeaponsRemoved;
		}
	}
	return numOfWeaponsRemoved;
}

/**
 * Returns whether the client index is within valid bounds.
 *
 * @param int client 	The client index
 * @return bool 		True if within valids bounds, false otherwise
 */
stock bool IsValidClientIndex(int client)
{
	return 0 < client && client <= MaxClients;
}

/**
 * An alternative command used to bring up the replays menu.
 */
public Action SM_Replay(int client, int args)
{
	if (!client)
	{
		ReplyToCommand(client, "You have to be in game in order to use this command");
		return Plugin_Handled;
	}
	
	if (!IsClientObserver(client))
	{
		ReplyToCommand(client, "You have to be observing the bot to request a replay");
		return Plugin_Handled;
	}
	
	int mode = GetEntData(client, m_iObserverMode);
	if ( mode != SPECMODE_FIRSTPERSON && mode != SPECMODE_3RDPERSON )
	{
		ReplyToCommand(client, "You have to be observing the bot to request a replay");
		return Plugin_Handled;
	}
	
	int target = GetEntDataEnt2(client, m_hObserverTarget);
	if (target != g_iGhost[CUSTOM_GHOST])
	{
		ReplyToCommand(client, "You have to be observing the bot to request a replay");
		return Plugin_Handled;
	}
	
	ReplaysMenu(client);
	return Plugin_Handled;
}

/**
 * Displays the replays menu to a client.
 *
 * @param int client 	The client index.
 * @noreturn
 */
void ReplaysMenu(int client)
{
	Menu menu = new Menu(ReplaysMenuHandler);
	
	menu.SetTitle("Bot Replays Menu");
	
	char buffer[MAX_LEVELNAME_LEN];
	for (int i = 0; i < MAX_LEVELS; ++i)
	{
		strcopy(buffer, sizeof(buffer), g_sLevelNames[i]);
		buffer[0] = CharToUpper(buffer[0]);
		menu.AddItem(g_sLevelNames[i], buffer);
	}
	
	menu.ExitButton = true;
	menu.Display(client, MENU_TIME_FOREVER);
}

public int ReplaysMenuHandler(Handle menu, MenuAction action, int client, int choice)
{
	switch (action)
	{
		case MenuAction_Select:
		{
			if ( IsPlayerAlive(client) || !IsClientObserver(client) )
			{
				PrintToChat(client, "You have to be observing the bot to request a replay");
				return 0;
			}
			
			int target = GetEntDataEnt2(client, m_hObserverTarget);
			if (target != g_iGhost[CUSTOM_GHOST])
			{
				PrintToChat(client, "You have to be observing the bot to request a replay");
				return 0;
			}
			int mode = GetEntData(client, m_iObserverMode);
			if ( mode != SPECMODE_FIRSTPERSON )
			{
				SetEntData(client, m_iObserverMode, SPECMODE_FIRSTPERSON, 4, true);
			}
			
			ReplaysStyleMenu(client, choice);
		}
		case MenuAction_End:
		{
			delete menu;
		}
	}
	return 0;
}

/**
 * Displays the replay styles menu to a client.
 *
 * @param int client 	The client index.
 * @param int level 	Main / bonus?
 * @noreturn
 */
void ReplaysStyleMenu(int client, int level)
{
	Menu menu = new Menu(ReplaysStyleMenuHandler);
	
	menu.SetTitle("Bot Replays Menu");
	
	char info[2];
	IntToString(level, info, sizeof(info));
	
	int startin;
	if (level == 0)
		startin = 1;
	else
		startin = 0;
	
	for (int i = startin; i < g_iGhostStylesCount; i++)
	{
		if (!g_bNoRecord[level][i])
			menu.AddItem(info, g_sStyleNames[i]);
		else
			menu.AddItem(info, g_sStyleNames[i], ITEMDRAW_DISABLED);
	}
	
	menu.ExitButton = true;
	menu.ExitBackButton = true;
	menu.Display(client, MENU_TIME_FOREVER);
}

public int ReplaysStyleMenuHandler(Menu menu, MenuAction action, int client, int choice)
{	
	switch (action)
	{
		case MenuAction_Select:
		{
			if ( IsPlayerAlive(client) || !IsClientObserver(client) )
			{
				PrintToChat(client, "You have to be observing the bot to request a replay");
				return 0;
			}
			
			int target = GetEntDataEnt2(client, m_hObserverTarget);
			if (target != g_iGhost[CUSTOM_GHOST])
			{
				PrintToChat(client, "You have to be observing the bot to request a replay");
				return 0;
			}
			int mode = GetEntData(client, m_iObserverMode);
			if ( mode != SPECMODE_FIRSTPERSON )
			{
				SetEntData(client, m_iObserverMode, SPECMODE_FIRSTPERSON, 4, true);
			}
			
			// Check if the custom ghost is in motion.
			if (g_iGhostFrame[CUSTOM_GHOST] != -1 || GetGameTime() - g_fLastUsed <= PLAYBACK_DELAY)
			{
				PrintToChat(client, "Please wait for the current playback to end.");
				return 0;
			}
			
			int style = choice;
			char info[2];
			menu.GetItem(choice, info, sizeof(info));
			
			int level = StringToInt(info);
			
			if (level == 0)
				style++;
			
			if ( SetGhostReplay(CUSTOM_GHOST, level, style) )
			{
				if ( StartPlayback(CUSTOM_GHOST, PLAYBACK_DELAY) )
				{
					NotifySpectators(client);
					g_fLastUsed = GetGameTime();
				}
			}
		}
		case MenuAction_Cancel:
		{
			if (choice == MenuCancel_ExitBack)
			{
				ReplaysMenu(client);
			}
		}
		case MenuAction_End:
		{
			delete menu;
		}
	}
	return 0;
}

/**
 * Notifies players spectating the custom ghost who started the playback.
 *
 * @param int client 	The player who started the playback
 * @noreturn
 */
void NotifySpectators(int client)
{
	for (int i = 1; i <= MaxClients; ++i)
	{
		if (!IsClientInGame(i) || IsFakeClient(i) || !IsClientObserver(i))
			continue;
		
		int mode = GetEntData(i, m_iObserverMode);
		if ( mode != SPECMODE_FIRSTPERSON && mode != SPECMODE_3RDPERSON ) 
			continue;
		
		int target = GetEntDataEnt2(i, m_hObserverTarget);
		if ( !IsValidClientIndex(target) || !IsClientInGame(target) || !IsFakeClient(target) )
			continue;
		
		if (target != g_iGhost[CUSTOM_GHOST])
			continue;
		
		PrintCenterText(i, "Playback started by: %N", client);
	}
}

public Action Timer_HudLoop(Handle timer, any data)
{
	for (int i = 1; i <= MaxClients; ++i)
	{
		if (!IsClientInGame(i) || IsFakeClient(i) || !IsClientObserver(i))
			continue;
		
		int mode = GetEntData(i, m_iObserverMode);
		if ( mode != SPECMODE_FIRSTPERSON && mode != SPECMODE_3RDPERSON ) 
			continue;
		
		int target = GetEntDataEnt2(i, m_hObserverTarget);
		if ( !IsValidClientIndex(target) || !IsClientInGame(target) || !IsFakeClient(target) )
			continue;
		
		for (int ghostID = 0; ghostID < MAX_GHOSTS; ghostID++)
		{
			if (target != g_iGhost[ghostID])
				continue;
			
			UpdateHUD(i, ghostID);
			break;
		}
	}
	return Plugin_Continue;
}

void UpdateHUD(int client, int ghostID)
{
	char HintTextBuffer[256];
	
	if (g_iGhostFrame[ghostID] == -1)
	{
		if (ghostID == CUSTOM_GHOST)
		{
			FormatEx(HintTextBuffer, sizeof(HintTextBuffer), "Press your +use key or type !replay");
		}
		else
		{
			int level = g_iGhostLevel[ghostID];
			int style = g_iGhostStyle[ghostID];
			
			if (g_bNoRecord[level][style])
			{
				// This shouldn't really happen anyway, the bot is gonna be dead
				// if there's no record available.
				char levelName[MAX_LEVELNAME_LEN];
				strcopy(levelName, sizeof(levelName), g_sLevelNames[level]);
				levelName[0] = CharToUpper(levelName[0]);
				
				FormatEx(HintTextBuffer, sizeof(HintTextBuffer), "No Replay Available [ %s %s ]", levelName, g_sStyleNames[style]);
			}
			else
			{
				FormatGhostHUD(ghostID, HintTextBuffer, g_fGhostTime[ ghostID ]);
			}
		}
	}
	else
	{
		FormatGhostHUD(ghostID, HintTextBuffer, (GetGameTime() - g_fGhostTime[ ghostID ]));
	}
	
	PrintHintText(client, HintTextBuffer);
}

void FormatGhostHUD(int ghostID, char buffer[256], float time)
{
	int level = g_iGhostLevel[ghostID];
	int style = g_iGhostStyle[ghostID];
	
	char levelName[MAX_LEVELNAME_LEN];
	strcopy(levelName, sizeof(levelName), g_sLevelNames[level]);
	levelName[0] = CharToUpper(levelName[0]);
	FormatEx(buffer, sizeof(buffer), "Replay Bot [ %s %s ]\n ", levelName, g_sStyleNames[style]);
	
	char cTime[16];
	TimerFormat(time, cTime, sizeof(cTime), true, false);
	Format(buffer, sizeof(buffer), "%s\n Time: %s", buffer, cTime);
	
	float velocity[3];
	GetEntDataVector(g_iGhost[ghostID], m_vecVelocity, velocity);
	Format(buffer, sizeof(buffer), "%s\nSpeed: %i", buffer, FormatVelocity(velocity));
}

int FormatVelocity(float vel[3])
{
	for (int i = 0; i < 2; ++i)
		vel[i] *= vel[i];
	
	int result = RoundToFloor(SquareRoot(vel[0] + vel[1]));
	return result;
}

public void TimerFormat(float fTime, char[] sBuffer, int len, bool showMS, bool addsymbol)
{
	FormatEx(sBuffer, len, "");
	
	if (fTime < 0)
	{
		fTime *= -1;
		if (addsymbol)
			FormatEx(sBuffer, len, "-");
	}
	else
	{
		if (addsymbol)
			FormatEx(sBuffer, len, "+");
	}
	
	int mins = RoundToFloor(fTime) / 60;
	int secs = RoundToFloor(fTime) - (mins * 60);

	if (!showMS)
	{
		Format(sBuffer, len, "%s%02i:%02i", sBuffer, mins, secs);
	}
	else
	{
		float ms = fTime - ((mins * 60) + secs);
		Format(sBuffer, len, "%s%02i:%02i.%03i", sBuffer, mins, secs, RoundToFloor( ms * 1000.0 ));
	}
}

public Action SM_UnloadReplays(int client, int args)
{
	UnloadReplays();
	
	PrintToChatAll("%N unloaded replays.", client);
	return Plugin_Handled;
}

public Action SM_ReloadReplays(int client, int args)
{
	UnloadReplays();
	CacheReplays();
	
	PrintToChatAll("%N reloaded replays.", client);
	return Plugin_Handled;
}
