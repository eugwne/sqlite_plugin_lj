#include <sqlite3.h>

#include <algorithm>
#include <chrono>
#include <cstdio>
#include <filesystem>
#include <fstream>
#include <mutex>
#include <optional>
#include <sstream>
#include <string>
#include <string_view>
#include <thread>
#include <vector>

#if defined(__APPLE__)
extern "C" int sqlite3_enable_load_extension(sqlite3* db, int onoff);
extern "C" int sqlite3_load_extension(sqlite3* db, const char* zFile, const char* zProc, char** pzErrMsg);
#endif

namespace {

constexpr int WORKER_COUNT = 6;
constexpr int MIN_LOOP_COUNT = 20;
constexpr auto DURATION = std::chrono::milliseconds(1500);

struct SharedState {
    bool has_error = false;
    std::string message;
    std::mutex lock;

    void set_error(std::string msg) {
        std::scoped_lock guard(lock);
        if (!has_error) {
            has_error = true;
            message = std::move(msg);
        }
    }
};

struct WorkerArgs {
    int worker_id = 0;
    std::string ext_path;
    std::filesystem::path sql_root;
    std::filesystem::path expected_root;
    std::vector<std::string> fixture_tests;
    std::chrono::steady_clock::time_point deadline;
    int min_loops = MIN_LOOP_COUNT;
    SharedState* shared = nullptr;
    int completed_loops = 0;
    long long started_ms = 0;
    long long finished_ms = 0;
};

long long monotonic_ms() {
    using namespace std::chrono;
    return duration_cast<milliseconds>(steady_clock::now().time_since_epoch()).count();
}

std::string sqlite_error(sqlite3* db, const char* fallback = "sqlite error") {
    if (!db) {
        return fallback;
    }
    const char* msg = sqlite3_errmsg(db);
    return msg ? msg : fallback;
}

struct SqliteDb {
    sqlite3* db = nullptr;

    ~SqliteDb() {
        if (db) {
            sqlite3_close(db);
            db = nullptr;
        }
    }

