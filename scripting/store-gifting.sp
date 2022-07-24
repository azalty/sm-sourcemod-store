#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdkhooks>
#include <sdktools>
#include <adminmenu>
#include <store>
#include <colors>

#define MAX_CREDIT_CHOICES 100

enum struct Present
{
	int Present_Owner;
	char Present_Data[64];
}

enum GiftAction
{
	GiftAction_Send,
	GiftAction_Drop
}

enum GiftType
{
	GiftType_Credits,
	GiftType_Item
}

enum struct GiftRequest
{
	bool GiftRequestActive;
	int GiftRequestSender;
	GiftType GiftRequestType;
	int GiftRequestValue;
}

char g_currencyName[64];
char g_menuCommands[32][32];

int g_creditChoices[MAX_CREDIT_CHOICES];
GiftRequest g_giftRequests[MAXPLAYERS+1];

Present g_spawnedPresents[2048];
char g_itemModel[32];
char g_creditsModel[32];
bool g_drop_enabled;

char g_game[32];

public Plugin myinfo =
{
	name        = "[Store] Gifting",
	author      = "alongub, drixevel",
	description = "Gifting component for [Store]",
	version     = STORE_VERSION,
	url         = "https://github.com/drixevel-dev/store"
};

/**
 * Plugin is loading.
 */
public void OnPluginStart()
{
	GetGameFolderName(g_game, sizeof(g_game));
	LoadConfig();

	LoadTranslations("common.phrases");
	LoadTranslations("store.phrases");

	Store_AddMainMenuItem("Gift", "Gift Description", _, OnMainMenuGiftClick, 5);
	
	RegConsoleCmd("sm_gift", Command_OpenGifting);
	RegConsoleCmd("sm_accept", Command_Accept);

	if (g_drop_enabled)
	{
		RegConsoleCmd("sm_drop", Command_Drop);
	}

	HookEvent("player_disconnect", Event_PlayerDisconnect);
}

/**
 * Configs just finished getting executed.
 */
public void OnConfigsExecuted()
{    
	Store_GetCurrencyName(g_currencyName, sizeof(g_currencyName));
}

/**
 * Load plugin config.
 */
void LoadConfig() 
{
	KeyValues kv = new KeyValues("root");
	
	char path[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, path, sizeof(path), "configs/store/gifting.cfg");
	
	if (!kv.ImportFromFile(path)) 
	{
		delete kv;
		SetFailState("Can't read config file %s", path);
	}

	char menuCommands[255];
	kv.GetString("gifting_commands", menuCommands, sizeof(menuCommands));
	ExplodeString(menuCommands, " ", g_menuCommands, sizeof(g_menuCommands), sizeof(g_menuCommands[]));
	
	char creditChoices[MAX_CREDIT_CHOICES][10];

	char creditChoicesString[255];
	kv.GetString("credits_choices", creditChoicesString, sizeof(creditChoicesString));

	int choices = ExplodeString(creditChoicesString, " ", creditChoices, sizeof(creditChoices), sizeof(creditChoices[]));
	for (int choice = 0; choice < choices; choice++)
		g_creditChoices[choice] = StringToInt(creditChoices[choice]);

	g_drop_enabled = view_as<bool>(kv.GetNum("drop_enabled", 0));

	if (g_drop_enabled)
	{
		kv.GetString("itemModel", g_itemModel, sizeof(g_itemModel), "");
		kv.GetString("creditsModel", g_creditsModel, sizeof(g_creditsModel), "");

		if (!g_itemModel[0] || !FileExists(g_itemModel, true))
		{
			if(StrEqual(g_game, "cstrike"))
			{
				strcopy(g_itemModel,sizeof(g_itemModel), "models/items/cs_gift.mdl");
			}
			else if (StrEqual(g_game, "tf"))
			{
				strcopy(g_itemModel,sizeof(g_itemModel), "models/items/tf_gift.mdl");
			}
			else if (StrEqual(g_game, "dod"))
			{
				strcopy(g_itemModel,sizeof(g_itemModel), "models/items/dod_gift.mdl");
			}
			else
				g_drop_enabled = false;
		}
		
		if (g_drop_enabled && (!g_creditsModel[0] || !FileExists(g_creditsModel, true))) 
		{
			// if the credits model can't be found, use the item model
			strcopy(g_creditsModel,sizeof(g_creditsModel),g_itemModel);
		}
	}

	delete kv;
}

