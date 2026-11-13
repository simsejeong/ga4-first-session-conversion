/* =====================================================================
   04. 페이지 경로 분석 — "어디를 개선할 것인가?"
   ---------------------------------------------------------------------
   입력 : user_mart (01), modeling_mart (03)
   대상 : 첫 세션 미구매 · D7 관찰 가능 신규 사용자 236,648명 (모델과 동일)
   목적 : 상품 상세 진입이 막히는 화면을 찾아 우선 개선 대상을 선정
   흐름 : 페이지 유형 사전 → 첫 세션 페이지 이벤트 → 탐색 단계 재정의(X)
          → 화면별 상세 도달률 → 목록 페이지 다음 이동 → 목록 방문자 퍼널
   ===================================================================== */

-- STEP 0. [품질 점검] page_view의 URL 결측 · 난독화 비율
-- 결측·비정상 비율이 높으면 '페이지 정보 없음' 집단이 커지므로 먼저 확인

WITH PV AS (
  SELECT  (
            SELECT  ep.value.string_value
              FROM  UNNEST(e.event_params) AS ep
             WHERE  ep.key = 'page_location'
          ) AS page_location
    FROM  `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*` AS e
   WHERE  e.event_name = 'page_view'
)
 
SELECT  COUNT(*)                                                              AS page_views,
        ROUND(AVG(IF(page_location IS NULL, 1, 0)) * 100, 2)                  AS null_pct,
        ROUND(AVG(IF(page_location IS NOT NULL
                     AND NOT STARTS_WITH(page_location, 'http'), 1, 0)) * 100, 2) AS non_url_pct,
        ROUND(AVG(IF(REGEXP_CONTAINS(page_location, r'googlemerchandisestore\.com'),
                     1, 0)) * 100, 2)                                          AS merch_domain_pct
  FROM  PV;

-- STEP 1. 페이지 유형 사전 만들기 (상품명 기반 상세 판별)
-- URL 정규화 : 쿼리스트링 제거 → 소문자 → 끝 슬래시 제거
-- 분류 규칙 (위에서부터 우선 적용)
--   메인            : 도메인 루트(shop. / www. / 무접두 모두)
--   검색 결과       : URL에 search 포함(asearch.html 등) 또는 view_search_results 발생
--   장바구니·결제·계정 : basket, signin, yourinfo, payment, revieworder, ordercompleted 등
--   상품 상세       : URL 마지막 경로가 상품명(items.item_name)과 일치
--                    (view_item 비율 규칙은 카테고리 페이지에서도 view_item이 발생해 사용하지 않음)
--   카테고리·목록   : store.html, /google+redesign/ 아래이면서 상품 상세가 아닌 페이지
--   기타            : 정책·안내 페이지 등
-- =====================================================================
CREATE OR REPLACE TABLE `your-project-id.ga4_portfolio.page_type_dict`
OPTIONS (
  expiration_timestamp = TIMESTAMP_ADD(CURRENT_TIMESTAMP(), INTERVAL 30 DAY)
) AS
 
WITH RAW AS (
  SELECT  e.event_name,
          REGEXP_REPLACE(LOWER(REGEXP_REPLACE((
            SELECT  ep.value.string_value
              FROM  UNNEST(e.event_params) AS ep
             WHERE  ep.key = 'page_location'
          ), r'[?#].*$', '')), r'/+$', '') AS page     -- URL 정규화
    FROM  `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*` AS e
),
 
-- 상품명 → URL 슬러그 형태로 정규화 (영문·숫자만 남기고 공백은 +)
ITEM_SLUGS AS (
  SELECT  DISTINCT
          REGEXP_REPLACE(
            TRIM(REGEXP_REPLACE(LOWER(i.item_name), r'[^a-z0-9 ]', '')),
            r'\s+', '+') AS slug
    FROM  `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*` AS e,
          UNNEST(e.items) AS i
   WHERE  i.item_name IS NOT NULL
     AND  i.item_name NOT IN ('(not set)', '')
),
 
PAGE_STATS AS (
  SELECT  page,
          -- URL 마지막 경로도 같은 방식으로 정규화 (%XX 인코딩 제거 후 영문·숫자·+만 유지)
          REGEXP_REPLACE(
            REGEXP_REPLACE(REGEXP_EXTRACT(page, r'/([^/]+)$'), r'%[0-9a-f]{2}', ''),
            r'[^a-z0-9+]', '')                      AS last_slug,
          COUNTIF(event_name = 'page_view')           AS page_views,
          COUNTIF(event_name = 'view_item')           AS view_items,
          COUNTIF(event_name = 'view_search_results') AS search_results,
          COUNTIF(event_name = 'select_item')         AS select_items,
          COUNTIF(event_name = 'view_promotion')      AS view_promotions
    FROM  RAW
   WHERE  page IS NOT NULL
   GROUP
      BY  page
),
 
