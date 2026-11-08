-- =============================================================================
-- 05_trades_and_costs.sql
-- LOBSTER records one execution message per resting order hit, so a single
-- marketable order that sweeps several orders shows up as several consecutive
-- fills with the same timestamp and sign. We stitch them back into trades.
--
-- Transaction-cost measures (per trade, in basis points of the pre-trade mid):
--   effective spread  = 2 * sign * (vwap - mid_pre)       / mid_pre
--   realized spread   = 2 * sign * (vwap - mid_{t+5s})     / mid_pre
--   price impact(h)   =     sign * (mid_{t+h} - mid_pre)   / mid_pre
-- with  effective spread = realized spread + 2 * impact(5s):  what liquidity
-- providers earn vs. what they lose to informed flow (adverse selection).
-- mid_{t+h} is the last quote at or before (trade time + h), so each horizon is
-- exactly h after the trade. Horizons that run past the last quote are NULL.
--
-- Hidden executions (type 5) are tracked per trade. LOBSTER reports their
-- direction, but many execute at the mid, where the price can't confirm it, so
-- costs are also reported separately for visible-only trades.
-- =============================================================================

DROP TABLE IF EXISTS trades;
CREATE TABLE trades AS
WITH f AS (
    SELECT event_id, time, t_ms, type, size, price, sign,
           LAG(event_id) OVER (ORDER BY event_id) AS prev_event,
           LAG(time)     OVER (ORDER BY event_id) AS prev_time,
           LAG(sign)     OVER (ORDER BY event_id) AS prev_sign
    FROM fills
),
g AS (
    SELECT *,
           SUM(CASE WHEN prev_event = event_id - 1
                     AND prev_time = time
                     AND prev_sign = sign THEN 0 ELSE 1 END)
               OVER (ORDER BY event_id ROWS UNBOUNDED PRECEDING) AS trade_id
    FROM f
)
SELECT trade_id,
       MIN(event_id) AS first_event,
       MAX(event_id) AS last_event,
       MIN(t_ms) AS t_ms,
       MAX(sign) AS sign,
       SUM(size) AS size,
       SUM(price * size) / SUM(size) AS vwap,
       MIN(price) AS min_price,
       MAX(price) AS max_price,
       COUNT(*) AS n_fills,
       SUM(CASE WHEN type = 5 THEN 1 ELSE 0 END) AS n_hidden_fills
FROM g
GROUP BY trade_id;

CREATE INDEX IF NOT EXISTS idx_trades_id ON trades(trade_id);

-- The quote in force at each horizon after each trade: the last book state at
-- or before (trade time + h). Done in one sorted pass instead of a lookup per
-- trade: merge the target times into the stream of book states, and carry the
-- latest event_id forward. event_id grows with time, so a running MAX works,
-- and book states sort before targets at the same millisecond (at or before).
DROP TABLE IF EXISTS trade_horizons;
CREATE TABLE trade_horizons AS
WITH hz(h) AS (
    VALUES (1000), (5000), (30000), (60000)
),
stream AS (
    SELECT t_ms AS ts, 0 AS kind, event_id,
           CAST(NULL AS INTEGER) AS trade_id, CAST(NULL AS INTEGER) AS h
    FROM tob
    UNION ALL
    SELECT tr.t_ms + hz.h, 1, CAST(NULL AS INTEGER), tr.trade_id, hz.h
    FROM trades tr
    CROSS JOIN hz
),
filled AS (
    SELECT kind, trade_id, h,
           MAX(event_id) OVER (ORDER BY ts, kind ROWS UNBOUNDED PRECEDING) AS ev
    FROM stream
)
SELECT trade_id,
       MAX(CASE WHEN h = 1000  THEN ev END) AS ev_1s,
       MAX(CASE WHEN h = 5000  THEN ev END) AS ev_5s,
       MAX(CASE WHEN h = 30000 THEN ev END) AS ev_30s,
       MAX(CASE WHEN h = 60000 THEN ev END) AS ev_60s
FROM filled
WHERE kind = 1
GROUP BY trade_id;

CREATE INDEX IF NOT EXISTS idx_trade_horizons_id ON trade_horizons(trade_id);

