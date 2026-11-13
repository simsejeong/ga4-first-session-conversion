/* =====================================================================
   03. 모델링용 데이터마트(modeling_mart) 생성 및 매출 기준값 산출
   ---------------------------------------------------------------------
   입력 : `your-project-id.ga4_portfolio.user_mart` (01번에서 생성)
   대상 : D7 관찰 가능 신규 사용자 238,279명
          (첫 세션 구매자 포함 — Python에서 first_session_purchase_flag = 0으로 필터링)
   타깃 : target_purchase_d7  첫 세션 종료 이후 ~ 첫 방문 168시간 이내 구매
          target_return_d1_d7 첫 세션 시작 후 24~168시간 사이 새로운 세션
   ※ BigQuery 샌드박스는 테이블 만료(최대 60일)가 필요해 expiration을 지정함
   ===================================================================== */

CREATE OR REPLACE TABLE `your-project-id.ga4_portfolio.modeling_mart`
OPTIONS (
  expiration_timestamp = TIMESTAMP_ADD(CURRENT_TIMESTAMP(), INTERVAL 30 DAY)
) AS

WITH BASE_USERS AS (
  SELECT  user_pseudo_id,
          first_ga_session_id
    FROM  `your-project-id.ga4_portfolio.user_mart`
   WHERE  observable_D7_flag = 1
     AND  first_ga_session_id IS NOT NULL
),

-- 대상 사용자 이벤트를 한 번만 스캔
EVENTS AS (
  SELECT  e.user_pseudo_id,
          e.event_name,
          e.event_timestamp,
          (
            SELECT  ep.value.int_value
              FROM  UNNEST(e.event_params) AS ep
             WHERE  ep.key = 'ga_session_id'
          ) AS ga_session_id,
          (
            SELECT  ep.value.int_value
              FROM  UNNEST(e.event_params) AS ep
             WHERE  ep.key = 'engagement_time_msec'
          ) AS engagement_time_msec,
          COALESCE((
            SELECT  ep.value.string_value
              FROM  UNNEST(e.event_params) AS ep
             WHERE  ep.key = 'transaction_id'
          ), e.ecommerce.transaction_id) AS transaction_id,
          e.items,
          e.device.category       AS device_category,
          e.traffic_source.medium AS traffic_medium
    FROM  `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*` AS e
    JOIN  BASE_USERS AS b
      ON  e.user_pseudo_id = b.user_pseudo_id
),

FIRST_VISIT AS (
  SELECT  user_pseudo_id,
          MIN(event_timestamp) AS first_visit_ts
    FROM  EVENTS
   WHERE  event_name = 'first_visit'
   GROUP
      BY  user_pseudo_id
),

FIRST_SESSION_EVENTS AS (
  SELECT  e.*
    FROM  EVENTS AS e
    JOIN  BASE_USERS AS b
      ON  e.user_pseudo_id = b.user_pseudo_id
     AND  e.ga_session_id  = b.first_ga_session_id
),

FIRST_SEARCH AS (
  SELECT  user_pseudo_id,
          MIN(event_timestamp) AS first_search_ts
    FROM  FIRST_SESSION_EVENTS
   WHERE  event_name = 'view_search_results'
   GROUP
      BY  user_pseudo_id
),

SESSION_FEATURES AS (
  SELECT  s.user_pseudo_id,
          -- 첫 검색 이후 발생한 상품 조회 횟수 (검색 미경험자는 0)
          COUNTIF(s.event_name = 'view_item'
                  AND s.event_timestamp > fs.first_search_ts)          AS search_then_view_count,
          SUM(COALESCE(s.engagement_time_msec, 0)) / 1000              AS engagement_sec,
          (MAX(s.event_timestamp) - MIN(s.event_timestamp)) / 1000000  AS session_duration_sec,
          COUNT(*)                                                     AS event_count,
          MAX(s.event_timestamp)                                       AS first_session_last_event_ts,
          ANY_VALUE(s.device_category)                                 AS device_category,
          ANY_VALUE(s.traffic_medium)                                  AS traffic_medium
    FROM  FIRST_SESSION_EVENTS AS s
    LEFT
    JOIN  FIRST_SEARCH AS fs
      ON  s.user_pseudo_id = fs.user_pseudo_id
   GROUP
      BY  s.user_pseudo_id
),

-- 탐색 다양성 : 첫 세션에서 조회한 고유 상품 수 · 카테고리 수
ITEM_FEATURES AS (
  SELECT  s.user_pseudo_id,
          COUNT(DISTINCT i.item_id)       AS distinct_item_viewed,
          COUNT(DISTINCT i.item_category) AS distinct_category_viewed
    FROM  FIRST_SESSION_EVENTS AS s,
          UNNEST(s.items) AS i
   WHERE  s.event_name = 'view_item'
   GROUP
      BY  s.user_pseudo_id
),

