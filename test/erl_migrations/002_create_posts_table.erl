-module('002_create_posts_table').
-export([perform/2]).

%% @doc Создаёт таблицу posts
perform(Conn, MigrationOpts) ->
    TablePrefix = proplists:get_value(table_prefix, MigrationOpts, ""),
    UsersTable = TablePrefix ++ "users",
    PostsTable = TablePrefix ++ "posts",
    
    CreateTableSQL = lists:flatten(io_lib:format(
        "CREATE TABLE ~s ("
        "id SERIAL PRIMARY KEY, "
        "user_id INTEGER NOT NULL REFERENCES ~s(id) ON DELETE CASCADE, "
        "title VARCHAR(500) NOT NULL, "
        "content TEXT, "
        "published BOOLEAN NOT NULL DEFAULT false, "
        "created_at TIMESTAMP NOT NULL DEFAULT NOW(), "
        "updated_at TIMESTAMP NOT NULL DEFAULT NOW()"
        ")",
        [PostsTable, UsersTable]
    )),
    
    {ok, [], []} = epgsql:squery(Conn, CreateTableSQL),
    
    %% Создаём индексы
    IndexUserId = lists:flatten(io_lib:format(
        "CREATE INDEX idx_~s_user_id ON ~s(user_id)",
        [PostsTable, PostsTable]
    )),
    {ok, [], []} = epgsql:squery(Conn, IndexUserId),
    
    IndexPublished = lists:flatten(io_lib:format(
        "CREATE INDEX idx_~s_published ON ~s(published)",
        [PostsTable, PostsTable]
    )),
    {ok, [], []} = epgsql:squery(Conn, IndexPublished),
    
    IndexCreatedAt = lists:flatten(io_lib:format(
        "CREATE INDEX idx_~s_created_at ON ~s(created_at)",
        [PostsTable, PostsTable]
    )),
    {ok, [], []} = epgsql:squery(Conn, IndexCreatedAt),
    
    ok.