public void OnMapStart()
{
	if(g_drop_enabled) // false if the files are not found
	{
		PrecacheModel(g_itemModel, true);
		AddFileToDownloadsTable(g_itemModel);

		if (!StrEqual(g_itemModel, g_creditsModel))
		{
			PrecacheModel(g_creditsModel, true);
			AddFileToDownloadsTable(g_creditsModel);
		}
	}
}

public Action Command_Drop(int client, int args)
{
	if (args == 0)
	{
		ReplyToCommand(client, "%sUsage: sm_drop <%s>", STORE_PREFIX, g_currencyName);
		return Plugin_Handled;
	}

	char sCredits[10];
	GetCmdArg(1, sCredits, sizeof(sCredits));

	int credits = StringToInt(sCredits);

	if (credits < 1)
	{
		ReplyToCommand(client, "%s%d is not a valid amount!", STORE_PREFIX, credits);
		return Plugin_Handled;
	}

	DataPack pack = new DataPack();
	pack.WriteCell(client);
	pack.WriteCell(credits);

	Store_GetCredits(GetSteamAccountID(client), DropGetCreditsCallback, pack);
	return Plugin_Handled;
}

public void DropGetCreditsCallback(int credits, DataPack pack)
{
	pack.Reset();

	int client = pack.ReadCell();
	int needed = pack.ReadCell();

	if (credits >= needed)
	{
		Store_GiveCredits(GetSteamAccountID(client), -needed, DropGiveCreditsCallback, pack);
	}
	else
	{
		delete pack;
		PrintToChat(client, "%s%t", STORE_PREFIX, "Not enough credits", g_currencyName);
	}
}

public void DropGiveCreditsCallback(int accountId, DataPack pack)
{
	pack.Reset();

	int client = pack.ReadCell();
	int credits = pack.ReadCell();

	delete pack;

	char value[32];
	Format(value, sizeof(value), "credits,%d", credits);

	CPrintToChat(client, "%s%t", STORE_PREFIX, "Gift Credits Dropped", credits, g_currencyName);

	int present;
	if((present = SpawnPresent(client, g_creditsModel)) != -1)
	{
		strcopy(g_spawnedPresents[present].Present_Data, 64, value);
		g_spawnedPresents[present].Present_Owner = client;
	}
}

public void OnMainMenuGiftClick(int client, const char[] value)
{
	OpenGiftingMenu(client);
}

public Action Event_PlayerDisconnect(Event event, const char[] name, bool dontBroadcast) 
{ 
	g_giftRequests[GetClientOfUserId(event.GetInt("userid"))].GiftRequestActive = false;
	return Plugin_Continue;
}

public Action OnClientSayCommand(int client, const char[] command, const char[] sArgs)
{
	char text[256];
	strcopy(text, sizeof(text), sArgs);
	StripQuotes(text);
	
	for (int index = 0; index < sizeof(g_menuCommands); index++) 
	{
		if (StrEqual(g_menuCommands[index], text))
		{
			OpenGiftingMenu(client);
			
			if (text[0] == 0x2F)
				return Plugin_Handled;
			
			return Plugin_Continue;
		}
	}
	
	return Plugin_Continue;
}

public Action Command_OpenGifting(int client, int args)
{
	OpenGiftingMenu(client);
	return Plugin_Handled;
}

/**
 * Opens the gifting menu for a client.
 *
 * @param client			Client index.
 *
 * @noreturn
 */
