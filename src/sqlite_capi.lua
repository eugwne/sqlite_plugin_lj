local ffi = require('ffi')
local C = ffi.C

ffi.cdef[[
typedef struct sqlite3 sqlite3;
typedef struct sqlite3_api_routines sqlite3_api_routines;
typedef struct sqlite3_context sqlite3_context;
typedef struct sqlite3_stmt sqlite3_stmt;

typedef long long int sqlite_int64;
typedef unsigned long long int sqlite_uint64;
typedef sqlite_int64 sqlite3_int64;
typedef sqlite_uint64 sqlite3_uint64;

typedef struct sqlite3_value sqlite3_value;

typedef struct sqlite3_vtab sqlite3_vtab;
typedef struct sqlite3_index_info sqlite3_index_info;
typedef struct sqlite3_vtab_cursor sqlite3_vtab_cursor;
typedef struct sqlite3_module sqlite3_module;

typedef int (*sqlite3_callback)(void*,int,char**, char**);

typedef struct sqlite3_blob sqlite3_blob;

typedef struct sqlite3_mutex sqlite3_mutex;

typedef struct sqlite3_vfs sqlite3_vfs;

typedef struct sqlite3_backup sqlite3_backup;

typedef struct sqlite3_str sqlite3_str;

typedef struct sqlite3_file sqlite3_file;

struct sqlite3_api_routines {
  void * (*aggregate_context)(sqlite3_context*,int nBytes);
  int  (*aggregate_count)(sqlite3_context*);
  int  (*bind_blob)(sqlite3_stmt*,int,const void*,int n,void(*)(void*));
  int  (*bind_double)(sqlite3_stmt*,int,double);
  int  (*bind_int)(sqlite3_stmt*,int,int);
  int  (*bind_int64)(sqlite3_stmt*,int,sqlite_int64);
  int  (*bind_null)(sqlite3_stmt*,int);
  int  (*bind_parameter_count)(sqlite3_stmt*);
  int  (*bind_parameter_index)(sqlite3_stmt*,const char*zName);
  const char * (*bind_parameter_name)(sqlite3_stmt*,int);
  int  (*bind_text)(sqlite3_stmt*,int,const char*,int n,void(*)(void*));
  int  (*bind_text16)(sqlite3_stmt*,int,const void*,int,void(*)(void*));
  int  (*bind_value)(sqlite3_stmt*,int,const sqlite3_value*);
  int  (*busy_handler)(sqlite3*,int(*)(void*,int),void*);
  int  (*busy_timeout)(sqlite3*,int ms);
  int  (*changes)(sqlite3*);
  int  (*close)(sqlite3*);
  int  (*collation_needed)(sqlite3*,void*,void(*)(void*,sqlite3*,
                           int eTextRep,const char*));
  int  (*collation_needed16)(sqlite3*,void*,void(*)(void*,sqlite3*,
                             int eTextRep,const void*));
  const void * (*column_blob)(sqlite3_stmt*,int iCol);
  int  (*column_bytes)(sqlite3_stmt*,int iCol);
  int  (*column_bytes16)(sqlite3_stmt*,int iCol);
  int  (*column_count)(sqlite3_stmt*pStmt);
  const char * (*column_database_name)(sqlite3_stmt*,int);
  const void * (*column_database_name16)(sqlite3_stmt*,int);
  const char * (*column_decltype)(sqlite3_stmt*,int i);
  const void * (*column_decltype16)(sqlite3_stmt*,int);
  double  (*column_double)(sqlite3_stmt*,int iCol);
  int  (*column_int)(sqlite3_stmt*,int iCol);
  sqlite_int64  (*column_int64)(sqlite3_stmt*,int iCol);
  const char * (*column_name)(sqlite3_stmt*,int);
  const void * (*column_name16)(sqlite3_stmt*,int);
  const char * (*column_origin_name)(sqlite3_stmt*,int);
  const void * (*column_origin_name16)(sqlite3_stmt*,int);
  const char * (*column_table_name)(sqlite3_stmt*,int);
  const void * (*column_table_name16)(sqlite3_stmt*,int);
  const unsigned char * (*column_text)(sqlite3_stmt*,int iCol);
  const void * (*column_text16)(sqlite3_stmt*,int iCol);
  int  (*column_type)(sqlite3_stmt*,int iCol);
  sqlite3_value* (*column_value)(sqlite3_stmt*,int iCol);
  void * (*commit_hook)(sqlite3*,int(*)(void*),void*);
  int  (*complete)(const char*sql);
  int  (*complete16)(const void*sql);
  int  (*create_collation)(sqlite3*,const char*,int,void*,
                           int(*)(void*,int,const void*,int,const void*));
  int  (*create_collation16)(sqlite3*,const void*,int,void*,
                             int(*)(void*,int,const void*,int,const void*));
  int  (*create_function)(sqlite3*,const char*,int,int,void*,
                          void (*xFunc)(sqlite3_context*,int,sqlite3_value**),
                          void (*xStep)(sqlite3_context*,int,sqlite3_value**),
                          void (*xFinal)(sqlite3_context*));
  int  (*create_function16)(sqlite3*,const void*,int,int,void*,
                            void (*xFunc)(sqlite3_context*,int,sqlite3_value**),
                            void (*xStep)(sqlite3_context*,int,sqlite3_value**),
                            void (*xFinal)(sqlite3_context*));
  int (*create_module)(sqlite3*,const char*,const sqlite3_module*,void*);
  int  (*data_count)(sqlite3_stmt*pStmt);
  sqlite3 * (*db_handle)(sqlite3_stmt*);
  int (*declare_vtab)(sqlite3*,const char*);
  int  (*enable_shared_cache)(int);
  int  (*errcode)(sqlite3*db);
  const char * (*errmsg)(sqlite3*);
  const void * (*errmsg16)(sqlite3*);
  int  (*exec)(sqlite3*,const char*,sqlite3_callback,void*,char**);
  int  (*expired)(sqlite3_stmt*);
  int  (*finalize)(sqlite3_stmt*pStmt);
  void  (*free)(void*);
  void  (*free_table)(char**result);
  int  (*get_autocommit)(sqlite3*);
  void * (*get_auxdata)(sqlite3_context*,int);
  int  (*get_table)(sqlite3*,const char*,char***,int*,int*,char**);
  int  (*global_recover)(void);
  void  (*interruptx)(sqlite3*);
  sqlite_int64  (*last_insert_rowid)(sqlite3*);
  const char * (*libversion)(void);
  int  (*libversion_number)(void);
  void *(*malloc)(int);
  char * (*mprintf)(const char*,...);
  int  (*open)(const char*,sqlite3**);
  int  (*open16)(const void*,sqlite3**);
  int  (*prepare)(sqlite3*,const char*,int,sqlite3_stmt**,const char**);
  int  (*prepare16)(sqlite3*,const void*,int,sqlite3_stmt**,const void**);
  void * (*profile)(sqlite3*,void(*)(void*,const char*,sqlite_uint64),void*);
  void  (*progress_handler)(sqlite3*,int,int(*)(void*),void*);
  void *(*realloc)(void*,int);
  int  (*reset)(sqlite3_stmt*pStmt);
  void  (*result_blob)(sqlite3_context*,const void*,int,void(*)(void*));
  void  (*result_double)(sqlite3_context*,double);
  void  (*result_error)(sqlite3_context*,const char*,int);
  void  (*result_error16)(sqlite3_context*,const void*,int);
  void  (*result_int)(sqlite3_context*,int);
  void  (*result_int64)(sqlite3_context*,sqlite_int64);
  void  (*result_null)(sqlite3_context*);
  void  (*result_text)(sqlite3_context*,const char*,int,void(*)(void*));
  void  (*result_text16)(sqlite3_context*,const void*,int,void(*)(void*));
  void  (*result_text16be)(sqlite3_context*,const void*,int,void(*)(void*));
  void  (*result_text16le)(sqlite3_context*,const void*,int,void(*)(void*));
  void  (*result_value)(sqlite3_context*,sqlite3_value*);
  void * (*rollback_hook)(sqlite3*,void(*)(void*),void*);
  int  (*set_authorizer)(sqlite3*,int(*)(void*,int,const char*,const char*,
                         const char*,const char*),void*);
  void  (*set_auxdata)(sqlite3_context*,int,void*,void (*)(void*));
  char * (*xsnprintf)(int,char*,const char*,...);
  int  (*step)(sqlite3_stmt*);
  int  (*table_column_metadata)(sqlite3*,const char*,const char*,const char*,
                                char const**,char const**,int*,int*,int*);
  void  (*thread_cleanup)(void);
  int  (*total_changes)(sqlite3*);
  void * (*trace)(sqlite3*,void(*xTrace)(void*,const char*),void*);
  int  (*transfer_bindings)(sqlite3_stmt*,sqlite3_stmt*);
  void * (*update_hook)(sqlite3*,void(*)(void*,int ,char const*,char const*,
                                         sqlite_int64),void*);
  void * (*user_data)(sqlite3_context*);
  const void * (*value_blob)(sqlite3_value*);
  int  (*value_bytes)(sqlite3_value*);
  int  (*value_bytes16)(sqlite3_value*);
  double  (*value_double)(sqlite3_value*);
  int  (*value_int)(sqlite3_value*);
  sqlite_int64  (*value_int64)(sqlite3_value*);
  int  (*value_numeric_type)(sqlite3_value*);
  const unsigned char * (*value_text)(sqlite3_value*);
  const void * (*value_text16)(sqlite3_value*);
  const void * (*value_text16be)(sqlite3_value*);
  const void * (*value_text16le)(sqlite3_value*);
  int  (*value_type)(sqlite3_value*);
  char *(*vmprintf)(const char*,va_list);
  /* Added ??? */
  int (*overload_function)(sqlite3*, const char *zFuncName, int nArg);
  /* Added by 3.3.13 */
  int (*prepare_v2)(sqlite3*,const char*,int,sqlite3_stmt**,const char**);
  int (*prepare16_v2)(sqlite3*,const void*,int,sqlite3_stmt**,const void**);
  int (*clear_bindings)(sqlite3_stmt*);
  /* Added by 3.4.1 */
  int (*create_module_v2)(sqlite3*,const char*,const sqlite3_module*,void*,
                          void (*xDestroy)(void *));
  /* Added by 3.5.0 */
  int (*bind_zeroblob)(sqlite3_stmt*,int,int);
  int (*blob_bytes)(sqlite3_blob*);
  int (*blob_close)(sqlite3_blob*);
  int (*blob_open)(sqlite3*,const char*,const char*,const char*,sqlite3_int64,
                   int,sqlite3_blob**);
  int (*blob_read)(sqlite3_blob*,void*,int,int);
  int (*blob_write)(sqlite3_blob*,const void*,int,int);
  int (*create_collation_v2)(sqlite3*,const char*,int,void*,
                             int(*)(void*,int,const void*,int,const void*),
                             void(*)(void*));
  int (*file_control)(sqlite3*,const char*,int,void*);
  sqlite3_int64 (*memory_highwater)(int);
  sqlite3_int64 (*memory_used)(void);
  sqlite3_mutex *(*mutex_alloc)(int);
  void (*mutex_enter)(sqlite3_mutex*);
  void (*mutex_free)(sqlite3_mutex*);
  void (*mutex_leave)(sqlite3_mutex*);
  int (*mutex_try)(sqlite3_mutex*);
  int (*open_v2)(const char*,sqlite3**,int,const char*);
  int (*release_memory)(int);
  void (*result_error_nomem)(sqlite3_context*);
  void (*result_error_toobig)(sqlite3_context*);
  int (*sleep)(int);
  void (*soft_heap_limit)(int);
  sqlite3_vfs *(*vfs_find)(const char*);
  int (*vfs_register)(sqlite3_vfs*,int);
  int (*vfs_unregister)(sqlite3_vfs*);
  int (*xthreadsafe)(void);
  void (*result_zeroblob)(sqlite3_context*,int);
  void (*result_error_code)(sqlite3_context*,int);
  int (*test_control)(int, ...);
  void (*randomness)(int,void*);
  sqlite3 *(*context_db_handle)(sqlite3_context*);
  int (*extended_result_codes)(sqlite3*,int);
  int (*limit)(sqlite3*,int,int);
  sqlite3_stmt *(*next_stmt)(sqlite3*,sqlite3_stmt*);
  const char *(*sql)(sqlite3_stmt*);
  int (*status)(int,int*,int*,int);
  int (*backup_finish)(sqlite3_backup*);
  sqlite3_backup *(*backup_init)(sqlite3*,const char*,sqlite3*,const char*);
  int (*backup_pagecount)(sqlite3_backup*);
  int (*backup_remaining)(sqlite3_backup*);
  int (*backup_step)(sqlite3_backup*,int);
  const char *(*compileoption_get)(int);
  int (*compileoption_used)(const char*);
  int (*create_function_v2)(sqlite3*,const char*,int,int,void*,
                            void (*xFunc)(sqlite3_context*,int,sqlite3_value**),
                            void (*xStep)(sqlite3_context*,int,sqlite3_value**),
                            void (*xFinal)(sqlite3_context*),
                            void(*xDestroy)(void*));
  int (*db_config)(sqlite3*,int,...);
  sqlite3_mutex *(*db_mutex)(sqlite3*);
  int (*db_status)(sqlite3*,int,int*,int*,int);
  int (*extended_errcode)(sqlite3*);
  void (*log)(int,const char*,...);
  sqlite3_int64 (*soft_heap_limit64)(sqlite3_int64);
  const char *(*sourceid)(void);
  int (*stmt_status)(sqlite3_stmt*,int,int);
  int (*strnicmp)(const char*,const char*,int);
  int (*unlock_notify)(sqlite3*,void(*)(void**,int),void*);
  int (*wal_autocheckpoint)(sqlite3*,int);
  int (*wal_checkpoint)(sqlite3*,const char*);
  void *(*wal_hook)(sqlite3*,int(*)(void*,sqlite3*,const char*,int),void*);
  int (*blob_reopen)(sqlite3_blob*,sqlite3_int64);
  int (*vtab_config)(sqlite3*,int op,...);
  int (*vtab_on_conflict)(sqlite3*);
  /* Version 3.7.16 and later */
  int (*close_v2)(sqlite3*);
  const char *(*db_filename)(sqlite3*,const char*);
  int (*db_readonly)(sqlite3*,const char*);
  int (*db_release_memory)(sqlite3*);
  const char *(*errstr)(int);
  int (*stmt_busy)(sqlite3_stmt*);
  int (*stmt_readonly)(sqlite3_stmt*);
  int (*stricmp)(const char*,const char*);
  int (*uri_boolean)(const char*,const char*,int);
  sqlite3_int64 (*uri_int64)(const char*,const char*,sqlite3_int64);
  const char *(*uri_parameter)(const char*,const char*);
  char *(*xvsnprintf)(int,char*,const char*,va_list);
  int (*wal_checkpoint_v2)(sqlite3*,const char*,int,int*,int*);
  /* Version 3.8.7 and later */
  int (*auto_extension)(void(*)(void));
  int (*bind_blob64)(sqlite3_stmt*,int,const void*,sqlite3_uint64,
                     void(*)(void*));
  int (*bind_text64)(sqlite3_stmt*,int,const char*,sqlite3_uint64,
                      void(*)(void*),unsigned char);
  int (*cancel_auto_extension)(void(*)(void));
  int (*load_extension)(sqlite3*,const char*,const char*,char**);
  void *(*malloc64)(sqlite3_uint64);
  sqlite3_uint64 (*msize)(void*);
  void *(*realloc64)(void*,sqlite3_uint64);
  void (*reset_auto_extension)(void);
  void (*result_blob64)(sqlite3_context*,const void*,sqlite3_uint64,
                        void(*)(void*));
  void (*result_text64)(sqlite3_context*,const char*,sqlite3_uint64,
                         void(*)(void*), unsigned char);
  int (*strglob)(const char*,const char*);
  /* Version 3.8.11 and later */
  sqlite3_value *(*value_dup)(const sqlite3_value*);
  void (*value_free)(sqlite3_value*);
  int (*result_zeroblob64)(sqlite3_context*,sqlite3_uint64);
  int (*bind_zeroblob64)(sqlite3_stmt*, int, sqlite3_uint64);
  /* Version 3.9.0 and later */
  unsigned int (*value_subtype)(sqlite3_value*);
  void (*result_subtype)(sqlite3_context*,unsigned int);
  /* Version 3.10.0 and later */
  int (*status64)(int,sqlite3_int64*,sqlite3_int64*,int);
  int (*strlike)(const char*,const char*,unsigned int);
  int (*db_cacheflush)(sqlite3*);
  /* Version 3.12.0 and later */
  int (*system_errno)(sqlite3*);
  /* Version 3.14.0 and later */
  int (*trace_v2)(sqlite3*,unsigned,int(*)(unsigned,void*,void*,void*),void*);
  char *(*expanded_sql)(sqlite3_stmt*);
  /* Version 3.18.0 and later */
  void (*set_last_insert_rowid)(sqlite3*,sqlite3_int64);
  /* Version 3.20.0 and later */
  int (*prepare_v3)(sqlite3*,const char*,int,unsigned int,
                    sqlite3_stmt**,const char**);
  int (*prepare16_v3)(sqlite3*,const void*,int,unsigned int,
                      sqlite3_stmt**,const void**);
  int (*bind_pointer)(sqlite3_stmt*,int,void*,const char*,void(*)(void*));
  void (*result_pointer)(sqlite3_context*,void*,const char*,void(*)(void*));
  void *(*value_pointer)(sqlite3_value*,const char*);
  int (*vtab_nochange)(sqlite3_context*);
  int (*value_nochange)(sqlite3_value*);
  const char *(*vtab_collation)(sqlite3_index_info*,int);
  /* Version 3.24.0 and later */
  int (*keyword_count)(void);
  int (*keyword_name)(int,const char**,int*);
  int (*keyword_check)(const char*,int);
  sqlite3_str *(*str_new)(sqlite3*);
  char *(*str_finish)(sqlite3_str*);
  void (*str_appendf)(sqlite3_str*, const char *zFormat, ...);
  void (*str_vappendf)(sqlite3_str*, const char *zFormat, va_list);
  void (*str_append)(sqlite3_str*, const char *zIn, int N);
  void (*str_appendall)(sqlite3_str*, const char *zIn);
  void (*str_appendchar)(sqlite3_str*, int N, char C);
  void (*str_reset)(sqlite3_str*);
  int (*str_errcode)(sqlite3_str*);
  int (*str_length)(sqlite3_str*);
  char *(*str_value)(sqlite3_str*);
  /* Version 3.25.0 and later */
  int (*create_window_function)(sqlite3*,const char*,int,int,void*,
                            void (*xStep)(sqlite3_context*,int,sqlite3_value**),
                            void (*xFinal)(sqlite3_context*),
                            void (*xValue)(sqlite3_context*),
                            void (*xInv)(sqlite3_context*,int,sqlite3_value**),
                            void(*xDestroy)(void*));
  /* Version 3.26.0 and later */
  const char *(*normalized_sql)(sqlite3_stmt*);
  /* Version 3.28.0 and later */
  int (*stmt_isexplain)(sqlite3_stmt*);
  int (*value_frombind)(sqlite3_value*);
  /* Version 3.30.0 and later */
  int (*drop_modules)(sqlite3*,const char**);
  /* Version 3.31.0 and later */
  sqlite3_int64 (*hard_heap_limit64)(sqlite3_int64);
  const char *(*uri_key)(const char*,int);
  const char *(*filename_database)(const char*);
  const char *(*filename_journal)(const char*);
  const char *(*filename_wal)(const char*);
  /* Version 3.32.0 and later */
  const char *(*create_filename)(const char*,const char*,const char*,
                           int,const char**);
  void (*free_filename)(const char*);
  sqlite3_file *(*database_file_object)(const char*);
  /* Version 3.34.0 and later */
  int (*txn_state)(sqlite3*,const char*);
  /* Version 3.36.1 and later */
  sqlite3_int64 (*changes64)(sqlite3*);
  sqlite3_int64 (*total_changes64)(sqlite3*);
  /* Version 3.37.0 and later */
  int (*autovacuum_pages)(sqlite3*,
     unsigned int(*)(void*,const char*,unsigned int,unsigned int,unsigned int),
     void*, void(*)(void*));
  /* Version 3.38.0 and later */
  int (*error_offset)(sqlite3*);
  int (*vtab_rhs_value)(sqlite3_index_info*,int,sqlite3_value**);
  int (*vtab_distinct)(sqlite3_index_info*);
  int (*vtab_in)(sqlite3_index_info*,int,int);
  int (*vtab_in_first)(sqlite3_value*,sqlite3_value**);
  int (*vtab_in_next)(sqlite3_value*,sqlite3_value**);
  /* Version 3.39.0 and later */
  int (*deserialize)(sqlite3*,const char*,unsigned char*,
                     sqlite3_int64,sqlite3_int64,unsigned);
  unsigned char *(*serialize)(sqlite3*,const char *,sqlite3_int64*,
                              unsigned int);
  const char *(*db_name)(sqlite3*,int);
  /* Version 3.40.0 and later */
  int (*value_encoding)(sqlite3_value*);
  /* Version 3.41.0 and later */
  int (*is_interrupted)(sqlite3*);
  /* Version 3.43.0 and later */
  int (*stmt_explain)(sqlite3_stmt*,int);
  /* Version 3.44.0 and later */
  void *(*get_clientdata)(sqlite3*,const char*);
  int (*set_clientdata)(sqlite3*, const char*, void*, void(*)(void*));
};

typedef void (*sqlite3_destructor_type)(void*);


typedef struct sqlite3_module {
    int iVersion;
    int (*xCreate)(sqlite3*, void *pAux,
                 int argc, const char *const*argv,
                 sqlite3_vtab **ppVTab, char**);
    int (*xConnect)(sqlite3*, void *pAux,
                 int argc, const char *const*argv,
                 sqlite3_vtab **ppVTab, char**);
    int (*xBestIndex)(sqlite3_vtab *pVTab, sqlite3_index_info*);
    int (*xDisconnect)(sqlite3_vtab *pVTab);
    int (*xDestroy)(sqlite3_vtab *pVTab);
    int (*xOpen)(sqlite3_vtab *pVTab, sqlite3_vtab_cursor **ppCursor);
    int (*xClose)(sqlite3_vtab_cursor*);
    int (*xFilter)(sqlite3_vtab_cursor*, int idxNum, const char *idxStr,
                  int argc, sqlite3_value **argv);
    int (*xNext)(sqlite3_vtab_cursor*);
    int (*xEof)(sqlite3_vtab_cursor*);
    int (*xColumn)(sqlite3_vtab_cursor*, sqlite3_context*, int);
    int (*xRowid)(sqlite3_vtab_cursor*, sqlite3_int64 *pRowid);
    int (*xUpdate)(sqlite3_vtab *, int, sqlite3_value **, sqlite3_int64 *);
    int (*xBegin)(sqlite3_vtab *pVTab);
    int (*xSync)(sqlite3_vtab *pVTab);
    int (*xCommit)(sqlite3_vtab *pVTab);
    int (*xRollback)(sqlite3_vtab *pVTab);
    int (*xFindFunction)(sqlite3_vtab *pVtab, int nArg, const char *zName,
                         void (**pxFunc)(sqlite3_context*,int,sqlite3_value**),
                         void **ppArg);
    int (*xRename)(sqlite3_vtab *pVtab, const char *zNew);
    /* The methods above are in version 1 of the sqlite_module object. Those
    ** below are for version 2 and greater. */
    int (*xSavepoint)(sqlite3_vtab *pVTab, int);
    int (*xRelease)(sqlite3_vtab *pVTab, int);
    int (*xRollbackTo)(sqlite3_vtab *pVTab, int);
    /* The methods above are in versions 1 and 2 of the sqlite_module object.
    ** Those below are for version 3 and greater. */
    int (*xShadowName)(const char*);
    /* The methods above are in versions 1 through 3 of the sqlite_module object.
    ** Those below are for version 4 and greater. */
    int (*xIntegrity)(sqlite3_vtab *pVTab, const char *zSchema,
                      const char *zTabName, int mFlags, char **pzErr);
} sqlite3_module;

struct sqlite3_vtab_cursor {
    sqlite3_vtab *pVtab;      /* Virtual table of this cursor */
    /* Virtual table implementations will typically add additional fields */
};

typedef struct lua_vtab_cursor {
    sqlite3_vtab_cursor base;  /* Base class - must be first */
    uint32_t index;           /* (this) Derived class data */
} lua_vtab_cursor;

struct sqlite3_vtab {
    const sqlite3_module *pModule;  /* The module for this virtual table */
    int nRef;                       /* Number of open cursors */
    char *zErrMsg;                  /* Error message from sqlite3_mprintf() */
    /* Virtual table implementations will typically add additional fields */
};

struct sqlite3_index_info {
  /* Inputs */
  int nConstraint;           /* Number of entries in aConstraint */
  struct sqlite3_index_constraint {
     int iColumn;              /* Column constrained.  -1 for ROWID */
     unsigned char op;         /* Constraint operator */
     unsigned char usable;     /* True if this constraint is usable */
     int iTermOffset;          /* Used internally - xBestIndex should ignore */
  } *aConstraint;            /* Table of WHERE clause constraints */
  int nOrderBy;              /* Number of terms in the ORDER BY clause */
  struct sqlite3_index_orderby {
     int iColumn;              /* Column number */
     unsigned char desc;       /* True for DESC.  False for ASC. */
  } *aOrderBy;               /* The ORDER BY clause */
  /* Outputs */
  struct sqlite3_index_constraint_usage {
    int argvIndex;           /* if >0, constraint is part of argv to xFilter */
    unsigned char omit;      /* Do not code a test for this constraint */
  } *aConstraintUsage;
  int idxNum;                /* Number used to identify the index */
  char *idxStr;              /* String, possibly obtained from sqlite3_malloc */
  int needToFreeIdxStr;      /* Free idxStr using sqlite3_free() if true */
  int orderByConsumed;       /* True if output is already ordered */
  double estimatedCost;           /* Estimated cost of using this index */
  /* Fields below are only available in SQLite 3.8.2 and later */
  sqlite3_int64 estimatedRows;    /* Estimated number of rows returned */
  /* Fields below are only available in SQLite 3.9.0 and later */
  int idxFlags;              /* Mask of SQLITE_INDEX_SCAN_* flags */
  /* Fields below are only available in SQLite 3.10.0 and later */
  sqlite3_uint64 colUsed;    /* Input: Mask of columns used by statement */
};

typedef struct lua_vtab {
  sqlite3_vtab base;  /* Base class - must be first */
  uint32_t index;           /* (this) Derived class data */
} lua_vtab;

typedef struct LJFunctionData {
    sqlite3 * db;
    char ** msg;
    const sqlite3_api_routines *api;
} LJFunctionData;
]]

