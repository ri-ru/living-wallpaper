-- Living Wallpaper tank schema (v2: every species in one animals table).
-- Every host runs this file at startup; it is idempotent.
-- Tanks made before v2 (a `sharks` table): run tools/migrate-v1-to-v2.sql once first.
PRAGMA journal_mode = WAL;
PRAGMA foreign_keys = ON;

CREATE TABLE IF NOT EXISTS families (
  id         INTEGER PRIMARY KEY,
  name       TEXT NOT NULL,
  hue        TEXT,
  founded_at TEXT NOT NULL DEFAULT (datetime('now', 'localtime'))
);

CREATE TABLE IF NOT EXISTS animals (
  id             INTEGER PRIMARY KEY,
  name           TEXT NOT NULL,
  species        TEXT NOT NULL CHECK (species IN ('hammerhead', 'leopard', 'manta', 'whale', 'jellyfish', 'fish', 'crab', 'shrimp')),
  family_id      INTEGER NOT NULL REFERENCES families(id),
  generation     INTEGER NOT NULL,
  parent_a_id    INTEGER REFERENCES animals(id),
  parent_b_id    INTEGER REFERENCES animals(id),   -- NULL for budding jellyfish (one parent)
  born_at        TEXT NOT NULL,
  born_ms        INTEGER NOT NULL,
  lifespan_hours REAL NOT NULL,
  died_at        TEXT,
  cause_of_death TEXT,                             -- age, eaten
  length         REAL NOT NULL,                    -- growth: pixels for swimmers and jellyfish, 0..1 for small animals
  adult_length   REAL NOT NULL,
  depth          REAL NOT NULL,
  fullness       REAL NOT NULL,
  love           INTEGER NOT NULL DEFAULT 0
);

-- Each animal's looks. Inherited from the parents with small mutations; never changes after birth.
CREATE TABLE IF NOT EXISTS animal_traits (
  animal_id    INTEGER PRIMARY KEY REFERENCES animals(id),
  girth        REAL NOT NULL,      -- body width, 1 = average
  fins         REAL NOT NULL,      -- fins, wings or tentacles
  tail         REAL NOT NULL,      -- tail length
  head         REAL NOT NULL,      -- hammer width, bell size
  speed        REAL NOT NULL,
  tint_r       INTEGER NOT NULL,   -- colour shift added to the species colour
  tint_g       INTEGER NOT NULL,
  tint_b       INTEGER NOT NULL,
  variant      TEXT NOT NULL CHECK (variant IN ('common', 'pale', 'dark')),
  pattern_seed INTEGER NOT NULL    -- spots and marks are drawn from this seed
);

CREATE TABLE IF NOT EXISTS events (
  id        INTEGER PRIMARY KEY,
  at        TEXT NOT NULL DEFAULT (datetime('now', 'localtime')),
  kind      TEXT NOT NULL,          -- opened, arrived, born, fed, loved, eaten, died, returned, visit
  animal_id INTEGER REFERENCES animals(id),
  text      TEXT NOT NULL
);

-- Small key/value store for the tank itself (last_seen_ms: when the wallpaper last ran, for replaying time away).
CREATE TABLE IF NOT EXISTS meta (
  key   TEXT PRIMARY KEY,
  value TEXT
);

CREATE INDEX IF NOT EXISTS events_animal   ON events(animal_id);
CREATE INDEX IF NOT EXISTS animals_parents ON animals(parent_a_id, parent_b_id);
CREATE INDEX IF NOT EXISTS animals_species ON animals(species, died_at);

DROP VIEW IF EXISTS alive;
CREATE VIEW alive AS SELECT * FROM animals WHERE died_at IS NULL;

DROP VIEW IF EXISTS babies;
CREATE VIEW babies AS
  SELECT a.id, a.name, a.species, f.name AS family, a.generation,
         pa.name AS parent_a, pb.name AS parent_b, a.born_at, a.died_at, a.cause_of_death,
         round(a.length / a.adult_length, 2) AS grown, a.love
  FROM animals a
  JOIN families f ON f.id = a.family_id
  LEFT JOIN animals pa ON pa.id = a.parent_a_id
  LEFT JOIN animals pb ON pb.id = a.parent_b_id
  WHERE a.parent_a_id IS NOT NULL;

DROP VIEW IF EXISTS sharks;
CREATE VIEW sharks AS SELECT * FROM animals WHERE species IN ('hammerhead', 'leopard');

DROP VIEW IF EXISTS census;
CREATE VIEW census AS
  SELECT species, count(*) AS alive, max(generation) AS latest_generation
  FROM animals WHERE died_at IS NULL GROUP BY species ORDER BY alive DESC;
