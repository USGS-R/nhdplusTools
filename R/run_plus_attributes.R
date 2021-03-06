par_make_subnet <- function(out, g, vs, net_new) {

  dfs <- igraph::dfs(g, which(vs == as.character(out)),
                     "in", unreachable = FALSE)

  subnet <- dplyr::filter(net_new, .data$comid %in% as.integer(names(dfs$order[!is.na(dfs$order)])))


  dplyr::mutate(dplyr::select(subnet, ID = .data$comid, toID = .data$tocomid,
                              nameID = .data$nameID, weight = .data$weight),
                nameID = as.character(.data$nameID))
}

split_network <- function(net, cl = NULL) {

  g <- igraph::graph_from_data_frame(select(net, .data$comid, .data$tocomid), directed = TRUE)

  vs <- names(igraph::V(g))

  if(!is.null(cl)) {
    cl <- get_cl(cl)
    on.exit(parallel::stopCluster(cl))
  }

  outlets <- net$comid[net$tocomid == 0 | is.na(net$tocomid)]

  lp <- pbapply::pblapply(cl = cl, X = outlets,
                            FUN = par_make_subnet, g = g,
                            vs = vs, net_new = net)

  return(lp)
}

run_small <- function(small_lp, override, cl) {
  if(!is.null(cl)) {
    cl <- parallel::makeCluster(cl)
    on.exit(parallel::stopCluster(cl))
  }

  small_lp <- parallel::parLapply(cl = cl, X = small_lp,
                                  fun = function(x, override) {
                                    nhdplusTools::get_levelpaths(x, override)
                                  },
                                  override = override)

}

combine_networks <- function(lp) {
  # ts stands for toposort here. Given that the networks retrieved above are
  # independent, we need to lag them so they don't have overlapping identifiers.
  start_ts <- 0

  for(i in 1:length(lp)) {

    lp[[i]]$levelpath <- lp[[i]]$levelpath + start_ts
    lp[[i]]$topo_sort <- lp[[i]]$topo_sort + start_ts

    start_ts <- max(lp[[i]]$topo_sort)

  }

  lp <- lapply(lp, function(x) {
    mutate(x, terminalpath = min(topo_sort))
  })

  bind_rows(lp)
}

#' Add NHDPlus Network Attributes to a provided network.
#' @description Given a river network with required base attributes, adds the
#' NHDPlus network attributes: hydrosequence, levelpath, terminalpath, pathlength,
#' down levelpath, down hydroseq, total drainage area, and terminalflag.
#' The function implements two parallelization schemes for small and large basins
#' respectively. If a number of cores is specified, parallel execution will be used.
#'
#' @param net data.frame containing comid, tocomid, nameID, lengthkm, and areasqkm.
#' Additional attributes will be passed through unchanged.
#' tocomid == 0 is the convention used for outlets.
#' If a "weight" column is provided, it will be used in \link{get_levelpaths}
#' otherwise, arbolate sum is calculated for the network and used as the weight.
#'
#' @param override numeric factor to be passed to \link{get_levelpaths}
#' @param cores integer number of processes to spawn if run in parallel.
#' @param split_temp character path to optional temporary copy of the network
#' split into independent sub-networks. If it exists, it will be read from disk
#' rather than recreated.
#' @param status logical should progress be printed?
#' @return data.frame with added attributes
#' @export
#' @examples
#'
#' source(system.file("extdata", "walker_data.R", package = "nhdplusTools"))
#'
#' test_flowline <- prepare_nhdplus(walker_flowline, 0, 0, FALSE)
#'
#' test_flowline <- data.frame(
#'   comid = test_flowline$COMID,
#'   tocomid = test_flowline$toCOMID,
#'   nameID = walker_flowline$GNIS_ID,
#'   lengthkm = test_flowline$LENGTHKM,
#'   areasqkm = walker_flowline$AreaSqKM)
#'
#' add_plus_network_attributes(test_flowline)

add_plus_network_attributes <- function(net, override = 5,
                                        cores = NULL, split_temp = NULL,
                                        status = TRUE) {

  if(!status) {
    old_opt <- pbapply::pboptions(type = "none")
    on.exit(pbapply::pboptions(type = old_opt$type))
  }

  net$tocomid[is.na(net$tocomid)] <- 0

  rename_arb <- FALSE

  if(!"weight" %in% names(net)) {
    net$weight <- calculate_arbolate_sum(
      select(net, ID = .data$comid,
             toID = .data$tocomid, length = .data$lengthkm))
    rename_arb <- TRUE
  }

  if(!is.null(split_temp) && file.exists(split_temp)) {
    lp <- readRDS(split_temp)
  } else {
    lp <- split_network(net, cl = cores)

    if(!is.null(split_temp)) {
      saveRDS(lp, split_temp)
    }
  }

  if(!is.null(cores)) {

    rows <- sapply(lp, nrow)

    small_lp <- lp[rows <= 20000]
    lp <- lp[rows > 20000]

  }

  lp <- pbapply::pblapply(X = lp,
                          FUN = function(x, override, cores) {
                            nhdplusTools::get_levelpaths(x,
                                                         override_factor = override,
                                                         cores = cores)
                          },
                          override = override, cores = cores)

  if(!is.null(cores)) {

    lp <- c(lp, run_small(small_lp, override, cores))

  }

  lp <- combine_networks(lp)

  net <- net %>%
    left_join(select(lp,
                     comid = .data$ID, terminalpa = .data$terminalpath,
                     hydroseq = .data$topo_sort, levelpathi = .data$levelpath),
              by = "comid")

  in_pathlength <- select(net, ID = .data$comid, toID = .data$tocomid, length = .data$lengthkm)

  pathlength <- get_pathlength(in_pathlength)

  pathlength <- distinct(pathlength) %>%
    filter(!is.na(.data$pathlength))

  net <- left_join(net,
                       select(pathlength,
                              comid = .data$ID,
                              .data$pathlength),
                       by = "comid")

  dn_lp <- net %>%
    left_join(select(net,
                     .data$comid, dnlevelpat = .data$levelpathi),
              by = c("tocomid" = "comid"), ) %>%
    filter(!is.na(.data$dnlevelpat)) %>%
    select(.data$comid, .data$dnlevelpat)

  net <- left_join(net, dn_lp, by = "comid") %>%
    mutate(dnlevelpat = ifelse(is.na(.data$dnlevelpat), 0, .data$dnlevelpat))

  dn_hs <- net %>%
    left_join(select(net,
                     .data$comid, dnhydroseq = .data$hydroseq),
              by = c("tocomid" = "comid")) %>%
    select(.data$comid, .data$dnhydroseq)

  net <- left_join(net, dn_hs, by = "comid") %>%
    mutate(dnhydroseq = ifelse(is.na(.data$dnhydroseq), 0, .data$dnhydroseq))

  net$totdasqkm <- calculate_total_drainage_area(
    select(net, ID = .data$comid, toID = .data$tocomid, area = .data$areasqkm)
  )

  net <- net %>%
    group_by(.data$terminalpa) %>%
    mutate(terminalfl = ifelse(.data$hydroseq == min(.data$hydroseq), 1, 0)) %>%
    ungroup()

  net
}
