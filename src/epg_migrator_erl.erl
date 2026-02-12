-module(epg_migrator_erl).

-export([
    execute/3
]).

%%%-----------------------------------------------------------------------------
%%% API
%%%-----------------------------------------------------------------------------

-spec execute(file:filename(), epgsql:connection(), proplists:proplist()) -> ok | {error, term()}.
execute(FilePath, Conn, MigrationOpts) ->
    {ok, ModuleName, Binary} = compile:file(FilePath, [binary]),
    {module, ModuleName} = code:load_binary(ModuleName, FilePath, Binary),
    case erlang:apply(ModuleName, perform, [Conn, MigrationOpts]) of
        ok ->
            cleanup_module(ModuleName),
            ok;
        {ok, _Result} ->
            cleanup_module(ModuleName),
            ok;
        {error, Reason} ->
            cleanup_module(ModuleName),
            {error, {migration_failed, Reason}};
        Other ->
            cleanup_module(ModuleName),
            {error, {unexpected_return, Other}}
    end.

%%%-----------------------------------------------------------------------------
%%% Internal functions
%%%-----------------------------------------------------------------------------

-spec cleanup_module(atom()) -> ok.
cleanup_module(ModuleName) ->
    code:purge(ModuleName),
    code:delete(ModuleName),
    ok.
