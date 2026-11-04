#![cfg_attr(all(windows, not(debug_assertions)), windows_subsystem = "windows")]

mod bridge;
mod host;
mod model;
mod storage;
mod updates;

use host::HostService;
use std::{path::PathBuf, process::Command, sync::OnceLock, time::Duration};
use storage::Storage;
use tauri::{
    menu::{Menu, MenuItem},
    tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent},
    AppHandle, Manager, WindowEvent,
};
use tauri_plugin_autostart::ManagerExt as AutoStartManagerExt;
use tauri_plugin_positioner::{Position, WindowExt};
use tracing_appender::{
    non_blocking::WorkerGuard,
    rolling::{RollingFileAppender, Rotation},
};
use updates::UpdateService;

static LOG_DIRECTORY: OnceLock<PathBuf> = OnceLock::new();

fn preferred_log_directory() -> PathBuf {
    let base = std::env::var_os("LOCALAPPDATA")
        .or_else(|| std::env::var_os("APPDATA"))
        .map(PathBuf::from)
        .unwrap_or_else(std::env::temp_dir);
    base.join("io.github.leobrqz").join("WindFull").join("logs")
}

fn log_directory() -> PathBuf {
    LOG_DIRECTORY
        .get()
        .cloned()
        .unwrap_or_else(preferred_log_directory)
}

fn initialize_logging() -> Option<WorkerGuard> {
    let candidates = [
        preferred_log_directory(),
        std::env::temp_dir().join("WindFull").join("logs"),
    ];

    for directory in candidates {
        if std::fs::create_dir_all(&directory).is_err() {
            continue;
        }
        let appender = RollingFileAppender::builder()
            .rotation(Rotation::DAILY)
            .filename_prefix("windfull")
            .filename_suffix("log")
            .max_log_files(14)
            .build(&directory);
        let Ok(appender) = appender else {
            continue;
        };
        let (writer, guard) = tracing_appender::non_blocking(appender);
        if tracing_subscriber::fmt()
            .with_env_filter("info")
            .with_ansi(false)
            .with_writer(writer)
            .try_init()
            .is_ok()
        {
            let _ = LOG_DIRECTORY.set(directory.clone());
            tracing::info!(log_directory = %directory.display(), "Persistent diagnostics logging started");
            return Some(guard);
        }
    }

    None
}

fn install_panic_logging() {
    let previous_hook = std::panic::take_hook();
    std::panic::set_hook(Box::new(move |panic| {
        tracing::error!(target: "panic", details = %panic, "WindFull host panic");
        previous_hook(panic);
    }));
}

fn clean_log_field(value: &str, max_chars: usize) -> String {
    value
        .chars()
        .take(max_chars)
        .map(|character| {
            if character.is_control() {
                ' '
            } else {
                character
            }
        })
        .collect()
}

#[tauri::command]
fn report_frontend_error(
    kind: String,
    message: String,
    source: Option<String>,
    line: Option<u32>,
    column: Option<u32>,
    stack: Option<String>,
) {
    let kind = clean_log_field(&kind, 80);
    let message = clean_log_field(&message, 1200);
    let source = source.map(|value| clean_log_field(&value, 500));
    let stack = stack.map(|value| clean_log_field(&value, 6000));
    tracing::error!(
        target: "frontend",
        kind = %kind,
        message = %message,
        source = ?source,
        line = ?line,
        column = ?column,
        stack = ?stack,
        "WebView front-end error"
    );
}

#[tauri::command]
fn log_ui_event(event: String) {
    let allowed = [
        "settings.tab.appliance",
        "settings.tab.phones",
        "settings.tab.network",
        "settings.tab.energy",
        "settings.tab.automation",
        "settings.tab.updates",
    ];
    if allowed.contains(&event.as_str()) {
        tracing::info!(target: "ui", event = %event, "Settings section selected");
    }
}

#[tauri::command]
fn open_log_folder() -> Result<(), String> {
    let directory = log_directory();
    std::fs::create_dir_all(&directory)
        .map_err(|error| format!("Could not create the WindFull log folder: {error}"))?;

    #[cfg(windows)]
    {
        Command::new("explorer.exe")
            .arg(&directory)
            .spawn()
            .map(|_| ())
            .map_err(|error| format!("Could not open the WindFull log folder: {error}"))
    }
    #[cfg(not(windows))]
    {
        let _ = Command::new("xdg-open").arg(&directory).spawn();
        Err("Opening the log folder is supported on Windows builds.".into())
    }
}

