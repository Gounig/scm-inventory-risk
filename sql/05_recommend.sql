-- =========================================================
-- 05_recommend.sql
-- 3-② 권장 발주 수량 + 발주 기한 + 위험도
--
--   새 오더가 들어오면 품목마다
--     1) 창고에 쓸 수 있는 재고(잔여)가 있는지 먼저 보고
--     2) 모자라는 만큼만 발주를 권하고
--     3) 거래처 P80 리드타임으로 "늦어도 이날까지 발주"를 알려 준다.
--
--   권장 발주량   = MAX(오더 수량 − 잔여 재고, 0)
--   재고에서 쓸 양 = MIN(오더 수량, 잔여 재고)
--   발주 기한      = 선적 예정일 − P80 리드타임
--   위험도         : 오늘이 발주 기한을 넘었으면 '높음', 3일 안이면 '중간', 그 밖은 '낮음'
--
--   ※ 담당자가 최종 결정한다. 이 값은 참고용이다.
-- =========================================================

-- 새로 들어온(또는 들어올) 오더를 넣는 표
DROP TABLE IF EXISTS incoming_orders;
CREATE TABLE incoming_orders (
    pi_no      TEXT,
    part_no    TEXT,
    order_qty  INTEGER,
    ship_date  TEXT,     -- 바이어·영업이 정한 선적 예정일
    today      TEXT      -- 검토하는 날 (보통 오늘)
);

DROP VIEW IF EXISTS reorder_recommendation;
CREATE VIEW reorder_recommendation AS
WITH io AS (
    SELECT *,
           LTRIM(UPPER(REPLACE(REPLACE(TRIM(part_no), '-', ''), ' ', '')), '0') AS part_key
    FROM incoming_orders
),
stock AS (                       -- 품목별 잔여 재고 (같은 매칭 키끼리 합침)
    SELECT part_key, SUM(free_qty) AS free_qty
    FROM inventory
    GROUP BY part_key
),
last_supplier AS (               -- 품목별로 가장 최근에 발주한 거래처
    SELECT part_key, supplier FROM (
        SELECT part_key, supplier,
               ROW_NUMBER() OVER (PARTITION BY part_key ORDER BY po_date DESC) AS rn
        FROM order_lines
        WHERE line_type IN ('NEW', 'PLAN') AND supplier NOT LIKE '%재고%')
    WHERE rn = 1
)
SELECT io.pi_no,
       io.part_no,
       io.order_qty,
       COALESCE(st.free_qty, 0)                                        AS free_stock,
       MIN(io.order_qty, COALESCE(st.free_qty, 0))                     AS use_from_stock,
       MAX(io.order_qty - COALESCE(st.free_qty, 0), 0)                 AS recommended_po_qty,
       ls.supplier,
       sl.p80_lead,
       DATE(io.ship_date, '-' || sl.p80_lead || ' days')               AS order_by_date,
       CASE
           WHEN io.order_qty <= COALESCE(st.free_qty, 0)               THEN '재고로 충당'
           WHEN sl.p80_lead IS NULL                                    THEN '확인 필요'
           WHEN io.today > DATE(io.ship_date, '-' || sl.p80_lead || ' days')  THEN '높음'
           WHEN io.today > DATE(io.ship_date, '-' || (sl.p80_lead + 3) || ' days') THEN '중간'
           ELSE '낮음'
       END                                                             AS risk
FROM io
LEFT JOIN stock st          ON st.part_key = io.part_key
LEFT JOIN last_supplier ls  ON ls.part_key = io.part_key
LEFT JOIN supplier_lead sl  ON sl.supplier = ls.supplier;


-- [분석 5] 과거 검증: 같은 품목을 '재사용'한 날 앞뒤 14일 안에 또 '새로 산' 경우
--   재사용했다 = 그때 창고에 그 품목이 있었다는 증거
--   그 근처에서 또 샀다면 → 재고가 있는데 중복 구매했을 가능성
WITH reuse AS MATERIALIZED (          -- 재사용 줄: 품목·날짜만 먼저 뽑아 둠 (속도)
    SELECT DISTINCT part_key, po_date
    FROM order_lines
    WHERE extract_type = '발주' AND bc_kind = 'BC_REUSE'
),
buy AS MATERIALIZED (                 -- 새로 산 줄
    SELECT part_key, po_date, po_amount,
           ROW_NUMBER() OVER () AS id
    FROM order_lines
    WHERE extract_type = '발주'
      AND (bc_kind = 'BC_REPURCHASE' OR line_type = 'NEW')
),
dup AS (
    SELECT DISTINCT b.id, b.part_key, b.po_amount
    FROM buy b
    JOIN reuse r
      ON r.part_key = b.part_key
     AND ABS(JULIANDAY(r.po_date) - JULIANDAY(b.po_date)) <= 14
)
SELECT COUNT(DISTINCT part_key)             AS 품목수,
       COUNT(*)                             AS 줄수,
       ROUND(SUM(po_amount) / 1000000.0, 1) AS 금액_백만원
FROM dup;
