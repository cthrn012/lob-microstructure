# Results

Data: the LOBSTER file pair `INTC_2012-06-21_34200000_57600000` (real Nasdaq data).

| Metric | Value |
|---|---|
| messages | 581,030 |
| limit order submissions | 283,287 |
| cancellations (full + partial) | 265,260 |
| executions (fills) | 32,483 |
| trades (stitched) | 10,407 |
| share volume | 10,471,645 |
| cancel-to-trade ratio | 25.49 |
| avg quoted spread, time-weighted ($) | 0.01013 |
| avg quoted spread per book update ($) | 0.01246 |
| share of time at 1-tick spread | 0.9878 |
| share of book updates at 1-tick spread | 0.7549 |
| avg effective spread (bps) | 2.995 |
| avg effective spread, visible-only trades (bps) | 3.938 |
| avg effective spread, trades with hidden fills (bps) | 0.7138 |
| share of fills against hidden orders | 0.1096 |
| share of hidden fills at the pre-trade mid | 0.7494 |
| avg realized spread 5s (bps) | -0.5661 |
| avg price impact 5s (bps) | 1.782 |
| share of trades walking the book | 0.02604 |
| roll autocovariance | -2.677e-06 |

## Key findings

- **Order flow imbalance:** 10s OFI (scaled by L1 depth) explains **R² = 0.835** of mid-price changes (n = 2339 buckets, t = 108.6).
- **Queue imbalance:** measured once per mid move (n = 3,213), the sign of L1 imbalance calls the next move **56.9%** of the time (depth-weighted: 55.7%). Counting every book state instead gives 65.3%, which overstates it because those states overlap.
- **Imbalance deciles:** P(next move up) goes from 0.24 in the most ask-heavy decile to 0.68 in the most bid-heavy.
- **Price impact:** 5s impact scales like size^0.22 (95% CI 0.09 to 0.35, 8 size buckets): below the square-root law's 0.5.
- **Spreads:** quoted $0.0101 (time-weighted), effective $0.0081, Roll-implied $0.0033.
- **Volatility signature:** daily vol from 1s trade prices is 1.47% vs 1.28% from 1s mids (bid-ask bounce inflates trade-based RV at high frequency).
- **Hidden liquidity:** 29.2% of trades hit at least one hidden order. Effective spread is 3.938 bps for visible-only trades and 0.714 bps for trades with hidden fills. LOBSTER's direction for hidden fills can't be checked against the quote when they execute at the mid, so the visible-only figure is the cleaner one.
- **Trade signs:** lag-1 autocorrelation of trade signs is 0.59 (order splitting).

