# download plans from spreadsheet
library(dplyr)
library(stringr)
irwm_db <- read.csv("tijuanabox/raw_data/planlinks.csv")
## add if statement to this if nrow within group is > 1
irwm_db <- irwm_db %>%
  mutate(region_name = paste0("Region_", str_extract(IRWM_Region, "[^-]+"))) %>%
  group_by(IRWM_Region, year) %>%
  mutate(region_year = paste0(region_name, "_", year))

  # mutate(n = row_number()) %>% 
  # mutate(alln = row_number(n)) %>%
  # # i think maybe i don't want this to be part_n but instead be whatever file name is
  # mutate(filename = 
  #          case_when(alln > 1 ~ paste0(region_name, "_", year, "_part", n, ".pdf"),
  #                    alln == 1 ~ paste0(region_name, "_", year, ".pdf"))) %>%
  ungroup()

urls <- irwm_db$url
filename <- paste0(irwm_db$region_year, "_")
planloc <- "tijuanabox/raw_data/plan_pdfs"

# for (i in seq_along(urls[2:25])) {
#   pdf_file <- file.path(planloc, paste0(filename[i], basename(urls[i])))
#   tryCatch({
#     if(!file.exists(pdf_file)) {
#       download.file(urls[i], destfile = pdf_file[i])
#     }
#     else {
#       message("Already downloaded", pdf_file[i])
#     }
#   }, error = function(e) {
#     message("Skipping file ", pdf_file[i], " due to error: ", e$message)
#   })
# }
# 
# download.file(urls[3], destfile = file.path(planloc, paste0(filename[3], basename(urls[3]))))



### this works when URL is .pdf link but not for other types. also rethink how to name the files, I had done like "part_n" before but thought we might want to know what's in them if we have it (like if appendix in name)
download_plans <- function(url, filename) {
  pdf_file <- file.path(planloc, paste0(filename, basename(url)))
  tryCatch({
    if(!file.exists(pdf_file)) {
      download.file(url, destfile = pdf_file)
    }
    else {
      message("Already downloaded:", pdf_file)
    }
  }, error = function(e) {
    message("Skipping file ", pdf_file, " due to error: ", e$message)
  })
}

mapply(download_plans, url = urls, filename = filename)  

# this isn't working for the urls that don't end in .pdf (like when they are to the link that has computer download them) so need to amend this for that 
# probably to get url type


