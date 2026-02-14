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

  sqlite.run_sql("DROP TABLE IF EXISTS TEMP.vt038")

  sqlite.make_vtable("vt038", {
    columns = {"v"},
    rows = {{1}, {2}}
  })
  local rows1 = sqlite.fetch_all("SELECT v FROM vt038 ORDER BY v")
  check("baseline table created", #rows1 == 2 and tonumber(rows1[1].v) == 1 and tonumber(rows1[2].v) == 2)

  local ok2, err2 = pcall(function()
    sqlite.make_vtable("vt038", {
      columns = {"v"},
      rows = {{10}, {20}, {30}}
    })
  end)
  check("re-create without drop errors", (not ok2) and tostring(err2):find("already exists") ~= nil, err2)

  local rows3 = sqlite.fetch_all("SELECT v FROM vt038 ORDER BY v")
  check("original table preserved after failed re-create", #rows3 == 2 and tonumber(rows3[1].v) == 1 and tonumber(rows3[2].v) == 2)

  sqlite.run_sql("DROP TABLE IF EXISTS TEMP.vt038")
  sqlite.make_vtable("vt038", {
    columns = {"v"},
    rows = {{7}}
  })
  local rows4 = sqlite.fetch_all("SELECT v FROM vt038")
  check("re-create works after explicit drop", #rows4 == 1 and tonumber(rows4[1].v) == 7)

  sqlite.run_sql("DROP TABLE IF EXISTS TEMP.vt038")
  return table.concat(out, "\n")
');
