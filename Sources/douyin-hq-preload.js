/* 抖音「高画质模式」补丁 —— 只注入到隔离副本里，原版应用不受影响。
 *
 * 作用：让页面里的 MediaSource.isTypeSupported 对 H.266（bvc2）返回 false，
 * 客户端就不会优先走 H.266 分支，改走 H.265 分支，于是服务端早就下发好的
 * 2K / 4K 码流能出现在画质菜单里。H.265 / H.264 的能力检测原样保留。
 *
 * 背景与完整调查过程见 NOTES-抖音4K画质.md。
 * 环境变量 PROXYLAUNCHER_H266_TEST=0 可以关掉补丁（对照组用）。
 */
(function proxyLauncherH266Test() {
  if (process.env && process.env.PROXYLAUNCHER_H266_TEST === '0') {
    console.warn('[ProxyLauncher H266 test] baseline: patch disabled');
    return;
  }
  function install() {
    const tag = '[ProxyLauncher H266 test]';
    if (typeof MediaSource === 'undefined' || typeof MediaSource.isTypeSupported !== 'function') {
      console.warn(tag + ' unavailable: MediaSource.isTypeSupported');
      return { installed: false };
    }
    const original = MediaSource.isTypeSupported;
    const marker = Symbol.for('ProxyLauncher.H266Test');
    if (original[marker]) return { installed: true, alreadyInstalled: true };
    const descriptor = Object.getOwnPropertyDescriptor(MediaSource, 'isTypeSupported');
    if (!descriptor || !('value' in descriptor)) {
      console.warn(tag + ' unexpected capability descriptor');
      return { installed: false };
    }
    let blocked = 0;
    const replacement = function isTypeSupported(type) {
      if (typeof type === 'string' && /\bbvc2(?:[.\s";]|$)/i.test(type)) {
        if (blocked++ < 3) console.warn(tag + ' bvc2 capability disabled');
        return false;
      }
      return Reflect.apply(original, this, arguments);
    };
    Object.defineProperty(replacement, marker, { value: true });
    Object.defineProperty(MediaSource, 'isTypeSupported', { ...descriptor, value: replacement });
    const hevc = MediaSource.isTypeSupported('video/mp4;codecs=hev1.1.6.L93.B0');
    console.warn(tag + ' installed; HEVC=' + hevc);
    // 打个标记，方便在页面里确认补丁是否真的装上了
    globalThis.__PROXYLAUNCHER_HQ__ = { patched: true, hevc: hevc, at: Date.now() };
    return { installed: true, hevc };
  }
  try {
    let result;
    if (process.contextIsolated) {
      const bridge = require('electron').contextBridge;
      if (typeof bridge.executeInMainWorld !== 'function') {
        console.warn('[ProxyLauncher H266 test] executeInMainWorld unavailable');
        return;
      }
      result = bridge.executeInMainWorld({ func: install });
    } else {
      result = install();
    }
    console.warn('[ProxyLauncher H266 test] preload result=' + JSON.stringify(result));
  } catch (error) {
    console.error('[ProxyLauncher H266 test] install failed: ' + String(error));
  }
})();
