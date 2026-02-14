select load_extension('./libsqlite_plugin_lj');

CREATE TABLE agg_err_data(v NUMERIC);
INSERT INTO agg_err_data(v) VALUES (1), (2);

select('--- coroutine aggregate error propagation ---');

select L('
    sqlite.create_function_agg_coro_text("agg_init_error", [[
        return function ()
            error("initialization error")
        end
    ]], 1)
');

select L('
    local ok, res = pcall(function()
        return sqlite.fetch_first("SELECT agg_init_error(v) AS s FROM agg_err_data")
    end)
    if ok then
        local s = tostring(res.s)
        if s:match("dead coroutine") then
            return "ISSUE:init:resume-error-returned-as-value"
        else
            return "ISSUE:init:unexpected:" .. s
        end
    else
        return "OK:init:query-failed"
    end
');

select L('
    sqlite.create_function_agg_coro_text("agg_step_error", [[
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
    local ok, res = pcall(function()
        return sqlite.fetch_first("SELECT agg_step_error(v) AS s FROM agg_err_data")
    end)
    if ok then
        local s = tostring(res.s)
        if s:match("dead coroutine") then
            return "ISSUE:step:resume-error-returned-as-value"
        else
            return "ISSUE:step:unexpected:" .. s
        end
    else
        return "OK:step:query-failed"
    end
');

select L('
    sqlite.create_function_agg_coro_text("agg_final_error", [[
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
    local ok, res = pcall(function()
        return sqlite.fetch_first("SELECT agg_final_error(v) AS s FROM agg_err_data")
    end)
    if ok then
        local s = tostring(res.s)
        if s:match("finalization error") then
            return "ISSUE:final:error-text-returned-as-value"
        else
            return "ISSUE:final:unexpected:" .. s
        end
    else
        return "OK:final:query-failed"
    end
');