-- 하위 URL이 있는 페이지 = 카테고리 (예: apparel → apparel/mens)
PARENT_PAGES AS (
  SELECT  DISTINCT p1.page
    FROM  PAGE_STATS AS p1
    JOIN  PAGE_STATS AS p2
      ON  STARTS_WITH(p2.page, p1.page || '/')
)
 
SELECT  p.page,
        p.page_views,
        p.view_items,
        p.search_results,
        p.select_items,
        p.view_promotions,
        CASE
          WHEN REGEXP_CONTAINS(p.page, r'^https?://[^/]+$')                                  THEN '메인'
          WHEN REGEXP_CONTAINS(p.page, r'search') OR p.search_results > 0                    THEN '검색 결과'
          WHEN REGEXP_CONTAINS(p.page, r'basket|cart|checkout|signin|yourinfo|payment|revieworder|ordercompleted|myaccount|register|login')
                                                                                             THEN '장바구니·결제·계정'
          WHEN s.slug IS NOT NULL                                                            THEN '상품 상세'
          WHEN ENDS_WITH(p.page, '/store.html')                                              THEN '카테고리·목록'
          WHEN REGEXP_CONTAINS(p.page, r'/google\+redesign/')
           AND (p.select_items > 0 OR pp.page IS NOT NULL)                                   THEN '카테고리·목록'
          WHEN REGEXP_CONTAINS(p.page, r'/google\+redesign/')                                THEN '상품 상세'
          ELSE '기타'
        END AS page_type,
        CASE
          WHEN s.slug IS NOT NULL                                                            THEN '상품명 일치'
          WHEN REGEXP_CONTAINS(p.page, r'/google\+redesign/')
           AND p.select_items = 0 AND pp.page IS NULL                                        THEN '구조 추정'
          ELSE NULL
        END AS detail_rule      -- 상품 상세 판별 근거 (검증용)
  FROM  PAGE_STATS AS p
  LEFT
  JOIN  ITEM_SLUGS AS s
    ON  p.last_slug = s.slug
  LEFT
  JOIN  PARENT_PAGES AS pp
    ON  p.page = pp.page;

-- STEP 2. 분석 대상의 첫 세션 페이지 이벤트 테이블
CREATE OR REPLACE TABLE `your-project-id.ga4_portfolio.fs_page_events`
OPTIONS (
  expiration_timestamp = TIMESTAMP_ADD(CURRENT_TIMESTAMP(), INTERVAL 30 DAY)
) AS
 
WITH BASE AS (
  SELECT  m.user_pseudo_id,
          u.first_ga_session_id
    FROM  `your-project-id.ga4_portfolio.modeling_mart` AS m
    JOIN  `your-project-id.ga4_portfolio.user_mart` AS u
      ON  m.user_pseudo_id = u.user_pseudo_id
   WHERE  m.first_session_purchase_flag = 0
)
 
SELECT  b.user_pseudo_id,
        e.event_name,
        e.event_timestamp,
        REGEXP_REPLACE(LOWER(REGEXP_REPLACE((
          SELECT  ep.value.string_value
            FROM  UNNEST(e.event_params) AS ep
           WHERE  ep.key = 'page_location'
        ), r'[?#].*$', '')), r'/+$', '') AS page          -- STEP 1과 동일한 정규화
  FROM  `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*` AS e
  JOIN  BASE AS b
    ON  e.user_pseudo_id = b.user_pseudo_id
 WHERE  e.event_name IN ('page_view', 'view_item')
   AND  (
          SELECT  ep.value.int_value
            FROM  UNNEST(e.event_params) AS ep
           WHERE  ep.key = 'ga_session_id'
        ) = b.first_ga_session_id;

-- STEP 3. [검증] 유형별 대표 페이지 확인
-- 상품 상세 상위 URL이 상품명, 카테고리·목록 상위 URL이 분류명인지 확인
-- '기타' 비중이 크면 STEP 1 규칙을 보완

SELECT  page_type,
        page,
        page_views,
        view_items,
        search_results,
        select_items,
        ROUND(SUM(page_views) OVER (PARTITION BY page_type)
              / SUM(page_views) OVER () * 100, 2) AS type_pv_share_pct
  FROM  (
          SELECT  *,
                  ROW_NUMBER() OVER (PARTITION BY page_type ORDER BY page_views DESC) AS rn
            FROM  `your-project-id.ga4_portfolio.page_type_dict`
        )
 WHERE  rn <= 5
 ORDER
    BY  page_type,
        page_views DESC;

-- STEP 3-2. [진단] view_item 이벤트는 실제로 어느 페이지에서 발생하는가?
-- 결과: 카테고리·목록 60.42% / 상품 상세 37.23% / 검색 결과 2.23%
--       → view_item ≠ 상품 상세 도달
-- 상품 상세 비중이 낮고 이벤트당 상품 수가 1보다 크면
-- view_item = 목록 노출·퀵뷰를 포함한 '상품 조회' 지표로 해석해야 함

