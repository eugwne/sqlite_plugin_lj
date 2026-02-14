#include <lua.h>
#include <lualib.h>
#include <lauxlib.h>
#include <luajit.h>

#include <sqlite3ext.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <stdbool.h>
#if defined(_WIN32)
#include <windows.h>
#else
#include <pthread.h>
#endif

#if defined(_MSC_VER)
#define ATTR_HIDDEN
#define ATTR_CONSTRUCTOR
#define ATTR_DESTRUCTOR
#define EXT_EXPORT __declspec(dllexport)
#else
#define ATTR_HIDDEN __attribute__((visibility("hidden")))
#define ATTR_CONSTRUCTOR __attribute__((constructor))
#define ATTR_DESTRUCTOR __attribute__((destructor))
#define EXT_EXPORT
#endif

int ATTR_HIDDEN checkLuaError(lua_State* L, int status);

static int loadBytecodeObject(lua_State* L, const unsigned char* bytecode, size_t size, const char* name) {
    if (luaL_loadbuffer(L, (const char*)bytecode, size, name) != LUA_OK) {
        const char* err = lua_tostring(L, -1);
        printf("Load error: %s\n", err);
        lua_pop(L, 1);
        return -1;
    }

    if (lua_pcall(L, 0, 1, 0) != LUA_OK) {
        const char* err = lua_tostring(L, -1);
        printf("Runtime error: %s\n", err);
        lua_pop(L, 1);
        return -1;
    }

    lua_setglobal(L, name);
    lua_settop(L, 0);

    return 0;
}


static const sqlite3_api_routines *sqlite3_api;

static lua_State *L_shared;
static int bridge_ready = 0;
static char bridge_init_error[256] = {0};

static void set_bridge_error(const char* msg) {
    if (!msg || bridge_init_error[0] != '\0') {
        return;
    }
    snprintf(bridge_init_error, sizeof(bridge_init_error), "%s", msg);
}

typedef struct FunctionContext {
    void (*fn_ptr)(sqlite3_context *ctx, int argc, sqlite3_value **argv);
    void (*fn_step_ptr)(sqlite3_context *ctx, int argc, sqlite3_value **argv);
    void (*fn_final_ptr)(sqlite3_context *ctx);
    void (*fn_destroy_ptr)(void*);
    int64_t udata; 
    int allowed_nested;
} FunctionContext;

typedef int (*set_object_cb_t)(const char* data, size_t len);
typedef const char* (*get_object_cb_t)(int id, size_t* len);
typedef int (*set_fn_context_cb_t)(const FunctionContext* ctx);
typedef const FunctionContext* (*get_fn_context_cb_t)(int64_t id);
typedef struct {
    set_object_cb_t set_object;
    get_object_cb_t get_object;
    set_fn_context_cb_t set_fn_context;
    get_fn_context_cb_t get_fn_context;
} SharedBridge;
static SharedBridge bridge = {0};

#if defined(_WIN32)
typedef DWORD conn_thread_id_t;
static conn_thread_id_t current_thread_id(void) {
    return GetCurrentThreadId();
}
static int thread_id_equal(conn_thread_id_t a, conn_thread_id_t b) {
    return a == b;
}
#else
typedef pthread_t conn_thread_id_t;
static conn_thread_id_t current_thread_id(void) {
    return pthread_self();
}
static int thread_id_equal(conn_thread_id_t a, conn_thread_id_t b) {
    return pthread_equal(a, b);
}
#endif

static const char* THREAD_GUARD_ERR = "sqlite_plugin_lj: connection used from multiple threads";
static const char* VM_INIT_ERR = "sqlite_plugin_lj: Lua VM init failed or call depth exceeded";
static const char* FN_CONTEXT_ERR = "sqlite_plugin_lj: function context callback is null";

#if defined(_WIN32)
static INIT_ONCE state_lock_once = INIT_ONCE_STATIC_INIT;
static CRITICAL_SECTION state_lock_cs;
static BOOL CALLBACK init_state_lock(PINIT_ONCE once, PVOID param, PVOID *ctx) {
    (void)once;
    (void)param;
    (void)ctx;
    InitializeCriticalSection(&state_lock_cs);
    return TRUE;
}
static void state_lock(void) {
    InitOnceExecuteOnce(&state_lock_once, init_state_lock, NULL, NULL);
    EnterCriticalSection(&state_lock_cs);
}
static void state_unlock(void) {
    LeaveCriticalSection(&state_lock_cs);
}
#else
static pthread_mutex_t state_lock_mutex = PTHREAD_MUTEX_INITIALIZER;
static void state_lock(void) {
    pthread_mutex_lock(&state_lock_mutex);
}
static void state_unlock(void) {
    pthread_mutex_unlock(&state_lock_mutex);
}
#endif

static sqlite3_mutex* global_mutex(void) {
    if (!sqlite3_api || !sqlite3_api->mutex_alloc) {
        return NULL;
    }
    return sqlite3_api->mutex_alloc(SQLITE_MUTEX_STATIC_MAIN);
}

static void global_lock(void) {
    sqlite3_mutex *m = global_mutex();
    if (m && sqlite3_api->mutex_enter) {
        sqlite3_api->mutex_enter(m);
    }
}

