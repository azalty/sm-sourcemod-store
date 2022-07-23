#pragma semicolon 1
#pragma newdecls required

#include <store/store-core>
#include <store/store-logging>
#include <store/store-backend>
#include <store/store-inventory>

#define MAX_CATEGORIES	32
#define MAX_ITEMS 		1024
#define MAX_LOADOUTS	32

enum struct Category
{
	int CategoryId;
	char CategoryDisplayName[STORE_MAX_DISPLAY_NAME_LENGTH];
	char CategoryDescription[STORE_MAX_DESCRIPTION_LENGTH];
	char CategoryRequirePlugin[STORE_MAX_REQUIREPLUGIN_LENGTH];
}

enum struct Item
{
	int ItemId;
	char ItemName[STORE_MAX_NAME_LENGTH];
	char ItemDisplayName[STORE_MAX_DISPLAY_NAME_LENGTH];
	char ItemDescription[STORE_MAX_DESCRIPTION_LENGTH];
	char ItemType[STORE_MAX_TYPE_LENGTH];
	char ItemLoadoutSlot[STORE_MAX_LOADOUTSLOT_LENGTH];
	int ItemPrice;
	int ItemCategoryId;
	bool ItemIsBuyable;
	bool ItemIsTradeable;
	bool ItemIsRefundable;
	int ItemFlags;
}

enum struct Loadout
{
	int LoadoutId;
	char LoadoutDisplayName[STORE_MAX_DISPLAY_NAME_LENGTH];
	char LoadoutGame[STORE_MAX_LOADOUTGAME_LENGTH];
	char LoadoutClass[STORE_MAX_LOADOUTCLASS_LENGTH];
	int LoadoutTeam;
}

Handle g_dbInitializedForward;
Handle g_reloadItemsForward;
Handle g_reloadItemsPostForward;

Handle g_hSQL;
int g_reconnectCounter = 0;

Category g_categories[MAX_CATEGORIES];
int g_categoryCount = -1;

Item g_items[MAX_ITEMS];
int g_itemCount = -1;

Loadout g_loadouts[MAX_LOADOUTS];
int g_loadoutCount = -1;

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
	CreateNative("Store_Register", Native_Register);
	CreateNative("Store_RegisterClient", Native_RegisterClient);

	CreateNative("Store_GetCategories", Native_GetCategories);
	CreateNative("Store_GetCategoryDisplayName", Native_GetCategoryDisplayName);
	CreateNative("Store_GetCategoryDescription", Native_GetCategoryDescription);
	CreateNative("Store_GetCategoryPluginRequired", Native_GetCategoryPluginRequired);
	
	CreateNative("Store_GetItems", Native_GetItems);
	CreateNative("Store_GetItemName", Native_GetItemName);	
	CreateNative("Store_GetItemDisplayName", Native_GetItemDisplayName);
	CreateNative("Store_GetItemDescription", Native_GetItemDescription);
	CreateNative("Store_GetItemType", Native_GetItemType);
	CreateNative("Store_GetItemLoadoutSlot", Native_GetItemLoadoutSlot);
	CreateNative("Store_GetItemPrice", Native_GetItemPrice);
	CreateNative("Store_GetItemCategory", Native_GetItemCategory);	
	CreateNative("Store_IsItemBuyable", Native_IsItemBuyable);
	CreateNative("Store_IsItemTradeable", Native_IsItemTradeable);	
	CreateNative("Store_IsItemRefundable", Native_IsItemRefundable);	
	CreateNative("Store_GetItemAttributes", Native_GetItemAttributes);	
	CreateNative("Store_WriteItemAttributes", Native_WriteItemAttributes);	

	CreateNative("Store_GetLoadouts", Native_GetLoadouts);
	CreateNative("Store_GetLoadoutDisplayName", Native_GetLoadoutDisplayName);
	CreateNative("Store_GetLoadoutGame", Native_GetLoadoutGame);
	CreateNative("Store_GetLoadoutClass", Native_GetLoadoutClass);
	CreateNative("Store_GetLoadoutTeam", Native_GetLoadoutTeam);
	
	CreateNative("Store_GetUserItems", Native_GetUserItems);
	CreateNative("Store_GetUserItemCount", Native_GetUserItemCount);
	CreateNative("Store_GetCredits", Native_GetCredits);
	
	CreateNative("Store_GiveCredits", Native_GiveCredits);
	CreateNative("Store_GiveCreditsToUsers", Native_GiveCreditsToUsers);	
	CreateNative("Store_GiveDifferentCreditsToUsers", Native_GiveDifferentCreditsToUsers);	
	CreateNative("Store_GiveItem", Native_GiveItem);

	CreateNative("Store_BuyItem", Native_BuyItem);
	CreateNative("Store_RemoveUserItem", Native_RemoveUserItem);

	CreateNative("Store_SetItemEquippedState", Native_SetItemEquippedState);
	CreateNative("Store_GetEquippedItemsByType", Native_GetEquippedItemsByType);
	
	CreateNative("Store_ReloadItemCache", Native_ReloadItemCache);

	RegPluginLibrary("store-backend");
	return APLRes_Success;
}

public Plugin myinfo =
{
	name        = "[Store] Backend",
	author      = "alongub, drixevel",
	description = "Backend component for [Store]",
	version     = STORE_VERSION,
	url         = "https://github.com/drixevel-dev/store"
};

/**
 * Plugin is loading.
 */
public void OnPluginStart()
{
	g_dbInitializedForward = CreateGlobalForward("Store_OnDatabaseInitialized", ET_Event);
	g_reloadItemsForward = CreateGlobalForward("Store_OnReloadItems", ET_Event);
	g_reloadItemsPostForward = CreateGlobalForward("Store_OnReloadItemsPost", ET_Event);
	
	RegAdminCmd("store_reloaditems", Command_ReloadItems, ADMFLAG_RCON, "Reloads store item cache.");
}

public void OnAllPluginsLoaded()
{
	ConnectSQL();
}

public void OnMapStart()
{
	if (g_hSQL != null)
	{
		ReloadItemCache();
	}
}

/**
 * Registers a player in the database:
 * 
 * - If the player is already in the database, his name will be updated according
 *   to the 'name' parameter provided.
 *
 * - If the player is not in the database (for example, a int player who just joined
 *   the server for the first time), he will be added using the account ID and name 
 *   provided.
 *
 * As with all other store-backend methods, this method is completely asynchronous.
 *
 * @param accountId		The account ID of the player, use GetSteamAccountID to convert a client index to account ID.
 * @param name          The name of the player.
 * @param credits 		The amount of credits to give to the player if it's his first register.
 *
 * @noreturn
 */
void Register(int accountId, const char[] name = "", int credits = 0)
{
	int size = 2 * 32 + 1;
	char[] safeName = new char[size];
	SQL_EscapeString(g_hSQL, name, safeName, size);
	
	char query[255];
	Format(query, sizeof(query), "INSERT INTO store_users (auth, name, credits) VALUES (%d, '%s', %d) ON DUPLICATE KEY UPDATE name = '%s';", accountId, safeName, credits, safeName);
	
	SQL_TQuery(g_hSQL, T_RegisterCallback, query, _, DBPrio_High);
}

/**
 * Registers a player in the database, provided his client index only. 
 *
 * This method converts the client index provided to an account id, retrieves 
 * the player's name, and calls Store_Register using that information.
 *
 * The logic of registering a player is explained in the Store_Register documentation.
 *
 * The store-core module calls this method every time a player joins the server.
 *
 * As with all other store-backend methods, this method is completely asynchronous.
 *
 * @param client 		Client index.
 * @param credits 		The amount of credits to give to the player if it's his first register. 
 *
 * @noreturn
 */
void RegisterClient(int client, int credits = 0)
{
	if (!IsClientInGame(client))
		return;

	if (IsFakeClient(client))
		return;

	char name[64];
	GetClientName(client, name, sizeof(name));
	
	Register(GetSteamAccountID(client), name, credits);
}

public void T_RegisterCallback(Database db, DBResultSet results, const char[] error, any data)
{
	if (results == null)
	{
		Store_LogError("SQL Error on Register: %s", error);
		return;
	}
}

/**
 * Retrieves all item categories from the database. 
 *
 * The store-backend module builds a cache of the categories retrieved the first time 
 * this method is called, for faster access the next time it's called.
 *
 * You can set the loadFromCache parameter of this method to false to retrieve categories
 * from the database and not from the cache.
 *
 * The store-core module calls this method when it is loaded to build a cache of 
 * categories.
 *
 * It also provides the store_reloaditems command to reload items and categories 
 * from the database. 
 *
 * To use this method, you can provide a callback for when the categories are loaded.
 * The callback will provide an array of the categories' IDs. You can then loop the array,
 * and find info about each category using the Store_GetCategory* methods.
 *
 * As with all other store-backend methods, this method is completely asynchronous.
 *
 * @param callback 		A callback which will be called when the categories are loaded.
 * @param plugin		The plugin owner of the callback.
 * @param loadFromCache	Whether to load categories from cache. If false, the method will 
 * 						query the database and rebuild its cache.
 * @param data 			Extra data value to pass to the callback.
 *
 * @noreturn
 */
