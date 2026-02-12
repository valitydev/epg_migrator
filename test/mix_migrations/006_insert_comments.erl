-module('006_insert_comments').
-export([perform/2]).

%% @doc Erlang миграция: вставляет тестовые комментарии
perform(Conn, MigrationOpts) ->
    Prefix = proplists:get_value(prefix, MigrationOpts, "app"),
    CommentsTable = Prefix ++ "_comments",
    
    %% Вставляем комментарии для разных постов
    Comments = [
        {1, 1, "Great post, Alice!"},
        {1, 2, "Thanks for sharing!"},
        {2, 1, "Nice to meet you, Bob!"},
        {2, 3, "Welcome to the community!"},
        {3, 2, "Interesting thoughts, Charlie!"}
    ],
    
    lists:foreach(fun({PostId, UserId, Content}) ->
        InsertSQL = lists:flatten(io_lib:format(
            "INSERT INTO ~s (post_id, user_id, content) VALUES (~p, ~p, '~s')",
            [CommentsTable, PostId, UserId, Content]
        )),
        {ok, 1} = epgsql:squery(Conn, InsertSQL)
    end, Comments),
    
    ok.