# build_igraphs.R
# Builds igraph network objects from the disambiguated textnet_extract RDS
# files produced by disambiguate_nodelists.R. For each Region_Year, writes
# two igraph variants:
#
#   1. igraph_objects/multiplex/extract_<Region_Year>.RDS
#        One edge per SVO triple from the extract — multi-edges between the
#        same source/target pair are preserved. All verb-level edge
#        attributes ride along on the edges.
#
#   2. igraph_objects/uniplex/extract_<Region_Year>.RDS
#        The multiplex graph collapsed via igraph::simplify(): verb-specific
#        edge attributes dropped, each edge weight = 1, and parallel edges
#        folded into one with weight = count of merged edges. Self-loops kept.
#
# Pre-graph filtering (kept here, not in the disambig step, because these are
# graph-construction prep — the disambiguated RDS is the source of truth and
# is not modified):
#   - drop edges where source OR target is NA (graph_from_data_frame rejects
#     NA endpoints; a half-NA edge isn't traversable).
#   - drop edges/nodes whose entity name has fewer than 2 a-z letters.
#   - drop nodelist rows where entity_name is NA.
#   - keep ALL remaining nodelist rows as vertices, even those in no edge —
#     they appear as isolates.
#   - dedup nodelist by canonical entity_name (the disambig step may emit
#     several rows that collapsed to the same canonical).
#
# Ported from kings core_code step5_build_igraphs.R.
# Run from the repo root:  Rscript code/build_igraphs.R

overwrite <- FALSE   # TRUE to rebuild graphs that already exist

library(igraph)
library(stringr)
library(data.table)

source("code/utils.R")   # atomic_saveRDS()

disambig_dir  <- "tijuanabox/int_data/disambiguated_extracted_networks"
multiplex_dir <- "tijuanabox/int_data/igraph_objects/multiplex"
uniplex_dir   <- "tijuanabox/int_data/igraph_objects/uniplex"
dir.create(multiplex_dir, recursive = TRUE, showWarnings = FALSE)
dir.create(uniplex_dir,   recursive = TRUE, showWarnings = FALSE)

# Edge attributes that describe a single SVO triple and don't aggregate
# meaningfully across collapsed parallel edges. Dropped before simplify().
verb_edge_attrs <- c(
  "head_verb_id", "head_verb_tense", "head_verb_name", "head_verb_lemma",
  "parent_verb_id", "neg",
  "doc_sent_verb", "doc_sent_parent",
  "helper_lemma", "helper_token",
  "xcomp_verb", "xcomp_helper_lemma", "xcomp_helper_token",
  "edgeiscomplete", "has_hedge", "is_future"
)

build_graphs <- function(edgenodelist) {
  edgelist <- as.data.table(edgenodelist$edgelist)
  nodelist <- as.data.table(edgenodelist$nodelist)

  n_edges_in <- nrow(edgelist)
  n_nodes_in <- nrow(nodelist)

  # Drop edges with a NA endpoint.
  edgelist <- edgelist[!is.na(source) & !is.na(target)]
  n_after_NA <- nrow(edgelist)

  # Drop edges/nodes whose entity name has <2 a-z letters.
  edgelist[, esletters := str_remove_all(source,      "[^a-z_]")]
  edgelist[, etletters := str_remove_all(target,      "[^a-z_]")]
  nodelist[, nletters  := str_remove_all(entity_name, "[^a-z_]")]
  edgelist <- edgelist[nchar(esletters) > 1L & nchar(etletters) > 1L]
  nodelist <- nodelist[!is.na(entity_name) & nchar(nletters) > 1L]
  edgelist[, c("esletters", "etletters") := NULL]
  nodelist[, nletters := NULL]

  # Dedup nodelist by canonical entity_name for unique vertex IDs.
  n_nodes_pre_dedup <- nrow(nodelist)
  nodelist <- unique(nodelist, by = "entity_name")

  message(sprintf(
    "    edges: %d in, %d after NA filter, %d after letter filter (dropped %d, %.0f%%)",
    n_edges_in, n_after_NA, nrow(edgelist),
    n_edges_in - nrow(edgelist),
    100 * (n_edges_in - nrow(edgelist)) / max(n_edges_in, 1)))
  message(sprintf(
    "    nodes: %d in, %d after letter filter, %d after canonical dedup (dropped %d, %.0f%%)",
    n_nodes_in, n_nodes_pre_dedup, nrow(nodelist),
    n_nodes_in - nrow(nodelist),
    100 * (n_nodes_in - nrow(nodelist)) / max(n_nodes_in, 1)))

  # graph_from_data_frame() expects source/target as the first two columns.
  other_cols <- setdiff(names(edgelist), c("source", "target"))
  edgelist   <- edgelist[, c("source", "target", other_cols), with = FALSE]

  # === Multiplex directed (one edge per row) ===
  multiplex <- igraph::graph_from_data_frame(edgelist,
                                             vertices = nodelist,
                                             directed = TRUE)

  # === Uniplex weighted (collapse parallel edges, weight = count) ===
  uniplex <- multiplex
  for (a in verb_edge_attrs) {
    if (a %in% igraph::edge_attr_names(uniplex)) {
      uniplex <- igraph::delete_edge_attr(uniplex, a)
    }
  }
  igraph::E(uniplex)$weight <- 1
  uniplex <- igraph::simplify(uniplex,
                              edge.attr.comb = list(weight = "sum"),
                              remove.loops   = FALSE)

  list(multiplex = multiplex, uniplex = uniplex)
}

disambig_files <- list.files(disambig_dir, pattern = "\\.RDS$", full.names = TRUE)
cat(sprintf("Found %d disambiguated extract(s) in %s\n",
            length(disambig_files), disambig_dir))

built <- skipped <- failed <- 0L

for (f in disambig_files) {
  stem           <- str_remove(basename(f), "\\.RDS$")   # extract_<Region_Year>
  multiplex_path <- file.path(multiplex_dir, paste0(stem, ".RDS"))
  uniplex_path   <- file.path(uniplex_dir,   paste0(stem, ".RDS"))

  if (!overwrite && file.exists(multiplex_path) && file.exists(uniplex_path)) {
    skipped <- skipped + 1L
    next
  }

  message("Building graphs: ", stem)
  res <- tryCatch({
    build_graphs(readRDS(f))
  }, error = function(e) {
    message("  ERROR (", stem, "): ", conditionMessage(e))
    NULL
  })

  if (is.null(res)) { failed <- failed + 1L; next }

  atomic_saveRDS(res$multiplex, multiplex_path)
  atomic_saveRDS(res$uniplex,   uniplex_path)
  message(sprintf("  -> %d vertices, %d multiplex edges, %d uniplex edges",
                  igraph::vcount(res$multiplex),
                  igraph::ecount(res$multiplex),
                  igraph::ecount(res$uniplex)))
  built <- built + 1L
}

cat(sprintf("\nDone. Built: %d  Skipped: %d  Failed: %d\n",
            built, skipped, failed))