void GetCategories(Function callback = INVALID_FUNCTION, Handle plugin = null, bool loadFromCache = true, any data = 0)
{
	if (loadFromCache && g_categoryCount != -1)
	{
		if (callback == INVALID_FUNCTION)
			return;

		int[] categories = new int[g_categoryCount];
		int count = 0;
		
		for (int category = 0; category < g_categoryCount; category++)
		{
			categories[count] = g_categories[category].CategoryId;
			count++;
		}
		
		Call_StartFunction(plugin, callback);
		Call_PushArray(categories, count);
		Call_PushCell(count);
		Call_PushCell(data);
		Call_Finish();
	}
	else
	{
		Handle pack = CreateDataPack();
		WritePackFunction(pack, callback);
		WritePackCell(pack, plugin);
		WritePackCell(pack, data);
	
		SQL_TQuery(g_hSQL, T_GetCategoriesCallback, "SELECT id, display_name, description, require_plugin FROM store_categories", pack);
	}
}

public void T_GetCategoriesCallback(Database db, DBResultSet results, const char[] error, DataPack pack)
{
	if (results == null)
	{
		CloseHandle(pack);
		
		Store_LogError("SQL Error on GetCategories: %s", error);
		return;
	}
	
	ResetPack(pack);
	
	Function callback = ReadPackFunction(pack);
	Handle plugin = ReadPackCell(pack);
	int arg = ReadPackCell(pack);
	
	CloseHandle(pack);
	
	g_categoryCount = 0;
	
	while (SQL_FetchRow(results))
	{
		g_categories[g_categoryCount].CategoryId = SQL_FetchInt(results, 0);
		SQL_FetchString(results, 1, g_categories[g_categoryCount].CategoryDisplayName, STORE_MAX_DISPLAY_NAME_LENGTH);
		SQL_FetchString(results, 2, g_categories[g_categoryCount].CategoryDescription, STORE_MAX_DESCRIPTION_LENGTH);
		SQL_FetchString(results, 3, g_categories[g_categoryCount].CategoryRequirePlugin, STORE_MAX_REQUIREPLUGIN_LENGTH);
		
		g_categoryCount++;
	}
	
	GetCategories(callback, plugin, true, arg);
}

int GetCategoryIndex(int id)
{
	for (int index = 0; index < g_categoryCount; index++)
	{
		if (g_categories[index].CategoryId == id)
			return index;
	}
	
	return -1;
}

/**
 * Retrieves items from the database. 
 *
 * The store-backend module builds a cache of the items retrieved the first time 
 * this method is called, for faster access the next time it's called.
 *
 * You can set the loadFromCache parameter of this method to false to retrieve categories
 * from the database and not from the cache.
 *
  * You can use the filter parameter to filter items returned by the following properties:
 *  - category_id (cell)
 *  - is_buyable (cell)
 *  - is_tradeable (cell)
 *  - type (string)
 *  - flags (cell)
 *
 * To use it, set it to a trie with some or all of the above properties.
 * IMPORTANT: You are *not* resposible for closing the filter trie's handle, 
 *            the store-backend module is.
 *
 * The store-backend module calls this method when it is loaded to build a cache of 
 * categories. It also provides the store_reloaditems command to reload items and categories 
 * from the database. 
 *
 * To use this method, you can provide a callback for when the items are loaded.
 * The callback will provide an array of the items' IDs. You can then loop the array,
 * and find info about each item using the Store_GetItem* methods.
 *
 *
 * As with all other store-backend methods, this method is completely asynchronous.
 *
 * @param filter            A trie which will be used to filter the loadouts returned.
 * @param callback		    A callback which will be called when the items are loaded.
 * @param plugin			The plugin owner of the callback.
 * @param loadFromCache     Whether to load items from cache. If false, the method will 
 *                          query the database and rebuild its cache.
 * @param data              Extra data value to pass to the callback.
 *
 * @noreturn
 */
void GetItems(Handle filter = null, Function callback = INVALID_FUNCTION, Handle plugin = null, bool loadFromCache = true, any data = 0)
{
	if (loadFromCache && g_itemCount != -1)
	{
		if (callback == INVALID_FUNCTION)
			return;

		int categoryId;
		bool categoryFilter = filter == null ? false : GetTrieValue(filter, "category_id", categoryId);
		
		bool isBuyable;
		bool buyableFilter = filter == null ? false : GetTrieValue(filter, "is_buyable", isBuyable);

		bool isTradeable;
		bool tradeableFilter = filter == null ? false : GetTrieValue(filter, "is_tradeable", isTradeable);

		bool isRefundable;
		bool refundableFilter = filter == null ? false : GetTrieValue(filter, "is_refundable", isRefundable);

		char type[STORE_MAX_TYPE_LENGTH];
		bool typeFilter = filter == null ? false : GetTrieString(filter, "type", type, sizeof(type));

		int flags;
		bool flagsFilter = filter == null ? false : GetTrieValue(filter, "flags", flags);

		CloseHandle(filter);
		
		int[] items = new int[g_itemCount];

		int count = 0;
		
		for (int item = 0; item < g_itemCount; item++)
		{
			if ((!categoryFilter || categoryId == g_items[item].ItemCategoryId) &&
				(!buyableFilter || isBuyable == g_items[item].ItemIsBuyable) &&
				(!tradeableFilter || isTradeable == g_items[item].ItemIsTradeable) &&
				(!refundableFilter || isRefundable == g_items[item].ItemIsRefundable) &&
				(!typeFilter || StrEqual(type, g_items[item].ItemType)) &&
				(!flagsFilter || !g_items[item].ItemFlags || (flags & g_items[item].ItemFlags)))
			{
				items[count] = g_items[item].ItemId;
				count++;
			}
		}
		
		Call_StartFunction(plugin, callback);
		Call_PushArray(items, count);
		Call_PushCell(count);
		Call_PushCell(data);
		Call_Finish();
	}
	else
	{
		Handle pack = CreateDataPack();
		WritePackCell(pack, filter);
		WritePackFunction(pack, callback);
		WritePackCell(pack, plugin);
		WritePackCell(pack, data);
	
		SQL_TQuery(g_hSQL, T_GetItemsCallback, "SELECT id, name, display_name, description, type, loadout_slot, price, category_id, attrs, LENGTH(attrs) AS attrs_len, is_buyable, is_tradeable, is_refundable, flags FROM store_items ORDER BY price, display_name", pack);
	}
}

public void T_GetItemsCallback(Database db, DBResultSet results, const char[] error, DataPack pack)
{
	if (results == null)
	{
		CloseHandle(pack);
			
		Store_LogError("SQL Error on GetItems: %s", error);
		return;
	}

	Call_StartForward(g_reloadItemsForward);
	Call_Finish();
	
	ResetPack(pack);
	
	Handle filter = ReadPackCell(pack);
	Function callback = ReadPackFunction(pack);
	Handle plugin = ReadPackCell(pack);
	int arg = ReadPackCell(pack);
	
	CloseHandle(pack);
	
	g_itemCount = 0;
	
	while (SQL_FetchRow(results))
	{
		g_items[g_itemCount].ItemId = SQL_FetchInt(results, 0);
		SQL_FetchString(results, 1, g_items[g_itemCount].ItemName, STORE_MAX_NAME_LENGTH);
		SQL_FetchString(results, 2, g_items[g_itemCount].ItemDisplayName, STORE_MAX_DISPLAY_NAME_LENGTH);
		SQL_FetchString(results, 3, g_items[g_itemCount].ItemDescription, STORE_MAX_DESCRIPTION_LENGTH);
		SQL_FetchString(results, 4, g_items[g_itemCount].ItemType, STORE_MAX_TYPE_LENGTH);
		SQL_FetchString(results, 5, g_items[g_itemCount].ItemLoadoutSlot, STORE_MAX_LOADOUTSLOT_LENGTH);
		g_items[g_itemCount].ItemPrice = SQL_FetchInt(results, 6);		
		g_items[g_itemCount].ItemCategoryId = SQL_FetchInt(results, 7);
		
		if (!SQL_IsFieldNull(results, 8))
		{
			int attrsLength = SQL_FetchInt(results, 9);

			char[] attrs = new char[attrsLength+1];
			SQL_FetchString(results, 8, attrs, attrsLength+1);

			Store_CallItemAttrsCallback(g_items[g_itemCount].ItemType, g_items[g_itemCount].ItemName, attrs);
		}

		g_items[g_itemCount].ItemIsBuyable = view_as<bool>(SQL_FetchInt(results, 10));
		g_items[g_itemCount].ItemIsTradeable = view_as<bool>(SQL_FetchInt(results, 11));
		g_items[g_itemCount].ItemIsRefundable = view_as<bool>(SQL_FetchInt(results, 12));

		char flags[11];
		SQL_FetchString(results, 13, flags, sizeof(flags));
		g_items[g_itemCount].ItemFlags = ReadFlagString(flags);

		g_itemCount++;
	}

	Call_StartForward(g_reloadItemsPostForward);
	Call_Finish();
	
	GetItems(filter, callback, plugin, true, arg);
}

