//Pragma
#pragma semicolon 1
#pragma newdecls required

//Defines

#define PLUGIN_DESCRIPTION "A sourcemod plugin with rich features for dynamic zone development."
#define PLUGIN_VERSION "1.0.0"

#define MAX_RADIUS_ZONES 256
#define MAX_ZONES 256

#define MAX_ZONE_NAME_LENGTH 128
#define MAX_ZONE_TYPE_LENGTH 64

#define MAX_EFFECT_NAME_LENGTH 128

#define EFFECT_CALLBACK_ONENTERZONE 0
#define EFFECT_CALLBACK_ONACTIVEZONE 1
#define EFFECT_CALLBACK_ONLEAVEZONE 2

#define DEFAULT_MODELINDEX "sprites/laserbeam.vmt"
#define DEFAULT_HALOINDEX "materials/sprites/halo.vmt"

#define ZONE_TYPES 2
#define ZONE_TYPE_BOX 0
#define ZONE_TYPE_CIRCLE 1

//Sourcemod Includes
#include <sourcemod>
#include <sourcemod-misc>
#include <sdktools>
#include <sdkhooks>

//External Includes
#include <colorvariables>

//ConVars
ConVar convar_Status;

//Forwards
Handle g_Forward_StartTouchZone;
Handle g_Forward_TouchZone;
Handle g_Forward_EndTouchZone;
Handle g_Forward_StartTouchZone_Post;
Handle g_Forward_TouchZone_Post;
Handle g_Forward_EndTouchZone_Post;

//Globals
bool bLate;
KeyValues kZonesConfig;
bool bShowAllZones[MAXPLAYERS + 1];

//Engine related stuff for entities.
int iDefaultModelIndex;
int iDefaultHaloIndex;
char sErrorModel[] = "models/error.mdl";

//Entities Data
bool g_bIsZone[MAX_ENTITY_LIMIT];
float g_fZoneRadius[MAX_ENTITY_LIMIT];
Handle g_hZoneEffects[MAX_ENTITY_LIMIT];

//Radius Management
bool bInsideRadius[MAXPLAYERS + 1][MAX_ENTITY_LIMIT];
bool bInsideRadius_Post[MAXPLAYERS + 1][MAX_ENTITY_LIMIT];

//Effects Data
StringMap g_hTrie_EffectCalls;
ArrayList g_hArray_EffectsList;

//Create Zones Data
char sCreateZone_Name[MAXPLAYERS + 1][MAX_ZONE_NAME_LENGTH];
int iCreateZone_Type[MAXPLAYERS + 1];
float fCreateZone_Start[MAXPLAYERS + 1][3];
float fCreateZone_End[MAXPLAYERS + 1][3];
float fCreateZone_Radius[MAXPLAYERS + 1];

bool bIsViewingZone[MAXPLAYERS + 1];
bool bSettingName[MAXPLAYERS + 1];
int iEditingName[MAXPLAYERS + 1] = {INVALID_ENT_REFERENCE, ...};

//Plugin Information
public Plugin myinfo =
{
	name = "Zones-Manager",
	author = "Keith Warren (Drixevel)",
	description = PLUGIN_DESCRIPTION,
	version = PLUGIN_VERSION,
	url = "http://www.drixevel.com/"
};

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
	RegPluginLibrary("zones_manager");

	CreateNative("Zones_Manager_Register_Effect", Native_Register_Effect);

	g_Forward_StartTouchZone = CreateGlobalForward("ZonesManager_OnStartTouchZone", ET_Event, Param_Cell, Param_Cell, Param_String, Param_Cell);
	g_Forward_TouchZone = CreateGlobalForward("ZonesManager_OnTouchZone", ET_Event, Param_Cell, Param_Cell, Param_String, Param_Cell);
	g_Forward_EndTouchZone = CreateGlobalForward("ZonesManager_OnEndTouchZone", ET_Event, Param_Cell, Param_Cell, Param_String, Param_Cell);
	g_Forward_StartTouchZone_Post = CreateGlobalForward("ZonesManager_OnStartTouchZone_Post", ET_Ignore, Param_Cell, Param_Cell, Param_String, Param_Cell);
	g_Forward_TouchZone_Post = CreateGlobalForward("ZonesManager_OnTouchZone_Post", ET_Ignore, Param_Cell, Param_Cell, Param_String, Param_Cell);
	g_Forward_EndTouchZone_Post = CreateGlobalForward("ZonesManager_OnEndTouchZone_Post", ET_Ignore, Param_Cell, Param_Cell, Param_String, Param_Cell);

	bLate = late;
	return APLRes_Success;
}

public void OnPluginStart()
{
	LoadTranslations("common.phrases");
	LoadTranslations("zonesmanager.phrases");

	CreateConVar("sm_zonesmanager_version", PLUGIN_VERSION, PLUGIN_DESCRIPTION, FCVAR_REPLICATED | FCVAR_NOTIFY | FCVAR_SPONLY | FCVAR_DONTRECORD);
	convar_Status = CreateConVar("sm_zonesmanager_status", "1", "Status of the plugin.", FCVAR_NOTIFY, true, 0.0, true, 1.0);

	//AutoExecConfig();

	HookEvent("teamplay_round_start", OnRoundStart);

	RegAdminCmd("sm_zones", Command_OpenZonesMenu, ADMFLAG_ROOT, "Display the zones manager menu.");
	RegAdminCmd("sm_regeneratezones", Command_RegenerateZones, ADMFLAG_ROOT, "Regenerate all zones on the map.");
	RegAdminCmd("sm_deleteallzones", Command_DeleteAllZones, ADMFLAG_ROOT, "Delete all zones on the map.");

	g_hTrie_EffectCalls = CreateTrie();
	g_hArray_EffectsList = CreateArray(ByteCountToCells(MAX_EFFECT_NAME_LENGTH));

	CreateTimer(0.1, Timer_DisplayZones, _, TIMER_REPEAT);
}

public void OnMapStart()
{
	iDefaultModelIndex = PrecacheModel(DEFAULT_MODELINDEX);
	iDefaultHaloIndex = PrecacheModel(DEFAULT_HALOINDEX);
	PrecacheModel(sErrorModel);

	LogDebug("zonesmanager", "Deleting current zones map configuration from memory.");

	SaveMapConfig();
	ReparseMapZonesConfig();
}

void ReparseMapZonesConfig(bool delete_config = false)
{
	delete kZonesConfig;

	char sFolder[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, sFolder, sizeof(sFolder), "data/zones/");
	CreateDirectory(sFolder, 511);

	char sMap[32];
	GetCurrentMap(sMap, sizeof(sMap));

	char sPath[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, sPath, sizeof(sPath), "data/zones/%s.cfg", sMap);

	if (delete_config)
	{
		DeleteFile(sPath);
	}

	LogDebug("zonesmanager", "Creating keyvalues for the new map before pulling new map zones info.");
	kZonesConfig = CreateKeyValues("zones_manager");

	if (FileExists(sPath))
	{
		LogDebug("zonesmanager", "Config exists, retrieving the zones...");
		FileToKeyValues(kZonesConfig, sPath);
	}
	else
	{
		LogDebug("zonesmanager", "Config doesn't exist, creating new zones config for the map: %s", sMap);
		KeyValuesToFile(kZonesConfig, sPath);
	}

	LogDebug("zonesmanager", "New config successfully loaded.");
}

public void OnConfigsExecuted()
{
	if (bLate)
	{
		SpawnAllZones();
		bLate = false;
	}
}

public void OnPluginEnd()
{
	ClearAllZones();
}

public void OnRoundStart(Event event, const char[] name, bool dontBroadcast)
{
	RegenerateZones();
}

void ClearAllZones()
{
	int entity = INVALID_ENT_INDEX;
	while ((entity = FindEntityByClassname(entity, "*")) != INVALID_ENT_INDEX)
	{
		if (IsEntityIndex(entity) && g_bIsZone[entity])
		{
			AcceptEntityInput(entity, "Kill");
			g_bIsZone[entity] = false;
			delete g_hZoneEffects[entity];
		}
	}
}

