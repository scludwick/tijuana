# download plans from spreadsheet

irwm_db <- read.csv("tijuanabox/raw_data/planlinks.csv")
## add if statement to this if nrow within group is > 1
irwm_db <- irwm_db %>%
  mutate(region_name = paste0("Region_", str_extract(IRWM_Region, "[^-]+"))) %>%
  group_by(IRWM_Region, year) %>%
  mutate(n = row_number()) %>% 
  mutate(alln = row_number(n)) %>%
  mutate(filename = 
           case_when(alln > 1 ~ paste0(region_name, "_", year, "_part", n, ".pdf"),
                     alln == 1 ~ paste0(region_name, "_", year, ".pdf"))) %>%
  ungroup()

urls <- irwm_db$url
filename <- irwm_db$filename
planloc <- "tijuanabox/raw_data/plan_pdfs"

for (i in seq_along(urls)) {
  pdf_files <- paste0(planloc, "/", filename[i])
  tryCatch({
    if(!file.exists(pdf_files)) {
      download.file(urls[i], destfile = pdf_files)
  }
  }, error = function(e) {
    message("Skipping file ", filenames[i], " due to error: ", e$message)
  })
}

# need to add a tryCatch to skip empty url values 
