select load_extension('./libsqlite_plugin_lj');

CREATE TABLE empty_win(x INT, cat TEXT);
CREATE TABLE single_win(x INT, cat TEXT);
INSERT INTO single_win VALUES (42, 'A');

select L('
  -- Window function without inverse (4-arg)
  sqlite.create_function_agg_chk_window("win_cnt",
    "n = 0",
    "n = n + 1",
    "return n",
    1)

  -- Window function with inverse (5-arg)
  sqlite.create_function_agg_chk_window("win_total",
    "n = 0",
    "n = n + arg[1]",
    "n = n - arg[1]",
    "return n",
    1)
');

select('--- window on empty table ORDER BY ---');
SELECT x, win_cnt(x) OVER (ORDER BY x) FROM empty_win;

select('--- window on empty table PARTITION BY ---');
SELECT x, win_cnt(x) OVER (PARTITION BY cat) FROM empty_win;

select('--- window inverse on empty table ---');
SELECT x, win_total(x) OVER (ORDER BY x ROWS BETWEEN 1 PRECEDING AND CURRENT ROW) FROM empty_win;

select('--- window on single row ---');
SELECT x, win_cnt(x) OVER (ORDER BY x) FROM single_win;

select('--- window inverse on single row ---');
SELECT x, win_total(x) OVER (ORDER BY x ROWS BETWEEN 1 PRECEDING AND CURRENT ROW) FROM single_win;

select('--- window partition on single row ---');
SELECT x, cat, win_cnt(x) OVER (PARTITION BY cat ORDER BY x) FROM single_win;