int GetItemIndex(int id)
{
	for (int index = 0; index < g_itemCount; index++)
	{
		if (g_items[index].ItemId == id)
			return index;
	}
	
	return -1;
}

/** 
 * Retrieves item attributes asynchronously.
 *
 * @param itemName			Item's name.
 *
 * @noreturn
 */
void GetItemAttributes(const char[] itemName, Function callback = INVALID_FUNCTION, Handle plugin = null, any data = 0) 
{
	Handle pack = CreateDataPack();
	WritePackString(pack, itemName);
	WritePackFunction(pack, callback);
	WritePackCell(pack, plugin);
	WritePackCell(pack, data);

	int itemNameLength = 2*strlen(itemName)+1;
	
	char[] itemNameSafe = new char[itemNameLength];
	SQL_EscapeString(g_hSQL, itemName, itemNameSafe, itemNameLength);

	char query[256];
	Format(query, sizeof(query), "SELECT attrs, LENGTH(attrs) AS attrs_len FROM store_items WHERE name = '%s'", itemNameSafe);
	
	SQL_TQuery(g_hSQL, T_GetItemAttributesCallback, query, pack);
}

public void T_GetItemAttributesCallback(Database db, DBResultSet results, const char[] error, DataPack pack)
{
	if (results == null)
	{
		CloseHandle(pack);
			
		Store_LogError("SQL Error on GetItemAttributes: %s", error);
		return;
	}
	
	ResetPack(pack);
	
	char itemName[STORE_MAX_NAME_LENGTH];
	ReadPackString(pack, itemName, sizeof(itemName));

	Function callback = ReadPackFunction(pack);
	Handle plugin = ReadPackCell(pack);
	int arg = ReadPackCell(pack);
	
	CloseHandle(pack);

	if (SQL_FetchRow(results))
	{
		if (!SQL_IsFieldNull(results, 0))
		{
			int attrsLength = SQL_FetchInt(results, 1);

			char[] attrs = new char[attrsLength+1];
			SQL_FetchString(results, 0, attrs, attrsLength+1);

			if (callback != INVALID_FUNCTION)
			{
				Call_StartFunction(plugin, callback);
				Call_PushString(itemName);
				Call_PushString(attrs);
				Call_PushCell(arg);
				Call_Finish();					
			}
		
		}
	}
}

/** 
 * Modifies item attributes asynchronously.
 *
 * @param itemName			Item's name.
 *
 * @noreturn
 */
void WriteItemAttributes(const char[] itemName, const char[] attrs, Function callback = INVALID_FUNCTION, Handle plugin = null, any data = 0)
{
	Handle pack = CreateDataPack();
	WritePackFunction(pack, callback);
	WritePackCell(pack, plugin);
	WritePackCell(pack, data);

	int itemNameLength = 2*strlen(itemName)+1;
	char[] itemNameSafe = new char[itemNameLength];
	SQL_EscapeString(g_hSQL, itemName, itemNameSafe, itemNameLength);

	int attrsLength = 10 * 1024;
	char[] attrsSafe = new char[2*attrsLength+1];
	SQL_EscapeString(g_hSQL, attrs, attrsSafe, 2*attrsLength+1);
	
	char[] query = new char[attrsLength + 256];
	Format(query, attrsLength + 256, "UPDATE store_items SET attrs = '%s}' WHERE name = '%s'", attrsSafe, itemNameSafe);	

	SQL_TQuery(g_hSQL, T_WriteItemAttributesCallback, query, pack);	
}

public void T_WriteItemAttributesCallback(Database db, DBResultSet results, const char[] error, DataPack pack)
{
	if (results == null)
	{
		CloseHandle(pack);
			
		Store_LogError("SQL Error on WriteItemAttributes: %s", error);
		return;
	}
	
	ResetPack(pack);

	Function callback = ReadPackFunction(pack);
	Handle plugin = ReadPackCell(pack);
	int arg = ReadPackCell(pack);
	
	CloseHandle(pack);

	if (callback != INVALID_FUNCTION)
	{
		Call_StartFunction(plugin, callback);
		Call_PushCell(true);
		Call_PushCell(arg);
		Call_Finish();					
	}
}

/**
 * Retrieves loadouts from the database. 
 *
 * The store-backend module builds a cache of the loadouts retrieved the first time 
 * this method is called, for faster access the next time it's called.
 *
 * You can set the loadFromCache parameter of this method to false to retrieve loadouts
 * from the database and not from the cache.
 *
 * You can use the filter parameter to filter loadouts returned by the following properties:
 *  - game (string)
 *  - team (cell)
 *  - class (string)
 *
 * To use it, set it to a trie with some or all of the above properties.
 * IMPORTANT: You are *not* resposible for closing the filter trie's handle, 
 *            the store-backend module is.
 * 
 * The store-loadout module calls this method when it is loaded to build a cache of 
 * loadouts.
 *
 * To use this method, you can provide a callback for when the items are loaded.
 * The callback will provide an array of the loadouts' IDs. You can then loop the array,
 * and find info about each item using the Store_GetLoadout* methods.
 *
 * As with all other store-backend methods, this method is completely asynchronous.
 *
 * @param filter            A trie which will be used to filter the loadouts returned.
 * @param callback		   	A callback which will be called when the items are loaded.
 * @param plugin			The plugin owner of the callback.
 * @param loadFromCache     Whether to load items from cache. If false, the method will 
 *                          query the database and rebuild its cache.
 * @param data              Extra data value to pass to the callback.
 *
 * @noreturn
 */
void GetLoadouts(Handle filter, Function callback = INVALID_FUNCTION, Handle plugin = null, bool loadFromCache = true, any data = 0)
{
	if (loadFromCache && g_loadoutCount != -1)
	{
		if (callback == INVALID_FUNCTION)
			return;

		int[] loadouts = new int[g_loadoutCount];
		int count = 0;
		
		char game[32];
		bool gameFilter = filter == null ? false : GetTrieString(filter, "game", game, sizeof(game));
		
		char class[32];
		bool classFilter = filter == null ? false : GetTrieString(filter, "class", class, sizeof(class));
		
		// int team = -1;
		// bool teamFilter = filter == null ? false : GetTrieValue(filter, "team", team);
		
		CloseHandle(filter);
		
		for (int loadout = 0; loadout < g_loadoutCount; loadout++)
		{	
			if (
				(!gameFilter || StrEqual(game, "") || StrEqual(g_loadouts[loadout].LoadoutGame, "") || StrEqual(game, g_loadouts[loadout].LoadoutGame)) &&
			 	(!classFilter || StrEqual(class, "") || StrEqual(g_loadouts[loadout].LoadoutClass, "") || StrEqual(class, g_loadouts[loadout].LoadoutClass))
				// (!teamFilter || team == -1 || team == g_loadouts[loadout].LoadoutTeam)
				)
			{
				loadouts[count] = g_loadouts[loadout].LoadoutId;
				count++;
			}
		}
		
		Call_StartFunction(plugin, callback);
		Call_PushArray(loadouts, count);
		Call_PushCell(count);
		Call_PushCell(data);
		Call_Finish();
	}
	else
	{
		Handle pack = CreateDataPack();
		WritePackCell(pack, filter);
		WritePackFunction(pack, callback);
		WritePackCell(pack, plugin);
		WritePackCell(pack, data);
	
		SQL_TQuery(g_hSQL, T_GetLoadoutsCallback, "SELECT id, display_name, game, class, team FROM store_loadouts", pack);
	}
}

