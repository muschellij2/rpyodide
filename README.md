
<!-- README.md is generated from README.Rmd. Please edit that file -->

# rpyodide

<!-- badges: start -->
[![R-CMD-check](https://github.com/muschellij2/rpyodide/actions/workflows/R-CMD-check.yaml/badge.svg)](https://github.com/muschellij2/rpyodide/actions/workflows/R-CMD-check.yaml)
[![test-coverage](https://github.com/muschellij2/rpyodide/actions/workflows/test-coverage.yaml/badge.svg)](https://github.com/muschellij2/rpyodide/actions/workflows/test-coverage.yaml)
[![Codecov test coverage](https://codecov.io/gh/muschellij2/rpyodide/graph/badge.svg)](https://app.codecov.io/gh/muschellij2/rpyodide)
[![CRAN status](https://www.r-pkg.org/badges/version/rpyodide)](https://CRAN.R-project.org/package=rpyodide)
<!-- badges: end -->

`rpyodide` lets you call Python from R **in the web browser**. R runs in
[webR](https://docs.r-wasm.org/webr/) and Python runs in
[Pyodide](https://pyodide.org), both compiled to WebAssembly. The API
follows [reticulate](https://rstudio.github.io/reticulate/), so most
reticulate code works unchanged.

``` r
library(rpyodide)

py_run_string("x = [i ** 2 for i in range(5)]")
py$x

np <- import("numpy")             # loaded from the Pyodide distribution on first use
np$linalg$inv(matrix(c(2, 1, 1, 3), 2))

pd <- import("pandas", convert = FALSE)
df <- r_to_py(mtcars)             # data.frame -> pandas.DataFrame
py_to_r(df$describe())            # pandas.DataFrame -> data.frame

py_install("tabulate")            # micropip: Pyodide packages or pure-Python PyPI wheels
```

The project repository has a minimal working example: a web page
(`demo/index.html`) that installs `rpyodide` into webR and runs the code
above, with a box for your own code. It is tested in headless Chrome.

## Installation

`rpyodide` is a pure R package.
[R-universe](https://muschellij2.r-universe.dev) builds it for
WebAssembly, so in webR install it with:

``` r
webr::install("rpyodide", repos = c("https://muschellij2.r-universe.dev", "https://repo.r-wasm.org"))
```

It also installs in regular R, from GitHub or R-universe:

``` r
# install.packages("pak")
pak::pak("muschellij2/rpyodide")
```

Outside webR, Pyodide sessions can’t start, but [CPython
sessions](#testing-without-a-browser) can. `is_webr()` tells you which
situation you’re in.

### Requirements

- webR 0.6.0 or later, using its **SharedArrayBuffer channel**. The page
  must be cross-origin isolated, so it has to be served with these
  headers:

      Cross-Origin-Opener-Policy: same-origin
      Cross-Origin-Embedder-Policy: require-corp

  On hosts that can’t set headers, such as GitHub Pages, a service
  worker like
  [coi-serviceworker](https://github.com/gzuidhof/coi-serviceworker) can
  add them.

- Network access to the Pyodide distribution. By default that’s
  `https://cdn.jsdelivr.net/pyodide/v314.0.7/full/`. Change it with
  `options(rpyodide.pyodide_url = ...)` or
  `pyodide_start(pyodide_url = ...)`.

## How it works

     page (main thread)                 webR worker                  Pyodide
     ──────────────────                 ───────────                  ───────
     webR relays worker  <──────────── R: webr::eval_js(...)
     messages              postMessage(json, {async: false})
            │                           R blocks until a reply
            ▼
     shim worker (classic) ──► nested module worker: Pyodide + rpyodide_bridge.py
            ▲                                               │
            └──────────────── {uuid, result: json} ◄────────┘

- Inside the webR worker, webR replaces `Worker` with a proxy. The real
  worker runs on the page’s main thread, and
  `postMessage(msg, {async: false})` blocks until the worker replies.
  That makes R → Python calls synchronous, which is what a
  reticulate-style API needs.
- webR creates proxied workers from an untyped Blob, which browsers
  won’t run as module workers, and Pyodide needs a module worker. So
  each session is a small classic “shim” worker that starts Pyodide in a
  nested module worker and forwards messages.
- Requests and replies are JSON with tagged values (see
  `inst/python/rpyodide_bridge.py`). Python objects that can’t be
  converted stay in the worker, and R holds a numbered reference to
  them. When R garbage-collects a reference, the Python object is freed
  on the next call.

## Conversions

| R | Python | back to R |
|----|----|----|
| `NULL` | `None` | `NULL` |
| length-1 logical, integer, double, character | `bool`, `int`, `float`, `str` | same |
| longer vector | `list` | list |
| named vector or list | `dict` | named list |
| matrix or array | `numpy.ndarray` (column-major order is kept) | matrix or array |
| `data.frame` | `pandas.DataFrame` (row names become the index) | `data.frame` |
| `POSIXct` | `pandas.Timestamp`, or `datetime64[ns]` array | `POSIXct` (UTC) |
| `difftime` | seconds | `difftime` |
| factor, Date | `str` values | character |
| `I(x)` | always a `list` | list |
| `NA` / `NaN` / `Inf` | `None` or `nan` / `nan` / `inf` | `NA` / `NaN` / `Inf` |
|  | `pandas.Series` | vector, named by the index (unless it is a default 0, 1, 2, … index) |
|  | `pandas.Index`, `DatetimeIndex` | vector, `POSIXct` |

Whole-number doubles stay Python `float`s, as in reticulate, so use `5L`
where Python needs an `int`. Set `convert = FALSE` in `import()`,
`py_eval()` or `r_to_py()` to keep Python objects instead of converting
them.

## Files

webR and Pyodide have **separate virtual file systems**. When R passes
Python the absolute path of an existing file, such as a CSV that R wrote
to `tempdir()`, `rpyodide` copies the file to the same path in Pyodide
first. So `pd$read_csv(tempfile_path)` just works. A file is copied
again only if it changes. To copy other files, such as a Python module
to import, use `py_upload()`. Turn automatic copying off with
`options(rpyodide.mirror_files = FALSE)`. Files larger than
`getOption("rpyodide.mirror_max_bytes")` (512 MB by default) aren’t
copied.

## Python packages and `py_require()`

``` r
py_require(c("numpy", "pandas>=2"))   # recorded; installed when Python starts
py_require(python_version = ">=3.12") # checked: Pyodide ships one Python per release
py_require("stepcount", deps = FALSE) # install without its (unmeetable) pins
py_require()                          # show the requirements
```

As with `reticulate::py_require()`, requirements accumulate and are
installed when Python starts, or immediately if it is already running.
Packages built for Pyodide (numpy, scipy, pandas, scikit-learn, …) come
from the Pyodide distribution. Others come from PyPI and must be pure
Python or have WebAssembly wheels.

## Python environments

A Pyodide interpreter has **one** environment: one `site-packages`, and
one version of each package. To get separate environments, `rpyodide`
runs one Pyodide per web worker:

``` r
pyodide_start("ml", packages = "scikit-learn")
pyodide_start("plain", lockfile_url = "https://example.org/pinned/pyodide-lock.json")
use_pyodide("ml")                  # make "ml" the active session
py_eval("1 + 1", session = "plain")
pyodide_sessions()
pyodide_stop("plain")
```

Objects belong to the session that made them, and using one in another
session is an error.

## Testing without a browser

`cpython_start()` runs the same Python bridge in a local CPython process
instead of Pyodide, so code written for `rpyodide` can be tested in
regular R, in continuous integration and on CRAN:

``` r
cpython_start("test")          # needs processx and Python >= 3.8
py_eval("[x ** 2 for x in range(3)]")
pyodide_stop("test")
```

`rpyodide`’s own tests use this. They run wherever Python is installed
and are skipped where it isn’t. Tests that need NumPy or pandas are
skipped if those aren’t installed. In CPython sessions, packages come
from the local Python (install them with pip), and files aren’t copied
because Python shares R’s file system.

## Using reticulate and rpyodide from one package

Most of `rpyodide`’s function names match reticulate’s, so a package can
choose its Python backend at run time:

``` r
py_backend <- function() {
  if (identical(R.version$os, "emscripten")) asNamespace("rpyodide")
  else asNamespace("reticulate")
}

np <- py_backend()$import("numpy")
```

List `rpyodide` in `Suggests`. See the `webr` branch of
[stepcount](https://github.com/jhuwit/stepcount) for a full example:
both of its models (a random forest and a PyTorch network) run in the
browser, and the results are identical to those on the desktop.

## Differences from reticulate

- **Where it runs:** only in webR, in a cross-origin isolated page.
- **Python version:** each Pyodide release ships exactly one Python.
  `python_version` in `py_require()` is a check, not a choice.
- **Packages:** packages with compiled code need a Pyodide or
  WebAssembly build. There is none for PyTorch, numba or hmmlearn, for
  example. Exact version pins often can’t be met, so use `deps = FALSE`
  and require compatible versions yourself.
- **Files:** the file systems are separate; see [Files](#files). Files
  that Python writes aren’t copied back to R.
- **Network:** Python has no sockets, so `urllib` and `requests` don’t
  work. Downloads have to go through the browser (for example
  `pyodide.http`) and are subject to the server’s CORS rules.
- **Data transfer:** values are copied as JSON. Nothing is shared in
  memory, so large arrays and data frames are slower than with
  reticulate.
- **Blocking:** R waits for each Python call to finish, and a running
  Python call can’t be interrupted.
- **Output:** Python’s printed output appears in R when the call
  finishes, not as it is printed.
- **Not implemented yet:** R functions as Python callbacks
  (`py_func()`), iterators and generators (`iterate()`), `with()`,
  Python operators on objects (`+`, `==`, …), `py_capture_output()`,
  `virtualenv_*()` and `conda_*()`. Use Pyodide sessions instead of
  environments.
- **Package loading:** Pyodide packages load automatically for `import`
  statements, `import()` and NumPy/pandas conversions. Imports Pyodide
  can’t see, such as `__import__("x")`, need `py_install()` or
  `py_require()` first.

## Future work

- **Faster data transfer.** As an option, send data frames and numeric
  vectors as **Arrow IPC** instead of JSON. The pieces exist on both
  sides: [nanoarrow](https://arrow.apache.org/nanoarrow/) is built for
  webR, and `pyarrow` is in the Pyodide distribution (the full R `arrow`
  package isn’t built for webR). It would only be used when both are
  installed, and it would remove most of the JSON encoding cost. Parquet
  through `duckdb` (available on both sides) is another option for very
  large tables. A lighter, dependency-free first step is to send numeric
  vectors as base64 binary rather than JSON numbers.
- **Callbacks** from Python to R, using the same synchronous messaging
  in the other direction.
- **Copying files from Python back to R**, and an option to share a
  mounted folder.
- Iterators, operators, `with()`, `py_capture_output()` and more of
  reticulate’s API.
- **Interrupting** long Python calls (Pyodide supports interrupts
  through a SharedArrayBuffer).
- Streaming Python output while a call runs.
- Testing in Firefox and Safari. So far `rpyodide` has only been tested
  in Chrome.
- Builds on [R-universe](https://r-universe.dev), which builds
  WebAssembly binaries automatically.

## CRAN

`R CMD check --as-cran` passes. The package is pure R, and its only
imports are `jsonlite` and `utils`. CRAN’s machines have Python, so the
tests run the R code and the Python bridge together against CPython (see
[Testing without a browser](#testing-without-a-browser)). What CRAN
can’t test:

- The browser part: the JavaScript glue and Pyodide itself. Those are
  tested in headless Chrome (`dev/` and `demo/` in the [project
  repository](https://github.com/muschellij2/rpyodide)), and examples
  that need webR are wrapped in `\dontrun{}`.
- The browser part relies on webR’s worker proxy (synchronous
  `postMessage`), which is a webR internal, not a documented API, and
  could change in a new webR release.
- Pyodide is downloaded from a CDN when a session starts.

webR users install packages from webR repositories (repo.r-wasm.org,
R-universe), so R-universe is how they get `rpyodide` either way.
