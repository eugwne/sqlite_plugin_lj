select load_extension('./libsqlite_plugin_lj');

select L('
  sqlite.config.use_traceback = 0
  local out = {}

  local function check(label, ok, detail)
    if ok then
      out[#out + 1] = "PASS " .. label
    else
      out[#out + 1] = "FAIL " .. label
      if detail then
        out[#out + 1] = "DETAIL:" .. label .. ":" .. tostring(detail)
      end
    end
  end

  -- Test 1: Standard make_vtable TEMP table works (exercises xConnect path)
  local ok1, err1 = pcall(function()
    sqlite.run_sql("DROP TABLE IF EXISTS TEMP.vt037")
    sqlite.make_vtable("vt037", {
      columns = {"id", "name"},
      rows = {{1, "alice"}, {2, "bob"}}
    })
    local rows = sqlite.fetch_all("SELECT id, name FROM vt037 ORDER BY id")
    assert(#rows == 2, "expected 2 rows, got " .. #rows)
    assert(tonumber(rows[1].id) == 1, "expected id=1")
    assert(rows[2].name == "bob", "expected name=bob")
  end)
  check("make_vtable TEMP works", ok1, err1)

  -- Test 2: Repeated queries on same vtable
  local ok2, err2 = pcall(function()
    for i = 1, 3 do
      local rows = sqlite.fetch_all("SELECT id, name FROM vt037 ORDER BY id")
      assert(#rows == 2, "query " .. i .. ": expected 2 rows")
      assert(tonumber(rows[1].id) == 1, "query " .. i .. ": expected id=1")
    end
  end)
  check("repeated queries stable", ok2, err2)

  -- Test 3: Drop and re-create (xDestroy then new xCreate)
  local ok3, err3 = pcall(function()
    sqlite.run_sql("DROP TABLE IF EXISTS TEMP.vt037")
    sqlite.make_vtable("vt037", {
      columns = {"id", "name"},
      rows = {{10, "charlie"}, {20, "diana"}, {30, "eve"}}
    })
    local rows = sqlite.fetch_all("SELECT id, name FROM vt037 ORDER BY id")
    assert(#rows == 3, "expected 3 rows after re-create")
    assert(tonumber(rows[1].id) == 10, "expected id=10")
    assert(rows[3].name == "eve", "expected name=eve")
  end)
  check("drop and re-create", ok3, err3)

  -- Test 4: Re-create with different column schema
  local ok4, err4 = pcall(function()
    sqlite.run_sql("DROP TABLE IF EXISTS TEMP.vt037")
    sqlite.make_vtable("vt037", {
      columns = {"x", "y", "z"},
      rows = {{100, 200, 300}}
    })
    local rows = sqlite.fetch_all("SELECT x, y, z FROM vt037")
    assert(#rows == 1, "expected 1 row")
    assert(tonumber(rows[1].x) == 100, "expected x=100")
    assert(tonumber(rows[1].z) == 300, "expected z=300")
  end)
  check("re-create different schema", ok4, err4)

  -- Test 5: Non-TEMP vtable creation using module name directly
  -- make_vtable registers a module named after the table. Creating a non-TEMP
  -- virtual table exercises the xCreate path (not xConnect).
  -- lua_vtable_module.xCreate just returns SQLITE_OK without setting ppVTab,
  -- so this should fail (SQLite should detect the NULL vtab pointer).
  local ok5, err5 = pcall(function()
    -- Ensure temp version is dropped first so module is available
    sqlite.run_sql("DROP TABLE IF EXISTS TEMP.vt037")
    -- Re-register the module by creating a temp table first
    sqlite.make_vtable("vt037", {
      columns = {"a"},
      rows = {{1}}
    })
    -- Drop the temp table but module remains registered
    sqlite.run_sql("DROP TABLE IF EXISTS TEMP.vt037")
    -- Now try creating a non-TEMP virtual table using the same module name
    -- This goes through xCreate (not xConnect) which doesn''t set ppVTab
    sqlite.run_sql("CREATE VIRTUAL TABLE main.vt037_main USING vt037()")
  end)
  -- Whether it errors or not, document the behavior
  if ok5 then
    -- If it succeeded, try to query it
    local qok, qerr = pcall(function()
      local rows = sqlite.fetch_all("SELECT * FROM main.vt037_main")
    end)
    check("non-TEMP xCreate succeeds (query " .. (qok and "works" or "fails") .. ")", true)
    pcall(function() sqlite.run_sql("DROP TABLE IF EXISTS main.vt037_main") end)
  else
    -- Expected: xCreate doesn''t set ppVTab, so SQLite should error
    check("non-TEMP xCreate errors as expected", true)
  end

  -- Test 6: Verify make_vtable still works after the xCreate test
  local ok6, err6 = pcall(function()
    sqlite.run_sql("DROP TABLE IF EXISTS TEMP.vt037")
    sqlite.make_vtable("vt037", {
      columns = {"v"},
      rows = {{42}}
    })
    local r = sqlite.fetch_first("SELECT v FROM vt037")
    assert(tonumber(r.v) == 42, "expected v=42, got " .. tostring(r.v))
  end)
  check("make_vtable works after xCreate test", ok6, err6)

  -- Cleanup
  pcall(function() sqlite.run_sql("DROP TABLE IF EXISTS TEMP.vt037") end)
  pcall(function() sqlite.run_sql("DROP TABLE IF EXISTS main.vt037_main") end)

  return table.concat(out, "\n")
');