void OpenGiftingMenu(int client)
{
	Menu menu = new Menu(GiftTypeMenuSelectHandle);
	menu.SetTitle("%T", "Gift Type Menu Title", client);

	char item[32];
	Format(item, sizeof(item), "%T", "Item", client);

	menu.AddItem("credits", g_currencyName);
	menu.AddItem("item", item);

	menu.Display(client, MENU_TIME_FOREVER);
}

public int GiftTypeMenuSelectHandle(Menu menu, MenuAction action, int client, int slot)
{
	switch (action) {
		case MenuAction_Select: {
			char giftType[10];
			
			if (menu.GetItem(slot, giftType, sizeof(giftType)))
			{
				if (StrEqual(giftType, "credits"))
				{
					if (g_drop_enabled)
					{
						OpenChooseActionMenu(client, GiftType_Credits);
					}
					else
					{
						OpenChoosePlayerMenu(client, GiftType_Credits);
					}
				}
				else if (StrEqual(giftType, "item"))
				{
					if (g_drop_enabled)
					{
						OpenChooseActionMenu(client, GiftType_Item);
					}
					else
					{
						OpenChoosePlayerMenu(client, GiftType_Item);
					}
				}
			}
		}
		case MenuAction_Cancel: {
			if (slot == MenuCancel_Exit)
			{
				Store_OpenMainMenu(client);
			}
		}
		case MenuAction_End:{
			delete menu;
		}
	}

	return 0;
}

void OpenChooseActionMenu(int client, GiftType giftType)
{
	Menu menu = new Menu(ChooseActionMenuSelectHandle);
	menu.SetTitle("%T", "Gift Delivery Method", client);

	char s_giftType[32];
	if (giftType == GiftType_Credits)
		strcopy(s_giftType, sizeof(s_giftType), "credits");
	else if (giftType == GiftType_Item)
		strcopy(s_giftType, sizeof(s_giftType), "item");

	char send[32], drop[32];
	Format(send, sizeof(send), "%s,send", s_giftType);
	Format(drop, sizeof(drop), "%s,drop", s_giftType);

	char methodSend[32], methodDrop[32];
	Format(methodSend, sizeof(methodSend), "%T", "Gift Method Send", client);
	Format(methodDrop, sizeof(methodDrop), "%T", "Gift Method Drop", client);

	menu.AddItem(send, methodSend);
	menu.AddItem(drop, methodDrop);

	menu.ExitBackButton = true;
	menu.Display(client, MENU_TIME_FOREVER);
}

public int ChooseActionMenuSelectHandle(Menu menu, MenuAction action, int client, int slot)
{
	switch (action)
	{
		case MenuAction_Select:
		{
			char values[32];
			if (menu.GetItem(slot, values, sizeof(values)))
			{
				char brokenValues[2][32];
				ExplodeString(values, ",", brokenValues, sizeof(brokenValues), sizeof(brokenValues[]));

				GiftType giftType;

				if (StrEqual(brokenValues[0], "credits"))
				{
					giftType = GiftType_Credits;
				}
				else if (StrEqual(brokenValues[0], "item"))
				{
					giftType = GiftType_Item;
				}

				if (StrEqual(brokenValues[1], "send"))
				{
					OpenChoosePlayerMenu(client, giftType);
				}
				else if (StrEqual(brokenValues[1], "drop"))
				{
					if (giftType == GiftType_Item)
					{
						OpenSelectItemMenu(client, GiftAction_Drop, -1);
					}
					else if (giftType == GiftType_Credits)
					{
						OpenSelectCreditsMenu(client, GiftAction_Drop, -1);
					}
				}
			}
		}
		case MenuAction_Cancel:
		{
			if (slot == MenuCancel_ExitBack)
			{
				OpenGiftingMenu(client);
			}
		}
		case MenuAction_End:
		{
			delete menu;
		}
	}

	return 0;
}

