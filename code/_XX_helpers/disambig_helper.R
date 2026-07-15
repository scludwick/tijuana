#removing where to == from. this happens when 
#state is in the name but does not begin with the state
#it doesn't mess up the disambiguate function but avoids
#annoying warnings
indicestoremove <- vector(mode = "numeric", length = 0)
for(x in 1:length(from)){
  if(length(from[[x]]) == length(to[[x]]) & all(from[[x]] == to[[x]])){
    indicestoremove <- append(indicestoremove, x)
  }
}
if(length(indicestoremove)>0){
  from <- from[-indicestoremove]
  to <- to[-indicestoremove]
}


cleaned_extract <- disambiguate(textnet_extract = myextracts[[i]],
                                from = from,
                                to = to)
#add AgencyScope
cleaned_extract$nodelist$AgencyScope <- 
  unlist(lapply(1:nrow(cleaned_extract$nodelist), function(j) {
    state <- myacronyms[[i]]$State[tolower(myacronyms[[i]]$to) == cleaned_extract$nodelist$entity_name[j]]
    state <- ifelse(length(state)==0, NA, state)}))

#don't overwrite AgencyScope from myacronyms but add on to it using entity dictionary
statesvect <- unlist(lapply(1:nrow(cleaned_extract$nodelist), function(j) {
  state <- entitydict[[i]]$State[entitydict[[i]]$Name == cleaned_extract$nodelist$entity_name[j]]
  state <- ifelse(length(state)==0, NA, state)}))
cleaned_extract$nodelist$AgencyScope <- dplyr::case_when(
  is.na(cleaned_extract$nodelist$AgencyScope) ~ statesvect,
  T ~ cleaned_extract$nodelist$AgencyScope
)
