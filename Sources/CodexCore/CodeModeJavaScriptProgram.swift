import Foundation

enum CodeModeJavaScriptProgram {
  static func make(
    bindings: [CodeModeHostBinding],
    initialStore: [String: JSONValue],
    source: String
  ) -> String {
    let toolValues: [JSONValue] = bindings.map { binding in
      .object([
        "name": .string(binding.publicName),
        "description": .string(binding.description),
        "parameters": binding.parameters,
        "output_schema": binding.outputSchema ?? .null,
        "deferred": .bool(binding.deferred),
        "path": .array(binding.path.map(JSONValue.string)),
      ])
    }
    let toolsJSON = jsonString(.array(toolValues)) ?? "[]"
    let storeJSON = jsonString(.object(initialStore)) ?? "{}"
    let sourceJSON = jsonString(.string(source)) ?? "\"\""
    return """
      delete globalThis.console;
      delete globalThis.Atomics;
      delete globalThis.SharedArrayBuffer;
      delete globalThis.WebAssembly;
      (() => {
        const __host = Object.freeze({
          toolCall: globalThis.__swiftToolCall,
          setTimer: globalThis.__swiftSetTimer,
          emit: globalThis.__swiftEmit,
          yield: globalThis.__swiftYield,
          complete: globalThis.__swiftComplete
        });
        const __jsonParse = JSON.parse.bind(JSON);
        const __jsonStringify = JSON.stringify.bind(JSON);
        const __objectCreate = Object.create.bind(Object);
        const __objectKeys = Object.keys.bind(Object);
        const __setPrototypeOf = Object.setPrototypeOf.bind(Object);
        const __arrayIsArray = Array.isArray.bind(Array);
        const __promiseThen = Function.call.bind(Promise.prototype.then);
        const __promiseResolve = Promise.resolve.bind(Promise);
        const __Promise = Promise;
        const __String = String;
        const __Number = Number;
        const __Boolean = Boolean;
        const __Error = Error;
        const __TypeError = TypeError;
        for (const name of ['__swiftToolCall', '__swiftSetTimer', '__swiftEmit', '__swiftYield', '__swiftComplete']) {
          try { Reflect.deleteProperty(globalThis, name); } catch (_) {}
          if (Object.prototype.hasOwnProperty.call(globalThis, name)) {
            try { Object.defineProperty(globalThis, name, {value: undefined, writable: false, configurable: false}); }
            catch (_) { try { globalThis[name] = undefined; } catch (_) {} }
          }
        }

        const ALL_TOOLS = \(toolsJSON);
        const tools = __objectCreate(null);
        const __pending = __objectCreate(null);
        const __timers = __objectCreate(null);
        const __store = Object.assign(__objectCreate(null), \(storeJSON));
        const __writes = __objectCreate(null);
        const __deletes = __objectCreate(null);
        let __nextID = 0;
        let __closed = false;

        function __normalize(value) {
          if (value === undefined) return null;
          return __jsonParse(__jsonStringify(value));
        }
        function __serializeText(value) {
          if (typeof value === 'string') return value;
          if (value === undefined) return 'undefined';
          if (value === null || ['boolean', 'number', 'bigint'].includes(typeof value)) return __String(value);
          const rendered = __jsonStringify(value);
          return rendered === undefined ? __String(value) : rendered;
        }
        function __callTool(name, args) {
          if (__closed) return __Promise.reject(new __Error('Code-mode cell is already closed.'));
          return new __Promise((resolve, reject) => {
            const id = __String(++__nextID);
            const pending = __objectCreate(null);
            pending.resolve = resolve;
            pending.reject = reject;
            __pending[id] = pending;
            __host.toolCall(id, name, __jsonStringify(args ?? {}));
          });
        }
        function __resolveTool(id, ok, payload, error) {
          if (__closed) return;
          const pending = __pending[id];
          if (!pending) return;
          delete __pending[id];
          if (ok) pending.resolve(__jsonParse(payload)); else pending.reject(new __Error(error));
        }
        function __install(path, name) {
          var target = tools;
          for (let index = 0; index < path.length - 1; index += 1) {
            target[path[index]] ??= __objectCreate(null);
            target = target[path[index]];
          }
          target[path[path.length - 1]] = (args = {}) => __callTool(name, args);
          tools[name] ??= (args = {}) => __callTool(name, args);
        }
        for (const definition of ALL_TOOLS) __install(definition.path, definition.name);
        function __emit(block, shouldYield = false) {
          if (__closed) return block;
          __host.emit(__jsonStringify(block), __Boolean(shouldYield));
          return block;
        }
        function text(value) {
          const rendered = __serializeText(value);
          __emit({type: 'text', text: rendered});
        }
        function __imageBlock(value, detailOverride = null) {
          let imageUrl = null;
          let detail = null;
          if (typeof value === 'string') {
            imageUrl = value;
          } else if (value && typeof value === 'object' && !__arrayIsArray(value)) {
            if (typeof value.image_url === 'string') {
              imageUrl = value.image_url;
              if (value.detail != null && typeof value.detail !== 'string') throw new TypeError('image detail must be a string when provided');
              detail = value.detail ?? null;
            } else if (value.type === 'image' && typeof value.data === 'string' && value.data.length > 0) {
              const mimeType = value.mimeType ?? value.mime_type ?? 'application/octet-stream';
              imageUrl = /^data:/i.test(value.data) ? value.data : `data:${mimeType};base64,${value.data}`;
              detail = value?._meta?.['codex/imageDetail'] ?? null;
            }
          }
          if (typeof imageUrl !== 'string' || imageUrl.length === 0) {
            throw new __TypeError('image expects a non-empty image URL string, an object with image_url and optional detail, or a raw MCP image block');
          }
          if (/^https?:/i.test(imageUrl)) {
            throw new TypeError('Tool call failed: remote image URLs are not supported in tool outputs. Pass a base64 data URI instead');
          }
          if (detailOverride != null && typeof detailOverride !== 'string') throw new __TypeError('image detail must be a string when provided');
          detail = detailOverride ?? detail ?? 'high';
          detail = __String(detail).toLowerCase();
          if (!['auto', 'low', 'high', 'original'].includes(detail)) {
            throw new __TypeError('image detail must be one of: auto, low, high, original');
          }
          return {type: 'image', image_url: imageUrl, detail};
        }
        function image(value, detail = null) {
          __emit(__imageBlock(value, detail));
        }
        function generatedImage(value) {
          if (!value || typeof value !== 'object' || __arrayIsArray(value)) throw new __TypeError('generatedImage expects an image generation result object');
          if (value.output_hint !== undefined && typeof value.output_hint !== 'string') throw new __TypeError('generatedImage output_hint must be a string when provided');
          __emit(__imageBlock(value));
          if (value.output_hint !== undefined) __emit({type: 'text', text: value.output_hint});
        }
        function notify(value) {
          const rendered = __serializeText(value);
          __emit({type: 'text', text: rendered, notification: true}, true);
          return value;
        }
        function store(key, value) {
          if (__closed) throw new __Error('Code-mode cell is already closed.');
          key = __String(key);
          if (value === undefined) {
            delete __store[key]; delete __writes[key]; __deletes[key] = true; return undefined;
          }
          const normalized = __normalize(value);
          __store[key] = normalized; __writes[key] = normalized; delete __deletes[key]; return value;
        }
        function load(key) { return __store[__String(key)]; }
        function exit() { throw new __Error('__CODE_MODE_EXIT__'); }
        function setTimeout(callback, milliseconds = 0) {
          if (__closed) throw new __Error('Code-mode cell is already closed.');
          const id = __String(++__nextID);
          __timers[id] = callback;
          __host.setTimer(id, __Number(milliseconds));
          return id;
        }
        function clearTimeout(id) { delete __timers[__String(id)]; }
        function __fireTimer(id) {
          if (__closed) return;
          id = __String(id);
          const callback = __timers[id];
          if (!callback) return;
          delete __timers[id];
          callback();
        }
        async function yield_control() {
          if (!__closed) __host.yield();
          await __promiseResolve();
        }
        function __complete(value, error = null) {
          if (__closed) return;
          __closed = true;
          var normalized = null;
          var completionError = error;
          if (completionError === null) {
            try { normalized = __normalize(value); }
            catch (normalizationError) { completionError = __String(normalizationError); }
          }
          try {
            const deletes = __objectKeys(__deletes);
            __setPrototypeOf(deletes, null);
            const payload = __objectCreate(null);
            payload.value = normalized;
            payload.error = completionError;
            payload.writes = __writes;
            payload.deletes = deletes;
            __host.complete(__jsonStringify(payload));
          } catch (completionSerializationError) {
            const fallbackDeletes = [];
            __setPrototypeOf(fallbackDeletes, null);
            const fallback = __objectCreate(null);
            fallback.value = null;
            fallback.error = __String(completionSerializationError);
            fallback.writes = __objectCreate(null);
            fallback.deletes = fallbackDeletes;
            __host.complete(__jsonStringify(fallback));
          }
        }

        Object.assign(globalThis, {
          ALL_TOOLS, tools, text, image, generatedImage, notify, store, load,
          exit, setTimeout, clearTimeout, yield_control
        });
        const __bridge = Object.freeze({resolveTool: __resolveTool, fireTimer: __fireTimer});
        try {
          const __AsyncFunction = Object.getPrototypeOf(async function() {}).constructor;
          const __runUser = new __AsyncFunction(\(sourceJSON));
          __promiseThen(__runUser(),
            value => __complete(value),
            error => {
              if (__String(error && error.message) === '__CODE_MODE_EXIT__') __complete(null);
              else __complete(null, __String(error));
            }
          );
        } catch (error) {
          __complete(null, __String(error));
        }
        return __bridge;
      })();
      """
  }

  private static func jsonString(_ value: JSONValue) -> String? {
    guard let data = try? JSONEncoder.codexCompact.encode(value) else { return nil }
    return String(data: data, encoding: .utf8)
  }
}
