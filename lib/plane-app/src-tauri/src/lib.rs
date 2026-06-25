use tauri::Manager;
use tauri_plugin_deep_link::DeepLinkExt;

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

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_deep_link::init())
        .setup(|app| {
            let handle = app.handle().clone();

            // Cold launch: if the app was started by a plane:// link, the main
            // window (configured in tauri.conf.json to load the Plane home) is
            // navigated to the deep-linked page before the user sees it.
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
