.load ./libsqlite_plugin_lj
select L('
  sqlite.config.use_traceback = 0
  local out = {}

  local function expect_fail(name, fn, pat)
    local ok, err = pcall(fn)
    local matched = (not ok) and tostring(err):match(pat)
    out[#out + 1] = (matched and "PASS " or "FAIL ") .. name
  end

  local function expect_ok(name, fn)
    local ok = pcall(fn)
    out[#out + 1] = (ok and "PASS " or "FAIL ") .. name
  end

  expect_ok("rows nil means empty table", function()
    sqlite.run_sql("DROP TABLE IF EXISTS TEMP.rows_nil")
    sqlite.make_vtable("rows_nil", { columns = {"a"}, rows = nil })
    local r = sqlite.fetch_first("select count(*) as c from rows_nil")
    assert(r and tonumber(r.c) == 0)
  end)

  expect_ok("rows empty means empty table", function()
    sqlite.run_sql("DROP TABLE IF EXISTS TEMP.rows_empty")
    sqlite.make_vtable("rows_empty", { columns = {"a"}, rows = {} })
    local r = sqlite.fetch_first("select count(*) as c from rows_empty")
    assert(r and tonumber(r.c) == 0)
  end)

  expect_ok("rows table-empty-row gives null row", function()
    sqlite.run_sql("DROP TABLE IF EXISTS TEMP.rows_null")
    sqlite.make_vtable("rows_null", { columns = {"a", "b"}, rows = {{}} })
    local r = sqlite.fetch_first("select count(*) as c from rows_null where a is null and b is null")
    assert(r and tonumber(r.c) == 1)
  end)

  expect_fail("duplicate columns", function()
    sqlite.make_vtable("dup_cols", {
      columns = {"a", "A"},
      rows = {{1, 2}}
    })
  end, "duplicate column name")

  expect_fail("rows must be table", function()
    sqlite.make_vtable("bad_rows", {
      columns = {"a"},
      rows = 1
    })
  end, "rows must be a table")

  expect_ok("extra row values ignored", function()
    sqlite.run_sql("DROP TABLE IF EXISTS TEMP.wide_rows")
    sqlite.make_vtable("wide_rows", {
      columns = {"a"},
      rows = {{1, 2}}
    })
    local r = sqlite.fetch_first("select a from wide_rows")
    assert(r and tonumber(r.a) == 1)
  end)

  expect_ok("garbage rows skipped", function()
    sqlite.make_vtable("flat_rows", {
      columns = {"a", "b"},
      rows = {1, 2}
    })
    local r = sqlite.fetch_first("select count(*) as c from flat_rows")
    assert(r and tonumber(r.c) == 0)
  end)

  return table.concat(out, "\n")
');
