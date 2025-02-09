select load_extension('./libsqlite_plugin_lj');

select('-------------');


select L('
    local sqlite = require("sqlite_lj")
    sqlite.run_sql("DROP TABLE IF EXISTS TEMP.table_a")
    sqlite.make_vtable("table_a",
        {
            columns = {"a", "b", "c"}, 
            rows = {{1,2}}
        }
    )
 ');

select * from table_a o1;
select('-------------');

select L('
    _G.list_iterator = function(t)
      local i = 0
      local n = #t
      return function ()
               i = i + 1
               if i <= n then return t[i] end
             end
    end
 ');


.mode column
SELECT * , typeof(value)
FROM L('
    local tbl = {123, 324, math.pi, NULL, "test", -1377409902473561268LL}
    return list_iterator(tbl)
 ')
 where value < 500;

SELECT * , typeof(value)
FROM L('
    local tbl = {123, 324, math.pi, NULL, "test", -1377409902473561268LL}
    return list_iterator(tbl)
 ')
;

SELECT *
FROM L10('
    local tbl = {
        {123, 324, math.pi, NULL, "test", -1377409902473561268LL},
        {124, 324, math.pi, NULL, "test", -1377409902473561268LL}
    }
    return list_iterator(tbl)
 ')
 where r0 > 123 and r1 = 324 limit 1
 ;
