use tauri::menu::{Menu, MenuItem, PredefinedMenuItem, Submenu};
use tauri::Manager;
use tauri_plugin_deep_link::DeepLinkExt;

/// Menu item id for the manual "Reload" action (PB-156).
const RELOAD_MENU_ID: &str = "plane-reload";

/// Base URL of the Plane instance, used for BOTH the window's start URL and the
/// deep-link target (so `plane://…` always resolves onto the same host the app
/// shows). Plane's proxy serves the SPA on the bare "localhost" host, and the
/// SPA renders deep paths (e.g. /pb/browse/PB-110) directly.
///
/// `init-plane app` templates this at build time by replacing the literal
/// `http://localhost:1800` below with the user's resolved Plane URL (see the
/// `__PLANE_BASE__` substitution in commands/init-plane.sh). The committed
/// default keeps the bare-build / unit-test path working.
const PLANE_BASE: &str = "http://localhost:1800"; // __PLANE_BASE__

/// Translate a `plane://` deep-link URI into the real http URL to load.
///
/// Accepted forms (everything after the scheme is treated as a path):
///   plane://pb/browse/PB-110                  -> http://localhost:1800/pb/browse/PB-110
///   plane://localhost:1800/pb/browse/PB-110   -> http://localhost:1800/pb/browse/PB-110
///   plane://plane.localhost:1800/pb/browse/.. -> http://localhost:1800/pb/browse/..
///   plane:pb/browse/PB-110                    -> http://localhost:1800/pb/browse/PB-110
///
/// Returns `None` for anything that is not a `plane:` URI or that has an empty
/// path (so callers can fall back to the home page).
fn plane_uri_to_http(uri: &str) -> Option<String> {
    let trimmed = uri.trim();
    // Strip the scheme, tolerating both `plane://` and the rarer `plane:` form.
    let rest = trimmed
        .strip_prefix("plane://")
        .or_else(|| trimmed.strip_prefix("plane:"))?;

    // Drop a leading slash if present, then split off any host:port prefix that
    // some link generators may include.
    let mut path = rest.trim_start_matches('/');

    // If the first segment looks like a known host (optionally with a port),
    // discard it — we always target PLANE_BASE.
    if let Some((head, tail)) = path.split_once('/') {
        let host = head.split(':').next().unwrap_or(head);
        if host == "localhost" || host == "plane.localhost" {
            path = tail;
        }
    } else {
        // Single segment that is itself a bare host means "no real path".
        let host = path.split(':').next().unwrap_or(path);
        if host == "localhost" || host == "plane.localhost" {
            return None;
        }
    }

    let path = path.trim_start_matches('/');
    if path.is_empty() {
        return None;
    }

    Some(format!("{PLANE_BASE}/{path}"))
}

/// Find the first valid deep-link target among a set of URLs, if any.
fn first_target(urls: &[url::Url]) -> Option<String> {
    urls.iter().find_map(|u| plane_uri_to_http(u.as_str()))
}