public void T_GetLoadoutsCallback(Database db, DBResultSet results, const char[] error, DataPack pack)
{
	if (results == null)
	{
		CloseHandle(pack);
		
		Store_LogError("SQL Error on GetLoadouts: %s", error);
		return;
	}
	
	ResetPack(pack);
	
	Handle filter = ReadPackCell(pack);
	Function callback = ReadPackFunction(pack);
	Handle plugin = ReadPackCell(pack);
	int arg = ReadPackCell(pack);
	
	CloseHandle(pack);
	
	g_loadoutCount = 0;
	
	while (SQL_FetchRow(results))
	{
		g_loadouts[g_loadoutCount].LoadoutId = SQL_FetchInt(results, 0);
		SQL_FetchString(results, 1, g_loadouts[g_loadoutCount].LoadoutDisplayName, STORE_MAX_DISPLAY_NAME_LENGTH);
		SQL_FetchString(results, 2, g_loadouts[g_loadoutCount].LoadoutGame, STORE_MAX_LOADOUTGAME_LENGTH);
		SQL_FetchString(results, 3, g_loadouts[g_loadoutCount].LoadoutClass, STORE_MAX_LOADOUTCLASS_LENGTH);
		
		if (SQL_IsFieldNull(results, 4))
			g_loadouts[g_loadoutCount].LoadoutTeam = -1;
		else
			g_loadouts[g_loadoutCount].LoadoutTeam = SQL_FetchInt(results, 4);
		
		g_loadoutCount++;
	}
	
	GetLoadouts(filter, callback, plugin, true, arg);
}

int GetLoadoutIndex(int id)
{
	for (int index = 0; index < g_loadoutCount; index++)
	{
		if (g_loadouts[index].LoadoutId == id)
			return index;
	}
	
	return -1;
}

/**
 * Retrieves items of a specific player in a specific category. 
 *
 * To use this method, you can provide a callback for when the items are loaded.
 * The callback will provide an array of the items' IDs. You can then loop the array,
 * and find info about each item using the Store_GetItem* methods.
 * 
 * You can use the filter parameter to filter items returned by the following properties:
 *  - category_id (cell)
 *  - is_buyable (cell)
 *  - is_tradeable (cell)
 *  - is_refundable (cell)
 *  - type (string)
 *
 * To use it, set it to a trie with some or all of the above properties.
 * IMPORTANT: You are *not* resposible for closing the filter trie's handle, 
 *            the store-backend module is.
 *
 * The items returned by this method are grouped by the item's name. That means that 
 * if a player has multiple items with the same name (the unique identifier of the item, NOT its 
 * display name), then the array will only have one element of that item.
 *
 * To determine how many items the player has of the same name, the callback provides the
 * itemCount[] array.
 *
 * To deremine whether or not an item is equipped in the loadout specified, the callback
 * provides the equipped[] array.
 *
 * For a full example of a usage of this method, see the store-inventory module.
 *
 * As with all other store-backend methods, this method is completely asynchronous.
 *
 * @param filter			A trie which will be used to filter the loadouts returned.
 * @param accountId		    The account ID of the player, use GetSteamAccountID to convert a client index to account ID.
 * @param loadoutId         The loadout which will be used to determine whether an item is equipped or not.
 * @param callback		    A callback which will be called when the items are loaded.
 * @param plugin 			The plugin owner of the callback.
 * @param data              Extra data value to pass to the callback.
 *
 * @noreturn
 */
void GetUserItems(Handle filter, int accountId, int loadoutId, Function callback = INVALID_FUNCTION, Handle plugin = null, any data = 0)
{
	Handle pack = CreateDataPack();
	WritePackCell(pack, filter); // 0 
	WritePackCell(pack, accountId); // 8
	WritePackCell(pack, loadoutId);	// 16
	WritePackFunction(pack, callback); // 24
	WritePackCell(pack, plugin); // 32
	WritePackCell(pack, data); // 40
	
	if (g_itemCount == -1)
	{
		Store_LogWarning("Store_GetUserItems has been called before item loading.");
		GetItems(null, GetUserItemsLoadCallback, null, true, pack);
		
		return;
	}
	
	char query[1906];
	Format(query, sizeof(query), "SELECT item_id, EXISTS(SELECT * FROM store_users_items_loadouts WHERE store_users_items_loadouts.useritem_id = store_users_items.id AND store_users_items_loadouts.loadout_id = %d) AS equipped, COUNT(*) AS count FROM store_users_items INNER JOIN store_users ON store_users.id = store_users_items.user_id INNER JOIN store_items ON store_items.id = store_users_items.item_id WHERE store_users.auth = %d AND ((store_users_items.acquire_date IS NULL OR store_items.expiry_time IS NULL OR store_items.expiry_time = 0) OR (store_users_items.acquire_date IS NOT NULL AND store_items.expiry_time IS NOT NULL AND store_items.expiry_time <> 0 AND DATE_ADD(store_users_items.acquire_date, INTERVAL store_items.expiry_time SECOND) > NOW()))", loadoutId, accountId);

	int categoryId;
	if (GetTrieValue(filter, "category_id", categoryId))
		Format(query, sizeof(query), "%s AND store_items.category_id = %d", query, categoryId);

	bool isBuyable;
	if (GetTrieValue(filter, "is_buyable", isBuyable))
		Format(query, sizeof(query), "%s AND store_items.is_buyable = %b", query, isBuyable);

	bool isTradeable;
	if (GetTrieValue(filter, "is_tradeable", isTradeable))
		Format(query, sizeof(query), "%s AND store_items.is_tradeable = %b", query, isTradeable);

	bool isRefundable;
	if (GetTrieValue(filter, "is_refundable", isRefundable))
		Format(query, sizeof(query), "%s AND store_items.is_refundable = %b", query, isRefundable);
			
	char type[STORE_MAX_TYPE_LENGTH];
	if (GetTrieString(filter, "type", type, sizeof(type)))
	{
		int typeLength = 2*strlen(type)+1;

		char[] buffer = new char[typeLength];
		SQL_EscapeString(g_hSQL, type, buffer, typeLength);

		Format(query, sizeof(query), "%s AND store_items.type = '%s'", query, buffer);
	}

	Format(query, sizeof(query), "%s GROUP BY item_id", query);

	CloseHandle(filter);

	SQL_TQuery(g_hSQL, T_GetUserItemsCallback, query, pack, DBPrio_High);
}

public void GetUserItemsLoadCallback(int[] ids, int count, DataPack pack)
{
	ResetPack(pack);
	
	Handle filter = ReadPackCell(pack);
	int accountId = ReadPackCell(pack);  
	int loadoutId = ReadPackCell(pack); 
	Function callback = ReadPackFunction(pack);
	Handle plugin = ReadPackCell(pack); 
	int arg = ReadPackCell(pack); 
	
	CloseHandle(pack);
	
	GetUserItems(filter, accountId, loadoutId, callback, plugin, arg);
}

public void T_GetUserItemsCallback(Database db, DBResultSet results, const char[] error, DataPack pack)
{
	if (results == null)
	{
		CloseHandle(pack);
		
		Store_LogError("SQL Error on GetUserItems: %s", error);
		return;
	}
	
	SetPackPosition(pack, view_as<DataPackPos>(16));	

	int loadoutId = ReadPackCell(pack);	
	Function callback = ReadPackFunction(pack);
	Handle plugin = ReadPackCell(pack);
	int arg = ReadPackCell(pack);
	
	CloseHandle(pack);
	
	int count = SQL_GetRowCount(results);

	int[] ids = new int[count];
	bool[] equipped = new bool[count];
	int[] itemCount = new int[count];
	
	int index = 0;
	while (SQL_FetchRow(results))
	{
		ids[index] = SQL_FetchInt(results, 0);
		equipped[index] = view_as<bool>(SQL_FetchInt(results, 1));
		itemCount[index] = SQL_FetchInt(results, 2);
		
		index++;
	}
	
	Call_StartFunction(plugin, callback);
	Call_PushArray(ids, count);
	Call_PushArray(equipped, count);
	Call_PushArray(itemCount, count);	
	Call_PushCell(count);
	Call_PushCell(loadoutId);
	Call_PushCell(arg);
	Call_Finish();
}

/**
 * Retrieves the amount of the same item a user has.
 *
 * As with all other store-backend methods, this method is completely asynchronous.
 *
 * @param accountId		    The account ID of the player, use GetSteamAccountID to convert a client index to account ID.
 * @param itemName          The name of the item.
 * @param callback		    A callback which will be called when the items are loaded.
 * @param plugin			The plugin owner of the callback. 
 * @param data              Extra data value to pass to the callback.
 *
 * @noreturn
 */
void GetUserItemCount(int accountId, const char[] itemName, Function callback = INVALID_FUNCTION, Handle plugin = null, any data = 0)
{
	Handle pack = CreateDataPack();
	WritePackFunction(pack, callback);
	WritePackCell(pack, plugin);
	WritePackCell(pack, data);

	int itemNameLength = 2*strlen(itemName)+1;

	char[] itemNameSafe = new char[itemNameLength];
	SQL_EscapeString(g_hSQL, itemName, itemNameSafe, itemNameLength);

	char query[512];
	Format(query, sizeof(query), "SELECT COUNT(*) AS count FROM store_users_items INNER JOIN store_users ON store_users.id = store_users_items.user_id INNER JOIN store_items ON store_items.id = store_users_items.item_id WHERE store_items.name = '%s' AND store_users.auth = %d", itemNameSafe, accountId);

	SQL_TQuery(g_hSQL, T_GetUserItemCountCallback, query, pack, DBPrio_High);
}