static void global_unlock(void) {
    sqlite3_mutex *m = global_mutex();
    if (m && sqlite3_api->mutex_leave) {
        sqlite3_api->mutex_leave(m);
    }
}

static int pushFunctionContext(FunctionContext ctx) {
    if (!bridge.set_fn_context) {
        return 0;
    }
    global_lock();
    int rc = bridge.set_fn_context(&ctx);
    global_unlock();
    return rc;
}

static const FunctionContext* getFunctionContext(int64_t index) {
    if (!bridge.get_fn_context) {
        return NULL;
    }
    global_lock();
    const FunctionContext* rc = bridge.get_fn_context(index);
    global_unlock();
    return rc;
}

static int bridge_set_object_locked(const char* data, size_t len) {
    if (!bridge.set_object) {
        return 0;
    }
    global_lock();
    int rc = bridge.set_object(data, len);
    global_unlock();
    return rc;
}

static const char* bridge_get_object_locked(int id, size_t* len) {
    if (!bridge.get_object) {
        return NULL;
    }
    global_lock();
    const char* rc = bridge.get_object(id, len);
    global_unlock();
    return rc;
}

#define SAVED_VM 10

typedef struct LJFunctionData {
    sqlite3 * db;
    char ** msg;
    const sqlite3_api_routines *api;
    void (*callback)(sqlite3_context *ctx, int argc, sqlite3_value **argv);
    void (*cb_context_fn)(sqlite3_context *ctx, int argc, sqlite3_value **argv);
    void (*cb_context_step_fn)(sqlite3_context *ctx, int argc, sqlite3_value **argv);
    void (*cb_context_final_fn)(sqlite3_context *ctx);
    void (*cb_context_destroy_fn)(void*);
    void (*sqlite_return_int_cb)(sqlite3_context *ctx, int argc, sqlite3_value **argv);
    void (*sqlite_return_text_cb)(sqlite3_context *ctx, int argc, sqlite3_value **argv);
    void (*sqlite_free_cb)(void*);

    // context functions
    int (*pushFunctionContext)(FunctionContext ctx);
    const FunctionContext* (*getFunctionContext)(int64_t index);
    //shared bridge functions
    int (*set_object)(const char* data, size_t len);
    const char* (*get_object)(int id, size_t* len);


    int call_depth;
    int is_vtable_vm;
    int conn_slot;
    // lua write
    void (*caller_fn)(sqlite3_context *ctx, int argc, sqlite3_value **argv);

    // vtable callbacks - Lua implementations (set by Lua)
    int (*vtab_xOpen_lua)(sqlite3_vtab*, sqlite3_vtab_cursor**);
    int (*vtab_xClose_lua)(sqlite3_vtab_cursor*);
    int (*vtab_xFilter_lua)(sqlite3_vtab_cursor*, int, const char*, int, sqlite3_value**);
    int (*vtab_xNext_lua)(sqlite3_vtab_cursor*);
    int (*vtab_xEof_lua)(sqlite3_vtab_cursor*);
    int (*vtab_xColumn_lua)(sqlite3_vtab_cursor*, sqlite3_context*, int);
    int (*vtab_xRowid_lua)(sqlite3_vtab_cursor*, sqlite3_int64*);
    // vtable callbacks - C wrappers (provided by C, used by Lua module)
    int (*cb_vtab_xOpen)(sqlite3_vtab*, sqlite3_vtab_cursor**);
    int (*cb_vtab_xClose)(sqlite3_vtab_cursor*);
    int (*cb_vtab_xFilter)(sqlite3_vtab_cursor*, int, const char*, int, sqlite3_value**);
    int (*cb_vtab_xNext)(sqlite3_vtab_cursor*);
    int (*cb_vtab_xEof)(sqlite3_vtab_cursor*);
    int (*cb_vtab_xColumn)(sqlite3_vtab_cursor*, sqlite3_context*, int);
    int (*cb_vtab_xRowid)(sqlite3_vtab_cursor*, sqlite3_int64*);
} LJFunctionData;

typedef struct LJFunctionArgs {
    sqlite3_context *ctx;
    int argc;
    sqlite3_value **argv;
} LJFunctionArgs;

typedef struct Worker {
    lua_State *L;
    int extension_init_ref;
    int extension_deinit_ref;
    int extension_call_ref;
    LJFunctionData* udata;
} Worker;

typedef struct ConnState {
    sqlite3 *db;
    int slot;
    bool cleanup_registered;
    bool owner_thread_set;
    conn_thread_id_t owner_thread_id;
    Worker vm_stack[SAVED_VM];
    int call_depth;
    Worker vtable_vm;
    bool vtable_vm_busy;
    bool vtable_vm_initialized;
} ConnState;

#define MAX_CONN_STATES 32
static ConnState conn_states[MAX_CONN_STATES] = {0};

typedef struct lua_vtab_local {
    sqlite3_vtab base;
    uint32_t index;
    int32_t conn_slot;
} lua_vtab_local;