-- 구매 타깃 : 첫 방문 후 168시간 이내
PURCHASE_TARGET AS (
  SELECT  b.user_pseudo_id,
          MAX(CASE WHEN e.event_name = 'purchase'
                    AND e.transaction_id IS NOT NULL
                    AND e.ga_session_id = b.first_ga_session_id
                   THEN 1 ELSE 0 END) AS first_session_purchase_flag,
          MAX(CASE WHEN e.event_name = 'purchase'
                    AND e.transaction_id IS NOT NULL
                    AND e.event_timestamp > sf.first_session_last_event_ts
                    AND e.ga_session_id IS DISTINCT FROM b.first_ga_session_id
                   THEN 1 ELSE 0 END) AS target_purchase_d7
    FROM  BASE_USERS AS b
    JOIN  FIRST_VISIT AS fv
      ON  b.user_pseudo_id = fv.user_pseudo_id
    JOIN  SESSION_FEATURES AS sf
      ON  b.user_pseudo_id = sf.user_pseudo_id
    LEFT
    JOIN  EVENTS AS e
      ON  b.user_pseudo_id = e.user_pseudo_id
     AND  e.event_timestamp >= fv.first_visit_ts
     AND  e.event_timestamp <= fv.first_visit_ts + 168 * 60 * 60 * 1000000
   GROUP
      BY  b.user_pseudo_id
),

-- 재방문 타깃 : 첫 세션 시작 후 24~168시간 사이 새로운 세션
SESSION_START AS (
  SELECT  user_pseudo_id,
          ga_session_id,
          MIN(event_timestamp) AS session_start_ts
    FROM  EVENTS
   GROUP
      BY  user_pseudo_id,
          ga_session_id
),

ORDERED_SESSIONS AS (
  SELECT  user_pseudo_id,
          session_start_ts,
          ROW_NUMBER() OVER (PARTITION BY user_pseudo_id ORDER BY session_start_ts) AS session_order,
          MIN(session_start_ts) OVER (PARTITION BY user_pseudo_id)                  AS first_session_ts
    FROM  SESSION_START
),

RETURN_TARGET AS (
  SELECT  user_pseudo_id,
          MAX(CASE WHEN session_order >= 2
                    AND session_start_ts >= first_session_ts + 24  * 60 * 60 * 1000000
                    AND session_start_ts <= first_session_ts + 168 * 60 * 60 * 1000000
                   THEN 1 ELSE 0 END) AS target_return_d1_d7
    FROM  ORDERED_SESSIONS
   GROUP
      BY  user_pseudo_id
)

SELECT  u.user_pseudo_id,

        -- 첫 세션 행동 횟수 (flag는 count > 0과 같으므로 모델에는 count만 사용)
        u.view_search_results_count,
        u.view_item_count,
        u.select_item_count,
        u.add_to_cart_count,
        u.view_promotion_count,
        u.select_promotion_count,
        u.begin_checkout_count,
        u.add_shipping_info_count,
        u.add_payment_info_count,

        -- 상품 조회 경로 분해 : 전체 조회 = 검색 후 조회 + 그 외 조회
        sf.search_then_view_count,
        u.view_item_count - sf.search_then_view_count AS other_view_count,
        IF(sf.search_then_view_count >= 3, 1, 0)      AS search_then_view_3plus_flag,

        -- 탐색 깊이 · 참여
        COALESCE(it.distinct_item_viewed, 0)     AS distinct_item_viewed,
        COALESCE(it.distinct_category_viewed, 0) AS distinct_category_viewed,
        sf.engagement_sec,
        sf.session_duration_sec,
        sf.event_count,

        -- 통제 변수 (개선 레버로 해석하지 않음)
        sf.device_category,
        sf.traffic_medium,

        -- 필터 · 타깃
        pt.first_session_purchase_flag,
        pt.target_purchase_d7,
        COALESCE(rt.target_return_d1_d7, 0) AS target_return_d1_d7
  FROM  `your-project-id.ga4_portfolio.user_mart` AS u
  JOIN  SESSION_FEATURES AS sf
    ON  u.user_pseudo_id = sf.user_pseudo_id
  LEFT
  JOIN  ITEM_FEATURES AS it
    ON  u.user_pseudo_id = it.user_pseudo_id
  JOIN  PURCHASE_TARGET AS pt
    ON  u.user_pseudo_id = pt.user_pseudo_id
  LEFT
  JOIN  RETURN_TARGET AS rt
    ON  u.user_pseudo_id = rt.user_pseudo_id;


