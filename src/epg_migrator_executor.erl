-module(epg_migrator_executor).

-export([
    execute/4
]).

%%%-----------------------------------------------------------------------------
%%% API
%%%-----------------------------------------------------------------------------

-spec execute(
    MigrationType :: atom(),
    FilePath :: file:filename(),
    Conn :: epgsql:connection(),
    MigrationOpts :: proplists:proplist()
) -> ok | {error, term()}.
execute(sql, FilePath, Conn, _MigrationOpts) ->
    epg_migrator_sql:execute(FilePath, Conn);
execute(dtl, FilePath, Conn, MigrationOpts) ->
    epg_migrator_dtl:execute(FilePath, Conn, MigrationOpts);
execute(erl, FilePath, Conn, MigrationOpts) ->
    epg_migrator_erl:execute(FilePath, Conn, MigrationOpts);
execute(unknown, _FilePath, _Conn, _MigrationOpts) ->
    {error, unknown_migration_type}.