WITH VI AS (
  SELECT  REGEXP_REPLACE(LOWER(REGEXP_REPLACE((
            SELECT  ep.value.string_value
              FROM  UNNEST(e.event_params) AS ep
             WHERE  ep.key = 'page_location'
          ), r'[?#].*$', '')), r'/+$', '') AS page,
          ARRAY_LENGTH(e.items)            AS n_items
    FROM  `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*` AS e
   WHERE  e.event_name = 'view_item'
)
 
SELECT  COALESCE(d.page_type, '사전 없음')               AS page_type,
        COUNT(*)                                         AS view_item_events,
        ROUND(COUNT(*) / SUM(COUNT(*)) OVER () * 100, 2) AS event_share_pct,
        ROUND(AVG(v.n_items), 2)                         AS avg_items_per_event,
        ROUND(AVG(IF(v.n_items = 1, 1, 0)) * 100, 2)     AS single_item_event_pct
  FROM  VI AS v
  LEFT
  JOIN  `your-project-id.ga4_portfolio.page_type_dict` AS d
    ON  v.page = d.page
 GROUP
    BY  page_type
 ORDER
    BY  view_item_events DESC;

-- STEP 3-3. [검증] 유형별 고유 페이지 수 · 카테고리 하위 URL 점검
-- 카테고리·목록 페이지 수가 수백 개 이상이면 상품명 매칭에서 빠진 상품 페이지가 섞인 것
-- 아래 두 번째 쿼리에서 상품명처럼 보이는 URL이 많으면 STEP 1 규칙 보완 필요

SELECT  page_type,
        detail_rule,
        COUNT(*)        AS distinct_pages,
        SUM(page_views) AS page_views
  FROM  `your-project-id.ga4_portfolio.page_type_dict`
 GROUP
    BY  page_type,
        detail_rule
 ORDER
    BY  page_views DESC;
 
SELECT  page,
        page_views,
        view_items,
        select_items
  FROM  `your-project-id.ga4_portfolio.page_type_dict`
 WHERE  page_type = '카테고리·목록'
 ORDER
    BY  page_views DESC
 LIMIT  50;

-- STEP 3-4. [X 재정의] 첫 세션 탐색 단계별 성과 (4단계)
-- view_item의 약 60%가 목록 페이지(이벤트당 상품 여러 개)에서 발생
-- → view_item은 '상세 조회'가 아니라 '상품 노출·조회' 지표
-- → 페이지 유형 기준으로 탐색 단계를 다시 정의해 비교
--   1. 상품 탐색 화면 미도달 : 메인·기타 페이지만 봄
--   2. 목록·검색까지만 도달  : 카테고리·목록 또는 검색 결과는 봤지만 상세는 안 봄
--   3. 상세 직접 랜딩        : 다른 화면을 거치지 않고 상품 상세로 바로 진입
--   4. 탐색 경유 상세 도달   : 목록·검색 등 다른 화면을 거쳐 상품 상세에 도달
-- 결과: 탐색 경유 상세 도달 7.97% / D7 구매전환율 2.72% / 구매자 포괄률 45.72%
--       상세 직접 랜딩 13.40% / D7 구매전환율 0.26%
-- ※ 정리 과정에서 기존 3단계 쿼리와 STEP 5(출발 화면)를 하나로 합침
--   → 실행 후 위 결과값과 일치하는지 확인

WITH BASE AS (
  SELECT  user_pseudo_id,
          target_purchase_d7,
          target_return_d1_d7
    FROM  `your-project-id.ga4_portfolio.modeling_mart`
   WHERE  first_session_purchase_flag = 0
),

PV AS (
  SELECT  f.user_pseudo_id,
          f.event_timestamp,
          COALESCE(d.page_type, '기타') AS page_type
    FROM  `your-project-id.ga4_portfolio.fs_page_events` AS f
    LEFT
    JOIN  `your-project-id.ga4_portfolio.page_type_dict` AS d
      ON  f.page = d.page
   WHERE  f.event_name = 'page_view'
),

FIRST_DETAIL AS (
  SELECT  user_pseudo_id,
          MIN(event_timestamp) AS first_detail_ts
    FROM  PV
   WHERE  page_type = '상품 상세'
   GROUP
      BY  user_pseudo_id
),

-- 첫 상품 상세 이전에 다른 화면을 거쳤는지
PRIOR_BROWSE AS (
  SELECT  DISTINCT f.user_pseudo_id
    FROM  FIRST_DETAIL AS f
    JOIN  PV AS p
      ON  f.user_pseudo_id = p.user_pseudo_id
     AND  p.event_timestamp < f.first_detail_ts
     AND  p.page_type != '상품 상세'
),

SCREENS AS (
  SELECT  user_pseudo_id,
          MAX(IF(page_type IN ('카테고리·목록', '검색 결과'), 1, 0)) AS saw_list_or_search
    FROM  PV
   GROUP
      BY  user_pseudo_id
),

