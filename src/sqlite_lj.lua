local plugin = {}

plugin._DESCRIPTION = "LuaJIT FFI sqlite language extension"
plugin._VERSION = "sqlite lj 0.1"

local ffi = require('ffi')

local SQLITE = require('sqlite_capi').SQLITE
local NULL = require('sqlite_capi').NULL

local int_t = ffi.typeof("int")
local int64_t = ffi.typeof("int64_t")
local uint64_t = ffi.typeof("uint64_t")
local float_t = ffi.typeof("float")
local double_t = ffi.typeof("double")

local sqlite3_module_t = ffi.typeof('sqlite3_module')
local vtab_cursor_t = ffi.typeof('lua_vtab_cursor')

local bor = require("bit").bor

local sqlite_db
local sqlite_api

local unfinalized_statements = setmetatable({}, { __mode = "k" })

local close_unfinalized = function ()
    for stmt, isopen in pairs(unfinalized_statements) do
        if not isopen then
            return
        end

        local step_rc = sqlite_api.finalize(ffi.gc(stmt, nil)[0])
        if step_rc ~= SQLITE.OK then
            print('close unfinalized statement failed', step_rc, stmt)
        end
    end
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

local function_refs = Storage()
local agg_function_refs = Storage()
local vfunc_data = Storage()
local vfunc_cur = Storage()

local stored_fn

local restore_functions_flag = false


local wrap_csafe
local create_function_agg_chk
local create_function_agg_coro
local run_sql
local fetch_all
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

--sqlite3_context *context, int argc, sqlite3_value **argv
local api_get_args = function(context, argc, argv)
    local tmp = {}
    for i = 0, argc -1 do
        local value = sqlite_to_l (argv[i])
        table.insert(tmp, value)
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
        if value == math.floor(value) then
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
        if value == math.floor(value) then
            sqlite_api.bind_int64(stmt, index, value)
        else
            sqlite_api.bind_double(stmt, index, value)
        end
    end,

    string = function(stmt, index, value)
        sqlite_api.bind_text(stmt, index, value, -1, nil)
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
            local msg = "api_function_return_any: unsupported type " .. tostring(type(value)) .. " value " .. tostring(value)
            error(msg)
        end
    else
        local msg = "api_bind_any: unsupported type " .. value_type .. " value " .. tostring(value)
        error(msg)
    end
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

--sqlite3_context *context, int argc, sqlite3_value **argv
local return_const = function(context, argc, argv)
    local saved_constant = ffi.cast('int64_t', sqlite_api.user_data(context))
    sqlite_api.result_int64(context, saved_constant)
end

local make_stored_int = function(name, value)
    local ok = api_create_function_v2(name, 0, bor(SQLITE.DETERMINISTIC, SQLITE.INNOCUOUS) , ffi.cast('void*', value), return_const, nil, nil, nil)
    if ok then
        stored_fn.store_function(name, nil, nil, value, 0, "create_constant")
    end
    return ok
end
public_env.make_stored_int = make_stored_int

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


local wrapped_functions = {}
wrap_csafe = function (fn)
    if fn then
        if not wrapped_functions[fn] then
            --sqlite3_context *context, int argc, sqlite3_value **argv
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

--sqlite3_context *context, int argc, sqlite3_value **argv
local caller_fn = function(context, argc, argv)
    local outer_statements = unfinalized_statements
    unfinalized_statements = setmetatable({}, { __mode = "k" })

    local saved_ref = ffi.cast('int64_t', sqlite_api.user_data(context))
    local fn = function_refs.get(saved_ref)
    local result = fn(api_get_args(context, argc, argv))

    api_function_return_any(context, result)

    close_unfinalized()
    unfinalized_statements = outer_statements
end

local create_function = function(name, fn, argc)
    if type(fn) ~= 'function' then
        return error('create_function: "fn" is not a function')
    end

    local ref = function_refs.new_key(fn) -- items count

    local status, err, errcode = api_create_function_v2(name, argc, SQLITE.UTF8, ffi.cast('void*', ref) , caller_fn, nil, nil, nil)
    if not status then
        return error(err)
    end