/// Polyfill injected into the webview at document-start, before any Plane code runs.
///
/// Apple's WebKit (and therefore the WKWebView this app embeds) does NOT implement
/// `window.requestIdleCallback` / `cancelIdleCallback`. Plane's Board / spreadsheet
/// layout calls `requestIdleCallback(...)` to measure row heights; in the WebView that
/// call throws `TypeError: requestIdleCallback is not a function`, React Router's error
/// boundary catches it during render, and the entire Board view renders blank. The List
/// layout never touches that path, which is why only Board breaks. (Chrome/Firefox ship
/// the API, so the same Plane build works fine in a normal browser.)
///
/// This is the standard setTimeout-based shim. It only defines the functions when they
/// are missing, so a future WebKit that ships the real API is left untouched.
const RIC_POLYFILL: &str = r#"
(function () {
  if (typeof window.requestIdleCallback !== 'function') {
    window.requestIdleCallback = function (cb, opts) {
      var start = Date.now();
      return setTimeout(function () {
        cb({
          didTimeout: false,
          timeRemaining: function () { return Math.max(0, 50 - (Date.now() - start)); }
        });
      }, (opts && opts.timeout) ? Math.min(opts.timeout, 1) : 1);
    };
  }
  if (typeof window.cancelIdleCallback !== 'function') {
    window.cancelIdleCallback = function (id) { clearTimeout(id); };
  }

  // --- Zoom (Cmd +/-/0 and trackpad pinch) ----------------------------------
  // Tauri's `zoom_hotkeys_enabled` relies on a polyfill / native path that is
  // unreliable here: the webview loads a REMOTE http origin (Plane), and the
  // native setZoom route also needs the `webview:allow-set-webview-zoom`
  // capability we don't grant. So we implement zoom ourselves with CSS `zoom`,
  // which works on any origin, needs no Tauri permission, and survives Plane's
  // SPA navigation because this script re-runs at document-start every load.
  // Level is persisted so it sticks across navigations and restarts.
  (function () {
    var KEY = 'planeAppZoom';
    var MIN = 0.5, MAX = 3.0, STEP = 0.1;
    function get() {
      var v = parseFloat(localStorage.getItem(KEY));
      return (isFinite(v) && v > 0) ? v : 1.0;
    }
    function apply(z) {
      z = Math.min(MAX, Math.max(MIN, Math.round(z * 100) / 100));
      localStorage.setItem(KEY, String(z));
      var el = document.documentElement;
      if (el) el.style.zoom = z;
    }
    // Apply the saved level as soon as <html> exists.
    function init() { apply(get()); }
    if (document.documentElement) init();
    else document.addEventListener('DOMContentLoaded', init);

    window.addEventListener('keydown', function (e) {
      if (!(e.metaKey || e.ctrlKey)) return;
      var k = e.key;
      if (k === '=' || k === '+') { apply(get() + STEP); e.preventDefault(); }
      else if (k === '-' || k === '_') { apply(get() - STEP); e.preventDefault(); }
      else if (k === '0') { apply(1.0); e.preventDefault(); }
    }, true);

    // Trackpad pinch / Ctrl+wheel zoom.
    window.addEventListener('wheel', function (e) {
      if (!e.ctrlKey) return;
      e.preventDefault();
      apply(get() + (e.deltaY < 0 ? STEP : -STEP));
    }, { passive: false, capture: true });
  })();
})();
"#;

/// Navigate the main window to `target` and bring it to the foreground.
fn focus_and_navigate(app: &tauri::AppHandle, target: &str) {
    if let Some(win) = app.get_webview_window("main") {
        if let Ok(url) = target.parse() {
            let _ = win.navigate(url);
        }
        let _ = win.unminimize();
        let _ = win.show();
        let _ = win.set_focus();
    }
}

