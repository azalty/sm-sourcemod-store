#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <store/store-core>
#include <store/store-backend>
#include <store/store-inventory>
#include <store/store-logging>
#include <store/store-loadout>

bool g_hideEmptyCategories;

char g_menuCommands[32][32];

ArrayList g_itemTypes;
StringMap g_itemTypeNameIndex;

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
	CreateNative("Store_OpenInventory", Native_OpenInventory);
	CreateNative("Store_OpenInventoryCategory", Native_OpenInventoryCategory);
	
	CreateNative("Store_RegisterItemType", Native_RegisterItemType);
	CreateNative("Store_IsItemTypeRegistered", Native_IsItemTypeRegistered);
	
	CreateNative("Store_CallItemAttrsCallback", Native_CallItemAttrsCallback);
	
	RegPluginLibrary("store-inventory");	
	return APLRes_Success;
}

public Plugin myinfo =
{
	name        = "[Store] Inventory",
	author      = "alongub, drixevel",
	description = "Inventory component for [Store]",
	version     = STORE_VERSION,
	url         = "https://github.com/drixevel-dev/store"
};

/**
 * Plugin is loading.
 */
public void OnPluginStart()
{
	LoadConfig();

	LoadTranslations("common.phrases");
	LoadTranslations("store.phrases");

	Store_AddMainMenuItem("Inventory", "Inventory Description", _, OnMainMenuInventoryClick, 4);

	RegConsoleCmd("sm_inventory", Command_OpenInventory);
	RegAdminCmd("store_itemtypes", Command_PrintItemTypes, ADMFLAG_RCON, "Prints registered item types");
}

/**
 * Load plugin config.
 */
void LoadConfig() 
{
	KeyValues kv = new KeyValues("root");
	
	char path[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, path, sizeof(path), "configs/store/inventory.cfg");
	
	if (!kv.ImportFromFile(path)) 
	{
		delete kv;
		SetFailState("Can't read config file %s", path);
	}

	char menuCommands[255];
	kv.GetString("inventory_commands", menuCommands, sizeof(menuCommands));
	ExplodeString(menuCommands, " ", g_menuCommands, sizeof(g_menuCommands), sizeof(g_menuCommands[]));

	g_hideEmptyCategories = view_as<bool>(kv.GetNum("hide_empty_categories", 0));
		
	delete kv;
}

public void OnMainMenuInventoryClick(int client, const char[] value)
{
	OpenInventory(client);
}

/**
 * Called when a client has typed a message to the chat.
 *
 * @param client		Client index.
 * @param command		Command name, lower case.
 * @param args          Argument count. 
 *
 * @return				Action to take.
 */
public Action OnClientSayCommand(int client, const char[] command, const char[] sArgs)
{
	char text[256];
	strcopy(text, sizeof(text), sArgs);
	StripQuotes(text);
	
	for (int index = 0; index < sizeof(g_menuCommands); index++) 
	{
		if (StrEqual(g_menuCommands[index], text))
		{
			OpenInventory(client);
			
			if (text[0] == 0x2F)
				return Plugin_Handled;
			
			return Plugin_Continue;
		}
	}
	
	return Plugin_Continue;
}

public Action Command_OpenInventory(int client, int args)
{
	OpenInventory(client);
	return Plugin_Handled;
}

public Action Command_PrintItemTypes(int client, int args)
{
	for (int itemTypeIndex = 0, size = g_itemTypes.Length; itemTypeIndex < size; itemTypeIndex++)
	{
		DataPack itemType = view_as<DataPack>(g_itemTypes.Get(itemTypeIndex));
		
		itemType.Reset();
		Handle plugin = view_as<Handle>(itemType.ReadCell());

		itemType.Position = view_as<DataPackPos>(24);
		char typeName[32];
		itemType.ReadString(typeName, sizeof(typeName));

		itemType.Reset();

		char pluginName[32];
		GetPluginFilename(plugin, pluginName, sizeof(pluginName));

		ReplyToCommand(client, " \"%s\" - %s", typeName, pluginName);			
	}

	return Plugin_Handled;
}

/**
* Opens the inventory menu for a client.
*
* @param client			Client index.
*
* @noreturn
*/
void OpenInventory(int client)
{
	if (client <= 0 || client > MaxClients)
		return;

	if (!IsClientInGame(client))
		return;

	Store_GetCategories(GetCategoriesCallback, true, GetClientSerial(client));
}