static ConnState* find_conn_state_unlocked(sqlite3 *db);
static ConnState* get_or_create_conn_state(sqlite3 *db);
static ConnState* find_conn_state_by_slot(int slot);
static ConnState* conn_state_from_context(sqlite3_context *ctx);
static ConnState* conn_state_from_vtab(sqlite3_vtab *pVtab);
static void cleanup_conn_state(ConnState *state);
static void sqlite_conn_cleanup_destroy_cb(void *p);
static void sqlite_conn_cleanup_noop_fn(sqlite3_context *ctx, int argc, sqlite3_value **argv);
static bool claim_or_validate_owner_thread(ConnState *state);
Worker ATTR_HIDDEN push_vm(ConnState *state);
void ATTR_HIDDEN pop_vm(ConnState *state, Worker w);

static ConnState* find_conn_state_unlocked(sqlite3 *db) {
    if (!db) {
        return NULL;
    }
    for (int i = 0; i < MAX_CONN_STATES; ++i) {
        if (conn_states[i].db == db) {
            return &conn_states[i];
        }
    }
    return NULL;
}

static ConnState* get_or_create_conn_state(sqlite3 *db) {
    state_lock();
    ConnState *found = find_conn_state_unlocked(db);
    if (found) {
        state_unlock();
        return found;
    }
    for (int i = 0; i < MAX_CONN_STATES; ++i) {
        if (conn_states[i].db == NULL) {
            memset(&conn_states[i], 0, sizeof(conn_states[i]));
            conn_states[i].db = db;
            conn_states[i].slot = i + 1;
            state_unlock();
            return &conn_states[i];
        }
    }
    state_unlock();
    return NULL;
}

static ConnState* find_conn_state_by_slot(int slot) {
    state_lock();
    if (slot <= 0 || slot > MAX_CONN_STATES) {
        state_unlock();
        return NULL;
    }
    ConnState *state = &conn_states[slot - 1];
    if (state->db == NULL) {
        state_unlock();
        return NULL;
    }
    state_unlock();
    return state;
}

static ConnState* conn_state_from_context(sqlite3_context *ctx) {
    if (!ctx || !sqlite3_api || !sqlite3_api->context_db_handle) {
        return NULL;
    }
    sqlite3 *db = sqlite3_api->context_db_handle(ctx);
    state_lock();
    ConnState *state = find_conn_state_unlocked(db);
    state_unlock();
    return state;
}

static ConnState* conn_state_from_vtab(sqlite3_vtab *pVtab) {
    if (!pVtab) {
        return NULL;
    }
    lua_vtab_local *local_vtab = (lua_vtab_local*)pVtab;
    return find_conn_state_by_slot(local_vtab->conn_slot);
}

static bool claim_or_validate_owner_thread(ConnState *state) {
    if (!state) {
        return false;
    }
    conn_thread_id_t tid = current_thread_id();
    bool ok = false;
    state_lock();
    if (!state->owner_thread_set) {
        state->owner_thread_id = tid;
        state->owner_thread_set = true;
        ok = true;
    } else {
        ok = thread_id_equal(state->owner_thread_id, tid) != 0;
    }
    state_unlock();
    return ok;
}

static void cleanup_conn_state(ConnState *state) {
    Worker vm_copy[SAVED_VM] = {0};
    Worker vtable_copy = {0};
    state_lock();
    if (!state || !state->db) {
        state_unlock();
        return;
    }
    for (int j = 0; j < SAVED_VM; ++j) {
        vm_copy[j] = state->vm_stack[j];
        memset(&state->vm_stack[j], 0, sizeof(state->vm_stack[j]));
    }
    if (state->vtable_vm.L) {
        vtable_copy = state->vtable_vm;
        memset(&state->vtable_vm, 0, sizeof(state->vtable_vm));
    }
    int slot = state->slot;
    memset(state, 0, sizeof(*state));
    state->slot = slot;
    state_unlock();

    for (int j = 0; j < SAVED_VM; ++j) {
        Worker *w = &vm_copy[j];
        if (!w->L) {
            continue;
        }
        if (w->extension_deinit_ref != LUA_NOREF) {
            lua_rawgeti(w->L, LUA_REGISTRYINDEX, w->extension_deinit_ref);
            int status = lua_pcall(w->L, 0, 0, 0);
            checkLuaError(w->L, status);
        }
        free(w->udata);
        w->udata = NULL;
        lua_close(w->L);
    }
    if (vtable_copy.L) {
        if (vtable_copy.extension_deinit_ref != LUA_NOREF) {
            lua_rawgeti(vtable_copy.L, LUA_REGISTRYINDEX, vtable_copy.extension_deinit_ref);
            int status = lua_pcall(vtable_copy.L, 0, 0, 0);
            checkLuaError(vtable_copy.L, status);
        }
        free(vtable_copy.udata);
        vtable_copy.udata = NULL;
        lua_close(vtable_copy.L);
    }
}

static void sqlite_conn_cleanup_destroy_cb(void *p) {
    cleanup_conn_state((ConnState*)p);
}

static void sqlite_conn_cleanup_noop_fn(sqlite3_context *ctx, int argc, sqlite3_value **argv) {
    (void)argc;
    (void)argv;
    sqlite3_api->result_null(ctx);
}

