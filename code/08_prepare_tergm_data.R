# prepare uniplex networks for TERGM: one list of aligned `network` objects per region
# (ordered by year). Run after 07_analyze_networks.R is not required; this is standalone.

library(igraph)
library(network)
library(tidyverse)

min_waves <- 2  # regions with fewer years are dropped
out_dir <- "tijuanabox/core_data/network_lists"
dir.create(out_dir, showWarnings = FALSE, recursive = TRUE)

# load -------------------------------------------------------------------
uni_files <- list.files("tijuanabox/core_data/igraph_objects/uniplex", full.names = TRUE)
nets <- lapply(uni_files, readRDS)
names(nets) <- str_extract(basename(uni_files), "(?<=extract_).+?(?=\\.RDS)")

meta <- tibble(
  network = names(nets),
  region  = str_extract(network, ".*(?=_[^_]*$)"),
  year    = as.integer(str_extract(network, ".{4}$"))
) |>
  # Region_NA_2012 has no valid region; excluded until investigated
  filter(region != "Region_NA")

# keep regions with enough waves -------------------------------------------
eligible <- meta |>
  group_by(region) |>
  filter(n() >= min_waves) |>
  ungroup() |>
  arrange(region, year)

# per-region waves summary (check gaps between years)
wave_summary <- eligible |>
  group_by(region) |>
  summarise(n_waves = n(), years = paste(year, collapse = ", "),
  .groups = "drop")
print(wave_summary)

# helpers ----------------------------------------------------------------
# binary, directed adjacency on a shared node set; absent nodes padded with 0.
# Self-loops are dropped and multi-edges / weights collapsed to binary.
to_padded_adj <- function(g, node_set) {
  g <- simplify(g, remove.loops = TRUE, remove.multiple = TRUE)
  A <- matrix(0L, length(node_set), length(node_set),
              dimnames = list(node_set, node_set))
  el <- as_edgelist(g)
  if (nrow(el) > 0) A[cbind(el[, 1], el[, 2])] <- 1L
  A
}

build_region <- function(reg) {
  meta_r <- filter(eligible, region == reg)
  gs <- nets[meta_r$network]
  node_set <- sort(unique(unlist(lapply(gs, \(g) V(g)$name))))

  # vertex attributes: entity_type taken from first wave in which node appears
  # (assumes it is stable over time; check `type_conflicts` below)
  attr_long <- map_dfr(gs, \(g) {
    tibble(name = V(g)$name, entity_type = V(g)$entity_type,
           num_appearances = V(g)$num_appearances)
  }, .id = "network")
  node_attrs <- attr_long |>
    group_by(name) |>
    summarise(entity_type = first(entity_type),
              n_types = n_distinct(entity_type), .groups = "drop") |>
    slice(match(node_set, name))
  type_conflicts <- sum(node_attrs$n_types > 1)

  wave_nets <- imap(gs, \(g, nm) {
    A <- to_padded_adj(g, node_set)
    present <- node_set %in% V(g)$name
    n <- network(A, directed = TRUE, loops = FALSE, matrix.type = "adjacency")
    network.vertex.names(n) <- node_set
    set.vertex.attribute(n, "entity_type", node_attrs$entity_type)
    set.vertex.attribute(n, "present", present)  # was node observed this wave
    attr(n, "network_name") <- nm
    n
  })
  names(wave_nets) <- meta_r$year
  attr(wave_nets, "type_conflicts") <- type_conflicts
  wave_nets
}

# build + diagnostics ------------------------------------------------------
tergm_nets <- set_names(unique(eligible$region)) |> map(build_region)

diagnostics <- imap_dfr(tergm_nets, \(lst, reg) {
  tibble(
    region = reg,
    year = as.integer(names(lst)),
    n_nodes_padded = network.size(lst[[1]]),
    n_present = map_int(lst, \(n) sum(get.vertex.attribute(n, "present"))),
    n_edges = map_int(lst, network.edgecount),
    density = map_dbl(lst, network.density),
    # tie persistence vs. previous wave (Jaccard)
    jaccard_prev = c(NA, map_dbl(seq_len(length(lst) - 1), \(i) {
      a <- as.matrix(lst[[i]]); b <- as.matrix(lst[[i + 1]])
      sum(a & b) / sum(a | b)
    })),
    type_conflicts = attr(lst, "type_conflicts")
  )
})
print(diagnostics, n = Inf)

# save ---------------------------------------------------------------------
iwalk(tergm_nets, \(lst, reg) saveRDS(lst, file.path(out_dir, paste0(reg, ".RDS"))))
write_csv(diagnostics, "output/tergm_prep_diagnostics.csv")
