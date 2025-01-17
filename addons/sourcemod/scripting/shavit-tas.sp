/*
 * shavit's Timer - TAS
 * by: xutaxkamay, KiD Fearless, rtldg
 *
 * This file is part of shavit's Timer.
 *
 * This program is free software; you can redistribute it and/or modify it under
 * the terms of the GNU General Public License, version 3.0, as published by the
 * Free Software Foundation.
 *
 * This program is distributed in the hope that it will be useful, but WITHOUT
 * ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
 * FOR A PARTICULAR PURPOSE.  See the GNU General Public License for more
 * details.
 *
 * You should have received a copy of the GNU General Public License along with
 * this program.  If not, see <http://www.gnu.org/licenses/>.
 *
 */

#include <sourcemod>
#include <sdktools>
#include <cstrike>
#include <convar_class>

#include <shavit/core>
#include <shavit/tas>
#include <shavit/tas-oblivious>
#include <shavit/tas-xutax>

#undef REQUIRE_PLUGIN
#include <shavit/checkpoints>
#include <shavit/zones>

#pragma newdecls required
#pragma semicolon 1

bool gB_Late = false;
EngineVersion gEV_Type = Engine_Unknown;

float g_flAirSpeedCap = 30.0;
float g_flOldYawAngle[MAXPLAYERS + 1];
int g_iSurfaceFrictionOffset;
float g_fMaxMove = 400.0;

bool g_bEnabled[MAXPLAYERS + 1];
TASType gI_Type[MAXPLAYERS + 1];
TASOverride gI_Override[MAXPLAYERS + 1];
bool gB_Prestrafe[MAXPLAYERS + 1];
bool gB_AutoJumpOnStart[MAXPLAYERS + 1];
float g_fPower[MAXPLAYERS + 1] = {1.0, ...};

bool gB_ForceJump[MAXPLAYERS+1];

Convar gCV_AutoFindOffsets = null;
ConVar sv_airaccelerate = null;
ConVar sv_accelerate = null;
ConVar sv_friction = null;
ConVar sv_stopspeed = null;

public Plugin myinfo =
{
	name = "[shavit] TAS (XutaxKamay)",
	author = "xutaxkamay, oblivious, KiD Fearless, rtldg",
	description = "TAS module for shavit's bhop timer featuring xutaxkamay's autostrafer and oblivious's autogain.",
	version = SHAVIT_VERSION,
	url = "https://github.com/shavitush/bhoptimer"
};

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
	CreateNative("Shavit_SetAutostrafeEnabled", Native_SetAutostrafeEnabled);
	CreateNative("Shavit_GetAutostrafeEnabled", Native_GetAutostrafeEnabled);
	CreateNative("Shavit_SetAutostrafeType", Native_SetAutostrafeType);
	CreateNative("Shavit_GetAutostrafeType", Native_GetAutostrafeType);
	CreateNative("Shavit_SetAutostrafePower", Native_SetAutostrafePower);
	CreateNative("Shavit_GetAutostrafePower", Native_GetAutostrafePower);
	CreateNative("Shavit_SetAutostrafeKeyOverride", Native_SetAutostrafeKeyOverride);
	CreateNative("Shavit_GetAutostrafeKeyOverride", Native_GetAutostrafeKeyOverride);
	CreateNative("Shavit_SetAutoPrestrafe", Native_SetAutoPrestrafe);
	CreateNative("Shavit_GetAutoPrestrafe", Native_GetAutoPrestrafe);
	CreateNative("Shavit_SetAutoJumpOnStart", Native_SetAutoJumpOnStart);
	CreateNative("Shavit_GetAutoJumpOnStart", Native_GetAutoJumpOnStart);

	gB_Late = late;
	RegPluginLibrary("shavit-tas");
	return APLRes_Success;
}

