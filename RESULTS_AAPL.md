# Results

Data: the LOBSTER file pair `AAPL_2012-06-21_34200000_57600000` (real Nasdaq data).

| Metric | Value |
|---|---|
| messages | 301,587 |
| limit order submissions | 143,822 |
| cancellations (full + partial) | 122,775 |
| executions (fills) | 34,990 |
| trades (stitched) | 24,862 |
| share volume | 2,850,140 |
| cancel-to-trade ratio | 4.938 |
| avg quoted spread, time-weighted ($) | 0.1513 |
| avg quoted spread per book update ($) | 0.1565 |
| share of time at 1-tick spread | 0.001331 |
| share of book updates at 1-tick spread | 0.005282 |
| avg effective spread (bps) | 1.544 |
| avg effective spread, visible-only trades (bps) | 1.697 |
| avg effective spread, trades with hidden fills (bps) | 1.305 |
| share of fills against hidden orders | 0.3239 |
| share of hidden fills at the pre-trade mid | 0.03433 |
| avg realized spread 5s (bps) | 0.03029 |
| avg price impact 5s (bps) | 0.757 |
| share of trades walking the book | 0.03403 |
| roll autocovariance | -0.0001651 |

## Key findings

- **Order flow imbalance:** 10s OFI (scaled by L1 depth) explains **R² = 0.501** of mid-price changes (n = 2339 buckets, t = 48.4).
- **Queue imbalance:** measured once per mid move (n = 55,421), the sign of L1 imbalance calls the next move **54.8%** of the time (depth-weighted: 51.1%). Counting every book state instead gives 55.7%, which overstates it because those states overlap.
- **Imbalance deciles:** P(next move up) goes from 0.42 in the most ask-heavy decile to 0.53 in the most bid-heavy.
- **Price impact:** 5s impact scales like size^0.04 (95% CI -0.04 to 0.11, 7 size buckets): not distinguishable from zero, so no clear size effect.
- **Spreads:** quoted $0.1513 (time-weighted), effective $0.0900, Roll-implied $0.0257.
- **Volatility signature:** daily vol from 1s trade prices is 1.23% vs 0.92% from 1s mids (bid-ask bounce inflates trade-based RV at high frequency).
- **Hidden liquidity:** 39.1% of trades hit at least one hidden order. Effective spread is 1.697 bps for visible-only trades and 1.305 bps for trades with hidden fills. LOBSTER's direction for hidden fills can't be checked against the quote when they execute at the mid, so the visible-only figure is the cleaner one.
- **Trade signs:** lag-1 autocorrelation of trade signs is 0.59 (order splitting).