static void sqlite_luajit_callback(sqlite3_context *ctx, int argc, sqlite3_value **argv) {
    ConnState *state = conn_state_from_context(ctx);
    if (!state) {
        sqlite3_api->result_error(ctx, "sqlite_plugin_lj: connection state missing", -1);
        return;
    }
    if (!claim_or_validate_owner_thread(state)) {
        sqlite3_api->result_error(ctx, THREAD_GUARD_ERR, -1);
        return;
    }
    Worker w = push_vm(state);
    if (!w.L) {
        // Handle error
        sqlite3_api->result_error(ctx, VM_INIT_ERR, -1);
        pop_vm(state, w);
        return;
    }

    w.udata->caller_fn(ctx, argc, argv);

    pop_vm(state, w);
}

static void sqlite_luajit_callback_context_fn(sqlite3_context *ctx, int argc, sqlite3_value **argv) {
    ConnState *state = conn_state_from_context(ctx);
    if (!state) {
        sqlite3_api->result_error(ctx, "sqlite_plugin_lj: connection state missing", -1);
        return;
    }
    if (!claim_or_validate_owner_thread(state)) {
        sqlite3_api->result_error(ctx, THREAD_GUARD_ERR, -1);
        return;
    }
    Worker w = push_vm(state);
    if (!w.L) {
        sqlite3_api->result_error(ctx, VM_INIT_ERR, -1);
        pop_vm(state, w);
        return;
    }
    const FunctionContext* fn_context = getFunctionContext((int64_t)sqlite3_api->user_data(ctx));
    if (!fn_context) {
        pop_vm(state, w);
        return;
    }
    if (!fn_context->fn_ptr) {
        sqlite3_api->result_error(ctx, FN_CONTEXT_ERR, -1);
        pop_vm(state, w);
        return;
    }
    if (!fn_context->allowed_nested && state && state->call_depth > 1) {
        // Handle error
        sqlite3_api->result_error(ctx, "max call depth[1] exceeded", -1);
        pop_vm(state, w);
        return;
    }
    

    fn_context->fn_ptr(ctx, argc, argv);

    pop_vm(state, w);
}

static void sqlite_luajit_callback_context_step_fn(sqlite3_context *ctx, int argc, sqlite3_value **argv) {
    ConnState *state = conn_state_from_context(ctx);
    if (!state) {
        sqlite3_api->result_error(ctx, "sqlite_plugin_lj: connection state missing", -1);
        return;
    }
    if (!claim_or_validate_owner_thread(state)) {
        sqlite3_api->result_error(ctx, THREAD_GUARD_ERR, -1);
        return;
    }
    Worker w = push_vm(state);
    if (!w.L) {
        sqlite3_api->result_error(ctx, VM_INIT_ERR, -1);
        pop_vm(state, w);
        return;
    }
    const FunctionContext* fn_context = getFunctionContext((int64_t)sqlite3_api->user_data(ctx));
    if (!fn_context) {
        pop_vm(state, w);
        return;
    }
    if (!fn_context->fn_step_ptr) {
        sqlite3_api->result_error(ctx, FN_CONTEXT_ERR, -1);
        pop_vm(state, w);
        return;
    }

    if (!fn_context->allowed_nested && state && state->call_depth > 1) {
        sqlite3_api->result_error(ctx, "max call depth[1] exceeded", -1);
        pop_vm(state, w);
        return;
    }

    fn_context->fn_step_ptr(ctx, argc, argv);
    pop_vm(state, w);
}

static void sqlite_luajit_callback_context_final_fn(sqlite3_context *ctx) {
    ConnState *state = conn_state_from_context(ctx);
    if (!state) {
        sqlite3_api->result_error(ctx, "sqlite_plugin_lj: connection state missing", -1);
        return;
    }
    if (!claim_or_validate_owner_thread(state)) {
        sqlite3_api->result_error(ctx, THREAD_GUARD_ERR, -1);
        return;
    }
    Worker w = push_vm(state);
    if (!w.L) {
        sqlite3_api->result_error(ctx, VM_INIT_ERR, -1);
        pop_vm(state, w);
        return;
    }
    const FunctionContext* fn_context = getFunctionContext((int64_t)sqlite3_api->user_data(ctx));
    if (!fn_context) {
        pop_vm(state, w);
        return;
    }
    if (!fn_context->fn_final_ptr) {
        sqlite3_api->result_error(ctx, FN_CONTEXT_ERR, -1);
        pop_vm(state, w);
        return;
    }

    if (!fn_context->allowed_nested && state && state->call_depth > 1) {
        sqlite3_api->result_error(ctx, "max call depth[1] exceeded", -1);
        pop_vm(state, w);
        return;
    }

    fn_context->fn_final_ptr(ctx);
    pop_vm(state, w);
}

static void sqlite_luajit_callback_context_destroy_fn(void *unused) {
    (void)unused;
    // to be implemented if needed
}


static void sqlite_return_int_cb(sqlite3_context *ctx, int argc, sqlite3_value **argv) {
    (void)argc;
    (void)argv;
    int64_t saved_constant = (int64_t) sqlite3_api->user_data(ctx);
    sqlite3_api->result_int64(ctx, saved_constant);
}

static void sqlite_return_text_cb(sqlite3_context *ctx, int argc, sqlite3_value **argv) {
    (void)argc;
    (void)argv;
    const char* saved_constant = (const char*) sqlite3_api->user_data(ctx);
    if (saved_constant == NULL) {
        sqlite3_api->result_null(ctx);
        return;
    }
    sqlite3_api->result_text(ctx, saved_constant, -1, SQLITE_STATIC);
}

