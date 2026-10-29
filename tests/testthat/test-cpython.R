# The R API and the Python bridge together, against a local CPython.

test_that("scalars round-trip with their types", {
  use_test_python()
  py$a <- 1L; py$b <- 2.5; py$c <- TRUE; py$d <- "é ü 中"
  expect_identical(py_eval("[type(x).__name__ for x in (a, b, c, d)]"),
                   list("int", "float", "bool", "str"))
  expect_identical(py$d, "é ü 中")
  py$w <- 3
  expect_identical(py_eval("type(w).__name__"), "float")
  py$p <- pi
  expect_identical(py$p, pi)
})

test_that("vectors, lists and dicts", {
  use_test_python()
  py$v <- c(1, NA, NaN, Inf, -Inf)
  expect_identical(py_eval("[repr(x) for x in v]"), list("1.0", "nan", "nan", "inf", "-inf"))
  py$dd <- list(x = 1L, y = list("a", "b"))
  expect_identical(py_eval("sorted(dd.keys())"), list("x", "y"))
  expect_identical(py$dd$y, list("a", "b"))
  py$l1 <- I(5)
  expect_true(py_eval("isinstance(l1, list)"))
  expect_null(py_eval("None"))
})

test_that("py_run_string, stdout and errors", {
  use_test_python()
  expect_output(py_run_string("print('to stdout')"), "to stdout")
  e <- tryCatch(py_run_string("raise ValueError('bad value')"), error = identity)
  expect_s3_class(e, "pyodide_error")
  expect_identical(e$type, "ValueError")
  expect_match(conditionMessage(e), "bad value")
  expect_match(py_last_error()$traceback, "Traceback")
  expect_error(py$f <- function() 1, "callbacks")
})

test_that("modules, attributes, calls and keyword arguments", {
  use_test_python()
  math <- import("math")
  expect_true(is_py_object(math))
  expect_s3_class(math, "python.builtin.module")
  expect_identical(math$sqrt(16), 4)
  expect_identical(import_builtins()$sorted(c(3L, 1L, 2L), reverse = TRUE), list(3L, 2L, 1L))
  expect_true("sqrt" %in% names(math))
  expect_output(print(math), "module 'math'")
  py_run_string("class Box: pass\nbox = Box()")
  box <- py_eval("box", convert = FALSE)
  box$value <- 42L
  expect_identical(py_eval("box.value"), 42L)
  expect_true(py_has_attr(box, "value"))
})

test_that("convert = FALSE, indexing, tuple() and dict()", {
  use_test_python()
  lst <- r_to_py(list(10L, 20L, 30L), convert = TRUE)
  lst[0] <- 99L
  expect_identical(lst[0], 99L)
  expect_identical(length(lst), 3L)
  expect_identical(py_str(r_to_py(1:3)), "[1, 2, 3]")
  t <- tuple(1L, "a")
  expect_s3_class(t, "python.builtin.tuple")
  expect_identical(py_to_r(t), list(1L, "a"))
  expect_identical(py_to_r(dict(k = 1L)), list(k = 1L))
})

test_that("unreferenced Python objects are freed", {
  use_test_python()
  count <- function() py_eval("len(__import__('rpyodide_bridge')._objects)")
  n0 <- count()
  for (i in 1:50) r_to_py(list(i))
  invisible(gc())
  invisible(gc())
  py_eval("1")
  expect_lt(count(), n0 + 50)
})

test_that("POSIXct and difftime round-trip", {
  use_test_python()
  t <- as.POSIXct("2019-07-22 14:34:40.25", tz = "UTC")
  py$t <- t
  expect_true(py_eval("type(t).__name__") %in% c("Timestamp", "datetime"))
  back <- py$t
  expect_s3_class(back, "POSIXct")
  expect_lt(abs(as.numeric(back) - as.numeric(t)), 1e-6)
  expect_s3_class(py_eval("__import__('datetime').timedelta(seconds=90)"), "difftime")
})

test_that("NumPy arrays", {
  use_test_python()
  skip_if_no_module("numpy")
  np <- import("numpy")
  expect_identical(np$reshape(np$arange(6L), c(2L, 3L)), matrix(c(0L, 3L, 1L, 4L, 2L, 5L), 2))
  expect_equal(np$linalg$inv(matrix(c(2, 1, 1, 3), 2)), solve(matrix(c(2, 1, 1, 3), 2)))
  m <- r_to_py(matrix(1:6, 2), convert = TRUE)
  expect_identical(m[1, 2], 6L)
  x <- np$array(c(1, NA, Inf))
  expect_identical(is.nan(x), c(FALSE, TRUE, FALSE))
})

test_that("pandas data frames and Series", {
  use_test_python()
  skip_if_no_module("pandas")
  df <- data.frame(n = c(1.5, NA), i = c(1L, NA), s = c("a", NA), f = factor(c("u", "v")),
                   stringsAsFactors = FALSE)
  back <- py_to_r(r_to_py(df))
  expect_identical(back$n, c(1.5, NaN))
  expect_identical(back$s, c("a", NA))
  expect_identical(back$f, c("u", "v"))
  expect_identical(rownames(py_to_r(r_to_py(mtcars[1:3, 1:2]))), rownames(mtcars)[1:3])
  py$tt <- as.POSIXct(c("2019-07-22 14:34:40", "2019-07-22 14:34:50"), tz = "UTC")
  s <- py_eval("__import__('pandas').Series([1.5, 2.5], index=__import__('pandas').DatetimeIndex(tt))")
  expect_identical(names(s), c("2019-07-22 14:34:40", "2019-07-22 14:34:50"))
})

test_that("CPython sessions can't install packages and share R's files", {
  use_test_python()
  expect_error(py_install("tabulate"), "pip")
  f <- tempfile(fileext = ".txt")
  writeLines("shared", f)
  expect_identical(py_eval(sprintf("open(r'%s').read().strip()", f)), "shared")
  expect_true(is.data.frame(py_list_packages()))
})

test_that("sessions are separate and objects can't cross them", {
  use_test_python()
  cpython_start("rpyodide-test-2", activate = FALSE)
  on.exit(pyodide_stop("rpyodide-test-2"))
  py_run_string("squares = 'only here'", session = "rpyodide-test-2")
  expect_identical(py_eval("squares", session = "rpyodide-test-2"), "only here")
  obj <- r_to_py(1:3)
  e <- tryCatch(py_call(py_get_attr(import_builtins(session = "rpyodide-test-2"), "len"), obj),
                error = conditionMessage)
  expect_match(e, "belongs to Pyodide session")
  expect_identical(pyodide_sessions()$type[pyodide_sessions()$name == "rpyodide-test-2"], "cpython")
})

test_that("objects from a stopped session error clearly", {
  use_test_python()
  cpython_start("rpyodide-test-3", activate = FALSE)
  obj <- r_to_py(1:3, session = "rpyodide-test-3")
  pyodide_stop("rpyodide-test-3")
  expect_error(py_len(obj), "stopped")
})

test_that("the shared test session stops", {
  skip_if_no_python()
  pyodide_stop("rpyodide-test")
  expect_false("rpyodide-test" %in% pyodide_sessions()$name)
})
