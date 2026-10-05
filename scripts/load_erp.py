"""
ERP 엑셀 → SQLite 적재
---------------------------------------------------------
폴더 안의 엑셀 파일을 파일명으로 구분해서 읽는다.
  '*발주*.xlsx' → 발주현황   '*입고*.xlsx' → 입고현황   '*재고*.xlsx' → 재고현황
  '*실적*.xlsx' → 선적 실적
파일명 앞 6자리(YYYYMM)를 기준 월로 사용한다. 예) '202404 발주.xlsx'

사용법
  python scripts/load_erp.py data/sample            # 가상 데이터 (기본)
  python scripts/load_erp.py data/private private.db # 실제 데이터 (깃에 올리지 않음)
"""
import re
import sqlite3
import sys
from pathlib import Path

import pandas as pd

ROOT = Path(__file__).resolve().parents[1]
src = Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / "data" / "sample"
db_path = Path(sys.argv[2]) if len(sys.argv) > 2 else ROOT / "scm.db"

ORDER_COLS = ["no", "maker_group", "part_no", "brand", "description", "pi_no", "supplier",
              "unit", "cls", "order_qty", "po_qty", "currency", "po_price", "rcv_qty",
              "return_qty", "rcv_price", "rcv_amount", "rcv_no", "rcv_date", "prev_pi",
              "orig_pi", "po_date"]


def as_text(v):
    """숫자로 읽힌 품번(1957.0)을 문자열('1957')로 통일"""
    if pd.isna(v):
        return None
    if isinstance(v, float) and v.is_integer():
        v = int(v)
    return str(v).strip()


def as_date(v):
    if pd.isna(v):
        return None
    return pd.Timestamp(v).strftime("%Y-%m-%d")


def read_order_file(path, kind):
    month = re.match(r"(\d{4})(\d{2})", path.name)
    df = pd.read_excel(path, header=None, skiprows=2, names=ORDER_COLS)
    df = df.drop(columns="no")
    df.insert(0, "extract_month", f"{month[1]}-{month[2]}" if month else None)
    df.insert(0, "extract_type", kind)
    for c in ["part_no", "pi_no", "prev_pi", "orig_pi", "rcv_no", "supplier", "brand"]:
        df[c] = df[c].map(as_text)
    for c in ["rcv_date", "po_date"]:
        df[c] = df[c].map(as_date)
    return df


def read_shipments(path):
    df = pd.read_excel(path)
    return pd.DataFrame({
        "ship_date": df["선적일자"].map(as_date), "order_date": df["수주일자"].map(as_date),
        "buyer_name": df["Buyer"].map(as_text), "pi_no": df["P/I NO"].map(as_text),
        "payment_terms": df["결재"].map(as_text), "order_amount": df["수주금액"],
        "shipped_amount": df["총선적액"], "ship_rate": df["선적율"], "cbm": df["CBM"],
        "order_to_ship_days": df["기간"],
    })   # 담당자 이름·CHECK POINT 메모는 개인정보가 섞여 있어 읽지 않음


def read_inventory(path):
    df = pd.read_excel(path)
    out = pd.DataFrame({
        "maker_group": df["삼사"], "part_no": df["대표품번"].map(as_text),
        "description": df["품명"], "brand": df["브랜드"].map(as_text),
        "stock_qty": df["재고"], "allocated_qty": df["발주"], "free_qty": df["잔여"],
        "std_price": df["표준단가"], "stock_price": df["재고단가"],
        "category_code": df["구분"].map(as_text), "group_partno": df["group_partno"].map(as_text),
    })
    return out.dropna(subset=["part_no"])


con = sqlite3.connect(db_path)
con.executescript((ROOT / "sql" / "01_schema.sql").read_text(encoding="utf-8"))

for f in sorted(src.glob("*.xlsx")):
    if "발주" in f.name:
        df = read_order_file(f, "발주")
        df.to_sql("raw_order_lines", con, if_exists="append", index=False)
    elif "입고" in f.name:
        df = read_order_file(f, "입고")
        df.to_sql("raw_order_lines", con, if_exists="append", index=False)
    elif "실적" in f.name:
        df = read_shipments(f)
        df.to_sql("raw_shipments", con, if_exists="append", index=False)
    elif "재고" in f.name:
        df = read_inventory(f)
        df.to_sql("raw_inventory", con, if_exists="append", index=False)
    else:
        continue
    print(f"{f.name:30s} {len(df):>8,d} rows")

con.commit()
con.close()
print("→", db_path)