USERS AS (
  SELECT  b.*,
          CASE WHEN fd.user_pseudo_id IS NOT NULL AND pb.user_pseudo_id IS NOT NULL THEN '4. 탐색 경유 상세 도달'
               WHEN fd.user_pseudo_id IS NOT NULL                                  THEN '3. 상세 직접 랜딩'
               WHEN COALESCE(s.saw_list_or_search, 0) = 1                          THEN '2. 목록·검색까지만 도달'
               ELSE '1. 상품 탐색 화면 미도달'
               END AS depth_stage
    FROM  BASE AS b
    LEFT
    JOIN  FIRST_DETAIL AS fd
      ON  b.user_pseudo_id = fd.user_pseudo_id
    LEFT
    JOIN  PRIOR_BROWSE AS pb
      ON  b.user_pseudo_id = pb.user_pseudo_id
    LEFT
    JOIN  SCREENS AS s
      ON  b.user_pseudo_id = s.user_pseudo_id
),

AGG AS (
  SELECT  depth_stage,
          COUNT(*)                 AS users,
          SUM(target_purchase_d7)  AS purchasers,
          SUM(target_return_d1_d7) AS returners
    FROM  USERS
   GROUP
      BY  depth_stage
)

SELECT  depth_stage,
        users,
        ROUND(users / SUM(users) OVER () * 100, 2)            AS user_share_pct,
        purchasers,
        ROUND(purchasers / users * 100, 2)                    AS purchase_rate_pct,
        ROUND(purchasers / SUM(purchasers) OVER () * 100, 2)  AS purchaser_coverage_pct,
        ROUND(returners / users * 100, 2)                     AS return_rate_pct
  FROM  AGG
 ORDER
    BY  depth_stage;


-- STEP 4. 랜딩 페이지 유형별 상세 도달률 · 미도달 규모
-- 질문 : 어떤 화면으로 들어온 사용자가 상품 상세까지 못 가는가?
-- 상세 도달 = 첫 세션 상품 상세 페이지 page_view 1회 이상 (view_item 아님)

WITH BASE AS (
  SELECT  user_pseudo_id,
          target_purchase_d7,
          target_return_d1_d7
    FROM  `your-project-id.ga4_portfolio.modeling_mart`
   WHERE  first_session_purchase_flag = 0
),
 
PV AS (
  SELECT  f.user_pseudo_id,
          f.event_timestamp,
          f.page,
          d.page_type
    FROM  `your-project-id.ga4_portfolio.fs_page_events` AS f
    LEFT
    JOIN  `your-project-id.ga4_portfolio.page_type_dict` AS d
      ON  f.page = d.page
   WHERE  f.event_name = 'page_view'
),
 
LANDING AS (
  SELECT  user_pseudo_id,
          ARRAY_AGG(COALESCE(page_type, '기타') ORDER BY event_timestamp LIMIT 1)[SAFE_OFFSET(0)] AS landing_type,
          COUNT(*)                                                                         AS page_views,
          MAX(IF(page_type = '상품 상세', 1, 0))                                            AS reached_detail
    FROM  PV
   GROUP
      BY  user_pseudo_id
),
 
USERS AS (
  SELECT  b.*,
          COALESCE(l.landing_type, '페이지 정보 없음') AS landing_type,
          COALESCE(l.page_views, 0)                    AS page_views,
          COALESCE(l.reached_detail, 0)                AS reached_detail
    FROM  BASE AS b
    LEFT
    JOIN  LANDING AS l
      ON  b.user_pseudo_id = l.user_pseudo_id
)
 
SELECT  landing_type,
        COUNT(*)                                                               AS users,
        ROUND(COUNT(*) / SUM(COUNT(*)) OVER () * 100, 2)                       AS user_share_pct,
        ROUND(AVG(IF(page_views <= 1, 1, 0)) * 100, 2)                         AS single_page_pct,      -- 1페이지 이탈
        ROUND(AVG(reached_detail) * 100, 2)                                    AS detail_reach_pct,     -- 상세 도달률
        COUNTIF(reached_detail = 0)                                            AS non_reachers,
        ROUND(COUNTIF(reached_detail = 0)
              / SUM(COUNTIF(reached_detail = 0)) OVER () * 100, 2)             AS non_reacher_share_pct, -- 전체 미도달자 중 비중
        SUM(target_purchase_d7)                                                AS purchasers,
        ROUND(AVG(target_purchase_d7) * 100, 3)                                AS purchase_rate_pct,
        ROUND(SAFE_DIVIDE(COUNTIF(reached_detail = 1 AND target_purchase_d7 = 1),
                          COUNTIF(reached_detail = 1)) * 100, 3)               AS cvr_reached_pct,
        ROUND(SAFE_DIVIDE(COUNTIF(reached_detail = 0 AND target_purchase_d7 = 1),
                          COUNTIF(reached_detail = 0)) * 100, 3)               AS cvr_not_reached_pct,
        ROUND(AVG(target_return_d1_d7) * 100, 2)                               AS return_rate_pct
  FROM  USERS
 GROUP
    BY  landing_type
 ORDER
    BY  users DESC;

