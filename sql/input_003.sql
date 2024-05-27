select load_extension('./libsqlite_plugin_lj');
select use_function_storage('tbl_lua_code_storage');
select echo1('expect error :function not found');
select inc(16) -1;
select make_stored_fn('echo11', 'return1 function(a) return "echo ["..tostring(a) .."]" end', 1);
select inc(17) -1;
select make_stored_fn('echo1', 'return function(a) return "echo ["..tostring(a) .."]" end', 1);
select echo1('tyu');
select L('
    local test3 = function(a,b,c)
        return("a ".. tostring(a) .. " b ".. tostring(b) .. " c ".. tostring(c) )
    end
    create_function("getV3", test3, 3)
');

select getV3('qwe', 'asd', 'zxc');
select make_stored_fn('echo2', 'return function(a) return tostring(a) .. tostring(a) end');
select echo2('tyu');
select('-------------');
CREATE TABLE data(val NUMERIC);
INSERT INTO data(val) VALUES (5), (7), (9);

select L('
    local avgCoroutine = function ()
        local acc = 0
        local n = 0
        while true do
            local has_next, value = coroutine.yield()  -- Receive values from the producer
            if has_next then
                acc = acc + value
                n = n + 1
            else
                acc = tonumber(acc) * (1/n)
                break  -- Break the loop when no more data is available
            end
        end
        return acc
    end

    create_function_agg_coro("agg_avg_coro", avgCoroutine, 1)


    create_function_agg_chk("agg_avg_chk",
        "acc = 0; n = 0;",
        "n = n + 1; acc = acc + tonumber(arg[1]);",
        "return acc * (1/n);",
        1)
');

SELECT agg_avg_coro(val), avg(val) FROM data;
SELECT agg_avg_chk(val), avg(val) FROM data;
select L('config["use_traceback"] = 0');
select error_inc_c(18) -1;
select inc_c(18) -1;