select load_extension('./libsqlite_plugin_lj');
select('-------------');

select L('run_sql[[
          CREATE TABLE numbers008(num1,num2);
          INSERT INTO numbers008 VALUES(1,11);
          INSERT INTO numbers008 VALUES(2,22);
          INSERT INTO numbers008 VALUES(3,33);
        ]]
');

select L('
    for value in urows("select num2 from numbers008") do
        print(tonumber(value))
        break;
    end
    -- urows statement stored in unfinalized_statements internal map and finalize(stmt) called here
');

select L('
    local sub1 = function()
        for value in urows("select num2 from numbers008") do
            return tonumber(value)
            -- urows in unfinalized_statements
        end
    end
    create_function("sub1", sub1, 0)
');
select sub1();

select L('
    local sub2 = function()
        for value in urows("select sub1() from numbers008") do
            return tonumber(value)
            -- urows in unfinalized_statements
        end
    end
    create_function("sub2", sub2, 0)
');
select sub2();

