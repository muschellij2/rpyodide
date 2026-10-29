# Tests that talk to Python use a local CPython session (see cpython_start()),
# so they run wherever Python is installed, including CRAN. They are skipped
# when Python or processx is missing.
skip_if_no_python <- function() {
  skip_if_not_installed("processx")
  skip_if(!nzchar(find_python()), "Python 3.8+ isn't available")
}

# Start (once) the CPython session the tests share.
use_test_python <- function() {
  skip_if_no_python()
  if (!"rpyodide-test" %in% pyodide_sessions()$name) cpython_start("rpyodide-test")
  use_pyodide_session("rpyodide-test")
}

use_pyodide_session <- function(name) {
  state <- rpyodide:::.rpyodide
  state$active <- name
}

skip_if_no_module <- function(module) {
  skip_if_not(py_module_available(module), paste("Python module", module, "isn't installed"))
}
