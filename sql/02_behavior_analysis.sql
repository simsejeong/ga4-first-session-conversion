/* =====================================================================
   02. 첫 세션 행동 분석 — 행동 X 후보 탐색
   ---------------------------------------------------------------------
   입력 : `your-project-id.ga4_portfolio.user_mart` (01번에서 생성)
   대상 : D7 관찰 가능 신규 사용자 238,279명 (observable_D7_flag = 1)
   ===================================================================== */


-- =====================================================================
-- 1. 첫 세션 행동별 D7 구매전환율 비교 (정방향 + 역방향)
--    - coverage           : 전체 사용자 중 행동 경험자 비율
--    - rate_diff_pp       : 경험군 전환율 - 비경험군 전환율
--    - lift               : 경험군 전환율 / 비경험군 전환율
--    - purchaser_overlap  : 전체 D7 구매자 중 행동 경험자 비율 (역방향)
--    결과 요약: view_item 5.22% vs 0.17% / view_search_results 3.30% vs 1.05%
--              select_item 10.81% vs 0.81%
--    ※ begin_checkout · add_payment_info 등 결제 직전 행동은 전환율은 높지만
--      구매 의도가 이미 높은 사용자의 행동이라 개선 레버(X)에서 제외
-- =====================================================================
WITH BASE AS (
  SELECT  *
    FROM  `your-project-id.ga4_portfolio.user_mart`
   WHERE  observable_D7_flag = 1
),

LONG AS (
  SELECT  b.D7_purchase_flag,
          x.behavior,
          x.flag
    FROM  BASE AS b,
          UNNEST([
            STRUCT('view_item'           AS behavior, b.view_item_flag           AS flag),
            STRUCT('view_search_results' AS behavior, b.view_search_results_flag AS flag),
            STRUCT('select_item'         AS behavior, b.select_item_flag         AS flag),
            STRUCT('add_to_cart'         AS behavior, b.add_to_cart_flag         AS flag),
            STRUCT('view_promotion'      AS behavior, b.view_promotion_flag      AS flag),
            STRUCT('select_promotion'    AS behavior, b.select_promotion_flag    AS flag),
            STRUCT('begin_checkout'      AS behavior, b.begin_checkout_flag      AS flag),
            STRUCT('add_shipping_info'   AS behavior, b.add_shipping_info_flag   AS flag),
            STRUCT('add_payment_info'    AS behavior, b.add_payment_info_flag    AS flag)
          ]) AS x
),

SUMMARY AS (
  SELECT  behavior,
          COUNTIF(flag = 1)                                                     AS exposed_users,
          COUNT(*)                                                              AS total_users,
          SAFE_DIVIDE(COUNTIF(flag = 1 AND D7_purchase_flag = 1), COUNTIF(flag = 1)) AS exposed_cvr,
          SAFE_DIVIDE(COUNTIF(flag = 0 AND D7_purchase_flag = 1), COUNTIF(flag = 0)) AS non_exposed_cvr,
          SAFE_DIVIDE(COUNTIF(flag = 1 AND D7_purchase_flag = 1), COUNTIF(D7_purchase_flag = 1)) AS purchaser_overlap
    FROM  LONG
   GROUP
      BY  behavior
)

SELECT  behavior,
        exposed_users,
        ROUND(exposed_users / total_users * 100, 2)               AS coverage_pct,
        ROUND(exposed_cvr * 100, 2)                               AS exposed_cvr_pct,
        ROUND(non_exposed_cvr * 100, 2)                           AS non_exposed_cvr_pct,
        ROUND((exposed_cvr - non_exposed_cvr) * 100, 2)           AS rate_diff_pp,
        ROUND(SAFE_DIVIDE(exposed_cvr, non_exposed_cvr), 1)       AS lift,
        ROUND(purchaser_overlap * 100, 2)                         AS purchaser_overlap_pct
  FROM  SUMMARY
 ORDER
    BY  rate_diff_pp DESC;