void SpawnAllZones()
{
	LogDebug("zonesmanager", "Spawning all zones...");

	KvRewind(kZonesConfig);
	if (KvGotoFirstSubKey(kZonesConfig))
	{
		do
		{
			char sName[MAX_ZONE_NAME_LENGTH];
			KvGetSectionName(kZonesConfig, sName, sizeof(sName));

			char sType[MAX_ZONE_TYPE_LENGTH];
			KvGetString(kZonesConfig, "type", sType, sizeof(sType));
			int type = GetZoneNameType(sType);

			float vStartPosition[3];
			KvGetVector(kZonesConfig, "start", vStartPosition);

			float vEndPosition[3];
			KvGetVector(kZonesConfig, "end", vEndPosition);

			float fRadius = KvGetFloat(kZonesConfig, "radius");

			CreateZone(sName, type, vStartPosition, vEndPosition, fRadius);
		}
		while(KvGotoNextKey(kZonesConfig));
	}

	LogDebug("zonesmanager", "Zones have been spawned.");
}

public void OnClientSayCommand_Post(int client, const char[] command, const char[] sArgs)
{
	if (strlen(sArgs) == 0)
	{
		return;
	}

	if (bSettingName[client])
	{
		strcopy(sCreateZone_Name[client], MAX_ZONE_NAME_LENGTH, sArgs);
		bSettingName[client] = false;
		OpenCreateZonesMenu(client);
	}

	if (iEditingName[client] != INVALID_ENT_REFERENCE)
	{
		int entity = EntRefToEntIndex(iEditingName[client]);

		char sName[MAX_ZONE_NAME_LENGTH];
		GetEntPropString(entity, Prop_Data, "m_iName", sName, sizeof(sName));

		UpdateZonesSectionName(entity, sArgs);
		CPrintToChat(client, "Zone '%s' has been renamed successfully to '%s'.", sName, sArgs);
		iEditingName[client] = INVALID_ENT_REFERENCE;

		OpenZonePropertiesMenu(client, entity);
	}
}

public Action OnPlayerRunCmd(int client, int &buttons, int &impulse, float vel[3], float angles[3], int &weapon, int &subtype, int &cmdnum, int &tickcount, int &seed, int mouse[2])
{
	if (client == 0 || client > MaxClients || !IsClientInGame(client))
	{
		return Plugin_Continue;
	}

	if (IsPlayerAlive(client))
	{
		float vecPosition[3];
		GetClientAbsOrigin(client, vecPosition);

		float vecOrigin[3];

		int entity = INVALID_ENT_INDEX;
		while ((entity = FindEntityByClassname(entity, "info_target")) != INVALID_ENT_INDEX)
		{
			if (g_bIsZone[entity])
			{
				GetEntPropVector(entity, Prop_Data, "m_vecOrigin", vecOrigin);
				float distance = GetVectorDistance(vecOrigin, vecPosition);
				//PrintToDrixevel("%.2f <= %.2f", distance, g_fZoneRadius[entity]);

				if (distance <= (g_fZoneRadius[entity] / 2.0))
				{
					Action action = IsNearRadiusZone(client, entity);

					if (action <= Plugin_Changed)
					{
						IsNearRadiusZone_Post(client, entity);
					}
				}
				else
				{
					Action action = IsNotNearRadiusZone(client, entity);

					if (action <= Plugin_Changed)
					{
						IsNotNearRadiusZone_Post(client, entity);
					}
				}
			}
		}
	}

	return Plugin_Continue;
}

public Action Command_OpenZonesMenu(int client, int args)
{
	if (!GetConVarBool(convar_Status))
	{
		return Plugin_Handled;
	}

	if (client == 0)
	{
		CReplyToCommand(client, "You must be in-game to use this command.");
		return Plugin_Handled;
	}

	OpenZonesMenu(client);
	return Plugin_Handled;
}

public Action Command_RegenerateZones(int client, int args)
{
	if (!GetConVarBool(convar_Status))
	{
		return Plugin_Handled;
	}

	RegenerateZones(client);
	return Plugin_Handled;
}

public Action Command_DeleteAllZones(int client, int args)
{
	if (!GetConVarBool(convar_Status))
	{
		return Plugin_Handled;
	}

	DeleteAllZones(client);
	return Plugin_Handled;
}

void OpenZonesMenu(int client)
{
	Menu menu = CreateMenu(MenuHandle_ZonesMenu);
	SetMenuTitle(menu, "Zones Manager");

	AddMenuItem(menu, "manage", "Manage Zones");
	AddMenuItem(menu, "create", "Create a Zone");
	AddMenuItem(menu, "---", "---", ITEMDRAW_DISABLED);
	AddMenuItemFormat(menu, "viewall", ITEMDRAW_DEFAULT, "Draw Zones: %s", bShowAllZones[client] ? "On" : "Off");
	AddMenuItemFormat(menu, "regenerate", ITEMDRAW_DEFAULT, "Regenerate Zones");
	AddMenuItemFormat(menu, "deleteall", ITEMDRAW_DEFAULT, "Delete all Zones");

	DisplayMenu(menu, client, MENU_TIME_FOREVER);
}

public int MenuHandle_ZonesMenu(Menu menu, MenuAction action, int param1, int param2)
{
	switch (action)
	{
		case MenuAction_Select:
		{
			char sInfo[32];
			GetMenuItem(menu, param2, sInfo, sizeof(sInfo));

			if (StrEqual(sInfo, "manage"))
			{
				OpenManageZonesMenu(param1);
			}
			else if (StrEqual(sInfo, "create"))
			{
				OpenCreateZonesMenu(param1, true);
			}
			else if (StrEqual(sInfo, "viewall"))
			{
				bShowAllZones[param1] = !bShowAllZones[param1];
				OpenZonesMenu(param1);
			}
			else if (StrEqual(sInfo, "regenerate"))
			{
				RegenerateZones(param1);
				OpenZonesMenu(param1);
			}
			else if (StrEqual(sInfo, "deleteall"))
			{
				DeleteAllZones(param1);
				OpenZonesMenu(param1);
			}
		}

		case MenuAction_End:
		{
			CloseHandle(menu);
		}
	}
}

void RegenerateZones(int client = -1)
{
	ClearAllZones();
	SpawnAllZones();

	if (client > -1)
	{
		CReplyToCommand(client, "All zones have been regenerated on the map.");
	}
}

void DeleteAllZones(int client = -1)
{
	ClearAllZones();
	ReparseMapZonesConfig(true);

	if (client > -1)
	{
		CReplyToCommand(client, "All zones have been deleted from the map.");
	}
}

void OpenManageZonesMenu(int client)
{
	Menu menu = CreateMenu(MenuHandle_ManageZonesMenu);
	SetMenuTitle(menu, "Manage Zones:");

	int entity = INVALID_ENT_INDEX;
	while ((entity = FindEntityByClassname(entity, "*")) != INVALID_ENT_INDEX)
	{
		if (!IsEntityIndex(entity) || !g_bIsZone[entity])
		{
			continue;
		}

		char sEntity[12];
		IntToString(entity, sEntity, sizeof(sEntity));

		char sName[MAX_ZONE_NAME_LENGTH];
		GetEntPropString(entity, Prop_Data, "m_iName", sName, sizeof(sName));

		AddMenuItem(menu, sEntity, sName);
	}

	if (GetMenuItemCount(menu) == 0)
	{
		AddMenuItem(menu, "", "[No Zones]", ITEMDRAW_DISABLED);
	}

	SetMenuExitBackButton(menu, true);
	DisplayMenu(menu, client, MENU_TIME_FOREVER);
}

