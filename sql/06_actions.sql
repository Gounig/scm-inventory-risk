-- =========================================================
-- 06_actions.sql
-- 3-③ 품목별 다음 액션: 입고 중단 · 거래처 독촉 · 발주
--
--   과다재고   : 잔여 재고 + 입고 예정 > 대기 중인 바이어 오더 + 최근 3개월 월평균 오더 × 1.5
--                (입고 예정 물량은 대부분 특정 바이어 오더용이라, 그 오더 수량은 먼저 빼고 본다)
--                → 남는 수량(초과분)이 그 발주 줄 전체면 '입고 중단·발주 취소 협의'
--                → 일부면 '입고 수량 축소' (초과분이 발주 수량의 20% 미만이면 무시)
--                → 입고 예정은 없지만 꾸준히 팔리는 품목이 재고만 많으면 '신규 발주 보류'
--   미입고 지연 : 아직 입고 안 됐는데 발주일 + 거래처 P80 리드타임이 지남
--                → '거래처 독촉'
--                (단, 그 품목이 과다재고면 독촉하지 않고 입고 중단 쪽으로 분류)
--   발주 필요   : 새 오더 대비 재고 부족 + 발주 기한 임박·초과 (05_recommend.sql)
--                → '발주'
--
--   ※ 기준일(today)은 review_settings 표에서 바꾼다. 담당자가 최종 결정한다.
-- =========================================================

DROP TABLE IF EXISTS review_settings;
CREATE TABLE review_settings (
    today           TEXT,     -- 검토 기준일
    excess_ratio    REAL,     -- 과다재고 배수 (월평균 오더 × 몇 배)
    demand_months   INTEGER   -- 월평균 오더를 계산할 기간 (개월)
);
INSERT INTO review_settings VALUES ('2024-06-10', 1.5, 3);


-- ---------------------------------------------------------
-- 1) 품목별 재고 상태: 잔여 재고 · 입고 예정 · 월평균 오더 · 몇 달 치인지
-- ---------------------------------------------------------
DROP VIEW IF EXISTS part_status;
CREATE VIEW part_status AS
WITH s AS (SELECT * FROM review_settings),
stock AS (                                   -- 지금 창고에 있는 잔여 재고
    SELECT part_key, SUM(free_qty) AS free_qty
    FROM inventory GROUP BY part_key
),
incoming AS (                                -- 발주했지만 아직 안 들어온 수량
    SELECT part_key, SUM(po_qty) AS incoming_qty, COUNT(*) AS open_lines,
           SUM(order_qty) AS pending_order_qty  -- 이 입고를 기다리는 바이어 오더 수량
    FROM order_lines
    WHERE extract_type = '발주' AND is_open = 1 AND supplier NOT LIKE '%재고%'
    GROUP BY part_key
),
demand AS (                                  -- 최근 N개월 바이어 오더 → 월평균
    SELECT o.part_key, SUM(o.order_qty) * 1.0 / s.demand_months AS avg_monthly
    FROM order_lines o, s
    WHERE o.extract_type = '발주' AND o.line_type = 'NEW'
      AND o.po_date >  DATE(s.today, '-' || s.demand_months || ' months')
      AND o.po_date <= s.today
    GROUP BY o.part_key
),
parts AS (
    SELECT part_key FROM stock UNION SELECT part_key FROM incoming
)
SELECT p.part_key,
       COALESCE(st.free_qty, 0)     AS free_qty,
       COALESCE(i.incoming_qty, 0)  AS incoming_qty,
       COALESCE(i.open_lines, 0)    AS open_lines,
       COALESCE(i.pending_order_qty, 0) AS pending_order_qty,
       ROUND(COALESCE(d.avg_monthly, 0), 1) AS avg_monthly,
       CASE WHEN COALESCE(d.avg_monthly, 0) > 0
            THEN ROUND((COALESCE(st.free_qty, 0) + COALESCE(i.incoming_qty, 0)) / d.avg_monthly, 1)
       END AS months_cover,                  -- 재고+입고예정이 몇 달 치인지 (오더 없으면 NULL)
       -- 초과분 = (잔여 재고 + 입고 예정) − (대기 바이어 오더 + 월평균 오더 × 1.5)
       ROUND(COALESCE(st.free_qty, 0) + COALESCE(i.incoming_qty, 0)
             - COALESCE(i.pending_order_qty, 0) - COALESCE(d.avg_monthly, 0) * s.excess_ratio, 0) AS excess_qty,
       CASE WHEN COALESCE(st.free_qty, 0) + COALESCE(i.incoming_qty, 0)
                 > COALESCE(i.pending_order_qty, 0) + COALESCE(d.avg_monthly, 0) * s.excess_ratio
            THEN 1 ELSE 0 END AS is_excess
FROM parts p
CROSS JOIN s
LEFT JOIN stock    st ON st.part_key = p.part_key
LEFT JOIN incoming i  ON i.part_key  = p.part_key
LEFT JOIN demand   d  ON d.part_key  = p.part_key;


