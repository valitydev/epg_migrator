-module('001_create_users_table').
-export([perform/2]).

%% @doc Создаёт таблицу users
perform(Conn, MigrationOpts) ->
    TablePrefix = proplists:get_value(table_prefix, MigrationOpts, ""),
    TableName = TablePrefix ++ "users",
    
    CreateTableSQL = lists:flatten(io_lib:format(
        "CREATE TABLE ~s ("
        "id SERIAL PRIMARY KEY, "
        "username VARCHAR(255) NOT NULL UNIQUE, "
        "email VARCHAR(255) NOT NULL, "
        "created_at TIMESTAMP NOT NULL DEFAULT NOW()"
        ")",
        [TableName]
    )),
    
    {ok, [], []} = epgsql:squery(Conn, CreateTableSQL),
    
    %% Создаём индексы
    IndexUsername = lists:flatten(io_lib:format(
        "CREATE INDEX idx_~s_username ON ~s(username)",
        [TableName, TableName]
    )),
    {ok, [], []} = epgsql:squery(Conn, IndexUsername),
    
    IndexEmail = lists:flatten(io_lib:format(
        "CREATE INDEX idx_~s_email ON ~s(email)",
        [TableName, TableName]
    )),
    {ok, [], []} = epgsql:squery(Conn, IndexEmail),
    
    ok.