#include <sqlite3.h>

#include <cstdio>
#include <string>
#include <thread>

#if defined(__APPLE__)
extern "C" int sqlite3_enable_load_extension(sqlite3* db, int onoff);
extern "C" int sqlite3_load_extension(sqlite3* db, const char* zFile, const char* zProc, char** pzErrMsg);
#endif

namespace {

constexpr const char* kExpectedErr = "sqlite_plugin_lj: connection used from multiple threads";

std::string sqlite_error(sqlite3* db, const char* fallback = "sqlite error") {
    if (!db) {
        return fallback;
    }
    const char* msg = sqlite3_errmsg(db);
    return msg ? msg : fallback;
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

bool scalar_int(sqlite3* db, const char* sql, int* out, std::string& err) {
    sqlite3_stmt* stmt = nullptr;
    int rc = sqlite3_prepare_v2(db, sql, -1, &stmt, nullptr);
    if (rc != SQLITE_OK) {
        err = sqlite_error(db);
        return false;
    }
    rc = sqlite3_step(stmt);
    if (rc != SQLITE_ROW) {
        err = sqlite_error(db);
        sqlite3_finalize(stmt);
        return false;
    }
    *out = sqlite3_column_int(stmt, 0);
    rc = sqlite3_finalize(stmt);
    if (rc != SQLITE_OK) {
        err = sqlite_error(db);
        return false;
    }
    return true;
}

}  // namespace

int main(int argc, char** argv) {
    if (argc < 2) {
        std::fprintf(stderr, "Usage: %s <extension-path>\n", argv[0]);
        return 2;
    }

    sqlite3* db = nullptr;
    if (sqlite3_open(":memory:", &db) != SQLITE_OK) {
        std::printf("FAIL thread guard same connection: open failed\n");
        if (db) sqlite3_close(db);
        return 1;
    }

    std::string load_err;
    if (!load_extension(db, argv[1], load_err)) {
        std::printf("FAIL thread guard same connection: load failed: %s\n", load_err.c_str());
        sqlite3_close(db);
        return 1;
    }

    int v = 0;
    std::string err;
    if (!scalar_int(db, "select L('return 1')", &v, err) || v != 1) {
        std::printf("FAIL thread guard same connection: owner setup failed: %s\n", err.c_str());
        sqlite3_close(db);
        return 1;
    }

    bool thread_ok = false;
    std::string thread_err;
    std::thread t([&]() {
        int out = 0;
        std::string e;
        bool ok = scalar_int(db, "select L('return 2')", &out, e);
        if (!ok && e.find(kExpectedErr) != std::string::npos) {
            thread_ok = true;
            return;
        }
        thread_err = ok ? "unexpected success" : e;
    });
    t.join();

    if (!thread_ok) {
        std::printf("FAIL thread guard same connection: expected cross-thread error, got: %s\n", thread_err.c_str());
        sqlite3_close(db);
        return 1;
    }

    std::printf("PASS thread guard same connection\n");
    sqlite3_close(db);
    return 0;
}
