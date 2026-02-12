-module(epg_migrator_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

%% CT callbacks
-export([
    all/0,
    init_per_suite/1,
    end_per_suite/1,
    init_per_testcase/2,
    end_per_testcase/2
]).

%% Test cases
-export([
    test_first_run_executes_all_migrations/1,
    test_second_run_executes_nothing/1,
    test_new_migration_executes_only_new/1,
    test_migration_creates_correct_tables/1,
    test_migration_inserts_data/1,
    test_different_realms_are_independent/1,
    test_failed_migration_rolls_back/1,
    test_storage_ensure_table/1,
    test_scanner_scan_directory/1,
    test_scanner_filter_pending/1
]).

%%%-----------------------------------------------------------------------------
%%% CT Callbacks
%%%-----------------------------------------------------------------------------

all() ->
    [
        test_storage_ensure_table,
        test_scanner_scan_directory,
        test_scanner_filter_pending,
        test_first_run_executes_all_migrations,
        test_second_run_executes_nothing,
        test_new_migration_executes_only_new,
        test_migration_creates_correct_tables,
        test_migration_inserts_data,
        test_different_realms_are_independent,
        test_failed_migration_rolls_back
    ].

init_per_suite(Config) ->
    application:ensure_all_started(epgsql),

    DbOpts = #{
        host => "postgres",
        port => 5432,
        database => "migrator_db",
        username => "migrator",
        password => "migrator"
    },

    DataDir = os:getenv("PWD"),
    MigrationsDir = filename:join([DataDir, "test", "migrations"]),

    [{db_opts, DbOpts}, {migrations_dir, MigrationsDir} | Config].

end_per_suite(_Config) ->
    ok.

init_per_testcase(TestCase, Config) ->
    ct:log("Starting test case: ~p", [TestCase]),

    DbOpts = ?config(db_opts, Config),
    cleanup_database(DbOpts),

    Config.

end_per_testcase(TestCase, _Config) ->
    ct:log("Finished test case: ~p", [TestCase]),
    ok.

%%%-----------------------------------------------------------------------------
%%% Test Cases - Unit Tests
%%%-----------------------------------------------------------------------------

test_storage_ensure_table(Config) ->
    DbOpts = ?config(db_opts, Config),
    {ok, Conn} = connect(DbOpts),

    try
        ?assertEqual(ok, epg_migrator_storage:ensure_table(Conn)),

        {ok, _Cols, Rows} = epgsql:equery(
            Conn,
            "SELECT table_name FROM information_schema.tables WHERE table_name = 'schema_migrations'",
            []
        ),
        ?assertEqual(1, length(Rows)),

        ?assertEqual(ok, epg_migrator_storage:ensure_table(Conn))
    after
        epgsql:close(Conn)
    end.

test_scanner_scan_directory(Config) ->
    MigrationsDir = ?config(migrations_dir, Config),

    {ok, Files} = epg_migrator_scanner:scan(MigrationsDir),

    ?assertEqual(Files, lists:sort(Files)),

    ?assertEqual(3, length(Files)),
    ?assertEqual(<<"001_create_users_table.sql">>, lists:nth(1, Files)),
    ?assertEqual(<<"002_create_posts_table.sql">>, lists:nth(2, Files)),
    ?assertEqual(<<"003_insert_test_data.sql">>, lists:nth(3, Files)).

test_scanner_filter_pending(Config) ->
    MigrationsDir = ?config(migrations_dir, Config),
    {ok, AllMigrations} = epg_migrator_scanner:scan(MigrationsDir),

    Executed = [<<"001_create_users_table.sql">>],
    Pending = epg_migrator_scanner:filter_pending(AllMigrations, Executed),

    ?assertEqual(2, length(Pending)),
    ?assertEqual(<<"002_create_posts_table.sql">>, lists:nth(1, Pending)),
    ?assertEqual(<<"003_insert_test_data.sql">>, lists:nth(2, Pending)).

%%%-----------------------------------------------------------------------------
%%% Test Cases - Integration Tests
%%%-----------------------------------------------------------------------------

test_first_run_executes_all_migrations(Config) ->
    DbOpts = ?config(db_opts, Config),
    MigrationsDir = ?config(migrations_dir, Config),
    Realm = "test_realm_1",

    {ok, Executed} = epg_migrator:perform(Realm, DbOpts, [], MigrationsDir),

    ?assertEqual(3, length(Executed)),

    {ok, Conn} = connect(DbOpts),
    try
        {ok, Migrations} = epg_migrator_storage:get_executed(Conn, Realm),
        ?assertEqual(3, length(Migrations)),
        ?assertEqual(<<"001_create_users_table.sql">>, lists:nth(1, Migrations)),
        ?assertEqual(<<"002_create_posts_table.sql">>, lists:nth(2, Migrations)),
        ?assertEqual(<<"003_insert_test_data.sql">>, lists:nth(3, Migrations))
    after
        epgsql:close(Conn)
    end.

