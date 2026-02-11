select load_extension('./libsqlite_plugin_lj');

-- Init list_iterator in vtable_vm scope
SELECT * FROM L('
    _G.list_iterator = function(t)
      local i = 0
      local n = #t
      return function ()
               i = i + 1
               if i <= n then return t[i] end
             end
    end
    return function() return nil end
');

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

  -- Setup: create a regular table to JOIN with
  sqlite.run_sql("CREATE TABLE IF NOT EXISTS t035(id INTEGER PRIMARY KEY, val TEXT)")
  sqlite.run_sql("DELETE FROM t035")
  sqlite.run_sql("INSERT INTO t035 VALUES(1, ''alpha'')")
  sqlite.run_sql("INSERT INTO t035 VALUES(2, ''beta'')")
  sqlite.run_sql("INSERT INTO t035 VALUES(3, ''gamma'')")

  -- Test 1: Baseline - simple L10 query (no join, single constraint)
  local ok1, err1 = pcall(function()
    local rows = sqlite.fetch_all("SELECT r0, r1 FROM L10(''return list_iterator({{10, 20}, {30, 40}})'') ")
    assert(#rows == 2, "expected 2 rows, got " .. #rows)
    assert(tonumber(rows[1].r0) == 10, "expected r0=10, got " .. tostring(rows[1].r0))
    assert(tonumber(rows[2].r1) == 40, "expected r1=40, got " .. tostring(rows[2].r1))
  end)
  check("L10 baseline no join", ok1, err1)

  -- Test 2: JOIN L10 with regular table + WHERE on L10 column
  -- This creates non-usable constraints from the join condition
  local ok2, err2 = pcall(function()
    local sql = "SELECT t.id, t.val, v.r0, v.r1 FROM t035 t JOIN L10(''return list_iterator({{1, \"x\"}, {2, \"y\"}, {3, \"z\"}})'') v ON t.id = v.r0 ORDER BY t.id"
    local rows = sqlite.fetch_all(sql)
    assert(#rows == 3, "expected 3 rows, got " .. #rows)
    assert(tonumber(rows[1].id) == 1, "expected id=1")
    assert(rows[1].r1 == "x", "expected r1=x, got " .. tostring(rows[1].r1))
    assert(tonumber(rows[3].id) == 3, "expected id=3")
    assert(rows[3].r1 == "z", "expected r1=z, got " .. tostring(rows[3].r1))
  end)
  check("L10 JOIN regular table", ok2, err2)

  -- Test 3: JOIN L (single-column) with regular table
  local ok3, err3 = pcall(function()
    local sql = "SELECT t.id, t.val, v.value FROM t035 t JOIN L(''return list_iterator({1, 2, 3})'') v ON t.id = v.value ORDER BY t.id"
    local rows = sqlite.fetch_all(sql)
    assert(#rows == 3, "expected 3 rows, got " .. #rows)
    assert(tonumber(rows[1].value) == 1, "expected value=1")
    assert(rows[2].val == "beta", "expected val=beta")
  end)
  check("L JOIN regular table", ok3, err3)

  -- Test 4: LEFT JOIN with L10 as right side
  local ok4, err4 = pcall(function()
    local sql = "SELECT t.id, v.r0 FROM t035 t LEFT JOIN L10(''return list_iterator({{1, \"match\"}})'') v ON t.id = v.r0 ORDER BY t.id"
    local rows = sqlite.fetch_all(sql)
    assert(#rows == 3, "expected 3 rows, got " .. #rows)
    assert(tonumber(rows[1].r0) == 1, "expected r0=1 for id=1")
    assert(rows[2].r0 == nil or rows[2].r0 == "" or rows[2].r0 == NULL, "expected NULL r0 for id=2")
  end)
  check("L10 LEFT JOIN", ok4, err4)

  -- Test 5: Subquery with IN (SELECT ... FROM L10)
  local ok5, err5 = pcall(function()
    local sql = "SELECT id, val FROM t035 WHERE id IN (SELECT r0 FROM L10(''return list_iterator({{1}, {3}})'')) ORDER BY id"
    local rows = sqlite.fetch_all(sql)
    assert(#rows == 2, "expected 2 rows, got " .. #rows)
    assert(tonumber(rows[1].id) == 1, "expected id=1")
    assert(tonumber(rows[2].id) == 3, "expected id=3")
  end)
  check("L10 IN subquery", ok5, err5)

  -- Cleanup
  sqlite.run_sql("DROP TABLE IF EXISTS t035")

  return table.concat(out, "\n")
');
