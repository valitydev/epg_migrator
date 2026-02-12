-module(epg_migrator_sql).

-export([
    execute/2
]).

%%%-----------------------------------------------------------------------------
%%% API
%%%-----------------------------------------------------------------------------

-spec execute(file:filename(), epgsql:connection()) -> ok | {error, term()}.
execute(FilePath, Conn) ->
    {ok, SqlContent} = file:read_file(FilePath),
    SQL = binary_to_list(SqlContent),
    case epgsql:squery(Conn, SQL) of
        {ok, _Count} ->
            ok;
        {ok, _Columns, _Rows} ->
            ok;
        Results when is_list(Results) ->
            case lists:all(fun is_ok_result/1, Results) of
                true ->
                    ok;
                false ->
                    {error, {sql_execution_failed, Results}}
            end;
        {error, Reason} ->
            {error, {sql_execution_failed, Reason}}
    end.

%%%-----------------------------------------------------------------------------
%%% Internal functions
%%%-----------------------------------------------------------------------------

-spec is_ok_result(term()) -> boolean().
is_ok_result({ok, _}) -> true;
is_ok_result({ok, _, _}) -> true;
is_ok_result(_) -> false.