void OpenChoosePlayerMenu(int client, GiftType giftType)
{
	Menu menu;

	if (giftType == GiftType_Credits)
		menu = new Menu(ChoosePlayerCreditsMenuSelectHandle);
	else if (giftType == GiftType_Item)
		menu = new Menu(ChoosePlayerItemMenuSelectHandle);
	else
		return;

	menu.SetTitle("Select Player:\n \n");

	AddTargetsToMenu2(menu, 0, COMMAND_FILTER_NO_BOTS);

	menu.ExitBackButton = true;
	menu.Display(client, MENU_TIME_FOREVER);	
}

public int ChoosePlayerCreditsMenuSelectHandle(Menu menu, MenuAction action, int client, int slot)
{
	switch (action) {
		case MenuAction_Select: {
			char userid[10];
			if (menu.GetItem(slot, userid, sizeof(userid)))
				OpenSelectCreditsMenu(client, GiftAction_Send, GetClientOfUserId(StringToInt(userid)));
		}
		case MenuAction_Cancel: {
			if (slot == MenuCancel_ExitBack)
			{
				OpenGiftingMenu(client);
			}
		}
		case MenuAction_End: {
			delete menu;
		}
	}

	return 0;
}

public int ChoosePlayerItemMenuSelectHandle(Menu menu, MenuAction action, int client, int slot)
{
	switch (action) {
		case MenuAction_Select:{
			char userid[10];
			if (menu.GetItem(slot, userid, sizeof(userid)))
				OpenSelectItemMenu(client, GiftAction_Send, GetClientOfUserId(StringToInt(userid)));
		}
		case MenuAction_Cancel: {
			if (slot == MenuCancel_ExitBack)
			{
				OpenGiftingMenu(client);
			}
		}
		case MenuAction_End: {
			delete menu;
		}
	}

	return 0;
}

void OpenSelectCreditsMenu(int client, GiftAction giftAction, int giftTo = -1)
{
	if (giftAction == GiftAction_Send && giftTo == -1)
		return;

	Menu menu = new Menu(CreditsMenuSelectItem);

	menu.SetTitle("Select %s:", g_currencyName);

	for (int choice = 0; choice < sizeof(g_creditChoices); choice++)
	{
		if (g_creditChoices[choice] == 0)
			continue;

		char text[48];
		IntToString(g_creditChoices[choice], text, sizeof(text));

		char value[32];
		Format(value, sizeof(value), "%d,%d,%d", giftAction, giftTo, g_creditChoices[choice]);

		menu.AddItem(value, text);
	}

	menu.ExitBackButton = true;
	menu.Display(client, MENU_TIME_FOREVER);
}

public int CreditsMenuSelectItem(Menu menu, MenuAction action, int client, int slot)
{
	switch (action) {
		case MenuAction_Select: {
			char value[32];
			if (menu.GetItem(slot, value, sizeof(value)))
			{
				char values[3][16];
				ExplodeString(value, ",", values, sizeof(values), sizeof(values[]));

				int giftAction = StringToInt(values[0]);
				int giftTo = StringToInt(values[1]);
				int credits = StringToInt(values[2]);

				DataPack pack = new DataPack();
				pack.WriteCell(client);
				pack.WriteCell(giftAction);
				pack.WriteCell(giftTo);
				pack.WriteCell(credits);

				Store_GetCredits(GetSteamAccountID(client), GetCreditsCallback, pack);
			}
		}
		case MenuAction_Cancel: {
			if (slot == MenuCancel_ExitBack)
			{
				OpenGiftingMenu(client);
			}
		}
		case MenuAction_End: {
			delete menu;
		}
	}

	return 0;
}

public void GetCreditsCallback(int credits, DataPack pack)
{
	pack.Reset();

	int client = pack.ReadCell();
	GiftAction giftAction = view_as<GiftAction>(pack.ReadCell());
	int giftTo = pack.ReadCell();
	int giftCredits = pack.ReadCell();

	delete pack;

	if (giftCredits > credits)
	{
		PrintToChat(client, "%s%t", STORE_PREFIX, "Not enough credits", g_currencyName);
	}
	else
	{
		OpenGiveCreditsConfirmMenu(client, giftAction, giftTo, giftCredits);
	}
}

