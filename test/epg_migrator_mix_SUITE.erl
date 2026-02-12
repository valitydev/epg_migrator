-module(epg_migrator_mix_SUITE).

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
    test_mixed_migrations_happy_path/1,
    test_mixed_migrations_sorted_execution/1,
    test_mixed_migrations_creates_all_tables/1,
    test_mixed_migrations_inserts_all_data/1,
    test_mixed_migrations_with_parameters/1,
    test_mixed_migrations_idempotent/1,
    test_mixed_migrations_incremental/1,
    test_mixed_migrations_different_realms/1,
    test_mixed_scanner_detects_all_types/1,
    test_mixed_rollback_on_failure/1
]).

%%%-----------------------------------------------------------------------------
%%% CT Callbacks
%%%-----------------------------------------------------------------------------

all() ->
    [
        test_mixed_scanner_detects_all_types,
        test_mixed_migrations_happy_path,
        test_mixed_migrations_sorted_execution,
        test_mixed_migrations_creates_all_tables,
        test_mixed_migrations_inserts_all_data,
        test_mixed_migrations_with_parameters,
        test_mixed_migrations_idempotent,
        test_mixed_migrations_incremental,
        test_mixed_migrations_different_realms,
        test_mixed_rollback_on_failure
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
    MigrationsDir = filename:join([DataDir, "test", "mix_migrations"]),

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
%%% Test Cases
%%%-----------------------------------------------------------------------------

test_mixed_scanner_detects_all_types(Config) ->
    MigrationsDir = ?config(migrations_dir, Config),

    {ok, Files} = epg_migrator_scanner:scan(MigrationsDir),

    ?assertEqual(6, length(Files)),

    ?assertEqual(Files, lists:sort(Files)),

    ?assertEqual(<<"001_create_users.sql">>, lists:nth(1, Files)),
    ?assertEqual(<<"002_create_posts.sql.dtl">>, lists:nth(2, Files)),
    ?assertEqual(<<"003_create_comments.erl">>, lists:nth(3, Files)),
    ?assertEqual(<<"004_insert_users.sql">>, lists:nth(4, Files)),
    ?assertEqual(<<"005_insert_posts.sql.dtl">>, lists:nth(5, Files)),
    ?assertEqual(<<"006_insert_comments.erl">>, lists:nth(6, Files)),

    ?assertEqual(sql, epg_migrator_scanner:get_migration_type(<<"001_create_users.sql">>)),
    ?assertEqual(dtl, epg_migrator_scanner:get_migration_type(<<"002_create_posts.sql.dtl">>)),
    ?assertEqual(erl, epg_migrator_scanner:get_migration_type(<<"003_create_comments.erl">>)).

test_mixed_migrations_happy_path(Config) ->
    DbOpts = ?config(db_opts, Config),
    MigrationsDir = ?config(migrations_dir, Config),
    Realm = "happy_path",
    MigrationOpts = [{prefix, "blog"}],

    {ok, Executed} = epg_migrator:perform(Realm, DbOpts, MigrationOpts, MigrationsDir),

    ?assertEqual(6, length(Executed)),

    ?assertEqual(<<"001_create_users.sql">>, lists:nth(1, Executed)),
    ?assertEqual(<<"002_create_posts.sql.dtl">>, lists:nth(2, Executed)),
    ?assertEqual(<<"003_create_comments.erl">>, lists:nth(3, Executed)),
    ?assertEqual(<<"004_insert_users.sql">>, lists:nth(4, Executed)),
    ?assertEqual(<<"005_insert_posts.sql.dtl">>, lists:nth(5, Executed)),
    ?assertEqual(<<"006_insert_comments.erl">>, lists:nth(6, Executed)),

    {ok, Conn} = connect(DbOpts),
    try
        {ok, Migrations} = epg_migrator_storage:get_executed(Conn, Realm),
        ?assertEqual(6, length(Migrations))
    after
        epgsql:close(Conn)
    end.

test_mixed_migrations_sorted_execution(Config) ->
    DbOpts = ?config(db_opts, Config),
    MigrationsDir = ?config(migrations_dir, Config),
    Realm = "sorted_test",
    MigrationOpts = [{prefix, "test"}],

    {ok, Executed} = epg_migrator:perform(Realm, DbOpts, MigrationOpts, MigrationsDir),

    ?assertEqual(6, length(Executed)),

    lists:foldl(
        fun(Migration, Prev) ->
            case Prev of
                undefined ->
                    Migration;
                _ ->
                    ?assert(Migration > Prev),
                    Migration
            end
        end,
        undefined,
        Executed
    ).

test_mixed_migrations_creates_all_tables(Config) ->
    DbOpts = ?config(db_opts, Config),
    MigrationsDir = ?config(migrations_dir, Config),
    Realm = "tables_test",
    MigrationOpts = [{prefix, "app"}],

    {ok, _} = epg_migrator:perform(Realm, DbOpts, MigrationOpts, MigrationsDir),

    {ok, Conn} = connect(DbOpts),
    try
        {ok, _, _} = epgsql:equery(Conn, "SELECT * FROM users", []),

        {ok, _, _} = epgsql:equery(Conn, "SELECT * FROM app_posts", []),

        {ok, _, _} = epgsql:equery(Conn, "SELECT * FROM app_comments", []),

        {ok, _, UserCols} = epgsql:equery(
            Conn,
            "SELECT column_name FROM information_schema.columns WHERE table_name = 'users' ORDER BY ordinal_position",
            []
        ),
        UserColumns = [Col || {Col} <- UserCols],
        ?assert(lists:member(<<"id">>, UserColumns)),
        ?assert(lists:member(<<"username">>, UserColumns)),
        ?assert(lists:member(<<"email">>, UserColumns)),

        {ok, _, PostCols} = epgsql:equery(
            Conn,
            "SELECT column_name FROM information_schema.columns WHERE table_name = 'app_posts' ORDER BY ordinal_position",
            []
        ),
        PostColumns = [Col || {Col} <- PostCols],
        ?assert(lists:member(<<"id">>, PostColumns)),
        ?assert(lists:member(<<"user_id">>, PostColumns)),
        ?assert(lists:member(<<"title">>, PostColumns)),

        {ok, _, CommentCols} = epgsql:equery(
            Conn,
            "SELECT column_name FROM information_schema.columns WHERE table_name = 'app_comments' ORDER BY ordinal_position",
            []
        ),
        CommentColumns = [Col || {Col} <- CommentCols],
        ?assert(lists:member(<<"id">>, CommentColumns)),
        ?assert(lists:member(<<"post_id">>, CommentColumns)),
        ?assert(lists:member(<<"user_id">>, CommentColumns)),
        ?assert(lists:member(<<"content">>, CommentColumns))
    after
        epgsql:close(Conn)
    end.

test_mixed_migrations_inserts_all_data(Config) ->
    DbOpts = ?config(db_opts, Config),
    MigrationsDir = ?config(migrations_dir, Config),
    Realm = "data_test",
    MigrationOpts = [{prefix, "data"}],

    {ok, _} = epg_migrator:perform(Realm, DbOpts, MigrationOpts, MigrationsDir),

    {ok, Conn} = connect(DbOpts),
    try
        {ok, _, UserRows} = epgsql:equery(Conn, "SELECT COUNT(*) FROM users", []),
        ?assertEqual([{3}], UserRows),

        {ok, _, Users} = epgsql:equery(Conn, "SELECT username FROM users ORDER BY id", []),
        Usernames = [U || {U} <- Users],
        ?assertEqual([<<"alice">>, <<"bob">>, <<"charlie">>], Usernames),

        {ok, _, PostRows} = epgsql:equery(Conn, "SELECT COUNT(*) FROM data_posts", []),
        ?assertEqual([{4}], PostRows),

        {ok, _, CommentRows} = epgsql:equery(Conn, "SELECT COUNT(*) FROM data_comments", []),
        ?assertEqual([{5}], CommentRows),

        {ok, _, Comments} = epgsql:equery(
            Conn,
            "SELECT content FROM data_comments WHERE post_id = 1 ORDER BY id",
            []
        ),
        CommentTexts = [C || {C} <- Comments],
        ?assertEqual([<<"Great post, Alice!">>, <<"Thanks for sharing!">>], CommentTexts)
    after
        epgsql:close(Conn)
    end.

test_mixed_migrations_with_parameters(Config) ->
    DbOpts = ?config(db_opts, Config),
    MigrationsDir = ?config(migrations_dir, Config),
    Realm = "params_test",
    MigrationOpts = [{prefix, "custom"}, {extra_param, "value"}],

    {ok, Executed} = epg_migrator:perform(Realm, DbOpts, MigrationOpts, MigrationsDir),

    ?assertEqual(6, length(Executed)),

    {ok, Conn} = connect(DbOpts),
    try
        {ok, _, _} = epgsql:equery(Conn, "SELECT * FROM users", []),
        {ok, _, _} = epgsql:equery(Conn, "SELECT * FROM custom_posts", []),
        {ok, _, _} = epgsql:equery(Conn, "SELECT * FROM custom_comments", [])
    after
        epgsql:close(Conn)
    end.

test_mixed_migrations_idempotent(Config) ->
    DbOpts = ?config(db_opts, Config),
    MigrationsDir = ?config(migrations_dir, Config),
    Realm = "idempotent_test",
    MigrationOpts = [{prefix, "idem"}],

    {ok, Executed1} = epg_migrator:perform(Realm, DbOpts, MigrationOpts, MigrationsDir),
    ?assertEqual(6, length(Executed1)),

    {ok, Executed2} = epg_migrator:perform(Realm, DbOpts, MigrationOpts, MigrationsDir),
    ?assertEqual(0, length(Executed2)),

    {ok, Executed3} = epg_migrator:perform(Realm, DbOpts, MigrationOpts, MigrationsDir),
    ?assertEqual(0, length(Executed3)).

test_mixed_migrations_incremental(Config) ->
    DbOpts = ?config(db_opts, Config),
    MigrationsDir = ?config(migrations_dir, Config),
    Realm = "incremental_test",
    MigrationOpts = [{prefix, "inc"}],

    TempDir = filename:join([?config(priv_dir, Config), "incremental_migrations"]),
    ok = filelib:ensure_dir(filename:join(TempDir, "dummy")),

    copy_migration(MigrationsDir, TempDir, "001_create_users.sql"),
    copy_migration(MigrationsDir, TempDir, "002_create_posts.sql.dtl"),
    copy_migration(MigrationsDir, TempDir, "003_create_comments.erl"),

    {ok, Executed1} = epg_migrator:perform(Realm, DbOpts, MigrationOpts, TempDir),
    ?assertEqual(3, length(Executed1)),

    copy_migration(MigrationsDir, TempDir, "004_insert_users.sql"),
    copy_migration(MigrationsDir, TempDir, "005_insert_posts.sql.dtl"),

    {ok, Executed2} = epg_migrator:perform(Realm, DbOpts, MigrationOpts, TempDir),
    ?assertEqual(2, length(Executed2)),
    ?assertEqual(<<"004_insert_users.sql">>, lists:nth(1, Executed2)),
    ?assertEqual(<<"005_insert_posts.sql.dtl">>, lists:nth(2, Executed2)),

    copy_migration(MigrationsDir, TempDir, "006_insert_comments.erl"),

    {ok, Executed3} = epg_migrator:perform(Realm, DbOpts, MigrationOpts, TempDir),
    ?assertEqual(1, length(Executed3)),
    ?assertEqual(<<"006_insert_comments.erl">>, lists:nth(1, Executed3)).

test_mixed_migrations_different_realms(Config) ->
    DbOpts = ?config(db_opts, Config),
    MigrationsDir = ?config(migrations_dir, Config),

    Realm1 = "realm_one",
    Realm2 = "realm_two",
    MigrationOpts1 = [{prefix, "r1"}],
    MigrationOpts2 = [{prefix, "r2"}],

    {ok, Executed1} = epg_migrator:perform(Realm1, DbOpts, MigrationOpts1, MigrationsDir),
    ?assertEqual(6, length(Executed1)),

    TempDir = filename:join([?config(priv_dir, Config), "realm2_migrations"]),
    ok = filelib:ensure_dir(filename:join(TempDir, "dummy")),

    copy_migration(MigrationsDir, TempDir, "002_create_posts.sql.dtl"),
    copy_migration(MigrationsDir, TempDir, "003_create_comments.erl"),
    copy_migration(MigrationsDir, TempDir, "005_insert_posts.sql.dtl"),
    copy_migration(MigrationsDir, TempDir, "006_insert_comments.erl"),

    {ok, Executed2} = epg_migrator:perform(Realm2, DbOpts, MigrationOpts2, TempDir),
    ?assertEqual(4, length(Executed2)),

    {ok, Conn} = connect(DbOpts),
    try
        {ok, _, _} = epgsql:equery(Conn, "SELECT * FROM users", []),

        {ok, _, _} = epgsql:equery(Conn, "SELECT * FROM r1_posts", []),
        {ok, _, _} = epgsql:equery(Conn, "SELECT * FROM r1_comments", []),

        {ok, _, _} = epgsql:equery(Conn, "SELECT * FROM r2_posts", []),
        {ok, _, _} = epgsql:equery(Conn, "SELECT * FROM r2_comments", []),

        {ok, Migrations1} = epg_migrator_storage:get_executed(Conn, Realm1),
        {ok, Migrations2} = epg_migrator_storage:get_executed(Conn, Realm2),

        ?assertEqual(6, length(Migrations1)),
        ?assertEqual(4, length(Migrations2))
    after
        epgsql:close(Conn)
    end.

test_mixed_rollback_on_failure(Config) ->
    DbOpts = ?config(db_opts, Config),
    MigrationsDir = ?config(migrations_dir, Config),
    Realm = "rollback_test",
    MigrationOpts = [{prefix, "fail"}],

    TempDir = filename:join([?config(priv_dir, Config), "rollback_migrations"]),
    ok = filelib:ensure_dir(filename:join(TempDir, "dummy")),

    copy_migration(MigrationsDir, TempDir, "001_create_users.sql"),
    copy_migration(MigrationsDir, TempDir, "002_create_posts.sql.dtl"),
    copy_migration(MigrationsDir, TempDir, "003_create_comments.erl"),

    Result1 = epg_migrator:perform(Realm, DbOpts, MigrationOpts, TempDir),

    ?assertEqual(
        {ok, [<<"001_create_users.sql">>, <<"002_create_posts.sql.dtl">>, <<"003_create_comments.erl">>]},
        Result1
    ),

    BadMigration = filename:join(TempDir, "004_bad_sql.sql"),
    ok = file:write_file(BadMigration, <<"INVALID SQL SYNTAX HERE;">>),

    Result2 = epg_migrator:perform(Realm, DbOpts, MigrationOpts, TempDir),

    ?assertMatch({error, _}, Result2),

    {ok, Conn} = connect(DbOpts),
    try
        {ok, Migrations} = epg_migrator_storage:get_executed(Conn, Realm),

        ?assertEqual(3, length(Migrations)),
        ?assertEqual(<<"001_create_users.sql">>, lists:nth(1, Migrations)),
        ?assertEqual(<<"002_create_posts.sql.dtl">>, lists:nth(2, Migrations)),
        ?assertEqual(<<"003_create_comments.erl">>, lists:nth(3, Migrations)),

        {ok, _, _} = epgsql:equery(Conn, "SELECT * FROM users", []),
        {ok, _, _} = epgsql:equery(Conn, "SELECT * FROM fail_posts", []),
        {ok, _, _} = epgsql:equery(Conn, "SELECT * FROM fail_comments", [])
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
