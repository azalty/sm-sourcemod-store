#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <store/store-core>
#include <store/store-backend>
#include <store/store-logging>
#include <store/store-inventory>
#include <store/store-loadout>

char g_currencyName[64];
char g_menuCommands[32][32];

float g_refundPricePercentage;
bool g_confirmItemRefund = true;

public Plugin myinfo =
{
	name        = "[Store] Refund",
	author      = "alongub, drixevel",
	description = "Refund component for [Store]",
	version     = STORE_VERSION,
	url         = "https://github.com/drixevel-dev/store"
};

/**
 * Plugin is loading.
 */
public void voidOnPluginStart()
{
	LoadConfig();

	LoadTranslations("common.phrases");
	LoadTranslations("store.phrases");

	Store_AddMainMenuItem("Refund", "Refund Description", _, OnMainMenuRefundClick, 6);
	
	RegConsoleCmd("sm_refund", Command_OpenRefund);
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
	BuildPath(Path_SM, path, sizeof(path), "configs/store/refund.cfg");
	
	if (!kv.ImportFromFile(path)) 
	{
		delete kv;
		SetFailState("Can't read config file %s", path);
	}

	char menuCommands[255];
	kv.GetString("refund_commands", menuCommands, sizeof(menuCommands));
	ExplodeString(menuCommands, " ", g_menuCommands, sizeof(g_menuCommands), sizeof(g_menuCommands[]));
	
	g_refundPricePercentage = kv.GetFloat("refund_price_percentage", 0.5);
	g_confirmItemRefund = view_as<bool>(kv.GetNum("confirm_item_refund", 1));

	delete kv;
}

public void OnMainMenuRefundClick(int client, const char[] value)
{
	OpenRefundMenu(client);
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
			OpenRefundMenu(client);
			
			if (text[0] == 0x2F)
				return Plugin_Handled;
			
			return Plugin_Continue;
		}
	}
	
	return Plugin_Continue;
}

public Action Command_OpenRefund(int client, int args)
{
	OpenRefundMenu(client);
	return Plugin_Handled;
}

/**
 * Opens the refund menu for a client.
 *
 * @param client			Client index.
 *
 * @noreturn
 */
void OpenRefundMenu(int client)
{
	Store_GetCategories(GetCategoriesCallback, true, GetClientSerial(client));
}

public void GetCategoriesCallback(int[] ids, int count, any serial)
{		
	int client = GetClientFromSerial(serial);
	
	if (client == 0)
		return;
		
	Menu menu = new Menu(RefundMenuSelectHandle);
	menu.SetTitle("%T\n \n", "Refund", client);
	
	for (int category = 0; category < count; category++)
	{
		char requiredPlugin[STORE_MAX_REQUIREPLUGIN_LENGTH];
		Store_GetCategoryPluginRequired(ids[category], requiredPlugin, sizeof(requiredPlugin));
		
		if (!StrEqual(requiredPlugin, "") && !Store_IsItemTypeRegistered(requiredPlugin))
			continue;
			
		char displayName[STORE_MAX_DISPLAY_NAME_LENGTH];
		Store_GetCategoryDisplayName(ids[category], displayName, sizeof(displayName));

		char description[STORE_MAX_DESCRIPTION_LENGTH];
		Store_GetCategoryDescription(ids[category], description, sizeof(description));

		char itemText[sizeof(displayName) + 1 + sizeof(description)];
		Format(itemText, sizeof(itemText), "%s\n%s", displayName, description);
		
		char itemValue[8];
		IntToString(ids[category], itemValue, sizeof(itemValue));
		
		menu.AddItem(itemValue, itemText);
	}
	
	menu.ExitBackButton = true;
	menu.Display(client, MENU_TIME_FOREVER);
}

public int RefundMenuSelectHandle(Menu menu, MenuAction action, int client, int slot)
{
	switch (action) {
		case MenuAction_Select: {
			char categoryIndex[64];
			
			if (GetMenuItem(menu, slot, categoryIndex, sizeof(categoryIndex)))
				OpenRefundCategory(client, StringToInt(categoryIndex));
		}
		case MenuAction_Cancel: {
			if (slot == MenuCancel_ExitBack)
			{
				Store_OpenMainMenu(client);
			}
		}
		case MenuAction_End: {
			delete menu;
		}
	}

	return 0;
}

/**
 * Opens the refund menu for a client in a specific category.
 *
 * @param client			Client index.
 * @param categoryId		The category that you want to open.
 *
 * @noreturn
 */
void OpenRefundCategory(int client, int categoryId, int slot = 0)
{
	DataPack pack = new DataPack();
	pack.WriteCell(GetClientSerial(client));
	pack.WriteCell(categoryId);
	pack.WriteCell(slot);

	StringMap filter = new StringMap();
	filter.SetValue("is_refundable", 1);
	filter.SetValue("category_id", categoryId);

	Store_GetUserItems(filter, GetSteamAccountID(client), Store_GetClientLoadout(client), GetUserItemsCallback, pack);
}

