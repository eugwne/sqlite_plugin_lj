select load_extension('./libsqlite_plugin_lj');

select('-------------');
CREATE TABLE data(val NUMERIC);
INSERT INTO data(val) VALUES (5), (7), (9);

select L('
    local sqlite = require("sqlite_lj")
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

    sqlite.create_function_agg_coro("agg_avg_coro", avgCoroutine, 1)


    sqlite.create_function_agg_chk("agg_avg_chk",
        "acc = 0; n = 0;",
        "n = n + 1; acc = acc + tonumber(arg[1]);",
        "return acc * (1/n);",
        1)
');

SELECT agg_avg_coro(val), avg(val) FROM data;
SELECT agg_avg_chk(val), avg(val) FROM data;
