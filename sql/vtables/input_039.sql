select load_extension('./libsqlite_plugin_lj');

-- Initialize list_iterator in vtable VM scope
SELECT *
FROM L('
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
  local ok, err = pcall(function()
    sqlite.fetch_first([[
      SELECT r0
      FROM L10('' 
        local done = false
        return function()
          if done then return nil end
          done = true
          local row = setmetatable({}, {
            __index = function(_, k)
              local nested = sqlite.fetch_first("SELECT value FROM L(''''return list_iterator({42})'''')")
              return tonumber(nested.value)
            end
          })
          return row
        end
      '')
    ]])
  end)

  local msg = tostring(err)
  local blocked = (not ok)
    and msg:find("vtable cannot be used from nested context") ~= nil
  return (blocked and "PASS" or "FAIL") .. " xColumn re-entry blocked"
');
