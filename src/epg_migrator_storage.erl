-module(epg_migrator_storage).

-export([
    ensure_table/1,
    get_executed/2,
    save_migration/3
]).

-define(MIGRATIONS_TABLE, "schema_migrations").

%%%-----------------------------------------------------------------------------
%%% API
%%%-----------------------------------------------------------------------------

-spec ensure_table(epgsql:connection()) -> ok | {error, term()}.
ensure_table(Conn) ->
    SQL =
        "CREATE TABLE IF NOT EXISTS "
        ?MIGRATIONS_TABLE
        " ("
        "realm VARCHAR(255) NOT NULL, "
        "migration_file_name VARCHAR(255) NOT NULL, "
        "executed_at TIMESTAMP NOT NULL DEFAULT NOW(), "
        "PRIMARY KEY (realm, migration_file_name)"
        ");"
        "LOCK TABLE "
        ?MIGRATIONS_TABLE
        " IN ACCESS EXCLUSIVE MODE;",
    case epgsql:squery(Conn, SQL) of
        {ok, _Columns, _Rows} ->
            ok;
        Results when is_list(Results) ->
            case lists:all(fun is_ok_result/1, Results) of
                true ->
                    ok;
                false ->
                    {error, create_lock_table_failed}
            end;
        {error, Reason} ->
            {error, {create_lock_table_failed, Reason}}
    end.

-spec get_executed(epgsql:connection(), string() | binary()) -> {ok, [binary()]} | {error, term()}.
get_executed(Conn, Realm) when is_list(Realm) ->
    get_executed(Conn, list_to_binary(Realm));
get_executed(Conn, Realm) when is_binary(Realm) ->
    SQL = iolist_to_binary([
        "SELECT migration_file_name FROM ",
        ?MIGRATIONS_TABLE,
        " WHERE realm = $1 ORDER BY migration_file_name"
    ]),
    case epgsql:equery(Conn, SQL, [Realm]) of
        {ok, _Columns, Rows} ->
            Migrations = [FileName || {FileName} <- Rows],
            {ok, Migrations};
        {error, Reason} ->
            {error, {query_failed, Reason}}
    end.

-spec save_migration(epgsql:connection(), string() | binary(), binary()) -> ok | {error, term()}.
save_migration(Conn, Realm, FileName) when is_list(Realm) ->
    save_migration(Conn, list_to_binary(Realm), FileName);
save_migration(Conn, Realm, FileName) when is_binary(Realm), is_binary(FileName) ->
    SQL = iolist_to_binary([
        "INSERT INTO ",
        ?MIGRATIONS_TABLE,
        " (realm, migration_file_name) VALUES ($1, $2)"
    ]),
    case epgsql:equery(Conn, SQL, [Realm, FileName]) of
        {ok, _Count} ->
            ok;
        {error, Reason} ->
            {error, {insert_failed, Reason}}
    end.

is_ok_result({ok, _}) -> true;
is_ok_result({ok, _, _}) -> true;
is_ok_result(_) -> false.
