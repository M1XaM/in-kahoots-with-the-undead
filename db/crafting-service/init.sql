-- Crafting Service schema + seed recipes.
-- Runs once on an empty database (mounted into /docker-entrypoint-initdb.d/),
-- and is safe to re-run: the table is created only if missing and the seed is
-- inserted only while `recipes` is empty.
--
-- Columns match what GORM's AutoMigrate creates, so the service sees no difference.
-- Output items are the ones seeded into Player's catalogue (db/player-service/init.sql).
-- Recipes 4 and 5 are gated: 4 needs player level 2, 5 needs a passed math exam and
-- the Math Wing (wingId 4 in World's seed).

CREATE TABLE IF NOT EXISTS recipes (
    id               BIGSERIAL PRIMARY KEY,
    name             text NOT NULL,
    inputs           text NOT NULL,
    output_item_id   text,
    output_name      text,
    output_quantity  bigint,
    requires_level   bigint,
    requires_subject text,
    requires_wing_id bigint,
    created_at       timestamp with time zone,
    updated_at       timestamp with time zone
);

INSERT INTO recipes (name, inputs, output_item_id, output_name, output_quantity,
                     requires_level, requires_subject, requires_wing_id, created_at, updated_at)
SELECT v.*, now(), now() FROM (VALUES
    ('Barricade Kit',     '{"wood":4,"metal":2}',      'barricade_kit',     'Barricade Kit',     1, NULL::bigint, NULL,   NULL::bigint),
    ('Coffee',            '{"food":2}',                'coffee',            'Coffee',            1, NULL,         NULL,   NULL),
    ('Improvised Weapon', '{"wood":2,"metal":3}',      'improvised_weapon', 'Improvised Weapon', 1, NULL,         NULL,   NULL),
    ('Energy Drink',      '{"food":3,"chemicals":1}',  'energy_drink',      'Energy Drink',      1, 2,            NULL,   NULL),
    ('Cheat Sheet',       '{"paper":3,"textbooks":1}', 'cheat_sheet',       'Cheat Sheet',       1, NULL,         'math', 4)
) AS v
WHERE NOT EXISTS (SELECT 1 FROM recipes);