-- 검증 : 첫 세션 미구매자 236,648명 / 이후 D7 구매 1,122명(0.47%) / D1~D7 재방문 5.00%
SELECT  COUNT(*)                                  AS users,
        SUM(target_purchase_d7)                   AS purchasers,
        ROUND(AVG(target_purchase_d7)  * 100, 2)  AS purchase_rate_pct,
        ROUND(AVG(target_return_d1_d7) * 100, 2)  AS return_rate_pct
  FROM  `your-project-id.ga4_portfolio.modeling_mart`
 WHERE  first_session_purchase_flag = 0;


-- =====================================================================
-- 매출 기준값 : 구매자당 D7 평균 매출 (기대 비즈니스 효과 산정용)
-- =====================================================================

-- (A) 전체 D7 구매자 기준 — 결과: 2,754명 / 총 $211,762 / 구매자당 $76.89
WITH FIRST_VISIT AS (
  SELECT  u.user_pseudo_id,
          MIN(e.event_timestamp) AS first_visit_ts
    FROM  `your-project-id.ga4_portfolio.user_mart` AS u
    JOIN  `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*` AS e
      ON  u.user_pseudo_id = e.user_pseudo_id
   WHERE  u.observable_D7_flag = 1
     AND  e.event_name = 'first_visit'
   GROUP
      BY  u.user_pseudo_id
),

D7_PURCHASE AS (
  SELECT  e.user_pseudo_id,
          SUM(e.ecommerce.purchase_revenue_in_usd) AS d7_revenue_usd
    FROM  `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*` AS e
    JOIN  FIRST_VISIT AS f
      ON  e.user_pseudo_id = f.user_pseudo_id
   WHERE  e.event_name = 'purchase'
     AND  e.event_timestamp BETWEEN f.first_visit_ts
                                AND f.first_visit_ts + 168 * 60 * 60 * 1000000
     AND  COALESCE((
            SELECT  ep.value.string_value
              FROM  UNNEST(e.event_params) AS ep
             WHERE  ep.key = 'transaction_id'
          ), e.ecommerce.transaction_id) IS NOT NULL
   GROUP
      BY  e.user_pseudo_id
)

SELECT  COUNT(*)                         AS d7_purchase_users,
        ROUND(SUM(d7_revenue_usd), 2)    AS total_d7_revenue_usd,
        ROUND(AVG(d7_revenue_usd), 2)    AS avg_d7_revenue_per_buyer_usd
  FROM  D7_PURCHASE;


-- (B) 첫 세션 미구매자의 이후 D7 구매자 기준 (Primary KPI와 같은 모집단)
--     기대 효과를 미구매자 기준으로 산정할 때는 이 값을 구매자당 매출로 사용
WITH TARGET_USERS AS (
  SELECT  m.user_pseudo_id,
          u.first_ga_session_id
    FROM  `your-project-id.ga4_portfolio.modeling_mart` AS m
    JOIN  `your-project-id.ga4_portfolio.user_mart` AS u
      ON  m.user_pseudo_id = u.user_pseudo_id
   WHERE  m.first_session_purchase_flag = 0
     AND  m.target_purchase_d7 = 1
),

FIRST_VISIT AS (
  SELECT  t.user_pseudo_id,
          t.first_ga_session_id,
          MIN(e.event_timestamp) AS first_visit_ts
    FROM  TARGET_USERS AS t
    JOIN  `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*` AS e
      ON  t.user_pseudo_id = e.user_pseudo_id
   WHERE  e.event_name = 'first_visit'
   GROUP
      BY  t.user_pseudo_id,
          t.first_ga_session_id
),

POST_SESSION_REVENUE AS (
  SELECT  e.user_pseudo_id,
          SUM(e.ecommerce.purchase_revenue_in_usd) AS d7_revenue_usd
    FROM  `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*` AS e
    JOIN  FIRST_VISIT AS f
      ON  e.user_pseudo_id = f.user_pseudo_id
   WHERE  e.event_name = 'purchase'
     AND  e.event_timestamp BETWEEN f.first_visit_ts
                                AND f.first_visit_ts + 168 * 60 * 60 * 1000000
     AND  (
            SELECT  ep.value.int_value
              FROM  UNNEST(e.event_params) AS ep
             WHERE  ep.key = 'ga_session_id'
          ) IS DISTINCT FROM f.first_ga_session_id
     AND  COALESCE((
            SELECT  ep.value.string_value
              FROM  UNNEST(e.event_params) AS ep
             WHERE  ep.key = 'transaction_id'
          ), e.ecommerce.transaction_id) IS NOT NULL
   GROUP
      BY  e.user_pseudo_id
)

SELECT  COUNT(*)                         AS post_session_buyers,
        ROUND(SUM(d7_revenue_usd), 2)    AS total_d7_revenue_usd,
        ROUND(AVG(d7_revenue_usd), 2)    AS avg_d7_revenue_per_buyer_usd
  FROM  POST_SESSION_REVENUE;