public int MenuHandle_ManageZonesMenu(Menu menu, MenuAction action, int param1, int param2)
{
	switch (action)
	{
		case MenuAction_Select:
		{
			char sEntity[12]; char sName[MAX_ZONE_NAME_LENGTH];
			GetMenuItem(menu, param2, sEntity, sizeof(sEntity), _, sName, sizeof(sName));

			OpenEditZoneMenu(param1, StringToInt(sEntity));
		}

		case MenuAction_Cancel:
		{
			if (param2 == MenuCancel_ExitBack)
			{
				OpenZonesMenu(param1);
			}
		}

		case MenuAction_End:
		{
			CloseHandle(menu);
		}
	}
}

void OpenEditZoneMenu(int client, int entity)
{
	char sName[MAX_ZONE_NAME_LENGTH];
	GetEntPropString(entity, Prop_Data, "m_iName", sName, sizeof(sName));

	Menu menu = CreateMenu(MenuHandle_ManageEditMenu);
	SetMenuTitle(menu, "Manage Zone '%s':", sName);

	AddMenuItem(menu, "edit", "Edit Zone");
	AddMenuItem(menu, "delete", "Delete Zone");
	AddMenuItem(menu, "", "---", ITEMDRAW_DISABLED);
	AddMenuItem(menu, "effects_add", "Add Effect");
	AddMenuItem(menu, "effects_remove", "Remove Effect");

	PushMenuCell(menu, "entity", entity);

	SetMenuExitBackButton(menu, true);
	DisplayMenu(menu, client, MENU_TIME_FOREVER);
}

public int MenuHandle_ManageEditMenu(Menu menu, MenuAction action, int param1, int param2)
{
	switch (action)
	{
		case MenuAction_Select:
		{
			char sInfo[32];
			GetMenuItem(menu, param2, sInfo, sizeof(sInfo));

			int entity = GetMenuCell(menu, "entity");

			if (StrEqual(sInfo, "edit"))
			{
				OpenZonePropertiesMenu(param1, entity);
			}
			else if (StrEqual(sInfo, "delete"))
			{
				DisplayConfirmDeleteZoneMenu(param1, entity);
			}
			else if (StrEqual(sInfo, "effects_add"))
			{
				if (!AddZoneEffectMenu(param1, entity))
				{
					OpenEditZoneMenu(param1, entity);
				}
			}
			else if (StrEqual(sInfo, "effects_remove"))
			{
				if (!RemoveZoneEffectMenu(param1, entity))
				{
					OpenEditZoneMenu(param1, entity);
				}
			}
		}

		case MenuAction_Cancel:
		{
			if (param2 == MenuCancel_ExitBack)
			{
				OpenManageZonesMenu(param1);
			}
		}

		case MenuAction_End:
		{
			CloseHandle(menu);
		}
	}
}

void OpenZonePropertiesMenu(int client, int entity)
{
	char sName[MAX_ZONE_NAME_LENGTH];
	GetEntPropString(entity, Prop_Data, "m_iName", sName, sizeof(sName));

	Menu menu = CreateMenu(MenuHandle_ZonePropertiesMenu);
	SetMenuTitle(menu, "Edit properties for zone '%s':", sName);

	AddMenuItem(menu, "edit_name", "Name");
	AddMenuItem(menu, "edit_type", "Type", ITEMDRAW_DISABLED);

	switch (GetZoneType(entity))
	{
		case ZONE_TYPE_BOX:
		{
			AddMenuItem(menu, "edit_startpoint_a", "StartPoint A");
			AddMenuItem(menu, "edit_startpoint_b", "StartPoint B");
		}
		case ZONE_TYPE_CIRCLE:
		{
			AddMenuItem(menu, "edit_startpoint", "StartPoint");
			AddMenuItem(menu, "edit_radius", "Radius", ITEMDRAW_DISABLED);
		}
	}

	PushMenuCell(menu, "entity", entity);

	SetMenuExitBackButton(menu, true);
	DisplayMenu(menu, client, MENU_TIME_FOREVER);
}

public int MenuHandle_ZonePropertiesMenu(Menu menu, MenuAction action, int param1, int param2)
{
	switch (action)
	{
		case MenuAction_Select:
		{
			char sInfo[32];
			GetMenuItem(menu, param2, sInfo, sizeof(sInfo));

			int entity = GetMenuCell(menu, "entity");

			char sName[MAX_ZONE_NAME_LENGTH];
			GetEntPropString(entity, Prop_Data, "m_iName", sName, sizeof(sName));

			if (StrEqual(sInfo, "edit_name"))
			{
				iEditingName[param1] = EntIndexToEntRef(entity);
				CPrintToChat(param1, "Type the new name for the zone '%s' in chat:", sName);
			}
			else if (StrEqual(sInfo, "edit_type"))
			{
				OpenZonePropertiesMenu(param1, entity);
			}
			else if (StrEqual(sInfo, "edit_startpoint_b"))
			{
				float start[3];
				GetClientLookPoint(param1, start);

				float end[3];
				GetEntPropVector(entity, Prop_Data, "m_vecMaxs", end);

				float fMiddle[3];
				GetMiddleOfABox(start, end, fMiddle);

				TeleportEntity(entity, fMiddle, NULL_VECTOR, NULL_VECTOR);

				// Have the mins always be negative
				start[0] = start[0] - fMiddle[0];
				if(start[0] > 0.0)
				start[0] *= -1.0;
				start[1] = start[1] - fMiddle[1];
				if(start[1] > 0.0)
				start[1] *= -1.0;
				start[2] = start[2] - fMiddle[2];
				if(start[2] > 0.0)
				start[2] *= -1.0;

				SetEntPropVector(entity, Prop_Data, "m_vecMins", start);
				SetEntPropVector(entity, Prop_Data, "m_vecMaxs", end);

				UpdateZonesConfigKeyVector(entity, "start", start);
				OpenZonePropertiesMenu(param1, entity);
			}
			else if (StrEqual(sInfo, "edit_startpoint_a"))
			{
				float start[3];
				GetEntPropVector(entity, Prop_Data, "m_vecMins", start);

				float end[3];
				GetClientLookPoint(param1, end);

				float fMiddle[3];
				GetMiddleOfABox(start, end, fMiddle);

				TeleportEntity(entity, fMiddle, NULL_VECTOR, NULL_VECTOR);

				// And the maxs always be positive
				end[0] = end[0] - fMiddle[0];
				if(end[0] < 0.0)
				end[0] *= -1.0;
				end[1] = end[1] - fMiddle[1];
				if(end[1] < 0.0)
				end[1] *= -1.0;
				end[2] = end[2] - fMiddle[2];
				if(end[2] < 0.0)
				end[2] *= -1.0;

				SetEntPropVector(entity, Prop_Data, "m_vecMins", start);
				SetEntPropVector(entity, Prop_Data, "m_vecMaxs", end);

				UpdateZonesConfigKeyVector(entity, "end", end);
				OpenZonePropertiesMenu(param1, entity);
			}
			else if (StrEqual(sInfo, "edit_startpoint"))
			{
				float start[3];
				GetClientLookPoint(param1, start);

				TeleportEntity(entity, start, NULL_VECTOR, NULL_VECTOR);

				UpdateZonesConfigKeyVector(entity, "start", start);
				OpenZonePropertiesMenu(param1, entity);
			}
			else if (StrEqual(sInfo, "edit_radius"))
			{
				OpenZonePropertiesMenu(param1, entity);
			}
			else
			{
				OpenZonePropertiesMenu(param1, entity);
			}
		}

		case MenuAction_Cancel:
		{
			if (param2 == MenuCancel_ExitBack)
			{
				OpenEditZoneMenu(param1, GetMenuCell(menu, "entity"));
			}
		}

		case MenuAction_End:
		{
			CloseHandle(menu);
		}
	}
}

stock void UpdateZonesConfigKey(int entity, const char[] key, const char[] value)
{
	if (kZonesConfig == null)
	{
		return;
	}

	char sName[MAX_ZONE_NAME_LENGTH];
	GetEntPropString(entity, Prop_Data, "m_iName", sName, sizeof(sName));

	KvRewind(kZonesConfig);

	if (KvJumpToKey(kZonesConfig, sName))
	{
		KvSetString(kZonesConfig, key, value);
		KvRewind(kZonesConfig);
	}

	SaveMapConfig();
}

