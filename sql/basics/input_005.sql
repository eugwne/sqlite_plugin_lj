select load_extension('./libsqlite_plugin_lj');

select('-------------');

select L('
    sqlite.register_internal_function("make_fn")
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


select L('return arg[1] + arg[2]', 12, 24), Lua('return arg[1]', 15, 24), L('return arg[2]', 12, 27);
--select L('print (int64_t(1))');
--SELECT * FROM sqlite_master;-- WHERE type='table';
select L('
    sqlite.run_sql("DROP TABLE IF EXISTS TEMP.table_x")
    local data_vt = {columns = {"a", "b", "c"},  rows = {[0] = {1,2}, {3,4}, a = {5,8}}}
    sqlite.make_vtable("table_x", data_vt)
 ');

select * from table_x o1
inner join table_x o2 on o1.a = o2.a 
where o1.b > 2;

select L('
    sqlite.run_sql("DROP TABLE IF EXISTS TEMP.table_a")
    sqlite.make_vtable("table_a",
        {
            columns = {"a", "b", "c"}, 
            rows = {{1,2}, {3,4}, {5,8}, {9, 10}}
        }
    )
 ');

 select * from table_a o1;

-- Test: query the same vtable twice (separate queries)
select('--- query same vtable twice ---');
select * from table_a;
select * from table_a where a > 1;

-- Test: join two different vtables
select('--- join two different vtables ---');
select L('
    sqlite.run_sql("DROP TABLE IF EXISTS TEMP.table_b")
    sqlite.make_vtable("table_b",
        {
            columns = {"x", "y"},
            rows = {{1, "one"}, {3, "three"}, {5, "five"}}
        }
    )
 ');

select table_a.a, table_a.b, table_b.x, table_b.y
from table_a
inner join table_b on table_a.a = table_b.x;
