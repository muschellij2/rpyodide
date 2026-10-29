// rpyodide glue, evaluated inside the webR worker by webr::eval_js().
//
// With webR's SharedArrayBuffer channel, `Worker` in the webR worker is a
// proxy: the real worker is created on the page's main thread, and
// `postMessage(msg, {async: false})` blocks R until the worker replies with
// `{uuid, result}`. That gives R synchronous calls into Python.
//
// webR creates proxied workers from an untyped Blob, which browsers refuse to
// run as module workers. Pyodide >= 314 needs a module worker, so each session
// is a small classic "shim" worker that starts Pyodide in a nested module
// worker and forwards messages both ways.
(() => {
  if (globalThis.__rpyodide) return 'installed';
  if (typeof Worker === 'undefined' || typeof Worker.prototype._message !== 'function') {
    return 'no-proxy';
  }

  const sessions = new Map();

  const shimSource = (workerSrc, config) => `
const inner = new Worker(URL.createObjectURL(
  new Blob([${JSON.stringify(workerSrc)}], { type: 'text/javascript' })), { type: 'module' });
inner.onmessage = (e) => self.postMessage(e.data);
inner.onerror = (e) => self.postMessage({
  status: 'error', message: 'Pyodide worker failed: ' + (e.message || 'unknown error')
});
self.onmessage = (e) => inner.postMessage(e.data);
inner.postMessage({ config: ${JSON.stringify(config)} });
`;

  globalThis.__rpyodide = {
    start(name, workerSrc, config) {
      if (sessions.has(name)) return 'exists';
      const shim = shimSource(workerSrc, config);
      const worker = new Worker('data:text/javascript;charset=utf-8,' + encodeURIComponent(shim));
      const session = { worker, status: 'loading', message: '' };
      worker.onmessage = (e) => {
        const d = e.data;
        if (d && d.status) {
          session.status = d.status;
          session.message = d.message || '';
        }
      };
      worker.onerror = () => {
        session.status = 'error';
        session.message = 'rpyodide shim worker failed to start';
      };
      sessions.set(name, session);
      return 'started';
    },

    // Deliver pending worker messages to this (blocked) worker and report status.
    poll(name) {
      Module.webr.handleEvents();
      const s = sessions.get(name);
      return JSON.stringify(s ? { status: s.status, message: s.message } : { status: 'missing' });
    },

    request(name, payload) {
      const s = sessions.get(name);
      if (!s) throw new Error(`No Pyodide session named '${name}'`);
      const reply = s.worker.postMessage(payload, { async: false });
      if (reply.error) throw new Error(reply.error);
      return reply.result;
    },

    stop(name) {
      const s = sessions.get(name);
      if (s) {
        s.worker.terminate();
        sessions.delete(name);
      }
      return 'stopped';
    },
  };
  return 'installed';
})()
