"""
SQL 연습장(docs/index.html) 만들기
web/template.html 에 가상 DB(scm.db)의 데이터와 sql/*.sql 을 넣어 한 파일로 만든다.
실행: python scripts/build_practice_page.py   (먼저 run_all.py 로 scm.db 를 만들어야 함)
"""
import json
import sqlite3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
con = sqlite3.connect(ROOT / "scm.db")
data = []
for t in ["raw_order_lines", "raw_inventory", "raw_shipments"]:
    cols = [r[1] for r in con.execute(f"PRAGMA table_info({t})")]
    data.append({"t": t, "cols": cols, "rows": con.execute(f"SELECT * FROM {t}").fetchall()})


def sql(name, cut=None):
    text = (ROOT / "sql" / name).read_text(encoding="utf-8")
    return json.dumps(text.split(cut)[0] if cut else text, ensure_ascii=False)


page = (ROOT / "web" / "template.html").read_text(encoding="utf-8")
page = (page.replace("__DATA__", json.dumps(data, ensure_ascii=False, separators=(",", ":")))
            .replace("__SCHEMA__", sql("01_schema.sql"))
            .replace("__CLEAN__", sql("02_clean.sql"))
            .replace("__BC__", sql("03_bc_causes.sql", "-- [분석 1]"))
            .replace("__TIMING__", sql("04_order_timing.sql", "-- [분석 4]"))
            .replace("__REC__", sql("05_recommend.sql", "-- [분석 5]")))
# 인터넷 없이도 열리도록 SQL 엔진(sql.js)을 같은 폴더의 파일로 불러온다
page = page.replace("https://cdn.jsdelivr.net/npm/sql.js@1.10.3/dist/sql-asm.js", "sql-asm.js")
out = ROOT / "docs" / "index.html"
# GitHub Pages 에서 바로 열리도록 문서 뼈대를 붙인다
out.write_text("<!doctype html>\n<html lang=\"ko\"><head><meta charset=\"utf-8\">"
               "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n"
               + page + "\n</html>\n", encoding="utf-8")
print("→", out)