void UpdateZonesConfigKeyVector(int entity, const char[] key, float[3] value)
{
	if (kZonesConfig == null)
	{
		return;
	}

	char sName[MAX_ZONE_NAME_LENGTH];
	GetEntPropString(entity, Prop_Data, "m_iName", sName, sizeof(sName));

	KvRewind(kZonesConfig);

	if (KvJumpToKey(kZonesConfig, sName))
	{
		KvSetVector(kZonesConfig, key, value);
		KvRewind(kZonesConfig);
	}

	SaveMapConfig();
}

void UpdateZonesSectionName(int entity, const char[] name)
{
	if (kZonesConfig == null)
	{
		return;
	}

	char sName[MAX_ZONE_NAME_LENGTH];
	GetEntPropString(entity, Prop_Data, "m_iName", sName, sizeof(sName));

	KvRewind(kZonesConfig);

	if (KvJumpToKey(kZonesConfig, sName))
	{
		KvSetSectionName(kZonesConfig, name);
		KvRewind(kZonesConfig);
	}

	SaveMapConfig();

	SetEntPropString(entity, Prop_Data, "m_iName", name);
}

void DisplayConfirmDeleteZoneMenu(int client, int entity)
{
	char sName[MAX_ZONE_NAME_LENGTH];
	GetEntPropString(entity, Prop_Data, "m_iName", sName, sizeof(sName));

	Menu menu = CreateMenu(MenuHandle_ManageConfirmDeleteZoneMenu);
	SetMenuTitle(menu, "Are you sure you want to delete '%s':", sName);

	AddMenuItem(menu, "yes", "Yes");
	AddMenuItem(menu, "no", "No");

	PushMenuCell(menu, "entity", entity);

	SetMenuExitBackButton(menu, true);
	DisplayMenu(menu, client, MENU_TIME_FOREVER);
}

public int MenuHandle_ManageConfirmDeleteZoneMenu(Menu menu, MenuAction action, int param1, int param2)
{
	switch (action)
	{
		case MenuAction_Select:
		{
			char sInfo[32];
			GetMenuItem(menu, param2, sInfo, sizeof(sInfo));

			int entity = GetMenuCell(menu, "entity");

			if (StrEqual(sInfo, "no"))
			{
				OpenEditZoneMenu(param1, entity);
				return;
			}

			char sName[MAX_ZONE_NAME_LENGTH];
			GetEntPropString(entity, Prop_Data, "m_iName", sName, sizeof(sName));

			DeleteZone(entity);
			CPrintToChat(param1, "You have deleted the zone '%s'.", sName);
			OpenManageZonesMenu(param1);
		}

		case MenuAction_Cancel:
		{
			if (param2 == MenuCancel_ExitBack)
			{
				OpenEditZoneMenu(param1, GetMenuCell(menu, "entity"));
			}
		}

		case MenuAction_End:
		{
			CloseHandle(menu);
		}
	}
}

void OpenCreateZonesMenu(int client, bool reset = false)
{
	if (reset)
	{
		ResetCreateZoneVariables(client);
	}

	char sType[MAX_ZONE_TYPE_LENGTH];
	GetZoneTypeName(iCreateZone_Type[client], sType, sizeof(sType));

	Menu menu = CreateMenu(MenuHandle_CreateZonesMenu);
	SetMenuTitle(menu, "Create a Zone:");

	AddMenuItem(menu, "create", "Create Zone", strlen(sCreateZone_Name[client]) > 0 ? ITEMDRAW_DEFAULT : ITEMDRAW_DISABLED);
	AddMenuItem(menu, "", "---", ITEMDRAW_DISABLED);

	AddMenuItemFormat(menu, "name", ITEMDRAW_DEFAULT, "Name: %s", strlen(sCreateZone_Name[client]) > 0 ? sCreateZone_Name[client] : "N/A");
	AddMenuItemFormat(menu, "type", ITEMDRAW_DEFAULT, "Type: %s", sType);

	switch (iCreateZone_Type[client])
	{
		case ZONE_TYPE_BOX:
		{
			AddMenuItem(menu, "start", "Set Starting Point", ITEMDRAW_DEFAULT);
			AddMenuItem(menu, "end", "Set Ending Point", ITEMDRAW_DEFAULT);
		}

		case ZONE_TYPE_CIRCLE:
		{
			AddMenuItem(menu, "start", "Set Starting Point", ITEMDRAW_DEFAULT);
			AddMenuItemFormat(menu, "radius", ITEMDRAW_DEFAULT, "Set Radius: %.2f", fCreateZone_Radius[client]);
		}
	}

	AddMenuItemFormat(menu, "view", ITEMDRAW_DEFAULT, "View Zone: %s", bIsViewingZone[client] ? "On" : "Off");

	SetMenuExitBackButton(menu, true);
	DisplayMenu(menu, client, MENU_TIME_FOREVER);
}

public int MenuHandle_CreateZonesMenu(Menu menu, MenuAction action, int param1, int param2)
{
	switch (action)
	{
		case MenuAction_Select:
		{
			char sInfo[32];
			GetMenuItem(menu, param2, sInfo, sizeof(sInfo));

			if (StrEqual(sInfo, "name"))
			{
				bSettingName[param1] = true;
				CPrintToChat(param1, "Type the name of this new zone in chat:");
			}
			else if (StrEqual(sInfo, "type"))
			{
				iCreateZone_Type[param1] = iCreateZone_Type[param1] == ZONE_TYPE_BOX ? ZONE_TYPE_CIRCLE : ZONE_TYPE_BOX;
				OpenZoneTypeMenu(param1);
			}
			else if (StrEqual(sInfo, "start"))
			{
				float vLookPoint[3];
				GetClientLookPoint(param1, vLookPoint);
				Array_Copy(vLookPoint, fCreateZone_Start[param1], 3);
				//CPrintToChat(param1, "Starting point: %.2f/%.2f/%.2f", fCreateZone_Start[param1][0], fCreateZone_Start[param1][1], fCreateZone_Start[param1][2]);

				OpenCreateZonesMenu(param1);
			}
			else if (StrEqual(sInfo, "end"))
			{
				float vLookPoint[3];
				GetClientLookPoint(param1, vLookPoint);
				Array_Copy(vLookPoint, fCreateZone_End[param1], 3);
				//CPrintToChat(param1, "Ending point: %.2f/%.2f/%.2f", fCreateZone_End[param1][0], fCreateZone_End[param1][1], fCreateZone_End[param1][2]);

				OpenCreateZonesMenu(param1);
			}
			else if (StrEqual(sInfo, "radius"))
			{
				fCreateZone_Radius[param1] += 5.0;

				if (fCreateZone_Radius[param1] > 500.0)
				{
					fCreateZone_Radius[param1] = 0.0;
				}

				OpenCreateZonesMenu(param1);
			}
			else if (StrEqual(sInfo, "view"))
			{
				bIsViewingZone[param1] = !bIsViewingZone[param1];
				OpenCreateZonesMenu(param1);
			}
			else if (StrEqual(sInfo, "create"))
			{
				CreateNewZone(param1);
				OpenZonesMenu(param1);
			}
		}

		case MenuAction_Cancel:
		{
			if (param2 == MenuCancel_ExitBack)
			{
				OpenZonesMenu(param1);
			}
		}

		case MenuAction_End:
		{
			CloseHandle(menu);
		}
	}
}