public void GetUserItemsCallback(int[] ids, bool[] equipped, int[] itemCount, int count, int loadoutId, DataPack pack)
{	
	pack.Reset();
	
	int serial = pack.ReadCell();
	int categoryId = pack.ReadCell();
	int slot = pack.ReadCell();
	
	delete pack;
	
	int client = GetClientFromSerial(serial);
	
	if (client == 0)
		return;
		
	if (count == 0)
	{
		PrintToChat(client, "%s%t", STORE_PREFIX, "No items in this category");
		OpenRefundMenu(client);
		
		return;
	}
	
	char categoryDisplayName[64];
	Store_GetCategoryDisplayName(categoryId, categoryDisplayName, sizeof(categoryDisplayName));
		
	Menu menu = new Menu(RefundCategoryMenuSelectHandle);
	menu.SetTitle("%T - %s\n \n", "Refund", client, categoryDisplayName);
	
	for (int item = 0; item < count; item++)
	{
		// TODO: Option to display descriptions	
		char displayName[STORE_MAX_DISPLAY_NAME_LENGTH];
		Store_GetItemDisplayName(ids[item], displayName, sizeof(displayName));
		
		char text[4 + sizeof(displayName) + 6];
		Format(text, sizeof(text), "%s%s", text, displayName);
		
		if (itemCount[item] > 1)
			Format(text, sizeof(text), "%s (%d)", text, itemCount[item]);
		
		Format(text, sizeof(text), "%s - %d %s", text, RoundToZero(Store_GetItemPrice(ids[item]) * g_refundPricePercentage), g_currencyName);

		char value[8];
		IntToString(ids[item], value, sizeof(value));
		
		menu.AddItem(value, text);    
	}

	menu.ExitBackButton = true;
	
	if (slot == 0)
		menu.Display(client, MENU_TIME_FOREVER);
	else
		menu.DisplayAt(client, slot, MENU_TIME_FOREVER);
}

public int RefundCategoryMenuSelectHandle(Menu menu, MenuAction action, int client, int slot)
{
	switch (action) {
		case MenuAction_Select: {
			char itemId[12];
			if (GetMenuItem(menu, slot, itemId, sizeof(itemId)))
			{
				if (g_confirmItemRefund)
				{
					DisplayConfirmationMenu(client, StringToInt(itemId));
				}
				else
				{			
					Store_RemoveUserItem(GetSteamAccountID(client), StringToInt(itemId), OnRemoveUserItemComplete, GetClientSerial(client));
				}
			}
		}
		case MenuAction_Cancel: {
			OpenRefundMenu(client);
		}
		case MenuAction_End: {
			delete menu;
		}
	}

	return 0;
}

void DisplayConfirmationMenu(int client, int itemId)
{
	char displayName[64];
	Store_GetItemDisplayName(itemId, displayName, sizeof(displayName));

	Menu menu = new Menu(ConfirmationMenuSelectHandle);
	menu.SetTitle("%T", "Item Refund Confirmation", client, displayName, RoundToZero(Store_GetItemPrice(itemId) * g_refundPricePercentage), g_currencyName);

	char value[8];
	IntToString(itemId, value, sizeof(value));

	menu.AddItem(value, "Yes");
	menu.AddItem("no", "No");

	menu.ExitButton = false;
	menu.Display(client, MENU_TIME_FOREVER);
}

public int ConfirmationMenuSelectHandle(Menu menu, MenuAction action, int client, int slot)
{
	switch (action) {
		case MenuAction_Select: {
			char itemId[12];
			if (GetMenuItem(menu, slot, itemId, sizeof(itemId)))
			{
				if (StrEqual(itemId, "no"))
				{
					OpenRefundMenu(client);
				}
				else
				{
					Store_RemoveUserItem(GetSteamAccountID(client), StringToInt(itemId), OnRemoveUserItemComplete, GetClientSerial(client));
				}
			}
		}
		case MenuAction_Cancel: {
			OpenRefundMenu(client);
		}
		case MenuAction_DisplayItem:  {
			char display[64];
			GetMenuItem(menu, slot, "", 0, _, display, sizeof(display));

			char buffer[255];
			Format(buffer, sizeof(buffer), "%T", display, client);

			return RedrawMenuItem(buffer);
		}
		case MenuAction_End: {
			delete menu;
		}
	}

	return 0;
}

public void OnRemoveUserItemComplete(int accountId, int itemId, any serial)
{
	int client = GetClientFromSerial(serial);

	if (client == 0)
		return;

	int credits = RoundToZero(Store_GetItemPrice(itemId) * g_refundPricePercentage);

	DataPack pack = new DataPack();
	pack.WriteCell(GetClientSerial(client));
	pack.WriteCell(credits);
	pack.WriteCell(itemId);

	Store_GiveCredits(accountId, credits, OnGiveCreditsComplete, pack);
}

public void OnGiveCreditsComplete(int accountId, DataPack pack)
{
	pack.Reset();

	int serial = pack.ReadCell();
	int credits = pack.ReadCell();
	int itemId = pack.ReadCell();

	delete pack;

	int client = GetClientFromSerial(serial);

	if (client == 0)
		return;

	char displayName[STORE_MAX_DISPLAY_NAME_LENGTH];
	Store_GetItemDisplayName(itemId, displayName, sizeof(displayName));
		
	PrintToChat(client, "%s%t", STORE_PREFIX, "Refund Message", displayName, credits, g_currencyName);

	OpenRefundMenu(client);
}