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
         sd_degree = sd(deg),
         reciprocity = reciprocity(g),
         transitivity = transitivity(g),
         centralization = centr_degree(g)$centralization,
         path_length = mean_distance(g)
  ))})

descriptives_df <- bind_rows(network_descriptives) %>%
  mutate(across(n_nodes:path_length, as.numeric))
# but can't compare all of these to each other because different network sizes (eg path length affected by network size)

# playing with modularity 
# modularity is how strongly the network divides into clusters
# you detect communities first 
# then you determine how "good" that division is (this is modularity score)
# so high score means there is clearer community structure
# low score means less clear comms

mods <- list()
for (i in seq_along(networks)) {
  g <- networks[[i]]
  comms <- cluster_infomap(g, e.weights = E(g)$weight)
  
  mods[[i]] <- data.frame(
    network    = names(networks)[i],
    n_comms    = length(unique(membership(comms))),
    modularity = modularity(comms)
  )
}
mods_df <- bind_rows(mods)


# some starting places:
# Graph correlation
# Some sort of graph structural matching (correlation is dyadic, structure matching is more about substructures).
# Core–periphery
# Modularity
# Centralization measure
# Perhaps a brokerage measure

# correlation (dyadic)
# first have to make into adjacency matrices
adj_mat_nets <- lapply(networks, as_adjacency_matrix, sparse = FALSE)
# also have to give each graph same node set 
# just try for Region_01
R1nodes <- sort(unique(c(V(networks[[1]])$name, V(networks[[2]])$name)))
gcor(dat = adj_mat_nets, diag=FALSE, mode="digraph")

