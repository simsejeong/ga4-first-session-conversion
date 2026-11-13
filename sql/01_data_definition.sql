/* =====================================================================
   01. 데이터 운영 정의 및 사용자 단위 데이터마트(user_mart) 생성
   ---------------------------------------------------------------------
   데이터 : bigquery-public-data.ga4_obfuscated_sample_ecommerce (2020.11.01 ~ 2021.01.31)
   실행   : `your-project-id.ga4_portfolio` 를 본인 프로젝트/데이터셋으로 바꿔서 실행
   순서   : 01 → 02 → 03 → 04
   ---------------------------------------------------------------------
   [확정한 운영 정의]
   - 신규 사용자 : first_visit이 관찰된 user_pseudo_id 중
                   최초 관찰 이벤트 시각 = 최초 first_visit 시각인 사용자 (256,914명)
   - 첫 세션     : 신규 사용자의 최초 first_visit 이벤트에 연결된 ga_session_id
   - 구매        : purchase 이벤트 중 event_params.transaction_id 또는
                   ecommerce.transaction_id로 주문번호를 확인할 수 있는 구매
   - D7 구매     : 첫 방문 후 168시간 이내 유효한 첫 구매
   - D1~D7 재방문 : 첫 세션 시작 후 24~168시간 사이 새로운 세션 발생
   - 관찰 가능   : 데이터 종료 시점까지 168시간을 온전히 관찰할 수 있는 사용자 (238,279명)
   ===================================================================== */


-- =====================================================================
-- 1. 신규 사용자 정의 검증
-- =====================================================================

-- 1-1. first_visit 이벤트 수 vs 고유 사용자 수
--      결과: 이벤트 257,462건 / 사용자 257,314명 → 147명에게 중복 기록
--      → 신규 사용자 수는 이벤트 수가 아니라 DISTINCT user_pseudo_id로 집계
SELECT  COUNT(*)                       AS event_count,
        COUNT(DISTINCT user_pseudo_id) AS user_count
  FROM  `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
 WHERE  event_name = 'first_visit';


-- 1-2. first_visit 사용자 vs ga_session_number = 1 사용자 비교
--      결과: 교집합 257,314명 / first_visit만 0명 / session_number=1만 3,834명
--      → session_number=1만 있는 3,834명 중 3,831명은 user_first_touch_timestamp도 없음
--      → 최초 방문 정보가 불완전하므로 first_visit을 신규 사용자 기준으로 사용
WITH FIRST_VISIT_USERS AS (
  SELECT  DISTINCT user_pseudo_id
    FROM  `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
   WHERE  event_name = 'first_visit'
),

SESSION_1_USERS AS (
  SELECT  DISTINCT user_pseudo_id
    FROM  `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`,
          UNNEST(event_params) AS ep
   WHERE  ep.key = 'ga_session_number'
     AND  ep.value.int_value = 1
)

SELECT  COUNTIF(f.user_pseudo_id IS NOT NULL AND s.user_pseudo_id IS NOT NULL) AS both_users,
        COUNTIF(f.user_pseudo_id IS NOT NULL AND s.user_pseudo_id IS NULL)     AS first_visit_only,
        COUNTIF(f.user_pseudo_id IS NULL     AND s.user_pseudo_id IS NOT NULL) AS session_1_only
  FROM  FIRST_VISIT_USERS AS f
  FULL
 OUTER
  JOIN  SESSION_1_USERS AS s
    ON  f.user_pseudo_id = s.user_pseudo_id;


-- 1-3. first_visit보다 먼저 발생한 이벤트가 있는 사용자 확인
--      결과: 257,314명 중 256,914명은 최초 이벤트 = 최초 first_visit, 400명(0.16%)은 예외
--      → 예외 400명을 제외한 256,914명을 정제 신규 사용자로 확정
WITH USER_EVENT_TIME AS (
  SELECT  user_pseudo_id,
          MIN(event_timestamp)                                          AS first_event_ts,
          MIN(CASE WHEN event_name = 'first_visit' THEN event_timestamp END) AS first_visit_ts
    FROM  `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
   GROUP
      BY  user_pseudo_id
)

SELECT  COUNT(*)                                  AS first_visit_users,
        COUNTIF(first_event_ts = first_visit_ts)  AS clean_new_users,
        COUNTIF(first_event_ts < first_visit_ts)  AS event_before_first_visit
  FROM  USER_EVENT_TIME
 WHERE  first_visit_ts IS NOT NULL;


-- =====================================================================
-- 2. 구매 정의 검증
-- =====================================================================

-- 2-1. 주문번호 통합 (event_params.transaction_id → 없으면 ecommerce.transaction_id)
--      결과: purchase 5,692건 / 고유 주문 4,467건 / 두 필드 모두 NULL 23건
--      → 두 필드 모두 NULL인 23건은 주문 식별 불가로 제외
WITH PURCHASE_EVENT AS (
  SELECT  user_pseudo_id,
          COALESCE((
            SELECT  ep.value.string_value
              FROM  UNNEST(event_params) AS ep
             WHERE  ep.key = 'transaction_id'
          ), ecommerce.transaction_id) AS final_transaction_id
    FROM  `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
   WHERE  event_name = 'purchase'
)

