select load_extension('./libsqlite_plugin_lj');

select('--- malformed lua handling ---');

select L('
    sqlite.config.use_traceback = 0
    local out = {}

    local function expect_error(label, fn, pattern)
        local _, res = pcall(fn)
        local text = tostring(res)
        if text:match(pattern) then
            out[#out + 1] = "PASS:" .. label
        else
            out[#out + 1] = "FAIL:" .. label
            out[#out + 1] = "DETAIL:" .. label .. ":" .. text
        end
    end

    expect_error("L", function()
        return sqlite.fetch_first([[SELECT L(''return ('') AS v]])
    end, "Create failed %[temp_fn%]")

    expect_error("L10", function()
        return sqlite.fetch_all([[SELECT * FROM L10(''return function('')]])
    end, "Create temporary function failed")

    expect_error("make_fn", function()
        return sqlite.make_fn("bad_fn", "return function(a) return (a + ) end", 1)
    end, "Create failed %[bad_fn%]")

    expect_error("make_chk", function()
        return sqlite.make_chk("bad_chk", "return (arg[1] + )", 1)
    end, "Create failed %[bad_chk%]")

    expect_error("make_stored_agg3:init", function()
        return sqlite.make_function_agg_chk("bad_agg3_init", "n =", "n = n + arg[1]", "return n", 1)
    end, "bad_agg3_init:init")

    expect_error("make_stored_agg3:step", function()
        return sqlite.make_function_agg_chk("bad_agg3_step", "n = 0", "n = n +", "return n", 1)
    end, "bad_agg3_step:step")

    expect_error("make_stored_agg3:final", function()
        return sqlite.make_function_agg_chk("bad_agg3_final", "n = 0", "n = n + arg[1]", "return n +", 1)
    end, "bad_agg3_final:final")

    expect_error("make_stored_aggc:code", function()
        return sqlite.create_function_agg_coro_text("bad_aggc", "return function() local x = 1 + end", 1)
    end, "Create failed %[bad_aggc%]")

    expect_error("make_stored_win:init", function()
        return sqlite.create_function_agg_chk_window("bad_win_init", "n =", "n = n + arg[1]", "return n", 1)
    end, "bad_win_init:init")

    expect_error("make_stored_win:step", function()
        return sqlite.create_function_agg_chk_window("bad_win_step", "n = 0", "n = n +", "return n", 1)
    end, "bad_win_step:step")

    expect_error("make_stored_win:final", function()
        return sqlite.create_function_agg_chk_window("bad_win_final", "n = 0", "n = n + arg[1]", "return n +", 1)
    end, "bad_win_final:final")

    expect_error("make_stored_win:inverse", function()
        return sqlite.create_function_agg_chk_window("bad_win_inverse", "n = 0", "n = n + arg[1]", "n = n -", "return n", 1)
    end, "bad_win_inverse:inverse")

    return table.concat(out, "\n")
');
