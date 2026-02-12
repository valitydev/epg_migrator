-module(epg_migrator_scanner).

-export([
    scan/1,
    get_migration_type/1,
    filter_pending/2
]).

-type migration_type() :: sql | dtl | erl | unknown.

%%%-----------------------------------------------------------------------------
%%% API
%%%-----------------------------------------------------------------------------

-spec scan(file:filename()) -> {ok, [binary()]} | {error, term()}.
scan(MigrationsDir) ->
    case filelib:is_dir(MigrationsDir) of
        true ->
            case file:list_dir(MigrationsDir) of
                {ok, Files} ->
                    MigrationFiles = lists:filter(
                        fun(File) ->
                            not lists:prefix(".", File) andalso
                                filelib:is_regular(filename:join(MigrationsDir, File)) andalso
                                is_migration_file(File)
                        end,
                        Files
                    ),
                    SortedFiles = lists:sort(MigrationFiles),
                    BinaryFiles = [list_to_binary(F) || F <- SortedFiles],
                    {ok, BinaryFiles};
                {error, Reason} ->
                    {error, {list_dir_failed, Reason}}
            end;
        false ->
            {error, {not_a_directory, MigrationsDir}}
    end.

-spec get_migration_type(binary() | string()) -> migration_type().
get_migration_type(FileName) when is_binary(FileName) ->
    get_migration_type(binary_to_list(FileName));
get_migration_type(FileName) when is_list(FileName) ->
    case lists:suffix(".sql.dtl", FileName) of
        true ->
            dtl;
        false ->
            case lists:suffix(".sql", FileName) of
                true ->
                    sql;
                false ->
                    case lists:suffix(".erl", FileName) of
                        true ->
                            erl;
                        false ->
                            unknown
                    end
            end
    end.

-spec filter_pending([binary()], [binary()]) -> [binary()].
filter_pending(AllMigrations, ExecutedMigrations) ->
    lists:filter(
        fun(Migration) ->
            not lists:member(Migration, ExecutedMigrations)
        end,
        AllMigrations
    ).

%%%-----------------------------------------------------------------------------
%%% Internal functions
%%%-----------------------------------------------------------------------------

-spec is_migration_file(string()) -> boolean().
is_migration_file(FileName) ->
    Type = get_migration_type(FileName),
    Type =/= unknown.