public void T_GetUserItemCountCallback(Database db, DBResultSet results, const char[] error, DataPack pack)
{
	if (results == null)
	{
		CloseHandle(pack);
		
		Store_LogError("SQL Error on GetUserItemCount: %s", error);
		return;
	}
	
	ResetPack(pack);
	
	Function callback = ReadPackFunction(pack);
	Handle plugin = ReadPackCell(pack);
	int arg = ReadPackCell(pack);

	CloseHandle(pack);
	
	if (SQL_FetchRow(results))
	{
		Call_StartFunction(plugin, callback);
		Call_PushCell(SQL_FetchInt(results, 0));
		Call_PushCell(arg);
		Call_Finish();	
	}
}

/**
 * Retrieves the amount of credits that a player currently has.
 *
 * As with all other store-backend methods, this method is completely asynchronous.
 *
 * @param accountId		    The account ID of the player, use GetSteamAccountID to convert a client index to account ID.
 * @param callback		    A callback which will be called when the credits amount is loaded.
 * @param plugin			The plugin owner of the callback.
 * @param data              Extra data value to pass to the callback.
 *
 * @noreturn
 */
void GetCredits(int accountId, Function callback = INVALID_FUNCTION, Handle plugin = null, any data = 0)
{
	Handle pack = CreateDataPack();
	WritePackFunction(pack, callback);
	WritePackCell(pack, plugin);
	WritePackCell(pack, data);
		
	char query[255];
	Format(query, sizeof(query), "SELECT credits FROM store_users WHERE auth = %d", accountId);

	SQL_TQuery(g_hSQL, T_GetCreditsCallback, query, pack, DBPrio_High);
}

public void T_GetCreditsCallback(Database db, DBResultSet results, const char[] error, DataPack pack)
{
	if (results == null)
	{
		CloseHandle(pack);
		
		Store_LogError("SQL Error on GetCredits: %s", error);
		return;
	}
	
	ResetPack(pack);
	
	Function callback = ReadPackFunction(pack);
	Handle plugin = ReadPackCell(pack);
	int arg = ReadPackCell(pack);
	
	CloseHandle(pack);
	
	if (SQL_FetchRow(results))
	{
		Call_StartFunction(plugin, callback);
		Call_PushCell(SQL_FetchInt(results, 0));
		Call_PushCell(arg);
		Call_Finish();	
	}
}

/**
 * Buys an item for a player, using his credits.
 * 
 * To determine whether or not the process of buying that item was successful,
 * use the 'success' parameter that is provided by the callback.
 * A false value of that parameter probably means that the user didn't have enough credits.
 *
 * As with all other store-backend methods, this method is completely asynchronous.
 *
 * @param accountId		    The account ID of the player, use GetSteamAccountID to convert a client index to account ID.
 * @param itemId            The ID of the item to buy.
 * @param callback		    A callback which will be called when the operation is finished.
 * @param plugin			The plugin owner of the callback.
 * @param data              Extra data value to pass to the callback.
 *
 * @noreturn
 */
void BuyItem(int accountId, int itemId, Function callback = INVALID_FUNCTION, Handle plugin = null, any data = 0)
{
	Handle pack = CreateDataPack();
	WritePackCell(pack, itemId); // 0
	WritePackCell(pack, accountId); // 8
	WritePackFunction(pack, callback); // 16
	WritePackCell(pack, plugin); // 24
	WritePackCell(pack, data); // 32
	
	GetCredits(accountId, T_BuyItemGetCreditsCallback, null, pack);
}

public void T_BuyItemGetCreditsCallback(int credits, DataPack pack)
{
	ResetPack(pack);
	
	int itemId = ReadPackCell(pack); 
	int accountId = ReadPackCell(pack); 
	Function callback = ReadPackFunction(pack);
	Handle plugin = ReadPackCell(pack);
	int arg = ReadPackCell(pack);
	
	if (credits < g_items[GetItemIndex(itemId)].ItemPrice)
	{
		Call_StartFunction(plugin, callback);
		Call_PushCell(0);
		Call_PushCell(arg);
		Call_Finish();	
		
		return;
	}

	GiveCredits(accountId, -g_items[GetItemIndex(itemId)].ItemPrice, BuyItemGiveCreditsCallback, _, pack);
}

public void BuyItemGiveCreditsCallback(int accountId, DataPack pack)
{
	ResetPack(pack);
	
	int itemId = ReadPackCell(pack);
	GiveItem(accountId, itemId, Store_Shop, BuyItemGiveItemCallback, _, pack);
}

public void BuyItemGiveItemCallback(int accountId, DataPack pack)
{
	SetPackPosition(pack, view_as<DataPackPos>(16));
	
	Function callback = ReadPackFunction(pack);
	Handle plugin = ReadPackCell(pack);
	int arg = ReadPackCell(pack);
	
	CloseHandle(pack);
	
	Call_StartFunction(plugin, callback);
	Call_PushCell(1);
	Call_PushCell(arg);
	Call_Finish();	
}

/**
 * Removes one copy of an item from a player's inventory.
 * 
 * As with all other store-backend methods, this method is completely asynchronous.
 *
 * @param accountId		    The account ID of the player, use GetSteamAccountID to convert a client index to account ID.
 * @param itemId            The ID of the item to use.
 * @param callback		    A callback which will be called when the operation is finished.
 * @param plugin			The plugin owner of the callback.
 * @param data              Extra data value to pass to the callback.
 *
 * @noreturn
 */
void RemoveUserItem(int accountId, int itemId, Function callback = INVALID_FUNCTION, Handle plugin = null, any data = 0)
{
	Handle pack = CreateDataPack();
	WritePackCell(pack, accountId); // 0
	WritePackCell(pack, itemId); // 8
	WritePackFunction(pack, callback); // 16
	WritePackCell(pack, plugin);
	WritePackCell(pack, data);
	
	UnequipItem(accountId, itemId, -1, RemoveUserItemUnnequipCallback, _, pack);
}

public void RemoveUserItemUnnequipCallback(int accountId, int itemId, int loadoutId, DataPack pack)
{
	char query[255];
	Format(query, sizeof(query), "DELETE FROM store_users_items WHERE store_users_items.item_id = %d AND store_users_items.user_id IN (SELECT store_users.id FROM store_users WHERE store_users.auth = %d) LIMIT 1", itemId, accountId);
	
	SQL_TQuery(g_hSQL, T_RemoveUserItemCallback, query, pack, DBPrio_High);	
}

public void T_RemoveUserItemCallback(Database db, DBResultSet results, const char[] error, DataPack pack)
{
	if (results == null)
	{
		CloseHandle(pack);
		
		Store_LogError("SQL Error on UseItem: %s", error);
		return;
	}
	
	ResetPack(pack);
		
	int accountId = ReadPackCell(pack);
	int itemId = ReadPackCell(pack);
	Function callback = ReadPackFunction(pack);
	Handle plugin = ReadPackCell(pack);
	int arg = ReadPackCell(pack);
	
	CloseHandle(pack);
	
	Call_StartFunction(plugin, callback);
	Call_PushCell(accountId);
	Call_PushCell(itemId);	
	Call_PushCell(arg);
	Call_Finish();	
}

/**
 * Changes item equipped state in a specific loadout for a player.
 * 
 * As with all other store-backend methods, this method is completely asynchronous.
 *
 * @param accountId		    The account ID of the player, use GetSteamAccountID to convert a client index to account ID.
 * @param itemId            The ID of the item to change equipped state to.
 * @param loadoutId         The loadout to equip the item in.
 * @param isEquipped		Whether or not the item is equipped in the specified loadout.
 * @param callback		    A callback which will be called when the operation is finished.
 * @param data              Extra data value to pass to the callback.
 *
 * @noreturn
 */
void SetItemEquippedState(int accountId, int itemId, int loadoutId, bool isEquipped, Function callback = INVALID_FUNCTION, Handle plugin = null, any data = 0)
{
	if (isEquipped)
	{
		EquipItem(accountId, itemId, loadoutId, callback, plugin, data);
	}
	else
	{
		UnequipItem(accountId, itemId, loadoutId, callback, plugin, data);
	}
}

/**
 * Equips an item for a player in a loadout.
 * 
 * As with all other store-backend methods, this method is completely asynchronous.
 *
 * @param accountId		    The account ID of the player, use GetSteamAccountID to convert a client index to account ID.
 * @param itemId            The ID of the item to equip.
 * @param loadoutId         The loadout to equip the item in.
 * @param callback		    A callback which will be called when the operation is finished.
 * @param plugin			The plugin owner of the callback.
 * @param data              Extra data value to pass to the callback.
 *
 * @noreturn
 */
