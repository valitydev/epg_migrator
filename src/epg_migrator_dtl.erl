-module(epg_migrator_dtl).

-export([
    execute/3
]).

%%%-----------------------------------------------------------------------------
%%% API
%%%-----------------------------------------------------------------------------

-spec execute(file:filename(), epgsql:connection(), proplists:proplist()) -> ok | {error, term()}.
execute(FilePath, Conn, MigrationOpts) ->
    {ok, TemplateContent} = file:read_file(FilePath),
    ModuleName = generate_module_name(FilePath),
    {ok, ModuleName} = erlydtl:compile_template(TemplateContent, ModuleName, [{out_dir, false}]),
    {ok, RenderedSQL} = ModuleName:render(MigrationOpts),
    SQL = binary_to_list(iolist_to_binary(RenderedSQL)),

    case epgsql:squery(Conn, SQL) of
        {ok, _Count} ->
            cleanup_module(ModuleName),
            ok;
        {ok, _Columns, _Rows} ->
            cleanup_module(ModuleName),
            ok;
        Results when is_list(Results) ->
            case lists:all(fun is_ok_result/1, Results) of
                true ->
                    cleanup_module(ModuleName),
                    ok;
                false ->
                    cleanup_module(ModuleName),
                    {error, {sql_execution_failed, Results}}
            end;
        {error, Reason} ->
            cleanup_module(ModuleName),
            {error, {sql_execution_failed, Reason}}
    end.

%%%-----------------------------------------------------------------------------
%%% Internal functions
%%%-----------------------------------------------------------------------------

-spec generate_module_name(file:filename()) -> atom().
generate_module_name(FilePath) ->
    FileName = filename:basename(FilePath),
    BaseName = filename:rootname(filename:rootname(FileName)),
    Timestamp = erlang:system_time(microsecond),
    ModuleName = lists:flatten(io_lib:format("dtl_migration_~s_~p", [BaseName, Timestamp])),
    SafeName = re:replace(ModuleName, "[^a-zA-Z0-9_]", "_", [global, {return, list}]),
    list_to_atom(SafeName).

-spec is_ok_result(term()) -> boolean().
is_ok_result({ok, _}) -> true;
is_ok_result({ok, _, _}) -> true;
is_ok_result(_) -> false.

-spec cleanup_module(atom()) -> ok.
cleanup_module(ModuleName) ->
    code:purge(ModuleName),
    code:delete(ModuleName),
    ok.
