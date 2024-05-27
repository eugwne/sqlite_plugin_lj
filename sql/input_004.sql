select load_extension('./libsqlite_plugin_lj');
select use_function_storage('tbl_lua_code_storage');
CREATE TABLE data4(val NUMERIC);
INSERT INTO data4(val) VALUES (5), (7), (9);
select('-------------');

select inc_c(18) -1;
select make_stored_agg3('sum_ac', 'n = 0', 'n = n + arg[1]', 'return n', 1);
SELECT sum_ac(val), sum(val) FROM data4;
select make_stored_aggc('sum_a', 
'return function ()
        local acc = 0
        local n = 0
        while true do
            local has_next, value = coroutine.yield() 
            if has_next then
                acc = acc + value
                n = n + 1
            else
                break 
            end
        end
        return acc
    end', 1);
SELECT sum_a(val), sum(val) FROM data4;
select inc_c(19) -1;
select make_stored_agg3('sum_error', 'n = 0', 'n = n[1] + arg[1]', 'return n', 1);
SELECT sum_error(val), sum(val) FROM data4;
select inc_c(20) -1;

select make_stored_fn('rs2', '
return function ()
        run_sql(''create table test_table2(value)'');
        run_sql(''INSERT INTO test_table2(value) VALUES (8), (10), (12);'')
        for row in nrows(''select * from test_table2 where value < ?'', {11}) do
            local test_row = ''''
            for k,v in pairs(row) do
                test_row = test_row .. '' | ['' .. (k) .. ''] '' .. tostring(v)
            end
            print(test_row)
        end
        --[[
        for row in nrows(''select name, file from PRAGMA_database_list;'') do
            local test_row = ''''
            for _,v in ipairs({''name'', ''file''}) do
                test_row = test_row .. '' | ['' .. (v) .. ''] '' .. tostring(row[v])
            end
            print(test_row)
        end
                ]]
        local database_list = fetch_all(''select * from PRAGMA_database_list;'')
        print(type(database_list))

    end
');
select rs2();