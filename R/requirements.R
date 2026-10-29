#' Declare Python requirements
#'
#' Like `reticulate::py_require()`: declare the Python packages (and Python
#' version) that your code needs, before or after Python has started.
#' Requirements are kept per session and accumulate across calls.
#'
#' * Before the session starts, requirements are only recorded. When
#'   [pyodide_start()] runs (or Python is first used), they are all installed
#'   with a single `micropip` call and the Python version is checked.
#' * After the session has started, new packages are installed right away.
#'   Packages that are already loaded can't be removed, so `action = "remove"`
#'   and `action = "set"` must not drop packages from a running session; stop
#'   it with [pyodide_stop()] first.
#'
#' Requirements survive [pyodide_stop()], so restarting a session installs them
#' again.
#'
#' Each Pyodide release ships exactly one Python version, so `python_version`
#' can't choose an interpreter. It is a check: if the session's Python doesn't
#' satisfy it, `py_require()` (or [pyodide_start()]) fails. To get a different
#' Python, start the session with a different `pyodide_url`.
#'
#' @param packages Package requirements, such as `"numpy"` or `"pandas>=2"`.
#'   Packages in the Pyodide distribution are used when available; others come
#'   from PyPI and must be pure Python or have WebAssembly wheels. Requiring a
#'   package that is already listed replaces its version specifier.
#' @param python_version Python version constraints, such as `">=3.12"`,
#'   `"3.14"` or `">=3.12,<3.15"`.
#' @param deps Install the packages' dependencies too? Packages required with
#'   `deps = FALSE` are kept in a separate list and installed after the others,
#'   without their dependencies. Use this for packages whose pinned
#'   dependencies (or `Requires-Python`) can't be met in Pyodide, and require
#'   compatible versions of those dependencies normally.
#' @param action `"add"` to add requirements, `"remove"` to remove them (by
#'   package name) or `"set"` to replace the list.
#' @param session Session name. Defaults to the active session, or
#'   `"default"` if no session has started.
#' @return With no `packages` or `python_version`, the session's requirements.
#'   Otherwise they are returned invisibly.
#' @export
#' @examples
#' py_require(c("numpy", "pandas>=2"), session = "example")
#' py_require(python_version = ">=3.12", session = "example")
#' py_require(session = "example")
py_require <- function(packages = NULL, python_version = NULL, deps = TRUE,
                       action = c("add", "remove", "set"), session = NULL) {
  action <- match.arg(action)
  field <- if (isTRUE(deps)) "packages" else "no_deps"
  if (is.null(session)) session <- if (is.null(.rpyodide$active)) "default" else .rpyodide$active
  old <- get_requirements(session)
  if (is.null(packages) && is.null(python_version)) {
    if (action != "set") return(old)
    packages <- character()
  }
  new <- old
  new[[field]] <- update_specs(old[[field]], as.character(packages), action, by_name = TRUE)
  new$python_version <- update_specs(old$python_version, as.character(python_version), action)

  if (!is.null(.rpyodide$sessions[[session]])) {
    dropped <- setdiff(package_name(old[[field]]), package_name(new[[field]]))
    if (length(dropped)) {
      stop("Can't remove packages (", paste(dropped, collapse = ", "),
           ") from the running Pyodide session '", session, "'. ",
           "Stop it with pyodide_stop() and require again.", call. = FALSE)
    }
    check_python_version(new$python_version, session_python_version(session), session)
    added <- setdiff(new[[field]], old[[field]])
    .rpyodide$requirements[[session]] <- new
    if (length(added)) py_install(added, deps = deps, session = session)
  } else {
    .rpyodide$requirements[[session]] <- new
  }
  invisible(get_requirements(session))
}

get_requirements <- function(session) {
  req <- .rpyodide$requirements[[session]]
  structure(list(session = session,
                 packages = as.character(req$packages),
                 no_deps = as.character(req$no_deps),
                 python_version = as.character(req$python_version),
                 started = !is.null(.rpyodide$sessions[[session]])),
            class = "pyodide_requirements")
}

