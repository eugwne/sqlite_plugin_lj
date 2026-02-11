select load_extension('./libsqlite_plugin_lj');

select('-------------');
CREATE TABLE data(val NUMERIC);
INSERT INTO data(val) VALUES (5), (7), (9);

select L('

    local avgCoroutine = [[ return function ()
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
    end ]]

    sqlite.create_function_agg_coro_text("agg_avg_coro", avgCoroutine, 1)


    sqlite.create_function_agg_chk("agg_avg_chk",
        "acc = 0; n = 0;",
        "n = n + 1; acc = acc + tonumber(arg[1]);",
        "return acc * (1/n);",
        1)

    sqlite.create_function_agg_chk("agg_avg_chk2",
        "acc = 0; n = 0;",
        "n = n + 1; acc = acc + tonumber(arg[1]) + tonumber(arg[2]);",
        "return acc * (1/n);",
        2)
');

SELECT agg_avg_coro(val), avg(val) FROM data;
SELECT agg_avg_chk(val), avg(val) FROM data;
SELECT agg_avg_chk2(val, 1), avg(val) + 1 FROM data;

select L('
    local out = {}
    for value in sqlite.urows("SELECT agg_avg_coro(val), avg(val) FROM data") do
        out[#out + 1] = tostring(tonumber(value))
    end
    for value in sqlite.urows("SELECT agg_avg_chk(val), avg(val) FROM data") do
        out[#out + 1] = tostring(tonumber(value))
    end
    return table.concat(out, "\n")
');

-- Test aggregates on empty table
select('--- empty table aggregates ---');
CREATE TABLE empty_data(val NUMERIC);

select L('
    sqlite.create_function_agg_chk("sum_chk", "n = 0", "n = n + arg[1]", "return n", 1)
    sqlite.create_function_agg_chk("sum_chk2", "n = 0", "n = n + arg[1] + arg[2]", "return n", 2)

    sqlite.create_function_agg_coro_text("sum_coro", [[ return function()
        local acc = 0
        while true do
            local has_next, value = coroutine.yield()
            if has_next then
                acc = acc + value
            else
                break
            end
        end
        return acc
    end ]], 1)
');

SELECT sum_chk(val), sum_coro(val), sum(val) FROM empty_data;
SELECT sum_chk2(val, 10) FROM empty_data;
SELECT sum_chk(val), sum_coro(val), sum(val) FROM data;
SELECT sum_chk2(val, 10), sum(val) + count(*) * 10 FROM data;

-- Test window functions
select('--- window functions ---');
CREATE TABLE win_data(x INT, cat TEXT);
INSERT INTO win_data VALUES (1,'A'), (2,'A'), (3,'B'), (4,'A'), (5,'B');

select L('
    sqlite.create_function_agg_chk_window("win_sum", "n = 0", "n = n + arg[1]", "return n", 1)
    sqlite.create_function_agg_chk_window("win_sum2", "n = 0", "n = n + arg[1] + arg[2]", "return n", 2)
');

-- As regular aggregate (GROUP BY)
SELECT cat, win_sum(x) FROM win_data GROUP BY cat;
SELECT cat, win_sum2(x, 10) FROM win_data GROUP BY cat;

-- As window function (PARTITION BY)
SELECT x, cat, win_sum(x) OVER (PARTITION BY cat ORDER BY x) FROM win_data ORDER BY cat, x;
SELECT x, cat, win_sum2(x, 10) OVER (PARTITION BY cat ORDER BY x) FROM win_data ORDER BY cat, x;

-- As window function (ORDER BY only - running total)
SELECT x, win_sum(x) OVER (ORDER BY x) FROM win_data;
SELECT x, win_sum2(x, 10) OVER (ORDER BY x) FROM win_data;

-- Test sliding window error (no inverse provided)
select('--- sliding window error ---');
select L('
    local ok, err = pcall(function()
        for row in sqlite.rows("SELECT x, win_sum(x) OVER (ORDER BY x ROWS BETWEEN 1 PRECEDING AND CURRENT ROW) FROM win_data") do
        end
    end)
    if not ok and err:find("sliding windows not supported") then
        return "error caught: sliding windows not supported"
    end
    return "error not caught"
');

-- Test sliding window with inverse (5-arg version)
select('--- sliding window with inverse ---');
select L('
    sqlite.create_function_agg_chk_window("win_sum_inv", "n = 0", "n = n + arg[1]", "n = n - arg[1]", "return n", 1)
    sqlite.create_function_agg_chk_window("win_sum_inv2", "n = 0", "n = n + arg[1] + arg[2]", "n = n - arg[1] - arg[2]", "return n", 2)
');

SELECT x, win_sum_inv(x) OVER (ORDER BY x ROWS BETWEEN 1 PRECEDING AND CURRENT ROW) FROM win_data;
SELECT x, win_sum_inv2(x, 10) OVER (ORDER BY x ROWS BETWEEN 1 PRECEDING AND CURRENT ROW) FROM win_data;

-- Test nested aggregate call
select('--- nested aggregate ---');
select L('
    sqlite.create_function_agg_chk("nested_sum", "n = 0", "n = n + arg[1]", "return n", 1)
');

select L('
    local result = sqlite.fetch_first("SELECT nested_sum(val) as s FROM data")
    return result["s"]
');
