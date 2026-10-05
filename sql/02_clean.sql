-- =========================================================
-- 02_clean.sql
-- 원본 테이블을 분석하기 좋은 형태로 정리하는 뷰(View)
-- =========================================================

-- ---------------------------------------------------------
-- 1) 품번 매칭 키
--    엑셀이 숫자로 읽으면서 앞자리 0이 사라지거나('01957' → '1957'),
--    하이픈·공백 표기가 달라 같은 품번이 다른 값으로 저장되는 문제를 막기 위해
--    "대문자 + 하이픈/공백 제거 + 앞자리 0 제거" 한 값을 매칭 키로 쓴다.
-- ---------------------------------------------------------
DROP VIEW IF EXISTS order_lines;
CREATE VIEW order_lines AS
SELECT
    extract_type,
    extract_month,
    part_no,
    LTRIM(UPPER(REPLACE(REPLACE(TRIM(part_no), '-', ''), ' ', '')), '0') AS part_key,
    brand,
    description,
    supplier,
    pi_no,
    prev_pi,
    orig_pi,

    -- 2) 바이어 코드: 선적PI 'S-ABCD01-02-24' 의 앞 두 덩어리 'S-ABCD01'
    CASE
        WHEN pi_no LIKE '계획발주%' THEN 'PLAN'
        WHEN INSTR(SUBSTR(pi_no, 3), '-') > 0
            THEN SUBSTR(pi_no, 1, INSTR(SUBSTR(pi_no, 3), '-') + 1)
        ELSE pi_no
    END AS buyer_code,

    -- 3) 줄 유형
    --    BC_CARRY  : 이전 선적에 못 실려 이번 선적으로 넘어온 백카톤
    --    BACKORDER : 백오더
    --    PLAN      : 계획발주 (재고용 구매)
    --    NEW       : 이번 오더를 위한 신규 발주
    CASE
        WHEN pi_no LIKE '계획발주%'                 THEN 'PLAN'
        WHEN UPPER(prev_pi) LIKE '%BC'              THEN 'BC_CARRY'
        WHEN UPPER(prev_pi) LIKE '%BO'
          OR UPPER(pi_no)   LIKE '%BO'
          OR UPPER(pi_no)   LIKE '%BO-%'            THEN 'BACKORDER'
        ELSE 'NEW'
    END AS line_type,

    -- 3-1) 백카톤 줄을 다시 둘로 나눔 (사용자 확인 완료)
    --    BC_REUSE      : 입고일 <= 발주일  → 창고에 있던 백카톤을 이번 선적에 배정 (재사용)
    --    BC_REPURCHASE : 입고일 >  발주일  → 지난 선적에 못 실은 물건을 새로 구매
    CASE
        WHEN UPPER(prev_pi) LIKE '%BC' AND pi_no NOT LIKE '계획발주%' THEN
            CASE
                WHEN rcv_date IS NULL      THEN 'BC_OPEN'        -- 아직 미입고
                WHEN rcv_date <= po_date   THEN 'BC_REUSE'
                ELSE 'BC_REPURCHASE'
            END
    END AS bc_kind,

    COALESCE(order_qty, po_qty)        AS order_qty,
    po_qty,
    po_price,
    rcv_qty,
    rcv_amount,
    COALESCE(po_qty, 0) * COALESCE(po_price, 0) AS po_amount,
    po_date,
    rcv_date,

    -- 4) 리드타임: 발주일 → 입고일 (일)
    --    입고일이 발주일보다 앞서는 줄은 '이미 있던 재고를 배정'한 경우라
    --    공급업체 납기 계산에서 제외한다.
    CASE
        WHEN rcv_date IS NOT NULL AND rcv_date >= po_date
            THEN CAST(JULIANDAY(rcv_date) - JULIANDAY(po_date) AS INTEGER)
    END AS lead_days,

    CASE WHEN rcv_date IS NULL THEN 1 ELSE 0 END AS is_open   -- 미입고
FROM raw_order_lines
WHERE part_no IS NOT NULL;


-- ---------------------------------------------------------
-- 5) 재고: 같은 매칭 키 기준으로 정리 + 재고금액
-- ---------------------------------------------------------
DROP VIEW IF EXISTS inventory;
CREATE VIEW inventory AS
SELECT
    part_no,
    LTRIM(UPPER(REPLACE(REPLACE(TRIM(part_no), '-', ''), ' ', '')), '0') AS part_key,
    description,
    brand,
    stock_qty,
    allocated_qty,
    free_qty,
    stock_price,
    stock_qty * stock_price AS stock_value,   -- 재고금액
    free_qty  * stock_price AS free_value     -- 오더에 안 묶인 재고금액
FROM raw_inventory
WHERE stock_qty > 0;
