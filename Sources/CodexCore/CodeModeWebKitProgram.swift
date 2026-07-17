import Foundation

enum CodeModeWebKitProgram {
  static func makeWorker(
    bindings: [CodeModeHostBinding],
    initialStore: [String: JSONValue],
    source: String,
    token: String
  ) -> String {
    let runtime = CodeModeJavaScriptProgram.make(
      bindings: bindings,
      initialStore: initialStore,
      source: source
    )
    let runtimeJSON = jsonString(runtime)
    let tokenJSON = jsonString(token)

    return """
      (() => {
        "use strict";

        const __scope = globalThis;
        const __token = \(tokenJSON);
        const __runtime = \(runtimeJSON);
        const __nativePostMessage = __scope.postMessage.bind(__scope);
        const __nativeSetTimeout = __scope.setTimeout.bind(__scope);
        const __nativeClearTimeout = __scope.clearTimeout.bind(__scope);
        const __nativeAddEventListener = __scope.addEventListener.bind(__scope);
        const __nativeRemoveEventListener = __scope.removeEventListener.bind(__scope);
        const __nativeEval = __scope.eval;
        const __jsonStringify = JSON.stringify.bind(JSON);
        const __defineProperty = Object.defineProperty.bind(Object);
        const __getPrototypeOf = Object.getPrototypeOf.bind(Object);
        const __hasOwn = Function.call.bind(Object.prototype.hasOwnProperty);
        const __deleteProperty = Reflect.deleteProperty.bind(Reflect);
        const __objectKeys = Object.keys.bind(Object);
        const __numberIsFinite = Number.isFinite.bind(Number);
        const __mathTrunc = Math.trunc.bind(Math);
        const __String = String;
        const __Number = Number;
        const __Boolean = Boolean;
        let __bridge = null;

        function __send(type, fields = null) {
          const message = {type, token: __token};
          if (fields !== null) {
            for (const key of __objectKeys(fields)) message[key] = fields[key];
          }
          __nativePostMessage(message);
        }

        function __replaceProperty(target, name) {
          try { __deleteProperty(target, name); } catch (_) {}
          try {
            __defineProperty(target, name, {
              value: undefined,
              writable: false,
              enumerable: false,
              configurable: false
            });
          } catch (_) {
            try { target[name] = undefined; } catch (_) {}
          }
        }

        function __lockDown(name) {
          let target = __scope;
          while (target !== null) {
            if (__hasOwn(target, name)) __replaceProperty(target, name);
            target = __getPrototypeOf(target);
          }
          // Keep an immutable own-property mask even when the native API only
          // existed on a prototype, so normal lookup cannot regain it either.
          __replaceProperty(__scope, name);
        }

        function __installHostFunction(name, value) {
          __defineProperty(__scope, name, {
            value,
            writable: false,
            enumerable: false,
            configurable: true
          });
        }

        function __timerMilliseconds(value) {
          const number = __Number(value);
          if (!__numberIsFinite(number) || number <= 0) return 0;
          if (number >= 300000) return 300000;
          return __mathTrunc(number);
        }

        function __receive(event) {
          const message = event && event.data;
          if (!message || message.type !== 'tool_result' || message.token !== __token) return;
          const bridge = __bridge;
          if (!bridge || typeof bridge.resolveTool !== 'function') return;
          const identifier = typeof message.id === 'string' ? message.id : __String(message.id ?? '');
          if (identifier.length === 0) return;
          let payload = message.payload;
          if (typeof payload !== 'string') {
            try { payload = __jsonStringify(payload === undefined ? null : payload); }
            catch (_) { payload = 'null'; }
          }
          const error = typeof message.error === 'string' ? message.error : 'Nested tool failed';
          bridge.resolveTool(identifier, message.ok === true, payload, error);
        }

        __nativeAddEventListener('message', __receive);

        for (const name of [
          'postMessage', 'close', 'fetch', 'XMLHttpRequest', 'WebSocket', 'EventSource',
          'importScripts', 'Worker', 'SharedWorker', 'indexedDB', 'caches',
          'BroadcastChannel', 'addEventListener', 'removeEventListener', 'eval',
          'setInterval', 'clearInterval'
        ]) {
          __lockDown(name);
        }

        __installHostFunction('__swiftToolCall', (id, name, argumentsJSON) => {
          __send('tool_call', {
            id: __String(id),
            name: __String(name),
            arguments: __String(argumentsJSON)
          });
        });
        __installHostFunction('__swiftSetTimer', (id, milliseconds) => {
          __nativeSetTimeout(() => {
            const bridge = __bridge;
            if (bridge && typeof bridge.fireTimer === 'function') bridge.fireTimer(__String(id));
          }, __timerMilliseconds(milliseconds));
        });
        __installHostFunction('__swiftEmit', (payload, shouldYield) => {
          __send('emit', {payload: __String(payload), yield: __Boolean(shouldYield)});
        });
        __installHostFunction('__swiftNotify', text => {
          __send('notify', {text: __String(text)});
        });
        __installHostFunction('__swiftYield', () => {
          __send('yield');
        });
        __installHostFunction('__swiftComplete', payload => {
          __send('complete', {payload: __String(payload)});
        });

        // Keep these references lexical so user code cannot recover or replace
        // the native worker bridge after the corresponding globals are hidden.
        void __nativeClearTimeout;
        void __nativeRemoveEventListener;
        __send('host_ready');
        try {
          __bridge = __nativeEval(__runtime);
        } catch (error) {
          __nativeRemoveEventListener('message', __receive);
          __send('host_error', {error: __String(error)});
        }
      })();
      """
  }