/// Reload the main window's current page in place (PB-156 manual refresh).
///
/// Uses a JS `location.reload()` eval rather than re-navigating to `PLANE_BASE`
/// so the user's current view (whatever issue/board/deep link they're on) comes
/// back with fresh data instead of bouncing them to the Plane home page.
fn reload_main_window(app: &tauri::AppHandle) {
    if let Some(win) = app.get_webview_window("main") {
        let _ = win.eval("window.location.reload();");
    }
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_deep_link::init())
        .setup(|app| {
            let handle = app.handle().clone();

            // Native "Reload" menu item (PB-156): View > Reload, Cmd+R.
            // Plane's own DOM is out of bounds (no injected on-page button),
            // so the manual-refresh control lives in the native menu instead.
            let reload_item = MenuItem::with_id(
                app,
                RELOAD_MENU_ID,
                "Reload",
                true,
                Some("CmdOrCtrl+R"),
            )?;
            let view_menu = Submenu::with_items(app, "View", true, &[&reload_item])?;
            let app_menu = Submenu::with_items(
                app,
                "Plane",
                true,
                &[
                    &PredefinedMenuItem::about(app, None, None)?,
                    &PredefinedMenuItem::separator(app)?,
                    &PredefinedMenuItem::quit(app, None)?,
                ],
            )?;
            let menu = Menu::with_items(app, &[&app_menu, &view_menu])?;
            app.set_menu(menu)?;
            app.on_menu_event(move |app, event| {
                if event.id() == RELOAD_MENU_ID {
                    reload_main_window(app);
                }
            });

            // Build the main window in Rust (rather than tauri.conf.json) so we can
            // attach an initialization script: it runs at document-start on EVERY
            // navigation, before any Plane code, which is the only place the
            // requestIdleCallback polyfill (see RIC_POLYFILL) can land early enough to
            // keep the Board layout from crashing in this WKWebView.
            let base = PLANE_BASE.parse().expect("PLANE_BASE is a valid URL");
            tauri::WebviewWindowBuilder::new(app, "main", tauri::WebviewUrl::External(base))
                .title("Plane")
                .inner_size(1400.0, 900.0)
                .min_inner_size(800.0, 600.0)
                .maximized(true)
                // Use macOS's default (visible) title bar rather than Overlay.
                // Overlay made the title bar transparent and floated the traffic
                // lights + window title ON TOP of the webview — but Plane's own web
                // header has no top inset, so the traffic lights collided with
                // Plane's workspace switcher / command bar. A normal title bar sits
                // ABOVE Plane's header instead, so nothing overlaps, with zero
                // coupling to Plane's DOM.
                // Enable the browser-style zoom hotkeys (Cmd +/-/0) inside the
                // WKWebView. Tauri does NOT wire these up by default, so without
                // this the app cannot zoom at all — Plane's dense Board/spreadsheet
                // views are unreadable on smaller displays. The flag is native
                // (maps to WKWebView magnification + the keyboard accelerators) and
                // needs no extra capability permission.
                .zoom_hotkeys_enabled(true)
                .initialization_script(RIC_POLYFILL)
                .build()?;

            // Cold launch: if the app was started by a plane:// link, the main
            // window (built just above to load the Plane home) is navigated to the
            // deep-linked page before the user sees it.
            if let Ok(Some(urls)) = app.deep_link().get_current() {
                if let Some(target) = first_target(&urls) {
                    focus_and_navigate(&handle, &target);
                }
            }

            // Links received while the app is already running.
            let handle = app.handle().clone();
            app.deep_link().on_open_url(move |event| {
                if let Some(target) = first_target(&event.urls()) {
                    focus_and_navigate(&handle, &target);
                }
            });

            Ok(())
        })
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}

#[cfg(test)]
mod tests {
    use super::plane_uri_to_http;

    #[test]
    fn maps_simple_path() {
        assert_eq!(
            plane_uri_to_http("plane://pb/browse/PB-110").as_deref(),
            Some("http://localhost:1800/pb/browse/PB-110")
        );
    }

    #[test]
    fn maps_scheme_without_slashes() {
        assert_eq!(
            plane_uri_to_http("plane:pb/browse/PB-110").as_deref(),
            Some("http://localhost:1800/pb/browse/PB-110")
        );
    }

    #[test]
    fn strips_localhost_host_with_port() {
        assert_eq!(
            plane_uri_to_http("plane://localhost:1800/pb/browse/PB-110").as_deref(),
            Some("http://localhost:1800/pb/browse/PB-110")
        );
    }

    #[test]
    fn strips_plane_localhost_host() {
        assert_eq!(
            plane_uri_to_http("plane://plane.localhost:1800/pb/browse/PB-110").as_deref(),
            Some("http://localhost:1800/pb/browse/PB-110")
        );
    }

    #[test]
    fn trims_whitespace() {
        assert_eq!(
            plane_uri_to_http("  plane://pb/browse/PB-110\n").as_deref(),
            Some("http://localhost:1800/pb/browse/PB-110")
        );
    }

    #[test]
    fn rejects_non_plane_scheme() {
        assert_eq!(plane_uri_to_http("http://localhost:1800/pb"), None);
    }

    #[test]
    fn rejects_empty_path() {
        assert_eq!(plane_uri_to_http("plane://"), None);
        assert_eq!(plane_uri_to_http("plane:///"), None);
    }

    #[test]
    fn bare_host_only_is_none() {
        assert_eq!(plane_uri_to_http("plane://localhost:1800"), None);
        assert_eq!(plane_uri_to_http("plane://plane.localhost:1800"), None);
    }
}
