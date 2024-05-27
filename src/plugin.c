#include <lua_scripts.h>
#include <lua.h>
#include <lualib.h>
#include <lauxlib.h>
#include <luajit.h>

#include <stdio.h>

static lua_State *L = NULL;
static int extension_init_ref = 0;
static int extension_deinit_ref = 0;

void checkLuaError(int status);

void __attribute__((constructor)) before_main()
{
    L = lua_open();
    //LUAJIT_VERSION_SYM();
    lua_gc(L, LUA_GCSTOP, 0);
    luaL_openlibs(L);
    lua_gc(L, LUA_GCRESTART, -1);
}

void __attribute__((destructor)) after_main();
void after_main()
{
    lua_rawgeti(L, LUA_REGISTRYINDEX, extension_deinit_ref);

    int status = lua_pcall(L, 0, 0, 0);
    checkLuaError(status);

    lua_close(L);
}


void checkLuaError(int status)
{
    if (status)
    {
        printf( "Lua error %d\n", status);
        if( status == LUA_ERRRUN) {
            if (lua_type(L, -1) == LUA_TSTRING){
                printf("Error: %s", lua_tostring((L), -1));
                lua_pop(L, lua_gettop(L));

            }else {
                printf("Lua error: [object]");
            }
        } else if (status == LUA_ERRMEM) {
            printf("%s %s","Memory error:",lua_tostring(L, -1));
        } else if (status == LUA_ERRERR) {
            printf("%s %s","Error:",lua_tostring(L, -1));
        }
    }
}

typedef struct sqlite3 sqlite3;
typedef struct sqlite3_api_routines sqlite3_api_routines;

typedef struct LJFunctionData {
    sqlite3 * db;
    char ** msg;
    const sqlite3_api_routines *api;
} LJFunctionData;


#define SQLITE_OK           0
#define SQLITE_ERROR        1

extern int sqlite3_extension_init(
    sqlite3 *,
    char **,
    const sqlite3_api_routines *pApi);

extern int sqlite3_extension_init(
    sqlite3 * db,
    char **msg,
    const sqlite3_api_routines *api)
{
    
#ifndef NO_EMBED_CODE
    const char* bootstrap = "local ffi = require 'ffi' \n"
    "ffi.cdef[[typedef struct PluginCode{const char* sqlit_lj_lua;const char* sqlit_capi_lua;} PluginCode;]]  \n"
    "local a = {...} local udata = ffi.cast ('PluginCode*', a[1]) \n" 
    "local code_capi = ffi.string(udata.sqlit_capi_lua) \n"

    "local fn, err = loadstring(code_capi, 'c_api', 't', _G) \n"
    "if not fn then return error(tostring(err)) end \n"

    "local capi = fn() \n"
    "package.loaded['sqlite_capi'] = capi \n"

    "local code_sqlite_plugin = ffi.string(udata.sqlit_lj_lua) \n"
    "fn, err = loadstring(code_sqlite_plugin, 'c_api', 't', _G) \n"

    "if not fn then return error(tostring(err)) end \n"

    "local sqlite_lj = fn() \n"
    "package.loaded['sqlite_lj'] = sqlite_lj \n"

    "return sqlite_lj \n";

    int status = luaL_loadstring(L, bootstrap);
    if (status) {
        checkLuaError(status);
        return SQLITE_ERROR;
    } 

    typedef struct PluginCode
    {
        const char* sqlit_lj_lua;
        const char* sqlit_capi_lua;
    } PluginCode;
    

    PluginCode* data = (PluginCode*)lua_newuserdata(L, sizeof(PluginCode));
    data->sqlit_lj_lua = SQLITE_LJ_LUA;
    data->sqlit_capi_lua = SQLITE_CAPI_LUA;

    status = lua_pcall(L, 1, 1, 0);
    if (status) {
        checkLuaError(status);
        return SQLITE_ERROR;
    }
            else
        {
            lua_getfield(L, 1, "extension_init");
            extension_init_ref  = luaL_ref(L, LUA_REGISTRYINDEX);
            lua_getfield(L, 1, "extension_deinit");
            extension_deinit_ref = luaL_ref(L, LUA_REGISTRYINDEX);
            lua_settop(L, 0);

            LJFunctionData* udata;

            lua_rawgeti(L, LUA_REGISTRYINDEX, extension_init_ref);

            udata = (LJFunctionData*) lua_newuserdata(L, sizeof(LJFunctionData));
            udata->db = db;
            udata->msg = msg;
            udata->api = api;

            status = lua_pcall(L, 1, 0, 0);
            checkLuaError(status);
        }

#else 
        lua_getglobal(L, "require");
        lua_pushstring(L, "sqlite_lj");
        int status = lua_pcall(L, 1, 1, 0);
        if (status)
        {
            checkLuaError(status);

            return SQLITE_ERROR;
        }
        else
        {
            lua_getfield(L, 1, "extension_init");
            extension_init_ref  = luaL_ref(L, LUA_REGISTRYINDEX);
            lua_settop(L, 0);

            LJFunctionData* udata;

            lua_rawgeti(L, LUA_REGISTRYINDEX, extension_init_ref);

            udata = (LJFunctionData*) lua_newuserdata(L, sizeof(LJFunctionData));
            udata->db = db;
            udata->msg = msg;
            udata->api = api;

            status = lua_pcall(L, 1, 0, 0);
            checkLuaError(status);
        }
    #endif
    return SQLITE_OK;
}


