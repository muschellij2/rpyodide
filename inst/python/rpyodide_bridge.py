"""Python side of the rpyodide bridge.

Runs inside a Pyodide web worker. R (webR) sends JSON requests; each one is
handled by `handle()`, which returns a JSON response. Python objects that
can't be converted to R values stay here in `_objects` and are passed to R as
numbered references.

Values are tagged dicts:
  {"t": "null"}
  {"t": "vec", "type": "double"|"integer"|"logical"|"character", "v": [...],
   "dim": [...], "names": [...], "nan": [...], "pinf": [...], "ninf": [...], "asis": bool,
   "posixct": bool, "difftime": bool}
  (doubles flagged `posixct` are seconds since 1970-01-01 UTC, and those
  flagged `difftime` are durations in seconds)
  {"t": "list", "v": [...], "names": [...]}
  {"t": "df", "names": [...], "cols": [...], "rownames": [...]}
  {"t": "ref", "id": int, "classes": [...], "callable": bool}
"""

import base64
import builtins
import contextlib
import datetime
import importlib
import importlib.util
import io
import json
import math
import os
import sys
import traceback

try:
    import pyodide_js
    from pyodide.ffi import to_js
except ImportError:  # running outside Pyodide (local tests)
    pyodide_js = None
    to_js = None

INT_MAX = 2**31 - 1

_objects = {}
_counter = 0
_main = sys.modules["__main__"]


# ---------------------------------------------------------------- references

def _store(obj):
    global _counter
    _counter += 1
    _objects[_counter] = obj
    return _counter


def _classes(obj):
    out = []
    for cls in type(obj).__mro__:
        if cls.__module__ == "builtins":
            out.append(f"python.builtin.{cls.__qualname__}")
        else:
            out.append(f"{cls.__module__}.{cls.__qualname__}")
    return out


def _ref(obj):
    return {"t": "ref", "id": _store(obj), "classes": _classes(obj),
            "callable": callable(obj)}


# ------------------------------------------------------------- Python -> R

def _vec(type_, values):
    return {"t": "vec", "type": type_, "v": values}


def _double_vec(values):
    v, nan, pinf, ninf = [], [], [], []
    for i, x in enumerate(values):
        if x is None:
            v.append(None)
        elif math.isnan(x):
            v.append(None)
            nan.append(i)
        elif math.isinf(x):
            v.append(None)
            (pinf if x > 0 else ninf).append(i)
        else:
            v.append(x)
    out = _vec("double", v)
    if nan:
        out["nan"] = nan
    if pinf:
        out["pinf"] = pinf
    if ninf:
        out["ninf"] = ninf
    return out


def _is_missing(x):
    return x is None or (isinstance(x, float) and math.isnan(x))


def _numpy_to_r(arr):
    """Encode a numpy array, or return None if its dtype has no R equivalent."""
    if arr.ndim == 0:
        if arr.dtype.kind in "mM":
            return _numpy_to_r(arr.reshape(1))
        return _to_r(arr.item())
    flat = arr.flatten(order="F")
    kind = arr.dtype.kind
    if kind == "b":
        out = _vec("logical", [bool(x) for x in flat.tolist()])
    elif kind in "iu":
        values = flat.tolist()
        if all(-INT_MAX <= x <= INT_MAX for x in values):
            out = _vec("integer", values)
        else:
            out = _double_vec([float(x) for x in values])
    elif kind == "f":
        out = _double_vec(flat.astype(float).tolist())
    elif kind in "US":
        out = _vec("character", [str(x) for x in flat.tolist()])
    elif kind == "O" and all(isinstance(x, str) or _is_missing(x) for x in flat.tolist()):
        out = _vec("character", [None if _is_missing(x) else x for x in flat.tolist()])
    elif kind == "M":
        out = _seconds_vec(flat.astype("datetime64[ns]"), "posixct")
    elif kind == "m":
        out = _seconds_vec(flat.astype("timedelta64[ns]"), "difftime")
    else:
        return None
    if arr.ndim > 1:
        out["dim"] = list(arr.shape)
    return out


