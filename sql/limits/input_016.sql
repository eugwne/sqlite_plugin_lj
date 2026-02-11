.load ./libsqlite_plugin_lj
select L('
  sqlite.config.use_traceback = 0

  local ok = true
  local errtxt = ""
  for i = 1, 20 do
    local status, err = pcall(function()
      sqlite.make_fn("obj_lim_" .. i, "return function() return " .. i .. " end", 0)
    end)
    if not status then
      ok = false
      errtxt = tostring(err)
      break
    end
  end

  if (not ok) and errtxt:match("shared object storage limit exceeded") then
    return "PASS: shared object count ceiling enforced"
  else
    return "FAIL: shared object count ceiling enforced"
  end
');
