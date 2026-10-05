-- =========================================================
-- 01_schema.sql
-- ERP 엑셀(발주현황 / 입고현황 / 재고현황)을 그대로 담는 원본 테이블
-- ※ 공개 저장소의 데이터는 모두 가상(synthetic) 데이터
-- =========================================================

DROP TABLE IF EXISTS raw_order_lines;
DROP TABLE IF EXISTS raw_inventory;
DROP TABLE IF EXISTS raw_shipments;

-- 발주현황 · 입고현황 엑셀은 열 구조가 같아서 한 테이블에 담고
-- extract_type 으로 구분한다.
--   extract_type = '발주' : 해당 월에 발주한 줄 (입고 전이면 rcv_* 비어 있음)
--   extract_type = '입고' : 해당 월에 입고된 줄
CREATE TABLE raw_order_lines (
    extract_type  TEXT NOT NULL,   -- '발주' / '입고'
    extract_month TEXT NOT NULL,   -- 'YYYY-MM' (파일명 기준)
    maker_group   TEXT,            -- 삼사 (H/K/D/G)
    part_no       TEXT,            -- Part No (원본 그대로, 숫자·문자 혼재)
    brand         TEXT,
    description   TEXT,
    pi_no         TEXT,            -- 선적 P/I No  예) S-ABCD01-02-24
    supplier      TEXT,            -- 국내 거래처
    unit          TEXT,
    cls           TEXT,
    order_qty     REAL,            -- P/I 수량
    po_qty        REAL,            -- 발주 수량
    currency      TEXT,
    po_price      REAL,
    rcv_qty       REAL,            -- 입고 수량
    return_qty    REAL,
    rcv_price     REAL,
    rcv_amount    REAL,
    rcv_no        TEXT,
    rcv_date      TEXT,            -- YYYY-MM-DD
    prev_pi       TEXT,            -- 이전PI  (…BC = 백카톤 이월, …BO = 백오더)
    orig_pi       TEXT,            -- 원PI    예) S-ABCD01-240313
    po_date       TEXT             -- 발주일자
);

-- 재고현황
CREATE TABLE raw_inventory (
    maker_group   TEXT,
    part_no       TEXT,            -- 대표품번
    description   TEXT,
    brand         TEXT,
    stock_qty     REAL,            -- 재고
    allocated_qty REAL,            -- 발주 (오더에 이미 묶인 수량)
    free_qty      REAL,            -- 잔여 (= 재고 - 발주, 새 오더에 쓸 수 있는 수량)
    std_price     REAL,            -- 표준단가
    stock_price   REAL,            -- 재고단가
    category_code TEXT,            -- 구분
    group_partno  TEXT
);

-- 선적 실적 (P/I 단위)
--   ship_date : 실제로 배가 떠난 날
--   못 실은 물건은 다음 선적 P/I로 넘어가고(BC), 이번 P/I 금액은 실제 선적분으로 정리됨
--   → 그래서 ship_rate 는 대부분 100%
CREATE TABLE raw_shipments (
    ship_date      TEXT,            -- 선적일자
    order_date     TEXT,            -- 수주일자
    buyer_name     TEXT,
    pi_no          TEXT,
    payment_terms  TEXT,            -- 결재 (T/T, D/A, L/C …)
    order_amount   REAL,            -- 수주금액 (USD)
    shipped_amount REAL,            -- 총선적액
    ship_rate      REAL,            -- 선적율 (%)
    cbm            REAL,
    order_to_ship_days INTEGER      -- 기간: 수주 → 선적 일수
);
