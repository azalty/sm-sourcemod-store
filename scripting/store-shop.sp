#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <store/store-core>
#include <store/store-backend>
#include <store/store-logging>
#include <store/store-inventory>
#include <colors>

char g_currencyName[64];
char g_menuCommands[32][32];

bool g_hideEmptyCategories;
bool g_confirmItemPurchase;
bool g_allowBuyingDuplicates;

GlobalForward g_buyItemForward;

Menu categories_menu[MAXPLAYERS+1];

/**
 * Called before plugin is loaded.
 * 
 * @param myself    The plugin handle.
 * @param late      True if the plugin was loaded after map change, false on map start.
 * @param error     Error message if load failed.
 * @param err_max   Max length of the error message.
 *
 * @return          APLRes_Success for load success, APLRes_Failure or APLRes_SilentFailure otherwise.
 */
public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
	CreateNative("Store_OpenShop", Native_OpenShop);
	CreateNative("Store_OpenShopCategory", Native_OpenShopCategory);
	
	RegPluginLibrary("store-shop");	
	return APLRes_Success;
}

public Plugin myinfo =
{
	name        = "[Store] Shop",
	author      = "alongub, drixevel",
	description = "Shop component for [Store]",
	version     = STORE_VERSION,
	url         = "https://github.com/drixevel-dev/store"
};

/**
 * Plugin is loading.
 */
public void OnPluginStart()
{
	LoadConfig();

	g_buyItemForward = new GlobalForward("Store_OnBuyItem", ET_Ignore, Param_Cell, Param_Cell, Param_Cell);

	LoadTranslations("common.phrases");
	LoadTranslations("store.phrases");

	Store_AddMainMenuItem("Shop", "Shop Description", _, OnMainMenuShopClick, 2);
	
	RegConsoleCmd("sm_shop", Command_OpenShop);
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
	BuildPath(Path_SM, path, sizeof(path), "configs/store/shop.cfg");
	
	if (!kv.ImportFromFile(path)) 
	{
		delete kv;
		SetFailState("Can't read config file %s", path);
	}

	char menuCommands[255];
	kv.GetString("shop_commands", menuCommands, sizeof(menuCommands));
	ExplodeString(menuCommands, " ", g_menuCommands, sizeof(g_menuCommands), sizeof(g_menuCommands[]));
	
	g_confirmItemPurchase = view_as<bool>(kv.GetNum("confirm_item_purchase", 0));
	g_hideEmptyCategories = view_as<bool>(kv.GetNum("hide_empty_categories", 0));
	g_allowBuyingDuplicates = view_as<bool>(kv.GetNum("allow_buying_duplicates", 0));

	delete kv;
}

public void OnMainMenuShopClick(int client, const char[] value)
{
	OpenShop(client);
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
			OpenShop(client);
			
			if (text[0] == 0x2F)
				return Plugin_Handled;
			
			return Plugin_Continue;
		}
	}
	
	return Plugin_Continue;
}

public Action Command_OpenShop(int client, int args)
{
	OpenShop(client);
	return Plugin_Handled;
}

/**
 * Opens the shop menu for a client.
 *
 * @param client			Client index.
 *
 * @noreturn
 */
void OpenShop(int client)
{
	Store_GetCategories(GetCategoriesCallback, true, GetClientSerial(client));
}

public void GetCategoriesCallback(int[] ids, int count, any serial)
{		
	int client = GetClientFromSerial(serial);
	
	if (client == 0)
		return;
	
	categories_menu[client] = new Menu(ShopMenuSelectHandle);
	categories_menu[client].SetTitle("%T\n \n", "Shop", client);
	
	for (int category = 0; category < count; category++)
	{
		char requiredPlugin[STORE_MAX_REQUIREPLUGIN_LENGTH];
		Store_GetCategoryPluginRequired(ids[category], requiredPlugin, sizeof(requiredPlugin));
		
		if (!StrEqual(requiredPlugin, "") && !Store_IsItemTypeRegistered(requiredPlugin))
			continue;

		DataPack pack = new DataPack();
		pack.WriteCell(GetClientSerial(client));
		pack.WriteCell(ids[category]);
		pack.WriteCell(count - category - 1);
		
		StringMap filter = new StringMap();
		filter.SetValue("is_buyable", 1);
		filter.SetValue("category_id", ids[category]);
		filter.SetValue("flags", GetUserFlagBits(client));

		Store_GetItems(filter, GetItemsForCategoryCallback, true, pack);
	}
}