SELECT  COUNT(*)                              AS purchase_events,
        COUNT(DISTINCT final_transaction_id)  AS distinct_orders,
        COUNTIF(final_transaction_id IS NULL) AS null_transaction_events
  FROM  PURCHASE_EVENT;


-- =====================================================================
-- 3. 관찰 기간(D1/D3/D7) 결정 — 우측 절단(right censoring) 반영
-- =====================================================================

-- 3-1. 경과 시간 기준 관찰 가능 사용자와 기간 내 첫 구매자
--      결과: D7 관찰 가능 238,279명 / 168시간 이내 첫 구매 2,754명 → 1.16%
--            (탐색 단계 참고값: D1 약 0.92%, D3 약 1.03%)
--      → 구매자의 약 84%가 첫 방문 후 7일 이내 첫 구매 → 관찰 기간을 D7(168시간)으로 설정
--      ※ 정수 시간(TIMESTAMP_DIFF ... HOUR) 대신 실제 timestamp 경계로 비교해야
--        168시간을 살짝 넘긴 구매(7명)가 섞이지 않음
WITH USER_EVENT_TIME AS (
  SELECT  user_pseudo_id,
          MIN(event_timestamp)                                          AS first_event_ts,
          MIN(CASE WHEN event_name = 'first_visit' THEN event_timestamp END) AS first_visit_ts
    FROM  `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
   GROUP
      BY  user_pseudo_id
),

CLEAN_NEW_USERS AS (
  SELECT  user_pseudo_id,
          first_visit_ts
    FROM  USER_EVENT_TIME
   WHERE  first_event_ts = first_visit_ts
     AND  first_visit_ts IS NOT NULL
),

FIRST_PURCHASE AS (
  SELECT  user_pseudo_id,
          MIN(event_timestamp) AS first_purchase_ts
    FROM  `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*` AS e
   WHERE  event_name = 'purchase'
     AND  COALESCE((
            SELECT  ep.value.string_value
              FROM  UNNEST(e.event_params) AS ep
             WHERE  ep.key = 'transaction_id'
          ), e.ecommerce.transaction_id) IS NOT NULL
   GROUP
      BY  user_pseudo_id
),

END_EVENT_TIME AS (
  SELECT  MAX(event_timestamp) AS end_event_ts
    FROM  `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
),

BASE AS (
  SELECT  c.user_pseudo_id,
          TIMESTAMP_MICROS(c.first_visit_ts)     AS first_visit_at,
          TIMESTAMP_MICROS(fp.first_purchase_ts) AS first_purchase_at,
          TIMESTAMP_MICROS(et.end_event_ts)      AS end_at
    FROM  CLEAN_NEW_USERS AS c
    LEFT
    JOIN  FIRST_PURCHASE AS fp
      ON  c.user_pseudo_id = fp.user_pseudo_id
   CROSS
    JOIN  END_EVENT_TIME AS et
)

SELECT  window_h,
        COUNTIF(first_visit_at <= TIMESTAMP_SUB(end_at, INTERVAL window_h HOUR)) AS observable_users,
        COUNTIF(first_visit_at <= TIMESTAMP_SUB(end_at, INTERVAL window_h HOUR)
                AND first_purchase_at <= TIMESTAMP_ADD(first_visit_at, INTERVAL window_h HOUR))
                                                                                  AS purchase_users
  FROM  BASE
 CROSS
  JOIN  UNNEST([24, 72, 168]) AS window_h
 GROUP
    BY  window_h
 ORDER
    BY  window_h;


-- =====================================================================
-- 4. 재방문 정의 검증
-- =====================================================================

