"""
가상 ERP 엑셀 생성
---------------------------------------------------------
실제 회사 ERP의 '발주현황 / 입고현황 / 재고현황' 엑셀과 열 구조가 똑같은
가상 파일을 만든다. 거래처·바이어·품번·단가는 모두 가짜다.

실제 데이터에서 관찰된 특징을 그대로 흉내 냈다.
  - P/I No 체계 : 원PI 'S-ABCD01-240313' → 선적PI 'S-ABCD01-01-24'
  - 백카톤(BC)  : 선적에 못 실린 물량이 다음 선적PI로 넘어가며
                  이전PI 에 '...-01-24BC' 처럼 BC 표시가 붙음
  - 백오더(BO)  : 이전PI '...-2023BO'
  - 계획발주    : 바이어 오더 없이 재고용으로 사는 발주 ('계획발주-2024-02-01')
  - 품번 형식   : 엑셀이 숫자로 인식해 앞자리 0이 사라진 품번, 하이픈이 빠진 품번이 섞여 있음
  - 입고 미완료 : 입고 수량·일자가 비어 있는 줄

실행 : python scripts/generate_sample_data.py
결과 : data/sample/ 아래 엑셀 5개
"""
import random
from datetime import date, timedelta
from pathlib import Path

import pandas as pd

random.seed(7)
OUT = Path(__file__).resolve().parents[1] / "data" / "sample"
OUT.mkdir(parents=True, exist_ok=True)

YEAR = 2024
SNAPSHOT = date(2024, 5, 31)

# ---------------------------------------------------------
# 마스터 (전부 가상)
# ---------------------------------------------------------
REGION_PREFIX = ["E", "S", "R"]
buyers = [f"{random.choice(REGION_PREFIX)}-{''.join(random.choices('ABCDEFGHJKLMNPRSTUVWXYZ', k=4))}0{random.randint(1, 3)}"
          for _ in range(30)]

# 공급업체: (평균 리드타임, 표준편차, 납기 위반 확률)
suppliers = {f"공급사{i:02d}": (random.randint(5, 18), random.uniform(1, 7), random.uniform(0.03, 0.35))
             for i in range(1, 26)}

BRANDS = ["BRAND-A", "BRAND-B", "BRAND-C (CHINA)", "OEM", "GENUINE", "BRAND-D", "BRAND-E (CHINA)"]
DESCS = ["BOLT-TENSIONER", "SENSOR-TEMPERATURE", "OIL SEAL-CRANKSHAFT", "TIMING BELT", "PAD KIT-BRAKE",
         "FILTER-OIL", "FILTER-AIR", "PUMP ASSY-WATER", "SWITCH ASSY-POWER", "ADJUSTER-TAPPET",
         "COIL ASSY-IGNITION", "BEARING-WHEEL", "MOUNTING-ENGINE", "LINK-STABILIZER", "GASKET-HEAD"]


def make_part_no():
    r = random.random()
    if r < 0.35:   # 현대·기아식 '24312-39800'
        return f"{random.randint(10000, 99999)}-{random.choice('0123456789ABCDEFGHJK')}{random.randint(1000, 9999)}"
    if r < 0.55:   # 앞자리 0 포함 숫자형 → 엑셀에서 숫자로 바뀌며 0이 사라짐
        return int(f"0{random.randint(100000, 999999)}")
    if r < 0.85:   # 7~8자리 숫자형
        return random.randint(1000000, 99999999)
    return f"0K{random.randint(10, 99)}A-{random.randint(10, 99)}-{random.randint(100, 999)}"


parts = []
for _ in range(700):
    parts.append({
        "part_no": make_part_no(),
        "삼사": random.choice("HHHKKDG"),
        "brand": random.choice(BRANDS),
        "desc": random.choice(DESCS),
        "supplier": random.choice(list(suppliers)),
        "unit": random.choice(["PCS"] * 9 + ["SET"]),
        "cls": random.choice("AAABBGFDCEX"),
        "price": random.choice([130, 250, 900, 1188, 2170, 2500, 3600, 7992, 10300, 20000, 37400]),
    })

# 바이어별 자주 사는 품목
buyer_parts = {b: random.sample(parts, k=random.randint(25, 80)) for b in buyers}

# ---------------------------------------------------------
# 오더 → 발주 → 입고 → (선적 누락 시) 백카톤 이월
# ---------------------------------------------------------
rows = []
rcv_seq = {}


