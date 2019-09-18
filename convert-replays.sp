/* Headers */
#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <cstrike>

/* Preprocessor directives */
#pragma semicolon 1 // Enforce the usage of semicolons
#pragma newdecls required // Enforce the new syntax

#define PLUGIN_VERSION "0.1.0" // Using semantic versioning: https://semver.org/
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
#define PLAYBACK_DELAY 2.0 // Delay before the playback begins
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

// Others
int g_iGhostStylesCount = 0; //Number of styles found in the KV file
char g_sStyleNames[MAX_STYLES][MAX_NAME_LENGTH]; //Style names
char g_sStyleTags[MAX_STYLES][MAX_STYLETAG_LEN]; //Style tags
char g_sLevelNames[MAX_LEVELS][MAX_LEVELNAME_LEN] =  { "main", "bonus" };

public void OnPluginStart()
{
	g_iGhostStylesCount = LoadStyles();
	CheckDirectories( g_iGhostStylesCount );
	
	RegAdminCmd("sm_convertreplays", SM_ConvertReplays, ADMFLAG_RCON);
}

public Action SM_ConvertReplays(int client, int args)
{
	char maplist[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, maplist, sizeof(maplist), REPLAYS_PATH);
	BuildPath(Path_SM, maplist, sizeof(maplist), "%s/maplist.txt", REPLAYS_PATH);
	
	if (!FileExists(maplist))
	{
		ReplyToCommand(client, "No maplist at \"%s\"", maplist);
		return Plugin_Handled;
	}
	
	char mapname[64]; //Current map name
	
	File maps = OpenFile(path, "rb");
	if (maps)
	{
		while (!maps.EndOfFile() && maps.ReadLine(mapname, sizeof(mapname)))
		{
			// Got the map, now load replays
			
		}
		maps.Close();
		return true;
	}
	else
	{
		ReplyToCommand(client, "Couldn't open maps for reading.");
		return Plugin_Handled;
	}
	
	return Plugin_Handled;
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
			}
		}
	}
	return numReplays;
}

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
	BuildPath(Path_SM, path, sizeof(path), "%s/%s/%d/%s.rec", REPLAYS_PATH, g_sLevelNames[level], style, g_sMapName);
	
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
		return true;
	}
	LogError("Could not open file \"%s\" for reading", path);
	return false;
}
