.load ./libsqlite_plugin_lj
select L('
  sqlite.config.use_traceback = 0
  local out = {}

  local ok1, err1 = pcall(function()
    sqlite.run_sql("DROP TABLE IF EXISTS TEMP.\"tbl weird\"")
    sqlite.make_vtable("tbl weird", {
      columns = {"select", "a\"b", "sp ace"},
      rows = {{11, 22, 33}}
    })
    local row = sqlite.fetch_first("select \"select\", \"a\"\"b\", \"sp ace\" from \"tbl weird\"")
    if row and row["select"] == 11 and row["a\"b"] == 22 and row["sp ace"] == 33 then
      out[#out + 1] = "PASS: make_vtable quoted identifiers"
    else
      out[#out + 1] = "FAIL: make_vtable quoted identifiers mismatch"
    end
  end)
  if not ok1 then
    out[#out + 1] = "FAIL: make_vtable quoted identifiers error"
  end

  local ok2, err2 = pcall(function()
    sqlite.make_vtable("bad_table", {
      columns = {""},
      rows = {{1}}
    })
  end)
  if (not ok2) and tostring(err2):match("identifier must be a non%-empty string") then
    out[#out + 1] = "PASS: make_vtable rejects empty identifier"
  else
    out[#out + 1] = "FAIL: make_vtable rejects empty identifier"
  end

  return table.concat(out, "\n")
');
