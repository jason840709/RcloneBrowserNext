(async () => {
  try {
    for (let i = 0; i < 100; i++) {
      if (window.rclone && document.querySelectorAll('.browser-pane').length === 2) break;
      await new Promise(resolve => setTimeout(resolve, 100));
    }
    const boot = await window.rclone.bootstrap();
    const widthBefore = window.innerWidth;
    await window.rclone.saveSettings({ interfaceScale: 125 });
    await new Promise(resolve => setTimeout(resolve, 300));
    const widthZoomed = window.innerWidth;
    await window.rclone.saveSettings({ interfaceScale: 100 });
    await window.__TAURI_INTERNALS__.invoke('smoke_result', { payload: {
      panes: document.querySelectorAll('.browser-pane').length,
      buttons: document.querySelectorAll('button').length,
      platform: boot.environment.platform,
      language: boot.resolvedLanguage,
      widthBefore, widthZoomed,
      webkit: typeof window.webkit?.messageHandlers?.rclone?.postMessage,
      error: null
    }});
  } catch (error) {
    await window.__TAURI_INTERNALS__.invoke('smoke_result', { payload: {error: String(error)} });
  }
})();