    SqliteDb() = default;
    SqliteDb(const SqliteDb&) = delete;
    SqliteDb& operator=(const SqliteDb&) = delete;
};

int query_output_cb(void* udata, int argc, char** argv, char** /*colnames*/) {
    auto* out = static_cast<std::string*>(udata);
    for (int i = 0; i < argc; ++i) {
        if (i > 0) {
            out->push_back('|');
        }
        if (argv[i]) {
            out->append(argv[i]);
        }
    }
    out->push_back('\n');
    return 0;
}

bool read_text_file(const std::filesystem::path& path, std::string& out) {
    std::ifstream in(path, std::ios::binary);
    if (!in) {
        return false;
    }
    std::ostringstream ss;
    ss << in.rdbuf();
    out = ss.str();
    return true;
}

std::string trim_right_newlines(std::string s) {
    while (!s.empty() && (s.back() == '\n' || s.back() == '\r')) {
        s.pop_back();
    }
    return s;
}

std::string normalize_for_compare(std::string s) {
    std::replace(s.begin(), s.end(), '\r', '\n');

    std::vector<std::string> lines;
    {
        std::istringstream iss(s);
        std::string line;
        while (std::getline(iss, line)) {
            if (!line.empty()) {
                lines.push_back(line);
            }
        }
    }

    std::string out;
    for (size_t i = 0; i < lines.size(); ++i) {
        if (i > 0) {
            out.push_back('\n');
        }
        out.append(lines[i]);
    }
    return trim_right_newlines(out);
}

bool line_has_load_extension(std::string_view line) {
    auto lower = std::string(line);
    std::transform(lower.begin(), lower.end(), lower.begin(), [](unsigned char c) {
        return static_cast<char>(std::tolower(c));
    });
    return lower.find("load_extension(") != std::string::npos;
}

std::string strip_load_extension_lines(const std::string& sql) {
    std::istringstream iss(sql);
    std::string line;
    std::string out;
    bool first = true;

    while (std::getline(iss, line)) {
        if (line_has_load_extension(line)) {
            continue;
        }
        if (!first) {
            out.push_back('\n');
        }
        first = false;
        out.append(line);
    }

    if (!sql.empty() && sql.back() == '\n') {
        out.push_back('\n');
    }
    return out;
}

bool scalar_int(sqlite3* db, const std::string& sql, int& out_value) {
    sqlite3_stmt* stmt = nullptr;
    int rc = sqlite3_prepare_v2(db, sql.c_str(), -1, &stmt, nullptr);
    if (rc != SQLITE_OK) {
        return false;
    }

    rc = sqlite3_step(stmt);
    if (rc != SQLITE_ROW) {
        sqlite3_finalize(stmt);
        return false;
    }

    out_value = sqlite3_column_int(stmt, 0);
    rc = sqlite3_finalize(stmt);
    return rc == SQLITE_OK;
}

bool exec_sql(sqlite3* db, const std::string& sql, std::string& err) {
    char* exec_err = nullptr;
    const int rc = sqlite3_exec(db, sql.c_str(), nullptr, nullptr, &exec_err);
    if (rc == SQLITE_OK) {
        return true;
    }

    err = exec_err ? exec_err : sqlite_error(db);
    if (exec_err) {
        sqlite3_free(exec_err);
    }
    return false;
}

bool load_extension(sqlite3* db, const std::string& ext_path, std::string& err) {
    if (sqlite3_enable_load_extension(db, 1) != SQLITE_OK) {
        err = "enable_load_extension failed: " + sqlite_error(db);
        return false;
    }

    char* load_err = nullptr;
    const int rc = sqlite3_load_extension(db, ext_path.c_str(), nullptr, &load_err);
    if (rc == SQLITE_OK) {
        return true;
    }
    err = load_err ? std::string(load_err) : sqlite_error(db);
    if (load_err) {
        sqlite3_free(load_err);
    }
    return false;
}

bool run_fixture_test(const WorkerArgs& arg, const std::string& test_id, std::string& err) {
    const auto sql_path = arg.sql_root / ("input_" + test_id + ".sql");
    const auto expected_path = arg.expected_root / ("output_" + test_id + ".txt");

    std::string sql_text;
    std::string expected_text;
    std::string actual_text;

    if (!read_text_file(sql_path, sql_text)) {
        err = "cannot read SQL fixture: " + sql_path.string();
        return false;
    }
    if (!read_text_file(expected_path, expected_text)) {
        err = "cannot read expected fixture: " + expected_path.string();
        return false;
    }

    SqliteDb holder;
    if (sqlite3_open(":memory:", &holder.db) != SQLITE_OK) {
        err = "sqlite3_open failed for fixture " + test_id;
        return false;
    }

    if (!load_extension(holder.db, arg.ext_path, err)) {
        err = "load_extension failed for fixture " + test_id + ": " + err;
        return false;
    }

    const std::string filtered_sql = strip_load_extension_lines(sql_text);
    char* exec_err = nullptr;
    const int exec_rc = sqlite3_exec(holder.db, filtered_sql.c_str(), query_output_cb, &actual_text, &exec_err);
    if (exec_rc != SQLITE_OK) {
        err = "fixture " + test_id + " SQL failed: " + (exec_err ? std::string(exec_err) : sqlite_error(holder.db));
        if (exec_err) {
            sqlite3_free(exec_err);
        }
        return false;
    }

    const std::string expected_cmp = normalize_for_compare(expected_text);
    const std::string actual_cmp = normalize_for_compare(actual_text);
    if (expected_cmp != actual_cmp) {
        err = "fixture " + test_id + " mismatch";
        return false;
    }

    return true;
}

bool run_fixture_suite(const WorkerArgs& arg, std::string& err) {
    for (const auto& test_id : arg.fixture_tests) {
        if (!run_fixture_test(arg, test_id, err)) {
            return false;
        }
    }
    return true;
}

void print_report(const std::vector<WorkerArgs>& args, long long total_ms) {
    int total_loops = 0;
    int min_loops = 0;
    int max_loops = 0;
    bool initialized = false;

    std::printf("Run summary: total_time_ms=%lld workers=%d\n", total_ms, static_cast<int>(args.size()));

    for (const auto& arg : args) {
        const int loops = arg.completed_loops;
        long long elapsed = 0;
        if (arg.started_ms > 0 && arg.finished_ms >= arg.started_ms) {
            elapsed = arg.finished_ms - arg.started_ms;
        }

        std::printf(
            " worker=%d loops=%d elapsed_ms=%lld mode=%s\n",
            arg.worker_id,
            loops,
            elapsed,
            arg.fixture_tests.empty() ? "churn" : "churn+fixture"
        );

        total_loops += loops;
        if (!initialized) {
            min_loops = loops;
            max_loops = loops;
            initialized = true;
        } else {
            min_loops = std::min(min_loops, loops);
            max_loops = std::max(max_loops, loops);
        }
    }

    if (!initialized) {
        min_loops = 0;
        max_loops = 0;
    }

    const double avg = args.empty() ? 0.0 : static_cast<double>(total_loops) / static_cast<double>(args.size());
    std::printf(
        " Aggregate: total_loops=%d min_loops=%d max_loops=%d avg_loops=%.2f\n",
        total_loops,
        min_loops,
        max_loops,
        avg
    );
}

void worker_main(WorkerArgs& arg) {
    arg.started_ms = monotonic_ms();

    int i = 1;
    while (true) {
        if (i > arg.min_loops && std::chrono::steady_clock::now() >= arg.deadline) {
            break;
        }

        SqliteDb holder;
        if (sqlite3_open(":memory:", &holder.db) != SQLITE_OK) {
            arg.shared->set_error(
                "worker " + std::to_string(arg.worker_id) +
                " iter " + std::to_string(i) +
                ": open failed: " + sqlite_error(holder.db, "unknown")
            );
            break;
        }

        std::string load_err;
        if (!load_extension(holder.db, arg.ext_path, load_err)) {
            arg.shared->set_error(
                "worker " + std::to_string(arg.worker_id) +
                " iter " + std::to_string(i) +
                ": load_extension failed: " + load_err
            );
            break;
        }

        const int expected = arg.worker_id * 100000 + i;
        const std::string scalar_sql = "select L('return " + std::to_string(expected) + "')";
        int got = 0;
        if (!scalar_int(holder.db, scalar_sql, got) || got != expected) {
            arg.shared->set_error(
                "worker " + std::to_string(arg.worker_id) +
                " iter " + std::to_string(i) +
                ": L() mismatch expected=" + std::to_string(expected) +
                " got=" + std::to_string(got)
            );
            break;
        }

        std::string sql_err;
        const std::string setup_sql =
            "select L('sqlite.run_sql[[create table if not exists t(v integer);"
            "delete from t; insert into t(v) values(" + std::to_string(arg.worker_id) + ");]]')";
        if (!exec_sql(holder.db, setup_sql, sql_err)) {
            arg.shared->set_error(
                "worker " + std::to_string(arg.worker_id) +
                " iter " + std::to_string(i) +
                ": setup sql failed: " + sql_err
            );
            break;
        }

        if (!scalar_int(holder.db, "select sum(v) from t", got) || got != arg.worker_id) {
            arg.shared->set_error(
                "worker " + std::to_string(arg.worker_id) +
                " iter " + std::to_string(i) +
                ": sum mismatch expected=" + std::to_string(arg.worker_id) +
                " got=" + std::to_string(got)
            );
            break;
        }

        if (!arg.fixture_tests.empty() && i == 1) {
            std::string fixture_err;
            if (!run_fixture_suite(arg, fixture_err)) {
                arg.shared->set_error(
                    "worker " + std::to_string(arg.worker_id) +
                    " iter " + std::to_string(i) +
                    ": fixture suite failed: " + fixture_err
                );
                break;
            }
        }

        arg.completed_loops = i;
        ++i;
    }

    arg.finished_ms = monotonic_ms();
}

}  // namespace