end
public_env.create_function = create_function

--sqlite3_context *context, int argc, sqlite3_value **argv
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
    close_unfinalized()
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

local make_stored_fn = function(name, code_text, argc)
    argc = argc or -1

    local fn_env = {}
    setmetatable(fn_env, public_env_mt)

    if code_text == nil then return end
    local f, err = loadstring(ffi.string(code_text), name, "t", fn_env)
    if (f) then
        local status, res = xpcall(f, error_xcall)
        if not status then
            local msg = 'Create failed ['.. name .. ']\n'  ..tostring(res.message) .. '\n' .. res.detail
            return msg
        end

        setfenv(res, fn_env)
        local status, err = xpcall(create_function, error_xcall, name, res, argc)

        if not status then
            local msg = 'Create failed ['.. name .. ']\n' .. tostring(err.message) .. '\n' .. err.detail
            return msg
        end
        
    else
        local msg = 'Create failed ['.. name .. ']\n' .. tostring(err)
        return msg
    end
    stored_fn.store_function(name, nil, code_text, nil, argc, "make_stored_fn")
end

local make_stored_chk = function (name, chunk_text, argc)
    local status, err = xpcall(create_function_chk, error_xcall, name, chunk_text, 1,  caller_chk)
    if not status then
        local msg = 'Create failed ['.. name .. ']\n' .. tostring(err.message) .. '\n' .. err.detail
        return msg
    end
    stored_fn.store_function(name, nil, chunk_text, nil, argc, "make_stored_chk")
end

local make_function_agg_chk = function(fname, finit, fstep, ffinal, fargc)
    fargc = fargc or -1
    return create_function_agg_chk(tostring(fname), tostring(finit), tostring(fstep), tostring(ffinal), fargc)
end

local make_function_agg = function(name, code_text, argc)
    argc = argc or -1
    if code_text == nil then return end
    local f, err = loadstring(ffi.string(code_text), name, "t", _G)
    if (f) then
        local status, res = xpcall(f, error_xcall)
        if not status then
            local msg = 'Create failed ['.. name .. ']\n'  ..tostring(res.message) .. '\n' .. res.detail
            return msg
        end

        local status, err = xpcall(create_function_agg_coro, error_xcall, name, res, argc)
        if not status then
            local msg = 'Create failed ['.. name .. ']\n' .. tostring(err.message) .. '\n' .. err.detail
            return msg
        end
    else
        local msg = 'Create failed ['.. name .. ']\n' .. tostring(err)
        return msg
    end
end

-- sqlite3_context *context, int argc, sqlite3_value **argv
local agg_cb_coro = function(context, argc, argv)
    local storage = ffi.cast('int*', sqlite_api.aggregate_context(context, ffi.sizeof('int')))
    if (storage == nil) then
        return sqlite_api.result_error_nomem(context);
    end

    if (storage[0] == 0) then
        local saved_ref = ffi.cast('int64_t', sqlite_api.user_data(context))
        local agg_fn = coroutine.create(function_refs.get(saved_ref))

        local key = agg_function_refs.new_key(agg_fn)
		storage[0] = key

        coroutine.resume(agg_fn, api_get_args(context, argc, argv)) --run coro
    end
    local agg_fn = agg_function_refs.get(storage[0])
    coroutine.resume(agg_fn, true, api_get_args(context, argc, argv))
end

--sqlite3_context *context
local agg_final_coro = function(context)
    local storage = ffi.cast('int*', sqlite_api.aggregate_context(context, ffi.sizeof('int')))
    local agg_index = storage[0]
    local agg_fn = agg_function_refs.get(agg_index)
    local _, result = coroutine.resume(agg_fn, false)
    agg_function_refs.remove(agg_index)
    api_function_return_any(context, result)
end