-- STEP 5. 상세 도달자의 출발 화면
-- 질문 : 상품 상세 도달은 현재 어떤 화면에서 주로 일어나는가?
-- 첫 상품 상세 page_view 직전의 마지막 비(非)상세 page_view = 출발 화면
-- 직전 비상세 페이지가 없으면 '상세 직접 랜딩'

WITH BASE AS (
  SELECT  user_pseudo_id,
          target_purchase_d7,
          target_return_d1_d7
    FROM  `your-project-id.ga4_portfolio.modeling_mart`
   WHERE  first_session_purchase_flag = 0
),
 
PV AS (
  SELECT  f.user_pseudo_id,
          f.event_timestamp,
          COALESCE(d.page_type, '기타') AS page_type
    FROM  `your-project-id.ga4_portfolio.fs_page_events` AS f
    LEFT
    JOIN  `your-project-id.ga4_portfolio.page_type_dict` AS d
      ON  f.page = d.page
   WHERE  f.event_name = 'page_view'
),
 
FIRST_DETAIL AS (
  SELECT  user_pseudo_id,
          MIN(event_timestamp) AS first_detail_ts
    FROM  PV
   WHERE  page_type = '상품 상세'
   GROUP
      BY  user_pseudo_id
),
 
SOURCE AS (
  SELECT  f.user_pseudo_id,
          ARRAY_AGG(p.page_type ORDER BY p.event_timestamp DESC LIMIT 1)[SAFE_OFFSET(0)] AS source_type
    FROM  FIRST_DETAIL AS f
    JOIN  PV AS p
      ON  f.user_pseudo_id = p.user_pseudo_id
     AND  p.event_timestamp < f.first_detail_ts
     AND  p.page_type != '상품 상세'
   GROUP
      BY  f.user_pseudo_id
),
 
REACHERS AS (
  SELECT  b.*,
          COALESCE(s.source_type, '상세 직접 랜딩') AS source_type
    FROM  FIRST_DETAIL AS f
    JOIN  BASE AS b
      ON  f.user_pseudo_id = b.user_pseudo_id
    LEFT
    JOIN  SOURCE AS s
      ON  f.user_pseudo_id = s.user_pseudo_id
)
 
SELECT  source_type,
        COUNT(*)                                          AS reachers,
        ROUND(COUNT(*) / SUM(COUNT(*)) OVER () * 100, 2)  AS reacher_share_pct,
        SUM(target_purchase_d7)                           AS purchasers,
        ROUND(AVG(target_purchase_d7) * 100, 3)           AS purchase_rate_pct,
        ROUND(AVG(target_return_d1_d7) * 100, 2)          AS return_rate_pct
  FROM  REACHERS
 GROUP
    BY  source_type
 ORDER
    BY  reachers DESC;


-- STEP 6-1. 화면별 방문자 기준 상세 도달률 (사용자 단위)
-- 결과: 카테고리·목록 방문율 56.0% · 상세 도달률 13.9%
--       메인 46.7% · 11.8% / 검색 결과 4.6% · 29.1%
-- 질문 : 각 화면을 방문한 사용자 중 몇 %가 그 이후 상품 상세에 도달했는가?
-- 방문자   : 첫 세션에 해당 유형 page_view가 1회 이상 있는 사용자
-- 이후 도달 : 해당 화면 첫 방문 시각 이후 상품 상세 page_view 발생
-- ※ 한 사용자가 여러 화면을 방문하면 각 화면에 모두 집계됨 (화면 간 합계 ≠ 전체)

WITH BASE AS (
  SELECT  user_pseudo_id,
          target_purchase_d7,
          target_return_d1_d7
    FROM  `your-project-id.ga4_portfolio.modeling_mart`
   WHERE  first_session_purchase_flag = 0
),
 
PV AS (
  SELECT  f.user_pseudo_id,
          f.event_timestamp,
          COALESCE(d.page_type, '기타') AS page_type
    FROM  `your-project-id.ga4_portfolio.fs_page_events` AS f
    LEFT
    JOIN  `your-project-id.ga4_portfolio.page_type_dict` AS d
      ON  f.page = d.page
   WHERE  f.event_name = 'page_view'
),
 
SCREEN_VISIT AS (
  SELECT  user_pseudo_id,
          page_type,
          MIN(event_timestamp) AS first_visit_ts
    FROM  PV
   WHERE  page_type != '상품 상세'
   GROUP
      BY  user_pseudo_id,
          page_type
),
 
LAST_DETAIL AS (
  SELECT  user_pseudo_id,
          MAX(event_timestamp) AS last_detail_ts
    FROM  PV
   WHERE  page_type = '상품 상세'
   GROUP
      BY  user_pseudo_id
),
 