test_second_run_executes_nothing(Config) ->
    DbOpts = ?config(db_opts, Config),
    MigrationsDir = ?config(migrations_dir, Config),
    Realm = "test_realm_2",

    {ok, Executed1} = epg_migrator:perform(Realm, DbOpts, [], MigrationsDir),
    ?assertEqual(3, length(Executed1)),

    {ok, Executed2} = epg_migrator:perform(Realm, DbOpts, [], MigrationsDir),

    ?assertEqual(0, length(Executed2)).

test_new_migration_executes_only_new(Config) ->
    DbOpts = ?config(db_opts, Config),
    MigrationsDir = ?config(migrations_dir, Config),
    Realm = "test_realm_3",

    TempDir = filename:join([?config(priv_dir, Config), "temp_migrations"]),
    ok = filelib:ensure_dir(filename:join(TempDir, "dummy")),

    copy_migration(MigrationsDir, TempDir, "001_create_users_table.sql"),
    copy_migration(MigrationsDir, TempDir, "002_create_posts_table.sql"),

    {ok, Executed1} = epg_migrator:perform(Realm, DbOpts, [], TempDir),
    ?assertEqual(2, length(Executed1)),

    copy_migration(MigrationsDir, TempDir, "003_insert_test_data.sql"),

    {ok, Executed2} = epg_migrator:perform(Realm, DbOpts, [], TempDir),
    ?assertEqual(1, length(Executed2)),
    ?assertEqual(<<"003_insert_test_data.sql">>, lists:nth(1, Executed2)).

test_migration_creates_correct_tables(Config) ->
    DbOpts = ?config(db_opts, Config),
    MigrationsDir = ?config(migrations_dir, Config),
    Realm = "test_realm_4",

    {ok, _} = epg_migrator:perform(Realm, DbOpts, [], MigrationsDir),

    {ok, Conn} = connect(DbOpts),
    try
        {ok, _, UsersRows} = epgsql:equery(
            Conn,
            "SELECT column_name FROM information_schema.columns WHERE table_name = 'users' ORDER BY ordinal_position",
            []
        ),
        UserColumns = [Col || {Col} <- UsersRows],
        ?assert(lists:member(<<"id">>, UserColumns)),
        ?assert(lists:member(<<"username">>, UserColumns)),
        ?assert(lists:member(<<"email">>, UserColumns)),
        ?assert(lists:member(<<"created_at">>, UserColumns)),

        {ok, _, PostsRows} = epgsql:equery(
            Conn,
            "SELECT column_name FROM information_schema.columns WHERE table_name = 'posts' ORDER BY ordinal_position",
            []
        ),
        PostColumns = [Col || {Col} <- PostsRows],
        ?assert(lists:member(<<"id">>, PostColumns)),
        ?assert(lists:member(<<"user_id">>, PostColumns)),
        ?assert(lists:member(<<"title">>, PostColumns)),
        ?assert(lists:member(<<"content">>, PostColumns))
    after
        epgsql:close(Conn)
    end.

test_migration_inserts_data(Config) ->
    DbOpts = ?config(db_opts, Config),
    MigrationsDir = ?config(migrations_dir, Config),
    Realm = "test_realm_5",

    {ok, _} = epg_migrator:perform(Realm, DbOpts, [], MigrationsDir),

    {ok, Conn} = connect(DbOpts),
    try
        {ok, _, UserRows} = epgsql:equery(Conn, "SELECT username FROM users ORDER BY id", []),
        Usernames = [Username || {Username} <- UserRows],
        ?assertEqual([<<"alice">>, <<"bob">>, <<"charlie">>], Usernames),

        {ok, _, PostRows} = epgsql:equery(Conn, "SELECT COUNT(*) FROM posts", []),
        ?assertEqual([{4}], PostRows)
    after
        epgsql:close(Conn)
    end.

