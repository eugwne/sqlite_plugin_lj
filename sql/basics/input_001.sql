select load_extension('./libsqlite_plugin_lj');

select L('
    sqlite.register_internal_function("make_fn")
    sqlite.register_internal_function("make_int")
    sqlite.register_internal_function("make_chk")
');
select make_fn('Lua', '
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
');
select Lua('
    local increment_w = function(a)
        return a + 1
    end
    sqlite.create_function("inc", increment_w, 1)
');

select make_chk('inc_c', 'return arg[1] + 1', 1);
select make_chk('error_inc_c', 'return arg[1][1] + 1', 1);

select inc(12);

select make_int('const_x', 9999);
select const_x();
select L('
sqlite.make_int("const_x2", 10000)
');
select const_x2();


select L('sqlite.run_sql[[
          CREATE TABLE numbers(num1,num2);
          INSERT INTO numbers VALUES(1,11);
          INSERT INTO numbers VALUES(2,22);
          INSERT INTO numbers VALUES(3,33);
        ]]
');

select L('
_G.pprint_table = function (tbl, out, indent)
    out = out or {}
    indent = indent or 0
    local keys = {}
    for k, _ in pairs(tbl) do
        table.insert(keys, k)
    end
    table.sort(keys)

    for _, k in ipairs(keys) do
        local v = tbl[k]
        if type(v) == "table" then
            out[#out + 1] = string.rep(" ", indent) .. tostring(k) .. " = {"
            pprint_table(v, out, indent + 4)
            out[#out + 1] = string.rep(" ", indent) .. "}"
        else
            out[#out + 1] = string.rep(" ", indent) .. tostring(k) .. " = " .. tostring(v)
        end
    end
    return out
end
');

select L('
local out = {}
for a in sqlite.rows("SELECT * FROM numbers") do pprint_table(a, out) end
return table.concat(out, "\n")
');

select L('
local out = {}
for a in sqlite.nrows("SELECT * FROM numbers") do pprint_table(a, out) end
return table.concat(out, "\n")
');

select L('
local out = {}
for num1, num2 in sqlite.urows("SELECT * FROM numbers") do
    out[#out + 1] = tostring(num1) .. "\t" .. tostring(num2)
end
return table.concat(out, "\n")
');

select L('
local out = {}
for num1, num2 in sqlite.urows("SELECT * FROM numbers") do 
for num3, num4 in sqlite.urows("SELECT * FROM numbers") do 
        out[#out + 1] = tostring(num1) .. "\t" .. tostring(num3)
    end
end
return table.concat(out, "\n")
');