static void sqlite_user_data_free_cb(void* user_data) {
    sqlite3_api->free(user_data);
}


// Forward declaration for get_vm with vtable flag
static Worker get_vm_internal(ConnState *state, int is_vtable);

// Initialize the dedicated vtable VM
static void ensure_vtable_vm(ConnState *state) {
    if (!state) {
        return;
    }
    if (!state->vtable_vm_initialized) {
        state->vtable_vm = get_vm_internal(state, 1);
        state->vtable_vm_initialized = state->vtable_vm.L != NULL;
    }
}

// C wrapper for vtable xOpen
static int cb_vtab_xOpen(sqlite3_vtab* pVtab, sqlite3_vtab_cursor** ppCursor) {
    ConnState *state = conn_state_from_vtab(pVtab);
    if (!state) {
        pVtab->zErrMsg = sqlite3_api->mprintf("vtable connection state missing");
        return SQLITE_ERROR;
    }
    if (!claim_or_validate_owner_thread(state)) {
        pVtab->zErrMsg = sqlite3_api->mprintf("%s", THREAD_GUARD_ERR);
        return SQLITE_ERROR;
    }
    if (state->vtable_vm_busy) {
        pVtab->zErrMsg = sqlite3_api->mprintf("vtable cannot be used from nested context (vtable VM is busy)");
        return SQLITE_ERROR;
    }

    ensure_vtable_vm(state);
    if (!state->vtable_vm.L || !state->vtable_vm.udata || !state->vtable_vm.udata->vtab_xOpen_lua) {
        pVtab->zErrMsg = sqlite3_api->mprintf("vtable VM not properly initialized");
        return SQLITE_ERROR;
    }

    state->vtable_vm_busy = true;
    int result = state->vtable_vm.udata->vtab_xOpen_lua(pVtab, ppCursor);
    state->vtable_vm_busy = false;

    return result;
}

// C wrapper for vtable xClose
static int cb_vtab_xClose(sqlite3_vtab_cursor* cursor) {
    ConnState *state = conn_state_from_vtab(cursor ? cursor->pVtab : NULL);
    if (!state) {
        if (cursor && cursor->pVtab) {
            cursor->pVtab->zErrMsg = sqlite3_api->mprintf("vtable connection state missing");
        }
        return SQLITE_ERROR;
    }
    if (!claim_or_validate_owner_thread(state)) {
        cursor->pVtab->zErrMsg = sqlite3_api->mprintf("%s", THREAD_GUARD_ERR);
        return SQLITE_ERROR;
    }
    if (state->vtable_vm_busy) {
        cursor->pVtab->zErrMsg = sqlite3_api->mprintf("vtable cannot be used from nested context (vtable VM is busy)");
        return SQLITE_ERROR;
    }

    ensure_vtable_vm(state);
    if (!state->vtable_vm.L || !state->vtable_vm.udata || !state->vtable_vm.udata->vtab_xClose_lua) {
        cursor->pVtab->zErrMsg = sqlite3_api->mprintf("vtable VM not properly initialized");
        return SQLITE_ERROR;
    }

    state->vtable_vm_busy = true;
    int result = state->vtable_vm.udata->vtab_xClose_lua(cursor);
    state->vtable_vm_busy = false;

    return result;
}

// C wrapper for vtable xFilter - checks busy flag before calling Lua
static int cb_vtab_xFilter(sqlite3_vtab_cursor* cursor, int idxNum, const char* idxStr, int argc, sqlite3_value** argv) {
    ConnState *state = conn_state_from_vtab(cursor ? cursor->pVtab : NULL);
    if (!state) {
        if (cursor && cursor->pVtab) {
            cursor->pVtab->zErrMsg = sqlite3_api->mprintf("vtable connection state missing");
        }
        return SQLITE_ERROR;
    }
    if (!claim_or_validate_owner_thread(state)) {
        cursor->pVtab->zErrMsg = sqlite3_api->mprintf("%s", THREAD_GUARD_ERR);
        return SQLITE_ERROR;
    }
    if (state->vtable_vm_busy) {
        cursor->pVtab->zErrMsg = sqlite3_api->mprintf("vtable cannot be used from nested context (vtable VM is busy)");
        return SQLITE_ERROR;
    }

    ensure_vtable_vm(state);
    if (!state->vtable_vm.L || !state->vtable_vm.udata || !state->vtable_vm.udata->vtab_xFilter_lua) {
        cursor->pVtab->zErrMsg = sqlite3_api->mprintf("vtable VM not properly initialized");
        return SQLITE_ERROR;
    }

    state->vtable_vm_busy = true;
    int result = state->vtable_vm.udata->vtab_xFilter_lua(cursor, idxNum, idxStr, argc, argv);
    state->vtable_vm_busy = false;

    return result;
}