void EquipItem(int accountId, int itemId, int loadoutId, Function callback = INVALID_FUNCTION, Handle plugin = null, any data = 0)
{
	Handle pack = CreateDataPack();
	WritePackCell(pack, accountId);
	WritePackCell(pack, itemId);
	WritePackCell(pack, loadoutId);	
	WritePackFunction(pack, callback);
	WritePackCell(pack, plugin);
	WritePackCell(pack, data);
	
	UnequipItem(accountId, itemId, loadoutId, EquipUnequipItemCallback, _, pack);
}

public void EquipUnequipItemCallback(int accountId, int itemId, int loadoutId, DataPack pack)
{
	char query[512];
	Format(query, sizeof(query), "INSERT INTO store_users_items_loadouts (loadout_id, useritem_id) SELECT %d AS loadout_id, store_users_items.id FROM store_users_items INNER JOIN store_users ON store_users.id = store_users_items.user_id WHERE store_users.auth = %d AND store_users_items.item_id = %d LIMIT 1", loadoutId, accountId, itemId);
	
	SQL_TQuery(g_hSQL, T_EquipItemCallback, query, pack, DBPrio_High);	
}

public void T_EquipItemCallback(Database db, DBResultSet results, const char[] error, DataPack pack)
{
	if (results == null)
	{
		CloseHandle(pack);
		
		Store_LogError("SQL Error on EquipItem: %s", error);
		return;
	}
	
	ResetPack(pack);
	
	int accountId = ReadPackCell(pack);
	int itemId = ReadPackCell(pack);
	int loadoutId = ReadPackCell(pack);
	Function callback = ReadPackFunction(pack);
	Handle plugin = ReadPackCell(pack);
	int arg = ReadPackCell(pack);
	
	CloseHandle(pack);
	
	Call_StartFunction(plugin, callback);
	Call_PushCell(accountId);
	Call_PushCell(itemId);
	Call_PushCell(loadoutId);	
	Call_PushCell(arg);
	Call_Finish();	
}

/**
 * Unequips an item for a player in a loadout.
 * 
 * You can unequip an item in all client's loadouts by setting loadoutId to -1.
 *
 * As with all other store-backend methods, this method is completely asynchronous.
 *
 * @param accountId		    The account ID of the player, use GetSteamAccountID to convert a client index to account ID.
 * @param itemId           	The ID of the item to unequip.
 * @param loadoutId         The loadout to unequip the item in.
 * @param callback		    A callback which will be called when the operation is finished.
 * @param plugin			The plugin owner of the callback.
 * @param data             	Extra data value to pass to the callback.
 *
 * @noreturn
 */
void UnequipItem(int accountId, int itemId, int loadoutId, Function callback = INVALID_FUNCTION, Handle plugin = null, any data = 0)
{
	Handle pack = CreateDataPack();
	WritePackCell(pack, accountId);
	WritePackCell(pack, itemId);
	WritePackCell(pack, loadoutId);
	WritePackFunction(pack, callback);
	WritePackCell(pack, plugin);
	WritePackCell(pack, data);
	
	char query[512];
	Format(query, sizeof(query), "DELETE store_users_items_loadouts FROM store_users_items_loadouts INNER JOIN store_users_items ON store_users_items.id = store_users_items_loadouts.useritem_id INNER JOIN store_users ON store_users.id = store_users_items.user_id INNER JOIN store_items ON store_items.id = store_users_items.item_id WHERE store_users.auth = %d AND store_items.loadout_slot = (SELECT loadout_slot from store_items WHERE store_items.id = %d)", accountId, itemId);
	
	if (loadoutId != -1)
	{
		Format(query, sizeof(query), "%s AND store_users_items_loadouts.loadout_id = %d", query, loadoutId);
	}

	SQL_TQuery(g_hSQL, T_UnequipItemCallback, query, pack, DBPrio_High);	
}

public void T_UnequipItemCallback(Database db, DBResultSet results, const char[] error, DataPack pack)
{
	if (results == null)
	{
		CloseHandle(pack);
		
		Store_LogError("SQL Error on UnequipItem: %s", error);
		return;
	}
	
	ResetPack(pack);
	
	int accountId = ReadPackCell(pack);
	int itemId = ReadPackCell(pack);
	int loadoutId = ReadPackCell(pack);
	Function callback = ReadPackFunction(pack);
	Handle plugin = ReadPackCell(pack);
	int arg = ReadPackCell(pack);
	
	CloseHandle(pack);
	
	Call_StartFunction(plugin, callback);
	Call_PushCell(accountId);
	Call_PushCell(itemId);
	Call_PushCell(loadoutId);
	Call_PushCell(arg);
	Call_Finish();	
}

/**
 * Retrieves equipped items of a specific player in a specific type. 
 *
 * To use this method, you can provide a callback for when the items are loaded.
 * The callback will provide an array of the items' IDs. You can then loop the array,
 * and find info about each item using the Store_GetItem* methods.
 * 
 * The items returned by this method are grouped by the item's name. That means that 
 * if a player has multiple items with the same name (the unique identifier of the item, NOT its 
 * display name), then the array will only have one element of that item.
 *
 * To determine how many items the player has of the same name, the callback provides the
 * itemCount[] array.
 *
 * To deremine whether or not an item is equipped in the loadout specified, the callback
 * provides the equipped[] array.
 *
 * For a full example of a usage of this method, see the store-inventory module.
 *
 * As with all other store-backend methods, this method is completely asynchronous.
 *
 * @param accountId		    The account ID of the player, use GetSteamAccountID to convert a client index to account ID.
 * @param type              The category of the items you want to retrieve.
 * @param loadoutId         The loadout which will be used to determine whether an item is equipped or not.
 * @param callback		    A callback which will be called when the items are loaded.
 * @param plugin			The plugin owner of the callback.
 * @param data              Extra data value to pass to the callback.
 *
 * @noreturn
 */
void GetEquippedItemsByType(int accountId, const char[] type, int loadoutId, Function callback = INVALID_FUNCTION, Handle plugin = null, any data = 0)
{
	Handle pack = CreateDataPack();
	WritePackFunction(pack, callback);
	WritePackCell(pack, plugin);
	WritePackCell(pack, data);
	
	char query[512];
	Format(query, sizeof(query), "SELECT store_items.id FROM store_users_items INNER JOIN store_items ON store_items.id = store_users_items.item_id INNER JOIN store_users ON store_users.id = store_users_items.user_id INNER JOIN store_users_items_loadouts ON store_users_items_loadouts.useritem_id = store_users_items.id WHERE store_users.auth = %d AND store_items.type = '%s' AND store_users_items_loadouts.loadout_id = %d", accountId, type, loadoutId);
	
	SQL_TQuery(g_hSQL, T_GetEquippedItemsByTypeCallback, query, pack, DBPrio_High);	
}

public void T_GetEquippedItemsByTypeCallback(Database db, DBResultSet results, const char[] error, DataPack pack)
{
	if (results == null)
	{
		CloseHandle(pack);
		
		Store_LogError("SQL Error on GetEquippedItemsByType: %s", error);
		return;
	}
	
	ResetPack(pack);
	
	Function callback = ReadPackFunction(pack);
	Handle plugin = ReadPackCell(pack);
	int arg = ReadPackCell(pack);
	
	CloseHandle(pack);
	
	int count = SQL_GetRowCount(results);
	int[] ids = new int[count];
	
	int index = 0;
	while (SQL_FetchRow(results))
	{
		ids[index] = SQL_FetchInt(results, 0);
		index++;
	}
	
	Call_StartFunction(plugin, callback);
	Call_PushArray(ids, count);
	Call_PushCell(count);
	Call_PushCell(arg);
	Call_Finish();	
}

/**
 * Gives a player a specific amount of credits. 
 * 
 * You can also set the credits parameter to a negative value to take credits
 * from the player.
 *
 * As with all other store-backend methods, this method is completely asynchronous.
 *
 * @param accountId		    The account ID of the player, use GetSteamAccountID to convert a client index to account ID.
 * @param credits           The amount of credits to give to the player.
 * @param callback		    A callback which will be called when the operation is finished.
 * @param plugin			The plugin owner of the callback.
 * @param data              Extra data value to pass to the callback.
 *
 * @noreturn
 */
void GiveCredits(int accountId, int credits, Function callback = INVALID_FUNCTION, Handle plugin = null, any data = 0)
{
	Handle pack = CreateDataPack();
	WritePackCell(pack, accountId);
	WritePackFunction(pack, callback);
	WritePackCell(pack, plugin);
	WritePackCell(pack, data);
	
	char query[255];
	Format(query, sizeof(query), "UPDATE store_users SET credits = credits + %d WHERE auth = %d", credits, accountId);

	SQL_TQuery(g_hSQL, T_GiveCreditsCallback, query, pack);	
}