public void OnPluginStart()
{
	LoadTranslations("shavit-common.phrases");
	LoadTranslations("shavit-misc.phrases");

	gEV_Type = GetEngineVersion();
	sv_airaccelerate = FindConVar("sv_airaccelerate");
	sv_accelerate = FindConVar("sv_accelerate");
	sv_friction = FindConVar("sv_friction");
	sv_stopspeed = FindConVar("sv_stopspeed");

	GameData gamedata = new GameData("shavit.games");

	if ((g_iSurfaceFrictionOffset = gamedata.GetOffset("m_surfaceFriction")) == -1)
	{
		LogError("[XUTAX] Invalid offset supplied, defaulting friction values");
	}

	delete gamedata;

	if (gEV_Type == Engine_CSGO)
	{
		g_fMaxMove = 450.0;
		ConVar sv_air_max_wishspeed = FindConVar("sv_air_max_wishspeed");
		sv_air_max_wishspeed.AddChangeHook(OnWishSpeedChanged);
		g_flAirSpeedCap = sv_air_max_wishspeed.FloatValue;

		if (g_iSurfaceFrictionOffset != -1)
		{
			g_iSurfaceFrictionOffset = FindSendPropInfo("CBasePlayer", "m_ubEFNoInterpParity") - g_iSurfaceFrictionOffset;
		}
	}
	else
	{
		if (g_iSurfaceFrictionOffset != -1)
		{
			g_iSurfaceFrictionOffset += FindSendPropInfo("CBasePlayer", "m_szLastPlaceName");
		}
	}

	RegConsoleCmd("sm_tasm", Command_TasSettingsMenu, "Opens the TAS settings menu.");
	RegConsoleCmd("sm_tasmenu", Command_TasSettingsMenu, "Opens the TAS settings menu.");
	RegAdminCmd("sm_xutax_scan", Command_ScanOffsets, ADMFLAG_CHEATS, "Scan for possible offset locations");

	gCV_AutoFindOffsets = new Convar("xutax_find_offsets", "1", "Attempt to autofind offsets", _, true, 0.0, true, 1.0);

	Convar.AutoExecConfig();

	if (gB_Late)
	{
		for (int i = 1; i <= MaxClients; i++)
		{
			if (IsClientConnected(i))
			{
				OnClientConnected(i);
			}
		}
	}
}

// doesn't exist in css so we have to cache the value
public void OnWishSpeedChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
	g_flAirSpeedCap = StringToFloat(newValue);
}

public void OnClientConnected(int client)
{
	g_bEnabled[client] = true;
	gI_Override[client] = TASOverride_Surf;
	gI_Type[client] = TASType_1Tick;
	gB_AutoJumpOnStart[client] = true;
	gB_Prestrafe[client] = true;
	g_fPower[client] = 1.0;
}

public void Shavit_OnLeaveZone(int client, int type, int track, int id, int entity, int data)
{
	if (!IsValidClient(client, true) || IsFakeClient(client))
	{
		return;
	}

	if (!Shavit_GetStyleSettingBool(Shavit_GetBhopStyle(client), TAS_STYLE_SETTING))
	{
		return;
	}

	if (Shavit_GetTimerStatus(client) != Timer_Running)
	{
		return;
	}

	if (type == Zone_Start)
	{
		if (GetEntityFlags(client) & FL_ONGROUND)
		{
			if (gB_AutoJumpOnStart[client])
			{
				gB_ForceJump[client] = true;
			}
		}
	}
}

int FindMenuItem(Menu menu, const char[] info)
{
	for (int i = 0; i < menu.ItemCount; i++)
	{
		char sInfo[64];
		menu.GetItem(i, sInfo, sizeof(sInfo));

		if (StrEqual(info, sInfo))
		{
			return i;
		}
	}

	return -1;
}

public Action Shavit_OnCheckpointMenuMade(int client, bool segmented, Menu menu)
{
	if (!Shavit_GetStyleSettingBool(Shavit_GetBhopStyle(client), TAS_STYLE_SETTING))
	{
		return Plugin_Continue;
	}

	char sDisplay[64];
	bool tas_timescale = (Shavit_GetStyleSettingFloat(Shavit_GetBhopStyle(client), "tas_timescale") == -1.0);
	int delcurrentcheckpoint = -1;

	if (tas_timescale)
	{
		if ((delcurrentcheckpoint = FindMenuItem(menu, "del")) != -1)
		{
			menu.RemoveItem(delcurrentcheckpoint);
		}
	}

	FormatEx(sDisplay, 64, "%T\n ", "TasSettings", client);
	menu.AddItem("tassettings", sDisplay);
	//menu.ExitButton = false;

	if (delcurrentcheckpoint != -1)
	{
		FormatEx(sDisplay, 64, "%T", "MiscCheckpointDeleteCurrent", client);
		menu.AddItem("del", sDisplay, (Shavit_GetTotalCheckpoints(client) > 0) ? ITEMDRAW_DEFAULT:ITEMDRAW_DISABLED);
	}

	return Plugin_Changed;
}

