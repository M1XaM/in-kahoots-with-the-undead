-- Data warehouse ETL, applied by run.sh before every run (everything here is idempotent, so a
-- changed file takes effect on the next run without recreating warehouse-db).
--
--   extract   every source database is a postgres_fdw server (src_<name>); its public schema is
--             re-imported as foreign tables into fdw_<name> on each run, so new tables and columns
--             appear by themselves. The sources point at the clusters' replica port (5433), so the
--             ETL never loads a primary.
--   load      each foreign table is copied into staging_<name>.<table> (a full snapshot), minus
--             service plumbing (idempotency keys, processed-event logs) and secrets (password_hash)
--   transform the snapshots are joined across services into the star schema in `dw`
--             (dim_* / fact_*), with report views on top
--
-- Each source and each dw table is its own step: a failing one (a source down, a renamed column)
-- is logged in etl.runs and keeps its previous data, the others carry on.

CREATE EXTENSION IF NOT EXISTS postgres_fdw;
CREATE SCHEMA IF NOT EXISTS etl;
CREATE SCHEMA IF NOT EXISTS dw;

CREATE TABLE IF NOT EXISTS etl.sources (
    name       text PRIMARY KEY,
    host       text NOT NULL,
    port       int  NOT NULL,
    dbname     text NOT NULL,
    updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS etl.runs (
    id          bigserial PRIMARY KEY,
    run_id      bigint      NOT NULL,
    step        text        NOT NULL,
    status      text        NOT NULL CHECK (status IN ('ok', 'failed')),
    rows        bigint,
    started_at  timestamptz NOT NULL,
    finished_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    error       text
);
CREATE INDEX IF NOT EXISTS runs_run_id_idx ON etl.runs (run_id);
CREATE SEQUENCE IF NOT EXISTS etl.run_seq;

-- tables that are bookkeeping, not business data
CREATE OR REPLACE FUNCTION etl.skipped_table(t text) RETURNS boolean LANGUAGE sql IMMUTABLE AS $$
    SELECT t IN ('idempotency_keys', 'processed_events', 'consumer_offsets', 'presence_sockets')
$$;

-- columns never copied into the warehouse
CREATE OR REPLACE FUNCTION etl.skipped_column(c text) RETURNS boolean LANGUAGE sql IMMUTABLE AS $$
    SELECT c IN ('password_hash')
$$;

-- (re)points the foreign server and user mapping of one source; called by run.sh with the values
-- from ETL_SOURCES, so a changed host or password applies on the next run
CREATE OR REPLACE FUNCTION etl.register_source(p_name text, p_host text, p_port int, p_db text,
                                               p_user text, p_password text) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
    srv text := 'src_' || p_name;
BEGIN
    IF EXISTS (SELECT 1 FROM pg_foreign_server WHERE srvname = srv) THEN
        EXECUTE format('ALTER SERVER %I OPTIONS (SET host %L, SET port %L, SET dbname %L)',
                       srv, p_host, p_port::text, p_db);
    ELSE
        EXECUTE format('CREATE SERVER %I FOREIGN DATA WRAPPER postgres_fdw OPTIONS (host %L, port %L, dbname %L, connect_timeout %L)',
                       srv, p_host, p_port::text, p_db, '5');
    END IF;
    EXECUTE format('DROP USER MAPPING IF EXISTS FOR CURRENT_USER SERVER %I', srv);
    EXECUTE format('CREATE USER MAPPING FOR CURRENT_USER SERVER %I OPTIONS (user %L, password %L)',
                   srv, p_user, p_password);
    INSERT INTO etl.sources (name, host, port, dbname) VALUES (p_name, p_host, p_port, p_db)
    ON CONFLICT (name) DO UPDATE SET host = excluded.host, port = excluded.port,
                                     dbname = excluded.dbname, updated_at = now();
END $$;

-- extract + load of one source: a fresh snapshot of every business table in staging_<name>
CREATE OR REPLACE FUNCTION etl.extract_source(p_run bigint, p_name text) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
    fdw     text := 'fdw_' || p_name;
    stg     text := 'staging_' || p_name;
    started timestamptz := clock_timestamp();
    t       record;
    cols    text;
    n       bigint;
    total   bigint := 0;
BEGIN
    EXECUTE format('DROP SCHEMA IF EXISTS %I CASCADE', fdw);
    EXECUTE format('CREATE SCHEMA %I', fdw);
    EXECUTE format('IMPORT FOREIGN SCHEMA public FROM SERVER %I INTO %I', 'src_' || p_name, fdw);
    EXECUTE format('CREATE SCHEMA IF NOT EXISTS %I', stg);

    FOR t IN SELECT foreign_table_name AS name FROM information_schema.foreign_tables
             WHERE foreign_table_schema = fdw AND NOT etl.skipped_table(foreign_table_name)
             ORDER BY 1
    LOOP
        SELECT string_agg(format('%I', column_name), ', ' ORDER BY ordinal_position) INTO cols
        FROM information_schema.columns
        WHERE table_schema = fdw AND table_name = t.name AND NOT etl.skipped_column(column_name);

        -- replaced inside this step's transaction: readers see the old snapshot until it commits
        EXECUTE format('DROP TABLE IF EXISTS %I.%I', stg, t.name);
        EXECUTE format('CREATE TABLE %I.%I AS SELECT %s, now() AS _loaded_at FROM %I.%I',
                       stg, t.name, cols, fdw, t.name);
        GET DIAGNOSTICS n = ROW_COUNT;
        total := total + n;
    END LOOP;

    INSERT INTO etl.runs (run_id, step, status, rows, started_at)
    VALUES (p_run, 'extract ' || p_name, 'ok', total, started);
EXCEPTION WHEN OTHERS THEN
    -- everything above is rolled back: staging_<name> keeps the previous snapshot
    INSERT INTO etl.runs (run_id, step, status, started_at, error)
    VALUES (p_run, 'extract ' || p_name, 'failed', started, SQLERRM);
END $$;

-- transform of one dw table: replaced by the result of p_query, or left as it was on failure
CREATE OR REPLACE FUNCTION etl.load_table(p_run bigint, p_table text, p_query text) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
    started timestamptz := clock_timestamp();
    n       bigint;
BEGIN
    EXECUTE format('TRUNCATE %s', p_table);
    EXECUTE format('INSERT INTO %s %s', p_table, p_query);
    GET DIAGNOSTICS n = ROW_COUNT;
    INSERT INTO etl.runs (run_id, step, status, rows, started_at)
    VALUES (p_run, 'transform ' || p_table, 'ok', n, started);
EXCEPTION WHEN OTHERS THEN
    INSERT INTO etl.runs (run_id, step, status, started_at, error)
    VALUES (p_run, 'transform ' || p_table, 'failed', started, SQLERRM);
END $$;

-- ---------------------------------------------------------------------------------------------
-- Star schema
-- ---------------------------------------------------------------------------------------------

-- a player across services: Player's profile with the state of their base (Base Service)
CREATE TABLE IF NOT EXISTS dw.dim_player (
    player_id        bigint PRIMARY KEY,
    username         text,
    level            bigint,
    xp               bigint,
    registered_at    timestamptz,
    base_level       bigint,
    storage_capacity bigint,
    facilities       bigint,
    barricades       bigint
);

CREATE TABLE IF NOT EXISTS dw.dim_item (
    item_id text PRIMARY KEY,
    name    text,
    type    text
);

CREATE TABLE IF NOT EXISTS dw.dim_zombie (
    zombie_id int PRIMARY KEY,
    type      text,
    name      text,
    subject   text
);

-- World's rooms with their wing
CREATE TABLE IF NOT EXISTS dw.dim_location (
    room_id       int PRIMARY KEY,
    room_name     text,
    room_type     text,
    wing_id       int,
    wing_name     text,
    wing_unlocked boolean
);

CREATE TABLE IF NOT EXISTS dw.fact_craft (
    craft_id    text PRIMARY KEY,
    player_id   bigint,
    recipe_id   bigint,
    recipe_name text,
    item_id     text,
    quantity    bigint,
    status      text,
    crafted_at  timestamptz,
    crafted_day date
);

CREATE TABLE IF NOT EXISTS dw.fact_exam (
    exam_id   int PRIMARY KEY,
    player_id int,
    zombie_id int,
    subject   text,
    passed    boolean,
    grade     int,
    correct   int,
    total     int,
    taken_at  timestamptz,
    taken_day date
);

-- every change of a player's resources (Resource's ledger), placed in the room of its node
CREATE TABLE IF NOT EXISTS dw.fact_resource (
    entry_id      uuid PRIMARY KEY,
    player_id     int,
    kind          text,
    resource_type text,
    amount        int,
    node_id       int,
    room_id       int,
    occurred_at   timestamptz,
    occurred_day  date
);