create_function_agg_coro = function(name, fn, argc)
    if type(fn) ~= 'function' then
        return error('create_function: "fn" is not a function')
    end

    local ref = function_refs.new_key(fn)

    local status, err, errcode = api_create_function_v2(name, argc, SQLITE.UTF8, ffi.cast('void*', ref) , nil, agg_cb_coro, agg_final_coro, nil)
    if not status then
        return error(err)
    end

end
public_env.create_function_agg_coro = create_function_agg_coro

--sqlite3_context *context, int argc, sqlite3_value **argv
local agg_cb_chk = function(context, argc, argv)
    local storage = ffi.cast('int*', sqlite_api.aggregate_context(context, ffi.sizeof('int')))
    if (storage == nil) then
        return sqlite_api.result_error_nomem(context);
    end

    local saved_ref = ffi.cast('int64_t', sqlite_api.user_data(context))
    local fn = function_refs.get(saved_ref)

    local args = {api_get_args(context, argc, argv)}

    if (storage[0] == 0) then
        local chk_env = {}
        setmetatable(chk_env, public_env_mt)
        chk_env['arg'] = args

        local key = agg_function_refs.new_key(chk_env)
		storage[0] = key
        setfenv(fn.init, chk_env)
        fn.init()
    end

    local chk_env = agg_function_refs.get(storage[0])
    chk_env['arg'] = args

    setfenv(fn.step, chk_env)
    fn.step()
end

--sqlite3_context *context
local agg_final_chk = function(context)
    local storage = ffi.cast('int*', sqlite_api.aggregate_context(context, ffi.sizeof('int')))
    local agg_index = storage[0]
    local chk_env = agg_function_refs.get(agg_index)
    agg_function_refs.remove(agg_index)

    local saved_ref = ffi.cast('int64_t', sqlite_api.user_data(context))
    local fn = function_refs.get(saved_ref)
    setfenv(fn.final, chk_env)

    local result = fn.final()
    api_function_return_any(context, result)
end

create_function_agg_chk = function(name, init, step, final, argc)
    local agg_code = {
        init = loadstring(init, name..':init', "t"),
        step = loadstring(step, name..':step', "t"),
        final = loadstring(final, name..':final', "t")
    }

    local ref = function_refs.new_key(agg_code)

    local status, err, errcode = api_create_function_v2(name, argc, SQLITE.UTF8, ffi.cast('void*', ref) , nil, agg_cb_chk, agg_final_chk, nil)
    if not status then
        return error(err)
    end
end
public_env.create_function_agg_chk = create_function_agg_chk

run_sql = function (sql)
    sql = tostring(sql)
    local rc = sqlite_api.exec(sqlite_db, sql, nil, nil, nil)
    if rc ~= SQLITE.OK then
        local msg = ffi.string(sqlite_api.errmsg(sqlite_db))
        return error("Failed to execute query: \n[" .. sql .. "] \n"  .. msg)
    end
end
public_env.run_sql = run_sql

local finalize_stmt = function (stmt)
    return sqlite_api.finalize(stmt[0])
end

fetch_all = function (...)
    local rows = {}
    for row in nrows(...) do
        table.insert(rows, row);
    end
    return rows
end
public_env.fetch_all = fetch_all

local Statement = function (sql, params)
    local self = {}

    local stmt
    local columns_count
    local columns
    local step_rc

    sql = tostring(sql)
    stmt = ffi.gc(ffi.new("sqlite3_stmt*[?]", 1), finalize_stmt)
    unfinalized_statements[stmt] = true

    local rc = sqlite_api.prepare_v2(sqlite_db, sql, -1, stmt, nil)
    if rc ~= SQLITE.OK then
        error("Failed to prepare query \n[" .. sql.. "]" )
    end
    if type(params) == "table" then
        local parameter_count = sqlite_api.bind_parameter_count(stmt[0])
        for k = 1, parameter_count  do
            local c_param_name = sqlite_api.bind_parameter_name(stmt[0], k)
            if c_param_name == nil then
                api_bind_any(stmt[0], k, params[k])
            else
                local name = ffi.string(c_param_name):sub(2) -- remove prefix 
                local value = params[name]
                if value == nil then
                    value = params[k]
                end
                api_bind_any(stmt[0], k, value)
            end
        end
    end

    columns_count = sqlite_api.column_count(stmt[0])

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
           
        for i = 0, columns_count - 1 do
            local value = sqlite_to_l(sqlite_api.column_value(stmt[0], i))
            table.insert(row, value)
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
        if step_rc ~= SQLITE.DONE then
            error('iterate sql failed '.. tostring(step_rc))
        end
        unfinalized_statements[stmt] = nil
        step_rc = sqlite_api.finalize(ffi.gc(stmt, nil)[0])

        if step_rc ~= SQLITE.OK then
            error('finalize last failed '.. tostring(step_rc))
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

