#!/usr/bin/env python3
"""Diagnose an installed Windows release through its real WebView2 and engine.

Run only on a disposable GitHub Actions Windows user. No browser download,
product patch, JavaScript host mock, DOM click, or external account is used.
The normal app gets a fresh settings directory and local rclone alias remotes.
CDP is enabled for this child only and bound to loopback. References:
https://playwright.dev/python/docs/webview2
https://learn.microsoft.com/en-us/microsoft-edge/webview2/how-to/debug-visual-studio-code

Exit 0 means the diagnostic completed, even if product checks failed. Inspect
probe-ui.json's passed/cases. Exit 2 means startup/attachment/setup was incomplete.
"""
from __future__ import annotations

import argparse
import asyncio
import ctypes
from ctypes import wintypes
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import socket
import subprocess
import tempfile
import time
import traceback
import urllib.request


APP_ID = "org.rclone.browser.next"
EVENT_OBSERVER = r"""() => {
  if (window.__windowsProbeEvents) return;
  window.__windowsProbeEvents = [];
  const describe = node => {
    if (!(node instanceof Element)) return String(node?.nodeName || '');
    const item = node.closest('[role="option"],button,input,[role="combobox"]') || node;
    return {tag:item.tagName, role:item.getAttribute('role'), class:item.className?.baseVal ?? item.className,
      value:item.getAttribute('data-value'), label:item.getAttribute('aria-label'),
      disabled:item.getAttribute('aria-disabled'), text:(item.textContent || '').trim().slice(0,120)};
  };
  for (const type of ['pointerdown','pointerup','click','dblclick','keydown','focusin','focusout']) {
    document.addEventListener(type, event => {
      const entry = {type, trusted:event.isTrusted, time:performance.now(), target:describe(event.target),
        key:event.key, button:event.button, x:event.clientX, y:event.clientY,
        related:describe(event.relatedTarget), prevented:event.defaultPrevented};
      window.__windowsProbeEvents.push(entry);
      if (window.__windowsProbeEvents.length > 1200) window.__windowsProbeEvents.shift();
      queueMicrotask(() => {entry.prevented = event.defaultPrevented;});
    }, true);
  }
}"""
DOM_SNAPSHOT = r"""() => {
  const box = element => {const r=element.getBoundingClientRect();return {x:r.x,y:r.y,width:r.width,height:r.height};};
  return {url:location.href, userAgent:navigator.userAgent, width:innerWidth,height:innerHeight,
    devicePixelRatio, activeElement:document.activeElement?.outerHTML?.slice(0,700),
    pageOverflow:document.documentElement.scrollWidth>innerWidth,
    panes:Array.from(document.querySelectorAll('.browser-pane')).map(p=>({
      side:p.getAttribute('data-pane-side'),path:p.querySelector('.path-form input')?.value,
      remote:p.querySelector('.path-endpoint-name')?.textContent || null,
      busy:p.querySelector('.file-list')?.getAttribute('aria-busy'),
      files:Array.from(p.querySelectorAll('.file-name')).map(e=>e.getAttribute('title')).slice(0,35),
      error:p.querySelector('[role="alert"]')?.textContent || null,rect:box(p)})),
    triggers:Array.from(document.querySelectorAll('.location-trigger')).map(e=>({
      title:e.title,disabled:e.disabled,expanded:e.getAttribute('aria-expanded'),rect:box(e)})),
    popups:Array.from(document.querySelectorAll('.location-popup')).map(p=>({rect:box(p),
      options:Array.from(p.querySelectorAll('[role="option"]')).map(e=>({value:e.getAttribute('data-value'),
        disabled:e.getAttribute('aria-disabled'),selected:e.getAttribute('aria-selected'),rect:box(e)}))})),
    dialogs:Array.from(document.querySelectorAll('dialog[open]')).map(d=>({class:d.className,rect:box(d)})),
    alerts:Array.from(document.querySelectorAll('[role="alert"],.engine-banner')).map(e=>e.textContent),
    events:(window.__windowsProbeEvents || []).slice(-140)};
}"""