-- every domain event the services published (their outboxes)
CREATE TABLE IF NOT EXISTS dw.fact_event (
    source       text,
    event_id     uuid,
    type         text,
    occurred_at  timestamptz,
    occurred_day date,
    PRIMARY KEY (source, event_id)
);

CREATE OR REPLACE VIEW dw.player_report AS
SELECT p.player_id, p.username, p.level, p.xp, p.base_level, p.barricades,
       coalesce(c.crafts, 0)             AS crafts,
       coalesce(e.exams, 0)              AS exams_taken,
       coalesce(e.passed, 0)             AS exams_passed,
       e.avg_grade,
       coalesce(r.gathered, 0)           AS resources_gathered,
       coalesce(r.spent, 0)              AS resources_spent
FROM dw.dim_player p
LEFT JOIN (SELECT player_id, count(*) AS crafts FROM dw.fact_craft GROUP BY 1) c USING (player_id)
LEFT JOIN (SELECT player_id, count(*) AS exams, count(*) FILTER (WHERE passed) AS passed,
                  round(avg(grade), 2) AS avg_grade
           FROM dw.fact_exam GROUP BY 1) e USING (player_id)
LEFT JOIN (SELECT player_id, sum(amount) FILTER (WHERE amount > 0) AS gathered,
                  -sum(amount) FILTER (WHERE amount < 0) AS spent
           FROM dw.fact_resource GROUP BY 1) r USING (player_id);

