# Encode R values as the tagged JSON values understood by rpyodide_bridge.py,
# and decode the values it sends back. See that file for the format.

r_to_enc <- function(x, session) {
  if (is.null(x)) return(list(t = "null"))
  if (is_py_object(x)) return(list(t = "ref", id = py_ref(x, session)$id))
  if (inherits(x, "pyodide_main")) {
    return(list(t = "ref", id = py_ref(import_main(session = session), session)$id))
  }
  if (is.data.frame(x)) {
    out <- list(t = "df", names = I(names(x)),
                cols = unname(lapply(x, function(col) r_vec_enc(plain_column(col)))))
    if (.row_names_info(x) > 0L) out$rownames <- I(rownames(x))
    return(out)
  }
  if (is.factor(x) || inherits(x, c("Date", "POSIXlt"))) x <- plain_column(x)
  if (is.character(x) && length(x) == 1L) queue_file_mirror(x, session)
  if (is.atomic(x)) return(r_vec_enc(x))
  if (is.list(x)) {
    out <- list(t = "list", v = unname(lapply(x, r_to_enc, session = session)))
    if (!is.null(names(x))) out$names <- I(names(x))
    return(out)
  }
  if (is.function(x)) {
    stop("R functions can't be passed to Python (callbacks aren't supported).",
         call. = FALSE)
  }
  stop("Can't convert an object of class '", class(x)[[1]], "' to Python.", call. = FALSE)
}

plain_column <- function(x) {
  if (inherits(x, "POSIXlt")) x <- as.POSIXct(x)
  if (is.factor(x) || inherits(x, "Date")) {
    out <- as.character(x)
    dim(out) <- dim(x)
    names(out) <- names(x)
    return(out)
  }
  x
}

r_vec_enc <- function(x) {
  type <- typeof(x)
  if (!type %in% c("logical", "integer", "double", "character")) {
    stop("Can't convert R vectors of type '", type, "' to Python.", call. = FALSE)
  }
  out <- list(t = "vec", type = type, v = I(as.vector(unclass(x))))
  names(out$v) <- NULL
  if (type == "double") {
    nan <- which(is.nan(x))
    pinf <- which(x == Inf)
    ninf <- which(x == -Inf)
    if (length(nan)) out$nan <- I(nan - 1L)
    if (length(pinf)) out$pinf <- I(pinf - 1L)
    if (length(ninf)) out$ninf <- I(ninf - 1L)
  }
  if (!is.null(dim(x))) out$dim <- I(dim(x))
  if (!is.null(names(x))) out$names <- I(names(x))
  if (inherits(x, "AsIs")) out$asis <- TRUE
  if (inherits(x, "POSIXct")) out$posixct <- TRUE
  if (inherits(x, "difftime")) {
    out$v <- I(as.vector(as.double(x, units = "secs")))
    out$difftime <- TRUE
  }
  out
}

enc_to_r <- function(e, session, convert) {
  switch(e$t,
    null = NULL,
    vec = dec_vec(e),
    list = {
      v <- lapply(e$v, enc_to_r, session = session, convert = convert)
      if (!is.null(e$names)) names(v) <- as.character(unlist(e$names))
      v
    },
    df = dec_df(e, session, convert),
    ref = new_py_object(e, session, convert),
    stop("Unknown value from Python: '", e$t, "'.", call. = FALSE)
  )
}

dec_vec <- function(e) {
  v <- e$v
  v[vapply(v, is.null, logical(1))] <- NA
  v <- unlist(v)
  out <- switch(e$type,
    logical = as.logical(v),
    integer = as.integer(v),
    double = as.double(v),
    character = as.character(v)
  )
  if (e$type == "double") {
    out[unlist(e$nan) + 1L] <- NaN
    out[unlist(e$pinf) + 1L] <- Inf
    out[unlist(e$ninf) + 1L] <- -Inf
  }
  if (!is.null(e$dim)) dim(out) <- as.integer(unlist(e$dim))
  if (!is.null(e$names)) names(out) <- as.character(unlist(e$names))
  if (isTRUE(e$posixct)) out <- structure(out, class = c("POSIXct", "POSIXt"), tzone = "UTC")
  if (isTRUE(e$difftime)) out <- structure(out, class = "difftime", units = "secs")
  out
}

dec_df <- function(e, session, convert) {
  cols <- lapply(e$cols, enc_to_r, session = session, convert = convert)
  names(cols) <- as.character(unlist(e$names))
  n <- if (length(cols)) NROW(cols[[1]]) else 0L
  row_names <- if (is.null(e$rownames)) .set_row_names(n) else as.character(unlist(e$rownames))
  structure(cols, class = "data.frame", row.names = row_names)
}

# webR and Pyodide have separate virtual file systems. When R passes Python
# the absolute path of an existing file (e.g. a CSV written to tempdir()), copy
# the file to the same path in Pyodide, so Python code that opens it works.
# Unchanged files are only copied once. Turn this off with
# `options(rpyodide.mirror_files = FALSE)`.
queue_file_mirror <- function(path, session) {
  if (is.null(session) || is.na(path) || !isTRUE(getOption("rpyodide.mirror_files", TRUE)) ||
      !startsWith(path, "/") || nchar(path) > 4096L) {
    return(invisible())
  }
  # CPython sessions share R's file system
  if (identical(.rpyodide$sessions[[session]]$type, "cpython")) return(invisible())
  info <- suppressWarnings(file.info(path, extra_cols = FALSE))
  if (is.na(info$isdir) || info$isdir) return(invisible())
  max_bytes <- getOption("rpyodide.mirror_max_bytes", 512 * 1024^2)
  if (info$size > max_bytes) {
    warning("Not copying '", path, "' to Pyodide: it is larger than ",
            "getOption(\"rpyodide.mirror_max_bytes\").", call. = FALSE)
    return(invisible())
  }
  stamp <- paste(info$size, as.numeric(info$mtime))
  seen <- .rpyodide$mirrored[[session]]
  if (identical(seen[[path]], stamp)) return(invisible())
  .rpyodide$upload_queue[[path]] <- list(path = path, stamp = stamp, session = session)
  invisible()
}

encode_file <- function(path) {
  jsonlite::base64_enc(readBin(path, "raw", n = file.size(path)))
}

# Files queued for `session`, as request entries, and mark them as copied.
take_file_mirrors <- function(session) {
  queue <- Filter(function(f) identical(f$session, session), .rpyodide$upload_queue)
  .rpyodide$upload_queue[names(queue)] <- NULL
  lapply(unname(queue), function(f) {
    .rpyodide$mirrored[[session]][[f$path]] <- f$stamp
    list(path = f$path, data = encode_file(f$path))
  })
}
