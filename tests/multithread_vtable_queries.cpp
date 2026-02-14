#include <sqlite3.h>

#include <chrono>
#include <cstdio>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#if defined(__APPLE__)
extern "C" int sqlite3_enable_load_extension(sqlite3* db, int onoff);
extern "C" int sqlite3_load_extension(sqlite3* db, const char* zFile, const char* zProc, char** pzErrMsg);
#endif

namespace {

constexpr int WORKER_COUNT = 6;
constexpr int MIN_LOOP_COUNT = 30;
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

bool scalar_int(sqlite3* db, const std::string& sql, int& out_value, std::string& err) {
    sqlite3_stmt* stmt = nullptr;
    int rc = sqlite3_prepare_v2(db, sql.c_str(), -1, &stmt, nullptr);
    if (rc != SQLITE_OK) {
        err = "prepare failed: " + sqlite_error(db);
        return false;
    }
    rc = sqlite3_step(stmt);
    if (rc != SQLITE_ROW) {
        sqlite3_finalize(stmt);
        err = "step failed: " + sqlite_error(db);
        return false;
    }
    out_value = sqlite3_column_int(stmt, 0);
    rc = sqlite3_finalize(stmt);
    if (rc != SQLITE_OK) {
        err = "finalize failed: " + sqlite_error(db);
        return false;
    }
    return true;
}

bool exec_sql(sqlite3* db, const std::string& sql, std::string& err) {
    char* exec_err = nullptr;
    const int rc = sqlite3_exec(db, sql.c_str(), nullptr, nullptr, &exec_err);
    if (rc == SQLITE_OK) {
        return true;
    }
    err = exec_err ? std::string(exec_err) : sqlite_error(db);
    if (exec_err) {
        sqlite3_free(exec_err);
    }
    return false;
}

void print_report(const std::vector<WorkerArgs>& args, long long total_ms) {
    int total_loops = 0;
    int min_loops = 0;
    int max_loops = 0;
    bool initialized = false;

    std::printf("Run summary: total_time_ms=%lld workers=%d\n", total_ms, static_cast<int>(args.size()));
    for (const auto& arg : args) {
        int loops = arg.completed_loops;
        long long elapsed = 0;
        if (arg.started_ms > 0 && arg.finished_ms >= arg.started_ms) {
            elapsed = arg.finished_ms - arg.started_ms;
        }
        std::printf(" worker=%d loops=%d elapsed_ms=%lld\n", arg.worker_id, loops, elapsed);
        total_loops += loops;
        if (!initialized) {
            min_loops = loops;
            max_loops = loops;
            initialized = true;
        } else {
            if (loops < min_loops) min_loops = loops;
            if (loops > max_loops) max_loops = loops;
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

    SqliteDb holder;
    if (sqlite3_open(":memory:", &holder.db) != SQLITE_OK) {
        arg.shared->set_error("worker " + std::to_string(arg.worker_id) + ": open failed: " + sqlite_error(holder.db, "unknown"));
        arg.finished_ms = monotonic_ms();
        return;
    }

    std::string load_err;
    if (!load_extension(holder.db, arg.ext_path, load_err)) {
        arg.shared->set_error("worker " + std::to_string(arg.worker_id) + ": load_extension failed: " + load_err);
        arg.finished_ms = monotonic_ms();
        return;
    }

    std::string sql_err;
    if (!exec_sql(
            holder.db,
            "SELECT * FROM L('"
            "_G.list_iterator = function(t) "
            "  local i = 0 "
            "  local n = #t "
            "  return function () "
            "    i = i + 1 "
            "    if i <= n then return t[i] end "
            "  end "
            "end "
            "return function() return nil end"
            "')",
            sql_err
        )) {
        arg.shared->set_error("worker " + std::to_string(arg.worker_id) + ": list_iterator init failed: " + sql_err);
        arg.finished_ms = monotonic_ms();
        return;
    }

    int i = 1;
    while (true) {
        if (i > arg.min_loops && std::chrono::steady_clock::now() >= arg.deadline) {
            break;
        }

        int got = 0;
        if (!scalar_int(holder.db, "SELECT count(*) FROM L10('return list_iterator({{1,10},{2,20},{3,30}})')", got, sql_err) || got != 3) {
            arg.shared->set_error("worker " + std::to_string(arg.worker_id) + " iter " + std::to_string(i) + ": q1 mismatch: " + sql_err);
            break;
        }

        if (!scalar_int(
                holder.db,
                "SELECT count(*) FROM ("
                "SELECT t.id, v.r1 "
                "FROM (SELECT 1 AS id UNION ALL SELECT 2 UNION ALL SELECT 3) t "
                "JOIN L10('return list_iterator({{1,100},{2,200},{3,300}})') v ON t.id = v.r0"
                ")",
                got,
                sql_err
            ) || got != 3) {
            arg.shared->set_error("worker " + std::to_string(arg.worker_id) + " iter " + std::to_string(i) + ": q2 mismatch: " + sql_err);
            break;
        }

        if (!scalar_int(holder.db, "SELECT count(*) FROM L('return list_iterator({1,2,3,4})') WHERE value >= 2", got, sql_err) || got != 3) {
            arg.shared->set_error("worker " + std::to_string(arg.worker_id) + " iter " + std::to_string(i) + ": q3 mismatch: " + sql_err);
            break;
        }

        arg.completed_loops = i;
        ++i;
    }

    arg.finished_ms = monotonic_ms();
}

}  // namespace

int main(int argc, char** argv) {
    if (argc < 2) {
        std::fprintf(stderr, "Usage: %s <extension-path>\n", argv[0]);
        return 2;
    }

    SharedState shared;
    const auto suite_start = monotonic_ms();
    const auto deadline = std::chrono::steady_clock::now() + DURATION;

    std::vector<WorkerArgs> args(WORKER_COUNT);
    for (int i = 0; i < WORKER_COUNT; ++i) {
        args[i].worker_id = i + 1;
        args[i].ext_path = argv[1];
        args[i].deadline = deadline;
        args[i].shared = &shared;
    }

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
        std::printf("FAIL multithread vtable queries: %s\n", shared.message.c_str());
        return 1;
    }
    std::printf("PASS multithread vtable queries\n");
    return 0;
}