CREATE OR REPLACE VIEW dw.daily_activity AS
SELECT day,
       sum(registrations) AS registrations, sum(crafts) AS crafts,
       sum(exams) AS exams, sum(resource_changes) AS resource_changes, sum(events) AS events
FROM (
    SELECT registered_at::date AS day, 1 AS registrations, 0 AS crafts, 0 AS exams, 0 AS resource_changes, 0 AS events FROM dw.dim_player
    UNION ALL SELECT crafted_day, 0, 1, 0, 0, 0 FROM dw.fact_craft
    UNION ALL SELECT taken_day, 0, 0, 1, 0, 0 FROM dw.fact_exam
    UNION ALL SELECT occurred_day, 0, 0, 0, 1, 0 FROM dw.fact_resource
    UNION ALL SELECT occurred_day, 0, 0, 0, 0, 1 FROM dw.fact_event
) a
WHERE day IS NOT NULL
GROUP BY day;

-- the latest run, one line per step
CREATE OR REPLACE VIEW etl.last_run AS
SELECT step, status, rows, round(extract(epoch FROM finished_at - started_at)::numeric * 1000) AS ms, error
FROM etl.runs WHERE run_id = (SELECT max(run_id) FROM etl.runs)
ORDER BY id;

-- one whole run: every source, then every dw table. A procedure so each step commits on its own.
CREATE OR REPLACE PROCEDURE etl.run() LANGUAGE plpgsql AS $$
DECLARE
    run bigint := nextval('etl.run_seq');
    s   record;
BEGIN
    FOR s IN SELECT name FROM etl.sources ORDER BY name LOOP
        PERFORM etl.extract_source(run, s.name);
        COMMIT;
    END LOOP;

    PERFORM etl.load_table(run, 'dw.dim_player', $q$
        SELECT p.id, p.username, p.level, p.xp, p.created_at,
               b.level, b.storage_capacity,
               (SELECT count(*) FROM staging_base.facilities f WHERE f.base_id = b.id),
               (SELECT count(*) FROM staging_base.barricades r WHERE r.base_id = b.id)
        FROM staging_player.players p
        LEFT JOIN staging_base.bases b ON b.player_id = p.id
    $q$);
    COMMIT;
    PERFORM etl.load_table(run, 'dw.dim_item', $q$
        SELECT item_id, name, type FROM staging_player.items
    $q$);
    COMMIT;
    PERFORM etl.load_table(run, 'dw.dim_zombie', $q$
        SELECT id, type, name, subject FROM staging_zombie.zombies
    $q$);
    COMMIT;
    PERFORM etl.load_table(run, 'dw.dim_location', $q$
        SELECT r.room_id, r.name, r.type, w.wing_id, w.name, w.unlocked
        FROM staging_world.rooms r LEFT JOIN staging_world.wings w USING (wing_id)
    $q$);
    COMMIT;
    PERFORM etl.load_table(run, 'dw.fact_craft', $q$
        SELECT c.id, c.player_id, c.recipe_id, r.name, c.item_id, c.quantity, c.status,
               c.created_at, c.created_at::date
        FROM staging_crafting.crafts c LEFT JOIN staging_crafting.recipes r ON r.id = c.recipe_id
    $q$);
    COMMIT;
    PERFORM etl.load_table(run, 'dw.fact_exam', $q$
        SELECT x.exam_id, x.player_id, e.zombie_id, x.subject, x.passed, x.grade, x.correct, x.total,
               x.taken_at, x.taken_at::date
        FROM staging_exam.exam_results x LEFT JOIN staging_exam.exams e USING (exam_id)
    $q$);
    COMMIT;
    -- Resource's timestamps are `timestamp without time zone` in UTC
    PERFORM etl.load_table(run, 'dw.fact_resource', $q$
        SELECT l.id, l."playerId", l.kind, l."resourceType", l.amount, l."nodeId", n.room_id,
               l."createdAt" AT TIME ZONE 'UTC', (l."createdAt" AT TIME ZONE 'UTC')::date
        FROM staging_resource.ledger_entries l
        LEFT JOIN staging_world.resource_nodes n ON n.node_id = l."nodeId"
    $q$);
    COMMIT;
    PERFORM etl.load_table(run, 'dw.fact_event', $q$
        SELECT source, event_id, type, occurred_at, occurred_at::date FROM (
                  SELECT 'player' AS source, event_id, type, occurred_at FROM staging_player.outbox_events
        UNION ALL SELECT 'game', event_id, type, occurred_at FROM staging_game.outbox_events
        UNION ALL SELECT 'exam', event_id, type, occurred_at FROM staging_exam.outbox_events
        UNION ALL SELECT 'world', event_id, type, occurred_at FROM staging_world.outbox_events
        UNION ALL SELECT 'resource', "eventId", type, "occurredAt" FROM staging_resource.outbox_events
        ) e
    $q$);
    COMMIT;

    -- keep a week of run history
    DELETE FROM etl.runs WHERE finished_at < now() - interval '7 days';
END $$;
