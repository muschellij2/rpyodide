// rpyodide Pyodide worker (module worker, nested inside the shim worker).
//
// Messages in:
//   {config: {pyodideUrl, lockFileURL, bridge}}  - sent once by the shim
//   {uuid, data}                                 - a JSON request from R
// Messages out:
//   {status: 'ready' | 'error', message}         - startup status
//   {uuid, result}                               - JSON response for R

let handle = null;
let chain = Promise.resolve();

async function boot(config) {
  try {
    const { loadPyodide } = await import(config.pyodideUrl + 'pyodide.mjs');
    const options = { indexURL: config.pyodideUrl };
    if (config.lockFileURL) options.lockFileURL = config.lockFileURL;
    const pyodide = await loadPyodide(options);
    pyodide.FS.mkdirTree('/home/pyodide/.rpyodide');
    pyodide.FS.writeFile('/home/pyodide/.rpyodide/rpyodide_bridge.py', config.bridge);
    pyodide.runPython("import sys; sys.path.insert(0, '/home/pyodide/.rpyodide')");
    const bridge = pyodide.pyimport('rpyodide_bridge');
    handle = bridge.handle;
    self.postMessage({ status: 'ready' });
  } catch (err) {
    self.postMessage({ status: 'error', message: String(err && err.stack || err) });
  }
}

async function respond(uuid, data) {
  let result;
  try {
    if (!handle) throw new Error('Pyodide is not ready yet');
    result = await handle(data);
  } catch (err) {
    result = JSON.stringify({
      ok: false, stdout: '', stderr: '',
      error: { type: 'JavaScriptError', message: String(err), traceback: String(err && err.stack || '') },
    });
  }
  self.postMessage({ uuid, result });
}

self.onmessage = (e) => {
  const d = e.data;
  if (d && d.config) {
    chain = boot(d.config);
    return;
  }
  // Requests run one at a time, after startup has finished.
  chain = chain.then(() => respond(d.uuid, d.data));
};
