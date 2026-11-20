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
names(uni_graphs) <- names
# record isolates before removing them
n_isolates <- sapply(uni_graphs, function(g) sum(degree(g) == 0))
# remove isolates (written back to the list)
uni_graphs <- lapply(uni_graphs, function(g) induced_subgraph(g, V(g)[degree(g) >= 1]))

names(uni_graphs)
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




### summary statistics for the full set of networks ----------------------

descriptives_df <- descriptives_df %>%
  mutate(
    year = as.integer(year),
    n_isolates_removed = n_isolates[network],
    # largest weakly connected component, share of nodes
    pct_largest_comp = map_dbl(networks, ~ max(components(.x, mode = "weak")$csize) / vcount(.x))[network] * 100,
    n_self_loops = map_int(networks, ~ sum(which_loop(.x)))[network],
    mean_weight = map_dbl(networks, ~ mean(E(.x)$weight))[network],
    n_orgs = map_int(networks, ~ sum(V(.x)$entity_type == "ORG", na.rm = TRUE))[network],
    n_persons = map_int(networks, ~ sum(V(.x)$entity_type == "PERSON", na.rm = TRUE))[network]
  )

# entity types present (check the labels used above match)
table(unlist(lapply(networks, function(g) V(g)$entity_type)), useNA = "ifany")

# overall distribution across networks
descriptives_df %>%
  select(n_nodes, n_edges, density, mean_degree, reciprocity, transitivity,
         centralization, pct_largest_comp, n_isolates_removed) %>%
  tbl_summary(statistic = all_continuous() ~ "{median} ({p25}, {p75}) [{min}, {max}]")

# waves per region
waves_per_region <- descriptives_df %>%
  group_by(region) %>%
  summarise(n_waves = n(), years = paste(sort(year), collapse = ", "),
            max_gap = if (n() > 1) max(diff(sort(year))) else NA_integer_)
waves_per_region

# how many regions have 1, 2, 3+ waves (2+ eligible for TERGM)
count(waves_per_region, n_waves)

# year coverage
count(descriptives_df, year)

# within-region change over time (TERGM-eligible regions only)
tergm_regions <- waves_per_region %>% filter(n_waves >= 2) %>% pull(region)
descriptives_df %>%
  filter(region %in% tergm_regions) %>%
  arrange(region, year) %>%
  select(region, year, n_nodes, n_edges, density, mean_degree, reciprocity,
         transitivity, pct_largest_comp)

# node and edge overlap between consecutive waves within each region
# (how much does the network persist? relevant for TERGM)
consec_overlap <- map_dfr(tergm_regions, function(reg) {
  d <- descriptives_df %>% filter(region == reg) %>% arrange(year)
  map_dfr(seq_len(nrow(d) - 1), function(k) {
    g1 <- networks[[d$network[k]]]; g2 <- networks[[d$network[k + 1]]]
    n1 <- V(g1)$name; n2 <- V(g2)$name
    e1 <- attr(E(g1), "vnames"); e2 <- attr(E(g2), "vnames")
    tibble(region = reg, from = d$year[k], to = d$year[k + 1],
           nodes_shared = length(intersect(n1, n2)),
           node_jaccard = length(intersect(n1, n2)) / length(union(n1, n2)),
           edge_jaccard = length(intersect(e1, e2)) / length(union(e1, e2)))
  })
})
consec_overlap

# density and node count over time, TERGM-eligible regions
tergm_long <- descriptives_df %>%
  filter(region %in% tergm_regions) %>%
  select(region, year, n_nodes, density) %>%
  pivot_longer(c(n_nodes, density), names_to = "measure", values_to = "value") %>%
  mutate(measure = recode(measure, n_nodes = "Number of nodes", density = "Density"))

for (m in unique(tergm_long$measure)) {
  p <- ggplot(filter(tergm_long, measure == m), aes(year, value)) +
    geom_line() +
    geom_point() +
    facet_wrap(~ region, scales = "free_y") +
    labs(x = NULL, y = m)
  print(p)
  ggsave(paste0("output/", tolower(gsub(" ", "_", m)), "_over_time.png"),
         p, width = 12, height = 12, dpi = 150)
}

# composition of top nodes by type across networks
top_nodes_df %>% count(node_type, sort = TRUE)

# save
write_csv(descriptives_df, "output/network_descriptives.csv")
write_csv(consec_overlap, "output/consecutive_wave_overlap.csv")