// C wrapper for vtable xNext - checks busy flag before calling Lua
static int cb_vtab_xNext(sqlite3_vtab_cursor* cursor) {
    ConnState *state = conn_state_from_vtab(cursor ? cursor->pVtab : NULL);
    if (!state) {
        if (cursor && cursor->pVtab) {
            cursor->pVtab->zErrMsg = sqlite3_api->mprintf("vtable connection state missing");
        }
        return SQLITE_ERROR;
    }
    if (!claim_or_validate_owner_thread(state)) {
        cursor->pVtab->zErrMsg = sqlite3_api->mprintf("%s", THREAD_GUARD_ERR);
        return SQLITE_ERROR;
    }
    if (state->vtable_vm_busy) {
        cursor->pVtab->zErrMsg = sqlite3_api->mprintf("vtable cannot be used from nested context (vtable VM is busy)");
        return SQLITE_ERROR;
    }

    ensure_vtable_vm(state);
    if (!state->vtable_vm.L || !state->vtable_vm.udata || !state->vtable_vm.udata->vtab_xNext_lua) {
        cursor->pVtab->zErrMsg = sqlite3_api->mprintf("vtable VM not properly initialized");
        return SQLITE_ERROR;
    }

    state->vtable_vm_busy = true;
    int result = state->vtable_vm.udata->vtab_xNext_lua(cursor);
    state->vtable_vm_busy = false;

    return result;
}

// C wrapper for vtable xEof
static int cb_vtab_xEof(sqlite3_vtab_cursor* cursor) {
    ConnState *state = conn_state_from_vtab(cursor ? cursor->pVtab : NULL);
    if (!state) {
        return 1;
    }
    if (!claim_or_validate_owner_thread(state)) {
        return 1;
    }
    // xEof doesn't set error message, just returns true/false (non-zero = EOF)
    if (state->vtable_vm_busy) {
        return 1; // return EOF to stop iteration
    }

    ensure_vtable_vm(state);
    if (!state->vtable_vm.L || !state->vtable_vm.udata || !state->vtable_vm.udata->vtab_xEof_lua) {
        return 1; // return EOF
    }

    state->vtable_vm_busy = true;
    int result = state->vtable_vm.udata->vtab_xEof_lua(cursor);
    state->vtable_vm_busy = false;

    return result;
}

// C wrapper for vtable xColumn
static int cb_vtab_xColumn(sqlite3_vtab_cursor* cursor, sqlite3_context* ctx, int col) {
    ConnState *state = conn_state_from_vtab(cursor ? cursor->pVtab : NULL);
    if (!state) {
        sqlite3_api->result_error(ctx, "vtable connection state missing", -1);
        return SQLITE_ERROR;
    }
    if (!claim_or_validate_owner_thread(state)) {
        sqlite3_api->result_error(ctx, THREAD_GUARD_ERR, -1);
        return SQLITE_ERROR;
    }
    if (state->vtable_vm_busy) {
        sqlite3_api->result_error(ctx, "vtable cannot be used from nested context", -1);
        return SQLITE_ERROR;
    }

    ensure_vtable_vm(state);
    if (!state->vtable_vm.L || !state->vtable_vm.udata || !state->vtable_vm.udata->vtab_xColumn_lua) {
        sqlite3_api->result_error(ctx, "vtable VM not properly initialized", -1);
        return SQLITE_ERROR;
    }

    state->vtable_vm_busy = true;
    int result = state->vtable_vm.udata->vtab_xColumn_lua(cursor, ctx, col);
    state->vtable_vm_busy = false;
    return result;
}

// C wrapper for vtable xRowid
static int cb_vtab_xRowid(sqlite3_vtab_cursor* cursor, sqlite3_int64* pRowid) {
    ConnState *state = conn_state_from_vtab(cursor ? cursor->pVtab : NULL);
    if (!state) {
        if (cursor && cursor->pVtab) {
            cursor->pVtab->zErrMsg = sqlite3_api->mprintf("vtable connection state missing");
        }
        return SQLITE_ERROR;
    }
    if (!claim_or_validate_owner_thread(state)) {
        cursor->pVtab->zErrMsg = sqlite3_api->mprintf("%s", THREAD_GUARD_ERR);
        return SQLITE_ERROR;
    }
    if (state->vtable_vm_busy) {
        cursor->pVtab->zErrMsg = sqlite3_api->mprintf("vtable cannot be used from nested context (vtable VM is busy)");
        return SQLITE_ERROR;
    }

    ensure_vtable_vm(state);
    if (!state->vtable_vm.L || !state->vtable_vm.udata || !state->vtable_vm.udata->vtab_xRowid_lua) {
        cursor->pVtab->zErrMsg = sqlite3_api->mprintf("vtable VM not properly initialized");
        return SQLITE_ERROR;
    }

    state->vtable_vm_busy = true;
    int result = state->vtable_vm.udata->vtab_xRowid_lua(cursor, pRowid);
    state->vtable_vm_busy = false;
    return result;
}

