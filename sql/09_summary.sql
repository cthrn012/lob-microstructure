-- =============================================================================
-- 09_summary.sql
-- One tidy (metric, value) table of headline numbers for the README / report.
-- =============================================================================

-- Time spent at each spread. Each book state lasts until the next update, so
-- quiet periods count for their full length. A plain average over rows would
-- count updates instead, which over-weights bursts of activity.
DROP TABLE IF EXISTS spread_time;
CREATE TABLE spread_time AS
WITH x AS (
    SELECT spread,
           LEAD(t_ms) OVER (ORDER BY event_id) - t_ms AS dt_ms
    FROM tob
)
SELECT ROUND(spread * 100) AS spread_ticks,
       COUNT(*) AS n_updates,
       SUM(dt_ms) AS ms,
       SUM(spread * dt_ms) AS spread_ms
FROM x
WHERE dt_ms IS NOT NULL
GROUP BY ROUND(spread * 100)
ORDER BY spread_ticks;

DROP TABLE IF EXISTS summary;
CREATE TABLE summary AS
SELECT 'messages' AS metric, COUNT(*) * 1.0 AS value FROM messages
UNION ALL SELECT 'limit order submissions', SUM(CASE WHEN type = 1 THEN 1.0 ELSE 0 END) FROM messages
UNION ALL SELECT 'cancellations (full + partial)', SUM(CASE WHEN type IN (2, 3) THEN 1.0 ELSE 0 END) FROM messages
UNION ALL SELECT 'executions (fills)', COUNT(*) * 1.0 FROM fills
UNION ALL SELECT 'trades (stitched)', COUNT(*) * 1.0 FROM trades
UNION ALL SELECT 'share volume', SUM(size) * 1.0 FROM trades
UNION ALL SELECT 'cancel-to-trade ratio',
    (SELECT SUM(CASE WHEN type IN (2, 3) THEN 1.0 ELSE 0 END) FROM messages)
    / NULLIF((SELECT COUNT(*) FROM trades), 0)
UNION ALL SELECT 'avg quoted spread, time-weighted ($)', SUM(spread_ms) * 1.0 / NULLIF(SUM(ms), 0) FROM spread_time
UNION ALL SELECT 'avg quoted spread per book update ($)', AVG(spread) FROM tob
UNION ALL SELECT 'share of time at 1-tick spread',
    SUM(CASE WHEN spread_ticks = 1 THEN ms ELSE 0 END) * 1.0 / NULLIF(SUM(ms), 0) FROM spread_time
UNION ALL SELECT 'share of book updates at 1-tick spread',
    SUM(CASE WHEN spread_ticks = 1 THEN n_updates ELSE 0 END) * 1.0 / NULLIF(SUM(n_updates), 0) FROM spread_time
UNION ALL SELECT 'avg effective spread (bps)', AVG(eff_spread_bps) FROM trade_costs
UNION ALL SELECT 'avg effective spread, visible-only trades (bps)', AVG(eff_spread_bps)
    FROM trade_costs WHERE liquidity = 'visible only'
UNION ALL SELECT 'avg effective spread, trades with hidden fills (bps)', AVG(eff_spread_bps)
    FROM trade_costs WHERE liquidity <> 'visible only'
UNION ALL SELECT 'share of fills against hidden orders', AVG(CASE WHEN type = 5 THEN 1.0 ELSE 0.0 END) FROM fills
UNION ALL SELECT 'share of hidden fills at the pre-trade mid',
    AVG(CASE WHEN f.price = (SELECT t.mid FROM tob t
                             WHERE t.event_id = (SELECT MAX(q.event_id) FROM tob q
                                                 WHERE q.event_id < f.event_id))
             THEN 1.0 ELSE 0.0 END)
    FROM fills f WHERE f.type = 5
UNION ALL SELECT 'avg realized spread 5s (bps)', AVG(real_spread_5s_bps) FROM trade_costs
UNION ALL SELECT 'avg price impact 5s (bps)', AVG(impact_5s_bps) FROM trade_costs
UNION ALL SELECT 'share of trades walking the book', AVG(walked_book * 1.0) FROM trade_costs
UNION ALL SELECT 'roll autocovariance', autocov FROM roll_autocov;