VISITORS AS (
  SELECT  v.page_type AS screen,
          v.user_pseudo_id,
          IF(l.last_detail_ts > v.first_visit_ts, 1, 0) AS reached_after,
          b.target_purchase_d7,
          b.target_return_d1_d7
    FROM  SCREEN_VISIT AS v
    JOIN  BASE AS b
      ON  v.user_pseudo_id = b.user_pseudo_id
    LEFT
    JOIN  LAST_DETAIL AS l
      ON  v.user_pseudo_id = l.user_pseudo_id
)
 
SELECT  screen,
        COUNT(*)                                                             AS visitors,
        ROUND(COUNT(*) / (SELECT COUNT(*) FROM BASE) * 100, 2)               AS visitor_share_pct,   -- 전체 신규 사용자 중 방문 비율
        SUM(reached_after)                                                   AS reachers,
        ROUND(AVG(reached_after) * 100, 2)                                   AS detail_reach_pct,    -- 방문자 기준 상세 도달률
        COUNT(*) - SUM(reached_after)                                        AS non_reachers,
        ROUND(SAFE_DIVIDE(COUNTIF(reached_after = 1 AND target_purchase_d7 = 1),
                          COUNTIF(reached_after = 1)) * 100, 3)              AS cvr_reached_pct,
        ROUND(SAFE_DIVIDE(COUNTIF(reached_after = 0 AND target_purchase_d7 = 1),
                          COUNTIF(reached_after = 0)) * 100, 3)              AS cvr_not_reached_pct,
        ROUND(SAFE_DIVIDE(COUNTIF(reached_after = 1 AND target_return_d1_d7 = 1),
                          COUNTIF(reached_after = 1)) * 100, 2)              AS return_reached_pct,
        ROUND(SAFE_DIVIDE(COUNTIF(reached_after = 0 AND target_return_d1_d7 = 1),
                          COUNTIF(reached_after = 0)) * 100, 2)              AS return_not_reached_pct
  FROM  VISITORS
 GROUP
    BY  screen
 ORDER
    BY  visitors DESC;


-- STEP 6-2. 화면별 다음 페이지 이동 (페이지뷰 단위)
-- 결과: 목록 페이지뷰 → 다른 목록 48.4% / 이탈 31.3% / 상품 상세 9.7% / 기타 10.6%
--       → 목록 페이지뷰의 79.7%가 다른 목록으로 이동하거나 이탈
-- 질문 : 각 화면을 본 직후 바로 상세로 가는 비율은? 바로 이탈하는 비율은?
-- to_detail_pct : 다음 page_view가 상품 상세인 비율 (화면 → 상세 클릭률에 해당)
-- exit_pct      : 다음 page_view가 없는 비율 (첫 세션 종료 = 이탈)

WITH PV AS (
  SELECT  f.user_pseudo_id,
          f.event_timestamp,
          COALESCE(d.page_type, '기타') AS page_type
    FROM  `your-project-id.ga4_portfolio.fs_page_events` AS f
    LEFT
    JOIN  `your-project-id.ga4_portfolio.page_type_dict` AS d
      ON  f.page = d.page
   WHERE  f.event_name = 'page_view'
),
 
SEQ AS (
  SELECT  page_type,
          LEAD(page_type) OVER (PARTITION BY user_pseudo_id ORDER BY event_timestamp) AS next_type
    FROM  PV
)
 
SELECT  page_type                                                  AS screen,
        COUNT(*)                                                   AS page_views,
        ROUND(COUNTIF(next_type = '상품 상세')     / COUNT(*) * 100, 2) AS to_detail_pct,
        ROUND(COUNTIF(next_type = '카테고리·목록') / COUNT(*) * 100, 2) AS to_list_pct,
        ROUND(COUNTIF(next_type = '메인')          / COUNT(*) * 100, 2) AS to_main_pct,
        ROUND(COUNTIF(next_type IS NULL)           / COUNT(*) * 100, 2) AS exit_pct
  FROM  SEQ
 GROUP
    BY  screen
 ORDER
    BY  page_views DESC;

-- STEP 6-3. 카테고리·목록 페이지별 상세 이동률 (개선 대상 목록 우선순위)
-- 결과: 방문량 상위 3개 목록이 목록 페이지뷰의 39.5% → A/B 테스트 우선 적용 대상
-- 첫 세션 page_view 500회 이상 목록 페이지만

WITH PV AS (
  SELECT  f.user_pseudo_id,
          f.event_timestamp,
          f.page,
          COALESCE(d.page_type, '기타') AS page_type
    FROM  `your-project-id.ga4_portfolio.fs_page_events` AS f
    LEFT
    JOIN  `your-project-id.ga4_portfolio.page_type_dict` AS d
      ON  f.page = d.page
   WHERE  f.event_name = 'page_view'
),
 
SEQ AS (
  SELECT  page,
          page_type,
          LEAD(page_type) OVER (PARTITION BY user_pseudo_id ORDER BY event_timestamp) AS next_type
    FROM  PV
)
 