public void GetCategoriesCallback(int[] ids, int count, any serial)
{	
	int client = GetClientFromSerial(serial);
	
	if (client == 0)
		return;
	
	categories_menu[client] = new Menu(InventoryMenuSelectHandle);
	categories_menu[client].SetTitle("%T\n \n", "Inventory", client);
		
	for (int category = 0; category < count; category++)
	{
		char requiredPlugin[STORE_MAX_REQUIREPLUGIN_LENGTH];
		Store_GetCategoryPluginRequired(ids[category], requiredPlugin, sizeof(requiredPlugin));
		
		int typeIndex;
		if (!StrEqual(requiredPlugin, "") && !g_itemTypeNameIndex.GetValue(requiredPlugin, typeIndex))
			continue;

		DataPack pack = new DataPack();
		pack.WriteCell(GetClientSerial(client));
		pack.WriteCell(ids[category]);
		pack.WriteCell(count - category - 1);
		
		StringMap filter = new StringMap();
		filter.SetValue("category_id", ids[category]);
		filter.SetValue("flags", GetUserFlagBits(client));

		Store_GetUserItems(filter, GetSteamAccountID(client), Store_GetClientLoadout(client), GetItemsForCategoryCallback, pack);
	}
}

public void GetItemsForCategoryCallback(int[] ids, bool[] equipped, int[] itemCount, int count, int loadoutId, DataPack pack)
{
	pack.Reset();
	
	int serial = pack.ReadCell();
	int categoryId = pack.ReadCell();
	int left = pack.ReadCell();
	
	delete pack;
	
	int client = GetClientFromSerial(serial);
	
	if (client <= 0)
		return;

	if (g_hideEmptyCategories && count <= 0)
	{
		if (left == 0)
		{
			categories_menu[client].ExitBackButton = true;
			categories_menu[client].Display(client, MENU_TIME_FOREVER);
		}
		return;
	}

	char displayName[STORE_MAX_DISPLAY_NAME_LENGTH];
	Store_GetCategoryDisplayName(categoryId, displayName, sizeof(displayName));

	//PrintToChatAll("%s %i %i %i", displayName, g_hideEmptyCategories, count, left);

	//char description[STORE_MAX_DESCRIPTION_LENGTH];
	//Store_GetCategoryDescription(categoryId, description, sizeof(description));

	//char itemText[sizeof(displayName) + 1 + sizeof(description)];
	//Format(itemText, sizeof(itemText), "%s\n%s", displayName, description);
	
	char itemValue[8];
	IntToString(categoryId, itemValue, sizeof(itemValue));
	
	categories_menu[client].AddItem( itemValue, displayName);

	if (left == 0)
	{
		categories_menu[client].ExitBackButton = true;
		categories_menu[client].Display(client, MENU_TIME_FOREVER);
	}
}

