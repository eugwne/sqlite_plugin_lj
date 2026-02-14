local plugin = {}

plugin._DESCRIPTION = "LuaJIT FFI sqlite language extension"
plugin._VERSION = "sqlite lj 0.3"

local ffi = require('ffi')

local sqlite_capi = sqlite_capi or require('sqlite_capi')
local SQLITE = sqlite_capi.SQLITE
local NULL = sqlite_capi.NULL

local int_t = ffi.typeof("int")
local int64_t = ffi.typeof("int64_t")
local uint64_t = ffi.typeof("uint64_t")
local float_t = ffi.typeof("float")
local double_t = ffi.typeof("double")

local sqlite3_module_t = ffi.typeof('sqlite3_module')
local vtab_cursor_t = ffi.typeof('lua_vtab_cursor')

local bor = require("bit").bor

local plugin_init_data
local sqlite_db
local sqlite_api

local unfinalized_statements = setmetatable({}, { __mode = "k" })

local safe_finalize_stmt = function(stmt_pp)
    if stmt_pp == nil then
        return SQLITE.OK
    end
    local stmt_p = stmt_pp[0]
    if stmt_p == nil then
        return SQLITE.OK
    end
    stmt_pp[0] = nil
    return sqlite_api.finalize(stmt_p)
end

local close_unfinalized = function ()
    local close_error
    for stmt, status in pairs(unfinalized_statements) do
        if status.isopen and stmt[0] ~= nil then
            status.isopen = false
            unfinalized_statements[stmt] = nil
            local step_rc = safe_finalize_stmt(stmt)
            if step_rc ~= SQLITE.OK and close_error == nil then
                close_error = 'close unfinalized statement failed: ' .. tostring(status.sql)
            end
        end
    end
    return close_error
end

local LJError = (function ()
    local self = {}

    local text

    self.get = function ()
        return text
    end

    self.set = function (value)
        text = value
        return self
    end
    
    return self
end)()

local is_error = function (value)
    return value == LJError
end

local public_env_mt = {
    __index = _G
}

local public_env = {}
public_env.NULL = NULL

public_env.int_t = int_t
public_env.int64_t = int64_t
public_env.uint64_t = uint64_t
public_env.double_t = double_t

local config = {}
public_env.config = config

local function error_xcall(err)
    if type(err) == "table" then
        if err.detail == nil then
            err.detail = config.use_traceback == 0 and '' or debug.traceback()
        end
        return err
    else
        return { message = err, detail = config.use_traceback == 0 and '' or debug.traceback() }
    end
end

