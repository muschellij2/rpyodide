# Python objects in R are references to objects held by the Pyodide worker.
# The reference itself is a plain environment (`id`, `session`, `token`,
# `convert`). Callable Python objects are R functions carrying the reference in
# the "py_ref" attribute; other objects are environments holding it as `.ref`.

new_py_object <- function(e, session, convert) {
  ref <- new.env(parent = emptyenv())
  ref$id <- e$id
  ref$session <- session
  ref$token <- session_token(session)
  ref$convert <- convert
  reg.finalizer(ref, function(r) queue_delete(r$session, r$token, r$id))
  classes <- unique(c(as.character(unlist(e$classes)), "python.builtin.object", "pyodide_object"))
  if (isTRUE(e$callable)) {
    obj <- make_callable(ref)
    attr(obj, "py_ref") <- ref
  } else {
    obj <- new.env(parent = emptyenv())
    obj$.ref <- ref
  }
  class(obj) <- classes
  obj
}

make_callable <- function(ref) {
  force(ref)
  function(...) py_call_ref(ref, list(...))
}

#' Is an object a Python object?
#'
#' @param x An R object.
#' @return `TRUE` if `x` refers to an object in a Pyodide session.
#' @export
is_py_object <- function(x) inherits(x, "pyodide_object")

py_ref <- function(x, session = NULL) {
  ref <- if (is.function(x)) attr(x, "py_ref", exact = TRUE) else get(".ref", envir = x)
  if (!identical(session_token(ref$session), ref$token)) {
    stop("This Python object belongs to a Pyodide session that has been stopped.",
         call. = FALSE)
  }
  if (!is.null(session) && !identical(session, ref$session)) {
    stop("This Python object belongs to Pyodide session '", ref$session,
         "', not '", session, "'.", call. = FALSE)
  }
  ref
}

obj_request <- function(ref, op, ..., convert = ref$convert) {
  val <- py_request(list(op = op, id = ref$id, convert = convert, ...), session = ref$session)
  enc_to_r(val, ref$session, convert)
}

py_call_ref <- function(ref, args) {
  nms <- names(args)
  if (is.null(nms)) nms <- rep("", length(args))
  pos <- args[nms == ""]
  kw <- args[nms != ""]
  enc <- function(a) unname(lapply(a, r_to_enc, session = ref$session))
  obj_request(ref, "call", args = I(enc(pos)), kwnames = I(as.character(names(kw))),
              kwargs = I(enc(kw)))
}

# Whole-number doubles used as keys (x[1]) are sent as Python ints.
as_key <- function(key) {
  if (is.double(key) && length(key) == 1L && !is.na(key) && key == trunc(key)) {
    return(as.integer(key))
  }
  key
}

#' Work with Python objects
#'
#' Low-level accessors for Python objects. Usually you use `$`, `[[` and `[`
#' instead: `x$attr`, `x[["attr"]]` and `x[key]` (Python `x[key]`, 0-based).
#'
#' @param x A Python object.
#' @param name Attribute name.
#' @param value An R value or Python object.
#' @param key An item key or index.
#' @param ... Arguments for the call; named arguments become keyword arguments.
#' @name py_object
NULL

#' @rdname py_object
#' @export
py_get_attr <- function(x, name) obj_request(py_ref(x), "getattr", name = name)

#' @rdname py_object
#' @export
py_set_attr <- function(x, name, value) {
  ref <- py_ref(x)
  py_request(list(op = "setattr", id = ref$id, name = name,
                  value = r_to_enc(value, ref$session)), session = ref$session)
  invisible(x)
}

#' @rdname py_object
#' @export
py_has_attr <- function(x, name) obj_request(py_ref(x), "hasattr", name = name, convert = TRUE)

#' @rdname py_object
#' @export
py_list_attributes <- function(x) {
  as.character(unlist(obj_request(py_ref(x), "dir", convert = TRUE)))
}

#' @rdname py_object
#' @export
py_get_item <- function(x, key) {
  ref <- py_ref(x)
  obj_request(ref, "getitem", key = r_to_enc(as_key(key), ref$session))
}

#' @rdname py_object
#' @export
py_set_item <- function(x, key, value) {
  ref <- py_ref(x)
  py_request(list(op = "setitem", id = ref$id, key = r_to_enc(as_key(key), ref$session),
                  value = r_to_enc(value, ref$session)), session = ref$session)
  invisible(x)
}

#' @rdname py_object
#' @export
py_call <- function(x, ...) py_call_ref(py_ref(x), list(...))

#' @rdname py_object
#' @export
py_len <- function(x) obj_request(py_ref(x), "len", convert = TRUE)

#' @rdname py_object
#' @export
py_str <- function(x) obj_request(py_ref(x), "str", convert = TRUE)

#' @rdname py_object
#' @export
py_repr <- function(x) obj_request(py_ref(x), "repr", convert = TRUE)

#' @export
`$.pyodide_object` <- function(x, name) py_get_attr(x, name)

#' @export
`[[.pyodide_object` <- function(x, name) {
  if (is.character(name)) py_get_attr(x, name) else py_get_item(x, name)
}

#' @export
`$<-.pyodide_object` <- function(x, name, value) py_set_attr(x, name, value)

#' @export
`[[<-.pyodide_object` <- function(x, name, value) {
  if (is.character(name)) py_set_attr(x, name, value) else py_set_item(x, name, value)
}

#' @export
`[.pyodide_object` <- function(x, ...) {
  keys <- list(...)
  key <- if (length(keys) == 1L) keys[[1]] else do.call(tuple, lapply(keys, as_key))
  py_get_item(x, key)
}

#' @export
`[<-.pyodide_object` <- function(x, ..., value) {
  keys <- list(...)
  key <- if (length(keys) == 1L) keys[[1]] else do.call(tuple, lapply(keys, as_key))
  py_set_item(x, key, value)
}

#' @export
print.pyodide_object <- function(x, ...) {
  cat(py_repr(x), "\n", sep = "")
  invisible(x)
}

#' @export
format.pyodide_object <- function(x, ...) py_repr(x)

#' @export
str.pyodide_object <- function(object, ...) cat(py_repr(object), "\n", sep = "")

#' @export
as.character.pyodide_object <- function(x, ...) py_str(x)

#' @export
names.pyodide_object <- function(x) py_list_attributes(x)

#' @export
length.pyodide_object <- function(x) {
  n <- py_len(x)
  if (is.null(n)) 1L else n
}

#' @export
.DollarNames.pyodide_object <- function(x, pattern = "") {
  grep(pattern, py_list_attributes(x), value = TRUE)
}
