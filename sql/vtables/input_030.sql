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

select('--- L10 all 10 columns ---');
.mode column
SELECT * FROM L10('
    local tbl = {
        {1, "a", 1.1, 10, "x", 100, true, -1, "end1", 999},
        {2, "b", 2.2, 20, "y", 200, false, -2, "end2", 888}
    }
    return list_iterator(tbl)
');

select('--- L10 filter on last columns ---');
SELECT r0, r8, r9 FROM L10('
    local tbl = {
        {1, "a", 1.1, 10, "x", 100, true, -1, "end1", 999},
        {2, "b", 2.2, 20, "y", 200, false, -2, "end2", 888},
        {3, "c", 3.3, 30, "z", 300, true, -3, "end3", 777}
    }
    return list_iterator(tbl)
') WHERE r9 < 900;

select('--- L10 single row all columns ---');
SELECT * FROM L10('
    return list_iterator({{10, 20, 30, 40, 50, 60, 70, 80, 90, 100}})
');