DROP TABLE IF EXISTS trade_costs;
CREATE TABLE trade_costs AS
WITH last_quote AS (
    SELECT MAX(t_ms) AS last_ms FROM tob
),
anchors AS (
    SELECT t.*,
           (SELECT MAX(q.event_id) FROM tob q WHERE q.event_id < t.first_event) AS pre_event,
           (SELECT MIN(q.event_id) FROM tob q WHERE q.event_id >= t.last_event) AS post_event,
           h.ev_1s, h.ev_5s, h.ev_30s, h.ev_60s,
           l.last_ms
    FROM trades t
    JOIN trade_horizons h ON h.trade_id = t.trade_id
    CROSS JOIN last_quote l
),
q AS (
    SELECT a.trade_id, a.t_ms, a.sign, a.size, a.vwap, a.n_fills, a.n_hidden_fills,
           CASE WHEN a.n_hidden_fills = 0 THEN 'visible only'
                WHEN a.n_hidden_fills = a.n_fills THEN 'hidden only'
                ELSE 'mixed' END AS liquidity,
           a.last_ms, a.ev_1s, a.ev_5s, a.ev_30s, a.ev_60s,
           pre.bid AS pre_bid, pre.ask AS pre_ask, pre.mid AS pre_mid,
           pre.spread AS pre_spread,
           CASE WHEN a.sign = 1 THEN pre.ask_size ELSE pre.bid_size END AS pre_touch_size,
           post.mid AS post_mid
    FROM anchors a
    JOIN tob pre       ON pre.event_id = a.pre_event
    LEFT JOIN tob post ON post.event_id = a.post_event
)
SELECT q.trade_id, q.t_ms, q.sign, q.size, q.vwap, q.n_fills, q.n_hidden_fills,
       q.liquidity, q.pre_bid, q.pre_ask, q.pre_mid, q.pre_spread,
       q.pre_touch_size, q.post_mid,
       q.size * 1.0 / NULLIF(q.pre_touch_size, 0) AS size_to_touch,
       CASE WHEN q.n_fills > 0 AND (q.vwap > q.pre_ask OR q.vwap < q.pre_bid)
            THEN 1 ELSE 0 END AS walked_book,
       20000.0 * q.sign * (q.vwap - q.pre_mid) / q.pre_mid      AS eff_spread_bps,
       20000.0 * q.sign * (q.vwap - g5.mid)    / q.pre_mid      AS real_spread_5s_bps,
       10000.0 * q.sign * (q.post_mid - q.pre_mid) / q.pre_mid  AS impact_0_bps,
       10000.0 * q.sign * (g1.mid  - q.pre_mid) / q.pre_mid     AS impact_1s_bps,
       10000.0 * q.sign * (g5.mid  - q.pre_mid) / q.pre_mid     AS impact_5s_bps,
       10000.0 * q.sign * (g30.mid - q.pre_mid) / q.pre_mid     AS impact_30s_bps,
       10000.0 * q.sign * (g60.mid - q.pre_mid) / q.pre_mid     AS impact_60s_bps
FROM q
LEFT JOIN tob g1  ON g1.event_id  = q.ev_1s  AND q.t_ms + 1000  <= q.last_ms
LEFT JOIN tob g5  ON g5.event_id  = q.ev_5s  AND q.t_ms + 5000  <= q.last_ms
LEFT JOIN tob g30 ON g30.event_id = q.ev_30s AND q.t_ms + 30000 <= q.last_ms
LEFT JOIN tob g60 ON g60.event_id = q.ev_60s AND q.t_ms + 60000 <= q.last_ms;

-- Costs split by whether a trade hit hidden orders.
DROP TABLE IF EXISTS costs_by_liquidity;
CREATE TABLE costs_by_liquidity AS
SELECT liquidity,
       COUNT(*) AS n_trades,
       AVG(eff_spread_bps) AS eff_spread_bps,
       AVG(real_spread_5s_bps) AS real_spread_5s_bps,
       AVG(impact_5s_bps) AS impact_5s_bps
FROM trade_costs
GROUP BY liquidity
ORDER BY liquidity;

-- Average impact path by trade-size bucket (the "impact curve").
-- Fixed buckets, not deciles: real trade sizes pile up on round lots (often
-- a large share of all trades is exactly 100 shares), and equal-count deciles
-- would split one size across several "deciles" with identical sizes.
DROP TABLE IF EXISTS impact_by_size;
CREATE TABLE impact_by_size AS
WITH d AS (
    SELECT *,
           CASE WHEN size < 100  THEN 1
                WHEN size = 100  THEN 2
                WHEN size < 200  THEN 3
                WHEN size < 300  THEN 4
                WHEN size < 500  THEN 5
                WHEN size < 1000 THEN 6
                WHEN size < 2000 THEN 7
                ELSE 8 END AS size_bucket,
           CASE WHEN size < 100  THEN '1-99'
                WHEN size = 100  THEN '100'
                WHEN size < 200  THEN '101-199'
                WHEN size < 300  THEN '200-299'
                WHEN size < 500  THEN '300-499'
                WHEN size < 1000 THEN '500-999'
                WHEN size < 2000 THEN '1000-1999'
                ELSE '2000+' END AS size_label
    FROM trade_costs
)
SELECT size_bucket,
       size_label,
       COUNT(*) AS n_trades,
       AVG(size) AS avg_size,
       AVG(size_to_touch) AS avg_size_to_touch,
       AVG(walked_book * 1.0) AS frac_walked_book,
       AVG(eff_spread_bps) AS eff_spread_bps,
       AVG(real_spread_5s_bps) AS real_spread_5s_bps,
       AVG(impact_0_bps) AS impact_0_bps,
       AVG(impact_1s_bps) AS impact_1s_bps,
       AVG(impact_5s_bps) AS impact_5s_bps,
       AVG(impact_30s_bps) AS impact_30s_bps,
       AVG(impact_60s_bps) AS impact_60s_bps
FROM d
GROUP BY size_bucket, size_label
ORDER BY size_bucket;

-- Roll (1984) implied spread: bid-ask bounce makes consecutive trade-price
-- changes negatively autocorrelated; spread = 2 * sqrt(-cov(dp_t, dp_{t-1})).
-- (sqrt is taken in R to stay engine-neutral.)
DROP TABLE IF EXISTS roll_autocov;
CREATE TABLE roll_autocov AS
WITH d AS (
    SELECT trade_id, vwap - LAG(vwap) OVER (ORDER BY trade_id) AS dp
    FROM trades
),
d2 AS (
    SELECT dp, LAG(dp) OVER (ORDER BY trade_id) AS dp_lag
    FROM d
)
SELECT COUNT(*) AS n_pairs,
       AVG(dp * dp_lag) - AVG(dp) * AVG(dp_lag) AS autocov
FROM d2
WHERE dp IS NOT NULL AND dp_lag IS NOT NULL;