SELECT  REGEXP_REPLACE(page, r'^https?://[^/]+', '')               AS list_page,
        COUNT(*)                                                   AS page_views,
        ROUND(COUNT(*) / SUM(COUNT(*)) OVER () * 100, 2)           AS pv_share_pct,
        ROUND(COUNTIF(next_type = '상품 상세') / COUNT(*) * 100, 2) AS to_detail_pct,
        ROUND(COUNTIF(next_type IS NULL)       / COUNT(*) * 100, 2) AS exit_pct
  FROM  SEQ
 WHERE  page_type = '카테고리·목록'
 GROUP
    BY  list_page
HAVING  COUNT(*) >= 500
 ORDER
    BY  page_views DESC;


-- STEP 7. 목록 방문자 퍼널 : 목록 방문 → 상품 노출 → 상품 선택 → 상세 도달
-- 대상 : 첫 세션에 카테고리·목록 page_view가 1회 이상인 사용자
-- 각 단계는 '첫 목록 방문 시각 이후' 발생한 이벤트로 판정
--   상품 노출 : 목록 페이지에서 view_item 발생 (상품 목록이 로드되어 보임)
--   상품 선택 : select_item 발생 (목록·검색 등에서 상품 클릭)
--   상세 도달 : 상품 상세 page_view 발생

-- STEP 7-0. 사용자별 퍼널 플래그 테이블
CREATE OR REPLACE TABLE `your-project-id.ga4_portfolio.list_funnel_users`
OPTIONS (
  expiration_timestamp = TIMESTAMP_ADD(CURRENT_TIMESTAMP(), INTERVAL 30 DAY)
) AS
 
WITH BASE AS (
  SELECT  m.user_pseudo_id,
          u.first_ga_session_id,
          m.target_purchase_d7,
          m.target_return_d1_d7
    FROM  `your-project-id.ga4_portfolio.modeling_mart` AS m
    JOIN  `your-project-id.ga4_portfolio.user_mart` AS u
      ON  m.user_pseudo_id = u.user_pseudo_id
   WHERE  m.first_session_purchase_flag = 0
),
 
FS AS (
  SELECT  b.user_pseudo_id,
          e.event_name,
          e.event_timestamp,
          REGEXP_REPLACE(LOWER(REGEXP_REPLACE((
            SELECT  ep.value.string_value
              FROM  UNNEST(e.event_params) AS ep
             WHERE  ep.key = 'page_location'
          ), r'[?#].*$', '')), r'/+$', '') AS page
    FROM  `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*` AS e
    JOIN  BASE AS b
      ON  e.user_pseudo_id = b.user_pseudo_id
   WHERE  e.event_name IN ('page_view', 'view_item', 'select_item')
     AND  (
            SELECT  ep.value.int_value
              FROM  UNNEST(e.event_params) AS ep
             WHERE  ep.key = 'ga_session_id'
          ) = b.first_ga_session_id
),
 
TYPED AS (
  SELECT  f.*,
          COALESCE(d.page_type, '기타') AS page_type
    FROM  FS AS f
    LEFT
    JOIN  `your-project-id.ga4_portfolio.page_type_dict` AS d
      ON  f.page = d.page
),
 
FIRST_LIST AS (
  SELECT  user_pseudo_id,
          MIN(event_timestamp) AS first_list_ts
    FROM  TYPED
   WHERE  event_name = 'page_view'
     AND  page_type = '카테고리·목록'
   GROUP
      BY  user_pseudo_id
),
 
FLAGS AS (
  SELECT  l.user_pseudo_id,
          MAX(IF(t.event_name = 'view_item'   AND t.page_type = '카테고리·목록'
                 AND t.event_timestamp >= l.first_list_ts, 1, 0))                  AS saw_items,
          MAX(IF(t.event_name = 'select_item'
                 AND t.event_timestamp >= l.first_list_ts, 1, 0))                  AS selected_item,
          MAX(IF(t.event_name = 'page_view'   AND t.page_type = '상품 상세'
                 AND t.event_timestamp >  l.first_list_ts, 1, 0))                  AS reached_detail,
          COUNTIF(t.event_name = 'page_view'  AND t.page_type = '카테고리·목록')   AS list_pv
    FROM  FIRST_LIST AS l
    JOIN  TYPED AS t
      ON  l.user_pseudo_id = t.user_pseudo_id
   GROUP
      BY  l.user_pseudo_id
)
 
SELECT  f.*,
        b.target_purchase_d7,
        b.target_return_d1_d7,
        CASE WHEN f.reached_detail = 1 THEN '4. 상세 도달'
             WHEN f.selected_item  = 1 THEN '3. 상품 선택 후 상세 미도달'
             WHEN f.saw_items      = 1 THEN '2. 상품 노출 후 미선택'
             ELSE '1. 상품 노출 없음'
             END AS funnel_stage
  FROM  FLAGS AS f
  JOIN  BASE AS b
    ON  f.user_pseudo_id = b.user_pseudo_id;
 
 
