select load_extension('./libsqlite_plugin_lj');

select L('
    sqlite.register_internal_function("make_chk")
');

select make_chk('sum2', 'return arg[1] + arg[2]', 2);
select sum2(10, 20);

select make_chk('answer', 'return 42', 0);
select answer();
