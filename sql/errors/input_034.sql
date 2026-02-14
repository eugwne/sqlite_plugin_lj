select load_extension('./libsqlite_plugin_lj');

select L('
  sqlite.config.use_traceback = 0
  local out = {}

  local function expect_error(label, fn, pattern)
    local ok, err = pcall(fn)
    local text = tostring(err)
    if (not ok) and text:match(pattern) then
      out[#out + 1] = "PASS " .. label
    else
      out[#out + 1] = "FAIL " .. label
      if ok then
        out[#out + 1] = "DETAIL:" .. label .. ":unexpected success"
      else
        out[#out + 1] = "DETAIL:" .. label .. ":" .. text
      end
    end
  end

  -- Test 1: L vtable with code that errors on xFilter (bad Lua code)
  expect_error("L xFilter syntax error", function()
    for row in sqlite.nrows("SELECT * FROM L(''return (('')") do end
  end, "Create temporary function failed")

  -- Test 2: L vtable with iterator function that errors mid-iteration
  expect_error("L xNext runtime error", function()
    local code = "local i = 0; return function() i = i + 1; if i == 1 then return 1 end; if i == 2 then error(\"deliberate iteration error\") end; return nil end"
    local sql = "SELECT * FROM L(''" .. code .. "'')"
    local results = {}
    for row in sqlite.nrows(sql) do
      results[#results + 1] = row
    end
  end, "deliberate iteration error")

  -- Test 3: L vtable with code that errors immediately (runtime error in xFilter)
  expect_error("L xFilter runtime error", function()
    for row in sqlite.nrows("SELECT * FROM L(''error(\"immediate xFilter fail\")'')") do end
  end, "immediate xFilter fail")

  -- Test 4: L10 with bad Lua code
  expect_error("L10 xFilter syntax error", function()
    for row in sqlite.nrows("SELECT * FROM L10(''return (('')") do end
  end, "Create temporary function failed")

  return table.concat(out, "\n")
');
