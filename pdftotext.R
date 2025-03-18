# practicing text processing on manually downloaded plan
# using code from salinas

#set-up: decide whether clobber is true or false,
#depending on whether you want to force overwrite files
CLOBBER <- FALSE  # Set this to TRUE if you want to overwrite existing txt files

packs <- c("pdftools", "data.table", "tesseract")
### check if package already installed
need <- packs[!packs %in% installed.packages()[,'Package']]
### install things that arent' installed yet
install.packages(need)
### load packages
sapply(packs,library,character.only = T)

# code here will get pdf files
# then will process to .txt
# and save to new txt directory
## figure out symbolic link to tijuanabox

# here is code from salinas:
for (file in pdfiles) {
  txt_file_path <- file.path(txt_file_directory, sub("\\.pdf$", ".txt", file))
  if (file.exists(txt_file_path) && !CLOBBER) {
    next
  }
  tryCatch({
    #we suppressmessages according to documentation of pdftools since the function is extremely verbose
    text <- suppressMessages(pdf_text(file.path(pdf_file_directory, file)))
    # If the text is null or empty, use OCR to get the text
    if (is.null(text) || !any(nchar(unlist(text)) > 0)) {
      text <- suppressMessages(pdf_ocr_text(file.path(pdf_file_directory, file)))
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