#[tauri::command]
async fn get_host_state(
    host: tauri::State<'_, HostService>,
) -> Result<model::HostViewState, String> {
    Ok(host.view().await)
}
#[tauri::command]
async fn retry_server(host: tauri::State<'_, HostService>) -> Result<(), String> {
    host.retry().await
}
#[tauri::command]
async fn discover_appliances(host: tauri::State<'_, HostService>) -> Result<(), String> {
    host.discover().await
}
#[tauri::command]
async fn select_appliance(
    host: tauri::State<'_, HostService>,
    appliance_id: String,
) -> Result<(), String> {
    host.select_appliance(appliance_id).await
}
#[tauri::command]
async fn configure_appliance_manually(
    service: tauri::State<'_, HostService>,
    host: String,
    name: Option<String>,
) -> Result<(), String> {
    service.configure_appliance(host, name).await
}
#[tauri::command]
async fn set_power(host: tauri::State<'_, HostService>, enabled: bool) -> Result<(), String> {
    host.control("power", serde_json::json!(enabled)).await
}
#[tauri::command]
async fn set_target_temperature(
    host: tauri::State<'_, HostService>,
    temperature: f64,
) -> Result<(), String> {
    host.control("temperature", serde_json::json!(temperature))
        .await
}
#[tauri::command]
async fn set_operating_mode(
    host: tauri::State<'_, HostService>,
    mode: String,
) -> Result<(), String> {
    host.control("mode", serde_json::json!(mode)).await
}
#[tauri::command]
async fn set_fan_speed(host: tauri::State<'_, HostService>, speed: String) -> Result<(), String> {
    host.control("fanSpeed", serde_json::json!(speed)).await
}
#[tauri::command]
async fn set_feature(
    host: tauri::State<'_, HostService>,
    feature_id: String,
    enabled: bool,
) -> Result<(), String> {
    if feature_id.to_ascii_lowercase() != "windfree" {
        return Err("Recurso não reconhecido.".into());
    }
    host.control("windFree", serde_json::json!(enabled)).await
}
#[tauri::command]
async fn set_energy_price_per_kwh(
    host: tauri::State<'_, HostService>,
    price: f64,
) -> Result<(), String> {
    host.set_price(price).await
}
#[tauri::command]
async fn approve_pairing_request(
    host: tauri::State<'_, HostService>,
    request_id: String,
) -> Result<(), String> {
    host.approve(request_id).await
}
#[tauri::command]
async fn reject_pairing_request(
    host: tauri::State<'_, HostService>,
    request_id: String,
) -> Result<(), String> {
    host.reject(request_id).await
}
#[tauri::command]
async fn revoke_paired_device(
    host: tauri::State<'_, HostService>,
    device_id: String,
) -> Result<(), String> {
    host.revoke(device_id).await
}
#[tauri::command]
async fn set_start_with_windows(
    app: AppHandle,
    host: tauri::State<'_, HostService>,
    enabled: bool,
) -> Result<(), String> {
    if enabled {
        app.autolaunch().enable().map_err(|e| e.to_string())?;
    } else {
        app.autolaunch().disable().map_err(|e| e.to_string())?;
    }
    host.set_startup(enabled).await
}
#[tauri::command]
async fn set_off_timer(host: tauri::State<'_, HostService>, hours: u8) -> Result<(), String> {
    host.set_off_timer(hours).await
}
#[tauri::command]
async fn reset_filter_reminder(host: tauri::State<'_, HostService>) -> Result<(), String> {
    host.reset_filter_reminder().await
}
#[tauri::command]
async fn set_alerts_enabled(
    host: tauri::State<'_, HostService>,
    enabled: bool,
) -> Result<(), String> {
    host.set_alerts_enabled(enabled).await
}

fn toggle_window(app: &AppHandle) {
    if let Some(window) = app.get_webview_window("main") {
        let visible = window.is_visible().unwrap_or(false);
        let focused = window.is_focused().unwrap_or(false);
        tracing::info!(visible, focused, "Tray icon activated");
        if visible && focused {
            match window.hide() {
                Ok(()) => tracing::info!("Panel hidden from tray icon"),
                Err(error) => tracing::error!(%error, "Could not hide panel from tray icon"),
            }
        } else {
            show_window(app);
        }
    }
}

fn show_window(app: &AppHandle) {
    if let Some(window) = app.get_webview_window("main") {
        if let Err(error) = window.move_window(Position::TrayCenter) {
            tracing::warn!(%error, "Could not position panel beside tray icon");
        }
        if let Err(error) = window.show() {
            tracing::error!(%error, "Could not show panel");
            return;
        }
        if let Err(error) = window.set_focus() {
            tracing::warn!(%error, "Could not focus panel");
        }
    }
}

