# Install the R packages this project uses.
# `Rscript` is non-interactive and can't prompt for a CRAN mirror, so set one
# if none is configured. A mirror that is already set (for example a binary
# package repository on CI) is kept.
repos <- getOption("repos")
if (is.null(repos) || !nzchar(repos["CRAN"]) || is.na(repos["CRAN"]) ||
    repos["CRAN"] == "@CRAN@") {
  options(repos = c(CRAN = "https://cloud.r-project.org"))
}

pkgs <- c("DBI", "RSQLite", "ggplot2", "rmarkdown", "knitr", "testthat")
missing <- setdiff(pkgs, rownames(installed.packages()))
if (length(missing)) install.packages(missing)

still_missing <- setdiff(pkgs, rownames(installed.packages()))
if (length(still_missing)) {
  stop("could not install: ", paste(still_missing, collapse = ", "))
}
message("All packages installed.")
message("Optional: install.packages('duckdb') to run the same SQL on DuckDB.")
if (!rmarkdown::pandoc_available("2.8")) {
  message("Note: the HTML report needs pandoc 2.8 or newer, which is not an R ",
          "package. Get it from https://pandoc.org/installing.html")
}