-- STEP 7-1. 퍼널 단계별 통과율 (누적 · 직전 단계 대비)
-- 결과: 목록 방문자 132,557명 중 상세 도달률 13.89% → 개선 KPI 기준값

WITH T AS (
  SELECT  COUNT(*)                                                          AS s1_list_visit,
          COUNTIF(saw_items = 1)                                            AS s2_saw_items,
          COUNTIF(saw_items = 1 AND selected_item = 1)                      AS s3_selected,
          COUNTIF(saw_items = 1 AND selected_item = 1 AND reached_detail = 1) AS s4_detail,
          COUNTIF(reached_detail = 1)                                       AS any_detail,
          COUNTIF(reached_detail = 1 AND selected_item = 0)                 AS detail_without_select
    FROM  `your-project-id.ga4_portfolio.list_funnel_users`
)
 
SELECT  s1_list_visit,
        s2_saw_items,
        ROUND(s2_saw_items / s1_list_visit * 100, 2)  AS s2_rate_pct,          -- 목록 방문 → 상품 노출
        s3_selected,
        ROUND(s3_selected  / s2_saw_items  * 100, 2)  AS s3_step_rate_pct,     -- 상품 노출 → 상품 선택
        s4_detail,
        ROUND(s4_detail    / s3_selected   * 100, 2)  AS s4_step_rate_pct,     -- 상품 선택 → 상세 도달
        any_detail,
        ROUND(any_detail   / s1_list_visit * 100, 2)  AS list_to_detail_pct,   -- 목록 방문자 기준 상세 도달률
        detail_without_select,
        ROUND(detail_without_select / any_detail * 100, 2) AS detail_without_select_pct  -- select_item 수집 누락 점검
  FROM  T;

-- STEP 7-2. 퍼널 단계별 D7 구매율 · 재방문율 (구매 KPI 연결)
-- 단계는 서로 겹치지 않음 (가장 깊이 도달한 단계 기준)
WITH TOTAL AS (
  SELECT  SUM(target_purchase_d7) AS all_purchasers          -- 분석 대상 전체 D7 구매자 (1,122명)
    FROM  `your-project-id.ga4_portfolio.modeling_mart`
   WHERE  first_session_purchase_flag = 0
),
 
AGG AS (
  SELECT  funnel_stage,
          COUNT(*)                 AS users,
          SUM(target_purchase_d7)  AS purchasers,
          SUM(target_return_d1_d7) AS returners
    FROM  `your-project-id.ga4_portfolio.list_funnel_users`
   GROUP
      BY  funnel_stage
)
 
SELECT  a.funnel_stage,
        a.users,
        ROUND(a.users / SUM(a.users) OVER () * 100, 2)                  AS share_of_list_visitors_pct,
        a.purchasers,
        ROUND(a.purchasers / a.users * 100, 3)                          AS purchase_rate_pct,
        ROUND(a.purchasers / t.all_purchasers * 100, 2)                 AS coverage_of_all_purchasers_pct,
        ROUND(SAFE_DIVIDE(a.purchasers / a.users,
              MAX(IF(a.funnel_stage = '2. 상품 노출 후 미선택', a.purchasers / a.users, NULL)) OVER ()), 1)
                                                                        AS purchase_lift_vs_stage2,
        ROUND(a.returners / a.users * 100, 2)                           AS return_rate_pct
  FROM  AGG AS a
 CROSS
  JOIN  TOTAL AS t
 ORDER
    BY  a.funnel_stage;

-- STEP 7-3. 목록 방문자의 상세 도달 여부별 D7 구매율
WITH TOTAL AS (
  SELECT  SUM(target_purchase_d7) AS all_purchasers
    FROM  `your-project-id.ga4_portfolio.modeling_mart`
   WHERE  first_session_purchase_flag = 0
),
 
AGG AS (
  SELECT  IF(reached_detail = 1, '상세 도달', '상세 미도달') AS detail_group,
          COUNT(*)                 AS users,
          SUM(target_purchase_d7)  AS purchasers,
          SUM(target_return_d1_d7) AS returners
    FROM  `your-project-id.ga4_portfolio.list_funnel_users`
   GROUP
      BY  detail_group
)
 
SELECT  a.detail_group,
        a.users,
        ROUND(a.users / SUM(a.users) OVER () * 100, 2)                  AS share_of_list_visitors_pct,
        a.purchasers,
        ROUND(a.purchasers / a.users * 100, 3)                          AS purchase_rate_pct,
        ROUND(a.purchasers / t.all_purchasers * 100, 2)                 AS coverage_of_all_purchasers_pct,
        ROUND(SAFE_DIVIDE(a.purchasers / a.users,
              MAX(IF(a.detail_group = '상세 미도달', a.purchasers / a.users, NULL)) OVER ()), 1)
                                                                        AS purchase_lift,
        ROUND(a.returners / a.users * 100, 2)                           AS return_rate_pct
  FROM  AGG AS a
 CROSS
  JOIN  TOTAL AS t
 ORDER
    BY  a.detail_group;