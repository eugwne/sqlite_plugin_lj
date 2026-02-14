select load_extension('./libsqlite_plugin_lj');

select L('
    sqlite.register_internal_function("make_str", "mkstr")
');

select mkstr('const_s', 'hello_fast');
select const_s();