public void GetItemsForCategoryCallback(int[] ids, int count, DataPack pack)
{
	pack.Reset();
	
	int serial = pack.ReadCell();
	int categoryId = pack.ReadCell();
	int left = pack.ReadCell();
	
	delete pack;
	
	int client = GetClientFromSerial(serial);
	
	if (client == 0)
		return;

	if (g_hideEmptyCategories && count != 0)
	{
		char displayName[STORE_MAX_DISPLAY_NAME_LENGTH];
		Store_GetCategoryDisplayName(categoryId, displayName, sizeof(displayName));

		//char description[STORE_MAX_DESCRIPTION_LENGTH];
		//Store_GetCategoryDescription(categoryId, description, sizeof(description));

		//char itemText[sizeof(displayName) + 1 + sizeof(description)];
		//Format(itemText, sizeof(itemText), "%s\n%s", displayName, description);
		
		char itemValue[8];
		IntToString(categoryId, itemValue, sizeof(itemValue));
		
		categories_menu[client].AddItem(itemValue, displayName);
	}

	if (left == 0)
	{
		categories_menu[client].ExitBackButton = true;
		categories_menu[client].Display(client, MENU_TIME_FOREVER);
	}
}

public int ShopMenuSelectHandle(Menu menu, MenuAction action, int client, int slot)
{
	switch (action) {
		case MenuAction_Select: {
			char categoryIndex[64];
			
			if (GetMenuItem(menu, slot, categoryIndex, sizeof(categoryIndex)))
				OpenShopCategory(client, StringToInt(categoryIndex));
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
 * Opens the shop menu for a client in a specific category.
 *
 * @param client			Client index.
 * @param categoryId		The category that you want to open.
 *
 * @noreturn
 */
void OpenShopCategory(int client, int categoryId)
{
	DataPack pack = new DataPack();
	pack.WriteCell(GetClientSerial(client));
	pack.WriteCell(categoryId);
	
	StringMap filter = new StringMap();
	filter.SetValue("is_buyable", 1);
	filter.SetValue("category_id", categoryId);
	filter.SetValue("flags", GetUserFlagBits(client));

	Store_GetItems(filter, GetItemsCallback, true, pack);
}

public void GetItemsCallback(int[] ids, int count, DataPack pack)
{	
	pack.Reset();
	
	int serial = pack.ReadCell();
	int categoryId = pack.ReadCell();
	
	delete pack;
	
	int client = GetClientFromSerial(serial);
	
	if (client == 0)
		return;
	
	if (count == 0)
	{
		PrintToChat(client, "%s%t", STORE_PREFIX, "No items in this category");
		OpenShop(client);
		
		return;
	}
	
	char categoryDisplayName[64];
	Store_GetCategoryDisplayName(categoryId, categoryDisplayName, sizeof(categoryDisplayName));
		
	Menu menu = new Menu(ShopCategoryMenuSelectHandle);
	menu.SetTitle("%T - %s\n \n", "Shop", client, categoryDisplayName);

	for (int item = 0; item < count; item++)
	{		
		char displayName[64];
		Store_GetItemDisplayName(ids[item], displayName, sizeof(displayName));
		
		char description[128];
		Store_GetItemDescription(ids[item], description, sizeof(description));
	
		char text[sizeof(displayName) + sizeof(description) + 5];
		Format(text, sizeof(text), "%s [%d %s]\n%s", displayName, Store_GetItemPrice(ids[item]), g_currencyName, description);
		
		char value[8];
		IntToString(ids[item], value, sizeof(value));
		
		menu.AddItem(value, text);    
	}

	menu.ExitBackButton = true;
	menu.Display(client, MENU_TIME_FOREVER);   
}

public int ShopCategoryMenuSelectHandle(Menu menu, MenuAction action, int client, int slot)
{
	switch (action) {
		case MenuAction_Select: {
			char value[12];

			if (GetMenuItem(menu, slot, value, sizeof(value)))
			{
				DoBuyItem(client, StringToInt(value));
			}
		}
		case MenuAction_Cancel: {
			OpenShop(client);
		}
		case MenuAction_End: {
			delete menu;
		}
	}

	return 0;
}

void DoBuyItem(int client, int itemId, bool confirmed = false, bool checkeddupes=false)
{
	if (g_confirmItemPurchase && !confirmed)
	{
		DisplayConfirmationMenu(client, itemId);
	}
	else if (!g_allowBuyingDuplicates && !checkeddupes)
	{
		char itemName[STORE_MAX_NAME_LENGTH];
		Store_GetItemName(itemId, itemName, sizeof(itemName));

		DataPack pack = new DataPack();
		pack.WriteCell(GetClientSerial(client));
		pack.WriteCell(itemId);

		Store_GetUserItemCount(GetSteamAccountID(client), itemName, DoBuyItem_ItemCountCallBack, pack);
	}
	else
	{
		DataPack pack = new DataPack();
		pack.WriteCell(GetClientSerial(client));
		pack.WriteCell(itemId);

		Store_BuyItem(GetSteamAccountID(client), itemId, OnBuyItemComplete, pack);
	}
}

public void DoBuyItem_ItemCountCallBack(int count, DataPack pack)
{
	pack.Reset();

	int client = GetClientFromSerial(pack.ReadCell());

	if (client == 0)
	{
		delete pack;
		return;
	}

	int itemId = pack.ReadCell();

	delete pack;

	if (count <= 0)
	{
		DoBuyItem(client, itemId, true, true);
	}
	else
	{
		char displayName[STORE_MAX_DISPLAY_NAME_LENGTH];
		Store_GetItemDisplayName(itemId, displayName, sizeof(displayName));
		PrintToChat(client, "%s%t", STORE_PREFIX, "Already purchased item", displayName);
	}
}

void DisplayConfirmationMenu(int client, int itemId)
{
	char displayName[STORE_MAX_DISPLAY_NAME_LENGTH];
	Store_GetItemDisplayName(itemId, displayName, sizeof(displayName));

	Menu menu = new Menu(ConfirmationMenuSelectHandle);
	menu.SetTitle("%T", "Item Purchase Confirmation", client,  displayName);

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
			char value[12];
			if (GetMenuItem(menu, slot, value, sizeof(value)))
			{
				if (StrEqual(value, "no"))
				{
					OpenShop(client);
				}
				else
				{
					DoBuyItem(client, StringToInt(value), true);
				}
			}
		}
		case MenuAction_Cancel: {
			OpenShop(client);
		}
		case MenuAction_DisplayItem: {
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

public void OnBuyItemComplete(bool success, DataPack pack)
{
	pack.Reset();

	int client = GetClientFromSerial(pack.ReadCell());

	if (client == 0)
	{
		delete pack;
		return;
	}

	int itemId = pack.ReadCell();

	delete pack;

	if (success)
	{
		char displayName[64];
		Store_GetItemDisplayName(itemId, displayName, sizeof(displayName));

		CPrintToChat(client, "%s%t", STORE_PREFIX, "Item Purchase Successful", displayName);
	}
	else
	{
		CPrintToChat(client, "%s%t", STORE_PREFIX, "Not enough credits to buy", g_currencyName);
	}

	Call_StartForward(g_buyItemForward);
	Call_PushCell(client);
	Call_PushCell(itemId);
	Call_PushCell(success);
	Call_Finish();
	
	OpenShop(client);
}

public int Native_OpenShop(Handle plugin, int numParams)
{       
	OpenShop(GetNativeCell(1));
	return 0;
}

public int Native_OpenShopCategory(Handle plugin, int numParams)
{       
	OpenShopCategory(GetNativeCell(1), GetNativeCell(2));
	return 0;
}