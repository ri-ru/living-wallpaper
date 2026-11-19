-- One-time migration for tanks made before v2 (sharks / shark_traits / events.shark_id).
-- Stop the wallpaper first, back up tank.sqlite, then:
--   sqlite3 tank.sqlite < tools/migrate-v1-to-v2.sql
-- Start the wallpaper again; it runs web/schema.sql, which adds the views.
PRAGMA foreign_keys = OFF;
BEGIN;
CREATE TABLE animals (
  id INTEGER PRIMARY KEY, name TEXT NOT NULL,
  species TEXT NOT NULL CHECK (species IN ('hammerhead', 'leopard', 'manta', 'whale', 'jellyfish', 'fish', 'crab', 'shrimp')),
  family_id INTEGER NOT NULL REFERENCES families(id), generation INTEGER NOT NULL,
  parent_a_id INTEGER REFERENCES animals(id), parent_b_id INTEGER REFERENCES animals(id),
  born_at TEXT NOT NULL, born_ms INTEGER NOT NULL, lifespan_hours REAL NOT NULL,
  died_at TEXT, cause_of_death TEXT,
  length REAL NOT NULL, adult_length REAL NOT NULL, depth REAL NOT NULL, fullness REAL NOT NULL, love INTEGER NOT NULL DEFAULT 0
);
INSERT INTO animals (id, name, species, family_id, generation, parent_a_id, parent_b_id, born_at, born_ms, lifespan_hours,
                     died_at, cause_of_death, length, adult_length, depth, fullness, love)
  SELECT id, name, species, family_id, generation, parent_a_id, parent_b_id, born_at, born_ms, lifespan_hours,
         died_at, CASE WHEN died_at IS NOT NULL THEN 'age' END, length, adult_length, depth, fullness, love
  FROM sharks;
CREATE TABLE animal_traits (
  animal_id INTEGER PRIMARY KEY REFERENCES animals(id), girth REAL NOT NULL, fins REAL NOT NULL, tail REAL NOT NULL,
  head REAL NOT NULL, speed REAL NOT NULL, tint_r INTEGER NOT NULL, tint_g INTEGER NOT NULL, tint_b INTEGER NOT NULL,
  variant TEXT NOT NULL CHECK (variant IN ('common', 'pale', 'dark')), pattern_seed INTEGER NOT NULL
);
INSERT INTO animal_traits SELECT * FROM shark_traits;
ALTER TABLE events RENAME TO events_v1;
CREATE TABLE events (
  id INTEGER PRIMARY KEY, at TEXT NOT NULL DEFAULT (datetime('now', 'localtime')), kind TEXT NOT NULL,
  animal_id INTEGER REFERENCES animals(id), text TEXT NOT NULL
);
INSERT INTO events (id, at, kind, animal_id, text) SELECT id, at, kind, shark_id, text FROM events_v1;
DROP VIEW IF EXISTS babies;
DROP VIEW IF EXISTS alive;
DROP INDEX IF EXISTS events_shark;
DROP INDEX IF EXISTS sharks_parents;
DROP TABLE events_v1;
DROP TABLE shark_traits;
DROP TABLE sharks;
COMMIT;
PRAGMA foreign_keys = ON;
