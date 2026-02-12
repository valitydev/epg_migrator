-module('003_insert_test_data').
-export([perform/2]).

%% @doc Вставляет тестовые данные в таблицы users и posts
perform(Conn, MigrationOpts) ->
    TablePrefix = proplists:get_value(table_prefix, MigrationOpts, ""),
    UsersTable = TablePrefix ++ "users",
    PostsTable = TablePrefix ++ "posts",
    
    %% Вставляем пользователей
    InsertUsersSQL = lists:flatten(io_lib:format(
        "INSERT INTO ~s (username, email) VALUES "
        "('alice', 'alice@example.com'), "
        "('bob', 'bob@example.com'), "
        "('charlie', 'charlie@example.com')",
        [UsersTable]
    )),
    {ok, 3} = epgsql:squery(Conn, InsertUsersSQL),
    
    %% Вставляем посты
    InsertPostsSQL = lists:flatten(io_lib:format(
        "INSERT INTO ~s (user_id, title, content, published) VALUES "
        "(1, 'First Post', 'This is Alice''s first post', true), "
        "(1, 'Second Post', 'This is Alice''s second post', false), "
        "(2, 'Bob''s Post', 'Hello from Bob', true), "
        "(3, 'Charlie''s Thoughts', 'Some interesting thoughts', true)",
        [PostsTable]
    )),
    {ok, 4} = epgsql:squery(Conn, InsertPostsSQL),
    
    ok.