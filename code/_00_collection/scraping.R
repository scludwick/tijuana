# download plans from spreadsheet
CLOBBER <- FALSE  # Set TRUE to re-download already-existing PDFs

library(dplyr)
library(stringr)
library(httr)
irwm_db <- read.csv("tijuanabox/raw_data/planlinks.csv")
## add if statement to this if nrow within group is > 1
irwm_db <- irwm_db %>%
  mutate(region_name = paste0("Region_", str_trim(str_extract(IRWM_Region, "[^-]+")))) %>%
  group_by(IRWM_Region, year) %>%
  mutate(region_year = paste0(region_name, "_", year)) %>%

  # mutate(n = row_number()) %>% 
  # mutate(alln = row_number(n)) %>%
  # # i think maybe i don't want this to be part_n but instead be whatever file name is
  # mutate(filename = 
  #          case_when(alln > 1 ~ paste0(region_name, "_", year, "_part", n, ".pdf"),
  #                    alln == 1 ~ paste0(region_name, "_", year, ".pdf"))) %>%
  ungroup()


urls   <- irwm_db$url
planloc <- "tijuanabox/raw_data/plan_pdfs"

sanitize_filename <- function(x) gsub(" ", "_", x)

gdrive_to_direct <- function(url) {
  # Convert Google Drive view URL to direct download URL.
  # e.g. https://drive.google.com/file/d/{ID}/view?resourcekey=...
  #   -> https://drive.google.com/uc?export=download&id={ID}
  m <- regmatches(url, regexpr("(?<=/d/)[^/]+", url, perl = TRUE))
  if (length(m) == 1) {
    paste0("https://drive.google.com/uc?export=download&id=", m)
  } else {
    url  # return unchanged if pattern not found
  }
}

is_gdrive_view <- function(url) {
  grepl("drive\\.google\\.com/.*/view", url)
}

gdrive_original_filename <- function(file_id) {
  # HEAD the direct download URL and read Content-Disposition for the original name.
  # Falls back to file ID if the header is absent or the request fails.
  direct_url <- paste0("https://drive.google.com/uc?export=download&id=", file_id)
  tryCatch({
    resp <- httr::HEAD(direct_url, httr::config(followlocation = TRUE))
    cd   <- httr::headers(resp)[["content-disposition"]]
    if (!is.null(cd)) {
      fname <- regmatches(cd, regexpr('(?<=filename=")[^"]+', cd, perl = TRUE))
      if (length(fname) == 1 && nchar(fname) > 0)
        return(sanitize_filename(URLdecode(fname)))
    }
  }, error = function(e) NULL)
  paste0("gdrive_", file_id, ".pdf")   # fallback
}

clean_basename <- function(url) {
  if (is_gdrive_view(url)) {
    file_id <- regmatches(url, regexpr("(?<=/d/)[^/?]+", url, perl = TRUE))
    return(gdrive_original_filename(file_id))
  }
  # Strip query string, get basename, URL-decode, sanitize
  bname <- basename(sub("\\?.*$", "", url))
  sanitize_filename(URLdecode(bname))
}

resolve_url <- function(url) {
  if (is_gdrive_view(url)) gdrive_to_direct(url) else url
}

# Build manifest: URL -> region_year -> filename on disk
manifest <- data.frame(
  url         = urls,
  region_year = irwm_db$region_year,
  filename    = mapply(function(ry, url) paste0(ry, "_", clean_basename(url)),
                       irwm_db$region_year, urls),
  status      = NA_character_,
  stringsAsFactors = FALSE
)

download_plans <- function(url, region_year) {
  download_url <- resolve_url(url)
  pdf_file     <- file.path(planloc, paste0(region_year, "_", clean_basename(url)))
  status <- tryCatch({
    if (CLOBBER || !file.exists(pdf_file)) {
      download.file(download_url, destfile = pdf_file)
      "downloaded"
    } else {
      message("Already downloaded: ", pdf_file)
      "skipped"
    }
  }, error = function(e) {
    message("Failed: ", pdf_file, " — ", e$message)
    "failed"
  })
  status
}

statuses <- mapply(download_plans, url = urls, region_year = irwm_db$region_year)
manifest$status <- statuses

write.csv(manifest, "tijuanabox/raw_data/download_manifest.csv", row.names = FALSE)
message("Manifest written to tijuanabox/raw_data/download_manifest.csv")


