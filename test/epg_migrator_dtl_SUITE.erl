-module(epg_migrator_dtl_SUITE).

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
    test_dtl_migration_with_single_realm/1,
    test_dtl_migration_with_multiple_realms/1,
    test_dtl_creates_correct_tables/1,
    test_dtl_inserts_correct_data/1,
    test_dtl_realms_use_same_migrations/1,
    test_dtl_second_run_executes_nothing/1,
    test_dtl_scanner_detects_dtl_files/1,
    test_dtl_template_rendering/1,
    test_dtl_with_complex_realm_names/1,
    test_dtl_failed_migration_rolls_back/1
]).

%%%-----------------------------------------------------------------------------
%%% CT Callbacks
%%%-----------------------------------------------------------------------------

all() ->
    [
        test_dtl_scanner_detects_dtl_files,
        test_dtl_template_rendering,
        test_dtl_migration_with_single_realm,
        test_dtl_migration_with_multiple_realms,
        test_dtl_creates_correct_tables,
        test_dtl_inserts_correct_data,
        test_dtl_realms_use_same_migrations,
        test_dtl_second_run_executes_nothing,
        test_dtl_with_complex_realm_names,
        test_dtl_failed_migration_rolls_back
    ].

init_per_suite(Config) ->
    application:ensure_all_started(epgsql),
    application:ensure_all_started(erlydtl),

    DbOpts = #{
        host => "postgres",
        port => 5432,
        database => "migrator_db",
        username => "migrator",
        password => "migrator"
    },

    DataDir = os:getenv("PWD"),
    MigrationsDir = filename:join([DataDir, "test", "dtl_migrations"]),

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

test_dtl_scanner_detects_dtl_files(Config) ->
    MigrationsDir = ?config(migrations_dir, Config),

    {ok, Files} = epg_migrator_scanner:scan(MigrationsDir),

    ?assertEqual(3, length(Files)),
    ?assertEqual(<<"001_create_users_table.sql.dtl">>, lists:nth(1, Files)),
    ?assertEqual(<<"002_create_posts_table.sql.dtl">>, lists:nth(2, Files)),
    ?assertEqual(<<"003_insert_test_data.sql.dtl">>, lists:nth(3, Files)),

    ?assertEqual(dtl, epg_migrator_scanner:get_migration_type(<<"001_create_users_table.sql.dtl">>)),
    ?assertEqual(dtl, epg_migrator_scanner:get_migration_type(<<"002_create_posts_table.sql.dtl">>)).

test_dtl_template_rendering(_Config) ->
    Template = <<"CREATE TABLE {{ realm }}_test (id SERIAL PRIMARY KEY);">>,
    ModuleName = test_dtl_module_123,

    {ok, ModuleName} = erlydtl:compile_template(Template, ModuleName, [{out_dir, false}]),

    try
        {ok, Rendered} = ModuleName:render([{realm, "myapp"}]),
        SQL = binary_to_list(iolist_to_binary(Rendered)),

        ?assertEqual("CREATE TABLE myapp_test (id SERIAL PRIMARY KEY);", SQL)
    after
        code:purge(ModuleName),
        code:delete(ModuleName)
    end.

%%%-----------------------------------------------------------------------------
%%% Test Cases - Integration Tests
%%%-----------------------------------------------------------------------------

test_dtl_migration_with_single_realm(Config) ->
    DbOpts = ?config(db_opts, Config),
    MigrationsDir = ?config(migrations_dir, Config),
    Realm = "test_realm",
    MigrationOpts = [{realm, "test"}],

    {ok, Executed} = epg_migrator:perform(Realm, DbOpts, MigrationOpts, MigrationsDir),

    ?assertEqual(3, length(Executed)),

    {ok, Conn} = connect(DbOpts),
    try
        {ok, Migrations} = epg_migrator_storage:get_executed(Conn, Realm),
        ?assertEqual(3, length(Migrations)),
        ?assertEqual(<<"001_create_users_table.sql.dtl">>, lists:nth(1, Migrations)),
        ?assertEqual(<<"002_create_posts_table.sql.dtl">>, lists:nth(2, Migrations)),
        ?assertEqual(<<"003_insert_test_data.sql.dtl">>, lists:nth(3, Migrations))
    after
        epgsql:close(Conn)
    end.