bool AddZoneEffectMenu(int client, int entity)
{
	char sName[MAX_ZONE_NAME_LENGTH];
	GetEntPropString(entity, Prop_Data, "m_iName", sName, sizeof(sName));

	Menu menu = CreateMenu(MenuHandler_AddZoneEffect);
	SetMenuTitle(menu, "Add a zone effect to %s:", sName);

	for (int i = 0; i < GetArraySize(g_hArray_EffectsList); i++)
	{
		char sEffect[MAX_EFFECT_NAME_LENGTH];
		GetArrayString(g_hArray_EffectsList, i, sEffect, sizeof(sEffect));

		int draw = ITEMDRAW_DEFAULT;

		StringMap values;
		if (GetTrieValue(g_hZoneEffects[entity], sEffect, values) && values != null)
		{
			draw = ITEMDRAW_DISABLED;
		}

		AddMenuItem(menu, sEffect, sEffect, draw);
	}

	if (GetMenuItemCount(menu) == 0)
	{
		AddMenuItem(menu, "", "[No Effects]", ITEMDRAW_DISABLED);
	}

	PushMenuCell(menu, "entity", entity);

	SetMenuExitBackButton(menu, true);
	DisplayMenu(menu, client, MENU_TIME_FOREVER);
	return true;
}

public int MenuHandler_AddZoneEffect(Menu menu, MenuAction action, int param1, int param2)
{
	switch (action)
	{
		case MenuAction_Select:
		{
			char sEffect[MAX_EFFECT_NAME_LENGTH];
			GetMenuItem(menu, param2, sEffect, sizeof(sEffect));

			int entity = GetMenuCell(menu, "entity");

			StringMap values = CreateTrie();
			SetTrieValue(values, "value1", 5);
			SetTrieString(values, "valu2", "peaches");

			SetTrieValue(g_hZoneEffects[entity], sEffect, values);
			OpenEditZoneMenu(param1, entity);
		}

		case MenuAction_Cancel:
		{
			if (param2 == MenuCancel_ExitBack)
			{
				OpenEditZoneMenu(param1, GetMenuCell(menu, "entity"));
			}
		}

		case MenuAction_End:
		{
			CloseHandle(menu);
		}
	}
}

bool RemoveZoneEffectMenu(int client, int entity)
{
	char sName[MAX_ZONE_NAME_LENGTH];
	GetEntPropString(entity, Prop_Data, "m_iName", sName, sizeof(sName));

	Menu menu = CreateMenu(MenuHandler_RemoveZoneEffect);
	SetMenuTitle(menu, "Add a zone type to %s to remove:", sName);

	for (int i = 0; i < GetArraySize(g_hArray_EffectsList); i++)
	{
		char sEffect[MAX_EFFECT_NAME_LENGTH];
		GetArrayString(g_hArray_EffectsList, i, sEffect, sizeof(sEffect));

		AddMenuItem(menu, "", sEffect);
	}

	PushMenuCell(menu, "entity", entity);

	SetMenuExitBackButton(menu, true);
	DisplayMenu(menu, client, MENU_TIME_FOREVER);
	return true;
}

public int MenuHandler_RemoveZoneEffect(Menu menu, MenuAction action, int param1, int param2)
{
	switch (action)
	{
		case MenuAction_Select:
		{
			char sEffect[MAX_EFFECT_NAME_LENGTH];
			GetMenuItem(menu, param2, sEffect, sizeof(sEffect));

			int entity = GetMenuCell(menu, "entity");

			StringMap values;
			GetTrieValue(g_hZoneEffects[entity], sEffect, values);
			delete values;

			RemoveFromTrie(g_hZoneEffects[entity], sEffect);
			OpenEditZoneMenu(param1, entity);
		}

		case MenuAction_Cancel:
		{
			if (param2 == MenuCancel_ExitBack)
			{
				OpenEditZoneMenu(param1, GetMenuCell(menu, "entity"));
			}
		}

		case MenuAction_End:
		{
			CloseHandle(menu);
		}
	}
}

void OpenZoneTypeMenu(int client)
{
	char sAddendum[256];
	FormatEx(sAddendum, sizeof(sAddendum), " for %s", sCreateZone_Name[client]);

	Menu menu = CreateMenu(MenuHandler_ZoneTypeMenu);
	SetMenuTitle(menu, "Choose a zone type%s:", strlen(sCreateZone_Name[client]) > 0 ? sAddendum : "");

	for (int i = 0; i < ZONE_TYPES; i++)
	{
		char sID[12];
		IntToString(i, sID, sizeof(sID));

		char sType[MAX_ZONE_TYPE_LENGTH];
		GetZoneTypeName(i, sType, sizeof(sType));

		AddMenuItem(menu, sID, sType);
	}

	DisplayMenu(menu, client, MENU_TIME_FOREVER);
}

public int MenuHandler_ZoneTypeMenu(Menu menu, MenuAction action, int param1, int param2)
{
	switch (action)
	{
		case MenuAction_Select:
		{
			char sID[12]; char sType[MAX_ZONE_TYPE_LENGTH];
			GetMenuItem(menu, param2, sID, sizeof(sID), _, sType, sizeof(sType));
			int type = StringToInt(sID);

			char sAddendum[256];
			FormatEx(sAddendum, sizeof(sAddendum), " for %s", sCreateZone_Name[param1]);

			iCreateZone_Type[param1] = type;
			CPrintToChat(param1, "Zone type%s set to %s.", sAddendum, sType);
			OpenCreateZonesMenu(param1);
		}

		case MenuAction_Cancel:
		{
			if (param2 == MenuCancel_ExitBack)
			{
				OpenCreateZonesMenu(param1);
			}
		}

		case MenuAction_End:
		{
			CloseHandle(menu);
		}
	}
}

void CreateNewZone(int client)
{
	if (strlen(sCreateZone_Name[client]) == 0)
	{
		CPrintToChat(client, "You must set a zone name in order to create it.");
		OpenCreateZonesMenu(client);
		return;
	}

	KvRewind(kZonesConfig);

	if (KvJumpToKey(kZonesConfig, sCreateZone_Name[client]))
	{
		KvRewind(kZonesConfig);
		CPrintToChat(client, "Zone already exists, please pick a different name.");
		OpenCreateZonesMenu(client);
		return;
	}

	KvJumpToKey(kZonesConfig, sCreateZone_Name[client], true);

	char sType[MAX_ZONE_TYPE_LENGTH];
	GetZoneTypeName(iCreateZone_Type[client], sType, sizeof(sType));
	KvSetString(kZonesConfig, "type", sType);

	switch (iCreateZone_Type[client])
	{
		case ZONE_TYPE_BOX:
		{
			KvSetVector(kZonesConfig, "start", fCreateZone_Start[client]);
			KvSetVector(kZonesConfig, "end", fCreateZone_End[client]);
		}

		case ZONE_TYPE_CIRCLE:
		{
			KvSetVector(kZonesConfig, "start", fCreateZone_Start[client]);
			KvSetFloat(kZonesConfig, "radius", fCreateZone_Radius[client]);
		}
	}

	SaveMapConfig();

	CreateZone(sCreateZone_Name[client], iCreateZone_Type[client], fCreateZone_Start[client], fCreateZone_End[client], fCreateZone_Radius[client]);
	CPrintToChat(client, "Zone '%s' has been created successfully.", sCreateZone_Name[client]);
	bIsViewingZone[client] = false;
}

void ResetCreateZoneVariables(int client)
{
	sCreateZone_Name[client][0] = '\0';
	iCreateZone_Type[client] = ZONE_TYPE_BOX;
	Array_Fill(fCreateZone_Start[client], 3, 0.0);
	Array_Fill(fCreateZone_End[client], 3, 0.0);
	fCreateZone_Radius[client] = 0.0;

	bIsViewingZone[client] = false;
	bSettingName[client] = false;
}

void GetZoneTypeName(int type, char[] buffer, int size)
{
	switch (type)
	{
		case ZONE_TYPE_BOX: strcopy(buffer, size, "Standard");
		case ZONE_TYPE_CIRCLE: strcopy(buffer, size, "Radius/Circle");
	}
}

int GetZoneType(int entity)
{
	char sClassname[64];
	GetEntityClassname(entity, sClassname, sizeof(sClassname));

	if (StrEqual(sClassname, "trigger_multiple"))
	{
		return ZONE_TYPE_BOX;
	}
	else if (StrEqual(sClassname, "info_target"))
	{
		return ZONE_TYPE_CIRCLE;
	}

	return ZONE_TYPE_BOX;
}