  static func makeRelay(handlerName: String, relayName: String) -> String {
    let handlerNameJSON = jsonString(handlerName)
    let relayNameJSON = jsonString(relayName)

    return """
      (() => {
        "use strict";

        const __scope = globalThis;
        const __handlerName = \(handlerNameJSON);
        const __relayName = \(relayNameJSON);
        const __handler = __scope.webkit?.messageHandlers?.[__handlerName];
        if (!__handler || typeof __handler.postMessage !== 'function') {
          throw new Error('The native code-mode message handler is unavailable.');
        }

        const __postToNative = __handler.postMessage.bind(__handler);
        const __Worker = __scope.Worker;
        const __Blob = __scope.Blob;
        const __createObjectURL = __scope.URL.createObjectURL.bind(__scope.URL);
        const __revokeObjectURL = __scope.URL.revokeObjectURL.bind(__scope.URL);
        const __textEncoder = new __scope.TextEncoder();
        const __encodeText = __textEncoder.encode.bind(__textEncoder);
        const __jsonStringify = JSON.stringify.bind(JSON);
        const __promiseResolve = Promise.resolve.bind(Promise);
        const __String = String;
        const __workers = new Map();

        function __errorMessage(error, fallback) {
          if (error && typeof error.message === 'string' && error.message.length > 0) {
            return error.message;
          }
          const rendered = error == null ? '' : __String(error);
          return rendered.length > 0 ? rendered : fallback;
        }

        function __fits(value, maximumBytes) {
          return typeof value === 'string' && __encodeText(value).byteLength <= maximumBytes;
        }

        function __postEvent(record, event) {
          const encoded = __jsonStringify(event);
          return __postToNative(`${record.cellID}\n${encoded}`);
        }

        function __postToolResult(record, identifier, ok, payload, error) {
          if (__workers.get(record.cellID) !== record) return;
          record.postMessage({
            type: 'tool_result',
            token: record.token,
            id: identifier,
            ok,
            payload: typeof payload === 'string' ? payload : 'null',
            error: typeof error === 'string' ? error : 'Nested tool failed'
          });
        }

        function __forward(record, message) {
          if (__workers.get(record.cellID) !== record) return;
          if (!message || typeof message !== 'object' || message.token !== record.token) return;

          let forwarded;
          switch (message.type) {
          case 'host_ready':
          case 'yield':
            forwarded = {
              type: message.type,
              token: record.token,
              cell_id: record.cellID
            };
            break;
          case 'tool_call':
            if (!__fits(message.id, 1024) || !__fits(message.name, 4096)
                || !__fits(message.arguments, record.maxEventBytes)) {
              __reportWorkerError(record, 'Code-mode tool call exceeded its byte limit.');
              return;
            }
            forwarded = {
              type: message.type,
              token: record.token,
              cell_id: record.cellID,
              id: message.id,
              name: message.name,
              arguments: message.arguments
            };
            break;
          case 'emit':
            if (!__fits(message.payload, record.maxEventBytes)) {
              __reportWorkerError(record, 'Code-mode content block exceeded its byte limit.');
              return;
            }
            forwarded = {
              type: message.type,
              token: record.token,
              cell_id: record.cellID,
              payload: message.payload,
              yield: message.yield === true
            };
            break;
          case 'notify':
            if (!__fits(message.text, record.maxEventBytes)) {
              __reportWorkerError(record, 'Code-mode notification exceeded its byte limit.');
              return;
            }
            forwarded = {
              type: message.type,
              token: record.token,
              cell_id: record.cellID,
              text: message.text
            };
            break;
          case 'complete':
            if (!__fits(message.payload, record.maxEventBytes)) {
              __reportWorkerError(record, 'Code-mode completion exceeded its byte limit.');
              return;
            }
            forwarded = {
              type: message.type,
              token: record.token,
              cell_id: record.cellID,
              payload: message.payload
            };
            break;
          case 'host_error':
          case 'worker_error':
            forwarded = {
              type: message.type,
              token: record.token,
              cell_id: record.cellID,
              error: __fits(message.error, record.maxEventBytes)
                ? message.error
                : 'The WebKit worker failed with an oversized error.'
            };
            break;
          default:
            return;
          }

          let reply;
          try {
            reply = __postEvent(record, forwarded);
          } catch (error) {
            if (message.type === 'tool_call') {
              __postToolResult(
                record,
                message.id,
                false,
                'null',
                __errorMessage(error, 'Nested tool failed')
              );
            }
            return;
          }

          if (message.type !== 'tool_call') {
            __promiseResolve(reply).catch(() => {});
            return;
          }

          __promiseResolve(reply).then(
            payload => {
              __postToolResult(record, message.id, true, payload, '');
            },
            error => {
              __postToolResult(
                record,
                message.id,
                false,
                'null',
                __errorMessage(error, 'Nested tool failed')
              );
            }
          );
        }

        function __reportWorkerError(record, error) {
          if (__workers.get(record.cellID) !== record) return;
          const event = {
            type: 'host_error',
            token: record.token,
            cell_id: record.cellID,
            error: __errorMessage(error, 'The WebKit worker failed.')
          };
          if (!__fits(event.error, record.maxEventBytes)) {
            event.error = 'The WebKit worker failed with an oversized error.';
          }
          try { __promiseResolve(__postEvent(record, event)).catch(() => {}); } catch (_) {}
        }

        function start(request) {
          if (!request || typeof request !== 'object') {
            throw new TypeError('Code-mode worker start requires a request object.');
          }
          const cellID = request.cell_id;
          const token = request.token;
          const program = request.program;
          const maxEventBytes = request.max_event_bytes;
          if (typeof cellID !== 'string' || cellID.length === 0) {
            throw new TypeError('Code-mode worker cell_id must be a non-empty string.');
          }
          if (typeof token !== 'string' || token.length === 0) {
            throw new TypeError('Code-mode worker token must be a non-empty string.');
          }
          if (typeof program !== 'string') {
            throw new TypeError('Code-mode worker program must be a string.');
          }
          if (!Number.isSafeInteger(maxEventBytes) || maxEventBytes < 1024
              || maxEventBytes > 67108864) {
            throw new TypeError('Code-mode worker max_event_bytes is invalid.');
          }
          if (__workers.has(cellID)) {
            throw new Error(`A code-mode worker already exists for cell_id ${cellID}.`);
          }

          let objectURL = null;
          let worker = null;
          try {
            objectURL = __createObjectURL(new __Blob([program], {type: 'text/javascript'}));
            worker = new __Worker(objectURL);
          } finally {
            if (objectURL !== null) __revokeObjectURL(objectURL);
          }

          const record = {
            cellID,
            token,
            maxEventBytes,
            worker,
            postMessage: worker.postMessage.bind(worker)
          };
          __workers.set(cellID, record);
          worker.addEventListener('message', event => __forward(record, event.data));
          worker.addEventListener('error', event => {
            if (typeof event.preventDefault === 'function') event.preventDefault();
            __reportWorkerError(record, event);
          });
          worker.addEventListener('messageerror', () => {
            __reportWorkerError(record, 'The WebKit worker emitted an undecodable message.');
          });
          return true;
        }

        function terminate(cellID) {
          if (typeof cellID !== 'string') {
            throw new TypeError('Code-mode worker cell_id must be a string.');
          }
          const record = __workers.get(cellID);
          if (!record) return false;
          __workers.delete(cellID);
          record.worker.terminate();
          return true;
        }

        function terminateAll() {
          const records = Array.from(__workers.values());
          __workers.clear();
          for (const record of records) record.worker.terminate();
          return records.length;
        }

        if (Object.prototype.hasOwnProperty.call(__scope, __relayName)) {
          throw new Error('The code-mode relay name is already installed.');
        }
        Object.defineProperty(__scope, __relayName, {
          value: Object.freeze({start, terminate, terminateAll}),
          writable: false,
          enumerable: false,
          configurable: false
        });
        return true;
      })();
      """
  }

  static let documentHTML = """
    <!doctype html>
    <html>
      <head>
        <meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-eval'; worker-src blob:; img-src data:; connect-src 'none'; media-src 'none'; frame-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'">
        <title>Code Mode Host</title>
      </head>
      <body></body>
    </html>
    """

  private static func jsonString(_ value: String) -> String {
    guard let data = try? JSONEncoder.codexCompact.encode(value) else { return "\"\"" }
    return String(decoding: data, as: UTF8.self)
  }
}
