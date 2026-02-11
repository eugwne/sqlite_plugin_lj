.load ./libsqlite_plugin_lj
select L('
  sqlite.config.use_traceback = 0

  local result = "PASS:callback_gc"
  for i = 1, 600 do
    local fname = "w_gc_" .. tostring(i)
    sqlite.create_function_agg_chk_window(
      fname,
      "n = 0",
      "n = n + arg[1]",
      "return n",
      1
    )

    collectgarbage("collect")
    collectgarbage("collect")

    local row = sqlite.fetch_first(
      "WITH t(v) AS (VALUES(1),(2),(3)) SELECT " .. fname .. "(v) OVER () AS s FROM t LIMIT 1"
    )
    if not row or tonumber(row.s) ~= 6 then
      result = "FAIL:callback_gc:" .. tostring(i)
      break
    end
  end

  return result
');