def write_json(path: Path, value) -> None:
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def normalized_path(value: str) -> str:
    return value.replace("\\", "/").rstrip("/").casefold()


def child_environment(directory: Path) -> dict[str, str]:
    environment = {key: value for key, value in os.environ.items()
                   if not key.upper().startswith("RCLONE_") and key.casefold() != "path"}
    system = Path(next((value for key, value in environment.items()
                       if key.casefold() == "systemroot"), r"C:\Windows"))
    # The installed app must resolve its own runtime, not a Swift SDK or a
    # development rclone inherited from the Actions runner's PATH.
    environment["PATH"] = os.pathsep.join(map(str, [system / "System32", system,
                                                   system / "System32/WindowsPowerShell/v1.0"]))
    temporary = directory / "tmp"
    temporary.mkdir()
    environment.update(TMPDIR=str(temporary), TMP=str(temporary), TEMP=str(temporary))
    return environment


def roaming_directory() -> Path:
    # Match the Windows Known Folder location used by Tauri, not an assumed
    # APPDATA override that a Known Folder API may ignore.
    buffer = ctypes.create_unicode_buffer(32768)
    result = ctypes.windll.shell32.SHGetFolderPathW(None, 0x001A, None, 0, buffer)
    if result != 0 or not buffer.value:
        raise OSError(f"Cannot resolve the disposable user's Roaming AppData: {result}")
    return Path(buffer.value)


def native_window(pid: int):
    user32 = ctypes.windll.user32
    found = []
    callback_type = ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HWND, wintypes.LPARAM)
    user32.EnumWindows.argtypes = [callback_type, wintypes.LPARAM]
    user32.GetWindowThreadProcessId.argtypes = [wintypes.HWND, ctypes.POINTER(wintypes.DWORD)]
    user32.IsWindowVisible.argtypes = [wintypes.HWND]
    user32.GetWindowTextW.argtypes = [wintypes.HWND, wintypes.LPWSTR, ctypes.c_int]

    @callback_type
    def visit(hwnd, _):
        owner = wintypes.DWORD()
        user32.GetWindowThreadProcessId(hwnd, ctypes.byref(owner))
        if owner.value == pid and user32.IsWindowVisible(hwnd):
            title = ctypes.create_unicode_buffer(512)
            user32.GetWindowTextW(hwnd, title, len(title))
            if title.value == "Rclone Browser Next":
                found.append(hwnd)
        return True

    user32.EnumWindows(visit, 0)
    if not found:
        raise RuntimeError("No visible Rclone Browser Next window belongs to the launched process")
    return found[0]


def resize_native(pid: int, width: int, height: int) -> dict:
    user32 = ctypes.windll.user32
    hwnd = native_window(pid)
    user32.GetWindowRect.argtypes = [wintypes.HWND, ctypes.POINTER(wintypes.RECT)]
    user32.GetClientRect.argtypes = [wintypes.HWND, ctypes.POINTER(wintypes.RECT)]
    user32.ShowWindow.argtypes = [wintypes.HWND, ctypes.c_int]
    user32.SetWindowPos.argtypes = [wintypes.HWND, wintypes.HWND, ctypes.c_int, ctypes.c_int, ctypes.c_int, ctypes.c_int, wintypes.UINT]
    user32.SetForegroundWindow.argtypes = [wintypes.HWND]
    user32.GetDpiForWindow.argtypes = [wintypes.HWND]
    user32.GetDpiForWindow.restype = wintypes.UINT
    dpi = user32.GetDpiForWindow(hwnd) or 96
    user32.ShowWindow(hwnd, 9)  # SW_RESTORE
    outer, client = wintypes.RECT(), wintypes.RECT()
    user32.GetWindowRect(hwnd, ctypes.byref(outer))
    user32.GetClientRect(hwnd, ctypes.byref(client))
    extra_w = outer.right - outer.left - client.right
    extra_h = outer.bottom - outer.top - client.bottom
    physical_w, physical_h = round(width * dpi / 96), round(height * dpi / 96)
    user32.SetWindowPos(hwnd, None, 30, 30, physical_w + extra_w, physical_h + extra_h, 0x0004)
    user32.SetForegroundWindow(hwnd)
    user32.GetClientRect(hwnd, ctypes.byref(client))
    user32.GetWindowRect(hwnd, ctypes.byref(outer))
    return {"requestedClientDIP": {"width": width, "height": height}, "dpi": dpi,
            "clientPhysical": {"width": client.right, "height": client.bottom},
            "outerPhysical": {"x": outer.left, "y": outer.top,
                              "width": outer.right - outer.left, "height": outer.bottom - outer.top}}