int GetZoneNameType(const char[] sType)
{
	if (StrEqual(sType, "Standard"))
	{
		return ZONE_TYPE_BOX;
	}
	else if (StrEqual(sType, "Radius/Circle"))
	{
		return ZONE_TYPE_CIRCLE;
	}

	return ZONE_TYPE_BOX;
}

void SaveMapConfig()
{
	if (kZonesConfig == null)
	{
		return;
	}

	char sMap[32];
	GetCurrentMap(sMap, sizeof(sMap));

	char sPath[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, sPath, sizeof(sPath), "data/zones/%s.cfg", sMap);

	KvRewind(kZonesConfig);
	KeyValuesToFile(kZonesConfig, sPath);
}

public Action Timer_DisplayZones(Handle timer)
{
	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i) && bIsViewingZone[i])
		{
			switch (iCreateZone_Type[i])
			{
				case ZONE_TYPE_BOX:
				{
					Effect_DrawBeamBoxToClient(i, fCreateZone_Start[i], fCreateZone_End[i], iDefaultModelIndex, iDefaultHaloIndex, 0, 30, 0.2, 5.0, 5.0, 2, 1.0, {255, 0, 0, 255}, 0);
				}
				case ZONE_TYPE_CIRCLE:
				{
					TE_SetupBeamRingPoint(fCreateZone_Start[i], fCreateZone_Radius[i], fCreateZone_Radius[i] + 4.0, iDefaultModelIndex, iDefaultHaloIndex, 0, 30, 0.2, 5.0, 0.0, {255, 0, 0, 255}, 0, 0);
					TE_SendToClient(i, 0.0);
				}
			}
		}

		if (IsClientInGame(i) && bShowAllZones[i])
		{
			float vecOrigin[3];
			float vecStart[3];
			float vecEnd[3];

			int entity = INVALID_ENT_INDEX;
			while ((entity = FindEntityByClassname(entity, "*")) != INVALID_ENT_INDEX)
			{
				if (!IsEntityIndex(entity) || !g_bIsZone[entity])
				{
					continue;
				}

				GetEntPropVector(entity, Prop_Data, "m_vecOrigin", vecOrigin);

				switch (GetZoneType(entity))
				{
					case ZONE_TYPE_BOX:
					{
						GetAbsBoundingBox(entity, vecStart, vecEnd);
						Effect_DrawBeamBoxToClient(i, vecStart, vecEnd, iDefaultModelIndex, iDefaultHaloIndex, 0, 30, 0.2, 5.0, 5.0, 2, 1.0, {255, 255, 0, 255}, 0);
					}
					case ZONE_TYPE_CIRCLE:
					{
						TE_SetupBeamRingPoint(vecOrigin, g_fZoneRadius[entity], g_fZoneRadius[entity] + 4.0, iDefaultModelIndex, iDefaultHaloIndex, 0, 30, 0.2, 5.0, 0.0, {255, 255, 0, 255}, 0, 0);
						TE_SendToClient(i, 0.0);
					}
				}
			}
		}
	}
}

void GetAbsBoundingBox(int ent, float mins[3], float maxs[3])
{
    float origin[3];

    GetEntPropVector(ent, Prop_Data, "m_vecOrigin", origin);
    GetEntPropVector(ent, Prop_Data, "m_vecMins", mins);
    GetEntPropVector(ent, Prop_Data, "m_vecMaxs", maxs);

    mins[0] += origin[0];
    mins[1] += origin[1];
    mins[2] += origin[2];

    maxs[0] += origin[0];
    maxs[1] += origin[1];
    maxs[2] += origin[2];
}

void CreateZone(const char[] sName, int type, float start[3], float end[3], float radius)
{
	char sType[MAX_ZONE_TYPE_LENGTH];
	GetZoneTypeName(type, sType, sizeof(sType));

	LogDebug("zonesmanager", "Spawning Zone: %s - %s - %.2f/%.2f/%.2f - %.2f/%.2f/%.2f - %.2f", sName, sType, start[0], start[1], start[2], end[0], end[1], end[2], radius);

	switch (type)
	{
		case ZONE_TYPE_BOX:
		{
			int entity = CreateEntityByName("trigger_multiple");

			if (IsValidEntity(entity))
			{
				DispatchKeyValue(entity, "targetname", sName);
				DispatchKeyValue(entity, "spawnflags", "64");
				DispatchSpawn(entity);
				SetEntProp(entity, Prop_Data, "m_spawnflags", 64);

				float fMiddle[3];
				GetMiddleOfABox(start, end, fMiddle);

				TeleportEntity(entity, fMiddle, NULL_VECTOR, NULL_VECTOR);
				SetEntityModel(entity, sErrorModel);

				// Have the mins always be negative
				start[0] = start[0] - fMiddle[0];
				if(start[0] > 0.0)
				start[0] *= -1.0;
				start[1] = start[1] - fMiddle[1];
				if(start[1] > 0.0)
				start[1] *= -1.0;
				start[2] = start[2] - fMiddle[2];
				if(start[2] > 0.0)
				start[2] *= -1.0;

				// And the maxs always be positive
				end[0] = end[0] - fMiddle[0];
				if(end[0] < 0.0)
				end[0] *= -1.0;
				end[1] = end[1] - fMiddle[1];
				if(end[1] < 0.0)
				end[1] *= -1.0;
				end[2] = end[2] - fMiddle[2];
				if(end[2] < 0.0)
				end[2] *= -1.0;

				SetEntPropVector(entity, Prop_Data, "m_vecMins", start);
				SetEntPropVector(entity, Prop_Data, "m_vecMaxs", end);
				SetEntProp(entity, Prop_Send, "m_nSolidType", 2);

				SDKHook(entity, SDKHook_StartTouchPost, Zones_StartTouch);
				SDKHook(entity, SDKHook_TouchPost, Zones_Touch);
				SDKHook(entity, SDKHook_EndTouchPost, Zones_EndTouch);
				SDKHook(entity, SDKHook_StartTouchPost, Zones_StartTouchPost);
				SDKHook(entity, SDKHook_TouchPost, Zones_TouchPost);
				SDKHook(entity, SDKHook_EndTouchPost, Zones_EndTouchPost);

				g_bIsZone[entity] = true;
				g_fZoneRadius[entity] = radius;

				delete g_hZoneEffects[entity];
				g_hZoneEffects[entity] = CreateTrie();
			}

			LogDebug("zonesmanager", "Zone %s has been spawned %s with the entity index %i.", sName, IsValidEntity(entity) ? "successfully" : "not successfully", entity);
		}

		case ZONE_TYPE_CIRCLE:
		{
			int entity = CreateEntityByName("info_target");

			if (IsValidEntity(entity))
			{
				DispatchKeyValue(entity, "targetname", sName);
				DispatchKeyValueVector(entity, "origin", start);
				DispatchSpawn(entity);

				g_bIsZone[entity] = true;
				g_fZoneRadius[entity] = radius;

				delete g_hZoneEffects[entity];
				g_hZoneEffects[entity] = CreateTrie();
			}

			LogDebug("zonesmanager", "Zone %s has been spawned with the radius %.2f.", sName, radius);
		}
	}
}

Action IsNearRadiusZone(int client, int entity)
{
	char sName[MAX_ZONE_NAME_LENGTH];
	GetEntPropString(entity, Prop_Data, "m_iName", sName, sizeof(sName));

	Action result = Plugin_Continue;

	if (!bInsideRadius[client][entity])
	{
		Call_StartForward(g_Forward_StartTouchZone);
		Call_PushCell(client);
		Call_PushCell(entity);
		Call_PushString(sName);
		Call_PushCell(ZONE_TYPE_CIRCLE);
		Call_Finish(result);

		bInsideRadius[client][entity] = true;
	}
	else
	{
		Call_StartForward(g_Forward_TouchZone);
		Call_PushCell(client);
		Call_PushCell(entity);
		Call_PushString(sName);
		Call_PushCell(ZONE_TYPE_CIRCLE);
		Call_Finish(result);
	}

	return result;
}

