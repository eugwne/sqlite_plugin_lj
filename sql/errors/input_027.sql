select load_extension('./libsqlite_plugin_lj');

select L('
  local ok, err = pcall(function()
    sqlite.fetch_first("SELECT :v as v", { v = { bad = 1 } })
  end)
  if ok then
    return "unexpected-success"
  end
  err = tostring(err):gsub("table: 0x%x+", "table")
  return err
');
