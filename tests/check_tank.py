"""CI check: the host wrote a sane tank. Usage: python check_tank.py tank.sqlite"""
import sqlite3, sys

db = sqlite3.connect(sys.argv[1])
alive = db.execute("select count(*) from alive").fetchone()[0]
families = db.execute("select count(*) from families").fetchone()[0]
kinds = dict(db.execute("select kind, count(*) from events group by kind").fetchall())
orphans = db.execute("""select count(*) from sharks s where (s.parent_a_id is not null and not exists
                        (select 1 from sharks p where p.id = s.parent_a_id))""").fetchone()[0]
print(f"alive={alive} families={families} events={kinds} orphans={orphans}")
assert alive >= 3, "expected the tank to open with sharks"
assert families >= 4, "expected four founding families"
assert kinds.get("opened") == 1, "expected exactly one 'opened' event"
assert orphans == 0, "every parent link must point at a shark"
print("tank ok")
