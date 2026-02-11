select load_extension('./libsqlite_plugin_lj');

select L('
  sqlite.config.use_traceback = 0
  local out = {}

  local function check(label, ok)
    out[#out + 1] = (ok and "PASS " or "FAIL ") .. label
  end

  -- Test 1: Create vtable, query, drop, re-create with different data
  sqlite.make_vtable("reuse_t", {
    columns = {"a", "b"},
    rows = {{1, "x"}, {2, "y"}}
  })
  local r1 = sqlite.fetch_all("SELECT a, b FROM reuse_t ORDER BY a")
  check("initial create", #r1 == 2 and tonumber(r1[1].a) == 1 and r1[2].b == "y")

  sqlite.run_sql("DROP TABLE IF EXISTS TEMP.reuse_t")
  sqlite.make_vtable("reuse_t", {
    columns = {"a", "b"},
    rows = {{10, "p"}, {20, "q"}, {30, "r"}}
  })
  local r2 = sqlite.fetch_all("SELECT a, b FROM reuse_t ORDER BY a")
  check("re-create different data", #r2 == 3 and tonumber(r2[1].a) == 10 and r2[3].b == "r")

  -- Test 2: Re-create with different row count (fewer rows)
  sqlite.run_sql("DROP TABLE IF EXISTS TEMP.reuse_t")
  sqlite.make_vtable("reuse_t", {
    columns = {"a", "b"},
    rows = {{99, "only"}}
  })
  local r3 = sqlite.fetch_all("SELECT a, b FROM reuse_t")
  check("re-create fewer rows", #r3 == 1 and tonumber(r3[1].a) == 99)

  -- Test 3: Re-create with empty rows
  sqlite.run_sql("DROP TABLE IF EXISTS TEMP.reuse_t")
  sqlite.make_vtable("reuse_t", {
    columns = {"a", "b"},
    rows = {}
  })
  local r4 = sqlite.fetch_first("SELECT count(*) as c FROM reuse_t")
  check("re-create empty", r4 and tonumber(r4.c) == 0)

  return table.concat(out, "\n")
');