public void T_GiveCreditsCallback(Database db, DBResultSet results, const char[] error, DataPack pack)
{
	if (results == null)
	{
		CloseHandle(pack);
		
		Store_LogError("SQL Error on GiveCredits: %s", error);
		return;
	}
	
	ResetPack(pack);
	
	int accountId = ReadPackCell(pack);
	Function callback = ReadPackFunction(pack);
	Handle plugin = ReadPackCell(pack);
	int arg = ReadPackCell(pack);
	
	CloseHandle(pack);
	
	if (callback != INVALID_FUNCTION) 
	{
		Call_StartFunction(plugin, callback);
		Call_PushCell(accountId);
		Call_PushCell(arg);
		Call_Finish();	
	}
}

/**
 * Gives player an item.
 *
 * As with all other store-backend methods, this method is completely asynchronous.
 *
 * @param accountId		    The account ID of the player, use GetSteamAccountID to convert a client index to account ID.
 * @param itemId 			The ID of the item to give to the player.
 * @param acquireMethod 		
 * @param callback		    A callback which will be called when the operation is finished.
 * @param plugin			The plugin owner of the callback.
 * @param data              Extra data value to pass to the callback.
 *
 * @noreturn
 */
void GiveItem(int accountId, int itemId, Store_AcquireMethod acquireMethod = Store_Unknown, Function callback = INVALID_FUNCTION, Handle plugin = null, any data = 0)
{
	Handle pack = CreateDataPack();
	WritePackCell(pack, accountId);
	WritePackFunction(pack, callback);
	WritePackCell(pack, plugin);
	WritePackCell(pack, data);

	char query[255];
	Format(query, sizeof(query), "INSERT INTO store_users_items (user_id, item_id, acquire_date, acquire_method) SELECT store_users.id AS userId, '%d' AS item_id, NOW() as acquire_date, ", itemId);

	if (acquireMethod == Store_Shop)
		Format(query, sizeof(query), "%s'shop'", query);
	else if (acquireMethod == Store_Trade)
		Format(query, sizeof(query), "%s'trade'", query);
	else if (acquireMethod == Store_Gift)
		Format(query, sizeof(query), "%s'gift'", query);
	else if (acquireMethod == Store_Admin)
		Format(query, sizeof(query), "%s'admin'", query);
	else if (acquireMethod == Store_Web)
		Format(query, sizeof(query), "%s'web'", query);
	else if (acquireMethod == Store_Unknown)
		Format(query, sizeof(query), "%sNULL", query);

	Format(query, sizeof(query), "%s AS acquire_method FROM store_users WHERE auth = %d", query, accountId);

	SQL_TQuery(g_hSQL, T_GiveItemCallback, query, pack, DBPrio_High);	
}

public void T_GiveItemCallback(Database db, DBResultSet results, const char[] error, DataPack pack)
{
	if (results == null)
	{
		CloseHandle(pack);
		
		Store_LogError("SQL Error on GiveItem: %s", error);
		return;
	}
	
	ResetPack(pack);
	
	int accountId = ReadPackCell(pack);
	Function callback = ReadPackFunction(pack);
	Handle plugin = ReadPackCell(pack);
	int arg = ReadPackCell(pack);
	
	CloseHandle(pack);
	
	if (callback != INVALID_FUNCTION) 
	{
		Call_StartFunction(plugin, callback);
		Call_PushCell(accountId);
		Call_PushCell(arg);
		Call_Finish();	
	}
}

/**
 * Gives multiple players a specific amount of credits. 
 * 
 * You can also set the credits parameter to a negative value to take credits
 * from the players.
 *
 * As with all other store-backend methods, this method is completely asynchronous.
 *
 * @param accountIds	    	The account IDs of the players, use GetSteamAccountID to convert a client index to account ID.
 * @param accountIdsLength  	Players count.
 * @param credits           	The amount of credits to give to the players.
 *
 * @noreturn
 */
void GiveCreditsToUsers(int [] accountIds, int accountIdsLength, int credits)
{
	if (accountIdsLength == 0)
		return;

	char query[2048];
	Format(query, sizeof(query), "UPDATE store_users SET credits = credits + %d WHERE auth IN (", credits);
	
	for (int i = 0; i < accountIdsLength; i++)
	{
		Format(query, sizeof(query), "%s%d", query, accountIds[i]);
		
		if (i < accountIdsLength - 1)
			Format(query, sizeof(query), "%s, ", query);			
	}

	Format(query, sizeof(query), "%s)", query);	
	
	SQL_TQuery(g_hSQL, T_GiveCreditsToUsersCallback, query);	
}

public void T_GiveCreditsToUsersCallback(Database db, DBResultSet results, const char[] error, any data)
{
	if (results == null)
	{
		Store_LogError("SQL Error on GiveCreditsToUsers: %s", error);
		return;
	}
}

/**
 * Gives multiple players different amounts of credits. 
 * 
 * You can also set the credits parameter to a negative value to take credits
 * from the players.
 *
 * As with all other store-backend methods, this method is completely asynchronous.
 *
 * @param accountIds	    	The account IDs of the players, use GetSteamAccountID to convert a client index to account ID.
 * @param accountIdsLength  	Players count.
 * @param credits 				Amount of credits per player. 
 *
 * @noreturn
 */
void GiveDifferentCreditsToUsers(int[] accountIds, int accountIdsLength, int[] credits)
{
	if (accountIdsLength == 0)
		return;

	char query[2048];
	Format(query, sizeof(query), "UPDATE store_users SET credits = credits + CASE auth");

	for (int i = 0; i < accountIdsLength; i++)
	{
		Format(query, sizeof(query), "%s WHEN %d THEN %d", query, accountIds[i], credits[i]);
	}

	Format(query, sizeof(query), "%s END WHERE auth IN (", query);

	for (int i = 0; i < accountIdsLength; i++)
	{
		Format(query, sizeof(query), "%s%d", query, accountIds[i]);
		
		if (i < accountIdsLength - 1)
			Format(query, sizeof(query), "%s, ", query);			
	}

	Format(query, sizeof(query), "%s)", query);	
	
	SQL_TQuery(g_hSQL, T_GiveDifferentCreditsToUsersCallback, query);	
}

public void T_GiveDifferentCreditsToUsersCallback(Database db, DBResultSet results, const char[] error, any data)
{
	if (results == null)
	{
		Store_LogError("SQL Error on GiveDifferentCreditsToUsers: %s", error);
		return;
	}
}

/**
 * Query the database for items and categories, so that
 * the store-backend module will have a cache of them.
 *
 * @noreturn
 */
void ReloadItemCache()
{
	GetCategories(_, _, false);
	GetItems(_, _, _, false);
}

void ConnectSQL()
{
	if (g_hSQL != null)
		CloseHandle(g_hSQL);
	
	g_hSQL = null;

	if (SQL_CheckConfig("store"))
	{
		SQL_TConnect(T_ConnectSQLCallback, "store");
	}
	else
	{
		SetFailState("No config entry found for 'store' in databases.cfg.");
	}
}

public void T_ConnectSQLCallback(Database db, DBResultSet results, const char[] error, any data)
{
	if (g_reconnectCounter >= 5)
	{
		SetFailState("PLUGIN STOPPED - Reason: reconnect counter reached max - PLUGIN STOPPED");
		return;
	}

	if (results == null)
	{
		Store_LogError("Connection to SQL database has failed, Reason: %s", error);
		
		g_reconnectCounter++;
		ConnectSQL();

		return;
	}

	char driver[16];
	SQL_GetDriverIdent(db, driver, sizeof(driver));

	g_hSQL = CloneHandle(results);		
	
	if (StrEqual(driver, "mysql", false))
	{
		SQL_FastQuery(g_hSQL, "SET NAMES  'utf8'");
	}
	
	CloseHandle(results);
	
	Call_StartForward(g_dbInitializedForward);
	Call_Finish();
	
	ReloadItemCache();

	g_reconnectCounter = 1;
}

public Action Command_ReloadItems(int client, int args)
{
	ReplyToCommand(client, "Reloading items...");
	ReloadItemCache();

	return Plugin_Handled;
}

public int Native_Register(Handle plugin, int params)
{
	char name[64];
	GetNativeString(2, name, sizeof(name));    
	
	Register(GetNativeCell(1), name, GetNativeCell(3));
	return 0;
}

public int Native_RegisterClient(Handle plugin, int params)
{
	RegisterClient(GetNativeCell(1), GetNativeCell(2));
	return 0;
}

