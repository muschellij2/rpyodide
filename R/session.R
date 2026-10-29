.rpyodide <- new.env(parent = emptyenv())
.rpyodide$sessions <- list()
.rpyodide$active <- NULL
.rpyodide$pending_del <- list()
.rpyodide$last_error <- NULL
.rpyodide$requirements <- list()
.rpyodide$mirrored <- list()
.rpyodide$upload_queue <- list()
.rpyodide$glue <- FALSE

#' Default Pyodide distribution URL
#'
#' Pyodide is loaded from this URL unless `pyodide_url` is given to
#' [pyodide_start()]. Set `options(rpyodide.pyodide_url = ...)` to change it.
#' The URL must end in `/` and contain `pyodide.mjs`.
#'
#' @return A character string.
#' @export
default_pyodide_url <- function() {
  getOption("rpyodide.pyodide_url", "https://cdn.jsdelivr.net/pyodide/v314.0.7/full/")
}

#' Is R running in webR?
#'
#' @return `TRUE` when R is webR (R compiled to WebAssembly).
#' @export
is_webr <- function() {
  identical(R.version$os, "emscripten") && nzchar(system.file(package = "webr"))
}

assert_webr <- function() {
  if (!is_webr()) {
    stop("rpyodide only works inside webR (R compiled to WebAssembly) in a web browser.",
         call. = FALSE)
  }
}

eval_js <- function(code) {
  getExportedValue("webr", "eval_js")(code)
}

# A JSON string literal, which is also a valid JavaScript string literal.
js_string <- function(x) {
  as.character(jsonlite::toJSON(as.character(x), auto_unbox = TRUE))
}

to_json <- function(x) {
  as.character(jsonlite::toJSON(x, auto_unbox = TRUE, null = "null", na = "null",
                                digits = I(17)))
}

read_asset <- function(...) {
  path <- system.file(..., package = "rpyodide", mustWork = TRUE)
  paste(readLines(path, warn = FALSE, encoding = "UTF-8"), collapse = "\n")
}

install_glue <- function() {
  if (isTRUE(.rpyodide$glue)) return(invisible())
  status <- eval_js(read_asset("js", "glue.js"))
  if (identical(status, "no-proxy")) {
    stop("rpyodide needs webR's SharedArrayBuffer channel, so the page must be ",
         "cross-origin isolated (served with the headers ",
         "`Cross-Origin-Opener-Policy: same-origin` and ",
         "`Cross-Origin-Embedder-Policy: require-corp`).", call. = FALSE)
  }
  .rpyodide$glue <- TRUE
  invisible()
}

#' Start a Pyodide session
#'
#' Starts a Python interpreter (Pyodide) in its own web worker. Each session is
#' an independent Python environment with its own packages and globals, so
#' several sessions can act like separate virtual environments. Python
#' functions use the active session unless told otherwise. A `"default"`
#' session is started automatically the first time Python is used.
#'
#' @param name Session name.
#' @param packages Packages to require for this session; they are added to
#'   its [py_require()] list and installed once Python has started.
#' @param pyodide_url URL of the Pyodide distribution.
#' @param lockfile_url Optional URL of a `pyodide-lock.json` to pin package
#'   versions for this session.
#' @param activate Make this the active session?
#' @param timeout Seconds to wait for Pyodide to start.
#' @return The session, invisibly.
#' @export
pyodide_start <- function(name = "default", packages = character(),
                          pyodide_url = default_pyodide_url(), lockfile_url = NULL,
                          activate = TRUE, timeout = 300) {
  assert_webr()
  install_glue()
  sess <- .rpyodide$sessions[[name]]
  if (!is.null(sess)) {
    if (activate) .rpyodide$active <- name
    if (length(packages)) py_require(packages, session = name)
    return(invisible(sess))
  }
  if (length(packages)) py_require(packages, session = name)
  config <- list(pyodideUrl = pyodide_url, lockFileURL = lockfile_url,
                 bridge = read_asset("python", "rpyodide_bridge.py"))
  eval_js(sprintf("globalThis.__rpyodide.start(%s, %s, %s)", js_string(name),
                  js_string(read_asset("js", "pyodide-worker.mjs")), to_json(config)))
  started <- Sys.time()
  repeat {
    st <- jsonlite::fromJSON(eval_js(sprintf("globalThis.__rpyodide.poll(%s)", js_string(name))))
    if (identical(st$status, "ready")) break
    if (identical(st$status, "error") ||
        difftime(Sys.time(), started, units = "secs") > timeout) {
      eval_js(sprintf("globalThis.__rpyodide.stop(%s)", js_string(name)))
      stop("Pyodide session '", name, "' failed to start: ",
           if (nzchar(st$message)) st$message else "timed out", call. = FALSE)
    }
    Sys.sleep(0.1)
  }
  sess <- structure(list(name = name, token = paste0(name, ":", as.numeric(Sys.time())),
                         pyodide_url = pyodide_url),
                    class = "pyodide_session")
  .rpyodide$sessions[[name]] <- sess
  .rpyodide$mirrored[[name]] <- NULL
  if (activate || is.null(.rpyodide$active)) .rpyodide$active <- name
  apply_requirements(name)
  invisible(sess)
}