local StoredFunctionControl = function ()
    local initialized = false
    local table_storage

    local create_table
    local drop_function
    local query_functions
    local store_function

    local restore_functions = function ()
        if not table_storage then return end
        run_sql (create_table)
        restore_functions_flag = true
    
        local rows = fetch_all (query_functions)
        for i, row in ipairs(rows)  do
            if row.creator == 'make_stored_fn' then
                make_stored_fn(row.name, row.body, row.argc)
            elseif row.creator == 'create_constant' then
                make_stored_int(row.name, row.ret)
            elseif row.creator == 'make_stored_chk' then
                make_stored_chk(row.name, row.body, row.argc)
            end
        end
        restore_functions_flag = false
    
    end

    local self = {}
    self.use_function_storage = function (table_name)
        if initialized then 
            print("use_function_storage already called")
            return
        end

        initialized = true
        table_storage = table_name
        create_table = string.format("CREATE TABLE IF NOT EXISTS %s(name, head, body, ret, argc, creator)", table_storage)
        drop_function = string.format("DELETE FROM %s WHERE lower(name) = lower(?) AND argc = ?", table_storage)
        query_functions = string.format("SELECT name, head, body, ret, argc, creator FROM %s", table_storage)
        store_function = string.format("INSERT INTO %s(name, head, body, ret, argc, creator) VALUES(?,?,?,?,?,?)", table_storage)

        restore_functions()
    end

    self.drop_function = function(name, argc)
        if not initialized then 
            print("drop_function: use_function_storage not set")
            return
        end
        if not table_storage then return end

        argc = argc or -1
    
        fetch_all (drop_function, {name, argc})
    
        local status, err, errcode = api_create_function_v2(name, argc, 0, nil , nil, nil, nil, nil)
        if not status then
            --TODO fix it 
            return "DROP FUNCTION error: ".. err
        end
        return ""
    end


    self.store_function = function (name, head, body, ret, argc, creator)
        if not initialized then 
            print("store_function: use_function_storage not set")
            return
        end
        if not table_storage then return end
        if not restore_functions_flag then
            fetch_all (store_function, {name, head, body, ret, argc, creator})
        end
    end

    return self
    
end