void OpenGiveCreditsConfirmMenu(int client, GiftAction giftAction, int giftTo, int credits)
{
	Menu menu = new Menu(CreditsConfirmMenuSelectItem);
	char value[32];

	if (giftAction == GiftAction_Send)
	{
		char name[32];
		GetClientName(giftTo, name, sizeof(name));
		menu.SetTitle("%T", "Gift Credit Confirmation", client, name, credits, g_currencyName);
		Format(value, sizeof(value), "%d,%d,%d", giftAction, giftTo, credits);
	}
	else if (giftAction == GiftAction_Drop)
	{
		menu.SetTitle("%T", "Drop Credit Confirmation", client, credits, g_currencyName);
		Format(value, sizeof(value), "%d,%d,%d", giftAction, giftTo, credits);
	}

	menu.AddItem(value, "Yes");
	menu.AddItem("", "No");

	menu.ExitBackButton = false;
	menu.Display(client, MENU_TIME_FOREVER);  
}

public int CreditsConfirmMenuSelectItem(Menu menu, MenuAction action, int client, int slot)
{
	switch (action) {
		case MenuAction_Select: {
			char value[32];
			if (menu.GetItem(slot, value, sizeof(value)))
			{
				if (!StrEqual(value, ""))
				{
					char values[3][16];
					ExplodeString(value, ",", values, sizeof(values), sizeof(values[]));

					GiftAction giftAction = view_as<GiftAction>(StringToInt(values[0]));
					int giftTo = StringToInt(values[1]);
					int credits = StringToInt(values[2]);

					if (giftAction == GiftAction_Send)
					{
						AskForPermission(client, giftTo, GiftType_Credits, credits);
					}
					else if (giftAction == GiftAction_Drop)
					{
						char data[32];
						Format(data, sizeof(data), "credits,%d", credits);

						DataPack pack = new DataPack();
						pack.WriteCell(client);
						pack.WriteCell(credits);

						Store_GetCredits(GetSteamAccountID(client), DropGetCreditsCallback, pack);
					}
				}
			}
		}
		case MenuAction_DisplayItem: {
			char display[64];
			menu.GetItem(slot, "", 0, _, display, sizeof(display));

			char buffer[255];
			Format(buffer, sizeof(buffer), "%T", display, client);

			return RedrawMenuItem(buffer);
		}	
		case MenuAction_Cancel: {
			if (slot == MenuCancel_ExitBack)
			{
				OpenChoosePlayerMenu(client, GiftType_Credits);
			}
		}
		case MenuAction_End: {
			delete menu;
		}
	}

	return 0;
}

void OpenSelectItemMenu(int client, GiftAction giftAction, int giftTo = -1)
{
	DataPack pack = new DataPack();
	pack.WriteCell(GetClientSerial(client));
	pack.WriteCell(giftAction);
	pack.WriteCell(giftTo);

	StringMap filter = new StringMap();
	filter.SetValue("is_tradeable", 1);

	Store_GetUserItems(filter, GetSteamAccountID(client), Store_GetClientLoadout(client), GetUserItemsCallback, pack);
}