test_dtl_migration_with_multiple_realms(Config) ->
    DbOpts = ?config(db_opts, Config),
    MigrationsDir = ?config(migrations_dir, Config),

    Realm1 = "test/test",
    Realm2 = "prod/prod",
    MigrationOpts1 = [{realm, "test_test"}],
    MigrationOpts2 = [{realm, "prod_prod"}],

    {ok, Executed1} = epg_migrator:perform(Realm1, DbOpts, MigrationOpts1, MigrationsDir),
    ?assertEqual(3, length(Executed1)),

    {ok, Executed2} = epg_migrator:perform(Realm2, DbOpts, MigrationOpts2, MigrationsDir),
    ?assertEqual(3, length(Executed2)),

    {ok, Conn} = connect(DbOpts),
    try
        {ok, _, _} = epgsql:equery(Conn, "SELECT * FROM test_test_users", []),
        {ok, _, _} = epgsql:equery(Conn, "SELECT * FROM test_test_posts", []),

        {ok, _, _} = epgsql:equery(Conn, "SELECT * FROM prod_prod_users", []),
        {ok, _, _} = epgsql:equery(Conn, "SELECT * FROM prod_prod_posts", [])
    after
        epgsql:close(Conn)
    end.

test_dtl_creates_correct_tables(Config) ->
    DbOpts = ?config(db_opts, Config),
    MigrationsDir = ?config(migrations_dir, Config),
    Realm = "schema_test",
    MigrationOpts = [{realm, "app"}],

    {ok, _} = epg_migrator:perform(Realm, DbOpts, MigrationOpts, MigrationsDir),

    {ok, Conn} = connect(DbOpts),
    try
        {ok, _, UsersRows} = epgsql:equery(
            Conn,
            "SELECT column_name FROM information_schema.columns WHERE table_name = 'app_users' ORDER BY ordinal_position",
            []
        ),
        UserColumns = [Col || {Col} <- UsersRows],
        ?assert(lists:member(<<"id">>, UserColumns)),
        ?assert(lists:member(<<"username">>, UserColumns)),
        ?assert(lists:member(<<"email">>, UserColumns)),
        ?assert(lists:member(<<"created_at">>, UserColumns)),

        {ok, _, PostsRows} = epgsql:equery(
            Conn,
            "SELECT column_name FROM information_schema.columns WHERE table_name = 'app_posts' ORDER BY ordinal_position",
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

test_dtl_inserts_correct_data(Config) ->
    DbOpts = ?config(db_opts, Config),
    MigrationsDir = ?config(migrations_dir, Config),
    Realm = "data_test",
    MigrationOpts = [{realm, "myapp"}],

    {ok, _} = epg_migrator:perform(Realm, DbOpts, MigrationOpts, MigrationsDir),

    {ok, Conn} = connect(DbOpts),
    try
        {ok, _, UserRows} = epgsql:equery(Conn, "SELECT username FROM myapp_users ORDER BY id", []),
        Usernames = [Username || {Username} <- UserRows],
        ?assertEqual([<<"alice_myapp">>, <<"bob_myapp">>, <<"charlie_myapp">>], Usernames),

        {ok, _, PostRows} = epgsql:equery(Conn, "SELECT COUNT(*) FROM myapp_posts", []),
        ?assertEqual([{4}], PostRows),

        {ok, _, TitleRows} = epgsql:equery(
            Conn, "SELECT title FROM myapp_posts WHERE id = 1", []
        ),
        [{Title}] = TitleRows,
        ?assertEqual(<<"First Post in myapp">>, Title)
    after
        epgsql:close(Conn)
    end.

test_dtl_realms_use_same_migrations(Config) ->
    DbOpts = ?config(db_opts, Config),
    MigrationsDir = ?config(migrations_dir, Config),

    Realm1 = "realm_shared_1",
    Realm2 = "realm_shared_2",
    MigrationOpts1 = [{realm, "shared1"}],
    MigrationOpts2 = [{realm, "shared2"}],

    {ok, Executed1} = epg_migrator:perform(Realm1, DbOpts, MigrationOpts1, MigrationsDir),
    {ok, Executed2} = epg_migrator:perform(Realm2, DbOpts, MigrationOpts2, MigrationsDir),

    ?assertEqual(Executed1, Executed2),
    ?assertEqual(3, length(Executed1)),

    {ok, Conn} = connect(DbOpts),
    try
        {ok, _, _} = epgsql:equery(Conn, "SELECT * FROM shared1_users", []),
        {ok, _, _} = epgsql:equery(Conn, "SELECT * FROM shared2_users", []),

        {ok, Migrations1} = epg_migrator_storage:get_executed(Conn, Realm1),
        {ok, Migrations2} = epg_migrator_storage:get_executed(Conn, Realm2),

        ?assertEqual(3, length(Migrations1)),
        ?assertEqual(3, length(Migrations2))
    after
        epgsql:close(Conn)
    end.

test_dtl_second_run_executes_nothing(Config) ->
    DbOpts = ?config(db_opts, Config),
    MigrationsDir = ?config(migrations_dir, Config),
    Realm = "idempotent_test",
    MigrationOpts = [{realm, "idem"}],

    {ok, Executed1} = epg_migrator:perform(Realm, DbOpts, MigrationOpts, MigrationsDir),
    ?assertEqual(3, length(Executed1)),

    {ok, Executed2} = epg_migrator:perform(Realm, DbOpts, MigrationOpts, MigrationsDir),
    ?assertEqual(0, length(Executed2)).

test_dtl_with_complex_realm_names(Config) ->
    DbOpts = ?config(db_opts, Config),
    MigrationsDir = ?config(migrations_dir, Config),

    Realm = "company/department/project",
    MigrationOpts = [{realm, "company_department_project"}],

    {ok, Executed} = epg_migrator:perform(Realm, DbOpts, MigrationOpts, MigrationsDir),
    ?assertEqual(3, length(Executed)),

    {ok, Conn} = connect(DbOpts),
    try
        {ok, _, _} = epgsql:equery(Conn, "SELECT * FROM company_department_project_users", []),
        {ok, _, _} = epgsql:equery(Conn, "SELECT * FROM company_department_project_posts", [])
    after
        epgsql:close(Conn)
    end.

test_dtl_failed_migration_rolls_back(Config) ->
    DbOpts = ?config(db_opts, Config),
    Realm = "dtl_fail_test",

    TempDir = filename:join([?config(priv_dir, Config), "bad_dtl_migrations"]),
    ok = filelib:ensure_dir(filename:join(TempDir, "dummy")),

    MigrationOpts = [{realm, "fail"}],

    GoodMigration = filename:join(TempDir, "001_good.sql.dtl"),
    ok = file:write_file(
        GoodMigration,
        <<"CREATE TABLE {{ realm }}_test_good (id SERIAL PRIMARY KEY);">>
    ),
    Result1 = epg_migrator:perform(Realm, DbOpts, MigrationOpts, TempDir),
    ?assertEqual({ok, [<<"001_good.sql.dtl">>]}, Result1),

    BadMigration = filename:join(TempDir, "002_bad.sql.dtl"),
    ok = file:write_file(BadMigration, <<"INVALID SQL {{ realm }} SYNTAX HERE;">>),

    Result = epg_migrator:perform(Realm, DbOpts, MigrationOpts, TempDir),

    ?assertMatch({error, _}, Result),

    {ok, Conn} = connect(DbOpts),
    try
        {ok, Migrations} = epg_migrator_storage:get_executed(Conn, Realm),

        ?assertEqual(1, length(Migrations)),
        ?assertEqual(<<"001_good.sql.dtl">>, lists:nth(1, Migrations)),

        {ok, _, _} = epgsql:equery(Conn, "SELECT * FROM fail_test_good", [])
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