#' Choose the active Pyodide session
#'
#' @param name Name of a session started with [pyodide_start()]. If it hasn't
#'   been started yet, it is started.
#' @param ... Passed to [pyodide_start()] when the session is new.
#' @return The previously active session name, invisibly.
#' @export
use_pyodide <- function(name, ...) {
  old <- .rpyodide$active
  pyodide_start(name, activate = TRUE, ...)
  invisible(old)
}

#' Stop a Pyodide session
#'
#' Terminates the session's worker. Python objects from that session can no
#' longer be used.
#'
#' @param name Session name.
#' @return `NULL`, invisibly.
#' @export
pyodide_stop <- function(name = .rpyodide$active) {
  if (is.null(name) || is.null(.rpyodide$sessions[[name]])) return(invisible())
  eval_js(sprintf("globalThis.__rpyodide.stop(%s)", js_string(name)))
  .rpyodide$sessions[[name]] <- NULL
  .rpyodide$pending_del[[name]] <- NULL
  .rpyodide$mirrored[[name]] <- NULL
  if (identical(.rpyodide$active, name)) {
    .rpyodide$active <- if (length(.rpyodide$sessions)) names(.rpyodide$sessions)[[1]]
  }
  invisible()
}

#' List Pyodide sessions
#'
#' @return A data frame with one row per session.
#' @export
pyodide_sessions <- function() {
  nms <- names(.rpyodide$sessions)
  if (is.null(nms)) nms <- character()
  data.frame(name = nms, active = nms %in% .rpyodide$active,
             pyodide_url = vapply(.rpyodide$sessions, `[[`, "", "pyodide_url",
                                  USE.NAMES = FALSE),
             stringsAsFactors = FALSE)
}

#' @export
print.pyodide_session <- function(x, ...) {
  cat("<Pyodide session '", x$name, "'>\n", sep = "")
  invisible(x)
}

resolve_session <- function(session = NULL) {
  if (is.null(session)) {
    if (is.null(.rpyodide$active)) pyodide_start()
    return(.rpyodide$active)
  }
  if (is.null(.rpyodide$sessions[[session]])) {
    stop("No Pyodide session named '", session, "'. Start it with pyodide_start().",
         call. = FALSE)
  }
  session
}

session_token <- function(session) .rpyodide$sessions[[session]]$token

queue_delete <- function(session, token, id) {
  if (identical(session_token(session), token)) {
    .rpyodide$pending_del[[session]] <- c(.rpyodide$pending_del[[session]], id)
  }
}

# Send one request to a session and return the encoded value of the reply.
py_request <- function(req, session = NULL) {
  force(req)  # encoding the request queues the files it refers to
  session <- resolve_session(session)
  del <- .rpyodide$pending_del[[session]]
  if (length(del)) {
    req$del <- I(del)
    .rpyodide$pending_del[[session]] <- NULL
  }
  files <- take_file_mirrors(session)
  if (length(files)) req$files <- files
  res <- eval_js(sprintf("globalThis.__rpyodide.request(%s, %s)", js_string(session),
                         js_string(to_json(req))))
  res <- jsonlite::fromJSON(res, simplifyVector = FALSE)
  if (length(res$stdout) && nzchar(res$stdout)) cat(res$stdout)
  if (length(res$stderr) && nzchar(res$stderr)) cat(res$stderr, file = stderr())
  if (!isTRUE(res$ok)) raise_python_error(res$error)
  res$value
}

raise_python_error <- function(err) {
  .rpyodide$last_error <- err
  cond <- structure(
    class = c("pyodide_error", "error", "condition"),
    list(message = paste0(err$type, ": ", err$message,
                          "\nRun `rpyodide::py_last_error()` for the Python traceback."),
         call = NULL, type = err$type, traceback = err$traceback)
  )
  stop(cond)
}

#' The last Python error
#'
#' @return A list with the Python exception `type`, `message` and `traceback`,
#'   or `NULL` if there hasn't been an error.
#' @export
py_last_error <- function() {
  err <- .rpyodide$last_error
  if (!is.null(err)) class(err) <- "pyodide_last_error"
  err
}

#' @export
print.pyodide_last_error <- function(x, ...) {
  cat(x$traceback)
  invisible(x)
}
