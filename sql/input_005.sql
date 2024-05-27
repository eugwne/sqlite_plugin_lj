select load_extension('./libsqlite_plugin_lj');
select use_function_storage('tbl_lua_code_storage');
select('-------------');


select L('return arg[1] + arg[2]', 12, 24), Lua('return arg[1]', 15, 24), L('return arg[2]', 12, 27);
--select L('print (int64_t(1))');
--SELECT * FROM sqlite_master;-- WHERE type='table';
select L('
    run_sql("DROP TABLE IF EXISTS TEMP.table_x")
    local data_vt = {columns = {"a", "b", "c"},  rows = {[0] = {1,2}, {3,4}, a = {5,8}}}
    make_vtable("table_x", data_vt)
 ');

select * from table_x o1
inner join table_x o2 on o1.a = o2.a 
where o1.b > 2;

select L('
    run_sql("DROP TABLE IF EXISTS TEMP.table_a")
    make_vtable("table_a",
        {
            columns = {"a", "b", "c"}, 
            rows = {{1,2}, {3,4}, {5,8}, {9, 10}}
        }
    )
 ');

 select * from table_a o1;


