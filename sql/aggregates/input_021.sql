select load_extension('./libsqlite_plugin_lj');

CREATE TABLE agg_err_data_future(v NUMERIC);
INSERT INTO agg_err_data_future(v) VALUES (1), (2);

select('--- coroutine aggregate error propagation expected ---');

select L('
    sqlite.create_function_agg_coro_text("agg_init_error_future", [[
        return function ()
            error("initialization error")
        end
    ]], 1)
');

select L('
    local ok, _ = pcall(function()
        return sqlite.fetch_first("SELECT agg_init_error_future(v) AS s FROM agg_err_data_future")
    end)
    if ok then
        return "ISSUE:init:query-succeeded"
    else
        return "OK:init:query-failed"
    end
');

select L('
    sqlite.create_function_agg_coro_text("agg_step_error_future", [[
        return function ()
            while true do
                local has_next, value = coroutine.yield()
                if has_next then
                    error("step error")
                else
                    return 0
                end
            end
        end
    ]], 1)
');

select L('
    local ok, _ = pcall(function()
        return sqlite.fetch_first("SELECT agg_step_error_future(v) AS s FROM agg_err_data_future")
    end)
    if ok then
        return "ISSUE:step:query-succeeded"
    else
        return "OK:step:query-failed"
    end
');

select L('
    sqlite.create_function_agg_coro_text("agg_final_error_future", [[
        return function ()
            local acc = 0
            while true do
                local has_next, value = coroutine.yield()
                if has_next then
                    acc = acc + value
                else
                    error("finalization error")
                end
            end
        end
    ]], 1)
');

select L('
    local ok, _ = pcall(function()
        return sqlite.fetch_first("SELECT agg_final_error_future(v) AS s FROM agg_err_data_future")
    end)
    if ok then
        return "ISSUE:final:query-succeeded"
    else
        return "OK:final:query-failed"
    end
');