Action IsNotNearRadiusZone(int client, int entity)
{
	char sName[MAX_ZONE_NAME_LENGTH];
	GetEntPropString(entity, Prop_Data, "m_iName", sName, sizeof(sName));

	Action result = Plugin_Continue;

	if (bInsideRadius[client][entity])
	{
		Call_StartForward(g_Forward_EndTouchZone);
		Call_PushCell(client);
		Call_PushCell(entity);
		Call_PushString(sName);
		Call_PushCell(ZONE_TYPE_CIRCLE);
		Call_Finish(result);

		bInsideRadius[client][entity] = false;
	}

	return result;
}

void IsNearRadiusZone_Post(int client, int entity)
{
	char sName[MAX_ZONE_NAME_LENGTH];
	GetEntPropString(entity, Prop_Data, "m_iName", sName, sizeof(sName));

	if (!bInsideRadius_Post[client][entity])
	{
		Call_StartForward(g_Forward_StartTouchZone_Post);
		Call_PushCell(client);
		Call_PushCell(entity);
		Call_PushString(sName);
		Call_PushCell(ZONE_TYPE_CIRCLE);
		Call_Finish();

		bInsideRadius_Post[client][entity] = true;
	}
	else
	{
		Call_StartForward(g_Forward_TouchZone_Post);
		Call_PushCell(client);
		Call_PushCell(entity);
		Call_PushString(sName);
		Call_PushCell(ZONE_TYPE_CIRCLE);
		Call_Finish();
	}
}

void IsNotNearRadiusZone_Post(int client, int entity)
{
	char sName[MAX_ZONE_NAME_LENGTH];
	GetEntPropString(entity, Prop_Data, "m_iName", sName, sizeof(sName));

	if (bInsideRadius_Post[client][entity])
	{
		Call_StartForward(g_Forward_EndTouchZone_Post);
		Call_PushCell(client);
		Call_PushCell(entity);
		Call_PushString(sName);
		Call_PushCell(ZONE_TYPE_CIRCLE);
		Call_Finish();

		bInsideRadius_Post[client][entity] = false;
	}
}

public Action Zones_StartTouch(int entity, int other)
{
	if (!g_bIsZone[entity])
	{
		return Plugin_Continue;
	}

	char sName[MAX_ZONE_NAME_LENGTH];
	GetEntPropString(entity, Prop_Data, "m_iName", sName, sizeof(sName));

	Call_StartForward(g_Forward_StartTouchZone);
	Call_PushCell(other);
	Call_PushCell(entity);
	Call_PushString(sName);
	Call_PushCell(ZONE_TYPE_BOX);

	Action result = Plugin_Continue;
	Call_Finish(result);

	return result;
}

public Action Zones_Touch(int entity, int other)
{
	if (!g_bIsZone[entity])
	{
		return Plugin_Continue;
	}

	char sName[MAX_ZONE_NAME_LENGTH];
	GetEntPropString(entity, Prop_Data, "m_iName", sName, sizeof(sName));

	Call_StartForward(g_Forward_TouchZone);
	Call_PushCell(other);
	Call_PushCell(entity);
	Call_PushString(sName);
	Call_PushCell(ZONE_TYPE_BOX);

	Action result = Plugin_Continue;
	Call_Finish(result);

	return result;
}

public Action Zones_EndTouch(int entity, int other)
{
	if (!g_bIsZone[entity])
	{
		return Plugin_Continue;
	}

	char sName[MAX_ZONE_NAME_LENGTH];
	GetEntPropString(entity, Prop_Data, "m_iName", sName, sizeof(sName));

	Call_StartForward(g_Forward_EndTouchZone);
	Call_PushCell(other);
	Call_PushCell(entity);
	Call_PushString(sName);
	Call_PushCell(ZONE_TYPE_BOX);

	Action result = Plugin_Continue;
	Call_Finish(result);

	return result;
}

public void Zones_StartTouchPost(int entity, int other)
{
	if (!g_bIsZone[entity])
	{
		return;
	}

	for (int i = 0; i < GetArraySize(g_hArray_EffectsList); i++)
	{
		char sEffect[MAX_EFFECT_NAME_LENGTH];
		GetArrayString(g_hArray_EffectsList, i, sEffect, sizeof(sEffect));

		Handle callbacks[3];
		if (GetTrieArray(g_hTrie_EffectCalls, sEffect, callbacks, sizeof(callbacks)) && callbacks[EFFECT_CALLBACK_ONENTERZONE] != null && GetForwardFunctionCount(callbacks[EFFECT_CALLBACK_ONENTERZONE]) > 0)
		{
			StringMap values;
			GetTrieValue(g_hZoneEffects[entity], sEffect, values);

			Call_StartForward(callbacks[EFFECT_CALLBACK_ONENTERZONE]);
			Call_PushCell(other);
			Call_PushCell(entity);
			Call_PushCell(values);
			Call_Finish();
		}
	}

	char sName[MAX_ZONE_NAME_LENGTH];
	GetEntPropString(entity, Prop_Data, "m_iName", sName, sizeof(sName));

	Call_StartForward(g_Forward_StartTouchZone_Post);
	Call_PushCell(other);
	Call_PushCell(entity);
	Call_PushString(sName);
	Call_PushCell(ZONE_TYPE_BOX);
	Call_Finish();
}

public void Zones_TouchPost(int entity, int other)
{
	if (!g_bIsZone[entity])
	{
		return;
	}

	for (int i = 0; i < GetArraySize(g_hArray_EffectsList); i++)
	{
		char sEffect[MAX_EFFECT_NAME_LENGTH];
		GetArrayString(g_hArray_EffectsList, i, sEffect, sizeof(sEffect));

		Handle callbacks[3];
		if (GetTrieArray(g_hTrie_EffectCalls, sEffect, callbacks, sizeof(callbacks)) && callbacks[EFFECT_CALLBACK_ONACTIVEZONE] != null && GetForwardFunctionCount(callbacks[EFFECT_CALLBACK_ONACTIVEZONE]) > 0)
		{
			StringMap values;
			GetTrieValue(g_hZoneEffects[entity], sEffect, values);

			Call_StartForward(callbacks[EFFECT_CALLBACK_ONACTIVEZONE]);
			Call_PushCell(other);
			Call_PushCell(entity);
			Call_PushCell(values);
			Call_Finish();
		}
	}

	char sName[MAX_ZONE_NAME_LENGTH];
	GetEntPropString(entity, Prop_Data, "m_iName", sName, sizeof(sName));

	Call_StartForward(g_Forward_TouchZone_Post);
	Call_PushCell(other);
	Call_PushCell(entity);
	Call_PushString(sName);
	Call_PushCell(ZONE_TYPE_BOX);
	Call_Finish();
}

public void Zones_EndTouchPost(int entity, int other)
{
	if (!g_bIsZone[entity])
	{
		return;
	}

	for (int i = 0; i < GetArraySize(g_hArray_EffectsList); i++)
	{
		char sEffect[MAX_EFFECT_NAME_LENGTH];
		GetArrayString(g_hArray_EffectsList, i, sEffect, sizeof(sEffect));

		Handle callbacks[3];
		if (GetTrieArray(g_hTrie_EffectCalls, sEffect, callbacks, sizeof(callbacks)) && callbacks[EFFECT_CALLBACK_ONLEAVEZONE] != null && GetForwardFunctionCount(callbacks[EFFECT_CALLBACK_ONLEAVEZONE]) > 0)
		{
			StringMap values;
			GetTrieValue(g_hZoneEffects[entity], sEffect, values);

			Call_StartForward(callbacks[EFFECT_CALLBACK_ONLEAVEZONE]);
			Call_PushCell(other);
			Call_PushCell(entity);
			Call_PushCell(values);
			Call_Finish();
		}
	}

	char sName[MAX_ZONE_NAME_LENGTH];
	GetEntPropString(entity, Prop_Data, "m_iName", sName, sizeof(sName));

	Call_StartForward(g_Forward_EndTouchZone_Post);
	Call_PushCell(other);
	Call_PushCell(entity);
	Call_PushString(sName);
	Call_PushCell(ZONE_TYPE_BOX);
	Call_Finish();
}