def _seconds_vec(values_ns, flag):
    """Encode datetime64[ns] / timedelta64[ns] values as seconds (NaT -> NA)."""
    np = sys.modules["numpy"]
    missing = np.isnat(values_ns)
    secs = values_ns.astype("int64") / 1e9
    out = _double_vec([None if m else float(x) for x, m in zip(secs.tolist(), missing.tolist())])
    out[flag] = True
    return out


def _pandas_values(obj):
    """A Series' or Index's values as numpy, with time zones converted to UTC."""
    pd = sys.modules["pandas"]
    if isinstance(obj.dtype, pd.DatetimeTZDtype):
        obj = obj.dt.tz_convert("UTC").dt.tz_localize(None) if isinstance(obj, pd.Series) \
            else obj.tz_convert("UTC").tz_localize(None)
    elif isinstance(obj.dtype, pd.CategoricalDtype):
        obj = obj.astype(str)
    return obj.to_numpy()


def _default_index(idx):
    pd = sys.modules["pandas"]
    return isinstance(idx, pd.RangeIndex) and idx.start == 0 and idx.step == 1


def _pandas_df_to_r(df):
    pd = sys.modules["pandas"]
    cols = []
    for i in range(df.shape[1]):
        col = df.iloc[:, i]
        enc = _numpy_to_r(_pandas_values(col))
        if enc is None:
            enc = {"t": "list", "v": [_to_r(x) for x in col.tolist()]}
        cols.append(enc)
    out = {"t": "df", "names": [str(c) for c in df.columns], "cols": cols}
    if not _default_index(df.index):
        out["rownames"] = [str(i) for i in df.index]
    return out


def _to_r(obj):
    """Convert a Python object to an R value, falling back to a reference."""
    if obj is None:
        return {"t": "null"}
    if isinstance(obj, bool):
        return _vec("logical", [obj])
    if isinstance(obj, int):
        if -INT_MAX <= obj <= INT_MAX:
            return _vec("integer", [obj])
        return _double_vec([float(obj)])
    if isinstance(obj, float):
        return _double_vec([obj])
    if isinstance(obj, str):
        return _vec("character", [obj])
    if isinstance(obj, datetime.datetime):
        pd = sys.modules.get("pandas")
        if pd is not None and obj is pd.NaT:
            return _double_vec([None]) | {"posixct": True}
        if obj.tzinfo is not None:
            obj = obj.astimezone(datetime.timezone.utc).replace(tzinfo=None)
        secs = (obj - datetime.datetime(1970, 1, 1)) / datetime.timedelta(seconds=1)
        if pd is not None and isinstance(obj, pd.Timestamp):
            secs = obj.value / 1e9
        return _double_vec([secs]) | {"posixct": True}
    if isinstance(obj, datetime.timedelta):
        return _double_vec([obj.total_seconds()]) | {"difftime": True}
    if isinstance(obj, (list, tuple)):
        return {"t": "list", "v": [_to_r(x) for x in obj]}
    if isinstance(obj, dict):
        return {"t": "list", "v": [_to_r(x) for x in obj.values()],
                "names": [str(k) for k in obj.keys()]}
    np = sys.modules.get("numpy")
    if np is not None:
        if isinstance(obj, np.ndarray):
            enc = _numpy_to_r(obj)
            if enc is not None:
                return enc
        elif isinstance(obj, np.generic):
            return _to_r(obj.item())
    pd = sys.modules.get("pandas")
    if pd is not None:
        if isinstance(obj, pd.DataFrame):
            return _pandas_df_to_r(obj)
        if isinstance(obj, (pd.Series, pd.Index)):
            enc = _numpy_to_r(_pandas_values(obj))
            if enc is not None:
                if isinstance(obj, pd.Series) and not _default_index(obj.index):
                    enc["names"] = [str(i) for i in obj.index]
                return enc
    return _ref(obj)


def _out(obj, convert):
    return _to_r(obj) if convert else _ref(obj)


# ------------------------------------------------------------- R -> Python

def _values(e):
    v = list(e["v"])
    type_ = e["type"]
    if type_ == "double":
        v = [math.nan if x is None else float(x) for x in v]
        for i in e.get("nan") or []:
            v[i] = math.nan
        for i in e.get("pinf") or []:
            v[i] = math.inf
        for i in e.get("ninf") or []:
            v[i] = -math.inf
    elif type_ == "integer":
        v = [None if x is None else int(x) for x in v]
    elif type_ == "logical":
        v = [None if x is None else bool(x) for x in v]
    return v


