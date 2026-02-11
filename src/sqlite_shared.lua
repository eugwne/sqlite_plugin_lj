local ffi = require('ffi')
local C = ffi.C

local plugin = {}
local cache_index = 1

local function read_limit(name, default)
    local raw = os.getenv(name)
    local n = raw and tonumber(raw) or nil
    if n and n > 0 then
        return math.floor(n)
    end
    return default
end

local LIMITS = {
    max_buffer_bytes = read_limit("SQLITE_LJ_MAX_BUFFER_BYTES", 64 * 1024 * 1024),
    max_object_bytes = read_limit("SQLITE_LJ_MAX_OBJECT_BYTES", 4 * 1024 * 1024),
    max_objects = read_limit("SQLITE_LJ_MAX_OBJECTS", 200000),
    max_function_contexts = read_limit("SQLITE_LJ_MAX_FUNCTION_CONTEXTS", 50000),
}

ffi.cdef[[
typedef long long int int64_t;
typedef struct {
    void* fn_ptr;
    void* fn_step_ptr;
    void* fn_final_ptr;
    void* fn_destroy_ptr;
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
]]

-- Extendable buffer manager
local BufferManager = {}
BufferManager.__index = BufferManager

function BufferManager.new(size)
    local self = setmetatable({}, BufferManager)
    self.size = size or (1024*1024)
    local ok, buf = pcall(ffi.new, "uint8_t[?]", self.size)
    if not ok then
        return nil, "shared buffer allocation failed"
    end
    self.buf = buf
    self.offset = 0
    self.registry = {}
    self.object_count = 0
    return self
end

function BufferManager:ensure_capacity(additional)
    local needed = self.offset + additional
    if needed > LIMITS.max_buffer_bytes then
        return nil, "shared buffer max bytes exceeded"
    end

    if needed > self.size then
        local new_size = math.max(self.size * 2, needed)
        if new_size > LIMITS.max_buffer_bytes then
            new_size = LIMITS.max_buffer_bytes
        end
        local ok, new_buf = pcall(ffi.new, "uint8_t[?]", new_size)
        if not ok then
            return nil, "shared buffer grow failed"
        end
        ffi.copy(new_buf, self.buf, self.offset)
        self.buf = new_buf
        self.size = new_size
    end
    return true
end

function BufferManager:store(id, data)
    local len = #data
    if len > LIMITS.max_object_bytes then
        return nil, "shared object exceeds max bytes"
    end
    if self.object_count >= LIMITS.max_objects then
        return nil, "shared object count limit exceeded"
    end

    local ok, err = self:ensure_capacity(len)
    if not ok then
        return nil, err
    end
    ffi.copy(self.buf + self.offset, data, len)
    self.registry[id] = { start = self.offset, len = len }
    self.offset = self.offset + len
    self.object_count = self.object_count + 1
    return true
end

function BufferManager:retrieve(id)
    local e = self.registry[id]
    if not e then return nil end
    return ffi.string(self.buf + e.start, e.len)
end

-- singleton manager
local manager, manager_err = BufferManager.new()
if not manager then
    error(manager_err)
end

-- Lua functions to expose
local function setObject(data, len)
    if len > LIMITS.max_object_bytes then
        return 0
    end
    if cache_index > 0x7FFFFFFF or cache_index > LIMITS.max_objects then
        return 0
    end
    local id = cache_index

    local s = ffi.string(data, len)
    local ok = manager:store(id, s)
    if not ok then
        return 0
    end
    cache_index = cache_index + 1
    return id
end

local function getObjectString(id, size_out)
    if type(id) ~= 'number' or id <= 0 or id ~= math.floor(id) then
        size_out[0] = 0
        return nil
    end
    local s = manager:retrieve(id)
    if not s then
        size_out[0] = 0
        return nil
    end
    size_out[0] = #s
    return s
end

local function_contexts = {}
local function_contexts_next_id = 1

local function setFunctionContext(ctx)
    if function_contexts_next_id > LIMITS.max_function_contexts then
        return 0
    end
    local id = function_contexts_next_id
    function_contexts_next_id = function_contexts_next_id + 1
    local fc = ffi.new("FunctionContext[1]")
    ffi.copy(fc, ctx, ffi.sizeof("FunctionContext"))
    function_contexts[id] = fc
    return id
end

local function getFunctionContext(id)
    id = tonumber(id)
    if not id then
        return nil
    end
    local fc = function_contexts[id]
    if not fc then
        return nil
    end
    return fc
end

-- -- Create C struct with function pointers
-- local bridge = ffi.new("SharedBridge")
-- bridge.set_object = ffi.cast("set_object_cb_t", setObject)
-- bridge.get_object = ffi.cast("get_object_cb_t", getObjectString)

plugin.init = function(bridge_ptr)
    local bridge = ffi.cast('SharedBridge*', bridge_ptr)
    --print('Bridge set', bridge)
    local cb_set_object = ffi.cast("set_object_cb_t", setObject)
    local cb_get_object = ffi.cast("get_object_cb_t", getObjectString)
    local cb_set_fn_context = ffi.cast("set_fn_context_cb_t", setFunctionContext)
    local cb_get_fn_context = ffi.cast("get_fn_context_cb_t", getFunctionContext)

    bridge.set_object = cb_set_object
    bridge.get_object = cb_get_object
    bridge.set_fn_context = cb_set_fn_context
    bridge.get_fn_context = cb_get_fn_context

    -- Keep callbacks alive
    plugin._bridge_callbacks = {
        set_object = cb_set_object,
        get_object = cb_get_object,
        set_fn_context = cb_set_fn_context,
        get_fn_context = cb_get_fn_context
    }
end
return plugin
