#' Run Python code
#'
#' `py_run_string()` runs code in the `__main__` module, like
#' `reticulate::py_run_string()`. `py_eval()` evaluates a single expression and
#' returns its value. Pyodide packages that the code imports (for example
#' `numpy`) are loaded automatically. Anything printed by Python appears in R.
#'
#' @param code Python code.
#' @param file A file in webR's virtual file system.
#' @param convert Convert results to R values where possible? If `FALSE`,
#'   Python objects are returned.
#' @param session Pyodide session; defaults to the active one.
#' @return `py_run_string()` and `py_run_file()` return the `__main__` module,
#'   invisibly. `py_eval()` returns the value of the expression.
#' @export
py_run_string <- function(code, convert = TRUE, session = NULL) {
  session <- resolve_session(session)
  py_request(list(op = "exec", code = paste(code, collapse = "\n")), session = session)
  invisible(import_main(convert = convert, session = session))
}

#' @rdname py_run_string
#' @export
py_run_file <- function(file, convert = TRUE, session = NULL) {
  py_run_string(readLines(file, warn = FALSE), convert = convert, session = session)
}

#' @rdname py_run_string
#' @export
py_eval <- function(code, convert = TRUE, session = NULL) {
  session <- resolve_session(session)
  val <- py_request(list(op = "eval", code = paste(code, collapse = "\n"), convert = convert),
                    session = session)
  enc_to_r(val, session, convert)
}

#' Import a Python module
#'
#' Imports a module, loading it from the Pyodide distribution first if
#' necessary. Use `$` to get its attributes.
#'
#' @param module Module name, e.g. `"numpy"` or `"os.path"`.
#' @param convert Convert values returned from this module to R?
#' @param session Pyodide session; defaults to the active one.
#' @return A Python module object.
#' @export
#' @examples
#' \dontrun{
#' np <- import("numpy")
#' np$linspace(0, 1, 5L)
#' }
import <- function(module, convert = TRUE, session = NULL) {
  session <- resolve_session(session)
  enc_to_r(py_request(list(op = "import", name = module), session = session), session, convert)
}

#' @rdname import
#' @export
import_main <- function(convert = TRUE, session = NULL) import("__main__", convert, session)

#' @rdname import
#' @export
import_builtins <- function(convert = TRUE, session = NULL) import("builtins", convert, session)

#' The Python `__main__` module
#'
#' `py$name` gets a variable from Python's `__main__` module in the active
#' session, and `py$name <- value` sets one.
#'
#' @format An object of class `pyodide_main`.
#' @export
py <- structure(list(), class = "pyodide_main")

#' @export
`$.pyodide_main` <- function(x, name) py_get_attr(import_main(), name)

#' @export
`[[.pyodide_main` <- function(x, name) py_get_attr(import_main(), name)

#' @export
`$<-.pyodide_main` <- function(x, name, value) {
  py_set_attr(import_main(), name, value)
  x
}

#' @export
`[[<-.pyodide_main` <- function(x, name, value) {
  py_set_attr(import_main(), name, value)
  x
}

#' @export
names.pyodide_main <- function(x) py_list_attributes(import_main())

#' @export
print.pyodide_main <- function(x, ...) {
  cat("<Python __main__ module of the active Pyodide session>\n")
  invisible(x)
}

#' @export
.DollarNames.pyodide_main <- function(x, pattern = "") {
  grep(pattern, names(x), value = TRUE)
}

#' Convert between R and Python
#'
#' `r_to_py()` converts an R value to a Python object; `py_to_r()` converts a
#' Python object to an R value. Vectors of length one become Python scalars,
#' longer vectors become lists, named vectors and lists become dicts, matrices
#' and arrays become NumPy arrays and data frames become pandas DataFrames.
#' Use [I()] to send a length-one vector as a list.
#'
#' @param x An R value or Python object.
#' @param convert For `r_to_py()`, should values returned from the new object
#'   be converted to R?
#' @param session Pyodide session; defaults to the active one.
#' @return `r_to_py()` returns a Python object; `py_to_r()` returns an R value.
#' @export
r_to_py <- function(x, convert = FALSE, session = NULL) {
  if (is_py_object(x)) return(x)
  session <- resolve_session(session)
  val <- py_request(list(op = "to_py", value = r_to_enc(x, session)), session = session)
  enc_to_r(val, session, convert)
}

