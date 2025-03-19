# cleaning txt files to remove maps, figs, TOCs, headers/footers(?)

CLOBBER <- TRUE
### code for cleaning .txt files before textnet, adapted from salinas proj

packs <- c("data.table", "stringr", "dplyr")
need <- packs[!packs %in% installed.packages()[,'Package']]
install.packages(need)
sapply(packs,library,character.only = T)


raw_txt_dir <- "tijuanabox/int_data/plan_txts_raw"
clean_txt_dir <- "tijuanabox/int_data/plan_txts_clean"
if (!dir.exists(clean_txt_dir)) {
  dir.create(clean_txt_dir)
}

raw_files <- list.files(raw_txt_dir)

### FROM SALINAS PROJ: change thresholds? 
# These thresholds were set for this project based on testing of samples
# what are maximum proportions of characters are punctuation, numeric characters, or white space?
# if want to turn off, set to 1 (i.e., keep all because ratio cannot be > 1)
punctuation_density_threshold <- 0.1
numeric_character_density_threshold <- 0.25
white_space_density_threshold <- 0.75
# what is the maximum number of characters in page?
# (20k is pretty generous)
max_characters = 20e3
data <- vector(mode = "list", length = length(raw_files))
dataraw <- vector(mode = "list", length = length(raw_files))
dataintermed <- vector(mode = "list", length = length(raw_files))

#### MANUALLY CLEANING A PLAN SO I UNDERSTAND WHAT IT'S DOING THEN LATER WILL MAKE FUNC OR LOOP
AV19 <- fread(paste0(raw_txt_dir,"/",raw_files))
total_characters <- nchar(AV19$text)
# Filter out pages with excessive punctuation, numeric characters, or too many total characters
punctuation_count <- str_count(AV19$text, "[[:punct:]]")
numeric_character_count <- str_count(AV19$text, "[0-9]")
white_space_count <- str_count(AV19$text, "\\s")

punctuation_density <- punctuation_count / total_characters
numeric_character_density <- numeric_character_count / total_characters
white_space_density <- white_space_count / total_characters

#use these vars to manually check examples of failed pages to make sure threshold is sensible
punctfail <- AV19[punctuation_density > punctuation_density_threshold, ]
# pgs 3-11 are TOCs, sensible to remove
numfail <- AV19[numeric_character_density > numeric_character_density_threshold, ]
# none
spacefail <- AV19[white_space_density > white_space_density_threshold, ]
# pg 192-194, 285 seem to be tables? not sure 
charfail <- AV19[total_characters > max_characters, ]
# none

# are thresholds suitable for not removing true sentences?