local buffer = require("string.buffer")
local function setObject(obj)
    local encoded = buffer.encode(obj)
    local key = tonumber(plugin_init_data.set_object(encoded, #encoded))
    if not key or key <= 0 then
        return error("shared object storage limit exceeded")
    end
    return key
end

local function getObject(id)
    local size_out = ffi.new("size_t[1]")
    local ptr = plugin_init_data.get_object(id, size_out)
    if ptr == nil then return nil end
    local encoded = ffi.string(ptr, size_out[0])
    return buffer.decode(encoded)
end

local function Storage()
    local self = {}
    local map = {}
    local next_key = 1

    self.new_key = function (item)
        next_key = next_key + 1
        while map[next_key] do
            next_key = next_key + 1
        end
        map[next_key] = item
        return next_key
    end

    self.get = function (key)
        key = tonumber(key)
        return map[key]
    end

    self.remove = function (key)
        key = tonumber(key)
        map[key] = nil
    end

    return self
end



local function FNStorage()
    local self = {}
    local map = {}

    self.new_key = function (name, code_text)
        if type(code_text) ~= 'string' then
            return nil, 'code_text is not a string'
        end
        local fn, err = self.__make_fn(name, code_text)
        if not fn then
            return nil, 'Failed to create function: ' .. tostring(err)
        end
        local key = setObject({name = name, code_text = code_text})
        return tonumber(key)
    end

    self.get = function (key)
        local key = tonumber(key)
        if not map[key] then
            local obj = getObject(key)
            if obj then
                local fn_name = obj.name or tostring(key)
                local fn, err = self.__make_fn(fn_name, ffi.string(obj.code_text), -1)
                if not fn then
                    return nil, 'Failed to load function: ' .. tostring(err)
                end
                map[key] = fn
            end
        end
        return map[key]
    end

    self.remove = function (key)
        key = tonumber(key)
        map[key] = nil
    end

    self.__make_fn = function(name, code_text)
        if code_text == nil then return end

        local fn_env = {}
        setmetatable(fn_env, public_env_mt)

        local f, err = loadstring(code_text, name, "t", fn_env)
        if (f) then
            local status, res = xpcall(f, error_xcall)
            if not status then
                local msg = 'Create failed ['.. name .. ']\n'  ..tostring(res.message) .. '\n' .. res.detail
                return nil, msg
            end

            setfenv(res, fn_env)
            return res, nil

        else
            local msg = 'Create failed ['.. name .. ']\n' .. tostring(err)
            return nil, msg
        end
    end

    return self
end

local function AggChkStorage()
    local self = {}
    local map = {}

    self.new_key = function(name, init_text, step_text, final_text, inverse_text)
        -- Validate and compile to check for errors early
        local init_fn, err = loadstring(init_text, name..':init', "t")
        if not init_fn then return nil, err end
        local step_fn, err = loadstring(step_text, name..':step', "t")
        if not step_fn then return nil, err end
        local final_fn, err = loadstring(final_text, name..':final', "t")
        if not final_fn then return nil, err end
        if inverse_text then
            local inverse_fn, err = loadstring(inverse_text, name..':inverse', "t")
            if not inverse_fn then return nil, err end
        end

        -- Store text in shared memory (include name for better error messages)
        local key = setObject({name = name, init = init_text, step = step_text, final = final_text, inverse = inverse_text})
        return tonumber(key)
    end

    self.get = function(key)
        key = tonumber(key)
        if key == nil then
            return nil
        end
        if not map[key] then
            local obj = getObject(key)
            if obj then
                local fn_name = obj.name or tostring(key)
                local init_fn, err = loadstring(obj.init, fn_name..':init', "t")
                if not init_fn then
                    error('aggregate load failed ['..fn_name..':init]: '..tostring(err))
                end
                local step_fn, err = loadstring(obj.step, fn_name..':step', "t")
                if not step_fn then
                    error('aggregate load failed ['..fn_name..':step]: '..tostring(err))
                end
                local final_fn, err = loadstring(obj.final, fn_name..':final', "t")
                if not final_fn then
                    error('aggregate load failed ['..fn_name..':final]: '..tostring(err))
                end
                local inverse_fn = nil
                if obj.inverse then
                    inverse_fn, err = loadstring(obj.inverse, fn_name..':inverse', "t")
                    if not inverse_fn then
                        error('aggregate load failed ['..fn_name..':inverse]: '..tostring(err))
                    end
                end
                map[key] = {
                    init = init_fn,
                    step = step_fn,
                    final = final_fn,
                    inverse = inverse_fn
                }
            end
        end
        return map[key]
    end

    self.remove = function(key)
        key = tonumber(key)
        if key == nil then
            return
        end
        map[key] = nil
    end

    return self
end

local function_refs_text = FNStorage()
local agg_chk_refs_text = AggChkStorage()
local function_refs = Storage()
local agg_function_refs = Storage()
local vfunc_cur = Storage()

-- Shared storage for vtable metadata (accessible from vtable_vm)
local function SharedStorage()
    local self = {}
    local map = {}

    self.new_key = function(data)
        -- Store in shared memory
        local key = setObject(data)
        return tonumber(key)
    end

    self.get = function(key)
        key = tonumber(key)
        if not map[key] then
            -- Retrieve from shared memory and cache locally
            local obj = getObject(key)
            if obj then
                map[key] = obj
            end
        end
        return map[key]
    end

    self.remove = function(key)
        key = tonumber(key)
        map[key] = nil
    end

    return self
end

local shared_vtab_data = SharedStorage()
local make_vtable_modules = {}


local wrap_csafe
local wrap_csafe_cs
local create_function_agg_chk
local run_sql
local fetch_all
local fetch_first
local nrows

local map_sqlite_to_lj = {
    [SQLITE.INTEGER] = function (value)
        return (sqlite_api.value_int64(value)) --subtype maybe
    end,
    [SQLITE.TEXT] = function (value)
        return ffi.string(sqlite_api.value_text(value))
    end,
    [SQLITE.NULL] = function ()
        return NULL
    end,
    [SQLITE.FLOAT] = function (value)
        return tonumber(sqlite_api.value_double(value))
    end,
    [SQLITE.BLOB] = function (value)
        local ptr = sqlite_api.value_blob(value);
        local size = sqlite_api.value_bytes(value);
        local buffer = size > 0 and ffi.new("uint8_t[?]", size) or NULL
        ffi.copy(buffer, ptr, size)

        return {data = buffer, size = size}
    end,
}

local sqlite_to_l = function(value)
    local value_type = tonumber(sqlite_api.value_type(value))
    local handler = map_sqlite_to_lj[value_type]
    local ret_value = handler(value)
    return ret_value
end

local api_get_args = function(context, argc, argv)
    local tmp = {}
    for i = 0, argc -1 do
        tmp[i + 1] = sqlite_to_l(argv[i])
    end
    return unpack(tmp)
end

local make_blob = function (array)
    array = array or {}
    local size = #array
    local data = size > 0 and ffi.new("uint8_t[?]", size) or NULL
    for i = 0, size - 1 do
        data[i] = array[i + 1]
    end
    return {data = data, size = size}
end
public_env.make_blob = make_blob

local return_handlers = {
    cdata = function(context, value)
        if ffi.istype(value, int_t) or ffi.istype(value, int64_t) then
            sqlite_api.result_int64(context, ffi.cast('int64_t', value))
        elseif ffi.istype(value, uint64_t) then
            sqlite_api.result_int64(context, ffi.cast('int64_t', value))
        elseif ffi.istype(value, float_t) or ffi.istype(value, double_t) then
            sqlite_api.result_double(context, value)
        elseif value == NULL then
            sqlite_api.result_null(context)
        else
            local msg = "api_function_return_any: unsupported type " .. tostring(ffi.typeof(value)) .. " value " .. tostring(value)
            sqlite_api.result_error(context, msg, -1)
        end
    end,

    number = function(context, value)
        if value ~= math.huge and value ~= -math.huge and value == math.floor(value) then
            sqlite_api.result_int64(context, value)
        else
            sqlite_api.result_double(context, value)
        end
    end,

    string = function(context, value)
        sqlite_api.result_text(context, value, -1, SQLITE.TRANSIENT)
    end,

    boolean = function(context, value)
        sqlite_api.result_int(context, value and 1 or 0)
    end
}

local api_function_return_any = function(context, value)
    local value_type = type(value)
    local handler = return_handlers[value_type]

    if handler then
        handler(context, value)
    elseif value == NULL then
        sqlite_api.result_null(context)
    elseif is_error(value) then
        sqlite_api.result_error(context, LJError.get(), -1)
    elseif value_type == 'table' then
        if value.size == 0 then
            sqlite_api.result_zeroblob(context, 0)
        elseif type(value.data) ~= 'nil' and value.size ~= nil then
            sqlite_api.result_blob(context, value.data, value.size, SQLITE.TRANSIENT)
        else
            local msg = "api_function_return_any: unsupported type " .. tostring(type(value)) .. " value " .. tostring(value)
            sqlite_api.result_error(context, msg, -1)
        end
    else
        local msg = "api_function_return_any: unsupported type " .. value_type .. " value " .. tostring(value)
        sqlite_api.result_error(context, msg, -1)
    end
end

local bind_handlers = {
    cdata = function(stmt, index, value)
        if ffi.istype(value, int_t) or ffi.istype(value, int64_t) then
            sqlite_api.bind_int64(stmt, index, value)
        elseif ffi.istype(value, uint64_t) then
            sqlite_api.bind_int64(stmt, index, ffi.cast('int64_t', value))
        elseif ffi.istype(value, float_t) or ffi.istype(value, double_t) then
            sqlite_api.bind_double(stmt, index, value)
        elseif value == NULL then
            sqlite_api.bind_null(stmt, index)
        else
            local msg = "api_bind_any: unsupported type " .. tostring(ffi.typeof(value)) .. " value " .. tostring(value)
            error(msg)
        end
    end,

    number = function(stmt, index, value)
        if value ~= math.huge and value ~= -math.huge and value == math.floor(value) then
            sqlite_api.bind_int64(stmt, index, value)
        else
            sqlite_api.bind_double(stmt, index, value)
        end
    end,

    string = function(stmt, index, value)
        sqlite_api.bind_text(stmt, index, value, -1, SQLITE.TRANSIENT)
    end,

    boolean = function(stmt, index, value)
        sqlite_api.bind_int(stmt, index, value and 1 or 0)
    end
}

local api_bind_any = function(stmt, index, value)
    local value_type = type(value)
    local handler = bind_handlers[value_type]

    if handler then
        handler(stmt, index, value)
    elseif value == NULL then
        sqlite_api.bind_null(stmt, index)
    elseif is_error(value) then
        error(LJError.get())
    elseif value_type == 'table' then
        if value.size == 0 then
            sqlite_api.bind_zeroblob(stmt, index, 0)
        elseif type(value.data) ~= 'nil' and value.size ~= nil then
            sqlite_api.bind_blob(stmt, index, value.data, value.size, SQLITE.TRANSIENT)
        else
            local msg = "api_bind_any: unsupported type " .. tostring(type(value)) .. " value " .. tostring(value)
            error(msg)
        end
    else
        local msg = "api_bind_any: unsupported type " .. value_type .. " value " .. tostring(value)
        error(msg)
    end
end

local validate_bind_value = function(value)
    local value_type = type(value)
    if bind_handlers[value_type] then
        if value_type == 'cdata' then
            if ffi.istype(value, int_t) or ffi.istype(value, int64_t) then
                return true
            elseif ffi.istype(value, uint64_t) then
                return true
            elseif ffi.istype(value, float_t) or ffi.istype(value, double_t) then
                return true
            elseif value == NULL then
                return true
            else
                return false, "api_bind_any: unsupported type " .. tostring(ffi.typeof(value)) .. " value " .. tostring(value)
            end
        elseif value_type == 'table' then
            if value.size == 0 then
                return true
            elseif type(value.data) ~= 'nil' and value.size ~= nil then
                return true
            end
            return false, "api_bind_any: unsupported type " .. tostring(type(value)) .. " value " .. tostring(value)
        end
        return true
    elseif value == NULL then
        return true
    elseif is_error(value) then
        return false, LJError.get()
    elseif value_type == 'table' then
        if value.size == 0 then
            return true
        elseif type(value.data) ~= 'nil' and value.size ~= nil then
            return true
        end
        return false, "api_bind_any: unsupported type " .. tostring(type(value)) .. " value " .. tostring(value)
    else
        return false, "api_bind_any: unsupported type " .. value_type .. " value " .. tostring(value)
    end
end

local resolve_bind_keys = function(stmt_p)
    local parameter_count = sqlite_api.bind_parameter_count(stmt_p)
    local bind_keys = {}
    for k = 1, parameter_count do
        local c_param_name = sqlite_api.bind_parameter_name(stmt_p, k)
        if c_param_name == nil then
            bind_keys[k] = k
        else
            bind_keys[k] = ffi.string(c_param_name):sub(2) -- remove prefix
        end
    end
    return parameter_count, bind_keys
end

local resolve_bind_value = function(params, key, index)
    if type(key) == "number" then
        return params[key]
    end
    local value = params[key]
    if value == nil then
        value = params[index]
    end
    return value
end


local api_create_function_v2 = function(zFunctionName, nArg, eTextRep, pApp, xFunc, xStep, xFinal, xDestroy)
    local rc = sqlite_api.create_function_v2(sqlite_db, zFunctionName, nArg, eTextRep, pApp,
        wrap_csafe(xFunc),
        wrap_csafe(xStep),
        wrap_csafe(xFinal),
        wrap_csafe(xDestroy)
    );

    if (rc ~= SQLITE.OK) then
        return false, ffi.string(sqlite_api.errmsg(sqlite_db)), rc
    end
    return true
end

local api_create_function_v2_c = function(zFunctionName, nArg, eTextRep, pApp, xFunc, xStep, xFinal, xDestroy)
    local rc = sqlite_api.create_function_v2(sqlite_db, zFunctionName, nArg, eTextRep, pApp,
        (xFunc),
        (xStep),
        (xFinal),
        (xDestroy)
    );

    if (rc ~= SQLITE.OK) then
        return false, ffi.string(sqlite_api.errmsg(sqlite_db)), rc
    end
    return true, nil, nil
end

local make_int = function(name, value)
    local ok = api_create_function_v2_c(
                   name,
                   0,
                   bor(SQLITE.DETERMINISTIC, SQLITE.INNOCUOUS) ,
                   ffi.cast('void*', value),
                   plugin_init_data.sqlite_return_int_cb, nil, nil, nil)
    return ok
end
public_env.make_int = make_int

local make_str = function(name, value)
    if type(value) ~= "string" then
        return false, "make_str: value must be a string", SQLITE.MISUSE
    end

    local size = #value + 1
    local str_ptr = sqlite_api.malloc(size)
    if str_ptr == nil then
        return false, "make_str: out of memory", SQLITE.NOMEM
    end

    ffi.copy(str_ptr, value, #value)
    ffi.cast("char*", str_ptr)[#value] = 0

    local ok, err, errcode = api_create_function_v2_c(
        name,
        0,
        bor(SQLITE.DETERMINISTIC, SQLITE.INNOCUOUS),
        str_ptr,
        plugin_init_data.sqlite_return_text_cb, nil, nil, plugin_init_data.sqlite_free_cb
    )

    if not ok then
        sqlite_api.free(str_ptr)
        return ok, err, errcode
    end

    return ok, err, errcode
end
public_env.make_str = make_str

local exec_lua = function (code_text, ...)
    local fn_env = {arg = {...}}
    setmetatable(fn_env, public_env_mt)
    local fn, err = loadstring(code_text, "temporary_function", "t", fn_env)
    if not fn then
        local msg = "Create temporary function failed \n" .. tostring(err)
        return error(msg)
    end
    return fn()
end


wrap_csafe = (function ()
    local wrapped_functions = {}
    return function (fn)
        if fn then
            if not wrapped_functions[fn] then
                wrapped_functions[fn] = function (context, argc, argv)
                    local status, result = xpcall(fn, error_xcall, context, argc, argv)
                    if not status then
                        local msg = tostring(result.message) .. '\n' .. result.detail
                        api_function_return_any(context, LJError.set(msg))
                    end
                end
            end

            return wrapped_functions[fn]
        end
        return fn
    end
end)()

wrap_csafe_cs = (function ()
    local wrapped_functions = {}
    return function (fn)
        if fn then
            if not wrapped_functions[fn] then
                wrapped_functions[fn] = function (context, argc, argv)
                    local outer_statements = unfinalized_statements
                    unfinalized_statements = setmetatable({}, { __mode = "k" })
                    local status, result = xpcall(fn, error_xcall, context, argc, argv)
                    local error_msg = nil
                    if not status then
                        error_msg = tostring(result.message) .. '\n' .. result.detail
                    end
                    local close_error = close_unfinalized()
                    if close_error and error_msg then
                        error_msg = error_msg .. '\n' .. tostring(close_error)
                    elseif close_error then
                        -- Function may already have produced a result for this context.
                        -- Do not call result_* again; report cleanup failure as diagnostic.
                        io.stderr:write("sqlite_plugin_lj: cleanup warning: " .. tostring(close_error) .. "\n")
                    end
                    if error_msg then
                        api_function_return_any(context, LJError.set(error_msg))
                    end
                    unfinalized_statements = outer_statements
                end
            end

            return wrapped_functions[fn]
        end
        return fn
    end
end)()


local get_fn_context = function(index)
    return plugin_init_data.getFunctionContext(index)
end

local allocate_function_context = function(ctx)
    local fn_context = tonumber(plugin_init_data.pushFunctionContext(ctx))
    if not fn_context or fn_context <= 0 then
        return error("function context storage limit exceeded")
    end
    return fn_context
end

local caller_fn = function(context, argc, argv)
    local fn_context = ffi.cast('int64_t', sqlite_api.user_data(context))
    local fc = get_fn_context(fn_context)
    local saved_ref = fc and fc.udata or nil

    local fn = function_refs.get(saved_ref)
    local result = fn(api_get_args(context, argc, argv))

    api_function_return_any(context, result)
end

local create_function = function(name, fn, argc)
    if type(fn) ~= 'function' then
        return error('create_function: "fn" is not a function')
    end

    local ref = function_refs.new_key(fn)
    --local callback_fn = wrap_csafe(caller_fn_cs)
    local callback_fn = wrap_csafe_cs(caller_fn)

    local fn_context = allocate_function_context(ffi.new("FunctionContext", {fn_ptr = callback_fn, udata = ref, allowed_nested = false}))

    local status, err, errcode = api_create_function_v2_c(name, argc, SQLITE.UTF8, ffi.cast('void*', fn_context) , plugin_init_data.cb_context_fn, nil, nil, nil)
    if not status then
        return error(err)
    end

end
public_env.create_function = create_function

local caller_chk = function(context, argc, argv)
    local outer_statements = unfinalized_statements
    unfinalized_statements = setmetatable({}, { __mode = "k" })

    local saved_ref = ffi.cast('int64_t', sqlite_api.user_data(context))

    local fn = function_refs.get(saved_ref)
    local chk_env = {}
    setmetatable(chk_env, public_env_mt)
    chk_env['arg'] = {api_get_args(context, argc, argv)}
    chk_env['ctx'] = context
    setfenv(fn, chk_env)

    local result = fn()
    api_function_return_any(context, result)
    local close_error = close_unfinalized()
    if close_error then
        io.stderr:write("sqlite_plugin_lj: cleanup warning: " .. tostring(close_error) .. "\n")
    end
    unfinalized_statements = outer_statements
end

local create_function_chk = function(name, code_text, argc, wrapper_function)
    if code_text == nil then return end

    local fn_env = {}
    setmetatable(fn_env, public_env_mt)
    local fn, err = loadstring(ffi.string(code_text), name, "t", fn_env)
    if not fn then
        local msg = 'Create failed ['.. name .. ']\n' .. tostring(err)
        return error(msg)
    end

    local ref = function_refs.new_key(fn)

    local status, err, errcode = api_create_function_v2(name, argc, SQLITE.UTF8, ffi.cast('void*', ref) , wrapper_function, nil, nil, nil)
    if not status then
        return error(err)
    end
    return fn
end

local make_fn = function(name, code_text, argc)

    local create_fn = function(name, argc, fid)
        local status, err, errcode = api_create_function_v2_c(name, argc, SQLITE.UTF8, ffi.cast('void*', fid) , plugin_init_data.callback, nil, nil, nil)
        if not status then
            return error(err)
        end
    end

    argc = argc or -1

    local fid, err = function_refs_text.new_key(name, code_text)
    if not fid then
        return err
    end

    local status, err = xpcall(create_fn, error_xcall, name, argc, fid)

    if not status then
        local msg = 'Create failed ['.. name .. ']\n' .. tostring(err.message) .. '\n' .. err.detail
        return msg
    end


end
public_env.make_fn = make_fn

local make_chk = function (name, chunk_text, argc)
    argc = argc or -1
    local status, err = xpcall(create_function_chk, error_xcall, name, chunk_text, argc, caller_chk)
    if not status then
        local msg = 'Create failed ['.. name .. ']\n' .. tostring(err.message) .. '\n' .. err.detail
        return msg
    end
end
public_env.make_chk = make_chk

local make_function_agg_chk = function(fname, finit, fstep, ffinal, fargc)
    fargc = fargc or -1
    return create_function_agg_chk(tostring(fname), tostring(finit), tostring(fstep), tostring(ffinal), fargc)
end
public_env.make_function_agg_chk = make_function_agg_chk

-- Aggregate helper functions
local get_agg_storage = function(context)
    return ffi.cast('int*', sqlite_api.aggregate_context(context, ffi.sizeof('int')))
end

local get_fn_udata = function(context)
    local fn_context = ffi.cast('int64_t', sqlite_api.user_data(context))
    local fc = get_fn_context(fn_context)
    return fc and fc.udata or nil
end

local resume_or_raise = function(agg_fn, phase, ...)
    local ok, result = coroutine.resume(agg_fn, ...)
    if not ok then
        error("aggregate coroutine " .. phase .. " failed: " .. tostring(result))
    end
    return result
end

-- Ensure coroutine is initialized, returns the coroutine
local ensure_coro_init = function(context, storage)
    if storage[0] == 0 then
        local coro_fn = function_refs_text.get(get_fn_udata(context))
        local agg_fn = coroutine.create(coro_fn)
        storage[0] = agg_function_refs.new_key(agg_fn)
        resume_or_raise(agg_fn, "init")
    end
    return agg_function_refs.get(storage[0])
end

local agg_cb_coro_text = function(context, argc, argv)
    local storage = get_agg_storage(context)
    if storage == nil then
        return sqlite_api.result_error_nomem(context)
    end
    local agg_fn = ensure_coro_init(context, storage)
    resume_or_raise(agg_fn, "step", true, api_get_args(context, argc, argv))
end

local agg_final_coro_text = function(context)
    local storage = get_agg_storage(context)
    local agg_fn = ensure_coro_init(context, storage)
    agg_function_refs.remove(storage[0])
    local result = resume_or_raise(agg_fn, "final", false)
    api_function_return_any(context, result)
end

local create_function_agg_coro_text = function(name, code_text, argc)
    local fid, err = function_refs_text.new_key(name, code_text)
    if not fid then
        return err
    end

    local fn_context = allocate_function_context(
        ffi.new("FunctionContext", {
            fn_ptr = nil,
            fn_step_ptr = wrap_csafe_cs(agg_cb_coro_text),
            fn_final_ptr = wrap_csafe_cs(agg_final_coro_text),
            fn_destroy_ptr = nil,
            udata = fid,
            allowed_nested = true
        }))

    local status, err, errcode = api_create_function_v2_c(name, argc, SQLITE.UTF8, ffi.cast('void*', fn_context),
        nil, plugin_init_data.cb_context_step_fn, plugin_init_data.cb_context_final_fn, nil)
    if not status then
        return error(err)
    end
end
public_env.create_function_agg_coro_text = create_function_agg_coro_text

-- Ensure chunk env is initialized, returns the env
local ensure_chk_init = function(context, storage)
    if storage[0] == 0 then
        local fn = agg_chk_refs_text.get(get_fn_udata(context))
        local chk_env = setmetatable({arg = {}}, public_env_mt)
        storage[0] = agg_function_refs.new_key(chk_env)
        setfenv(fn.init, chk_env)
        fn.init()
    end
    return agg_function_refs.get(storage[0])
end

local agg_cb_chk_text = function(context, argc, argv)
    local storage = get_agg_storage(context)
    if storage == nil then
        return sqlite_api.result_error_nomem(context)
    end

    local chk_env = ensure_chk_init(context, storage)
    chk_env['arg'] = {api_get_args(context, argc, argv)}

    local fn = agg_chk_refs_text.get(get_fn_udata(context))
    setfenv(fn.step, chk_env)
    fn.step()
end

local agg_final_chk_text = function(context)
    local storage = get_agg_storage(context)
    local chk_env = ensure_chk_init(context, storage)
    agg_function_refs.remove(storage[0])

    local fn = agg_chk_refs_text.get(get_fn_udata(context))
    setfenv(fn.final, chk_env)
    local result = fn.final()
    api_function_return_any(context, result)
end


create_function_agg_chk = function(name, init, step, final, argc)
    argc = argc or -1

    local fid, err = agg_chk_refs_text.new_key(name, init, step, final)
    if not fid then
        return error(err)
    end

    local fn_context = allocate_function_context(
        ffi.new("FunctionContext", {
            fn_ptr = nil,
            fn_step_ptr = wrap_csafe_cs(agg_cb_chk_text),
            fn_final_ptr = wrap_csafe_cs(agg_final_chk_text),
            fn_destroy_ptr = nil,
            udata = fid,
            allowed_nested = true
        }))

    local status, err, errcode = api_create_function_v2_c(
        name, argc, SQLITE.UTF8, ffi.cast('void*', fn_context),
        nil,
        plugin_init_data.cb_context_step_fn,
        plugin_init_data.cb_context_final_fn,
        nil)
    if not status then
        return error(err)
    end
end
public_env.create_function_agg_chk = create_function_agg_chk

-- Window function callbacks (use direct udata, not FunctionContext)
local get_udata_direct = function(context)
    return tonumber(ffi.cast('int64_t', sqlite_api.user_data(context)))
end

local ensure_chk_init_window = function(context, storage)
    if storage[0] == 0 then
        local fn = agg_chk_refs_text.get(get_udata_direct(context))
        local chk_env = setmetatable({arg = {}}, public_env_mt)
        storage[0] = agg_function_refs.new_key(chk_env)
        setfenv(fn.init, chk_env)
        fn.init()
    end
    return agg_function_refs.get(storage[0])
end

local agg_cb_chk_window = function(context, argc, argv)
    local storage = get_agg_storage(context)
    if storage == nil then
        return sqlite_api.result_error_nomem(context)
    end

    local chk_env = ensure_chk_init_window(context, storage)
    chk_env['arg'] = {api_get_args(context, argc, argv)}

    local fn = agg_chk_refs_text.get(get_udata_direct(context))
    setfenv(fn.step, chk_env)
    fn.step()
end

local agg_final_chk_window = function(context)
    local storage = get_agg_storage(context)
    local chk_env = ensure_chk_init_window(context, storage)
    agg_function_refs.remove(storage[0])

    local fn = agg_chk_refs_text.get(get_udata_direct(context))
    setfenv(fn.final, chk_env)
    local result = fn.final()
    api_function_return_any(context, result)
end

local agg_value_chk_window = function(context)
    local storage = get_agg_storage(context)
    local chk_env = ensure_chk_init_window(context, storage)

    local fn = agg_chk_refs_text.get(get_udata_direct(context))
    setfenv(fn.final, chk_env)
    local result = fn.final()
    api_function_return_any(context, result)
end

local agg_inverse_chk_window = function(context, argc, argv)
    local storage = get_agg_storage(context)
    local chk_env = ensure_chk_init_window(context, storage)

    local fn = agg_chk_refs_text.get(get_udata_direct(context))
    if not fn.inverse then
        return sqlite_api.result_error(context, "sliding windows not supported for this aggregate", -1)
    end
    chk_env['arg'] = {api_get_args(context, argc, argv)}
    setfenv(fn.inverse, chk_env)
    fn.inverse()
end

local window_cb_anchors = nil
local get_window_cb_anchors = function()
    if window_cb_anchors ~= nil then
        return window_cb_anchors
    end
    window_cb_anchors = {
        step = ffi.cast(
            'void (*)(sqlite3_context*, int, sqlite3_value**)',
            wrap_csafe_cs(agg_cb_chk_window)
        ),
        final = ffi.cast(
            'void (*)(sqlite3_context*)',
            wrap_csafe_cs(agg_final_chk_window)
        ),
        value = ffi.cast(
            'void (*)(sqlite3_context*)',
            wrap_csafe_cs(agg_value_chk_window)
        ),
        inverse = ffi.cast(
            'void (*)(sqlite3_context*, int, sqlite3_value**)',
            wrap_csafe_cs(agg_inverse_chk_window)
        ),
    }
    return window_cb_anchors
end

-- create_function_agg_chk_window(name, init, step, final, argc) - no sliding window support
-- create_function_agg_chk_window(name, init, step, inverse, final, argc) - full sliding window support
local create_function_agg_chk_window = function(name, init, step, arg4, arg5, arg6)
    local inverse, final, argc

    if type(arg5) == "number" or arg5 == nil then
        -- 4 string args: init, step, final, argc (no inverse)
        inverse = nil
        final = arg4
        argc = arg5 or -1
    else
        -- 5 string args: init, step, inverse, final, argc
        inverse = arg4
        final = arg5
        argc = arg6 or -1
    end

    local fid, err = agg_chk_refs_text.new_key(name, init, step, final, inverse)
    if not fid then
        return error(err)
    end

    local cbs = get_window_cb_anchors()
    local rc = sqlite_api.create_window_function(
        sqlite_db, name, argc, SQLITE.UTF8, ffi.cast('void*', fid),
        cbs.step,
        cbs.final,
        cbs.value,
        cbs.inverse,
        nil)
    if rc ~= SQLITE.OK then
        return error(ffi.string(sqlite_api.errmsg(sqlite_db)))
    end
end
public_env.create_function_agg_chk_window = create_function_agg_chk_window

local internal_sql_builtin_specs = {
    make_fn = { fn = make_fn, argc = -1 },
    make_int = { fn = make_int, argc = 2 },
    make_str = { fn = make_str, argc = 2 },
    make_chk = { fn = make_chk, argc = 3 },
    make_function_agg_chk = { fn = make_function_agg_chk, argc = -1 },
    create_function_agg_coro_text = { fn = create_function_agg_coro_text, argc = -1 },
    create_function_agg_chk = { fn = create_function_agg_chk, argc = -1 },
    create_function_agg_chk_window = { fn = create_function_agg_chk_window, argc = -1 },
}

local register_internal_function = function(source_name, sql_name)
    if type(source_name) ~= "string" or source_name == "" then
        return error("register_internal_function: source_name must be a non-empty string")
    end

    local spec = internal_sql_builtin_specs[source_name]
    if not spec then
        return error("register_internal_function: unknown source_name [" .. source_name .. "]")
    end

    sql_name = sql_name or source_name
    if type(sql_name) ~= "string" or sql_name == "" then
        return error("register_internal_function: sql_name must be a non-empty string")
    end

    return create_function(sql_name, spec.fn, spec.argc)
end
public_env.register_internal_function = register_internal_function

local register_internal_functions = function(name_map)
    if name_map == nil then
        name_map = {}
    end
    if type(name_map) ~= "table" then
        return error("register_internal_functions: name_map must be a table")
    end

    for source_name, spec in pairs(internal_sql_builtin_specs) do
        local mapped_name = name_map[source_name]
        if mapped_name ~= false then
            if mapped_name == nil then
                mapped_name = source_name
            end
            create_function(mapped_name, spec.fn, spec.argc)
        end
    end
end
public_env.register_internal_functions = register_internal_functions

run_sql = function (sql)
    sql = tostring(sql)
    local rc = sqlite_api.exec(sqlite_db, sql, nil, nil, nil)
    if rc ~= SQLITE.OK then
        local msg = ffi.string(sqlite_api.errmsg(sqlite_db))
        return error("Failed to execute query: \n[" .. sql .. "] \n"  .. msg)
    end
end
public_env.run_sql = run_sql

fetch_all = function (...)
    local rows = {}
    local n = 0
    for row in nrows(...) do
        n = n + 1
        rows[n] = row
    end
    return rows
end
public_env.fetch_all = fetch_all

local fetchOneStatement = function (sql, params)
    local stmt = ffi.new("sqlite3_stmt*[?]", 1)
    local columns_count
    local step_rc

    local self = {}
    self.get_columns = function ()
        local columns = {}
        for i = 0, columns_count - 1 do
            columns[i] = ffi.string(sqlite_api.column_name(stmt[0], i))
        end
        return columns
    end

    self.to_table = function ()
        local row = {}
        local cols = self.get_columns()
        for i = 0, columns_count - 1 do
            local value = sqlite_to_l(sqlite_api.column_value(stmt[0], i))
            row[cols[i]] = value
        end
        return row
    end

    sql = tostring(sql)
    local rc = sqlite_api.prepare_v2(sqlite_db, sql, -1, stmt, nil)
    if rc ~= SQLITE.OK then
        error("Failed to prepare query \n[" .. sql.. "]" )
    end

    local result = nil
    local error_text
    if type(params) == "table" then
        local bind_error
        local parameter_count, bind_keys = resolve_bind_keys(stmt[0])
        for k = 1, parameter_count do
            local key = bind_keys[k]
            local value = resolve_bind_value(params, key, k)
            local can_bind, bind_err = validate_bind_value(value)
            if not can_bind then
                bind_error = bind_err
                break
            end
            api_bind_any(stmt[0], k, value)
        end

        if bind_error then
            safe_finalize_stmt(stmt)
            return error(bind_error)
        end
    end
    columns_count = sqlite_api.column_count(stmt[0])
    step_rc = sqlite_api.step(stmt[0])
    if step_rc == SQLITE.ROW then
        result = self.to_table()
    elseif step_rc ~= SQLITE.DONE then
        error_text = 'fetch one failed: \n\tmsg: ' .. ffi.string(sqlite_api.errmsg(sqlite_db)) .. '\n\tsql: ' .. sql
    end

    local finalize_rc = safe_finalize_stmt(stmt)
    if finalize_rc ~= SQLITE.OK and not error_text then
        error('fetch one finalize failed: \n\tsql: ' .. sql)
    end
    if error_text then
        return error(error_text)
    end
    return result
end


local Statement = function (sql, params)
    local self = {}

    local stmt
    local columns_count
    local columns
    local step_rc

    sql = tostring(sql)
    stmt = ffi.new("sqlite3_stmt*[?]", 1)

    local rc = sqlite_api.prepare_v2(sqlite_db, sql, -1, stmt, nil)
    if rc ~= SQLITE.OK then
        error("Failed to prepare query \n[" .. sql.. "]" )
    end

    unfinalized_statements[stmt] = {isopen = true, sql = sql}
    if type(params) == "table" then
        local parameter_count, bind_keys = resolve_bind_keys(stmt[0])
        for k = 1, parameter_count do
            local key = bind_keys[k]
            local value = resolve_bind_value(params, key, k)
            api_bind_any(stmt[0], k, value)
        end
    end

    columns_count = sqlite_api.column_count(stmt[0])
    local finalized = false

    self.get_columns = function ()
        if not columns then
            columns = {}
            for i = 0, columns_count - 1 do
                columns[i] = ffi.string(sqlite_api.column_name(stmt[0], i))
            end
        end
        return columns
    end

    self.to_array = function()
        local row = {}
        local out = 1
           
        for i = 0, columns_count - 1 do
            local value = sqlite_to_l(sqlite_api.column_value(stmt[0], i))
            row[out] = value
            out = out + 1
        end
        return row
    end

    self.to_table = function ()
        local row = {}
        local cols = self.get_columns()

        for i = 0, columns_count - 1 do
            local value = sqlite_to_l(sqlite_api.column_value(stmt[0], i))
            row[cols[i]] =  value
        end
        return row
    end

    self.finalize_done = function ()
        if finalized then
            return
        end
        finalized = true
        local state = unfinalized_statements[stmt]
        local error_text
        if step_rc ~= SQLITE.DONE then
            error_text = 'iterate sql failed: \n\tmsg: ' .. ffi.string(sqlite_api.errmsg(sqlite_db)) .. '\n\tsql: ' .. sql
        end
        if state ~= nil then
            state.isopen = false
        end
        unfinalized_statements[stmt] = nil
        step_rc = safe_finalize_stmt(stmt)

        -- if statement failed then closing it also returns error
        if step_rc ~= SQLITE.OK and not error_text then
            error('finalize last failed: '.. sql )
        end
        if error_text then
            error(error_text)
        end
    end

    self.step = function ()
        step_rc = sqlite_api.step(stmt[0])

        if step_rc ~= SQLITE.ROW then
            -- auto close when done
            self.finalize_done()
        end

        return step_rc
    end

    return self

end

fetch_first = function (sql, params)
    return fetchOneStatement(sql, params)
end
public_env.fetch_first = fetch_first

nrows = function (sql, params)
    local stmt = Statement(sql, params)

    return function ()
        if stmt.step() == SQLITE.ROW then
            return stmt.to_table()
        end

      end
end
public_env.nrows = nrows

local rows = function (sql, params)
    local stmt = Statement(sql, params)

    return function ()
        if stmt.step() == SQLITE.ROW then
            return stmt.to_array()
        end

      end
end
public_env.rows = rows

local urows = function (sql, params)
    local stmt = Statement(sql, params)
    
    return function ()
        if stmt.step() == SQLITE.ROW then
            return unpack(stmt.to_array())
        end

    end
end
public_env.urows = urows

--local sqlite3_module_test = ffi.cast('sqlite3_module *', api.malloc(ffi.sizeof(sqlite3_module_t)))--sqlite3_module_t{}
local connect_make_vtable = function (db, pAux, argc, argv, ppVTab, pzErrUnused)
    local shared_key_ptr = ffi.cast('int64_t*', pAux)
    local shared_key = shared_key_ptr ~= nil and tonumber(shared_key_ptr[0]) or nil
    if not shared_key then
        if pzErrUnused ~= nil then
            pzErrUnused[0] = sqlite_api.mprintf("lua_vtab: module context missing")
        end
        return SQLITE.ERROR
    end
    local vtab_data = shared_vtab_data.get(shared_key)
    if not vtab_data or not vtab_data.xtable_text then
        if pzErrUnused ~= nil then
            pzErrUnused[0] = sqlite_api.mprintf("lua_vtab: shared metadata missing")
        end
        return SQLITE.ERROR
    end
    local xtable_text = vtab_data.xtable_text

    local rc = sqlite_api.declare_vtab(db, xtable_text) --"CREATE TABLE x(...)";
    if rc == SQLITE.OK then
        local pTable = ffi.cast('lua_vtab*', sqlite_api.malloc(ffi.sizeof('lua_vtab')))

        if( pTable==nil ) then
            return SQLITE.NOMEM
        end

        pTable.base.pModule = nil;
        pTable.base.nRef = 0
        pTable.base.zErrMsg = nil
        pTable.index = shared_key  -- store shared_key for vtable_vm to access
        pTable.conn_slot = plugin_init_data.conn_slot

        ppVTab[0] = ffi.cast('sqlite3_vtab*', pTable)
    end
    return rc
end

local lua_vtable_module = sqlite3_module_t{
    iVersion = 1,
    xCreate = connect_make_vtable,
    xDestroy = function (pVtab)
        local pTable = ffi.cast('lua_vtab*', pVtab)
        local shared_key = tonumber(pTable.index)
        shared_vtab_data.remove(shared_key)
        sqlite_api.free(pVtab)
        return SQLITE.OK
    end,

    xConnect = connect_make_vtable,

    --sqlite3_vtab *pVtab
    xDisconnect = function(pVtab)
        -- Don't remove from shared_vtab_data cache - data may be reused on next query
        sqlite_api.free(pVtab);
        return SQLITE.OK;
    end ,

    xBestIndex = function (pVTab, pIdxInfo)
        return SQLITE.OK;
    end,

    -- Cursor callbacks are set dynamically in create_vtable_functions
    -- to use C wrappers that route through vtable_vm
    xOpen = nil,
    xClose = nil,
    xFilter = nil,
    xNext = nil,
    xEof = nil,
    xColumn = nil,
    xRowid = nil
}

local quote_ident_sqlite = function(name)
    if type(name) ~= "string" or name == "" then
        return error("identifier must be a non-empty string")
    end
    local escaped = sqlite_api.mprintf("%w", name)
    if escaped == nil then
        return error("identifier quote failed: out of memory")
    end
    local quoted = '"' .. ffi.string(escaped) .. '"'
    sqlite_api.free(escaped)
    return quoted
end

local normalize_make_vtable_input = function(table_name, input)
    if type(table_name) ~= "string" or table_name == "" then
        return error("make_vtable: table_name must be a non-empty string")
    end
    if type(input) ~= "table" then
        return error("make_vtable: input must be a table")
    end
    if type(input.columns) ~= "table" or #input.columns == 0 then
        return error("make_vtable: columns must be a non-empty array")
    end
    local rows = input.rows
    if rows == nil then
        rows = {}
    end
    if type(rows) ~= "table" then
        return error("make_vtable: rows must be a table")
    end

    local seen = {}
    for i, col in ipairs(input.columns) do
        if type(col) ~= "string" then
            return error("make_vtable: column names must be non-empty strings")
        end
        if col == "" then
            return error("identifier must be a non-empty string")
        end
        local normalized = string.lower(col)
        if seen[normalized] then
            return error("make_vtable: duplicate column name [" .. col .. "]")
        end
        seen[normalized] = true
    end

    return {
        columns = input.columns,
        rows = rows
    }
end

local make_vtable = function(table_name, input)
    local normalized_input = normalize_make_vtable_input(table_name, input)

    local quoted_columns = {}
    for i, col in ipairs(normalized_input.columns) do
        quoted_columns[i] = quote_ident_sqlite(col)
    end
    local column_names = table.concat(quoted_columns, ', ')
    local xtable_text = string.format("CREATE TABLE x(%s)", column_names)
    local quoted_table_name = quote_ident_sqlite(table_name)

    -- Store vtab metadata in shared memory so vtable_vm can access it
    local key = shared_vtab_data.new_key({
        xtable_text = xtable_text,
        input = normalized_input,  -- normalized input data in shared storage
        module_type = "make_vtable"
    })

    local module_aux = make_vtable_modules[table_name]
    if module_aux == nil then
        module_aux = ffi.new("int64_t[1]", key)
        local rc = sqlite_api.create_module_v2(sqlite_db, table_name, lua_vtable_module, ffi.cast('void*', module_aux), nil);
        if rc ~= SQLITE.OK then
            -- Shared storage is append-only; clear local cache entry at least.
            shared_vtab_data.remove(key)
            return error("setup module failed")
        end
        make_vtable_modules[table_name] = module_aux
    else
        module_aux[0] = key
    end

    local create_vtable_text = "CREATE VIRTUAL TABLE TEMP." .. quoted_table_name .. " USING " .. quoted_table_name .. "();"
    run_sql(create_vtable_text);
end
public_env.make_vtable = make_vtable

local lua_vtable_module2 = sqlite3_module_t{
    iVersion = 0,

    xConnect = function (db, pAux, argc, argv, ppVTab, pzErrUnused)
        local shared_key = tonumber(ffi.cast('int64_t', pAux))
        local vtab_data = shared_vtab_data.get(shared_key)
        if not vtab_data or not vtab_data.xtable_text then
            if pzErrUnused ~= nil then
                pzErrUnused[0] = sqlite_api.mprintf("lua_vtab: shared metadata missing")
            end
            return SQLITE.ERROR
        end
        local xtable_text = vtab_data.xtable_text

        local rc = sqlite_api.declare_vtab(db, xtable_text) --"CREATE TABLE x(...)";
        if rc == SQLITE.OK then
            local pTable = ffi.cast('lua_vtab*', sqlite_api.malloc(ffi.sizeof('lua_vtab')))

            if( pTable==nil ) then
                return SQLITE.NOMEM
            end

            pTable.base.pModule = nil;
            pTable.base.nRef = 0
            pTable.base.zErrMsg = nil
            pTable.index = shared_key  -- store shared_key for vtable_vm to access
            pTable.conn_slot = plugin_init_data.conn_slot

            ppVTab[0] = ffi.cast('sqlite3_vtab*', pTable)

            sqlite_api.vtab_config(db, SQLITE.VTAB_INNOCUOUS);
        end

        return rc

    end,

    xDisconnect = function(pVTab)
        -- Don't remove from shared_vtab_data cache - data may be reused on next query
        sqlite_api.free(pVTab);
        return SQLITE.OK;
    end,

    xDestroy = function(pVTab)
        local pTable = ffi.cast('lua_vtab*', pVTab)
        local shared_key = tonumber(pTable.index)
        shared_vtab_data.remove(shared_key)
        sqlite_api.free(pVTab)
        return SQLITE.OK
    end,

    xBestIndex = function (pVTab, pIdxInfo)
        local pTable = ffi.cast('lua_vtab*', pVTab)
        local shared_key = tonumber(pTable.index)
        local vtab_data = shared_vtab_data.get(shared_key)
        if not vtab_data then
            pVTab.zErrMsg = sqlite_api.mprintf("lua_vtab: shared metadata missing")
            return SQLITE.ERROR
        end

        local pConstraint = pIdxInfo.aConstraint;
        local code_column_idx = vtab_data.code_column_idx
        local has_code_eq = false

        for i = 0, pIdxInfo.nConstraint - 1 do
            local iColumn = pConstraint[i].iColumn

            pIdxInfo.aConstraintUsage[i].argvIndex = 0
            pIdxInfo.aConstraintUsage[i].omit = 0

            if (not has_code_eq)
                and iColumn == code_column_idx
                and pConstraint[i].usable == 1
                and pConstraint[i].op == SQLITE.INDEX_CONSTRAINT_EQ then
                has_code_eq = true
                pIdxInfo.aConstraintUsage[i].argvIndex = 1
                pIdxInfo.aConstraintUsage[i].omit = 1
            end
        end

        pIdxInfo.idxNum = has_code_eq and 1 or 0
        pIdxInfo.estimatedCost = has_code_eq and 10 or 1000000
        pIdxInfo.estimatedRows = has_code_eq and 16 or 1048576

        return SQLITE.OK;
    end,

    -- All cursor callbacks are set dynamically in create_vtable_functions
    -- to use C wrappers that route through vtable_vm
    xOpen = nil,
    xClose = nil,
    xFilter = nil,
    xNext = nil,
    xEof = nil,
    xColumn = nil,
    xRowid = nil
}

-- Keep module structs strongly referenced for SQLite module lifetime.
plugin._vtable_module_anchors = {
    lua_vtable_module,
    lua_vtable_module2,
}

local list_iterator = function(t)
    local i = 0
    local n = #t
    return function ()
            i = i + 1
            if i <= n then return t[i] end
        end
end

-- Setup vtable Lua callbacks (only needed in vtable_vm)
local setup_vtable_callbacks = function()
    -- Define all cursor callbacks as standalone functions
    -- These handle both lua_vtable_module (make_vtable) and lua_vtable_module2 (L/L10)

    local function set_vtab_error(cur_sqlptr, err)
        local msg
        if type(err) == 'table' then
            msg = tostring(err.message)
            if err.detail and err.detail ~= '' then
                msg = msg .. '\n' .. err.detail
            end
        else
            msg = tostring(err)
        end

        cur_sqlptr.base.pVtab.zErrMsg = sqlite_api.mprintf("%s", msg)
        return SQLITE.ERROR
    end

    local function is_make_vtable_array_key(k, array_len)
        return type(k) == "number" and k == math.floor(k) and k >= 1 and k <= array_len
    end

    local function advance_make_vtable_extra(cursor_data)
        while true do
            local k, row = next(cursor_data.input.rows, cursor_data.extra_key)
            cursor_data.extra_key = k
            if k == nil then
                cursor_data.current_row = nil
                return
            end
            if (not is_make_vtable_array_key(k, cursor_data.array_len)) and type(row) == "table" then
                cursor_data.current_row = row
                return
            end
        end
    end

    local function reset_make_vtable_cursor(cursor_data)
        cursor_data.array_len = #(cursor_data.input.rows)
        cursor_data.array_idx = 1
        cursor_data.extra_key = nil
        while cursor_data.array_idx <= cursor_data.array_len do
            local row = cursor_data.input.rows[cursor_data.array_idx]
            if type(row) == "table" then
                cursor_data.current_row = row
                return
            end
            cursor_data.array_idx = cursor_data.array_idx + 1
        end
        advance_make_vtable_extra(cursor_data)
    end

    local function advance_make_vtable_cursor(cursor_data)
        cursor_data.array_idx = (cursor_data.array_idx or 1) + 1
        while cursor_data.array_idx <= cursor_data.array_len do
            local row = cursor_data.input.rows[cursor_data.array_idx]
            if type(row) == "table" then
                cursor_data.current_row = row
                return
            end
            cursor_data.array_idx = cursor_data.array_idx + 1
        end
        advance_make_vtable_extra(cursor_data)
    end

    local xOpen_lua = function(pVTab, ppCursor)
        local pTable = ffi.cast('lua_vtab*', pVTab)
        local shared_key = tonumber(pTable.index)
        local vtab_data = shared_vtab_data.get(shared_key)
        if not vtab_data then
            pVTab.zErrMsg = sqlite_api.mprintf("lua_vtab: shared metadata missing")
            return SQLITE.ERROR
        end

        local cursor_data = {rowid = 1}

        if vtab_data.code_column_idx then
            -- L/L10 module: set up getter for iterator results
            local code_column_idx = vtab_data.code_column_idx
            if code_column_idx > 1 then
                cursor_data.getter = function(self, col)
                    return self.value[1][col]
                end
            else
                cursor_data.getter = function(self, _)
                    return self.value[1]
                end
            end
        else
            -- make_vtable module: input is stored directly in shared data
            local input = vtab_data.input
            cursor_data.input = input
            reset_make_vtable_cursor(cursor_data)
        end

        local cursor_index = vfunc_cur.new_key(cursor_data)

        local cur_sz = ffi.sizeof(vtab_cursor_t)
        local cur_sqlptr = ffi.cast('lua_vtab_cursor *', sqlite_api.malloc(cur_sz))

        if cur_sqlptr == nil then
            return SQLITE.NOMEM
        end

        cur_sqlptr.index = cursor_index
        cur_sqlptr.base.pVtab = pVTab

        ppCursor[0] = ffi.cast('sqlite3_vtab_cursor *', cur_sqlptr)

        return SQLITE.OK
    end

    local xClose_lua = function(cur)
        local cur_sqlptr = ffi.cast('lua_vtab_cursor *', cur)
        vfunc_cur.remove(tonumber(cur_sqlptr.index))
        sqlite_api.free(cur)
        return SQLITE.OK
    end

    local xFilter_lua = function(pVtabCursor, idxNum, idxStrUnused, argc, argv)
        local cur_sqlptr = ffi.cast('lua_vtab_cursor *', pVtabCursor)
        local cursor = vfunc_cur.get(cur_sqlptr.index)

        if cursor == nil then
            -- stale handle or double-close; treat as empty result
            return SQLITE.OK
        end

        if cursor.input then
            -- make_vtable module: reset iterator
            reset_make_vtable_cursor(cursor)
        else
            -- L/L10 module: execute code when provided; otherwise yield nothing
            local missing = (idxNum ~= 1) or (argv == nil or argc < 1)
            if missing then
                cursor.fn = function() return nil end
            else
                local code_value = argv[0]
                if code_value ~= nil and code_value ~= ffi.NULL then
                    local code_field = ffi.string(sqlite_api.value_text(code_value))
                    local results
                    local ok, err = xpcall(function()
                        results = {exec_lua(code_field)}
                    end, error_xcall)
                    if not ok then
                        return set_vtab_error(cur_sqlptr, err)
                    end

                    if type(results[1]) == "table" then
                        results = list_iterator(results[1]) 
                    elseif type(results[1]) == "function" then
                        results = results[1]
                    else
                        results = list_iterator(results)
                    end

                    cursor.fn = results
                else
                    cursor.fn = function() return nil end
                end
            end
            local ok, err = xpcall(function()
                cursor.value = {cursor.fn()}
            end, error_xcall)
            if not ok then
                return set_vtab_error(cur_sqlptr, err)
            end
        end

        cursor.rowid = 1

        return SQLITE.OK
    end

    local xNext_lua = function(cur)
        local cur_sqlptr = ffi.cast('lua_vtab_cursor *', cur)
        local cursor = vfunc_cur.get(cur_sqlptr.index)

        if cursor == nil then
            cur_sqlptr.base.pVtab.zErrMsg = sqlite_api.mprintf("lua_vtab: cursor missing")
            return SQLITE.MISUSE
        end

        if cursor.input then
            -- make_vtable module: advance iterator
            advance_make_vtable_cursor(cursor)
        else
            -- L/L10 module: call iterator function
            local ok, err = xpcall(function()
                cursor.value = {cursor.fn()}
            end, error_xcall)
            if not ok then
                return set_vtab_error(cur_sqlptr, err)
            end
        end

        cursor.rowid = cursor.rowid + 1

        return SQLITE.OK
    end

    local xEof_lua = function(cur)
        local cur_sqlptr = ffi.cast('lua_vtab_cursor *', cur)
        local cursor = vfunc_cur.get(cur_sqlptr.index)

        if cursor == nil then
            return 1 -- treat as exhausted instead of crashing
        end

        if cursor.input then
            -- make_vtable module: check if iterator exhausted
            return cursor.current_row == nil and 1 or 0
        else
            -- L/L10 module: check if value is empty
            return #cursor.value == 0 and 1 or 0
        end
    end

    local xColumn_lua = function(cur, ctx, col)
        local cur_sqlptr = ffi.cast('lua_vtab_cursor *', cur)
        local cursor = vfunc_cur.get(cur_sqlptr.index)

        if cursor == nil then
            sqlite_api.result_error(ctx, "lua_vtab: cursor missing", -1)
            return SQLITE.MISUSE
        end

        if cursor.input then
            -- make_vtable module: get column from current row
            local row = cursor.current_row
            local data
            if type(row) == "table" then
                data = row[col + 1]
            else
                data = nil
            end
            api_function_return_any(ctx, data)
        else
            -- L/L10 module: use getter
            local ok, result = xpcall(function()
                return cursor:getter(col + 1)
            end, error_xcall)
            if not ok then
                return set_vtab_error(cur_sqlptr, result)
            end

            api_function_return_any(ctx, result)
        end

        return SQLITE.OK
    end

    local xRowid_lua = function(cur, pRowid)
        local cur_sqlptr = ffi.cast('lua_vtab_cursor *', cur)
        local cursor = vfunc_cur.get(cur_sqlptr.index)
        if cursor == nil then
            cur_sqlptr.base.pVtab.zErrMsg = sqlite_api.mprintf("lua_vtab: cursor missing")
            return SQLITE.MISUSE
        end

        pRowid[0] = cursor.rowid
        return SQLITE.OK
    end

    -- Keep FFI callback cdata strongly referenced for VM lifetime.
    local vtab_cbs = {
        xOpen = ffi.cast('int (*)(sqlite3_vtab*, sqlite3_vtab_cursor**)', xOpen_lua),
        xClose = ffi.cast('int (*)(sqlite3_vtab_cursor*)', xClose_lua),
        xFilter = ffi.cast('int (*)(sqlite3_vtab_cursor*, int, const char*, int, sqlite3_value**)', xFilter_lua),
        xNext = ffi.cast('int (*)(sqlite3_vtab_cursor*)', xNext_lua),
        xEof = ffi.cast('int (*)(sqlite3_vtab_cursor*)', xEof_lua),
        xColumn = ffi.cast('int (*)(sqlite3_vtab_cursor*, sqlite3_context*, int)', xColumn_lua),
        xRowid = ffi.cast('int (*)(sqlite3_vtab_cursor*, sqlite_int64*)', xRowid_lua),
    }
    plugin._vtable_lua_callback_anchors = vtab_cbs

    -- Store Lua callbacks in plugin_init_data (C code will call these from vtable_vm)
    plugin_init_data.vtab_xOpen_lua = vtab_cbs.xOpen
    plugin_init_data.vtab_xClose_lua = vtab_cbs.xClose
    plugin_init_data.vtab_xFilter_lua = vtab_cbs.xFilter
    plugin_init_data.vtab_xNext_lua = vtab_cbs.xNext
    plugin_init_data.vtab_xEof_lua = vtab_cbs.xEof
    plugin_init_data.vtab_xColumn_lua = vtab_cbs.xColumn
    plugin_init_data.vtab_xRowid_lua = vtab_cbs.xRowid
end

-- Setup vtable module callbacks to use C wrappers (needed at depth 1 before create_module_v2)
local setup_vtable_module_callbacks = function()
    -- Set both modules to use C wrappers (which route through vtable_vm)
    lua_vtable_module.xOpen = plugin_init_data.cb_vtab_xOpen
    lua_vtable_module.xClose = plugin_init_data.cb_vtab_xClose
    lua_vtable_module.xFilter = plugin_init_data.cb_vtab_xFilter
    lua_vtable_module.xNext = plugin_init_data.cb_vtab_xNext
    lua_vtable_module.xEof = plugin_init_data.cb_vtab_xEof
    lua_vtable_module.xColumn = plugin_init_data.cb_vtab_xColumn
    lua_vtable_module.xRowid = plugin_init_data.cb_vtab_xRowid

    lua_vtable_module2.xOpen = plugin_init_data.cb_vtab_xOpen
    lua_vtable_module2.xClose = plugin_init_data.cb_vtab_xClose
    lua_vtable_module2.xFilter = plugin_init_data.cb_vtab_xFilter
    lua_vtable_module2.xNext = plugin_init_data.cb_vtab_xNext
    lua_vtable_module2.xEof = plugin_init_data.cb_vtab_xEof
    lua_vtable_module2.xColumn = plugin_init_data.cb_vtab_xColumn
    lua_vtable_module2.xRowid = plugin_init_data.cb_vtab_xRowid
end

-- Create L and L10 vtable modules (only needed once at depth 1)
local create_vtable_modules = function()
    local key = shared_vtab_data.new_key({
        xtable_text = "CREATE TABLE x(value, code hidden)",
        code_column_idx = 1,
        module_type = "L"
    })

    local rc = sqlite_api.create_module_v2(
        sqlite_db,
        "L",
        lua_vtable_module2,
        ffi.cast('void*', key),
        nil
    );
    if rc ~= SQLITE.OK then
        return error("setup L module failed")
    end

    key = shared_vtab_data.new_key({
        xtable_text = "CREATE TABLE x(r0,r1,r2,r3,r4,r5,r6,r7,r8,r9, code hidden)",
        code_column_idx = 10,
        module_type = "L10"
    })
    local rc = sqlite_api.create_module_v2(
        sqlite_db,
        "L10",
        lua_vtable_module2,
        ffi.cast('void*', key),
        nil
    );
    if rc ~= SQLITE.OK then
        return error("setup L10 module failed")
    end
end

local copy_to_global = function (map)
    _G.NULL = map.NULL
end

local copy_to_plugin = function (map)
    for k,v in pairs(map) do
        plugin[k] = v
    end
end

local __depth__
plugin.extension_call = function ()
end


local text_caller_fn = function(context, argc, argv)
    --call function stored as text, no depth limit
    local saved_ref = tonumber(ffi.cast('int64_t', sqlite_api.user_data(context)))
    local fn = function_refs_text.get(saved_ref)
    local result = fn(api_get_args(context, argc, argv))

    api_function_return_any(context, result)
end

plugin.extension_init = function ( ctx )
    copy_to_global(public_env)

    copy_to_plugin(public_env)

    plugin.extension_init = nil
    plugin.extension_deinit = nil
    plugin.extension_call = nil

    plugin_init_data = ffi.cast('LJFunctionData *', ctx)

    sqlite_db = plugin_init_data.db
    sqlite_api = plugin_init_data.api
    __depth__ = plugin_init_data.call_depth

    plugin_init_data.caller_fn = wrap_csafe_cs(text_caller_fn)

    if plugin_init_data.is_vtable_vm == 1 then
        setup_vtable_callbacks()
        return
    end

    --package.loaded["sqlite_lj"] = plugin
    if __depth__ > 1 then
        return
    end

    setup_vtable_module_callbacks()
    create_vtable_modules()

    make_fn('L', [[
    return function (code_text, ...)
        local name = "temp_fn"
        local fn_env = {}
        setmetatable(fn_env, { __index = _G })
        fn_env["arg"] = {...}

        local fn, err = loadstring(code_text, name, "t", fn_env)
        if not fn then
            local msg = "Create failed [".. name .. "]\n" .. tostring(err)
            return error(msg)
        end
        return fn()
    end
    ]]);
end

plugin.extension_deinit = function ()
    -- no db operations expected here
end

return plugin
