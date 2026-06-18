# _config.R — shared configuration for the tijuana pipeline.
# Sourced (via code/utils.R) by every R step. Centralizes the flags and
# tunables that more than one step depends on, so a single change rolls
# through the pipeline. Ported from the kings core_code _config.R; the
# filekey/fk() layer is intentionally omitted (tijuana uses plain relative
# paths in each script).
#
# Usage: scripts source code/utils.R, which sources this file. Override any
# default from the shell with an environment variable before invoking Rscript
# (or set it for a python step too — the python scripts read the same names):
#
#   CLOBBER=1        -> CLOBBER        <- TRUE   (default FALSE)
#   TESTING=1        -> TESTING        <- TRUE   (default FALSE)
#   TESTING_N=10     -> TESTING_N      <- 10     (default 5)
#   MIN_PAGE_CHARS=300 -> MIN_PAGE_CHARS <- 300  (default 200)
#   PARSE_WORKERS=8  -> PARSE_WORKERS  <- 8      (default 1)
#   SPACY_ENV=myenv  -> SPACY_ENV      <- "myenv" (default "spacy-env")
#
# e.g.   CLOBBER=1 Rscript code/04_disambiguate_nodelists.R
#        TESTING=1 TESTING_N=3 Rscript code/03_textnet_parse_and_extract.R

# === Helper: bool / int env var with default ================================
.env_bool <- function(name, default = FALSE) {
  v <- Sys.getenv(name, unset = NA)
  if (is.na(v) || !nzchar(v)) return(default)
  tolower(v) %in% c("1", "true", "t", "yes", "y")
}
.env_int <- function(name, default) {
  v <- Sys.getenv(name, unset = NA)
  if (is.na(v) || !nzchar(v)) return(default)
  suppressWarnings(as.integer(v))
}

# === Pipeline flags =========================================================
# CLOBBER: re-run a step's work even if the output already exists. Default
# FALSE so reruns are cheap.
CLOBBER   <- .env_bool("CLOBBER", FALSE)

# TESTING: restrict to the first TESTING_N input units for a fast smoke test.
TESTING   <- .env_bool("TESTING", FALSE)
TESTING_N <- .env_int("TESTING_N", 5L)

# === Shared thresholds ======================================================
# MIN_PAGE_CHARS: a usable page must have more than this many characters after
# cleaning. Consumed by the parse step (filters pages before parsing).
MIN_PAGE_CHARS <- .env_int("MIN_PAGE_CHARS", 200L)

# PARSE_WORKERS: number of parallel workers passed as `cl` to
# textNet::textnet_extract() in the parse step. 1 is the safe default; raise
# on a workstation.
PARSE_WORKERS <- .env_int("PARSE_WORKERS", 1L)

# === spaCy env ==============================================================
# Conda env name (resolved via reticulate::conda_list()) OR a full path to a
# python binary with spacy + en_core_web_trf installed. Per-user/machine, so
# it lives here as an editable default rather than a committed path.
SPACY_ENV <- Sys.getenv("SPACY_ENV", unset = "spacy-env")

# === Atomic writes ==========================================================
# Long steps that get Ctrl-C'd, run out of disk, or crash mid-write would
# otherwise leave half-written outputs that satisfy file.exists() and get
# skipped on the next non-CLOBBER rerun. atomic_write() writes to <out>.tmp
# and only renames into place on success.
atomic_write <- function(out_path, writer_fn) {
  tmp <- paste0(out_path, ".tmp")
  on.exit(if (file.exists(tmp)) file.remove(tmp), add = TRUE)
  writer_fn(tmp)
  if (!file.exists(tmp)) stop("atomic_write: writer_fn did not create ", tmp)
  file.rename(tmp, out_path)
}

atomic_saveRDS <- function(obj, out_path, ...) {
  atomic_write(out_path, function(p) saveRDS(obj, p, ...))
}
