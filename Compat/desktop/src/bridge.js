(() => {
  const send = request => {
    window.__TAURI_INTERNALS__.invoke('dispatch', { request }).then(
      reply => window.__rbnReply?.(reply),
      error => window.__rbnReply?.({ id: request.id, error: String(error) })
    );
  };
  const handler = Object.freeze({ postMessage: send });
  if (window.webkit?.messageHandlers) {
    // WebKitGTK already owns this namespace. Preserve its ipc handler, which
    // Wry uses internally to deliver the invoke call to the native process.
    Object.defineProperty(window.webkit.messageHandlers, 'rclone', { value: handler });
  } else {
    Object.defineProperty(window, 'webkit', {
      value: Object.freeze({ messageHandlers: Object.freeze({ rclone: handler }) })
    });
  }
  window.addEventListener('keydown', event => {
    if ((event.ctrlKey || event.metaKey) && !event.altKey && event.key.toLowerCase() === 'q') {
      event.preventDefault();
      window.__TAURI_INTERNALS__.invoke('request_quit').catch(() => {});
    }
  }, true);
})();