public int Native_GetCategories(Handle plugin, int params)
{
	any data = 0;
	
	if (params == 3)
		data = GetNativeCell(3);
		
	GetCategories(GetNativeFunction(1), plugin, GetNativeCell(2), data);
	return 0;
}

public int Native_GetCategoryDisplayName(Handle plugin, int params)
{
	SetNativeString(2, g_categories[GetCategoryIndex(GetNativeCell(1))].CategoryDisplayName, GetNativeCell(3));
	return 0;
}

public int Native_GetCategoryDescription(Handle plugin, int params)
{
	SetNativeString(2, g_categories[GetCategoryIndex(GetNativeCell(1))].CategoryDescription, GetNativeCell(3));
	return 0;
}

public int Native_GetCategoryPluginRequired(Handle plugin, int params)
{
	SetNativeString(2, g_categories[GetCategoryIndex(GetNativeCell(1))].CategoryRequirePlugin, GetNativeCell(3));
	return 0;
}

public int Native_GetItems(Handle plugin, int params)
{
	any data = 0;
	
	if (params == 4)
		data = GetNativeCell(4);
		
	GetItems(GetNativeCell(1), GetNativeFunction(2), plugin, GetNativeCell(3), data);
	return 0;
}

public int Native_GetItemName(Handle plugin, int params)
{
	SetNativeString(2, g_items[GetItemIndex(GetNativeCell(1))].ItemName, GetNativeCell(3));
	return 0;
}

public int Native_GetItemDisplayName(Handle plugin, int params)
{
	SetNativeString(2, g_items[GetItemIndex(GetNativeCell(1))].ItemDisplayName, GetNativeCell(3));
	return 0;
}

public int Native_GetItemDescription(Handle plugin, int params)
{
	SetNativeString(2, g_items[GetItemIndex(GetNativeCell(1))].ItemDescription, GetNativeCell(3));
	return 0;
}

public int Native_GetItemType(Handle plugin, int params)
{
	SetNativeString(2, g_items[GetItemIndex(GetNativeCell(1))].ItemType, GetNativeCell(3));
	return 0;
}

public int Native_GetItemLoadoutSlot(Handle plugin, int params)
{
	SetNativeString(2, g_items[GetItemIndex(GetNativeCell(1))].ItemLoadoutSlot, GetNativeCell(3));
	return 0;
}

public int Native_GetItemPrice(Handle plugin, int params)
{
	return g_items[GetItemIndex(GetNativeCell(1))].ItemPrice;
}

public int Native_GetItemCategory(Handle plugin, int params)
{
	return g_items[GetItemIndex(GetNativeCell(1))].ItemCategoryId;
}

public int Native_IsItemBuyable(Handle plugin, int params)
{
	return g_items[GetItemIndex(GetNativeCell(1))].ItemIsBuyable;
}

public int Native_IsItemTradeable(Handle plugin, int params)
{
	return g_items[GetItemIndex(GetNativeCell(1))].ItemIsTradeable;
}

public int Native_IsItemRefundable(Handle plugin, int params)
{
	return g_items[GetItemIndex(GetNativeCell(1))].ItemIsRefundable;
}

public int Native_GetItemAttributes(Handle plugin, int params)
{
	any data = 0;
	
	if (params == 3)
		data = GetNativeCell(3);
	
	char itemName[STORE_MAX_NAME_LENGTH];
	GetNativeString(1, itemName, sizeof(itemName));

	GetItemAttributes(itemName, GetNativeFunction(2), plugin, data);
	return 0;
}

public int Native_WriteItemAttributes(Handle plugin, int params)
{
	any data = 0;
	
	if (params == 4)
		data = GetNativeCell(4);
	
	char itemName[STORE_MAX_NAME_LENGTH];
	GetNativeString(1, itemName, sizeof(itemName));

	int attrsLength = 10*1024;
	GetNativeStringLength(2, attrsLength);

	char[] attrs = new char[attrsLength];
	GetNativeString(2, attrs, attrsLength);

	WriteItemAttributes(itemName, attrs, GetNativeFunction(3), plugin, data);
	return 0;
}

public int Native_GetLoadouts(Handle plugin, int params)
{	
	any data = 0;    
	if (params == 4)
		data = GetNativeCell(4);
		
	GetLoadouts(GetNativeCell(1), GetNativeFunction(2), plugin, GetNativeCell(3), data);
	return 0;
}

public int Native_GetLoadoutDisplayName(Handle plugin, int params)
{
	SetNativeString(2, g_loadouts[GetLoadoutIndex(GetNativeCell(1))].LoadoutDisplayName, GetNativeCell(3));
	return 0;
}

public int Native_GetLoadoutGame(Handle plugin, int params)
{
	SetNativeString(2, g_loadouts[GetLoadoutIndex(GetNativeCell(1))].LoadoutGame, GetNativeCell(3));
	return 0;
}

public int Native_GetLoadoutClass(Handle plugin, int params)
{
	SetNativeString(2, g_loadouts[GetLoadoutIndex(GetNativeCell(1))].LoadoutClass, GetNativeCell(3));
	return 0;
}

public int Native_GetLoadoutTeam(Handle plugin, int params)
{
	return g_loadouts[GetLoadoutIndex(GetNativeCell(1))].LoadoutTeam;
}

public int Native_GetUserItems(Handle plugin, int params)
{
	any data = 0;
	if (params == 5)
		data = GetNativeCell(5);
		
	GetUserItems(GetNativeCell(1), GetNativeCell(2), GetNativeCell(3), GetNativeFunction(4), plugin, data);
	return 0;
}

public int Native_GetUserItemCount(Handle plugin, int params)
{
	any data = 0;
	if (params == 4)
		data = GetNativeCell(4);

	char itemName[STORE_MAX_NAME_LENGTH];
	GetNativeString(2, itemName, sizeof(itemName));

	GetUserItemCount(GetNativeCell(1), itemName, GetNativeFunction(3), plugin, data);
	return 0;
}

public int Native_GetCredits(Handle plugin, int params)
{
	any data = 0;
	if (params == 3)
		data = GetNativeCell(3);
		
	GetCredits(GetNativeCell(1), GetNativeFunction(2), plugin, data);
	return 0;
}

public int Native_BuyItem(Handle plugin, int params)
{	
	any data = 0;
	
	if (params == 4)
		data = GetNativeCell(4);

	BuyItem(GetNativeCell(1), GetNativeCell(2), GetNativeFunction(3), plugin, data);
	return 0;
}

public int Native_RemoveUserItem(Handle plugin, int params)
{
	any data = 0;
	
	if (params == 4)
		data = GetNativeCell(4);

	RemoveUserItem(GetNativeCell(1), GetNativeCell(2), GetNativeFunction(3), plugin, data);
	return 0;
}

public int Native_SetItemEquippedState(Handle plugin, int params)
{
	any data = 0;
	
	if (params == 6)
		data = GetNativeCell(6);

	SetItemEquippedState(GetNativeCell(1), GetNativeCell(2), GetNativeCell(3), GetNativeCell(4), GetNativeFunction(5), plugin, data);
	return 0;
}

public int Native_GetEquippedItemsByType(Handle plugin, int params)
{	
	char type[32];
	GetNativeString(2, type, sizeof(type)); 
	
	any data = 0;
	
	if (params == 5)
		data = GetNativeCell(5);

	GetEquippedItemsByType(GetNativeCell(1), type, GetNativeCell(3), GetNativeFunction(4), plugin, data);
	return 0;
}

public int Native_GiveCredits(Handle plugin, int params)
{
	any data = 0;
	
	if (params == 4)
		data = GetNativeCell(4);
		
	GiveCredits(GetNativeCell(1), GetNativeCell(2), GetNativeFunction(3), plugin, data);
	return 0;
}

public int Native_GiveCreditsToUsers(Handle plugin, int params)
{
	int length = GetNativeCell(2);
	
	int[] accountIds = new int[length];
	GetNativeArray(1, accountIds, length);
	
	GiveCreditsToUsers(accountIds, length, GetNativeCell(3));
	return 0;
}

public int Native_GiveItem(Handle plugin, int params)
{
	any data = 0;
	if (params == 5)
		data = GetNativeCell(5);

	GiveItem(GetNativeCell(1), GetNativeCell(2), GetNativeCell(3), GetNativeFunction(4), plugin, data);
	return 0;
}

public int Native_GiveDifferentCreditsToUsers(Handle plugin, int params)
{
	int length = GetNativeCell(2);
	
	int[] accountIds = new int[length];
	GetNativeArray(1, accountIds, length);

	int[] credits = new int[length];
	GetNativeArray(3, credits, length);

	GiveDifferentCreditsToUsers(accountIds, length, credits);
	return 0;
}

public int Native_ReloadItemCache(Handle plugin, int params)
{       
	ReloadItemCache();
	return 0;
}