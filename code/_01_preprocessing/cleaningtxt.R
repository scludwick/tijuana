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

raw_files <- list.files(raw_txt_dir, full.names = T)

### FROM SALINAS PROJ, change thresholds? DOES NOT INCLUDE HEADER/FOOTER REMOVAL FROM SALINAS
# These thresholds were set for this project based on testing of samples
# what are maximum proportions of characters are punctuation, numeric characters, or white space?
# if want to turn off, set to 1 (i.e., keep all because ratio cannot be > 1)
punctuation_density_threshold <- 0.1
numeric_character_density_threshold <- 0.25
white_space_density_threshold <- 0.75
# what is the maximum number of characters in page?
# (20k is pretty generous)
max_characters = 20e3

# why doing this and not just using data[[x]] i don't see where dataraw or dataintermed are used ???
data <- vector(mode = "list", length = length(raw_files))
dataraw <- vector(mode = "list", length = length(raw_files))
dataintermed <- vector(mode = "list", length = length(raw_files))

#### 
for (x in seq_along(raw_files)) {
  
  cleaned_file <- file.path(clean_txt_dir, 
                            stringr::str_replace(basename(raw_files[x]), ".txt$", ".RDS"))
  if (CLOBBER || !file.exists(cleaned_file)) {
    ## ??? ##
    data[[x]] <- fread(raw_files[x])
    dataintermed[[x]] <- fread(raw_files[x])
    dataraw[[x]] <- fread(raw_files[x])
    # Calculate total characters for each text entry once
    total_characters <- nchar(data[[x]]$text)
    
    # Filter out pages with excessive punctuation, numeric characters, or too many total characters
    punctuation_count <- str_count(data[[x]]$text, "[[:punct:]]")
    numeric_character_count <- str_count(data[[x]]$text, "[0-9]")
    white_space_count <- str_count(data[[x]]$text, "\\s")
    
    punctuation_density <- punctuation_count / total_characters
    numeric_character_density <- numeric_character_count / total_characters
    white_space_density <- white_space_count / total_characters
    
    #use these vars to manually check examples of failed pages to make sure threshold is sensible
    #punctfail for the first and second file is only references and table of contents
    punctfail <- data[[x]][punctuation_density > punctuation_density_threshold, ]
    #numfail for the first file is empty. threshold of 0.1 catches partial tables
    #for file 1 and 0.15 catches partial tables for file 2 so 0.25 seems reasonable
    #for file 3, 0.05 catches references
    numfail <- data[[x]][numeric_character_density > numeric_character_density_threshold, ]
    #spacefail for the first file is only tables
    spacefail <- data[[x]][white_space_density > white_space_density_threshold, ]
    #charfail for the first file is empty, for file 2 is a bunch of maps
    charfail <- data[[x]][total_characters > max_characters, ]
    #thresholds are suitable for not removing true sentences.
    
    #instead of cutting pages we just set them to an empty string.
    #That way it's easier to query by page number and match network
    #data to the original pdf
    
    data[[x]]$text <- case_when(
      total_characters == 0 ~ "",
      punctuation_density > punctuation_density_threshold |
        numeric_character_density > numeric_character_density_threshold |
        white_space_density > white_space_density_threshold | 
        total_characters > max_characters ~ "",
      T ~ data[[x]]$text
    )
    print(raw_files[x])
    dataintermed[[x]]$text <- data[[x]]$text
    

    #keep in RDS rather than txt for encoding ease
    #this is important because we want to compare the header/footer removal to make sure it works acceptably
    saveRDS(object = data[[x]], file = cleaned_file)
  }
}

### this not giving numfail, punctfail, spacefail for all files 

# punctfail: pgs 3-11 are TOCs, sensible to remove
# spacefail: pg 192-194, 285 seem to be tables? not sure 
