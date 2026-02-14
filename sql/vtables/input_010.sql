.load ./libsqlite_plugin_lj
.mode column
SELECT count(*) FROM L;
SELECT * , typeof(value) from L('return {1,2,NULL,3}');
SELECT * , typeof(value) from L('return 6,NULL,7,8');