def _datetimes(e):
    """POSIXct seconds -> numpy datetime64[ns] (NA -> NaT)."""
    np = importlib.import_module("numpy")
    # whole seconds and the fraction separately, to keep nanosecond arithmetic exact
    ns = [None if math.isnan(x) else math.floor(x) * 10**9 + round((x - math.floor(x)) * 1e9)
          for x in _values(e)]
    return np.array([np.datetime64("NaT") if x is None else np.datetime64(x, "ns") for x in ns],
                    dtype="datetime64[ns]")


_NUMPY_DTYPES = {"double": "float64", "integer": "int32", "logical": "bool", "character": "object"}


def _from_r(e):
    t = e["t"]
    if t == "null":
        return None
    if t == "ref":
        try:
            return _objects[e["id"]]
        except KeyError:
            raise RuntimeError(f"Python object reference {e['id']} no longer exists") from None
    if t == "list":
        v = [_from_r(x) for x in e["v"]]
        names = e.get("names")
        return dict(zip(names, v)) if names is not None else v
    if t == "df":
        pd = importlib.import_module("pandas")
        cols = {}
        for name, col in zip(e["names"], e["cols"]):
            if col["t"] == "vec":
                cols[name] = _datetimes(col) if col.get("posixct") else _values(col)
            else:
                cols[name] = _from_r(col)
        df = pd.DataFrame(cols)
        if e.get("rownames") is not None:
            df.index = e["rownames"]
        return df
    if t == "vec" and e.get("posixct"):
        times = _datetimes(e)
        if e.get("dim") is not None:
            return times.reshape(e["dim"], order="F")
        if e.get("names") is None and len(times) == 1 and not e.get("asis"):
            return importlib.import_module("pandas").Timestamp(times[0])
        return times
    if t == "vec":
        values = _values(e)
        dim = e.get("dim")
        if dim is not None:
            np = importlib.import_module("numpy")
            dtype = _NUMPY_DTYPES[e["type"]]
            if e["type"] in ("integer", "logical") and None in values:
                dtype = "float64"
                values = [math.nan if x is None else x for x in values]
            return np.array(values, dtype=dtype).reshape(dim, order="F")
        names = e.get("names")
        if names is not None:
            return dict(zip(names, values))
        if len(values) == 1 and not e.get("asis"):
            return values[0]
        return values
    raise ValueError(f"unknown value tag from R: {t!r}")


def _needed_packages(e, acc):
    """Find the numpy/pandas packages needed to decode an R value."""
    if isinstance(e, dict):
        if e.get("t") == "df":
            acc.add("pandas")
        elif e.get("t") == "vec" and (e.get("dim") is not None or e.get("posixct")):
            acc.add("numpy")
        for v in e.values():
            _needed_packages(v, acc)
    elif isinstance(e, list):
        for v in e:
            _needed_packages(v, acc)
    return acc


async def _load_packages(names):
    missing = [n for n in names if importlib.util.find_spec(n) is None]
    if missing and pyodide_js is not None:
        await pyodide_js.loadPackage(to_js(missing))
        importlib.invalidate_caches()


async def _load_imports(code):
    """Load Pyodide packages that `code` imports (e.g. numpy) before running it."""
    if pyodide_js is not None:
        await pyodide_js.loadPackagesFromImports(code)
        importlib.invalidate_caches()


# -------------------------------------------------------------- operations

def _obj(req):
    return _from_r({"t": "ref", "id": req["id"]})


async def _op_exec(req):
    await _load_imports(req["code"])
    exec(compile(req["code"], "<string>", "exec"), _main.__dict__)
    return {"t": "null"}


async def _op_eval(req):
    await _load_imports(req["code"])
    value = eval(compile(req["code"], "<string>", "eval"), _main.__dict__)
    return _out(value, req.get("convert", True))


async def _op_import(req):
    await _load_imports(f"import {req['name']}")
    return _ref(importlib.import_module(req["name"]))


async def _op_getattr(req):
    return _out(getattr(_obj(req), req["name"]), req.get("convert", True))