--local sqlite3_module_test = ffi.cast('sqlite3_module *', api.malloc(ffi.sizeof(sqlite3_module_t)))--sqlite3_module_t{}
local lua_vtable_module = sqlite3_module_t{
    iVersion = 1,
    xCreate = function ()
        return SQLITE.OK
    end,
    xDestroy = function ()
        return SQLITE.OK
    end,

    xConnect = function (db, pAux, argc, argv, ppVTab, pzErrUnused)
        local vfunc_data_index  = ffi.cast('int64_t', pAux)
        local xtable_text = vfunc_data.get(vfunc_data_index).xtable_text

        local rc = sqlite_api.declare_vtab(db, xtable_text) --"CREATE TABLE x(...)";
        if rc == SQLITE.OK then
            local pTable = ffi.cast('lua_vtab*', sqlite_api.malloc(ffi.sizeof('lua_vtab')))
    
            if( pTable==nil ) then
                return SQLITE.NOMEM
            end
    
            pTable.base.pModule = nil;
            pTable.base.nRef = 0
            pTable.base.zErrMsg = nil
            pTable.index = vfunc_data_index
    
            ppVTab[0] = ffi.cast('sqlite3_vtab*', pTable)
        end
        return rc
        
    end,

    --sqlite3_vtab *pVtab
    xDisconnect = function(pVtab)
        local pTable = ffi.cast('lua_vtab*', pVtab)
        local vfunc_data_index  = tonumber(pTable.index)

        vfunc_data.remove(vfunc_data_index)

        sqlite_api.free(pVtab);
        return SQLITE.OK;
    end ,

    xBestIndex = function (pVTab, pIdxInfo)
        return SQLITE.OK;
    end,

    --sqlite3_vtab * pVtab, sqlite3_vtab_cursor **ppCursor
    xOpen = function( pVtab, ppCursor)
        local pTable = ffi.cast('lua_vtab*', pVtab)
        local input = vfunc_data.get(pTable.index).input
        local first_index = next(input.rows, nil)
       
        local cursor_index = vfunc_cur.new_key({input = input, iterator = first_index, rowid = 1})

        local cur_sz = ffi.sizeof(vtab_cursor_t)
        local cur_sqlptr =  ffi.cast('lua_vtab_cursor *', sqlite_api.malloc(cur_sz))

        if( cur_sqlptr==nil ) then
            return SQLITE.NOMEM
        end

        cur_sqlptr.index = cursor_index
        cur_sqlptr.base.pVtab = pVtab

        ppCursor[0] = ffi.cast('sqlite3_vtab_cursor *', cur_sqlptr)

        return SQLITE.OK;
    end,

    --sqlite3_vtab_cursor *
    xClose = function(cur)
        local cur_sqlptr = ffi.cast('lua_vtab_cursor *', cur)
        vfunc_cur.remove(tonumber(cur_sqlptr.index))
        sqlite_api.free(cur);
        return SQLITE.OK;
    end,

    xFilter = function (pVtabCursor, idxNum, idxStrUnused, argc, argv)
        local cur_sqlptr = ffi.cast('lua_vtab_cursor *', pVtabCursor)
        local cursor = vfunc_cur.get(cur_sqlptr.index)

        cursor.iterator = next(cursor.input.rows, nil)
        cursor.rowid = 1

        return SQLITE.OK;
    end,

    --sqlite3_vtab_cursor * cur
    xNext = function(cur)
        local cur_sqlptr = ffi.cast('lua_vtab_cursor *', cur)
        local cursor = vfunc_cur.get(cur_sqlptr.index)

        cursor.iterator = next(cursor.input.rows, cursor.iterator)
        cursor.rowid = cursor.rowid + 1

        return SQLITE.OK;
    end,

    --sqlite3_vtab_cursor * cur
    xEof = function(cur)
        local cur_sqlptr = ffi.cast('lua_vtab_cursor *', cur)
        local cursor = vfunc_cur.get(cur_sqlptr.index)

        return not cursor.iterator
    end,

    --sqlite3_vtab_cursor *cur, sqlite3_context *ctx, int col
    xColumn = function(cur, ctx, col)
        local cur_sqlptr = ffi.cast('lua_vtab_cursor *', cur)
        local cursor = vfunc_cur.get(cur_sqlptr.index)

        -- zero index to 1 index
        local data = cursor.input.rows[cursor.iterator][col + 1]
        api_function_return_any(ctx, data)

        return SQLITE.OK
    end,

    --sqlite3_vtab_cursor *cur, --sqlite_int64 *pRowid
    xRowid = function(cur, pRowid)
        local cur_sqlptr = ffi.cast('lua_vtab_cursor *', cur)
        local cursor = vfunc_cur.get(cur_sqlptr.index)

        pRowid[0] = cursor.rowid
        return SQLITE.OK;
    end
}

