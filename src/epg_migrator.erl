-module(epg_migrator).

-export([
    perform/4
]).

%%%-----------------------------------------------------------------------------
%%% API
%%%-----------------------------------------------------------------------------

-spec perform(
    Realm :: string() | binary(),
    DbOpts :: #{
        host := string(),
        port := integer(),
        database := string(),
        username := string(),
        password := string()
    },
    MigrationOpts :: proplists:proplist(),
    MigrationsDir :: file:filename()
) -> {ok, [binary()]} | {error, term()}.
perform(Realm, #{database := DbName} = DbOpts, MigrationOpts, MigrationsDir) ->
    {ok, AllMigrations} = epg_migrator_scanner:scan(MigrationsDir),
    {ok, Conn} = connect(DbOpts),
    Result = epgsql:with_transaction(
        Conn,
        fun(C) ->
            ok = epg_migrator_storage:advisory_lock(C, DbName),
            ok = epg_migrator_storage:ensure_table(C),
            {ok, ExecutedMigrations} = epg_migrator_storage:get_executed(C, Realm),
            PendingMigrations = epg_migrator_scanner:filter_pending(AllMigrations, ExecutedMigrations),
            execute_migrations(C, Realm, MigrationsDir, PendingMigrations, MigrationOpts)
        end
    ),
    ok = epgsql:close(Conn),
    case Result of
        {ok, _} = OK ->
            OK;
        {rollback, Error} ->
            {error, Error}
    end.

%%%-----------------------------------------------------------------------------
%%% Internal functions
%%%-----------------------------------------------------------------------------

-spec connect(map()) -> {ok, epgsql:connection()} | {error, term()}.
connect(#{host := Host, port := Port, database := Database, username := Username, password := Password}) ->
    epgsql:connect(Host, Username, Password, [
        {database, Database},
        {port, Port},
        {timeout, 10000}
    ]).

-spec execute_migrations(
    epgsql:connection(),
    string() | binary(),
    file:filename(),
    [binary()],
    proplists:proplist()
) -> {ok, [binary()]} | {error, term()}.
execute_migrations(_Conn, _Realm, _MigrationsDir, [], _MigrationOpts) ->
    {ok, []};
execute_migrations(Conn, Realm, MigrationsDir, PendingMigrations, MigrationOpts) ->
    execute_migrations_loop(Conn, Realm, MigrationsDir, PendingMigrations, MigrationOpts, []).

-spec execute_migrations_loop(
    epgsql:connection(),
    string() | binary(),
    file:filename(),
    [binary()],
    proplists:proplist(),
    [binary()]
) -> {ok, [binary()]} | {error, term()}.
execute_migrations_loop(_Conn, _Realm, _MigrationsDir, [], _MigrationOpts, Executed) ->
    {ok, lists:reverse(Executed)};
execute_migrations_loop(Conn, Realm, MigrationsDir, [Migration | Rest], MigrationOpts, Executed) ->
    FilePath = filename:join(MigrationsDir, binary_to_list(Migration)),
    MigrationType = epg_migrator_scanner:get_migration_type(Migration),
    ok = epg_migrator_executor:execute(MigrationType, FilePath, Conn, MigrationOpts),
    ok = epg_migrator_storage:save_migration(Conn, Realm, Migration),
    execute_migrations_loop(
        Conn,
        Realm,
        MigrationsDir,
        Rest,
        MigrationOpts,
        [Migration | Executed]
    ).