local defines = {
    SQLITE_UTF8 = 1,
    SQLITE_OK = 0,
    SQLITE_NOMEM = 7, --A malloc() failed

    SQLITE_DETERMINISTIC  = 0x000000800,
    SQLITE_DIRECTONLY     = 0x000080000,
    SQLITE_SUBTYPE        = 0x000100000,
    SQLITE_INNOCUOUS      = 0x000200000,
    SQLITE_RESULT_SUBTYPE = 0x001000000,

    SQLITE_ROW  = 100,
    SQLITE_DONE = 101,

    SQLITE_TRANSIENT = ffi.cast('sqlite3_destructor_type', -1),

    SQLITE_INTEGER = 1,
    SQLITE_FLOAT   = 2,
    SQLITE_BLOB    = 4,
    SQLITE_NULL    = 5,
    SQLITE_TEXT    = 3,

    SQLITE_VTAB_INNOCUOUS         = 2
}

local SQLITE = {}
for k,v in pairs(defines) do
    local key = k:gsub( "SQLITE_", "")
    SQLITE[key] = v
end

ffi.cdef[[
    typedef  struct null_s{} null_s;
]]


local null_t, NULL, nullptr
local null_mt = {
  __tostring = function() return 'NULL' end,
   __eq = function( left, right )
            local t = type(left)
            if not (t == 'nil' or t == 'cdata') then
                return false
            end

            if ffi.cast('void*', left) == nullptr then
                left = right
            end
            t = type(left)
            if not (t == 'nil' or t == 'cdata') then
                return false
            end
            local ptr = ffi.cast('void*', left)

            return ((ptr == nil) or (ptr == nullptr))
        end
}
null_t = ffi.metatype("null_s", null_mt)
NULL = null_t()
nullptr = ffi.cast('void*', NULL)


return {
  SQLITE = SQLITE,
  NULL = NULL
}