-- 4-1. ga_session_id는 사용자 간 재사용됨 (8,512개 ID가 2명 이상에게 등장, 최대 17명)
--      → 세션은 user_pseudo_id + ga_session_id 조합으로 식별
--
-- 4-2. D1~D7 재방문율 (첫 세션 시작 후 24~168시간 사이 새로운 세션)
--      결과: 관찰 가능 238,279명 중 12,164명 재방문 → 5.10%
--      ※ 두 번째 세션만 보면 24시간 이내 재접속(68.2%)에 가려 이후 재방문을 놓치므로
--        모든 후속 세션을 확인함
WITH USER_EVENT_TIME AS (
  SELECT  user_pseudo_id,
          MIN(event_timestamp)                                          AS first_event_ts,
          MIN(CASE WHEN event_name = 'first_visit' THEN event_timestamp END) AS first_visit_ts
    FROM  `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
   GROUP
      BY  user_pseudo_id
),

CLEAN_NEW_USERS AS (
  SELECT  user_pseudo_id
    FROM  USER_EVENT_TIME
   WHERE  first_event_ts = first_visit_ts
     AND  first_visit_ts IS NOT NULL
),

USER_SESSION_LEVEL AS (
  SELECT  e.user_pseudo_id,
          (
            SELECT  ep.value.int_value
              FROM  UNNEST(e.event_params) AS ep
             WHERE  ep.key = 'ga_session_id'
          ) AS ga_session_id,
          MIN(e.event_timestamp) AS session_start_ts
    FROM  CLEAN_NEW_USERS AS c
    JOIN  `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*` AS e
      ON  c.user_pseudo_id = e.user_pseudo_id
   GROUP
      BY  e.user_pseudo_id,
          ga_session_id
),

ORDERED_SESSIONS AS (
  SELECT  user_pseudo_id,
          session_start_ts,
          ROW_NUMBER() OVER (PARTITION BY user_pseudo_id ORDER BY session_start_ts) AS session_order,
          MIN(session_start_ts) OVER (PARTITION BY user_pseudo_id)                  AS first_session_ts
    FROM  USER_SESSION_LEVEL
),

END_EVENT_TIME AS (
  SELECT  MAX(event_timestamp) AS end_event_ts
    FROM  `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
)

SELECT  COUNT(DISTINCT IF(
          TIMESTAMP_MICROS(o.first_session_ts)
            <= TIMESTAMP_SUB(TIMESTAMP_MICROS(et.end_event_ts), INTERVAL 168 HOUR),
          o.user_pseudo_id, NULL))                                         AS observable_users,
        COUNT(DISTINCT IF(
          TIMESTAMP_MICROS(o.first_session_ts)
            <= TIMESTAMP_SUB(TIMESTAMP_MICROS(et.end_event_ts), INTERVAL 168 HOUR)
          AND o.session_order >= 2
          AND TIMESTAMP_MICROS(o.session_start_ts)
            BETWEEN TIMESTAMP_ADD(TIMESTAMP_MICROS(o.first_session_ts), INTERVAL 24 HOUR)
                AND TIMESTAMP_ADD(TIMESTAMP_MICROS(o.first_session_ts), INTERVAL 168 HOUR),
          o.user_pseudo_id, NULL))                                         AS returned_d1_d7_users
  FROM  ORDERED_SESSIONS AS o
 CROSS
  JOIN  END_EVENT_TIME AS et;


-- =====================================================================
-- 5. 사용자 단위 데이터마트 생성 (신규 사용자 1명 = 1행)
--    - 첫 세션 ID / 첫 세션 행동 여부·횟수 / D7 구매 여부 / D7 관찰 가능 여부
--    - 검증: 256,914행 = 256,914명, 관찰 가능 238,279명, D7 구매 2,754명
-- =====================================================================
CREATE OR REPLACE TABLE `your-project-id.ga4_portfolio.user_mart` AS

WITH USER_EVENT_TIME AS (
  SELECT  user_pseudo_id,
          MIN(event_timestamp)                                          AS first_event_ts,
          MIN(CASE WHEN event_name = 'first_visit' THEN event_timestamp END) AS first_visit_ts
    FROM  `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
   GROUP
      BY  user_pseudo_id
),

CLEAN_NEW_USERS AS (
  SELECT  user_pseudo_id,
          first_visit_ts
    FROM  USER_EVENT_TIME
   WHERE  first_event_ts = first_visit_ts
     AND  first_visit_ts IS NOT NULL
),

-- 첫 방문 시각에 first_visit·session_start·page_view가 같은 timestamp로 찍혀
-- 사용자당 여러 행이 나오지만 세션 ID는 모두 동일 → DISTINCT로 사용자당 1행
FIRST_SESSION AS (
  SELECT  DISTINCT
          c.user_pseudo_id,
          (
            SELECT  ep.value.int_value
              FROM  UNNEST(e.event_params) AS ep
             WHERE  ep.key = 'ga_session_id'
          ) AS first_ga_session_id
    FROM  CLEAN_NEW_USERS AS c
    JOIN  `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*` AS e
      ON  c.user_pseudo_id = e.user_pseudo_id
     AND  c.first_visit_ts = e.event_timestamp
),

FIRST_SESSION_EVENTS AS (
  SELECT  f.user_pseudo_id,
          e.event_name
    FROM  FIRST_SESSION AS f
    JOIN  `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*` AS e
      ON  f.user_pseudo_id = e.user_pseudo_id
   WHERE  (
            SELECT  ep.value.int_value
              FROM  UNNEST(e.event_params) AS ep
             WHERE  ep.key = 'ga_session_id'
          ) = f.first_ga_session_id
),

FIRST_PURCHASE AS (
  SELECT  c.user_pseudo_id,
          MIN(e.event_timestamp) AS first_purchase_ts
    FROM  CLEAN_NEW_USERS AS c
    JOIN  `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*` AS e
      ON  c.user_pseudo_id = e.user_pseudo_id
   WHERE  e.event_name = 'purchase'
     AND  COALESCE((
            SELECT  ep.value.string_value
              FROM  UNNEST(e.event_params) AS ep
             WHERE  ep.key = 'transaction_id'
          ), e.ecommerce.transaction_id) IS NOT NULL
   GROUP
      BY  c.user_pseudo_id
),

END_EVENT_TIME AS (
  SELECT  MAX(event_timestamp) AS end_event_ts
    FROM  `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
),