#include "sqlite_capi.h"
#include "sqlite_lj.h"
static Worker get_vm_internal(ConnState *state, int is_vtable) {
    Worker w = (Worker){0};
    w.extension_init_ref = LUA_NOREF;
    w.extension_deinit_ref = LUA_NOREF;
    w.extension_call_ref = LUA_NOREF;
    if (!state) {
        return w;
    }
    w.L = lua_open();
    if (!w.L) {
        return w;
    }
    //LUAJIT_VERSION_SYM();
    lua_gc(w.L, LUA_GCSTOP, 0);
    luaL_openlibs(w.L);
    lua_gc(w.L, LUA_GCRESTART, -1);

    if (loadBytecodeObject(
        w.L,
        luaJIT_BC_sqlite_capi,
        luaJIT_BC_sqlite_capi_SIZE, "sqlite_capi") != 0)
    {
        lua_close(w.L);
        w.L = NULL;
        return w;
    }

    if (loadBytecodeObject(
        w.L,
        luaJIT_BC_sqlite_lj,
        luaJIT_BC_sqlite_lj_SIZE, "sqlite") != 0)
    {
        lua_close(w.L);
        w.L = NULL;
        return w;
    }

    lua_getglobal(w.L, "sqlite");

    {
        lua_getfield(w.L, 1, "extension_init");
        w.extension_init_ref  = luaL_ref(w.L, LUA_REGISTRYINDEX);
        lua_getfield(w.L, 1, "extension_deinit");
        w.extension_deinit_ref = luaL_ref(w.L, LUA_REGISTRYINDEX);
        lua_getfield(w.L, 1, "extension_call");
        w.extension_call_ref = luaL_ref(w.L, LUA_REGISTRYINDEX);
        lua_settop(w.L, 0);



        lua_rawgeti(w.L, LUA_REGISTRYINDEX, w.extension_init_ref);

        w.udata = (LJFunctionData*)calloc(1, sizeof(LJFunctionData));
        if (!w.udata) {
            lua_close(w.L);
            w.L = NULL;
            return w;
        }

        w.udata->db = state->db;
        w.udata->api = sqlite3_api;
        w.udata->callback = sqlite_luajit_callback;
        w.udata->cb_context_fn = sqlite_luajit_callback_context_fn;
        w.udata->cb_context_step_fn = sqlite_luajit_callback_context_step_fn;
        w.udata->cb_context_final_fn = sqlite_luajit_callback_context_final_fn;
        w.udata->cb_context_destroy_fn = sqlite_luajit_callback_context_destroy_fn;
        w.udata->sqlite_return_int_cb = sqlite_return_int_cb;
        w.udata->sqlite_return_text_cb = sqlite_return_text_cb;
        w.udata->sqlite_free_cb = sqlite_user_data_free_cb;

        // bridge functions
        w.udata->set_object = bridge_set_object_locked;
        w.udata->get_object = bridge_get_object_locked;

        w.udata->pushFunctionContext = pushFunctionContext;
        w.udata->getFunctionContext = getFunctionContext;

        w.udata->call_depth = state->call_depth - 1;
        w.udata->is_vtable_vm = is_vtable;
        w.udata->conn_slot = state->slot;
        w.udata->caller_fn = NULL;

        // vtable callbacks - Lua implementations set by Lua, C wrappers provided here
        w.udata->vtab_xOpen_lua = NULL;
        w.udata->vtab_xClose_lua = NULL;
        w.udata->vtab_xFilter_lua = NULL;
        w.udata->vtab_xNext_lua = NULL;
        w.udata->vtab_xEof_lua = NULL;
        w.udata->vtab_xColumn_lua = NULL;
        w.udata->vtab_xRowid_lua = NULL;
        w.udata->cb_vtab_xOpen = cb_vtab_xOpen;
        w.udata->cb_vtab_xClose = cb_vtab_xClose;
        w.udata->cb_vtab_xFilter = cb_vtab_xFilter;
        w.udata->cb_vtab_xNext = cb_vtab_xNext;
        w.udata->cb_vtab_xEof = cb_vtab_xEof;
        w.udata->cb_vtab_xColumn = cb_vtab_xColumn;
        w.udata->cb_vtab_xRowid = cb_vtab_xRowid;

        lua_pushlightuserdata(w.L, w.udata);

        int status = lua_pcall(w.L, 1, 0, 0);
        if (!checkLuaError(w.L, status)) {
            free(w.udata);
            w.udata = NULL;
            lua_close(w.L);
            w.L = NULL;
            w.extension_init_ref = LUA_NOREF;
            w.extension_deinit_ref = LUA_NOREF;
            w.extension_call_ref = LUA_NOREF;
            return w;
        }
        lua_settop(w.L, 0);
    }
    return w;
}

Worker push_vm(ConnState *state) {
    Worker empty = (Worker){0};
    if (!state) {
        return empty;
    }
    ++state->call_depth;
    if(state->call_depth > SAVED_VM) {
        return get_vm_internal(state, 0);
    } else {
        if (!state->vm_stack[state->call_depth-1].L) {
            state->vm_stack[state->call_depth-1] = get_vm_internal(state, 0);
        }
        return state->vm_stack[state->call_depth-1];
    }

}

void pop_vm(ConnState *state, Worker w){
    if (!state) {
        return;
    }
    if (!w.L) {
        --state->call_depth;
        return;
    }

    if(state->call_depth > SAVED_VM) {
        lua_State* L = w.L;
        if (w.extension_deinit_ref != LUA_NOREF) {
            lua_rawgeti(L, LUA_REGISTRYINDEX, w.extension_deinit_ref);
            int status = lua_pcall(L, 0, 0, 0);
            checkLuaError(L, status);
        }
        free(w.udata);
        w.udata = NULL;

        lua_close(L);
    }
    --state->call_depth;
}