def rcv_no(d):
    key = d.strftime("%y-%m%d")
    rcv_seq[key] = rcv_seq.get(key, 0) + 1
    return f"{key}-{(rcv_seq[key] - 1) // 25 + 1:03d}"


def lead(supplier, po_date):
    mean, sd, late_p = suppliers[supplier]
    lt = random.gauss(mean, sd)
    if po_date.month in (1, 2, 9):          # 명절 무렵 지연
        lt += random.uniform(0, 7)
    if random.random() < late_p:            # 공급사별 납기 위반
        lt += random.uniform(10, 40)
    return max(1, round(lt))


ship_seq = {b: 0 for b in buyers}
ship_records = []                           # 선적 실적 (P/I 단위)
carry = {b: [] for b in buyers}             # 다음 선적으로 넘어갈 백카톤

for month in range(1, 6):
    for b in buyers:
        if random.random() < 0.45:
            continue
        od = date(YEAR, month, random.randint(1, 26))
        orig_pi = f"{b}-{od.strftime('%y%m%d')}"
        ship_seq[b] += 1
        ship_pi = f"{b}-{ship_seq[b]:02d}-{str(YEAR)[2:]}"
        deadline = od + timedelta(days=random.randint(20, 35))
        po_date = od + timedelta(days=random.randint(1, 10))

        ship_records.append({"선적일자": deadline, "수주일자": od, "Buyer": f"BUYER {b[2:6]}",
                             "P/I NO": ship_pi})

        # (1) 지난 선적에서 넘어온 백카톤 → 이번 선적PI 로 옮겨 실림 (이전PI 에 BC 표시)
        for prev_ship_pi, prev_orig, p, qty, prev_po, prev_rcv in carry[b]:
            if prev_rcv <= po_date and random.random() < 0.35:
                # 창고에 있던 백카톤을 이번 선적에 배정 → 재사용 (입고일 <= 발주일)
                rows.append({**p, "pi_no": ship_pi, "order_qty": qty, "po_qty": qty,
                             "rcv_qty": qty, "rcv_date": prev_rcv,
                             "prev_pi": f"{prev_ship_pi}BC", "orig_pi": prev_orig,
                             "po_date": po_date})
            else:
                # 원래 발주 줄이 그대로 다음 선적PI 로 옮겨짐 (원래 발주일·입고일 유지)
                received = prev_rcv <= SNAPSHOT
                rows.append({**p, "pi_no": ship_pi, "order_qty": qty, "po_qty": qty,
                             "rcv_qty": qty if received else None,
                             "rcv_date": prev_rcv if received else None,
                             "prev_pi": f"{prev_ship_pi}BC", "orig_pi": prev_orig,
                             "po_date": prev_po})
        carry[b] = []

        # (2) 이번 오더 신규 발주
        for p in random.sample(buyer_parts[b], k=random.randint(5, 25)):
            qty = random.choice([2, 4, 6, 10, 20, 40, 50, 80, 100, 200, 400, 500, 1000])
            pdt = po_date
            if random.random() < 0.06:              # 선적 이후에 뒤늦게 발주한 품목
                pdt = deadline + timedelta(days=random.randint(1, 10))
            rd = pdt + timedelta(days=lead(p["supplier"], pdt))
            received = rd <= SNAPSHOT
            missed = (rd > deadline) or (random.random() < 0.08)   # 입고 지연 / 창고 작업 누락
            if missed and deadline <= SNAPSHOT:
                carry[b].append((ship_pi, orig_pi, p, qty, pdt, rd))
                continue
            prev_pi = orig_pi if random.random() > 0.05 else f"{b}-{YEAR - 1}BO"
            rows.append({**p, "pi_no": ship_pi, "order_qty": qty, "po_qty": qty,
                         "rcv_qty": qty if received else None,
                         "rcv_date": rd if received else None,
                         "prev_pi": prev_pi, "orig_pi": orig_pi, "po_date": pdt})

# (3) 계획발주
for month in range(1, 6):
    for _ in range(30):
        p = random.choice(parts)
        pd_ = date(YEAR, month, random.randint(1, 28))
        rd = pd_ + timedelta(days=lead(p["supplier"], pd_))
        received = rd <= SNAPSHOT
        qty = random.choice([50, 100, 200, 300])
        rows.append({**p, "pi_no": f"계획발주-{pd_.isoformat()}", "order_qty": None,
                     "po_qty": qty, "rcv_qty": qty if received else None,
                     "rcv_date": rd if received else None, "prev_pi": None,
                     "orig_pi": None, "po_date": pd_})