public Action Shavit_OnCheckpointMenuSelect(int client, int param2, char[] info, int maxlength, int currentCheckpoint, int maxCPs)
{
	if (!Shavit_GetStyleSettingBool(Shavit_GetBhopStyle(client), TAS_STYLE_SETTING))
	{
		return Plugin_Continue;
	}

	if (StrEqual(info, "tassettings"))
	{
		OpenTasSettingsMenu(client);
		return Plugin_Stop;
	}

	return Plugin_Continue;
}

// TODO: Not good enough. Need to jump earlier to get 0.0 offset...
public Action Shavit_OnUserCmdPre(int client, int &buttons, int &impulse, float vel[3], float angles[3], TimerStatus status, int track, int style, int mouse[2])
{
	if (!Shavit_ShouldProcessFrame(client))
	{
		return Plugin_Continue;
	}

	if (gB_ForceJump[client] && status == Timer_Running && Shavit_GetStyleSettingBool(style, TAS_STYLE_SETTING))
	{
		buttons |= IN_JUMP;
	}

	gB_ForceJump[client] = false;
	return Plugin_Changed;
}

public Action OnPlayerRunCmd(int client, int& buttons, int& impulse, float vel[3], float angles[3], int& weapon, int& subtype, int& cmdnum, int& tickcount, int& seed, int mouse[2])
{
	if (!g_bEnabled[client])
	{
		return Plugin_Continue;
	}

	if (IsFakeClient(client))
	{
		return Plugin_Continue;
	}

	TASType tastype = view_as<TASType>(Shavit_GetStyleSettingInt(Shavit_GetBhopStyle(client), TAS_STYLE_SETTING));

	if (!tastype)
	{
		return Plugin_Continue;
	}

	if (tastype == TASType_Any)
	{
		tastype = gI_Type[client];
	}

	if (!Shavit_ShouldProcessFrame(client))
	{
		return Plugin_Continue;
	}

	if (!IsPlayerAlive(client) || GetEntityMoveType(client) == MOVETYPE_NOCLIP || GetEntityMoveType(client) == MOVETYPE_LADDER || !(GetEntProp(client, Prop_Data, "m_nWaterLevel") <= 1))
	{
		return Plugin_Continue;
	}

	static int s_iOnGroundCount[MAXPLAYERS+1] = {1, ...};

	if (GetEntPropEnt(client, Prop_Send, "m_hGroundEntity") != -1)
	{
		s_iOnGroundCount[client]++;
	}
	else
	{
		s_iOnGroundCount[client] = 0;

#if 0
		if (buttons & IN_FORWARD)
		{
			buttons &= ~IN_FORWARD;
			vel[0] = 0.0;
		}
#endif
	}

	float flSurfaceFriction = 1.0;

	if (g_iSurfaceFrictionOffset > 0)
	{
		flSurfaceFriction = GetEntDataFloat(client, g_iSurfaceFrictionOffset);

		if (gCV_AutoFindOffsets.BoolValue && s_iOnGroundCount[client] == 0 && !(flSurfaceFriction == 0.25 || flSurfaceFriction == 1.0))
		{
			FindNewFrictionOffset(client);
		}
	}

	if (s_iOnGroundCount[client] <= 1)
	{
		if (IsSurfing(client))
		{
			return Plugin_Continue;
		}

		if (tastype != TASType_Autogain && tastype != TASType_AutogainNoSpeedLoss)
		{
			if (!!(buttons & (IN_FORWARD | IN_BACK)))
			{
				return Plugin_Continue;
			}

			if (!!(buttons & (IN_MOVERIGHT | IN_MOVELEFT)))
			{
				if (gI_Override[client] == TASOverride_All)
				{
					return Plugin_Continue;
				}
				/*
				else if (gI_Override[client] == TASOverride_Surf && IsSurfing(client))
				{
					return Plugin_Continue;
				}
				*/
			}
		}

		if (tastype == TASType_1Tick)
		{
			XutaxOnPlayerRunCmd(client, buttons, impulse, vel, angles, weapon, subtype, cmdnum, tickcount, seed, mouse,
				sv_airaccelerate.FloatValue, flSurfaceFriction, g_flAirSpeedCap, g_fMaxMove, g_flOldYawAngle[client], g_fPower[client]);
		}
		else if (tastype == TASType_Autogain || tastype == TASType_AutogainNoSpeedLoss)
		{
			ObliviousOnPlayerRunCmd(client, buttons, impulse, vel, angles, weapon, subtype, cmdnum, tickcount, seed, mouse,
				sv_airaccelerate.FloatValue, flSurfaceFriction, g_flAirSpeedCap, g_fMaxMove,
				(tastype == TASType_AutogainNoSpeedLoss));
		}
	}
	else
	{
		if (gB_Prestrafe[client] && (vel[0] != 0.0 || vel[1] != 0.0))
		{
			float _delta_opt = ground_delta_opt(client, angles, vel, flSurfaceFriction,
				sv_accelerate.FloatValue, sv_friction.FloatValue, sv_stopspeed.FloatValue);

			float _tmp[3]; _tmp[0] = angles[0]; _tmp[2] = angles[2];
			_tmp[1] = normalize_yaw(angles[1] - _delta_opt);

			angles[1] = _tmp[1];
		}

		//return Plugin_Continue; // maybe??
	}

	g_flOldYawAngle[client] = angles[1];

	return Plugin_Continue;
}

