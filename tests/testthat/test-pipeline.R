# Run from the repo root:  Rscript -e 'testthat::test_dir("tests/testthat")'
root <- normalizePath(file.path(testthat::test_path(), "..", ".."))
for (f in c("simulate_lob.R", "db.R", "analysis.R")) source(file.path(root, "R", f))

tmp <- tempfile("lobtest")
sim <- simulate_lobster(out_dir = tmp, start_sec = 34200, end_sec = 34200 + 900,
                        seed = 7, verbose = FALSE)
con <- db_connect(file.path(tmp, "test.sqlite"))
load_lobster(con, sim$message_file, sim$orderbook_file)
run_pipeline(con, file.path(root, "sql"), verbose = FALSE)
q <- function(sql) DBI::dbGetQuery(con, sql)

test_that("simulated book never goes negative and files round-trip", {
  expect_true(all(sim$orderbook[, grepl("size", colnames(sim$orderbook))] >= 0))
  expect_equal(q("SELECT COUNT(*) AS n FROM messages")$n, nrow(sim$messages))
  expect_equal(q("SELECT MAX(level) AS l FROM book")$l, 5)
})

test_that("top of book is sane", {
  bad <- q("SELECT COUNT(*) AS n FROM tob
            WHERE spread <= 0 OR microprice < bid OR microprice > ask
               OR imb_l1 < -1 OR imb_l1 > 1")$n
  expect_equal(bad, 0)
})

test_that("fills stitch back into exactly one trade per market order", {
  expect_equal(q("SELECT COUNT(*) AS n FROM trades")$n, sim$n_market_orders)
  expect_equal(q("SELECT SUM(size) AS s FROM trades")$s,
               q("SELECT SUM(size) AS s FROM fills")$s)
})

test_that("effective spread = realized spread + 2 x impact (identity)", {
  d <- q("SELECT eff_spread_bps, real_spread_5s_bps, impact_5s_bps
          FROM trade_costs WHERE impact_5s_bps IS NOT NULL")
  expect_gt(nrow(d), 0)
  expect_equal(d$eff_spread_bps, d$real_spread_5s_bps + 2 * d$impact_5s_bps,
               tolerance = 1e-8)
})

test_that("time grid is a complete 1-second clock", {
  g <- q("SELECT COUNT(*) AS n, MIN(sec_ms) AS lo, MAX(sec_ms) AS hi FROM time_grid")
  expect_equal(g$n, (g$hi - g$lo) / 1000 + 1)
})

test_that("imbalance signal: next move is +/-1 and deciles cover all rows", {
  expect_true(all(q("SELECT DISTINCT next_move FROM imbalance_signal")$next_move %in% c(-1, 1)))
  n_sig <- q("SELECT COUNT(*) AS n FROM imbalance_per_move")$n
  n_dec <- q("SELECT SUM(n) AS n FROM imbalance_deciles
              WHERE measure = 'L1 queue imbalance'")$n
  expect_equal(n_sig, n_dec)
})

test_that("imbalance is sampled once per mid move", {
  d <- q("SELECT event_id + events_until_move AS move_event FROM imbalance_per_move")
  expect_gt(nrow(d), 0)
  expect_equal(anyDuplicated(d$move_event), 0)
  n_states <- q("SELECT COUNT(*) AS n FROM imbalance_signal")$n
  expect_lt(nrow(d), n_states)
})

test_that("spread metrics are weighted by time, not by update", {
  d <- q("SELECT t_ms, spread FROM tob ORDER BY event_id")
  dt <- diff(d$t_ms)
  s <- d$spread[-nrow(d)]
  st <- q("SELECT * FROM spread_time")
  expect_equal(sum(st$ms), sum(dt))
  expect_equal(sum(st$spread_ms) / sum(st$ms), sum(s * dt) / sum(dt))
  summ <- q("SELECT value FROM summary WHERE metric = 'share of time at 1-tick spread'")$value
  expect_equal(summ, sum(dt[round(s * 100) == 1]) / sum(dt))
})

test_that("models fit", {
  res <- analyze(con)
  expect_true(is.finite(res$ofi$r2_scaled))
  expect_gt(res$imbalance$hit_rate_l1, 0.5)
  expect_true(all(is.finite(res$impact$ci)))
  expect_lt(res$impact$ci[1], res$impact$exponent)
  expect_gt(res$impact$ci[2], res$impact$exponent)
  expect_type(impact_verdict(res$impact), "character")
})

test_that("impact verdict reads the confidence interval correctly", {
  expect_match(impact_verdict(list(ci = c(0.3, 0.7))), "consistent")
  expect_match(impact_verdict(list(ci = c(-0.04, 0.1))), "zero")
  expect_match(impact_verdict(list(ci = c(0.09, 0.38))), "below")
  expect_match(impact_verdict(list(ci = c(0.6, 0.9))), "above")
  expect_match(impact_verdict(list(ci = c(NA, NA))), "too few")
})

test_that("impact horizons are exactly h after the trade", {
  tob <- q("SELECT t_ms, mid FROM tob ORDER BY event_id")
  tc <- q("SELECT t_ms, sign, pre_mid, impact_5s_bps, impact_60s_bps FROM trade_costs")
  for (h in c(5000, 60000)) {
    col <- if (h == 5000) "impact_5s_bps" else "impact_60s_bps"
    ok <- tc$t_ms + h <= max(tob$t_ms)
    mid_h <- tob$mid[findInterval(tc$t_ms[ok] + h, tob$t_ms)]
    expected <- 10000 * tc$sign[ok] * (mid_h - tc$pre_mid[ok]) / tc$pre_mid[ok]
    expect_equal(tc[[col]][ok], expected, tolerance = 1e-10)
    expect_true(all(is.na(tc[[col]][!ok])))
  }
})

test_that("hidden fills are tracked and costed separately", {
  # The simulator has no hidden orders, so relabel some fills as hidden.
  msgs <- q("SELECT * FROM messages")
  fills <- which(msgs$type == 4)
  hidden <- fills[seq(1, length(fills), by = 3)]
  msgs$type[hidden] <- 5L
  con2 <- db_connect(file.path(tmp, "hidden.sqlite"))
  DBI::dbWriteTable(con2, "messages", msgs, overwrite = TRUE)
  DBI::dbWriteTable(con2, "book", q("SELECT * FROM book"), overwrite = TRUE)
  run_pipeline(con2, file.path(root, "sql"), verbose = FALSE)
  q2 <- function(sql) DBI::dbGetQuery(con2, sql)
  expect_equal(q2("SELECT SUM(n_hidden_fills) AS n FROM trades")$n, length(hidden))
  by_liq <- q2("SELECT * FROM costs_by_liquidity")
  expect_setequal(by_liq$liquidity, c("hidden only", "mixed", "visible only"))
  expect_equal(sum(by_liq$n_trades), q2("SELECT COUNT(*) AS n FROM trades")$n)
  share <- q2("SELECT value FROM summary WHERE metric = 'share of fills against hidden orders'")$value
  expect_equal(share, length(hidden) / length(fills))
  res2 <- analyze(con2)
  expect_match(hidden_line(res2), "Hidden liquidity")
  DBI::dbDisconnect(con2)
})

test_that("results are labelled with the dataset", {
  expect_match(data_description(NULL), "unlabelled")
  expect_match(data_description(data.frame(source = "x", simulated = TRUE)), "simulated")
  expect_match(data_description(data.frame(source = "AAPL_2012", simulated = FALSE)),
               "AAPL_2012")
})

DBI::dbDisconnect(con)
unlink(tmp, recursive = TRUE)
