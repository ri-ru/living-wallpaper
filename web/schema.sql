-- Living Wallpaper tank schema. Every host runs this file at startup (it is idempotent).
PRAGMA journal_mode = WAL;
PRAGMA foreign_keys = ON;

CREATE TABLE IF NOT EXISTS families (
  id         INTEGER PRIMARY KEY,
  name       TEXT NOT NULL,
  hue        TEXT,
  founded_at TEXT NOT NULL DEFAULT (datetime('now', 'localtime'))
);

CREATE TABLE IF NOT EXISTS sharks (
  id             INTEGER PRIMARY KEY,
  name           TEXT NOT NULL,
  species        TEXT NOT NULL CHECK (species IN ('hammerhead', 'leopard')),
  family_id      INTEGER NOT NULL REFERENCES families(id),
  generation     INTEGER NOT NULL,
  parent_a_id    INTEGER REFERENCES sharks(id),
  parent_b_id    INTEGER REFERENCES sharks(id),
  born_at        TEXT NOT NULL,
  born_ms        INTEGER NOT NULL,
  lifespan_hours REAL NOT NULL,
  died_at        TEXT,
  length         REAL NOT NULL,
  adult_length   REAL NOT NULL,
  depth          REAL NOT NULL,
  fullness       REAL NOT NULL,
  love           INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS events (
  id       INTEGER PRIMARY KEY,
  at       TEXT NOT NULL DEFAULT (datetime('now', 'localtime')),
  kind     TEXT NOT NULL,          -- opened, arrived, born, fed, loved, died, returned
  shark_id INTEGER REFERENCES sharks(id),
  text     TEXT NOT NULL
);

-- Each shark's looks. Inherited from both parents with small mutations; never changes after birth.
CREATE TABLE IF NOT EXISTS shark_traits (
  shark_id     INTEGER PRIMARY KEY REFERENCES sharks(id),
  girth        REAL NOT NULL,      -- body width, 1 = average
  fins         REAL NOT NULL,      -- pectoral fin size
  tail         REAL NOT NULL,      -- tail fin length
  head         REAL NOT NULL,      -- hammer width (hammerheads)
  speed        REAL NOT NULL,      -- cruising speed
  tint_r       INTEGER NOT NULL,   -- colour shift added to the species colour
  tint_g       INTEGER NOT NULL,
  tint_b       INTEGER NOT NULL,
  variant      TEXT NOT NULL CHECK (variant IN ('common', 'pale', 'dark')),
  pattern_seed INTEGER NOT NULL    -- spots and marks are drawn from this seed
);

-- Small key/value store for the tank itself (last_seen_ms: when the wallpaper last ran, for replaying time away).
CREATE TABLE IF NOT EXISTS meta (
  key   TEXT PRIMARY KEY,
  value TEXT
);

CREATE INDEX IF NOT EXISTS events_shark   ON events(shark_id);
CREATE INDEX IF NOT EXISTS sharks_parents ON sharks(parent_a_id, parent_b_id);

DROP VIEW IF EXISTS babies;
CREATE VIEW babies AS
  SELECT s.id, s.name, s.species, f.name AS family, s.generation,
         a.name AS parent_a, b.name AS parent_b, s.born_at, s.died_at,
         round(s.length / s.adult_length, 2) AS grown, s.love
  FROM sharks s
  JOIN families f ON f.id = s.family_id
  LEFT JOIN sharks a ON a.id = s.parent_a_id
  LEFT JOIN sharks b ON b.id = s.parent_b_id
  WHERE s.parent_a_id IS NOT NULL;

DROP VIEW IF EXISTS alive;
CREATE VIEW alive AS SELECT * FROM sharks WHERE died_at IS NULL;