test_different_realms_are_independent(Config) ->
    DbOpts = ?config(db_opts, Config),

    Realm1 = "realm_a",
    Realm2 = "realm_b",

    TempDir1 = filename:join([?config(priv_dir, Config), "realm_a_migrations"]),
    TempDir2 = filename:join([?config(priv_dir, Config), "realm_b_migrations"]),
    ok = filelib:ensure_dir(filename:join(TempDir1, "dummy")),
    ok = filelib:ensure_dir(filename:join(TempDir2, "dummy")),

    Migration1_A = filename:join(TempDir1, "001_create_realm_a_table.sql"),
    ok = file:write_file(Migration1_A, <<"CREATE TABLE realm_a_data (id SERIAL PRIMARY KEY, value TEXT);">>),

    Migration1_B = filename:join(TempDir2, "001_create_realm_b_table.sql"),
    ok = file:write_file(Migration1_B, <<"CREATE TABLE realm_b_data (id SERIAL PRIMARY KEY, value TEXT);">>),

    {ok, Executed1} = epg_migrator:perform(Realm1, DbOpts, [], TempDir1),
    ?assertEqual(1, length(Executed1)),

    {ok, Executed2} = epg_migrator:perform(Realm2, DbOpts, [], TempDir2),
    ?assertEqual(1, length(Executed2)),

    {ok, Executed3} = epg_migrator:perform(Realm1, DbOpts, [], TempDir1),
    ?assertEqual(0, length(Executed3)),

    {ok, Conn} = connect(DbOpts),
    try
        {ok, Migrations1} = epg_migrator_storage:get_executed(Conn, Realm1),
        {ok, Migrations2} = epg_migrator_storage:get_executed(Conn, Realm2),

        ?assertEqual(1, length(Migrations1)),
        ?assertEqual(1, length(Migrations2)),
        ?assertEqual(<<"001_create_realm_a_table.sql">>, lists:nth(1, Migrations1)),
        ?assertEqual(<<"001_create_realm_b_table.sql">>, lists:nth(1, Migrations2)),

        {ok, _, _} = epgsql:equery(Conn, "SELECT * FROM realm_a_data", []),
        {ok, _, _} = epgsql:equery(Conn, "SELECT * FROM realm_b_data", [])
    after
        epgsql:close(Conn)
    end.

test_failed_migration_rolls_back(Config) ->
    DbOpts = ?config(db_opts, Config),
    Realm = "test_realm_fail",

    TempDir = filename:join([?config(priv_dir, Config), "bad_migrations"]),
    ok = filelib:ensure_dir(filename:join(TempDir, "dummy")),

    GoodMigration = filename:join(TempDir, "001_good.sql"),
    ok = file:write_file(GoodMigration, <<"CREATE TABLE test_good (id SERIAL PRIMARY KEY);">>),

    {ok, [<<"001_good.sql">>]} = epg_migrator:perform(Realm, DbOpts, [], TempDir),

    BadMigration = filename:join(TempDir, "002_bad.sql"),
    ok = file:write_file(BadMigration, <<"INVALID SQL SYNTAX HERE;">>),

    Result = epg_migrator:perform(Realm, DbOpts, [], TempDir),

    ?assertMatch({error, _}, Result),

    {ok, Conn} = connect(DbOpts),
    try
        {ok, Migrations} = epg_migrator_storage:get_executed(Conn, Realm),

        ?assertEqual(1, length(Migrations)),
        ?assertEqual(<<"001_good.sql">>, lists:nth(1, Migrations)),

        {ok, _, _} = epgsql:equery(Conn, "SELECT * FROM test_good", [])
    after
        epgsql:close(Conn)
    end.

%%%-----------------------------------------------------------------------------
%%% Helper Functions
%%%-----------------------------------------------------------------------------

connect(DbOpts) ->
    #{
        host := Host,
        port := Port,
        database := Database,
        username := Username,
        password := Password
    } = DbOpts,
    epgsql:connect(Host, Username, Password, [
        {database, Database},
        {port, Port},
        {timeout, 10000}
    ]).

cleanup_database(DbOpts) ->
    {ok, Conn} = connect(DbOpts),
    try
        epgsql:squery(Conn, "DROP SCHEMA public CASCADE"),
        epgsql:squery(Conn, "CREATE SCHEMA public"),
        epgsql:squery(Conn, "GRANT ALL ON SCHEMA public TO migrator"),
        epgsql:squery(Conn, "GRANT ALL ON SCHEMA public TO public"),
        ok
    after
        epgsql:close(Conn)
    end.

copy_migration(SourceDir, TargetDir, FileName) ->
    Source = filename:join(SourceDir, FileName),
    Target = filename:join(TargetDir, FileName),
    {ok, _} = file:copy(Source, Target),
    ok.