public int InventoryMenuSelectHandle(Menu menu, MenuAction action, int client, int slot)
{
	switch (action) {
		case MenuAction_Select:
		{
			char categoryIndex[64];
			
			if (GetMenuItem(menu, slot, categoryIndex, sizeof(categoryIndex)))
				OpenInventoryCategory(client, StringToInt(categoryIndex));
		}
		case MenuAction_Cancel:
		{
			if (slot == MenuCancel_ExitBack)
			{
				Store_OpenMainMenu(client);
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
* Opens the inventory menu for a client in a specific category.
*
* @param client			Client index.
* @param categoryId		The category that you want to open.
*
* @noreturn
*/
void OpenInventoryCategory(int client, int categoryId, int slot = 0)
{
	DataPack pack = new DataPack();
	pack.WriteCell(GetClientSerial(client));
	pack.WriteCell(categoryId);
	pack.WriteCell(slot);
	
	StringMap filter = new StringMap();
	filter.SetValue("category_id", categoryId);
	filter.SetValue("flags", GetUserFlagBits(client));

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
		OpenInventory(client);
		
		return;
	}
	
	char categoryDisplayName[64];
	Store_GetCategoryDisplayName(categoryId, categoryDisplayName, sizeof(categoryDisplayName));
		
	Menu menu = new Menu(InventoryCategoryMenuSelectHandle);
	menu.SetTitle("%T - %s\n \n", "Inventory", client, categoryDisplayName);
	
	for (int item = 0; item < count; item++)
	{
		// TODO: Option to display descriptions	
		char displayName[STORE_MAX_DISPLAY_NAME_LENGTH];
		Store_GetItemDisplayName(ids[item], displayName, sizeof(displayName));
		
		char text[4 + sizeof(displayName) + 6];
		
		if (equipped[item])
			strcopy(text, sizeof(text), "[E] ");
		
		Format(text, sizeof(text), "%s%s", text, displayName);
		
		if (itemCount[item] > 1)
			Format(text, sizeof(text), "%s (%d)", text, itemCount[item]);
			
		char value[16];
		Format(value, sizeof(value), "%b,%d", equipped[item], ids[item]);
		
		menu.AddItem(value, text);    
	}

	menu.ExitBackButton = true;
	
	if (slot == 0)
		menu.Display(client, MENU_TIME_FOREVER);
	else
		menu.DisplayAt(client, slot, MENU_TIME_FOREVER);
}

public int InventoryCategoryMenuSelectHandle(Menu menu, MenuAction action, int client, int slot)
{
	switch (action) {
		case MenuAction_Select: {
			char value[16];

			if (menu.GetItem(slot, value, sizeof(value)))
			{
				char buffers[2][16];
				ExplodeString(value, ",", buffers, sizeof(buffers), sizeof(buffers[]));
				
				bool equipped = view_as<bool>(StringToInt(buffers[0]));
				int id = StringToInt(buffers[1]);
				
				char name[STORE_MAX_NAME_LENGTH];
				Store_GetItemName(id, name, sizeof(name));
				
				char type[STORE_MAX_TYPE_LENGTH];
				Store_GetItemType(id, type, sizeof(type));
				
				char loadoutSlot[STORE_MAX_LOADOUTSLOT_LENGTH];
				Store_GetItemLoadoutSlot(id, loadoutSlot, sizeof(loadoutSlot));
				
				int itemTypeIndex = -1;
				g_itemTypeNameIndex.GetValue(type, itemTypeIndex);
				
				if (itemTypeIndex == -1)
				{
					PrintToChat(client, "%s%t", STORE_PREFIX, "Item type not registered", type);
					Store_LogWarning("The item type '%s' wasn't registered by any plugin.", type);
					
					OpenInventoryCategory(client, Store_GetItemCategory(id));
					
					return 0;
				}
				
				Store_ItemUseAction callbackValue = Store_DoNothing;
				
				DataPack itemType = view_as<DataPack>(g_itemTypes.Get(itemTypeIndex));
				itemType.Reset();
				
				Handle plugin = view_as<Handle>(itemType.ReadCell());
				Function callback = itemType.ReadFunction();
			
				Call_StartFunction(plugin, callback);
				Call_PushCell(client);
				Call_PushCell(id);
				Call_PushCell(equipped);
				Call_Finish(callbackValue);
				
				if (callbackValue != Store_DoNothing)
				{
					int auth = GetSteamAccountID(client);
						
					DataPack pack = new DataPack();
					pack.WriteCell(GetClientSerial(client));
					pack.WriteCell(slot);

					if (callbackValue == Store_EquipItem)
					{
						if (StrEqual(loadoutSlot, ""))
						{
							Store_LogWarning("A user tried to equip an item that doesn't have a loadout slot.");
						}
						else
						{
							Store_SetItemEquippedState(auth, id, Store_GetClientLoadout(client), true, EquipItemCallback, pack);
						}
					}
					else if (callbackValue == Store_UnequipItem)
					{
						if (StrEqual(loadoutSlot, ""))
						{
							Store_LogWarning("A user tried to unequip an item that doesn't have a loadout slot.");
						}
						else
						{				
							Store_SetItemEquippedState(auth, id, Store_GetClientLoadout(client), false, EquipItemCallback, pack);
						}
					}
					else if (callbackValue == Store_DeleteItem)
					{
						Store_RemoveUserItem(auth, id, UseItemCallback, pack);
					}
				}
			}
		}
		case MenuAction_Cancel: {
			OpenInventory(client);
		}
		case MenuAction_End: {
			delete menu;
		}
	}

	return 0;
}

public void EquipItemCallback(int accountId, int itemId, int loadoutId, DataPack pack)
{
	pack.Reset();
	
	int serial = pack.ReadCell();
	// int slot = pack.ReadCell();
	
	delete pack;
	
	int client = GetClientFromSerial(serial);
	
	if (client == 0)
		return;
		
	OpenInventoryCategory(client, Store_GetItemCategory(itemId));
}

public void UseItemCallback(int accountId, int itemId, DataPack pack)
{
	pack.Reset();
	
	int serial = pack.ReadCell();
	// int slot = pack.ReadCell();
	
	delete pack;
	
	int client = GetClientFromSerial(serial);
	
	if (client == 0)
		return;
		
	OpenInventoryCategory(client, Store_GetItemCategory(itemId));
}

/**
* Registers an item type. 
*
* A type of an item defines its behaviour. Once you register a type, 
* the store will provide two callbacks for you:
* 	- Use callback: called when a player selects your item in his inventory.
*	- Attributes callback: called when the store loads the attributes of your item (optional).
*
* It is recommended that each plugin registers *one* item type. 
*
* @param type			Item type unique identifer - maximum 32 characters, no whitespaces, lower case only.
* @param plugin			The plugin owner of the callback(s).
* @param useCallback	Called when a player selects your item in his inventory.
* @param attrsCallback	Called when the store loads the attributes of your item.
*
* @noreturn
*/
void RegisterItemType(const char[] type, Handle plugin, Function useCallback = INVALID_FUNCTION, Function attrsCallback = INVALID_FUNCTION)
{
	if (g_itemTypes == null)
		g_itemTypes = new ArrayList();
	
	if (g_itemTypeNameIndex == null)
	{
		g_itemTypeNameIndex = new StringMap();
	}
	else
	{
		int itemType;
		if (g_itemTypeNameIndex.GetValue(type, itemType))
		{
			delete view_as<Handle>(g_itemTypes.Get(itemType));
		}
	}

	DataPack itemType = new DataPack();
	itemType.WriteCell(plugin); // 0
	itemType.WriteFunction(useCallback); // 8
	itemType.WriteFunction(attrsCallback); // 16
	itemType.WriteString(type); // 24

	int index = g_itemTypes.Push(itemType);
	g_itemTypeNameIndex.SetValue(type, index);
}

public int Native_OpenInventory(Handle plugin, int numParams)
{       
	OpenInventory(GetNativeCell(1));
	return 0;
}

public int Native_OpenInventoryCategory(Handle plugin, int numParams)
{       
	OpenInventoryCategory(GetNativeCell(1), GetNativeCell(2));
	return 0;
}

public int Native_RegisterItemType(Handle plugin, int numParams)
{
	char type[STORE_MAX_TYPE_LENGTH];
	GetNativeString(1, type, sizeof(type));
	
	RegisterItemType(type, plugin, GetNativeFunction(2), GetNativeFunction(3));
	return 0;
}

public int Native_IsItemTypeRegistered(Handle plugin, int numParams)
{
	char type[STORE_MAX_TYPE_LENGTH];
	GetNativeString(1, type, sizeof(type));
	
	int typeIndex;
	return g_itemTypeNameIndex.GetValue(type, typeIndex);
}

public int Native_CallItemAttrsCallback(Handle plugin, int numParams)
{
	if (g_itemTypeNameIndex == null)
		return false;
		
	char type[STORE_MAX_TYPE_LENGTH];
	GetNativeString(1, type, sizeof(type));

	int typeIndex;
	if (!g_itemTypeNameIndex.GetValue(type, typeIndex))
		return false;

	char name[STORE_MAX_NAME_LENGTH];
	GetNativeString(2, name, sizeof(name));

	char attrs[STORE_MAX_ATTRIBUTES_LENGTH];
	GetNativeString(3, attrs, sizeof(attrs));		

	DataPack pack = view_as<DataPack>(g_itemTypes.Get(typeIndex));
	pack.Reset();

	Handle callbackPlugin = view_as<Handle>(pack.ReadCell());
	
	pack.Position = view_as<DataPackPos>(16);

	Function callback = pack.ReadFunction();

	delete pack;

	if (callback == INVALID_FUNCTION)
		return false;

	Call_StartFunction(callbackPlugin, callback);
	Call_PushString(name);
	Call_PushString(attrs);
	Call_Finish();	
	
	return true;
}
