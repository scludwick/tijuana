# analyze networks generated in previous steps of pipeline

library(textNet)
library(purrr)
library(igraph)
library(tidyverse)
library(ggraph)
library(gtsummary)

#uniplex networks 
uni_files <- list.files("tijuanabox/core_data/igraph_objects/uniplex", full.names = T)
uni_graphs <- lapply(uni_files, readRDS)
names <- str_extract(basename(uni_files), pattern = "(?<=extract_).+?(?=\\.RDS)")
for (i in 1:length(uni_graphs)) {
  names(uni_graphs)[i] <- names[i] # name the networks
  g <- uni_graphs[[i]]
  g <- induced_subgraph(g, V(g)[degree(g) >= 1]) # remove isolates
}

# names(uni_graphs) 
# we have a Region_NA_2012, need to investigate that but for now moving along 


# ggraph(g, layout = "fr") +
#   geom_edge_link() +
#   geom_node_point(aes(color = entity_type, size = num_appearances),  alpha = 0.6)

# peep top nodes
top_nodes_all_networks <- list()
networks <- uni_graphs
for (i in seq_along(networks)) {
  g <- networks[[i]] 
  network_name <- names(networks)[[i]]
  deg <- degree(networks[[i]], mode = "all")
  # btw <- betweenness(g, directed = is.directed(g))
  # eig <- eigen_centrality(g)$vector
  node_names <- V(g)$name
  entity_type <- V(g)$entity_type
  
  # store as df per network
  nodes <- data.frame(
    network = network_name,
    node    = node_names,
    degree  = deg,
    node_type = entity_type,
    row.names = NULL) 
  
  # get top 30 
  top_nodes <- nodes %>%
    arrange(desc(degree)) %>%
    slice_head(n = 30)
  
  top_nodes_all_networks[[i]] <- top_nodes
}

top_nodes_df <- bind_rows(top_nodes_all_networks)


### descriptives
network_descriptives <- lapply(seq_along(networks), function(i) {
  g <- networks[[i]]
  deg <- degree(g)
  list(c(network = names(networks[i]),
         region = str_extract(names(networks[i]), ".*(?=_[^_]*$)"),
         year = str_extract(names(networks[i]), ".{4}$"),
         n_nodes = vcount(g),
         n_edges = ecount(g),
         density = edge_density(g),
         mean_degree = mean(deg),
         sd_degree = sd(deg)
         # reciprocity = reciprocity(g),
         # transitivity = transitivity(g, type = "global"),
         # centralization = centr_degree(g)$centralization)
  ))})

descriptives_df <- bind_rows(network_descriptives) %>%
  mutate(across(n_nodes:sd_degree, as.numeric))

summary(descriptives_df)

# some starting places:
# Graph correlation
# Some sort of graph structural matching (correlation is dyadic, structure matching is more about substructures).
# Core–periphery
# Modularity
# Centralization measure
# Perhaps a brokerage measure
