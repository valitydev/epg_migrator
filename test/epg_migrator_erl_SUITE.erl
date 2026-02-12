-module(epg_migrator_erl_SUITE).

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
    test_erl_migration_with_single_realm/1,
    test_erl_migration_with_multiple_table_prefixes/1,
    test_erl_creates_correct_tables/1,
    test_erl_inserts_correct_data/1,
    test_erl_second_run_executes_nothing/1,
    test_erl_scanner_detects_erl_files/1,
    test_erl_with_options/1,
    test_erl_failed_migration_rolls_back/1,
    test_erl_compile_error/1
]).

%%%-----------------------------------------------------------------------------
%%% CT Callbacks
%%%-----------------------------------------------------------------------------

all() ->
    [
        test_erl_scanner_detects_erl_files,
        test_erl_migration_with_single_realm,
        test_erl_migration_with_multiple_table_prefixes,
        test_erl_creates_correct_tables,
        test_erl_inserts_correct_data,
        test_erl_second_run_executes_nothing,
        test_erl_with_options,
        test_erl_failed_migration_rolls_back,
        test_erl_compile_error
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
    MigrationsDir = filename:join([DataDir, "test", "erl_migrations"]),

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

test_erl_scanner_detects_erl_files(Config) ->
    MigrationsDir = ?config(migrations_dir, Config),

    {ok, Files} = epg_migrator_scanner:scan(MigrationsDir),

    ?assertEqual(3, length(Files)),
    ?assertEqual(<<"001_create_users_table.erl">>, lists:nth(1, Files)),
    ?assertEqual(<<"002_create_posts_table.erl">>, lists:nth(2, Files)),
    ?assertEqual(<<"003_insert_test_data.erl">>, lists:nth(3, Files)),

    ?assertEqual(erl, epg_migrator_scanner:get_migration_type(<<"001_create_users_table.erl">>)),
    ?assertEqual(erl, epg_migrator_scanner:get_migration_type(<<"002_create_posts_table.erl">>)).

%%%-----------------------------------------------------------------------------
%%% Test Cases - Integration Tests
%%%-----------------------------------------------------------------------------

test_erl_migration_with_single_realm(Config) ->
    DbOpts = ?config(db_opts, Config),
    MigrationsDir = ?config(migrations_dir, Config),
    Realm = "test_realm",
    MigrationOpts = [{table_prefix, "erl_"}],

    {ok, Executed} = epg_migrator:perform(Realm, DbOpts, MigrationOpts, MigrationsDir),

    ?assertEqual(3, length(Executed)),

    {ok, Conn} = connect(DbOpts),
    try
        {ok, Migrations} = epg_migrator_storage:get_executed(Conn, Realm),
        ?assertEqual(3, length(Migrations)),
        ?assertEqual(<<"001_create_users_table.erl">>, lists:nth(1, Migrations)),
        ?assertEqual(<<"002_create_posts_table.erl">>, lists:nth(2, Migrations)),
        ?assertEqual(<<"003_insert_test_data.erl">>, lists:nth(3, Migrations))
    after
        epgsql:close(Conn)
    end.

test_erl_migration_with_multiple_table_prefixes(Config) ->
    DbOpts = ?config(db_opts, Config),
    MigrationsDir = ?config(migrations_dir, Config),

    Realm1 = "realm_prefix_1",
    Realm2 = "realm_prefix_2",
    MigrationOpts1 = [{table_prefix, "prefix1_"}],
    MigrationOpts2 = [{table_prefix, "prefix2_"}],

    {ok, Executed1} = epg_migrator:perform(Realm1, DbOpts, MigrationOpts1, MigrationsDir),
    ?assertEqual(3, length(Executed1)),

    {ok, Executed2} = epg_migrator:perform(Realm2, DbOpts, MigrationOpts2, MigrationsDir),
    ?assertEqual(3, length(Executed2)),

    {ok, Conn} = connect(DbOpts),
    try
        {ok, _, _} = epgsql:equery(Conn, "SELECT * FROM prefix1_users", []),
        {ok, _, _} = epgsql:equery(Conn, "SELECT * FROM prefix1_posts", []),

        {ok, _, _} = epgsql:equery(Conn, "SELECT * FROM prefix2_users", []),
        {ok, _, _} = epgsql:equery(Conn, "SELECT * FROM prefix2_posts", [])
    after
        epgsql:close(Conn)
    end.

test_erl_creates_correct_tables(Config) ->
    DbOpts = ?config(db_opts, Config),
    MigrationsDir = ?config(migrations_dir, Config),
    Realm = "schema_test",
    MigrationOpts = [{table_prefix, "test_"}],

    {ok, _} = epg_migrator:perform(Realm, DbOpts, MigrationOpts, MigrationsDir),

    {ok, Conn} = connect(DbOpts),
    try
        {ok, _, UsersRows} = epgsql:equery(
            Conn,
            "SELECT column_name FROM information_schema.columns WHERE table_name = 'test_users' ORDER BY ordinal_position",
            []
        ),
        UserColumns = [Col || {Col} <- UsersRows],
        ?assert(lists:member(<<"id">>, UserColumns)),
        ?assert(lists:member(<<"username">>, UserColumns)),
        ?assert(lists:member(<<"email">>, UserColumns)),
        ?assert(lists:member(<<"created_at">>, UserColumns)),

        {ok, _, PostsRows} = epgsql:equery(
            Conn,
            "SELECT column_name FROM information_schema.columns WHERE table_name = 'test_posts' ORDER BY ordinal_position",
            []
        ),
        PostColumns = [Col || {Col} <- PostsRows],
        ?assert(lists:member(<<"id">>, PostColumns)),
        ?assert(lists:member(<<"user_id">>, PostColumns)),
        ?assert(lists:member(<<"title">>, PostColumns)),
        ?assert(lists:member(<<"content">>, PostColumns)),
        ?assert(lists:member(<<"published">>, PostColumns))
    after
        epgsql:close(Conn)
    end.

test_erl_inserts_correct_data(Config) ->
    DbOpts = ?config(db_opts, Config),
    MigrationsDir = ?config(migrations_dir, Config),
    Realm = "data_test",
    MigrationOpts = [{table_prefix, "data_"}],

    {ok, _} = epg_migrator:perform(Realm, DbOpts, MigrationOpts, MigrationsDir),

    {ok, Conn} = connect(DbOpts),
    try
        {ok, _, UserRows} = epgsql:equery(Conn, "SELECT username FROM data_users ORDER BY id", []),
        Usernames = [Username || {Username} <- UserRows],
        ?assertEqual([<<"alice">>, <<"bob">>, <<"charlie">>], Usernames),

        {ok, _, PostRows} = epgsql:equery(Conn, "SELECT COUNT(*) FROM data_posts", []),
        ?assertEqual([{4}], PostRows),

        {ok, _, TitleRows} = epgsql:equery(Conn, "SELECT title FROM data_posts WHERE id = 1", []),
        [{Title}] = TitleRows,
        ?assertEqual(<<"First Post">>, Title)
    after
        epgsql:close(Conn)
    end.

test_erl_second_run_executes_nothing(Config) ->
    DbOpts = ?config(db_opts, Config),
    MigrationsDir = ?config(migrations_dir, Config),
    Realm = "idempotent_test",
    MigrationOpts = [{table_prefix, "idem_"}],

    {ok, Executed1} = epg_migrator:perform(Realm, DbOpts, MigrationOpts, MigrationsDir),
    ?assertEqual(3, length(Executed1)),

    {ok, Executed2} = epg_migrator:perform(Realm, DbOpts, MigrationOpts, MigrationsDir),
    ?assertEqual(0, length(Executed2)).

test_erl_with_options(Config) ->
    DbOpts = ?config(db_opts, Config),
    MigrationsDir = ?config(migrations_dir, Config),
    Realm = "options_test",
    MigrationOpts = [{table_prefix, "opts_"}, {custom_option, "custom_value"}],

    {ok, Executed} = epg_migrator:perform(Realm, DbOpts, MigrationOpts, MigrationsDir),
    ?assertEqual(3, length(Executed)),

    {ok, Conn} = connect(DbOpts),
    try
        {ok, _, _} = epgsql:equery(Conn, "SELECT * FROM opts_users", []),
        {ok, _, _} = epgsql:equery(Conn, "SELECT * FROM opts_posts", [])
    after
        epgsql:close(Conn)
    end.

test_erl_failed_migration_rolls_back(Config) ->
    DbOpts = ?config(db_opts, Config),
    Realm = "erl_fail_test",

    TempDir = filename:join([?config(priv_dir, Config), "bad_erl_migrations"]),
    ok = filelib:ensure_dir(filename:join(TempDir, "dummy")),

    MigrationOpts = [{table_prefix, "fail_"}],

    GoodMigration = filename:join(TempDir, "001_good.erl"),
    GoodCode =
        "-module(m001_good).\n"
        "-export([perform/2]).\n"
        "perform(Conn, Opts) ->\n"
        "    Prefix = proplists:get_value(table_prefix, Opts, \"\"),\n"
        "    SQL = \"CREATE TABLE \" ++ Prefix ++ \"test_good (id SERIAL PRIMARY KEY)\",\n"
        "    {ok, [], []} = epgsql:squery(Conn, SQL),\n"
        "    ok.\n",
    ok = file:write_file(GoodMigration, GoodCode),

    Result1 = epg_migrator:perform(Realm, DbOpts, MigrationOpts, TempDir),

    ?assertEqual({ok, [<<"001_good.erl">>]}, Result1),

    BadMigration = filename:join(TempDir, "002_bad.erl"),
    BadCode =
        "-module(m002_bad).\n"
        "-export([perform/2]).\n"
        "perform(Conn, _Opts) ->\n"
        "    {ok, [], []} = epgsql:squery(Conn, \"INVALID SQL SYNTAX HERE\"),\n"
        "    ok.\n",
    ok = file:write_file(BadMigration, BadCode),

    Result2 = epg_migrator:perform(Realm, DbOpts, MigrationOpts, TempDir),

    ?assertMatch({error, _}, Result2),

    {ok, Conn} = connect(DbOpts),
    try
        {ok, Migrations} = epg_migrator_storage:get_executed(Conn, Realm),

        ?assertEqual(1, length(Migrations)),
        ?assertEqual(<<"001_good.erl">>, lists:nth(1, Migrations)),

        {ok, _, _} = epgsql:equery(Conn, "SELECT * FROM fail_test_good", [])
    after
        epgsql:close(Conn)
    end.

test_erl_compile_error(Config) ->
    DbOpts = ?config(db_opts, Config),
    Realm = "compile_error_test",

    TempDir = filename:join([?config(priv_dir, Config), "compile_error_migrations"]),
    ok = filelib:ensure_dir(filename:join(TempDir, "dummy")),

    Migration = filename:join(TempDir, "001_syntax_error.erl"),
    BadCode =
        "-module(m001_syntax_error).\n"
        "-export([perform/2]).\n"
        "perform(Conn, Opts) ->\n"
        "    this is not valid erlang syntax!!!\n",
    ok = file:write_file(Migration, BadCode),

    MigrationOpts = [],

    Result = epg_migrator:perform(Realm, DbOpts, MigrationOpts, TempDir),

    ?assertMatch({error, _}, Result).

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