void DeleteZone(int entity)
{
	char sName[MAX_ZONE_NAME_LENGTH];
	GetEntPropString(entity, Prop_Data, "m_iName", sName, sizeof(sName));

	AcceptEntityInput(entity, "Kill");
	g_bIsZone[entity] = false;
	delete g_hZoneEffects[entity];

	KvRewind(kZonesConfig);
	if (KvJumpToKey(kZonesConfig, sName))
	{
		KvDeleteThis(kZonesConfig);
	}

	SaveMapConfig();
}

void RegisterNewEffect(Handle plugin, const char[] name, Function function1 = INVALID_FUNCTION, Function function2 = INVALID_FUNCTION, Function function3 = INVALID_FUNCTION)
{
	if (plugin == null || strlen(name) == 0 || FindStringInArray(g_hArray_EffectsList, name) != -1)
	{
		return;
	}

	Handle callbacks[3];

	if (function1 != INVALID_FUNCTION)
	{
		callbacks[EFFECT_CALLBACK_ONENTERZONE] = CreateForward(ET_Ignore, Param_Cell, Param_Cell, Param_Cell);
		AddToForward(callbacks[EFFECT_CALLBACK_ONENTERZONE], plugin, function1);
	}

	if (function2 != INVALID_FUNCTION)
	{
		callbacks[EFFECT_CALLBACK_ONACTIVEZONE] = CreateForward(ET_Ignore, Param_Cell, Param_Cell, Param_Cell);
		AddToForward(callbacks[EFFECT_CALLBACK_ONACTIVEZONE], plugin, function2);
	}

	if (function3 != INVALID_FUNCTION)
	{
		callbacks[EFFECT_CALLBACK_ONLEAVEZONE] = CreateForward(ET_Ignore, Param_Cell, Param_Cell, Param_Cell);
		AddToForward(callbacks[EFFECT_CALLBACK_ONLEAVEZONE], plugin, function3);
	}

	SetTrieArray(g_hTrie_EffectCalls, name, callbacks, sizeof(callbacks));
	PushArrayString(g_hArray_EffectsList, name);
}

//STOCKS STOCKS STOCKS STOCKS NOT SANTA
stock void PogChamp(float fMins[3], float fMiddle[3])
{
	fMins[0] = fMins[0] - fMiddle[0];
	if(fMins[0] > 0.0)
		fMins[0] *= -1.0;
	fMins[1] = fMins[1] - fMiddle[1];
	if(fMins[1] > 0.0)
		fMins[1] *= -1.0;
	fMins[2] = fMins[2] - fMiddle[2];
	if(fMins[2] > 0.0)
		fMins[2] *= -1.0;
}

void GetMiddleOfABox(const float vec1[3], const float vec2[3], float buffer[3])
{
	float mid[3];
	MakeVectorFromPoints(vec1, vec2, mid);
	mid[0] = mid[0] / 2.0;
	mid[1] = mid[1] / 2.0;
	mid[2] = mid[2] / 2.0;
	AddVectors(vec1, mid, buffer);
}

bool GetClientLookPoint(int client, float lookposition[3])
{
	float vEyePos[3];
	GetClientEyePosition(client, vEyePos);

	float vEyeAng[3];
	GetClientEyeAngles(client, vEyeAng);

	Handle hTrace = TR_TraceRayFilterEx(vEyePos, vEyeAng, MASK_SHOT, RayType_Infinite, TraceEntityFilter_NoPlayers);
	bool bHit = TR_DidHit(hTrace);

	TR_GetEndPosition(lookposition, hTrace);

	CloseHandle(hTrace);
	return bHit;
}

public bool TraceEntityFilter_NoPlayers(int entity, int contentsMask)
{
	return false;
}

stock void Array_Fill(any[] array, int size, any value, int start = 0)
{
	if (start < 0)
	{
		start = 0;
	}

	for (int i = start; i < size; i++)
	{
		array[i] = value;
	}
}

stock void Array_Copy(const any[] array, any[] newArray, int size)
{
	for (int i = 0; i < size; i++)
	{
		newArray[i] = array[i];
	}
}

stock void Effect_DrawBeamBoxToClient(int client, const float bottomCorner[3], const float upperCorner[3], int modelIndex, int haloIndex, int startFrame = 0, int frameRate = 30, float life = 5.0, float width = 5.0, float endWidth = 5.0, int fadeLength = 2, float amplitude = 1.0, const color[4] = {255, 0, 0, 255}, int speed = 0)
{
    int clients[1];
    clients[0] = client;
    Effect_DrawBeamBox(clients, 1, bottomCorner, upperCorner, modelIndex, haloIndex, startFrame, frameRate, life, width, endWidth, fadeLength, amplitude, color, speed);
}

stock void Effect_DrawBeamBoxToAll(const float bottomCorner[3], const float upperCorner[3], int modelIndex, int haloIndex, int startFrame = 0, int frameRate = 30, float life = 5.0, float width = 5.0, float endWidth = 5.0, int fadeLength = 2, float amplitude = 1.0, const color[4] = {255, 0, 0, 255}, int speed = 0)
{
	int clients[MaxClients];
	int numClients;

	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i))
		{
			clients[numClients++] = i;
		}
	}

	Effect_DrawBeamBox(clients, numClients, bottomCorner, upperCorner, modelIndex, haloIndex, startFrame, frameRate, life, width, endWidth, fadeLength, amplitude, color, speed);
}

stock void Effect_DrawBeamBox(int[] clients,int numClients, const float bottomCorner[3], const float upperCorner[3], int modelIndex, int haloIndex, int startFrame = 0, int frameRate = 30, float life = 5.0, float width = 5.0, float endWidth = 5.0, int fadeLength = 2, float amplitude = 1.0, const color[4] = {255, 0, 0, 255}, int speed = 0)
{
	float corners[8][3];

	for (int i = 0; i < 4; i++)
	{
		Array_Copy(bottomCorner, corners[i], 3);
		Array_Copy(upperCorner, corners[i + 4], 3);
	}

	corners[1][0] = upperCorner[0];
	corners[2][0] = upperCorner[0];
	corners[2][1] = upperCorner[1];
	corners[3][1] = upperCorner[1];
	corners[4][0] = bottomCorner[0];
	corners[4][1] = bottomCorner[1];
	corners[5][1] = bottomCorner[1];
	corners[7][0] = bottomCorner[0];

	for (int i = 0; i < 4; i++)
	{
		int j = ( i == 3 ? 0 : i+1 );
		TE_SetupBeamPoints(corners[i], corners[j], modelIndex, haloIndex, startFrame, frameRate, life, width, endWidth, fadeLength, amplitude, color, speed);
		TE_Send(clients, numClients);
	}

	for (int i = 4; i < 8; i++)
	{
		int j = ( i == 7 ? 4 : i+1 );
		TE_SetupBeamPoints(corners[i], corners[j], modelIndex, haloIndex, startFrame, frameRate, life, width, endWidth, fadeLength, amplitude, color, speed);
		TE_Send(clients, numClients);
	}

	for (int i = 0; i < 4; i++)
	{
		TE_SetupBeamPoints(corners[i], corners[i+4], modelIndex, haloIndex, startFrame, frameRate, life, width, endWidth, fadeLength, amplitude, color, speed);
		TE_Send(clients, numClients);
	}
}

//Natives
public int Native_Register_Effect(Handle plugin, int numParams)
{
	int size;
	GetNativeStringLength(1, size);

	char[] sEffect = new char[size + 1];
	GetNativeString(1, sEffect, size + 1);

	Function function1 = GetNativeFunction(2);
	Function function2 = GetNativeFunction(3);
	Function function3 = GetNativeFunction(4);

	RegisterNewEffect(plugin, sEffect, function1, function2, function3);
}
