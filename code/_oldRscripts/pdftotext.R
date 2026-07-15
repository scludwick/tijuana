# using code from salinas

#set-up: decide whether clobber is true or false,
#depending on whether you want to force overwrite files
CLOBBER <- FALSE  # Set this to TRUE if you want to overwrite existing txt files

packs <- c("pdftools", "data.table", "tesseract")
need <- packs[!packs %in% installed.packages()[,'Package']]
install.packages(need)
sapply(packs,library,character.only = T)

### decide (here?) whether to combine chapters into one plan or keep separate ###

# directories for plan pdfs and folder to store converted txt files
pdf_dir <- "tijuanabox/raw_data/plan_pdfs"
txt_dir <- "tijuanabox/int_data/plan_txts_raw"
if (!dir.exists(txt_dir)) {
  dir.create(txt_dir)
}

pdfs <- list.files(pdf_dir, pattern = ".pdf")

# code for converting pdfs to .txts adapted from salinas:
for (file in pdfs) {
  txt_file_path <- file.path(txt_dir, sub("\\.pdf$", ".txt", file))
  if (file.exists(txt_file_path) && !CLOBBER) {
    next
  }
  tryCatch({
    #we suppressmessages according to documentation of pdftools since the function is extremely verbose
    text <- suppressMessages(pdf_text(file.path(pdf_dir, file)))
    # If the text is null or empty, use OCR to get the text
    if (is.null(text) || !any(nchar(unlist(text)) > 0)) {
      text <- suppressMessages(pdf_ocr_text(file.path(pdf_dir, file)))
    }
    # If the text is not null or empty, write it to the txt file    
    if (!is.null(text)) {
      dt <- data.table(page = seq_along(text), text = text)
      fwrite(dt, txt_file_path, sep = "\t")
    }
  }, error = function(e) {
    message(sprintf("Error processing file %s: %s", file, e$message))
  })
}

# write script to return list of files with errors?