-- ---------------------------------------------------------
-- 2) 액션 목록
-- ---------------------------------------------------------
DROP VIEW IF EXISTS action_list;
CREATE VIEW action_list AS
WITH s AS (SELECT * FROM review_settings),
open_po AS (                                 -- 아직 안 들어온 발주 줄 + 거래처 P80 + 줄일 수 있는 수량
    SELECT o.part_key, o.part_no, o.supplier, o.pi_no, o.po_date, o.po_qty,
           sl.p80_lead,
           CAST(JULIANDAY(s.today) - JULIANDAY(DATE(o.po_date, '+' || sl.p80_lead || ' days')) AS INTEGER) AS days_over,
           ps.free_qty, ps.incoming_qty, ps.pending_order_qty, ps.avg_monthly, ps.months_cover,
           CASE WHEN ps.excess_qty > 0 THEN MIN(ps.excess_qty, o.po_qty) ELSE 0 END AS cut_qty
    FROM order_lines o
    CROSS JOIN s
    JOIN part_status ps        ON ps.part_key = o.part_key
    LEFT JOIN supplier_lead sl ON sl.supplier = o.supplier
    WHERE o.extract_type = '발주' AND o.is_open = 1 AND o.supplier NOT LIKE '%재고%'
)
-- ① 들어올 물건이 남는 경우 → 입고 중단 또는 수량 축소
SELECT '과다재고' AS status,
       CASE WHEN cut_qty >= po_qty THEN '입고 중단 · 발주 취소 협의'
            ELSE '입고 수량 축소 (' || CAST(cut_qty AS INTEGER) || '개 줄이기)' END AS action,
       1 AS priority,
       part_no, supplier, pi_no, po_qty AS qty,
       free_qty, incoming_qty, avg_monthly, months_cover, NULL AS days_over,
       '잔여 재고 ' || CAST(free_qty AS INTEGER) || '개 · 대기 오더 ' || CAST(pending_order_qty AS INTEGER) || '개' AS note
FROM open_po
WHERE cut_qty >= 0.2 * po_qty

UNION ALL
-- ② 남지 않는데 P80을 넘긴 미입고 → 거래처 독촉
SELECT '미입고 지연', '거래처 독촉', 2,
       part_no, supplier, pi_no, po_qty,
       free_qty, incoming_qty, avg_monthly, months_cover, days_over,
       'P80(' || p80_lead || '일) 기준 ' || days_over || '일 초과'
FROM open_po
WHERE cut_qty < 0.2 * po_qty AND days_over > 0

UNION ALL
-- ③ 입고 예정은 없지만, 꾸준히 오더가 들어오는 품목인데 재고가 많음 → 신규 발주 보류
--    (최근 오더가 아예 없는 품목은 '장기 체류 재고'라 별도 검토 대상으로 두고 여기선 뺀다)
SELECT '과다재고', '신규 발주 보류 · 재고 우선 사용', 3,
       (SELECT MIN(part_no) FROM inventory i WHERE i.part_key = ps.part_key),
       NULL, NULL, NULL,
       ps.free_qty, ps.incoming_qty, ps.avg_monthly, ps.months_cover, NULL,
       ps.months_cover || '개월 치 보유'
FROM part_status ps
WHERE ps.is_excess = 1 AND ps.incoming_qty = 0 AND ps.avg_monthly > 0

UNION ALL
-- ④ 새 오더 대비 재고 부족 + 발주 기한 임박·초과 → 발주
SELECT '발주 필요', '발주 (' || order_by_date || '까지)', 2,
       part_no, supplier, pi_no, recommended_po_qty,
       free_stock, NULL, NULL, NULL, NULL,
       '위험도 ' || risk
FROM reorder_recommendation
WHERE risk IN ('높음', '중간');


-- [분석 6] 액션별 건수
SELECT status AS 상태,
       CASE WHEN action LIKE '입고 수량 축소%' THEN '입고 수량 축소' WHEN action LIKE '발주 (%' THEN '발주' ELSE action END AS 액션,
       COUNT(*) AS 건수
FROM action_list
GROUP BY status, CASE WHEN action LIKE '입고 수량 축소%' THEN '입고 수량 축소' WHEN action LIKE '발주 (%' THEN '발주' ELSE action END
ORDER BY MIN(priority), 건수 DESC;


-- [분석 7] 과거 검증: 독촉 기준이 있었다면 입고 지연 이월을 미리 잡을 수 있었을까?
--   입고 지연(A)으로 넘어간 줄 중, 선적일 전에 이미 '발주일 + P80'을 넘긴 줄
--   = 선적 전에 독촉 대상으로 떴을 줄
SELECT COUNT(*)                                                    AS 입고지연_건수,
       SUM(CASE WHEN DATE(b.po_date, '+' || sl.p80_lead || ' days') < b.missed_ship_date
                THEN 1 ELSE 0 END)                                 AS 선적전_독촉가능_건수,
       ROUND(100.0 * SUM(CASE WHEN DATE(b.po_date, '+' || sl.p80_lead || ' days') < b.missed_ship_date
                THEN 1 ELSE 0 END) / COUNT(*), 1)                  AS 비율,
       ROUND(AVG(CASE WHEN DATE(b.po_date, '+' || sl.p80_lead || ' days') < b.missed_ship_date
                THEN JULIANDAY(b.missed_ship_date)
                     - JULIANDAY(DATE(b.po_date, '+' || sl.p80_lead || ' days')) END), 1) AS 선적_며칠전_평균
FROM bc_lines b
JOIN supplier_lead sl ON sl.supplier = b.supplier
WHERE b.bc_cause = 'A. 입고 지연';
