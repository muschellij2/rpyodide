# py_require() only records requirements until a session starts, so this
# bookkeeping can be tested without webR.

reset <- function(session) {
  state <- rpyodide:::.rpyodide
  state$requirements[[session]] <- NULL
}

test_that("requirements accumulate, replace by name, and can be removed or set", {
  s <- "test-req"
  reset(s)
  on.exit(reset(s))
  expect_identical(py_require(session = s)$packages, character())
  py_require(c("numpy", "pandas"), session = s)
  py_require("Pandas>=2", session = s)
  expect_identical(py_require(session = s)$packages, c("numpy", "Pandas>=2"))
  py_require("pandas", action = "remove", session = s)
  expect_identical(py_require(session = s)$packages, "numpy")
  py_require(c("scipy", "scipy"), action = "set", session = s)
  expect_identical(py_require(session = s)$packages, "scipy")
  py_require(python_version = ">=3.12", session = s)
  r <- py_require(session = s)
  expect_identical(r$python_version, ">=3.12")
  expect_false(r$started)
  expect_output(print(r), "not started")
  py_require(action = "set", session = s)
  expect_identical(py_require(session = s)$packages, character())
})

test_that("package names are normalised", {
  expect_identical(rpyodide:::package_name(c("Scikit_Learn[all]>=1.0", "a.b ==1", "x; python_version>'3'")),
                   c("scikit-learn", "a-b", "x"))
})

test_that("python_version constraints", {
  ok <- function(c) rpyodide:::python_version_satisfies("3.14.2", c)
  expect_true(ok("3.14"))
  expect_true(ok("3"))
  expect_false(ok("3.13"))
  expect_true(ok(">=3.12"))
  expect_true(ok(">=3.12,<3.15"))
  expect_false(ok("<3.14"))
  expect_true(ok("<=3.14"))
  expect_false(ok(">3.14"))
  expect_true(ok("!=3.13"))
  expect_true(ok("~=3.12"))
  expect_false(ok("~=3.12.0"))
  expect_error(ok("latest"), "Invalid python_version")
  expect_error(rpyodide:::check_python_version("<3.12", "3.14.2", "s"), "doesn't satisfy")
})

test_that("deps = FALSE requirements are kept separately", {
  s <- "test-req-nodeps"
  reset(s)
  on.exit(reset(s))
  py_require("numpy", session = s)
  py_require(c("stepcount", "actipy"), deps = FALSE, session = s)
  py_require("actipy", deps = FALSE, action = "remove", session = s)
  r <- py_require(session = s)
  expect_identical(r$packages, "numpy")
  expect_identical(r$no_deps, "stepcount")
  expect_output(print(r), "without deps:   stepcount")
})
