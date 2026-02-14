select load_extension('./libsqlite_plugin_lj');

select L('
  sqlite.config.use_traceback = 0
  local out = {}

  local function check(label, ok)
    out[#out + 1] = (ok and "PASS " or "FAIL ") .. label
  end

  -- Setup test data
  sqlite.run_sql("CREATE TABLE np_data(id INTEGER, name TEXT, val REAL)")
  sqlite.run_sql("INSERT INTO np_data VALUES(1, ''alice'', 1.5)")
  sqlite.run_sql("INSERT INTO np_data VALUES(2, ''bob'', 2.5)")
  sqlite.run_sql("INSERT INTO np_data VALUES(3, ''charlie'', 3.5)")

  -- Test 1: :param style with fetch_first
  local r = sqlite.fetch_first("SELECT id, name FROM np_data WHERE id = :id", {id = 2})
  check(":param fetch_first", r and tonumber(r.id) == 2 and r.name == "bob")

  -- Test 2: $param style with fetch_first
  local r2 = sqlite.fetch_first("SELECT id, name FROM np_data WHERE name = $name", {name = "alice"})
  check("$param fetch_first", r2 and tonumber(r2.id) == 1)

  -- Test 3: @param style with fetch_first
  local r3 = sqlite.fetch_first("SELECT id FROM np_data WHERE val = @val", {val = 3.5})
  check("@param fetch_first", r3 and tonumber(r3.id) == 3)

  -- Test 4: Multiple named params
  local r4 = sqlite.fetch_first("SELECT id FROM np_data WHERE id = :id AND name = :name", {id = 1, name = "alice"})
  check("multi named params", r4 and tonumber(r4.id) == 1)

  -- Test 5: fetch_all with named params
  local rows = sqlite.fetch_all("SELECT id FROM np_data WHERE val >= :min_val ORDER BY id", {min_val = 2.5})
  check("fetch_all named", #rows == 2 and tonumber(rows[1].id) == 2 and tonumber(rows[2].id) == 3)

  -- Test 6: nrows iterator with named params
  local ids = {}
  for row in sqlite.nrows("SELECT id FROM np_data WHERE id > :min_id ORDER BY id", {min_id = 1}) do
    ids[#ids + 1] = tonumber(row.id)
  end
  check("nrows named", #ids == 2 and ids[1] == 2 and ids[2] == 3)

  -- Test 7: urows iterator with named params
  local names = {}
  for name in sqlite.urows("SELECT name FROM np_data WHERE val < :max_val ORDER BY name", {max_val = 3.0}) do
    names[#names + 1] = name
  end
  check("urows named", #names == 2 and names[1] == "alice" and names[2] == "bob")

  -- Test 8: Positional fallback when named param not found in table
  -- :b is param index 2, so params[2] = 20 is the positional fallback
  local r5 = sqlite.fetch_first("SELECT :a as a, :b as b", {a = 10, [2] = 20})
  check("positional fallback", r5 and tonumber(r5.a) == 10 and tonumber(r5.b) == 20)

  -- Test 9: NULL for missing named params (key not in table, no positional fallback)
  local r6 = sqlite.fetch_first("SELECT :x as x, :y as y", {x = 42})
  check("NULL missing param", r6 and tonumber(r6.x) == 42 and r6.y == nil)

  -- Test 10: All positional (? style) still works with table
  local r7 = sqlite.fetch_first("SELECT ? as a, ? as b", {100, 200})
  check("positional with table", r7 and tonumber(r7.a) == 100 and tonumber(r7.b) == 200)

  return table.concat(out, "\n")
');