async def _op_setattr(req):
    setattr(_obj(req), req["name"], _from_r(req["value"]))
    return {"t": "null"}


async def _op_hasattr(req):
    return _to_r(hasattr(_obj(req), req["name"]))


async def _op_dir(req):
    return _to_r(list(dir(_obj(req))))


async def _op_call(req):
    args = [_from_r(a) for a in req["args"]]
    kwargs = {k: _from_r(v) for k, v in zip(req["kwnames"], req["kwargs"])}
    result = _obj(req)(*args, **kwargs)
    if hasattr(result, "__await__"):
        result = await result
    return _out(result, req.get("convert", True))


async def _op_getitem(req):
    return _out(_obj(req)[_from_r(req["key"])], req.get("convert", True))


async def _op_setitem(req):
    _obj(req)[_from_r(req["key"])] = _from_r(req["value"])
    return {"t": "null"}


async def _op_len(req):
    obj = _obj(req)
    if not hasattr(obj, "__len__"):
        return {"t": "null"}
    return _to_r(len(obj))


async def _op_str(req):
    return _to_r(str(_obj(req)))


async def _op_repr(req):
    return _to_r(repr(_obj(req)))


async def _op_to_r(req):
    return _to_r(_obj(req))


async def _op_to_py(req):
    return _ref(_from_r(req["value"]))


async def _op_install(req):
    await _load_packages(["micropip"])
    import micropip
    await micropip.install(req["packages"], deps=req.get("deps", True))
    return {"t": "null"}


def _write_file(path, data_b64):
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    with open(path, "wb") as f:
        f.write(base64.b64decode(data_b64))


async def _op_write_file(req):
    _write_file(req["path"], req["data"])
    return {"t": "null"}


async def _op_list_packages(req):
    await _load_packages(["micropip"])
    import micropip
    pkgs = micropip.list()
    names = sorted(pkgs.keys())
    return {"t": "df", "names": ["package", "version", "source"],
            "cols": [_vec("character", names),
                     _vec("character", [str(pkgs[n].version) for n in names]),
                     _vec("character", [str(pkgs[n].source) for n in names])]}


async def _op_module_available(req):
    name = req["name"]
    if importlib.util.find_spec(name) is not None:
        return _to_r(True)
    try:
        lock_packages = pyodide_js.lockfile.packages.to_py()
        import_names = {m for p in lock_packages.values() for m in p.get("imports", [])}
        return _to_r(name in lock_packages or name in import_names)
    except Exception:
        return _to_r(False)


async def _op_config(req):
    loaded = []
    if pyodide_js is not None:
        loaded = sorted(pyodide_js.loadedPackages.to_py().keys())
    return _to_r({
        "python": sys.version,
        "pyodide": str(pyodide_js.version) if pyodide_js is not None else None,
        "executable": sys.executable,
        "platform": sys.platform,
        "loaded_packages": loaded,
    })


_OPS = {name[4:]: fn for name, fn in globals().items() if name.startswith("_op_")}


async def handle(payload):
    """Handle one JSON request from R and return a JSON response."""
    out, err = io.StringIO(), io.StringIO()
    try:
        req = json.loads(payload)
        for i in req.get("del") or []:
            _objects.pop(i, None)
        # Files from webR's file system that the request refers to.
        for f in req.get("files") or []:
            _write_file(f["path"], f["data"])
        await _load_packages(sorted(_needed_packages(req, set())))
        op = _OPS.get(req["op"])
        if op is None:
            raise ValueError(f"unknown rpyodide operation: {req['op']!r}")
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            value = await op(req)
        resp = {"ok": True, "value": value}
    except BaseException as e:  # noqa: BLE001 - report everything (incl. SystemExit) to R
        resp = {"ok": False, "error": {
            "type": type(e).__name__,
            "message": str(e),
            "traceback": "".join(traceback.format_exception(e)),
        }}
    resp["stdout"] = out.getvalue()
    resp["stderr"] = err.getvalue()
    try:
        return json.dumps(resp, allow_nan=False)
    except (TypeError, ValueError) as e:
        return json.dumps({"ok": False, "stdout": resp["stdout"], "stderr": resp["stderr"],
                           "error": {"type": type(e).__name__,
                                     "message": f"could not encode result for R: {e}",
                                     "traceback": ""}})