def fixed_drives() -> list[str]:
    kernel32 = ctypes.windll.kernel32
    kernel32.GetLogicalDrives.restype = wintypes.DWORD
    kernel32.GetDriveTypeW.argtypes = [wintypes.LPCWSTR]
    mask = kernel32.GetLogicalDrives()
    return [f"{chr(65 + index)}:/" for index in range(26)
            if mask & (1 << index) and kernel32.GetDriveTypeW(f"{chr(65 + index)}:\\") == 3]


async def wait_cdp(port: int, process: subprocess.Popen, timeout: float = 90) -> dict:
    deadline = time.monotonic() + timeout
    last_error = ""
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise RuntimeError(f"product_startup_exit: app exited with {process.returncode} before CDP was available")
        try:
            def read():
                with urllib.request.urlopen(f"http://127.0.0.1:{port}/json/version", timeout=1) as response:
                    return json.load(response)
            return await asyncio.to_thread(read)
        except Exception as error:
            last_error = str(error)
            await asyncio.sleep(0.2)
    raise RuntimeError(f"cdp_attachment_unavailable: the app is still running; no conclusion about control behavior. {last_error}")


async def inspect(args, report: dict) -> None:
    from playwright.async_api import async_playwright, expect

    output = args.output.resolve()
    fixture = Path(tempfile.mkdtemp(prefix="rbn-windows-ui-", dir=os.environ.get("RUNNER_TEMP")))
    state = roaming_directory() / APP_ID
    owned_state = False
    process = None
    log = None
    browser = None
    context = None
    page = None
    tracing = False
    try:
        if state.exists():
            raise RuntimeError(f"isolated_profile_required: refusing to replace existing app data at {state}")
        state.mkdir()
        owned_state = True
        local_root = fixture / "local source 資料"
        local_root.mkdir()
        (local_root / "local-root-marker.txt").write_text("local root fixture\n", encoding="utf-8")
        (local_root / "child folder").mkdir()
        (local_root / "child folder" / "local-child-marker.txt").write_text("local child fixture\n", encoding="utf-8")
        right_root = fixture / "local destination 資料"
        right_root.mkdir()
        (right_root / "right-root-marker.txt").write_text("right root fixture\n", encoding="utf-8")
        aliases = []
        for index in range(1, 18):
            name = f"probe-{index:02d}"
            directory = fixture / f"alias {index:02d} 資料"
            directory.mkdir()
            marker = f"remote-{index:02d}-marker.txt"
            (directory / marker).write_text(f"{name}\n", encoding="utf-8")
            aliases.append({"name": name, "directory": str(directory), "marker": marker})
        config = fixture / "rclone-probe.conf"
        config.write_text("\n".join(f"[{item['name']}]\ntype = alias\nremote = {Path(item['directory']).as_posix()}\n" for item in aliases), encoding="utf-8")
        settings = {"settingsSchemaVersion": 7, "settingsRevision": 1,
                    "rclonePath": args.rclone.as_posix(), "rcloneDirectory": args.rclone.parent.as_posix(),
                    "configPath": config.as_posix(), "language": "en", "theme": "green-dark",
                    "interfaceScale": 100, "autoCheckUpdates": False,
                    "initialLocations": {"left": {"remote": None, "path": local_root.as_posix()},
                                         "right": {"remote": None, "path": right_root.as_posix()}}}
        write_json(state / "settings.json", settings)
        environment = child_environment(fixture)
        direct = subprocess.run([str(args.rclone), "--config", str(config), "listremotes"],
                                env=environment, capture_output=True, text=True, encoding="utf-8", timeout=30)
        report["fixture"] = {"directory": str(fixture), "stateDirectory": str(state),
                             "settings": settings, "aliases": aliases,
                             "childPath": environment["PATH"], "rcloneEnvironmentRemoved": True,
                             "rcloneListRemotes": {"exitCode": direct.returncode, "stdout": direct.stdout, "stderr": direct.stderr}}
        if direct.returncode or any(item["name"] + ":" not in direct.stdout.splitlines() for item in aliases):
            raise RuntimeError("fixture_setup_failed: pinned rclone could not read the synthetic alias configuration")
        with socket.socket() as listener:
            listener.bind(("127.0.0.1", 0))
            port = listener.getsockname()[1]
        environment["WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS"] = f"--remote-debugging-address=127.0.0.1 --remote-debugging-port={port}"
        environment["WEBVIEW2_USER_DATA_FOLDER"] = str(fixture / "webview2-profile")
        log = (output / "native.log").open("wb")
        process = subprocess.Popen([str(args.app)], cwd=args.app.parent, env=environment,
                                   stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT)
        report["appProcessID"] = process.pid
        report["cdp"] = {"address": f"http://127.0.0.1:{port}", "version": await wait_cdp(port, process)}
        async with async_playwright() as playwright:
            browser = await playwright.chromium.connect_over_cdp(f"http://127.0.0.1:{port}", timeout=15000)
            deadline = time.monotonic() + 30
            while page is None and time.monotonic() < deadline:
                for candidate_context in browser.contexts:
                    for candidate in candidate_context.pages:
                        if re.match(r"^(?:https?://tauri\.localhost|tauri://localhost)(?:/|$)", candidate.url):
                            context, page = candidate_context, candidate
                            break
                if page is None:
                    await asyncio.sleep(0.2)
            if page is None:
                raise RuntimeError("cdp_target_missing: no bundled application page was found")
            page.set_default_timeout(7000)
            report["pageErrors"], report["console"] = [], []
            page.on("pageerror", lambda error: report["pageErrors"].append(str(error)))
            page.on("console", lambda message: report["console"].append({"type": message.type, "text": message.text[:4000]}))
            await context.tracing.start(screenshots=True, snapshots=True, sources=False)
            tracing = True
            await page.wait_for_function("() => !!window.rclone && document.querySelectorAll('.browser-pane').length === 2", timeout=90000)
            await page.evaluate(EVENT_OBSERVER)
            report["bootstrap"] = await page.evaluate("() => window.rclone.bootstrap()")
            report["initialWindow"] = resize_native(process.pid, 1280, 800)
            await page.wait_for_timeout(350)
            report["initialDOM"] = await page.evaluate(DOM_SNAPSHOT)
            report["cases"] = []

            async def run_case(name, callback, trusted_input=True):
                start = time.monotonic()
                event_start = await page.evaluate("() => performance.now()")
                result = {"name": name, "passed": False}
                try:
                    result["observed"] = await callback()
                    events = await page.evaluate("since => (window.__windowsProbeEvents || []).filter(e=>e.time>=since)", event_start)
                    result["trustedClicks"] = sum(event["type"] in ["click", "dblclick"] and event["trusted"] for event in events)
                    result["trustedKeys"] = sum(event["type"] == "keydown" and event["trusted"] for event in events)
                    if trusted_input and not result["trustedClicks"] and not result["trustedKeys"]:
                        raise AssertionError("No trusted pointer or keyboard input was observed")
                    result["passed"] = True
                except Exception as error:
                    result["error"] = str(error)
                    result["traceback"] = traceback.format_exc()
                result["seconds"] = round(time.monotonic() - start, 3)
                try:
                    result["dom"] = await page.evaluate(DOM_SNAPSHOT)
                    filename = re.sub(r"[^a-zA-Z0-9_-]", "-", name) + ".png"
                    await page.screenshot(path=str(output / filename), animations="disabled", timeout=7000)
                    result["screenshot"] = filename
                except Exception as error:
                    result["evidenceError"] = str(error)
                report["cases"].append(result)
                write_json(output / "probe-ui.json", report)
                print(f"{'PASS' if result['passed'] else 'FAIL'} {name}", flush=True)
                # A failed popup inside Settings can require two Escape keys:
                # dismiss the popup first, then the dialog. Preserve its DOM
                # and screenshot above before recovering through real input.
                for _ in range(3):
                    if not await page.locator(".location-popup, dialog[open]").count():
                        break
                    await page.keyboard.press("Escape")
                    await page.wait_for_timeout(60)

            async def type_text(locator, value):
                await locator.click()
                await locator.press("Control+A")
                await page.keyboard.type(value, delay=1)

            async def choose(trigger, name, keyboard=False):
                await trigger.click()
                popup = page.locator(".location-popup")
                await expect(popup).to_be_visible()
                if keyboard:
                    search = popup.get_by_role("combobox")
                    await type_text(search, name)
                    await expect(popup.locator('[role="option"]')).to_have_count(1)
                    await search.press("Enter")
                else:
                    option = popup.locator(f'[role="option"][data-value="{name}"]')
                    if await option.get_attribute("aria-disabled") == "true":
                        raise AssertionError(f"Remote {name} is aria-disabled; investigate environment.available before event handling")
                    await option.click()
                await expect(popup).to_have_count(0)

            async def remote_case(side, alias, keyboard=False):
                pane = page.get_by_test_id(f"{side}-pane")
                await choose(pane.locator(".location-trigger"), alias["name"], keyboard)
                await expect(pane.locator(".path-endpoint-name")).to_have_text(alias["name"] + ":")
                await expect(pane.locator(".file-list")).to_have_attribute("aria-busy", "false")
                await expect(pane.locator(f'.file-name[title="{alias["marker"]}"]')).to_be_visible(timeout=15000)
                await expect(pane.locator(".path-form input")).to_have_value("/")
                return {"side": side, "remote": alias["name"], "path": "", "realListingMarker": alias["marker"], "input": "keyboard" if keyboard else "pointer"}

            async def local_case(side):
                pane = page.get_by_test_id(f"{side}-pane")
                await choose(pane.locator(".location-trigger"), "@local:home")
                path_input = pane.locator(".path-form input")
                await type_text(path_input, str(local_root))
                await path_input.press("Enter")
                await expect(pane.locator('.file-name[title="local-root-marker.txt"]')).to_be_visible(timeout=15000)
                await pane.locator('.file-name[title="child folder"]').dblclick()
                await expect(pane.locator('.file-name[title="local-child-marker.txt"]')).to_be_visible(timeout=15000)
                assert normalized_path(await path_input.input_value()) == normalized_path(str(local_root / "child folder"))
                await pane.locator(".path-toolbar > .icon-button").nth(2).click()
                await expect(pane.locator('.file-name[title="local-root-marker.txt"]')).to_be_visible(timeout=15000)
                assert normalized_path(await path_input.input_value()) == normalized_path(str(local_root))
                return {"side": side, "root": str(local_root), "visitedChild": "child folder", "returnedToParent": True}

            async def drive_case():
                boot = await page.evaluate("() => window.rclone.bootstrap()")
                expected = fixed_drives()
                locations = boot.get("localLocations", [])
                roots = {normalized_path(item.get("path", "")) for item in locations}
                report["driveCatalog"] = {"windowsFixedDrives": expected, "locations": locations,
                                          "missing": [root for root in expected if normalized_path(root) not in roots]}
                assert not report["driveCatalog"]["missing"], f"Fixed drives absent from the location catalog: {report['driveCatalog']['missing']}"
                pane = page.get_by_test_id("left-pane")
                await pane.locator(".location-trigger").click()
                for location in locations:
                    if normalized_path(location.get("path", "")) in {normalized_path(root) for root in expected}:
                        await expect(page.locator(f'.location-popup [data-value="@local:{location["id"]}"]')).to_have_count(1)
                return report["driveCatalog"]

            async def settings_dialog():
                await page.get_by_role("button", name="Settings", exact=True).click()
                dialog = page.locator(".settings-dialog")
                await expect(dialog).to_be_visible()
                return dialog

            async def editor_case(alias):
                dialog = await settings_dialog()
                trigger = dialog.locator(".startup-location-editors .location-trigger").last
                await choose(trigger, alias["name"], True)
                await expect(trigger).to_have_attribute("title", re.compile(re.escape(alias["name"])))
                deadline = time.monotonic() + 8
                boot = None
                while time.monotonic() < deadline:
                    boot = await page.evaluate("() => window.rclone.bootstrap()")
                    if boot["settings"]["initialLocations"].get("right", {}).get("remote") == alias["name"]:
                        break
                    await asyncio.sleep(0.1)
                assert boot["settings"]["initialLocations"]["right"]["remote"] == alias["name"]
                await dialog.locator(".dialog-footer button").last.click()
                return {"persistedStartupRight": boot["settings"]["initialLocations"]["right"]}

            async def scale_case():
                # Close any prior dialog with a real Escape key before opening
                # settings. Size changes use Win32, never viewport emulation.
                await page.keyboard.press("Escape")
                before = await page.evaluate("() => ({width:innerWidth,height:innerHeight})")
                dialog = await settings_dialog()
                await dialog.locator(".preferences-tabs button").nth(1).click()
                await dialog.locator('.interface-scale-picker label:has(input[value="125"])').click()
                await expect(dialog.locator('input[value="125"]')).to_be_checked()
                await page.wait_for_function("before => innerWidth < before.width - 30", arg=before)
                await dialog.locator(".dialog-footer button").last.click()
                window = resize_native(process.pid, 880, 600)
                await page.wait_for_timeout(400)
                boot = await page.evaluate("() => window.rclone.bootstrap()")
                assert boot["settings"]["interfaceScale"] == 125
                return {"before": before, "window": window, "cssViewport": await page.evaluate("() => ({width:innerWidth,height:innerHeight})")}

            for side in ["left", "right"]:
                for alias in [aliases[0], aliases[8], aliases[-1]]:
                    await run_case(f"normal-{side}-pointer-{alias['name']}", lambda side=side, alias=alias: remote_case(side, alias))
                await run_case(f"normal-{side}-keyboard-middle", lambda side=side: remote_case(side, aliases[8], True))
                await run_case(f"normal-{side}-local-navigation", lambda side=side: local_case(side))
            await run_case("windows-drive-catalog", drive_case, trusted_input=False)
            if not args.core_only:
                await run_case("endpoint-editor-startup-remote", lambda: editor_case(aliases[-1]))
                await run_case("native-minimum-window-125-percent", scale_case)
                for side in ["left", "right"]:
                    for alias in [aliases[0], aliases[8], aliases[-1]]:
                        await run_case(f"compact-{side}-pointer-{alias['name']}", lambda side=side, alias=alias: remote_case(side, alias))
                    await run_case(f"compact-{side}-keyboard-middle", lambda side=side: remote_case(side, aliases[8], True))
                await run_case("compact-endpoint-editor-startup-remote", lambda: editor_case(aliases[0]))
            report["finalBootstrap"] = await page.evaluate("() => window.rclone.bootstrap()")
            report["completed"] = True
            report["passed"] = all(case["passed"] for case in report["cases"]) and not report["pageErrors"]
            report["totals"] = {"passed": sum(case["passed"] for case in report["cases"]),
                                "failed": sum(not case["passed"] for case in report["cases"])}
            await context.tracing.stop(path=str(output / "trace.zip"))
            tracing = False
    except Exception as error:
        report["completed"] = False
        report["passed"] = False
        report["incompleteReason"] = str(error)
        report["incompleteTraceback"] = traceback.format_exc()
        if page is not None:
            try:
                report["incompleteDOM"] = await page.evaluate(DOM_SNAPSHOT)
                await page.screenshot(path=str(output / "incomplete.png"), timeout=5000)
            except Exception:
                pass
        if tracing and context is not None:
            try:
                await context.tracing.stop(path=str(output / "trace.zip"))
            except Exception:
                pass
    finally:
        cleanup_errors = []
        if process is not None:
            report["appExitBeforeCleanup"] = process.poll()
            if process.poll() is None:
                try:
                    subprocess.run(["taskkill.exe", "/PID", str(process.pid), "/T", "/F"], capture_output=True, timeout=30)
                    process.wait(timeout=10)
                except Exception as error:
                    cleanup_errors.append(str(error))
        if log is not None:
            log.close()
        if owned_state:
            saved = state / "settings.json"
            if saved.is_file():
                try:
                    shutil.copyfile(saved, output / "final-settings.json")
                except Exception as error:
                    cleanup_errors.append(str(error))
            shutil.rmtree(state, ignore_errors=True)
            report["ownedStateRemoved"] = not state.exists()
        shutil.rmtree(fixture, ignore_errors=True)
        if cleanup_errors:
            report["cleanupErrors"] = cleanup_errors
        report["finishedAt"] = datetime.now(timezone.utc).isoformat()
        write_json(output / "probe-ui.json", report)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--rclone", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--label", default="installed-release")
    parser.add_argument("--core-only", action="store_true", help="Only remote choices, local navigation and drive visibility")
    args = parser.parse_args()
    args.app, args.rclone, args.output = args.app.resolve(), args.rclone.resolve(), args.output.resolve()
    args.output.mkdir(parents=True, exist_ok=True)
    report = {"schemaVersion": 1, "label": args.label, "startedAt": datetime.now(timezone.utc).isoformat(),
              "completed": False, "passed": False, "method": "Installed normal-mode WebView2 via loopback CDP; trusted pointer/keyboard, real bundled helper and local rclone alias configuration",
              "limits": ["Disposable CI user and synthetic local aliases only; no real cloud account or user data.",
                         "This is diagnostic evidence. A completed job does not mean every product case passed; inspect passed/cases."]}
    if os.name != "nt" or os.environ.get("GITHUB_ACTIONS", "").lower() != "true":
        report["incompleteReason"] = "isolated_profile_required: this probe runs only on a disposable GitHub Actions Windows user"
        write_json(args.output / "probe-ui.json", report)
        return 2
    if not args.app.is_file() or not args.rclone.is_file():
        report["incompleteReason"] = "fixture_setup_failed: the installed app or pinned rclone executable is missing"
        write_json(args.output / "probe-ui.json", report)
        return 2
    report["app"] = {"path": str(args.app), "sha256": sha256(args.app)}
    report["rclone"] = {"path": str(args.rclone), "sha256": sha256(args.rclone)}
    ctypes.windll.user32.SetProcessDpiAwarenessContext.argtypes = [ctypes.c_void_p]
    ctypes.windll.user32.SetProcessDpiAwarenessContext(ctypes.c_void_p(-4))
    try:
        asyncio.run(inspect(args, report))
    except Exception as error:
        report["incompleteReason"] = str(error)
        report["incompleteTraceback"] = traceback.format_exc()
        write_json(args.output / "probe-ui.json", report)
    print(json.dumps({key: report.get(key) for key in ["label", "completed", "passed", "totals", "incompleteReason"]}, ensure_ascii=False), flush=True)
    return 0 if report.get("completed") else 2


if __name__ == "__main__":
    raise SystemExit(main())
