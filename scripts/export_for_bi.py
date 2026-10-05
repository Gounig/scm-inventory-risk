"""
태블로 / Power BI 대시보드용 CSV 내보내기 → data/exports/*.csv
실행: python scripts/export_for_bi.py   (먼저 run_all.py 로 scm.db 를 만들어야 함)
엑셀에서 한글이 깨지지 않도록 utf-8-sig 로 저장한다.
"""
import sqlite3
from pathlib import Path

import pandas as pd

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "data" / "exports"
OUT.mkdir(parents=True, exist_ok=True)
con = sqlite3.connect(ROOT / "scm.db")

queries = {
    # 백카톤 줄 하나하나 + 원인 (대시보드의 기본 표)
    "bc_lines": """
        SELECT extract_month, part_no, part_key, buyer_code, supplier, pi_no, prev_pi,
               missed_pi, missed_ship_date, po_date, rcv_date, po_qty, po_amount,
               bc_kind, bc_cause, days_late
        FROM bc_lines""",
    # 거래처별 지연율·리드타임
    "supplier_summary": """
        SELECT d.supplier, d.on_time_lines, d.late_lines, d.late_rate_pct,
               d.avg_days_late, d.late_amount_mil, d.avg_lead_days,
               l.p80_lead, l.basis
        FROM supplier_delay d LEFT JOIN supplier_lead l ON l.supplier = d.supplier""",
    # 발주 기한 검증용 (줄 단위)
    "order_timing": """
        SELECT supplier, part_key, ship_pi, ship_date, po_date, po_amount,
               p80_lead, order_by_date, ordered_late, became_bc
        FROM order_timing""",
    # 월별 발주 줄 유형
    "monthly_line_types": """
        SELECT extract_month, line_type, COALESCE(bc_kind, '-') AS bc_kind,
               COUNT(*) AS lines, ROUND(SUM(po_amount)) AS amount
        FROM order_lines WHERE extract_type = '발주'
        GROUP BY 1, 2, 3""",
}
for name, q in queries.items():
    df = pd.read_sql_query(q, con)
    df.to_csv(OUT / f"{name}.csv", index=False, encoding="utf-8-sig")
    print(f"→ data/exports/{name}.csv  ({len(df)} rows)")