# ---------------------------------------------------------
# ERP 엑셀 형식으로 내보내기 (2줄 머리글, 22개 열)
# ---------------------------------------------------------
HEADER1 = ["NO", "삼사", "Part No", "브랜드", "Description", "P/I No", "거래처", "PCS", "CLS", "수량",
           "발주", None, None, "입고", None, None, None, "입고번호", "입고일자", "이전PI", "원PI", "발주일자"]
HEADER2 = [None] * 10 + ["수량", "C", "단가", "수량", "반품", "단가", "금액"] + [None] * 5


def messy(part_no):
    """같은 품번을 가끔 다르게 적기 (하이픈 빠짐) — 실제 ERP에서 관찰된 문제"""
    if isinstance(part_no, str) and "-" in part_no and random.random() < 0.08:
        return part_no.replace("-", "")
    return part_no


def to_erp(df_rows):
    out = []
    for r in df_rows:
        r = {**r, "part_no": messy(r["part_no"])}
        has_rcv = r["rcv_date"] is not None
        out.append([None, r["삼사"], r["part_no"], r["brand"], r["desc"], r["pi_no"], r["supplier"],
                    r["unit"], r["cls"], r["order_qty"], r["po_qty"], "￦", r["price"],
                    r["rcv_qty"], None, r["price"] if has_rcv else None,
                    r["rcv_qty"] * r["price"] if has_rcv else None,
                    rcv_no(r["rcv_date"]) if has_rcv else None,
                    pd.Timestamp(r["rcv_date"]) if has_rcv else None,
                    r["prev_pi"], r["orig_pi"], pd.Timestamp(r["po_date"])])
    return pd.DataFrame([HEADER1, HEADER2] + out)


for m in (2, 4):
    po_rows = [r for r in rows if r["po_date"].month == m]
    rc_rows = [r for r in rows if r["rcv_date"] is not None and r["rcv_date"].month == m]
    to_erp(po_rows).to_excel(OUT / f"{YEAR}{m:02d} 발주.xlsx", header=False, index=False)
    to_erp(rc_rows).to_excel(OUT / f"{YEAR}{m:02d}입고.xlsx", header=False, index=False)

# ---------------------------------------------------------
# 재고현황 (재고 / 발주=오더에 묶인 수량 / 잔여=자유 재고)
# ---------------------------------------------------------
inv = []
for p in parts:
    if random.random() < 0.55:
        continue
    stock = random.choice([1, 2, 4, 5, 10, 15, 20, 30, 50, 80, 120, 300, 800])
    alloc = 0 if random.random() < 0.7 else random.randint(0, stock)
    inv.append({"NO": None, "삼사": p["삼사"], "대표품번": p["part_no"], "품명": p["desc"],
                "공용품번": None, "차종": None, "공용차종": None, "CLS": None, "브랜드": p["brand"],
                "재고": stock, "발주": alloc, "잔여": stock - alloc,
                "표준단가": p["price"], "재고단가": round(p["price"] * random.uniform(0.9, 1.1)),
                "구분": random.choice([0, 1, 3]), "group_partno": random.randint(10000, 999999),
                "Promotion QT": 0})
pd.DataFrame(inv).to_excel(OUT / "재고.xlsx", index=False)

# ---------------------------------------------------------
# 선적 실적 (못 실은 물건은 다음 P/I로 넘어가므로 선적율은 대부분 100%)
# ---------------------------------------------------------
ship = []
for r in ship_records:
    if r["선적일자"] > SNAPSHOT:
        continue
    amt = round(random.uniform(2000, 80000), 2)
    rate = 100 if random.random() > 0.02 else round(random.uniform(60, 99), 2)
    ship.append({"선적일자": r["선적일자"].isoformat(), "수주일자": r["수주일자"].isoformat(),
                 "담당": "담당자", "Buyer": r["Buyer"], "P/I NO": r["P/I NO"],
                 "결재": random.choice(["T/T 30", "T/T 60", "D/A 120", "L/C"]),
                 "수주금액": amt, "총선적액": round(amt * rate / 100, 2), "선적율": rate,
                 "CBM": random.randint(1, 30), "기간": (r["선적일자"] - r["수주일자"]).days,
                 "CHECK POINT": None, "백오더": None})
pd.DataFrame(ship).to_excel(OUT / f"실적 {YEAR}.xlsx", index=False)

print(f"lines: {len(rows):,}  BC 이월: {sum(1 for r in rows if (r['prev_pi'] or '').endswith('BC')):,}")
print("→", OUT)
