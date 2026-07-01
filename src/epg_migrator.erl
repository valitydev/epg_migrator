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
) -> {ok, [binary()]} | {error, Reason :: term()}.
perform(Realm, #{database := DbName} = DbOpts, MigrationOpts, MigrationsDir) ->
    {ok, AllMigrations} = epg_migrator_scanner:scan(MigrationsDir),
    {ok, Conn} = connect(DbOpts),
    Result =
        case setup(Conn, DbName) of
            {error, _} = Error ->
                Error;
            ok ->
                {ok, PreviouslyMigrated} = epg_migrator_storage:get_executed(Conn, Realm),
                PendingMigrations = epg_migrator_scanner:filter_pending(AllMigrations, PreviouslyMigrated),
                execute_migrations(Conn, Realm, DbName, MigrationOpts, MigrationsDir, PendingMigrations)
        end,
    ok = epgsql:close(Conn),
    Result.

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

-spec setup(epgsql:connection(), string()) -> ok | {error, term()}.
setup(Conn, DbName) ->
    try
        F = fun(C) ->
            ok = epg_migrator_storage:advisory_lock(C, DbName),
            epg_migrator_storage:ensure_table(C)
        end,
        ok = epgsql:with_transaction(Conn, F, [{reraise, true}])
    catch
        error:Reason:Stacktrace ->
            ok = logger:error(
                "Failed to setup migration table in database '~s' with reason: ~p and stacktrace: ~p",
                [DbName, Reason, Stacktrace]
            ),
            {error, Reason}
    end.

-spec execute_migrations(
    epgsql:connection(),
    string() | binary(),
    string(),
    proplists:proplist(),
    file:filename(),
    [binary()]
) -> {ok, [binary()]} | {error, term()}.
execute_migrations(Conn, Realm, DbName, MigrationOpts, MigrationsDir, PendingMigrations) ->
    try
        F = fun(Migration, Executed) ->
            case execute_migration(Conn, Realm, DbName, MigrationOpts, MigrationsDir, Migration) of
                ok -> [Migration | Executed];
                already_applied -> Executed
            end
        end,
        ExecutedMigrations = lists:foldl(F, [], PendingMigrations),
        {ok, lists:reverse(ExecutedMigrations)}
    catch
        error:Reason ->
            {error, Reason}
    end.

-spec execute_migration(
    epgsql:connection(),
    string() | binary(),
    string(),
    proplists:proplist(),
    file:filename(),
    binary()
) -> ok | already_applied | no_return().
execute_migration(Conn, Realm, DbName, MigrationOpts, MigrationsDir, Migration) ->
    F = fun(C) ->
        ok = epg_migrator_storage:advisory_lock(C, DbName),
        {ok, ExecutedMigrations} = epg_migrator_storage:get_executed(C, Realm),
        case lists:member(Migration, ExecutedMigrations) of
            true ->
                already_applied;
            false ->
                FilePath = filename:join(MigrationsDir, binary_to_list(Migration)),
                MigrationType = epg_migrator_scanner:get_migration_type(Migration),
                ok = epg_migrator_executor:execute(MigrationType, FilePath, Conn, MigrationOpts),
                ok = epg_migrator_storage:save_migration(Conn, Realm, Migration)
        end
    end,
    try
        epgsql:with_transaction(Conn, F, [{reraise, true}])
    catch
        Class:Reason:Stacktrace ->
            ok = logger:error(
                "Migration '~s' failed with '~s' reason: ~p and stacktrace: ~p",
                [Migration, Class, Reason, Stacktrace]
            ),
            erlang:raise(Class, Reason, Stacktrace)
    end.
