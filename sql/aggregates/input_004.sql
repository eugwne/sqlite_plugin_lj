select load_extension('./libsqlite_plugin_lj');

CREATE TABLE data4(val NUMERIC);
INSERT INTO data4(val) VALUES (5), (7), (9);
select('-------------');
SELECT L('
    local sqlite = sqlite
    sqlite.create_function("make_stored_agg3", sqlite.make_function_agg_chk, -1)
    sqlite.create_function("make_stored_aggc", sqlite.create_function_agg_coro_text, -1)
');
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

select make_stored_agg3('sum_error', 'n = 0', 'n = n[1] + arg[1]', 'return n', 1);
select L('
    sqlite.config.use_traceback = 0
    local ok, err = pcall(function()
        return sqlite.fetch_first("SELECT sum_error(val) FROM data4")
    end)
    if not ok and tostring(err):match("attempt to index") then
        return "PASS: sum_error correctly reported indexing error"
    else
        return "FAIL: expected indexing error, got: " .. tostring(ok) .. " " .. tostring(err)
    end
');

select L('
    sqlite.config.use_traceback = 0
    local ok, err = pcall(function()
        return sqlite.fetch_all([[select * from L(''return ter{1,2,NULL,3}'')]])
    end)
    if not ok and tostring(err):match("attempt to call global ''ter''") then
        return "PASS: L table reports missing function error"
    else
        return "FAIL: expected missing function error, got: " .. tostring(ok) .. " " .. tostring(err)
    end
');

select L('
    local sqlite = sqlite
    local fn = function(name, text_code, argc)
        sqlite.make_fn(name, text_code, argc)
    end
    sqlite.create_function("make_fn", fn, -1)
');

select make_fn('rs2', '
local sqlite = sqlite
return function ()
        local out = {}
        sqlite.run_sql(''create table test_table2(value)'');
        sqlite.run_sql(''INSERT INTO test_table2(value) VALUES (8), (10), (12);'')
        for row in sqlite.nrows(''select * from test_table2 where value < ?'', {11}) do
            local test_row = ''''
            for k,v in pairs(row) do
                test_row = test_row .. '' | ['' .. (k) .. ''] '' .. tostring(v)
            end
            out[#out + 1] = test_row
        end
        --[[
        for row in sqlite.nrows(''select name, file from PRAGMA_database_list;'') do
            local test_row = ''''
            for _,v in ipairs({''name'', ''file''}) do
                test_row = test_row .. '' | ['' .. (v) .. ''] '' .. tostring(row[v])
            end
            out[#out + 1] = test_row
        end
                ]]
        local database_list = sqlite.fetch_all(''select * from PRAGMA_database_list;'')
        out[#out + 1] = type(database_list)
        return table.concat(out, "\n")
    end
');
select rs2();
