"""
전체 실행: 가상 데이터 생성 → DB 적재 → 정제 → 분석 결과 출력

  python scripts/run_all.py                    # 가상 데이터
  python scripts/run_all.py data/private private.db --no-generate   # 실제 데이터 (로컬 전용)
"""
import re
import sqlite3
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
args = [a for a in sys.argv[1:] if not a.startswith("--")]
src = args[0] if len(args) > 0 else str(ROOT / "data" / "sample")
db = args[1] if len(args) > 1 else str(ROOT / "scm.db")

if "--no-generate" not in sys.argv:
    subprocess.run([sys.executable, ROOT / "scripts" / "generate_sample_data.py"], check=True)
subprocess.run([sys.executable, ROOT / "scripts" / "load_erp.py", src, db], check=True)

con = sqlite3.connect(db)
for name in ["02_clean.sql", "03_bc_causes.sql", "04_order_timing.sql", "05_recommend.sql", "06_actions.sql"]:
    text = (ROOT / "sql" / name).read_text(encoding="utf-8")
    parts = re.split(r"\n(?=-- \[분석 \d\])", text)
    con.executescript(parts[0])                       # 뷰·표 만들기
    for part in parts[1:]:
        title = part.splitlines()[0]
        body = "\n".join(l for l in part.splitlines() if not l.startswith("--"))
        stmts = [s.strip() for s in body.split(";") if s.strip()]
        for s in stmts[:-1]:
            con.execute(s)                            # 분석용 뷰
        cur = con.execute(stmts[-1])                  # 마지막 SELECT = 결과
        print("\n" + title)
        print(" | ".join(d[0] for d in cur.description))
        for row in cur.fetchall():
            print(" | ".join("" if v is None else str(v) for v in row))