stock void FindNewFrictionOffset(int client, bool logOnly = false)
{
	if (gEV_Type == Engine_CSGO)
	{
		int startingOffset = FindSendPropInfo("CBasePlayer", "m_ubEFNoInterpParity");
		for (int i = 16; i >= -128; --i)
		{
			float friction = GetEntDataFloat(client, startingOffset + i);
			if (friction == 0.25 || friction == 1.0)
			{
				if (logOnly)
				{
					PrintToConsole(client, "Found offset canidate: %i", i * -1);
				}
				else
				{
					g_iSurfaceFrictionOffset = startingOffset - i;
					LogError("[XUTAX] Current offset is out of date. Please update to new offset: %i", i * -1);
				}
			}
		}
	}
	else
	{
		int startingOffset = FindSendPropInfo("CBasePlayer", "m_szLastPlaceName");
		for (int i = 1; i <= 128; ++i)
		{
			float friction = GetEntDataFloat(client, startingOffset + i);
			if (friction == 0.25 || friction == 1.0)
			{
				if(logOnly)
				{
					PrintToConsole(client, "Found offset canidate: %i", i);
				}
				else
				{
					g_iSurfaceFrictionOffset = startingOffset + i;
					LogError("[XUTAX] Current offset is out of date. Please update to new offset: %i", i);
				}
			}
		}
	}
}

void OpenTasSettingsMenu(int client)
{
	char display[64];
	Menu menu = new Menu(MenuHandler_TasSettings, MENU_ACTIONS_DEFAULT);
	menu.SetTitle("%T\n ", "TasSettings", client);

	FormatEx(display, sizeof(display), "[%s] %T", g_bEnabled[client] ? "＋":"－", "Autostrafer", client);
	menu.AddItem("toggle", display);

	FormatEx(display, sizeof(display), "[%s] %T", gB_AutoJumpOnStart[client] ? "＋":"－", "JumpOnStart", client);
	menu.AddItem("autojump", display);

	FormatEx(display, sizeof(display), "[%s] %T\n ", gB_Prestrafe[client] ? "＋":"－", "AutoPrestrafe", client);
	menu.AddItem("prestrafe", display);

	TASType tastype = view_as<TASType>(Shavit_GetStyleSettingInt(Shavit_GetBhopStyle(client), TAS_STYLE_SETTING));
	bool tastype_editable = (tastype == TASType_Any);
	tastype = (tastype == TASType_Any) ? gI_Type[client] : tastype;

	FormatEx(display, sizeof(display), "%T: %T\n ", "Autostrafer_type", client,
		(tastype == TASType_1Tick ? "Autostrafer_1tick" : "Autostrafer_autogain"), client);
	menu.AddItem("type", display, (tastype_editable ? ITEMDRAW_DEFAULT : ITEMDRAW_DISABLED));

	TASOverride ov = gI_Override[client];
	FormatEx(display, sizeof(display), "%T: %T", "TASOverride", client,
		(ov == TASOverride_Normal ? "TASOverride_Normal" : (ov == TASOverride_Surf ? "TASOverride_Surf" : "TASOverride_All")), client);
	menu.AddItem("override", display);

	if (Shavit_GetStyleSettingBool(Shavit_GetBhopStyle(client), "segments"))
	{
		menu.ExitBackButton = true;
	}
	else
	{
		menu.ExitButton = true;
	}

	menu.Display(client, MENU_TIME_FOREVER);
}