public void GetUserItemsCallback(int[] ids, bool[] equipped, int[] itemCount, int count, int loadoutId, DataPack pack)
{		
	pack.Reset();
	
	int serial = pack.ReadCell();
	GiftAction giftAction = view_as<GiftAction>(pack.ReadCell());
	int giftTo = pack.ReadCell();
	
	delete pack;
	
	int client = GetClientFromSerial(serial);
	
	if (client == 0)
		return;
		
	if (count == 0)
	{
		PrintToChat(client, "%s%t", STORE_PREFIX, "No items");	
		return;
	}
	
	Menu menu = new Menu(ItemMenuSelectHandle);
	menu.SetTitle("Select item:\n \n");
	
	for (int item = 0; item < count; item++)
	{
		char displayName[STORE_MAX_DISPLAY_NAME_LENGTH];
		Store_GetItemDisplayName(ids[item], displayName, sizeof(displayName));
		
		char text[4 + sizeof(displayName) + 6];
		Format(text, sizeof(text), "%s%s", text, displayName);
		
		if (itemCount[item] > 1)
			Format(text, sizeof(text), "%s (%d)", text, itemCount[item]);
		
		char value[32];
		Format(value, sizeof(value), "%d,%d,%d", giftAction, giftTo, ids[item]);
		
		menu.AddItem(value, text);    
	}

	menu.ExitBackButton = true;
	menu.Display(client, MENU_TIME_FOREVER);
}

public int ItemMenuSelectHandle(Menu menu, MenuAction action, int client, int slot)
{
	switch (action) {
		case MenuAction_Select: {
			char value[32];
			if (menu.GetItem(slot, value, sizeof(value)))
			{
				OpenGiveItemConfirmMenu(client, value);
			}
		}
		case MenuAction_Cancel: {
			OpenGiftingMenu(client); //OpenChoosePlayerMenu(client, GiftType_Item);
		}
		case MenuAction_End: {
			delete menu;
		}
	}

	return 0;
}

void OpenGiveItemConfirmMenu(int client, const char[] value)
{
	char values[3][16];
	ExplodeString(value, ",", values, sizeof(values), sizeof(values[]));

	GiftAction giftAction = view_as<GiftAction>(StringToInt(values[0]));
	int giftTo = StringToInt(values[1]);
	int itemId = StringToInt(values[2]);

	char name[32];
	if (giftAction == GiftAction_Send)
	{
		GetClientName(giftTo, name, sizeof(name));
	}

	char displayName[STORE_MAX_DISPLAY_NAME_LENGTH];
	Store_GetItemDisplayName(itemId, displayName, sizeof(displayName));

	Menu menu = new Menu(ItemConfirmMenuSelectItem);
	if (giftAction == GiftAction_Send)
		menu.SetTitle("%T", "Gift Item Confirmation", client, name, displayName);
	else if (giftAction == GiftAction_Drop)
		menu.SetTitle("%T", "Drop Item Confirmation", client, displayName);

	menu.AddItem(value, "Yes");
	menu.AddItem("", "No");

	menu.ExitButton = false;
	menu.Display(client, MENU_TIME_FOREVER);
}

public int ItemConfirmMenuSelectItem(Menu menu, MenuAction action, int client, int slot)
{
	switch (action) {
		case MenuAction_Select: {
			char value[32];
			if (menu.GetItem(slot, value, sizeof(value)))
			{
				if (!StrEqual(value, ""))
				{
					char values[3][16];
					ExplodeString(value, ",", values, sizeof(values), sizeof(values[]));

					GiftAction giftAction = view_as<GiftAction>(StringToInt(values[0]));
					int giftTo = StringToInt(values[1]);
					int itemId = StringToInt(values[2]);

					if (giftAction == GiftAction_Send)
						AskForPermission(client, giftTo, GiftType_Item, itemId);
					else if (giftAction == GiftAction_Drop)
					{
						int present;
						if((present = SpawnPresent(client, g_itemModel)) != -1)
						{
							char data[32];
							Format(data, sizeof(data), "item,%d", itemId);

							strcopy(g_spawnedPresents[present].Present_Data, 64, data);
							g_spawnedPresents[present].Present_Owner = client;

							Store_RemoveUserItem(GetSteamAccountID(client), itemId, DropItemCallback, client);
						}
					}
				}
			}
		}
		case MenuAction_DisplayItem: {
			char display[64];
			menu.GetItem(slot, "", 0, _, display, sizeof(display));

			char buffer[255];
			Format(buffer, sizeof(buffer), "%T", display, client);

			return RedrawMenuItem(buffer);
		}	
		case MenuAction_Cancel: {
			if (slot == MenuCancel_ExitBack)
			{
				OpenGiftingMenu(client);
			}
		}
		case MenuAction_End: {
			delete menu;
		}
	}

	return 0;
}