fn main() {
    let _log_guard = initialize_logging();
    install_panic_logging();
    tracing::info!(
        version = env!("CARGO_PKG_VERSION"),
        "WindFull host starting"
    );
    if rustls::crypto::CryptoProvider::get_default().is_none() {
        rustls::crypto::ring::default_provider()
            .install_default()
            .expect("Could not install the Rustls ring crypto provider");
        tracing::info!("Installed Rustls ring crypto provider");
    }
    let mut velopack = velopack::VelopackApp::build().set_auto_apply_on_startup(false);
    velopack.run();
    tauri::Builder::default()
        .plugin(tauri_plugin_positioner::init())
        .plugin(
            tauri_plugin_autostart::Builder::new()
                .args(["--hidden"])
                .build(),
        )
        .plugin(tauri_plugin_notification::init())
        .setup(|app| {
            tracing::info!("Tauri application setup started");
            let storage = Storage::open().map_err(std::io::Error::other)?;
            let identity = storage.load_identity().map_err(std::io::Error::other)?;
            let current_dir = std::env::current_exe()
                .ok()
                .and_then(|p| p.parent().map(|p| p.to_path_buf()))
                .unwrap_or_default();
            let resource = app
                .path()
                .resource_dir()
                .map_err(std::io::Error::other)?
                .join("windfull-samsung-ocf.exe");
            let local = current_dir.join("windfull-samsung-ocf.exe");
            let bridge = if resource.exists() {
                resource
            } else if local.exists() {
                local
            } else {
                std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"))
                    .join("../native/samsung/target/release/windfull-samsung-ocf.exe")
            };
            let service = tauri::async_runtime::block_on(HostService::new(
                app.handle().clone(),
                storage,
                identity,
                bridge,
            ))
            .map_err(std::io::Error::other)?;
            let startup =
                tauri::async_runtime::block_on(async { service.view().await.start_with_windows });
            app.manage(service.clone());
            app.manage(UpdateService::new());
            if startup {
                let _ = app.autolaunch().enable();
            }
            let show = MenuItem::with_id(app, "show", "Abrir", true, None::<&str>)?;
            let quit = MenuItem::with_id(app, "quit", "Fechar", true, None::<&str>)?;
            let menu = Menu::with_items(app, &[&show, &quit])?;
            let builder = TrayIconBuilder::new()
                .menu(&menu)
                .show_menu_on_left_click(false)
                .on_tray_icon_event(|tray, event| {
                    let app = tray.app_handle();
                    tauri_plugin_positioner::on_tray_event(&app, &event);
                    if let TrayIconEvent::Click {
                        button: MouseButton::Left,
                        button_state: MouseButtonState::Up,
                        ..
                    } = event
                    {
                        toggle_window(&app);
                    }
                })
                .on_menu_event(|app, event| match event.id().as_ref() {
                    "show" => show_window(app),
                    "quit" => app.exit(0),
                    _ => {}
                });
            if let Some(icon) = app.default_window_icon() {
                builder.icon(icon.clone()).build(app)?;
            } else {
                builder.build(app)?;
            }
            let service = service.clone();
            tauri::async_runtime::spawn(async move {
                if let Err(error) = service.start().await {
                    tracing::error!(%error,"Host HTTPS startup failed");
                }
            });
            Ok(())
        })
        .on_window_event(|window, event| match event {
            WindowEvent::CloseRequested { api, .. } => {
                tracing::info!("Panel close requested; hiding to tray");
                api.prevent_close();
                let _ = window.hide();
            }
            WindowEvent::Focused(true) => {
                tracing::info!("Panel gained focus");
            }
            WindowEvent::Focused(false) => {
                tracing::info!("Panel lost focus; waiting before auto-hide");
                // A tray panel can briefly lose focus while WebView2 changes
                // focused controls or Windows displays a native control. Wait
                // for that transition to settle before treating it as an
                // outside click.
                let window = window.clone();
                tauri::async_runtime::spawn(async move {
                    tokio::time::sleep(Duration::from_millis(250)).await;
                    if window.is_visible().unwrap_or(false) && !window.is_focused().unwrap_or(true)
                    {
                        match window.hide() {
                            Ok(()) => tracing::info!("Panel auto-hidden after focus loss"),
                            Err(error) => tracing::error!(%error, "Could not auto-hide panel"),
                        }
                    } else {
                        tracing::info!("Panel remained open after focus check");
                    }
                });
            }
            _ => {}
        })
        .invoke_handler(tauri::generate_handler![
            get_host_state,
            retry_server,
            discover_appliances,
            select_appliance,
            configure_appliance_manually,
            set_power,
            set_target_temperature,
            set_operating_mode,
            set_fan_speed,
            set_feature,
            set_energy_price_per_kwh,
            approve_pairing_request,
            reject_pairing_request,
            revoke_paired_device,
            set_start_with_windows,
            set_off_timer,
            reset_filter_reminder,
            set_alerts_enabled,
            report_frontend_error,
            log_ui_event,
            open_log_folder,
            updates::get_update_context,
            updates::check_for_updates,
            updates::download_update,
            updates::apply_update,
            updates::open_release_page
        ])
        .run(tauri::generate_context!())
        .expect("WindFull Tauri host failed to start");
}