int main(int argc, char** argv) {
    if (argc < 4) {
        std::fprintf(stderr, "Usage: %s <extension-path> <sql-root> <expected-root>\n", argv[0]);
        return 2;
    }

    SharedState shared;
    const auto suite_start = monotonic_ms();
    const auto deadline = std::chrono::steady_clock::now() + DURATION;

    std::vector<WorkerArgs> args(WORKER_COUNT);
    for (int i = 0; i < WORKER_COUNT; ++i) {
        args[i].worker_id = i + 1;
        args[i].ext_path = argv[1];
        args[i].sql_root = argv[2];
        args[i].expected_root = argv[3];
        args[i].deadline = deadline;
        args[i].min_loops = MIN_LOOP_COUNT;
        args[i].shared = &shared;
    }

    args[0].fixture_tests = {"035"};
    args[1].fixture_tests = {"037"};

    std::vector<std::thread> threads;
    threads.reserve(args.size());
    for (auto& arg : args) {
        threads.emplace_back([&arg]() { worker_main(arg); });
    }

    for (auto& t : threads) {
        t.join();
    }

    const auto suite_end = monotonic_ms();
    print_report(args, suite_end - suite_start);

    if (shared.has_error) {
        std::printf("FAIL multithread isolated connections: %s\n", shared.message.c_str());
        return 1;
    }

    std::printf("PASS multithread isolated connections\n");
    return 0;
}
