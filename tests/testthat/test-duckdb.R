# The SQL is meant to run unchanged on SQLite and DuckDB. Run the same short
# simulated session through both engines and compare the results.
testthat::skip_if_not_installed("duckdb")

root <- normalizePath(file.path(testthat::test_path(), "..", ".."))
for (f in c("simulate_lob.R", "db.R", "analysis.R")) source(file.path(root, "R", f))

tmp <- tempfile("lobduck")
sim <- simulate_lobster(out_dir = tmp, start_sec = 34200, end_sec = 34200 + 900,
                        seed = 11, verbose = FALSE)

run_engine <- function(engine) {
  con <- db_connect(file.path(tmp, paste0(engine, ".sqlite")), engine = engine)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  load_lobster(con, sim$message_file, sim$orderbook_file)
  run_pipeline(con, file.path(root, "sql"), verbose = FALSE)
  list(
    summary = DBI::dbGetQuery(con, "SELECT metric, value FROM summary ORDER BY metric"),
    deciles = DBI::dbGetQuery(con, "SELECT measure, decile, n, p_up FROM imbalance_deciles
                                    ORDER BY measure, decile"),
    impact = DBI::dbGetQuery(con, "SELECT * FROM impact_by_size ORDER BY size_bucket"),
    rv = DBI::dbGetQuery(con, "SELECT * FROM rv_signature ORDER BY interval_sec"),
    ofi = DBI::dbGetQuery(con, "SELECT bucket_ms, ofi, d_mid FROM ofi_buckets ORDER BY bucket_ms")
  )
}

lite <- run_engine("sqlite")
duck <- run_engine("duckdb")

test_that("DuckDB and SQLite give the same results", {
  for (nm in names(lite)) {
    a <- as.data.frame(lapply(lite[[nm]], function(x) if (is.numeric(x)) as.numeric(x) else x))
    b <- as.data.frame(lapply(duck[[nm]], function(x) if (is.numeric(x)) as.numeric(x) else x))
    expect_equal(b, a, tolerance = 1e-9, label = paste("duckdb", nm),
                 expected.label = paste("sqlite", nm))
  }
})

unlink(tmp, recursive = TRUE)