public void DropItemCallback(int accountId, int itemId, any client)
{
	char displayName[64];
	Store_GetItemDisplayName(itemId, displayName, sizeof(displayName));
	CPrintToChat(client, "%s%t", STORE_PREFIX, "Gift Item Dropped", displayName);
}

void AskForPermission(int client, int giftTo, GiftType giftType, int value)
{
	char giftToName[32];
	GetClientName(giftTo, giftToName, sizeof(giftToName));

	CPrintToChatEx(client, giftTo, "%s%T", STORE_PREFIX, "Gift Waiting to accept", client, giftToName);

	char clientName[32];
	GetClientName(client, clientName, sizeof(clientName));	

	char what[64];

	if (giftType == GiftType_Credits)
		Format(what, sizeof(what), "%d %s", value, g_currencyName);
	else if (giftType == GiftType_Item)
		Store_GetItemDisplayName(value, what, sizeof(what));	

	CPrintToChatEx(giftTo, client, "%s%T", STORE_PREFIX, "Gift Request Accept", client, clientName, what);

	g_giftRequests[giftTo].GiftRequestActive = true;
	g_giftRequests[giftTo].GiftRequestSender = client;
	g_giftRequests[giftTo].GiftRequestType = giftType;
	g_giftRequests[giftTo].GiftRequestValue = value;
}

public Action Command_Accept(int client, int args)
{
	if (!g_giftRequests[client].GiftRequestActive)
		return Plugin_Continue;

	if (g_giftRequests[client].GiftRequestType == GiftType_Credits)
		GiftCredits(g_giftRequests[client].GiftRequestSender, client, g_giftRequests[client].GiftRequestValue);
	else
		GiftItem(g_giftRequests[client].GiftRequestSender, client, g_giftRequests[client].GiftRequestValue);

	g_giftRequests[client].GiftRequestActive = false;
	return Plugin_Handled;
}

void GiftCredits(int from, int to, int amount)
{
	DataPack pack = new DataPack();
	pack.WriteCell(from); // 0
	pack.WriteCell(to); // 8
	pack.WriteCell(amount);

	Store_GiveCredits(GetSteamAccountID(from), -amount, TakeCreditsCallback, pack);
}

public void TakeCreditsCallback(int accountId, DataPack pack)
{
	pack.Position = view_as<DataPackPos>(8);

	int to = pack.ReadCell();
	int amount = pack.ReadCell();

	Store_GiveCredits(GetSteamAccountID(to), amount, GiveCreditsCallback, pack);
}

public void GiveCreditsCallback(int  accountId, DataPack pack)
{
	pack.Reset();

	int from = pack.ReadCell();
	int to = pack.ReadCell();

	delete pack;

	char receiverName[32];
	GetClientName(to, receiverName, sizeof(receiverName));	

	CPrintToChatEx(from, to, "%s%t", STORE_PREFIX, "Gift accepted - sender", receiverName);

	char senderName[32];
	GetClientName(from, senderName, sizeof(senderName));

	CPrintToChatEx(to, from, "%s%t", STORE_PREFIX, "Gift accepted - receiver", senderName);
}

void GiftItem(int from, int to, int itemId)
{
	DataPack pack = new DataPack();
	pack.WriteCell(from); // 0
	pack.WriteCell(to); // 8
	pack.WriteCell(itemId);

	Store_RemoveUserItem(GetSteamAccountID(from), itemId, RemoveUserItemCallback, pack);
}