#include "sqlite_shared.h"
void ATTR_CONSTRUCTOR before_main(void)
{
    if (L_shared || bridge_ready) {
        return;
    }
    L_shared = lua_open();
    if (!L_shared) {
        set_bridge_error("sqlite_plugin_lj: failed to create shared Lua state");
        return;
    }
    lua_gc(L_shared, LUA_GCSTOP, 0);
    luaL_openlibs(L_shared);
    lua_gc(L_shared, LUA_GCRESTART, -1);

    if (loadBytecodeObject(
        L_shared, 
        luaJIT_BC_sqlite_shared, 
        luaJIT_BC_sqlite_shared_SIZE, "sqlite_shared") != 0) {
        set_bridge_error("sqlite_plugin_lj: failed to load sqlite_shared bytecode");
        return;
    }

    if (luaL_dostring(L_shared,
        "return sqlite_shared\n"

    ) != LUA_OK) {
        const char* err = lua_tostring(L_shared, -1);
        printf("Lua load error: %s\n", err);
        set_bridge_error("sqlite_plugin_lj: failed to load sqlite_shared module");
        lua_pop(L_shared, 1);
        return;
    }
    lua_getfield(L_shared, -1, "init");  // plugin.init
    if (!lua_isfunction(L_shared, -1)) {
        printf("Error: init is not a function\n");
        set_bridge_error("sqlite_plugin_lj: sqlite_shared.init is not a function");
        lua_pop(L_shared, 2); // remove plugin and whatever is on top
        return;
    }

    lua_pushlightuserdata(L_shared, &bridge);

    if (lua_pcall(L_shared, 1, 0, 0) != LUA_OK) {
        const char* err = lua_tostring(L_shared, -1);
        printf("Lua init error: %s\n", err);
        set_bridge_error("sqlite_plugin_lj: sqlite_shared.init failed");
        lua_pop(L_shared, 1);
        return;
    }

    if (bridge.set_fn_context && bridge.get_fn_context) {
        bridge_ready = 1;
    } else {
        set_bridge_error("sqlite_plugin_lj: bridge callbacks not initialized");
    }
}

void ATTR_DESTRUCTOR after_main(void);
void after_main(void)
{
    for (int i = 0; i < MAX_CONN_STATES; ++i) {
        cleanup_conn_state(&conn_states[i]);
    }
    if (L_shared) {
        lua_close(L_shared);
    }

}


int checkLuaError(lua_State* L, int status)
{
    if (status == LUA_OK) {
        return 1;
    }
    const char* detail = NULL;
    if (L && lua_gettop(L) > 0) {
        detail = lua_tostring(L, -1);
    }
    if (!detail) {
        detail = "[non-string lua error]";
    }
    printf("Lua error %d: %s\n", status, detail);
    if (L && lua_gettop(L) > 0) {
        lua_pop(L, 1);
    }
    return 0;
}

extern EXT_EXPORT int sqlite3_extension_init(
    sqlite3 *,
    char **,
    const sqlite3_api_routines *pApi);

extern EXT_EXPORT int sqlite3_extension_init(
    sqlite3 * db,
    char **msg,
    const sqlite3_api_routines *api)
{
    sqlite3_api = api;
    ConnState *state = get_or_create_conn_state(db);
    if (!state) {
        if (msg) {
            *msg = sqlite3_api->mprintf("%s", "sqlite_plugin_lj: too many active sqlite connections");
        }
        return SQLITE_ERROR;
    }
    if (state->vm_stack[0].L || state->vtable_vm.L) {
        cleanup_conn_state(state);
        state->db = db;
    }

#if defined(_MSC_VER)
    /* MSVC does not support GCC constructor attributes; initialize lazily. */
    state_lock();
    if (!L_shared && !bridge_ready) {
        before_main();
    }
    state_unlock();
#endif

    if (!bridge_ready || !bridge.set_fn_context || !bridge.get_fn_context) {
        if (msg) {
            const char* detail = bridge_init_error[0] ? bridge_init_error : "sqlite_plugin_lj: shared bridge not initialized";
            *msg = sqlite3_api->mprintf("%s", detail);
        }
        return SQLITE_ERROR;
    }

    if (!state->cleanup_registered) {
        int rc = sqlite3_api->create_function_v2(
            db,
            "__sqlite_lj_conn_cleanup__",
            0,
            SQLITE_UTF8,
            state,
            sqlite_conn_cleanup_noop_fn,
            NULL,
            NULL,
            sqlite_conn_cleanup_destroy_cb
        );
        if (rc != SQLITE_OK) {
            if (msg) {
                *msg = sqlite3_api->mprintf("%s", sqlite3_api->errmsg(db));
            }
            return SQLITE_ERROR;
        }
        state->cleanup_registered = true;
    }

    pushFunctionContext((FunctionContext){0}); // index 0 is empty context

    Worker w = push_vm(state);
    if (!w.L){
        if (msg) {
            *msg = sqlite3_api->mprintf("%s", VM_INIT_ERR);
        }
        return SQLITE_ERROR;
    }
    pop_vm(state, w);

    return SQLITE_OK;
}