local make_vtable = function(table_name, input)
    local column_names = table.concat(input.columns, ', ')
    local xtable_text = string.format("CREATE TABLE x(%s)", column_names)
    
    local key = vfunc_data.new_key({
        xtable_text = xtable_text,
        input = input,
        module = lua_vtable_module -- anchor to keep it alive
    })

    local rc = sqlite_api.create_module_v2(sqlite_db, table_name, lua_vtable_module, ffi.cast('void*', key), nil);
    if rc ~= SQLITE.OK then
        return error("setup module failed")
    end

    local create_vtable_text = "CREATE VIRTUAL TABLE TEMP." .. table_name .. " USING " .. table_name .. "();"
    run_sql(create_vtable_text);
end
public_env.make_vtable = make_vtable

local lua_vtable_module2 = sqlite3_module_t{
    iVersion = 0,

    xConnect = function (db, pAux, argc, argv, ppVTab, pzErrUnused)
        local vfunc_data_index  = tonumber(ffi.cast('int64_t', pAux))
        local xtable_text = vfunc_data.get(vfunc_data_index).xtable_text

        local rc = sqlite_api.declare_vtab(db, xtable_text) --"CREATE TABLE x(...)";
        if rc == SQLITE.OK then
            local pTable = ffi.cast('lua_vtab*', sqlite_api.malloc(ffi.sizeof('lua_vtab')))
    
            if( pTable==nil ) then
                return SQLITE.NOMEM
            end
    
            pTable.base.pModule = nil;
            pTable.base.nRef = 0
            pTable.base.zErrMsg = nil
            pTable.index = vfunc_data_index
    
            ppVTab[0] = ffi.cast('sqlite3_vtab*', pTable)

            sqlite_api.vtab_config(db, SQLITE.VTAB_INNOCUOUS);
        end

        return rc
        
    end,

    xDisconnect = function(pVTab)
        local pTable = ffi.cast('lua_vtab*', pVTab)
        local vfunc_data_index  = tonumber(pTable.index)

        vfunc_data.remove(vfunc_data_index)

        sqlite_api.free(pVTab);
        return SQLITE.OK;
    end,

    xBestIndex = function (pVTab, pIdxInfo)
        local pTable = ffi.cast('lua_vtab*', pVTab)
        local vfunc_data_index  = tonumber(pTable.index)

        local pConstraint = pIdxInfo.aConstraint;

        local code_column_idx = vfunc_data.get(vfunc_data_index).code_column_idx

        local constraint_code_idx = 0
        for i = 0, pIdxInfo.nConstraint - 1 do
            local iColumn = pConstraint[i].iColumn

            pIdxInfo.aConstraintUsage[i].argvIndex = i + 1
            pIdxInfo.aConstraintUsage[i].omit = 0

            if iColumn == code_column_idx then
                constraint_code_idx = i
                pIdxInfo.aConstraintUsage[i].omit = 1
            end
        end

        pIdxInfo.idxNum = constraint_code_idx

        return SQLITE.OK;
    end,

    xOpen = function( pVTab, ppCursor)
        local pTable = ffi.cast('lua_vtab*', pVTab)
        local code_column_idx = vfunc_data.get(pTable.index).code_column_idx

        local getter 
        if code_column_idx > 1 then
            getter = function (self, col)
                return self.value[1][col]
            end
        else
            getter = function (self, _)
                return self.value[1]
            end
        end
        
        local cursor_index = vfunc_cur.new_key({rowid = 1, getter = getter})

        local cur_sz = ffi.sizeof(vtab_cursor_t)
        local cur_sqlptr =  ffi.cast('lua_vtab_cursor *', sqlite_api.malloc(cur_sz))

        if( cur_sqlptr==nil ) then 
            return SQLITE.NOMEM 
        end

        cur_sqlptr.index = cursor_index
        cur_sqlptr.base.pVtab = pVTab

        ppCursor[0] = ffi.cast('sqlite3_vtab_cursor *', cur_sqlptr)

        return SQLITE.OK;
    end,

    xClose = function(cur)
        local cur_sqlptr = ffi.cast('lua_vtab_cursor *', cur)
        vfunc_cur.remove(tonumber(cur_sqlptr.index))
        sqlite_api.free(cur);
        return SQLITE.OK;
    end,

    xFilter = function (pVtabCursor, idxNum, idxStrUnused, argc, argv)
        local code_field = ffi.string(sqlite_api.value_text(argv[idxNum]))
        local cur_sqlptr = ffi.cast('lua_vtab_cursor *', pVtabCursor)
        local cursor = vfunc_cur.get(cur_sqlptr.index)

        cursor.fn = exec_lua(code_field)
        cursor.value = {cursor.fn()}

        cursor.rowid = 1

        return SQLITE.OK;
    end,

    xNext = function(cur)
        local cur_sqlptr = ffi.cast('lua_vtab_cursor *', cur)
        local cursor = vfunc_cur.get(cur_sqlptr.index)

        cursor.value = {cursor.fn()}
 
        cursor.rowid = cursor.rowid + 1

        return SQLITE.OK;
    end,

    xEof = function(cur)
        local cur_sqlptr = ffi.cast('lua_vtab_cursor *', cur)
        local cursor = vfunc_cur.get(cur_sqlptr.index)

        return #cursor.value == 0
    end,

     xColumn = function(cur, ctx, col)
        local cur_sqlptr = ffi.cast('lua_vtab_cursor *', cur)
        local cursor = vfunc_cur.get(cur_sqlptr.index)

        api_function_return_any(ctx, cursor:getter(col + 1)) 

        -- only when pIdxInfo.aConstraintUsage[...].omit = 0
        -- api_function_return_any(ctx, cursor.filter)
        return SQLITE.OK
    end,

    xRowid = function(cur, pRowid)
        local cur_sqlptr = ffi.cast('lua_vtab_cursor *', cur)
        local cursor = vfunc_cur.get(cur_sqlptr.index)

        pRowid[0] = cursor.rowid
        return SQLITE.OK;
    end
}

