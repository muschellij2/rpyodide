# These tests run anywhere; they check the JSON encoding that is sent to
# Python and the decoding of what comes back, without needing webR.

roundtrip <- function(x) {
  json <- rpyodide:::to_json(rpyodide:::r_to_enc(x, session = NULL))
  jsonlite::fromJSON(json, simplifyVector = FALSE)
}

test_that("atomic vectors are encoded with their type", {
  e <- roundtrip(c(1.5, NA, NaN, Inf, -Inf))
  expect_equal(e$type, "double")
  expect_equal(e$v[[1]], 1.5)
  expect_null(e$v[[2]])
  expect_equal(unlist(e$nan), 2L)
  expect_equal(unlist(e$pinf), 3L)
  expect_equal(unlist(e$ninf), 4L)
  expect_equal(roundtrip(1L)$type, "integer")
  expect_equal(roundtrip(c(TRUE, NA))$v, list(TRUE, NULL))
  expect_equal(roundtrip(c(a = "x"))$names, list("a"))
  expect_true(roundtrip(I(1))$asis)
})

test_that("doubles keep full precision", {
  expect_identical(roundtrip(pi)$v[[1]], pi)
  expect_identical(roundtrip(1 / 3)$v[[1]], 1 / 3)
})

test_that("matrices, lists, factors and data frames are encoded", {
  m <- roundtrip(matrix(1:6, 2))
  expect_equal(unlist(m$dim), c(2L, 3L))
  expect_equal(unlist(m$v), 1:6)
  l <- roundtrip(list(a = 1, b = list("x", NULL)))
  expect_equal(l$t, "list")
  expect_equal(l$v[[2]]$v[[2]]$t, "null")
  expect_equal(roundtrip(factor(c("u", "v")))$type, "character")
  d <- roundtrip(data.frame(x = 1:2, y = c("a", "b")))
  expect_equal(d$t, "df")
  expect_equal(unlist(d$names), c("x", "y"))
  expect_null(d$rownames)
  expect_equal(unlist(roundtrip(mtcars[1:2, 1:2])$rownames), rownames(mtcars)[1:2])
})

test_that("R functions can't be sent to Python", {
  expect_error(rpyodide:::r_to_enc(function() 1, NULL), "callbacks")
})

test_that("values from Python are decoded", {
  dec <- function(json) rpyodide:::enc_to_r(jsonlite::fromJSON(json, simplifyVector = FALSE),
                                            NULL, TRUE)
  expect_identical(dec('{"t":"vec","type":"integer","v":[1,null]}'), c(1L, NA))
  expect_identical(dec('{"t":"vec","type":"double","v":[2,null,null],"nan":[1],"ninf":[2]}'),
                   c(2, NaN, -Inf))
  expect_identical(dec('{"t":"vec","type":"double","v":[1,2,3,4],"dim":[2,2]}'),
                   matrix(c(1, 2, 3, 4), 2))
  expect_identical(dec('{"t":"list","v":[{"t":"null"},{"t":"vec","type":"character","v":["a"]}],"names":["n","s"]}'),
                   list(n = NULL, s = "a"))
  df <- dec('{"t":"df","names":["a","b"],"cols":[{"t":"vec","type":"integer","v":[1,2]},{"t":"vec","type":"character","v":["x",null]}]}')
  expect_identical(df, data.frame(a = 1:2, b = c("x", NA)))
  expect_identical(dec('{"t":"vec","type":"logical","v":[]}'), logical())
})

test_that("Pyodide sessions error clearly outside webR", {
  skip_if(rpyodide::is_webr())
  expect_error(pyodide_start(), "only works inside webR")
})

test_that("POSIXct and difftime round-trip through the encoding", {
  t <- as.POSIXct(c("2019-07-22 14:34:40.5", NA), tz = "UTC")
  e <- roundtrip(t)
  expect_true(e$posixct)
  expect_equal(e$v[[1]], as.numeric(t[1]))
  dec <- function(json) rpyodide:::enc_to_r(jsonlite::fromJSON(json, simplifyVector = FALSE),
                                            NULL, TRUE)
  back <- dec(rpyodide:::to_json(rpyodide:::r_to_enc(t, NULL)))
  expect_identical(back, structure(as.numeric(t), class = c("POSIXct", "POSIXt"), tzone = "UTC"))
  expect_true(roundtrip(as.difftime(2, units = "mins"))$difftime)
  expect_equal(roundtrip(as.difftime(2, units = "mins"))$v[[1]], 120)
  expect_true(roundtrip(data.frame(t = t))$cols[[1]]$posixct)
  expect_equal(roundtrip(as.POSIXlt(t[1]))$type, "double")
})

test_that("pandas Series names come back as names", {
  dec <- function(json) rpyodide:::enc_to_r(jsonlite::fromJSON(json, simplifyVector = FALSE),
                                            NULL, TRUE)
  x <- dec('{"t":"vec","type":"double","v":[1,2],"names":["2019-07-22 14:34:40","2019-07-22 14:34:50"]}')
  expect_identical(names(x), c("2019-07-22 14:34:40", "2019-07-22 14:34:50"))
})

test_that("file paths are only queued for copying with a session", {
  f <- tempfile()
  writeLines("x", f)
  rpyodide:::r_to_enc(f, session = NULL)
  expect_length(rpyodide:::.rpyodide$upload_queue, 0)
})