#' @export
print.pyodide_requirements <- function(x, ...) {
  cat("Python requirements for Pyodide session '", x$session, "'",
      if (x$started) "" else " (not started)", "\n", sep = "")
  cat("  packages:       ",
      if (length(x$packages)) paste(x$packages, collapse = ", ") else "(none)", "\n", sep = "")
  if (length(x$no_deps)) {
    cat("  without deps:   ", paste(x$no_deps, collapse = ", "), "\n", sep = "")
  }
  cat("  python_version: ",
      if (length(x$python_version)) paste(x$python_version, collapse = ", ") else "(any)",
      "\n", sep = "")
  invisible(x)
}

# Normalised package name: "Scikit_Learn[extra]>=1.0" -> "scikit-learn".
package_name <- function(spec) {
  tolower(gsub("[-_.]+", "-", trimws(sub("[[<>=!~;@ ].*$", "", spec))))
}

update_specs <- function(old, new, action, by_name = FALSE) {
  key <- if (by_name) package_name else identity
  switch(action,
    add = unique(c(old[!key(old) %in% key(new)], new)),
    remove = old[!key(old) %in% key(new)],
    set = unique(new)
  )
}

# Install everything a newly started session requires.
apply_requirements <- function(session) {
  req <- get_requirements(session)
  if (length(req$python_version)) {
    tryCatch(
      check_python_version(req$python_version, session_python_version(session), session),
      error = function(e) {
        pyodide_stop(session)
        stop(e)
      }
    )
  }
  if (length(req$packages)) py_install(req$packages, session = session)
  if (length(req$no_deps)) py_install(req$no_deps, deps = FALSE, session = session)
  invisible()
}

session_python_version <- function(session) {
  sub(" .*$", "", py_config(session = session)$python)
}

check_python_version <- function(constraints, version, session = NULL) {
  if (!length(constraints)) return(invisible(TRUE))
  failed <- Filter(function(c) !python_version_satisfies(version, c), constraints)
  if (length(failed)) {
    stop("Pyodide session '", session, "' has Python ", version,
         ", which doesn't satisfy python_version '", paste(failed, collapse = "', '"), "'. ",
         "Each Pyodide release ships one Python; pick a release that matches with ",
         "pyodide_start(pyodide_url = ...).", call. = FALSE)
  }
  invisible(TRUE)
}

# Does `version` (e.g. "3.14.2") satisfy a constraint such as ">=3.12,<3.15"?
python_version_satisfies <- function(version, constraint) {
  v <- as.integer(strsplit(version, ".", fixed = TRUE)[[1]])
  parts <- trimws(strsplit(constraint, ",", fixed = TRUE)[[1]])
  all(vapply(parts, function(part) {
    m <- regmatches(part, regexec("^(>=|<=|==|!=|~=|>|<)?\\s*([0-9]+(\\.[0-9]+)*)$", part))[[1]]
    if (!length(m)) stop("Invalid python_version constraint: '", part, "'.", call. = FALSE)
    op <- if (nzchar(m[2])) m[2] else "=="
    target <- as.integer(strsplit(m[3], ".", fixed = TRUE)[[1]])
    prefix_match <- function(t) length(v) >= length(t) && all(v[seq_along(t)] == t)
    cmp <- compare_versions(v, target)
    switch(op,
      "==" = prefix_match(target),
      "!=" = !prefix_match(target),
      ">=" = cmp >= 0,
      "<=" = cmp <= 0,
      ">" = cmp > 0,
      "<" = cmp < 0,
      "~=" = length(target) >= 2 && cmp >= 0 && prefix_match(target[-length(target)])
    )
  }, logical(1)))
}

# Compare only as many components as the target has: 3.14.2 vs 3.14 is equal.
compare_versions <- function(v, target) {
  v <- c(v, rep(0L, max(0L, length(target) - length(v))))[seq_along(target)]
  d <- sign(v - target)
  if (any(d != 0)) d[d != 0][[1]] else 0
}
