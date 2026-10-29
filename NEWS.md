# rpyodide 0.1.0

* Initial version: call Python (Pyodide) from R in webR, with a
  reticulate-style API.
* `py_run_string()`, `py_run_file()`, `py_eval()`, `import()`, `py`,
  `r_to_py()`, `py_to_r()`, `tuple()`, `dict()`, and `$`, `[[`, `[` on Python
  objects.
* Conversions for vectors, lists, matrices and arrays (NumPy), data frames
  (pandas), `POSIXct` and `difftime`, and pandas Series (named by their index).
* `py_require()` declares Python requirements, like
  `reticulate::py_require()`, including `deps = FALSE` for packages whose pins
  can't be met in Pyodide. `py_install()` installs packages with `micropip`.
* Several independent Python sessions: `pyodide_start()`, `use_pyodide()`,
  `pyodide_stop()`, `pyodide_sessions()`.
* Files whose paths are passed to Python are copied from webR's file system
  to Pyodide's; `py_upload()` copies other files.
* `cpython_start()` runs the same Python bridge in a local CPython process,
  so `rpyodide` (and code using it) can be tested outside webR, including on
  CRAN.
