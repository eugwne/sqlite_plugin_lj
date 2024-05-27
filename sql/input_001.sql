select load_extension('./libsqlite_plugin_lj');
select use_function_storage('tbl_lua_code_storage');
select make_stored_fn('Lua', '
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
select L('
    local increment_w = function(a)
        return a + 1
    end
    create_function("inc", increment_w, 1)
');

select make_stored_chk('inc_c', 'return arg[1] + 1', 1);
select make_stored_chk('error_inc_c', 'return arg[1][1] + 1', 1);

select inc(12);
select make_stored_int('const_x', 9999);
select const_x();
select L('
make_stored_int("const_x2", 10000)
');
select const_x2();


select L('run_sql[[
          CREATE TABLE numbers(num1,num2);
          INSERT INTO numbers VALUES(1,11);
          INSERT INTO numbers VALUES(2,22);
          INSERT INTO numbers VALUES(3,33);
        ]]
');

select L('
_G.pprint_table = function (tbl, indent)
    indent = indent or 0
    local keys = {}
    for k, _ in pairs(tbl) do
        table.insert(keys, k)
    end
    table.sort(keys)

    for _, k in ipairs(keys) do
        local v = tbl[k]
        if type(v) == "table" then
            print(string.rep(" ", indent) .. tostring(k) .. " = {")
            pprint_table(v, indent + 4)
            print(string.rep(" ", indent) .. "}")
        else
            print(string.rep(" ", indent) .. tostring(k) .. " = " .. tostring(v))
        end
    end
end
');

select L('
for a in rows("SELECT * FROM numbers") do pprint_table(a) end
');

select L('
for a in nrows("SELECT * FROM numbers") do pprint_table(a) end
');

select L('
for num1, num2 in urows("SELECT * FROM numbers") do print(num1,num2) end
');
