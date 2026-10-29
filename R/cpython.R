#' Start a session backed by a local CPython
#'
#' Runs rpyodide's Python bridge in a regular Python process instead of
#' Pyodide, talking to it over stdin and stdout. Everything else works the
#' same way, so code written for rpyodide (and rpyodide itself) can be tested
#' outside webR, for example on CRAN or in continuous integration. This needs
#' the processx package and Python 3.8 or later.
#'
#' Differences from Pyodide sessions: packages come from the Python
#' installation (use pip; [py_install()] and [py_require()] can't install
#' them), files aren't copied because Python shares R's file system, and the
#' Python version is the local one.
#'
#' @param name Session name.
#' @param python Path to the Python executable. By default, the first of
#'   `python3` and `python` found on the `PATH`.
#' @param activate Make this the active session?
#' @return The session, invisibly.
#' @seealso [pyodide_start()] for Python in webR.
#' @export
#' @examples
#' if (nzchar(find_python()) && requireNamespace("processx", quietly = TRUE)) {
#'   cpython_start("example")
#'   py_eval("1 + 1", session = "example")
#'   pyodide_stop("example")
#' }
cpython_start <- function(name = "cpython", python = find_python(), activate = TRUE) {
  if (!requireNamespace("processx", quietly = TRUE)) {
    stop("cpython_start() needs the processx package.", call. = FALSE)
  }
  if (!nzchar(python)) stop("Python wasn't found.", call. = FALSE)
  if (!is.null(.rpyodide$sessions[[name]])) {
    stop("A session named '", name, "' is already running.", call. = FALSE)
  }
  server <- system.file("python", "rpyodide_stdio.py", package = "rpyodide", mustWork = TRUE)
  log <- tempfile("rpyodide-", fileext = ".log")
  proc <- processx::process$new(python, c("-u", "-B", server),
                                stdin = "|", stdout = "|", stderr = log)
  sess <- structure(list(name = name, token = paste0(name, ":", as.numeric(Sys.time())),
                         type = "cpython", pyodide_url = NA_character_, process = proc,
                         log = log),
                    class = "pyodide_session")
  .rpyodide$sessions[[name]] <- sess
  if (activate || is.null(.rpyodide$active)) .rpyodide$active <- name
  tryCatch(py_request(list(op = "config"), session = name), error = function(e) {
    pyodide_stop(name)
    stop(e)
  })
  invisible(sess)
}

#' @describeIn cpython_start The Python executable `cpython_start()` uses by
#'   default, or `""` if there is none.
#' @export
find_python <- function() {
  for (exe in c("python3", "python")) {
    path <- Sys.which(exe)
    # Windows' "python3" may be a Microsoft Store stub; check that it runs.
    if (nzchar(path) && python_ok(path)) return(unname(path))
  }
  ""
}

python_ok <- function(path) {
  out <- tryCatch(
    suppressWarnings(system2(path, c("-c", shQuote("import sys; print(sys.version_info >= (3, 8))")),
                             stdout = TRUE, stderr = FALSE)),
    error = function(e) "")
  identical(out, "True")
}

cpython_request <- function(sess, payload) {
  proc <- sess$process
  check_alive <- function() {
    if (!proc$is_alive()) {
      log <- if (file.exists(sess$log)) paste(readLines(sess$log, warn = FALSE), collapse = "\n")
      stop("The Python process for session '", sess$name, "' has exited.\n", log,
           call. = FALSE)
    }
  }
  check_alive()
  rest <- proc$write_input(paste0(payload, "\n"))
  while (length(rest)) {
    proc$poll_io(1000)
    rest <- proc$write_input(rest)
  }
  repeat {
    line <- proc$read_output_lines(n = 1)
    if (length(line)) return(line)
    check_alive()
    proc$poll_io(1000)
  }
}