local create_vtable_functions = function()

    local key = vfunc_data.new_key({
        module = lua_vtable_module2, -- anchor to keep it alive
        xtable_text = "CREATE TABLE x(value, code hidden)",
        code_column_idx = 1
    })

    local rc = sqlite_api.create_module_v2(sqlite_db, "L", lua_vtable_module2, ffi.cast('void*', key), nil);
    if rc ~= SQLITE.OK then
        return error("setup L module failed")
    end

    key = vfunc_data.new_key({
        module = lua_vtable_module2, -- anchor to keep it alive
        xtable_text = "CREATE TABLE x(r0,r1,r2,r3,r4,r5,r6,r7,r8,r9, code hidden)",
        code_column_idx = 10
    })
    local rc = sqlite_api.create_module_v2(sqlite_db, 'L10', lua_vtable_module2, ffi.cast('void*', key), nil);
    if rc ~= SQLITE.OK then
        return error("setup L10 module failed")
    end
end

local copy_to_global = function (map)
    for k,v in pairs(map) do
        _G[k] = v
    end
end


plugin.extension_init = function ( ctx )
    copy_to_global(public_env)

    local plugin_init_data = ffi.cast('LJFunctionData *', ctx)

    sqlite_db = plugin_init_data.db
    sqlite_api = plugin_init_data.api

    stored_fn = StoredFunctionControl()

    create_vtable_functions()
    create_function("L", exec_lua, -1)

    -- all stored functions will be called, do not run untrusted code/dbfile !!!
    create_function("use_function_storage", stored_fn.use_function_storage, -1)
    create_function("drop_function", stored_fn.drop_function, -1)

    create_function("make_stored_int", make_stored_int, 2)
    create_function("make_stored_chk", make_stored_chk, -1)
    create_function("make_stored_fn", make_stored_fn, -1)
    create_function("make_stored_agg3", make_function_agg_chk, -1)
    create_function("make_stored_aggc", make_function_agg, -1)
end

plugin.extension_deinit = function ()
    -- no db operations expected here
end

return plugin
