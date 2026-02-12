-module('003_create_comments').
-export([perform/2]).

%% @doc Erlang миграция: создаёт таблицу comments
perform(Conn, MigrationOpts) ->
    Prefix = proplists:get_value(prefix, MigrationOpts, "app"),
    PostsTable = Prefix ++ "_posts",
    CommentsTable = Prefix ++ "_comments",
    
    CreateTableSQL = lists:flatten(io_lib:format(
        "CREATE TABLE ~s ("
        "id SERIAL PRIMARY KEY, "
        "post_id INTEGER NOT NULL REFERENCES ~s(id) ON DELETE CASCADE, "
        "user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE, "
        "content TEXT NOT NULL, "
        "created_at TIMESTAMP NOT NULL DEFAULT NOW()"
        ")",
        [CommentsTable, PostsTable]
    )),
    
    {ok, [], []} = epgsql:squery(Conn, CreateTableSQL),
    
    %% Создаём индексы
    IndexPostId = lists:flatten(io_lib:format(
        "CREATE INDEX idx_~s_post_id ON ~s(post_id)",
        [CommentsTable, CommentsTable]
    )),
    {ok, [], []} = epgsql:squery(Conn, IndexPostId),
    
    IndexUserId = lists:flatten(io_lib:format(
        "CREATE INDEX idx_~s_user_id ON ~s(user_id)",
        [CommentsTable, CommentsTable]
    )),
    {ok, [], []} = epgsql:squery(Conn, IndexUserId),
    
    ok.