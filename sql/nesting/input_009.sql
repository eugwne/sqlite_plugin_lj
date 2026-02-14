select load_extension('./libsqlite_plugin_lj');
select('-------------');
select L('
    sqlite.register_internal_function("make_fn")
    sqlite.run_sql[[
    CREATE TABLE numbers009(num1,num2);
    INSERT INTO numbers009 VALUES(1,11);
    INSERT INTO numbers009 VALUES(2,22);
    INSERT INTO numbers009 VALUES(3,33);
]]
');

select make_fn('fib', '
return function (value)
    if (value <= 1) then
        return value
    end
    local value1 = sqlite.fetch_first("select fib(?) as f", {value - 1})["f"]
    local value2 = sqlite.fetch_first("select fib(?) as f", {value - 2})["f"]
    return value1 + value2;
end
');

select L('
local res = sqlite.fetch_first("select fib(10) as result");
return tostring(res["result"])
');
select fib(10);


-- select L('
-- error("test error")
-- ');

select L('
    sqlite.config.use_traceback = 0

    local fib2 = function (value)
        if (value <= 1) then
            return value
        end

        local value1 = sqlite.fetch_first("select fib2(?) as f", {value - 1})["f"]
        local value2 = sqlite.fetch_first("select fib(?) as f", {value - 2})["f"]
        return value1 + value2;
    end

    sqlite.create_function("fib2", fib2, 1)
');

-- Test that closure-based function fails in nested call (expected behavior)
select L('
    local ok, err = pcall(function()
        return sqlite.fetch_first("select fib2(2)")
    end)
    if not ok and tostring(err):match("max call depth") then
        return "PASS: fib2 correctly rejected nested closure call"
    else
        return "FAIL: fib2 expected max call depth error, got: " .. tostring(ok) .. " " .. tostring(err)
    end
');

-- check close of unfinalized statements in nested calls

select L('
    local sub3 = function()
        for value in sqlite.urows("select num2 from numbers009") do
            return tonumber(value)
            -- urows in unfinalized_statements
        end
    end
    sqlite.create_function("sub3", sub3, 0)
');

select L('
    local sub4 = function()
        for value in sqlite.urows("select sub3() from numbers009") do
            return tonumber(value)
            -- urows in unfinalized_statements
        end
    end
    sqlite.create_function("sub4", sub4, 0)
');

-- Test that nested closure calls fail (expected behavior)
select L('
    local ok, err = pcall(function()
        sqlite.fetch_first("select sub4()")
    end)
    if not ok and tostring(err):match("max call depth") then
        return "PASS: sub4 correctly rejected nested closure call"
    else
        return "FAIL: expected max call depth error, got: " .. tostring(ok) .. " " .. tostring(err)
    end
');

-- Test nested aggregate (create_function_agg_chk)
select L('
    sqlite.create_function_agg_chk("nested_sum", "n = 0", "n = n + arg[1]", "return n", 1)
');

-- Direct call
select nested_sum(num1) from numbers009;

-- Nested call from L()
select L('
    local result = sqlite.fetch_first("SELECT nested_sum(num1) as s FROM numbers009")
    return result["s"]
');