-- =====================================================================
-- 2. 첫 세션 미구매자의 상품 조회 횟수 구간별 이후 D7 구매전환율
--    대상 : D7 관찰 가능 + 첫 세션 미구매 신규 사용자 236,648명
--    결과 : 0회 0.16% → 1~2회 0.76% → 3~4회 2.11% → 5~6회 2.93%
--           → 7~9회 4.61% → 10회 이상 6.80%
-- =====================================================================
WITH FIRST_SESSION_END AS (
  SELECT  u.user_pseudo_id,
          MAX(e.event_timestamp) AS first_session_last_event_ts
    FROM  `your-project-id.ga4_portfolio.user_mart` AS u
    JOIN  `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*` AS e
      ON  u.user_pseudo_id = e.user_pseudo_id
   WHERE  u.observable_D7_flag = 1
     AND  (
            SELECT  ep.value.int_value
              FROM  UNNEST(e.event_params) AS ep
             WHERE  ep.key = 'ga_session_id'
          ) = u.first_ga_session_id
   GROUP
      BY  u.user_pseudo_id
),

FIRST_VISIT AS (
  SELECT  user_pseudo_id,
          MIN(event_timestamp) AS first_visit_ts
    FROM  `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
   WHERE  event_name = 'first_visit'
   GROUP
      BY  user_pseudo_id
),

PURCHASE_EVENTS AS (
  SELECT  e.user_pseudo_id,
          e.event_timestamp AS purchase_ts,
          (
            SELECT  ep.value.int_value
              FROM  UNNEST(e.event_params) AS ep
             WHERE  ep.key = 'ga_session_id'
          ) AS purchase_session_id
    FROM  `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*` AS e
   WHERE  e.event_name = 'purchase'
     AND  COALESCE((
            SELECT  ep.value.string_value
              FROM  UNNEST(e.event_params) AS ep
             WHERE  ep.key = 'transaction_id'
          ), e.ecommerce.transaction_id) IS NOT NULL
),

USER_STATUS AS (
  SELECT  u.user_pseudo_id,
          u.view_item_count,
          MAX(IF(p.purchase_session_id = u.first_ga_session_id, 1, 0)) AS first_session_purchase_flag,
          MAX(IF(p.purchase_ts > s.first_session_last_event_ts
                 AND p.purchase_ts <= f.first_visit_ts + 168 * 60 * 60 * 1000000, 1, 0))
                                                                     AS post_session_D7_purchase_flag
    FROM  `your-project-id.ga4_portfolio.user_mart` AS u
    JOIN  FIRST_VISIT AS f
      ON  u.user_pseudo_id = f.user_pseudo_id
    JOIN  FIRST_SESSION_END AS s
      ON  u.user_pseudo_id = s.user_pseudo_id
    LEFT
    JOIN  PURCHASE_EVENTS AS p
      ON  u.user_pseudo_id = p.user_pseudo_id
     AND  p.purchase_ts >= f.first_visit_ts
   WHERE  u.observable_D7_flag = 1
   GROUP
      BY  u.user_pseudo_id,
          u.view_item_count
),

GROUPED AS (
  SELECT  post_session_D7_purchase_flag,
          CASE WHEN view_item_count = 0             THEN '0회'
               WHEN view_item_count BETWEEN 1 AND 2 THEN '1~2회'
               WHEN view_item_count BETWEEN 3 AND 4 THEN '3~4회'
               WHEN view_item_count BETWEEN 5 AND 6 THEN '5~6회'
               WHEN view_item_count BETWEEN 7 AND 9 THEN '7~9회'
               ELSE '10회 이상' END AS view_count_group,
          CASE WHEN view_item_count = 0             THEN 0
               WHEN view_item_count BETWEEN 1 AND 2 THEN 1
               WHEN view_item_count BETWEEN 3 AND 4 THEN 2
               WHEN view_item_count BETWEEN 5 AND 6 THEN 3
               WHEN view_item_count BETWEEN 7 AND 9 THEN 4
               ELSE 5 END AS group_order
    FROM  USER_STATUS
   WHERE  first_session_purchase_flag = 0
)

SELECT  view_count_group,
        COUNT(*)                                                                       AS users,
        ROUND(COUNT(*) / SUM(COUNT(*)) OVER () * 100, 2)                               AS user_share_pct,
        COUNTIF(post_session_D7_purchase_flag = 1)                                     AS buyers,
        ROUND(COUNTIF(post_session_D7_purchase_flag = 1) / COUNT(*) * 100, 2)          AS purchase_rate_pct,
        ROUND(COUNTIF(post_session_D7_purchase_flag = 1)
              / SUM(COUNTIF(post_session_D7_purchase_flag = 1)) OVER () * 100, 2)      AS buyer_coverage_pct
  FROM  GROUPED
 GROUP
    BY  view_count_group,
        group_order
 ORDER
    BY  group_order;


-- =====================================================================
-- 3. 검색 이후 상품 조회 발생 여부 (이벤트 순서 기준)
--    대상 : D7 관찰 가능 + 첫 세션 검색 경험자 10,862명
--    결과 : 첫 검색 이후 상품 조회 발생 40.42%
--    ※ 첫 검색 결과 조회 시점보다 늦게 발생한 view_item만 집계
-- =====================================================================
WITH BASE_USERS AS (
  SELECT  user_pseudo_id,
          first_ga_session_id
    FROM  `your-project-id.ga4_portfolio.user_mart`
   WHERE  observable_D7_flag = 1
),

FIRST_SESSION_EVENTS AS (
  SELECT  e.user_pseudo_id,
          e.event_name,
          e.event_timestamp
    FROM  `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*` AS e
    JOIN  BASE_USERS AS u
      ON  e.user_pseudo_id = u.user_pseudo_id
   WHERE  e.event_name IN ('view_search_results', 'view_item')
     AND  (
            SELECT  ep.value.int_value
              FROM  UNNEST(e.event_params) AS ep
             WHERE  ep.key = 'ga_session_id'
          ) = u.first_ga_session_id
),

FIRST_SEARCH AS (
  SELECT  user_pseudo_id,
          MIN(event_timestamp) AS first_search_ts
    FROM  FIRST_SESSION_EVENTS
   WHERE  event_name = 'view_search_results'
   GROUP
      BY  user_pseudo_id
),

SEARCH_TO_VIEW AS (
  SELECT  s.user_pseudo_id,
          COUNTIF(e.event_name = 'view_item'
                  AND e.event_timestamp > s.first_search_ts) AS post_search_view_count
    FROM  FIRST_SEARCH AS s
    LEFT
    JOIN  FIRST_SESSION_EVENTS AS e
      ON  s.user_pseudo_id = e.user_pseudo_id
   GROUP
      BY  s.user_pseudo_id
)

SELECT  COUNT(*)                                                         AS search_users,
        COUNTIF(post_search_view_count >= 1)                             AS post_search_view_users,
        ROUND(COUNTIF(post_search_view_count >= 1) / COUNT(*) * 100, 2)  AS post_search_view_rate_pct,
        ROUND(AVG(post_search_view_count), 2)                            AS avg_post_search_view_count
  FROM  SEARCH_TO_VIEW;


-- =====================================================================
-- 4. 검색 이후 상품 조회 N회 이상 기준별 D7 구매전환율
--    대상 : D7 관찰 가능 + 첫 세션 검색 경험 + 첫 세션 미구매 10,611명
--    결과 : 1회 이상 2.07% vs 0.33% (+1.74%p, 구매자 포괄률 80.37%)
--           3회 이상 2.93% vs 0.49% (+2.44%p, 구매자 포괄률 61.68%)
--    → 전환율 격차와 구매자 포괄률을 함께 고려해 '3회 이상'을 1차 행동 후보로 선정
-- =====================================================================
WITH FIRST_SESSION_EVENTS AS (
  SELECT  u.user_pseudo_id,
          e.event_name,
          e.event_timestamp,
          COALESCE((
            SELECT  ep.value.string_value
              FROM  UNNEST(e.event_params) AS ep
             WHERE  ep.key = 'transaction_id'
          ), e.ecommerce.transaction_id) AS transaction_id
    FROM  `your-project-id.ga4_portfolio.user_mart` AS u
    JOIN  `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*` AS e
      ON  u.user_pseudo_id = e.user_pseudo_id
   WHERE  u.observable_D7_flag = 1
     AND  u.view_search_results_flag = 1
     AND  (
            SELECT  ep.value.int_value
              FROM  UNNEST(e.event_params) AS ep
             WHERE  ep.key = 'ga_session_id'
          ) = u.first_ga_session_id
),

FIRST_SESSION_SUMMARY AS (
  SELECT  user_pseudo_id,
          COUNTIF(event_name = 'purchase' AND transaction_id IS NOT NULL) AS first_session_purchase_count,
          MIN(IF(event_name = 'view_search_results', event_timestamp, NULL)) AS first_search_ts
    FROM  FIRST_SESSION_EVENTS
   GROUP
      BY  user_pseudo_id
),

USER_LEVEL AS (
  SELECT  s.user_pseudo_id,
          COUNTIF(e.event_name = 'view_item'
                  AND e.event_timestamp > s.first_search_ts) AS post_search_view_count,
          ANY_VALUE(u.D7_purchase_flag)                      AS D7_purchase_flag
    FROM  FIRST_SESSION_SUMMARY AS s
    JOIN  FIRST_SESSION_EVENTS AS e
      ON  s.user_pseudo_id = e.user_pseudo_id
    JOIN  `your-project-id.ga4_portfolio.user_mart` AS u
      ON  s.user_pseudo_id = u.user_pseudo_id
   WHERE  s.first_session_purchase_count = 0
     AND  s.first_search_ts IS NOT NULL
   GROUP
      BY  s.user_pseudo_id
),

N_ANALYSIS AS (
  SELECT  N,
          COUNT(*)                                                       AS total_users,
          COUNTIF(u.D7_purchase_flag = 1)                                AS total_buyers,
          COUNTIF(u.post_search_view_count >= N)                         AS achieved_users,
          COUNTIF(u.post_search_view_count >= N AND u.D7_purchase_flag = 1) AS achieved_buyers,
          COUNTIF(u.post_search_view_count <  N)                         AS not_achieved_users,
          COUNTIF(u.post_search_view_count <  N AND u.D7_purchase_flag = 1) AS not_achieved_buyers
    FROM  UNNEST(GENERATE_ARRAY(1, 10)) AS N
   CROSS
    JOIN  USER_LEVEL AS u
   GROUP
      BY  N
)

SELECT  CONCAT(CAST(N AS STRING), '회 이상')                                    AS threshold,
        achieved_users,
        ROUND(SAFE_DIVIDE(achieved_buyers, achieved_users) * 100, 2)           AS achieved_cvr_pct,
        ROUND(SAFE_DIVIDE(not_achieved_buyers, not_achieved_users) * 100, 2)   AS not_achieved_cvr_pct,
        ROUND((SAFE_DIVIDE(achieved_buyers, achieved_users)
              - SAFE_DIVIDE(not_achieved_buyers, not_achieved_users)) * 100, 2) AS cvr_diff_pp,
        ROUND(SAFE_DIVIDE(achieved_buyers, total_buyers) * 100, 2)             AS buyer_coverage_pct,
        ROUND(SAFE_DIVIDE(achieved_users, total_users) * 100, 2)               AS user_coverage_pct
  FROM  N_ANALYSIS
 ORDER
    BY  N;
