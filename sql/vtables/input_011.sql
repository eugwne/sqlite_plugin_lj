.load ./libsqlite_plugin_lj
select L('
    sqlite.run_sql("DROP TABLE IF EXISTS TEMP.crash_vt")
    sqlite.make_vtable("crash_vt", {
        columns = {"a", "b"},
        rows = {{1, 2}}
    })
');
select * from crash_vt;