#' @rdname r_to_py
#' @export
py_to_r <- function(x) UseMethod("py_to_r")

#' @export
py_to_r.default <- function(x) x

#' @export
py_to_r.pyodide_object <- function(x) obj_request(py_ref(x), "to_r", convert = TRUE)

#' Python tuples and dicts
#'
#' @param ... Values for the tuple, or `name = value` pairs for the dict.
#' @param session Pyodide session; defaults to the active one.
#' @return A Python object.
#' @export
tuple <- function(..., session = NULL) {
  py_call(py_get_attr(import_builtins(convert = FALSE, session = session), "tuple"),
          list(...))
}

#' @rdname tuple
#' @export
dict <- function(..., session = NULL) {
  py_call(py_get_attr(import_builtins(convert = FALSE, session = session), "dict"),
          list(...))
}

#' Install Python packages
#'
#' Installs packages into a Pyodide session with `micropip`. Packages built
#' for Pyodide (such as numpy, pandas and scikit-learn) come from the Pyodide
#' distribution; others come from PyPI and must be pure Python or have
#' WebAssembly wheels.
#'
#' @param packages Package names, optionally with version specifiers.
#' @param deps Also install the packages' dependencies? Use `FALSE` for
#'   packages whose pinned dependencies can't be met in Pyodide, after
#'   installing compatible versions of those dependencies yourself.
#' @param session Pyodide session; defaults to the active one.
#' @return `NULL`, invisibly.
#' @export
py_install <- function(packages, deps = TRUE, session = NULL) {
  py_request(list(op = "install", packages = I(as.character(packages)), deps = isTRUE(deps)),
             session = session)
  invisible()
}

#' Copy a file into Pyodide's file system
#'
#' webR and Pyodide have separate virtual file systems. Files whose absolute
#' paths are passed to Python as arguments are copied automatically (see
#' the `rpyodide.mirror_files` option); use `py_upload()` to copy other files,
#' such as Python modules to import.
#'
#' @param from Path of a file in webR's file system.
#' @param to Path in Pyodide's file system. Directories are created as needed.
#' @param session Pyodide session; defaults to the active one.
#' @return `to`, invisibly.
#' @export
py_upload <- function(from, to = normalizePath(from, mustWork = TRUE), session = NULL) {
  py_request(list(op = "write_file", path = to, data = encode_file(from)), session = session)
  invisible(to)
}

#' Is Python available?
#'
#' @param initialize Start the default session if none is running?
#' @return `TRUE` if a Pyodide session is running (or was started).
#' @export
py_available <- function(initialize = FALSE) {
  if (length(.rpyodide$sessions)) return(TRUE)
  if (!initialize || !is_webr()) return(FALSE)
  !inherits(try(resolve_session(), silent = TRUE), "try-error")
}

#' List installed Python packages
#'
#' @param session Pyodide session; defaults to the active one.
#' @return A data frame of package names, versions and sources.
#' @export
py_list_packages <- function(session = NULL) {
  session <- resolve_session(session)
  enc_to_r(py_request(list(op = "list_packages"), session = session), session, TRUE)
}

#' Is a Python module available?
#'
#' @param module Module name.
#' @param session Pyodide session; defaults to the active one.
#' @return `TRUE` if the module can be imported, either because it is
#'   installed or because it is in the Pyodide distribution.
#' @export
py_module_available <- function(module, session = NULL) {
  isTRUE(enc_to_r(py_request(list(op = "module_available", name = module), session = session),
                  NULL, TRUE))
}

#' Python configuration
#'
#' @param session Pyodide session; defaults to the active one.
#' @return A list with the Python and Pyodide versions and loaded packages.
#' @export
py_config <- function(session = NULL) {
  session <- resolve_session(session)
  cfg <- enc_to_r(py_request(list(op = "config"), session = session), session, TRUE)
  cfg$session <- session
  cfg$loaded_packages <- as.character(unlist(cfg$loaded_packages))
  structure(cfg, class = "pyodide_config")
}

#' @export
print.pyodide_config <- function(x, ...) {
  cat("session:  ", x$session, "\n",
      "python:   ", x$python, "\n",
      "pyodide:  ", x$pyodide, "\n",
      "platform: ", x$platform, "\n",
      "packages: ", if (length(x$loaded_packages)) paste(x$loaded_packages, collapse = ", ")
                    else "(none loaded)", "\n", sep = "")
  invisible(x)
}