public int MenuHandler_TasSettings(Menu menu, MenuAction action, int param1, int param2)
{
	if (action == MenuAction_Select)
	{
		char info[16];
		menu.GetItem(param2, info, sizeof(info));

		if (StrEqual(info, "toggle"))
		{
			g_bEnabled[param1] = !g_bEnabled[param1];
		}
		else if (StrEqual(info, "autojump"))
		{
			gB_AutoJumpOnStart[param1] = !gB_AutoJumpOnStart[param1];
		}
		else if (StrEqual(info, "prestrafe"))
		{
			gB_Prestrafe[param1] = !gB_Prestrafe[param1];
		}
		else if (StrEqual(info, "type"))
		{
			TASType tastype = view_as<TASType>(Shavit_GetStyleSettingInt(Shavit_GetBhopStyle(param1), TAS_STYLE_SETTING));

			if (tastype == TASType_Any)
			{
				gI_Type[param1] = (gI_Type[param1] == TASType_1Tick ? TASType_Autogain : TASType_1Tick);
			}
		}
		else if (StrEqual(info, "override"))
		{
			if (gI_Override[param1] == TASOverride_Normal)
			{
				gI_Override[param1] = TASOverride_Surf;
			}
			else if (gI_Override[param1] == TASOverride_Surf)
			{
				gI_Override[param1] = TASOverride_All;
			}
			else
			{
				gI_Override[param1] = TASOverride_Normal;
			}
		}

		OpenTasSettingsMenu(param1);
	}
	else if (action == MenuAction_Cancel && param2 == MenuCancel_ExitBack)
	{
		FakeClientCommandEx(param1, "sm_cp");
	}
	else if (action == MenuAction_End)
	{
		delete menu;
	}

	return 0;
}

public Action Command_TasSettingsMenu(int client, int args)
{
	if (IsValidClient(client))
	{
		OpenTasSettingsMenu(client);
	}

	return Plugin_Handled;
}

public Action Command_ScanOffsets(int client, int args)
{
	FindNewFrictionOffset(client, .logOnly = true);

	return Plugin_Handled;
}

// natives
public any Native_SetAutostrafeEnabled(Handle plugin, int numParams)
{
	int client = GetNativeCell(1);
	bool value = GetNativeCell(2);
	g_bEnabled[client] = value;
	return 0;
}

public any Native_GetAutostrafeEnabled(Handle plugin, int numParams)
{
	int client = GetNativeCell(1);
	return g_bEnabled[client];
}

public any Native_SetAutostrafeType(Handle plugin, int numParams)
{
	int client = GetNativeCell(1);
	TASType value = view_as<TASType>(GetNativeCell(2));
	gI_Type[client] = value;
	return 0;
}

public any Native_GetAutostrafeType(Handle plugin, int numParams)
{
	int client = GetNativeCell(1);
	return gI_Type[client];
}

public any Native_SetAutostrafePower(Handle plugin, int numParams)
{
	int client = GetNativeCell(1);
	float value = GetNativeCell(2);
	g_fPower[client] = value;
	return 0;
}

public any Native_GetAutostrafePower(Handle plugin, int numParams)
{
	int client = GetNativeCell(1);
	return g_fPower[client];
}

public any Native_SetAutostrafeKeyOverride(Handle plugin, int numParams)
{
	int client = GetNativeCell(1);
	TASOverride value = view_as<TASOverride>(GetNativeCell(2));
	gI_Override[client] = value;
	return 0;
}

public any Native_GetAutostrafeKeyOverride(Handle plugin, int numParams)
{
	int client = GetNativeCell(1);
	return gI_Override[client];
}

public any Native_SetAutoPrestrafe(Handle plugin, int numParams)
{
	int client = GetNativeCell(1);
	bool value = GetNativeCell(2);
	gB_Prestrafe[client] = value;
	return 0;
}

public any Native_GetAutoPrestrafe(Handle plugin, int numParams)
{
	int client = GetNativeCell(1);
	return gB_Prestrafe[client];
}

public any Native_SetAutoJumpOnStart(Handle plugin, int numParams)
{
	int client = GetNativeCell(1);
	bool value = GetNativeCell(2);
	gB_AutoJumpOnStart[client] = value;
	return 0;
}

public any Native_GetAutoJumpOnStart(Handle plugin, int numParams)
{
	int client = GetNativeCell(1);
	return gB_AutoJumpOnStart[client];
}
