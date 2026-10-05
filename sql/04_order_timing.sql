-- =========================================================
-- 04_order_timing.sql
-- 3-① "늦어도 이날까지 발주" 기준
--
--   거래처별 리드타임(발주 → 입고)의 80% 지점(P80)을 구한다.
--   = "이 거래처 물건은 10번 중 8번은 이 일수 안에 들어온다"
--
--   늦어도 발주해야 하는 날 = 선적일 − P80 리드타임
--   이 날짜보다 늦게 발주했으면 '백카톤 위험 발주'
-- =========================================================

-- ---------------------------------------------------------
-- 1) 거래처별 P80 리드타임
--    · 회사 자체 재고에서 배정한 줄(리드타임 0일, 거래처명에 '재고')은 제외
--    · 입고 20줄 미만 거래처는 전체 P80을 대신 사용
-- ---------------------------------------------------------
DROP VIEW IF EXISTS supplier_lead;
CREATE VIEW supplier_lead AS
WITH base AS (
    SELECT supplier, lead_days
    FROM order_lines
    WHERE extract_type = '입고' AND line_type = 'NEW'
      AND lead_days IS NOT NULL
      AND supplier NOT LIKE '%재고%'
),
ranked AS (
    SELECT supplier, lead_days,
           ROW_NUMBER() OVER (PARTITION BY supplier ORDER BY lead_days) AS rn,
           COUNT(*)     OVER (PARTITION BY supplier)                    AS n
    FROM base
),
per_supplier AS (
    SELECT supplier, MAX(n) AS n,
           ROUND(AVG(lead_days), 1) AS avg_lead,
           MIN(CASE WHEN rn >= 0.8 * n THEN lead_days END) AS p80_lead
    FROM ranked
    GROUP BY supplier
),
overall AS (
    SELECT MIN(lead_days) AS p80_all FROM (
        SELECT lead_days,
               ROW_NUMBER() OVER (ORDER BY lead_days) AS rn,
               COUNT(*) OVER () AS n
        FROM base)
    WHERE rn >= 0.8 * n
)
SELECT p.supplier, p.n, p.avg_lead,
       CASE WHEN p.n >= 20 THEN p.p80_lead ELSE o.p80_all END AS p80_lead,
       CASE WHEN p.n >= 20 THEN '거래처 기준' ELSE '전체 기준(표본 부족)' END AS basis
FROM per_supplier p CROSS JOIN overall o;


-- ---------------------------------------------------------
-- 2) 검증용 데이터: 선적일을 아는 신규 발주 줄 + 그 결과
--    · 제때 실린 줄      : 자기 선적 P/I 에 그대로 남은 신규 발주
--    · 늦어서 빠진 줄    : 백카톤 A(입고 지연)·C(입고됐는데 누락)
-- ---------------------------------------------------------
DROP VIEW IF EXISTS order_timing;
CREATE VIEW order_timing AS
WITH lines AS (
    SELECT o.supplier, o.part_key, o.pi_no AS ship_pi, s.ship_date, o.po_date, o.po_amount,
           0 AS became_bc
    FROM order_lines o
    JOIN raw_shipments s ON s.pi_no = o.pi_no
    WHERE o.extract_type = '발주' AND o.line_type = 'NEW'
    UNION ALL
    SELECT supplier, part_key, missed_pi, missed_ship_date, po_date, po_amount, 1
    FROM bc_lines
    WHERE bc_cause IN ('A. 입고 지연', 'C. 입고됐는데 누락')
)
SELECT l.*,
       sl.p80_lead,
       DATE(l.ship_date, '-' || sl.p80_lead || ' days') AS order_by_date,   -- 늦어도 발주해야 하는 날
       CASE WHEN l.po_date > DATE(l.ship_date, '-' || sl.p80_lead || ' days')
            THEN 1 ELSE 0 END AS ordered_late                               -- 기준보다 늦게 발주
FROM lines l
JOIN supplier_lead sl ON sl.supplier = l.supplier;


-- [분석 4] 기준보다 늦게 발주하면 백카톤이 정말 더 생길까?
SELECT CASE ordered_late WHEN 1 THEN '기준보다 늦게 발주' ELSE '기준 안에 발주' END AS 발주_시점,
       COUNT(*)                                   AS 줄수,
       SUM(became_bc)                             AS 백카톤_된_줄,
       ROUND(100.0 * SUM(became_bc) / COUNT(*), 1) AS 백카톤_비율
FROM order_timing
GROUP BY ordered_late;