D7_PURCHASE AS (
  SELECT  c.user_pseudo_id,
          CASE WHEN fp.first_purchase_ts IS NOT NULL
                AND TIMESTAMP_MICROS(fp.first_purchase_ts)
                    <= TIMESTAMP_ADD(TIMESTAMP_MICROS(c.first_visit_ts), INTERVAL 168 HOUR)
               THEN 1 ELSE 0 END AS D7_purchase_flag,
          CASE WHEN TIMESTAMP_MICROS(c.first_visit_ts)
                    <= TIMESTAMP_SUB(TIMESTAMP_MICROS(et.end_event_ts), INTERVAL 168 HOUR)
               THEN 1 ELSE 0 END AS observable_D7_flag
    FROM  CLEAN_NEW_USERS AS c
    LEFT
    JOIN  FIRST_PURCHASE AS fp
      ON  c.user_pseudo_id = fp.user_pseudo_id
   CROSS
    JOIN  END_EVENT_TIME AS et
),

FIRST_SESSION_BEHAVIOR AS (
  SELECT  user_pseudo_id,
          -- 행동 여부 (0/1)
          MAX(IF(event_name = 'view_item',           1, 0)) AS view_item_flag,
          MAX(IF(event_name = 'view_search_results', 1, 0)) AS view_search_results_flag,
          MAX(IF(event_name = 'select_item',         1, 0)) AS select_item_flag,
          MAX(IF(event_name = 'add_to_cart',         1, 0)) AS add_to_cart_flag,
          MAX(IF(event_name = 'view_promotion',      1, 0)) AS view_promotion_flag,
          MAX(IF(event_name = 'select_promotion',    1, 0)) AS select_promotion_flag,
          MAX(IF(event_name = 'begin_checkout',      1, 0)) AS begin_checkout_flag,
          MAX(IF(event_name = 'add_shipping_info',   1, 0)) AS add_shipping_info_flag,
          MAX(IF(event_name = 'add_payment_info',    1, 0)) AS add_payment_info_flag,
          -- 행동 횟수
          COUNTIF(event_name = 'view_item')           AS view_item_count,
          COUNTIF(event_name = 'view_search_results') AS view_search_results_count,
          COUNTIF(event_name = 'select_item')         AS select_item_count,
          COUNTIF(event_name = 'add_to_cart')         AS add_to_cart_count,
          COUNTIF(event_name = 'view_promotion')      AS view_promotion_count,
          COUNTIF(event_name = 'select_promotion')    AS select_promotion_count,
          COUNTIF(event_name = 'begin_checkout')      AS begin_checkout_count,
          COUNTIF(event_name = 'add_shipping_info')   AS add_shipping_info_count,
          COUNTIF(event_name = 'add_payment_info')    AS add_payment_info_count
    FROM  FIRST_SESSION_EVENTS
   GROUP
      BY  user_pseudo_id
)

SELECT  b.*,
        f.first_ga_session_id,
        fp.first_purchase_ts,
        p.D7_purchase_flag,
        p.observable_D7_flag
  FROM  FIRST_SESSION_BEHAVIOR AS b
  JOIN  FIRST_SESSION AS f
    ON  b.user_pseudo_id = f.user_pseudo_id
  JOIN  D7_PURCHASE AS p
    ON  b.user_pseudo_id = p.user_pseudo_id
  LEFT
  JOIN  FIRST_PURCHASE AS fp
    ON  b.user_pseudo_id = fp.user_pseudo_id;


-- 5-1. 데이터마트 검증
SELECT  COUNT(*)                                                  AS row_cnt,
        COUNT(DISTINCT user_pseudo_id)                            AS user_cnt,
        COUNTIF(observable_D7_flag = 1)                           AS observable_D7_users,
        COUNTIF(observable_D7_flag = 1 AND D7_purchase_flag = 1)  AS D7_purchase_users
  FROM  `your-project-id.ga4_portfolio.user_mart`;
