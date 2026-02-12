-- Третья тестовая миграция: добавление тестовых данных
INSERT INTO users (username, email) VALUES
    ('alice', 'alice@example.com'),
    ('bob', 'bob@example.com'),
    ('charlie', 'charlie@example.com');

INSERT INTO posts (user_id, title, content, published) VALUES
    (1, 'First Post', 'This is Alice''s first post', true),
    (1, 'Second Post', 'This is Alice''s second post', false),
    (2, 'Bob''s Post', 'Hello from Bob', true),
    (3, 'Charlie''s Thoughts', 'Some interesting thoughts', true);
