-- =========================================================
-- 03_bc_causes.sql
-- 2-① 백카톤은 왜 생겼을까?
--
-- 백카톤 줄(BC_CARRY)의 이전PI 에서 'BC'를 떼면 "원래 실렸어야 할 선적 P/I"가 된다.
-- 그 P/I의 실제 선적일(배가 떠난 날)과 이 줄의 발주일·입고일을 비교해서 원인을 나눈다.
--
--   A. 입고 지연      : 발주는 선적 전에 했는데, 입고가 선적보다 늦음
--   B. 발주 지연      : 선적이 끝난 뒤에 발주함 (오더 추가·수량 변경 등)
--   C. 입고됐는데 누락 : 선적 전에 이미 입고됐는데 선적에 안 실림 (창고 작업·마감 문제 의심)
--   D. 백카톤 재사용   : 창고에 있던 백카톤을 다음 선적에 배정한 줄 (원인 분석 대상 아님)
--   E. 연도 BC        : 이전PI 가 '바이어-2024BC' 형태 = 그 바이어의 2024년 백카톤 묶음
--                       → 원래 어느 선적에서 넘어왔는지 기록이 없어 A~C 판단 불가
--   F. 선적 기록 없음  : 원래 선적 P/I는 있지만 실적 파일 기간 밖 (예: 2023년 선적)
-- =========================================================

DROP VIEW IF EXISTS bc_lines;
CREATE VIEW bc_lines AS
SELECT
    o.*,
    SUBSTR(o.prev_pi, 1, LENGTH(o.prev_pi) - 2) AS missed_pi,      -- 원래 실렸어야 할 P/I
    s.ship_date                                  AS missed_ship_date,
    CASE
        WHEN o.bc_kind = 'BC_REUSE'                      THEN 'D. 백카톤 재사용'
        WHEN SUBSTR(o.prev_pi, 1, LENGTH(o.prev_pi) - 2) GLOB '*-20[0-9][0-9]'
                                                         THEN 'E. 연도 BC (원래 선적 불명)'
        WHEN s.ship_date IS NULL                         THEN 'F. 선적 기록 없음'
        WHEN o.po_date >  s.ship_date                    THEN 'B. 발주 지연'
        WHEN o.rcv_date > s.ship_date                    THEN 'A. 입고 지연'
        WHEN o.rcv_date <= s.ship_date                   THEN 'C. 입고됐는데 누락'
        ELSE '미입고'
    END AS bc_cause,
    -- 입고가 선적보다 며칠 늦었는지 (A 유형)
    CASE WHEN o.rcv_date > s.ship_date
         THEN CAST(JULIANDAY(o.rcv_date) - JULIANDAY(s.ship_date) AS INTEGER) END AS days_late
FROM order_lines o
LEFT JOIN raw_shipments s
       ON s.pi_no = SUBSTR(o.prev_pi, 1, LENGTH(o.prev_pi) - 2)
WHERE o.line_type = 'BC_CARRY'
  AND o.extract_type = '발주';


-- [분석 1] 백카톤 원인별 건수·금액
SELECT bc_cause                              AS 원인,
       COUNT(*)                              AS 줄수,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1) AS 비율,
       ROUND(SUM(po_amount) / 1000000.0, 1)  AS 금액_백만원
FROM bc_lines
GROUP BY bc_cause
ORDER BY 줄수 DESC;


-- =========================================================
-- [분석 2] 2-② 공급업체별 입고 지연 백카톤 순위
--
--   제때 실린 줄 : 이번 선적 P/I 에 그대로 실린 신규 발주 줄 (선적 기록이 있는 것)
--   늦어서 빠진 줄 : A. 입고 지연 백카톤
--   지연율 = 늦어서 빠진 줄 / (제때 실린 줄 + 늦어서 빠진 줄)
--   줄 수가 너무 적은 업체는 우연일 수 있어서 10줄 이상만 본다. (실제 데이터는 30줄 권장)
-- =========================================================
DROP VIEW IF EXISTS supplier_delay;
CREATE VIEW supplier_delay AS
WITH on_time AS (
    SELECT o.supplier, COUNT(*) AS n
    FROM order_lines o
    JOIN raw_shipments s ON s.pi_no = o.pi_no
    WHERE o.extract_type = '발주' AND o.line_type = 'NEW'
    GROUP BY o.supplier
),
late AS (
    SELECT supplier, COUNT(*) AS n, AVG(days_late) AS avg_late,
           SUM(po_amount) AS amt
    FROM bc_lines
    WHERE bc_cause = 'A. 입고 지연'
    GROUP BY supplier
),
lead AS (
    SELECT supplier, AVG(lead_days) AS avg_lead, COUNT(*) AS n
    FROM order_lines
    WHERE extract_type = '입고' AND line_type = 'NEW' AND lead_days IS NOT NULL
    GROUP BY supplier
)
SELECT t.supplier,
       t.n                         AS on_time_lines,
       COALESCE(l.n, 0)            AS late_lines,
       ROUND(100.0 * COALESCE(l.n, 0) / (t.n + COALESCE(l.n, 0)), 1) AS late_rate_pct,
       ROUND(l.avg_late, 1)        AS avg_days_late,
       ROUND(COALESCE(l.amt, 0) / 1000000.0, 1) AS late_amount_mil,
       ROUND(d.avg_lead, 1)        AS avg_lead_days
FROM on_time t
LEFT JOIN late l ON l.supplier = t.supplier
LEFT JOIN lead d ON d.supplier = t.supplier
WHERE t.n + COALESCE(l.n, 0) >= 10;

SELECT supplier        AS 거래처,
       on_time_lines   AS 제때_실림,
       late_lines      AS 늦어서_빠짐,
       late_rate_pct   AS 지연율_퍼센트,
       avg_days_late   AS 평균_지연일,
       late_amount_mil AS 지연금액_백만원,
       avg_lead_days   AS 평균_리드타임
FROM supplier_delay
ORDER BY late_lines DESC
LIMIT 15;


-- =========================================================
-- [분석 3] 2-③ C. 입고됐는데 누락 — 선적 며칠 전에 들어왔나?
--   선적 직전(0~2일)에 들어왔다면 → 창고 작업 시간 부족 가능성
--   한참 전(8일 이상)에 들어왔다면 → 재고 확인·배정이 안 된 관리 문제 가능성
-- =========================================================
SELECT CASE
         WHEN gap <= 2  THEN '1) 선적 0~2일 전'
         WHEN gap <= 7  THEN '2) 선적 3~7일 전'
         WHEN gap <= 14 THEN '3) 선적 8~14일 전'
         ELSE                '4) 선적 15일 이상 전'
       END                                   AS 입고_시점,
       COUNT(*)                              AS 줄수,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1) AS 비율,
       ROUND(SUM(po_amount) / 1000000.0, 1)  AS 금액_백만원
FROM (
    SELECT *, CAST(JULIANDAY(missed_ship_date) - JULIANDAY(rcv_date) AS INTEGER) AS gap
    FROM bc_lines
    WHERE bc_cause = 'C. 입고됐는데 누락'
)
GROUP BY 1
ORDER BY 1;
