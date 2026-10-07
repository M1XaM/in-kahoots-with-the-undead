-- Player Service item catalogue.
-- Runs once on an empty database (mounted into /docker-entrypoint-initdb.d/),
-- and is safe to re-run: the table is created only if missing and rows that
-- already exist are left alone.
--
-- Only the catalogue is seeded; Player creates its other tables itself. These are
-- the items Base (Kiki rewards) and Crafting (recipe outputs) deliver into
-- inventories; without them every delivery ends in `422 UNKNOWN_ITEM`.

CREATE TABLE IF NOT EXISTS items (
    item_id character varying(64) NOT NULL,
    name    text                  NOT NULL,
    type    character varying(20) NOT NULL,
    CONSTRAINT items_pkey PRIMARY KEY (item_id)
);

INSERT INTO items (item_id, name, type) VALUES
    ('coffee',            'Coffee',            'consumable'),
    ('energy_drink',      'Energy Drink',      'consumable'),
    ('cheat_sheet',       'Cheat Sheet',       'consumable'),
    ('barricade_kit',     'Barricade Kit',     'equipment'),
    ('improvised_weapon', 'Improvised Weapon', 'equipment')
ON CONFLICT (item_id) DO NOTHING;