public void RemoveUserItemCallback(int accountId, int itemId, DataPack pack)
{
	pack.Position = view_as<DataPackPos>(8);

	int to = pack.ReadCell();

	Store_GiveItem(GetSteamAccountID(to), itemId, Store_Gift, GiveCreditsCallback, pack);
}

int SpawnPresent(int owner, const char[] model)
{
	int present;

	if((present = CreateEntityByName("prop_physics_override")) != -1)
	{
		char targetname[100];

		Format(targetname, sizeof(targetname), "gift_%i", present);

		DispatchKeyValue(present, "model", model);
		DispatchKeyValue(present, "physicsmode", "2");
		DispatchKeyValue(present, "massScale", "1.0");
		DispatchKeyValue(present, "targetname", targetname);
		DispatchSpawn(present);
		
		SetEntProp(present, Prop_Send, "m_usSolidFlags", 8);
		SetEntProp(present, Prop_Send, "m_CollisionGroup", 1);
		
		float pos[3];
		GetClientAbsOrigin(owner, pos);
		pos[2] += 16;

		TeleportEntity(present, pos, NULL_VECTOR, NULL_VECTOR);
		
		int rotator = CreateEntityByName("func_rotating");
		DispatchKeyValueVector(rotator, "origin", pos);
		DispatchKeyValue(rotator, "targetname", targetname);
		DispatchKeyValue(rotator, "maxspeed", "200");
		DispatchKeyValue(rotator, "friction", "0");
		DispatchKeyValue(rotator, "dmg", "0");
		DispatchKeyValue(rotator, "solid", "0");
		DispatchKeyValue(rotator, "spawnflags", "64");
		DispatchSpawn(rotator);
		
		SetVariantString("!activator");
		AcceptEntityInput(present, "SetParent", rotator, rotator);
		AcceptEntityInput(rotator, "Start");
		
		SetEntPropEnt(present, Prop_Send, "m_hEffectEntity", rotator);

		SDKHook(present, SDKHook_StartTouch, OnStartTouch);
	}

	return present;
}

public void OnStartTouch(int present, int client)
{
	if(!(0<client<=MaxClients))
		return;

	if(g_spawnedPresents[present].Present_Owner == client)
		return;

	int rotator = GetEntPropEnt(present, Prop_Send, "m_hEffectEntity");
	if(rotator && IsValidEdict(rotator))
		AcceptEntityInput(rotator, "Kill");

	AcceptEntityInput(present, "Kill");

	char values[2][16];
	ExplodeString(g_spawnedPresents[present].Present_Data, ",", values, sizeof(values), sizeof(values[]));

	DataPack pack = new DataPack();
	pack.WriteCell(client);
	pack.WriteString(values[0]);

	if (StrEqual(values[0],"credits"))
	{
		int credits = StringToInt(values[1]);
		pack.WriteCell(credits);
		Store_GiveCredits(GetSteamAccountID(client), credits, PickupGiveCallback, pack);
	}
	else if (StrEqual(values[0], "item"))
	{
		int itemId = StringToInt(values[1]);
		pack.WriteCell(itemId);
		Store_GiveItem(GetSteamAccountID(client), itemId, Store_Gift, PickupGiveCallback, pack);
	}
}

public void PickupGiveCallback(int accountId, DataPack pack)
{
	pack.Reset();

	int client = pack.ReadCell();

	char itemType[32];
	pack.ReadString(itemType, sizeof(itemType));

	int value = pack.ReadCell();

	delete pack;

	if (StrEqual(itemType, "credits"))
	{
		CPrintToChat(client, "%s%t", STORE_PREFIX, "Gift Credits Found", value, g_currencyName); //translate
	}
	else if (StrEqual(itemType, "item"))
	{
		char displayName[STORE_MAX_DISPLAY_NAME_LENGTH];
		Store_GetItemDisplayName(value, displayName, sizeof(displayName));
		CPrintToChat(client, "%s%t", STORE_PREFIX, "Gift Item Found", displayName); //translate
	}
}