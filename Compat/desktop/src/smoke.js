(async () => {
  try {
    for (let i = 0; i < 100; i++) {
      if (window.rclone && document.querySelectorAll('.browser-pane').length === 2) break;
      await new Promise(resolve => setTimeout(resolve, 100));
    }
    const boot = await window.rclone.bootstrap();
    const widthBefore = window.innerWidth;
    const themeBefore = document.documentElement.dataset.theme;
    await window.rclone.saveSettings({ interfaceScale: 125 });
    await new Promise(resolve => setTimeout(resolve, 300));
    const widthZoomed = window.innerWidth;
    await window.rclone.saveSettings({ interfaceScale: 100 });
    await new Promise(resolve => setTimeout(resolve, 300));
    const track = document.createElement('div');
    track.className = 'progress-track indeterminate';
    track.style.cssText = 'position:fixed;bottom:10px;left:10px;width:320px;height:4px;';
    const marker = document.createElement('span'); marker.className = 'progress-indicator';
    track.append(marker); document.body.append(track);
    const motionSamples = [];
    for (let i=0;i<5;i++) {
      motionSamples.push(getComputedStyle(marker).transform);
      await new Promise(resolve => setTimeout(resolve, 180));
    }
    const reduced = matchMedia('(prefers-reduced-motion: reduce)').matches;
    const progressMotion = {
      reduced, samples: motionSamples,
      animation: getComputedStyle(marker).animationName,
      passed: reduced ? getComputedStyle(marker).animationName === 'none'
        : getComputedStyle(marker).animationName === 'progress-sweep' && new Set(motionSamples).size > 1
    };
    track.remove();
    await window.__TAURI_INTERNALS__.invoke('smoke_result', { payload: {
      progressMotion,
      panes: document.querySelectorAll('.browser-pane').length,
      buttons: document.querySelectorAll('button').length,
      platform: boot.environment.platform,
      language: boot.resolvedLanguage,
      widthBefore, widthZoomed, widthRestored: window.innerWidth,
      scaleBefore: boot.settings.interfaceScale,
      initialTheme: window.__rbnInitialAppearance?.theme, themeBefore,
      webkit: typeof window.webkit?.messageHandlers?.rclone?.postMessage,
      error: null
    }});
  } catch (error) {
    await window.__TAURI_INTERNALS__.invoke('smoke_result', { payload: {error: String(error)} });
  }
})();
