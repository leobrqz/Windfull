mod bridge;
mod host;
mod model;
mod storage;
mod updates;

use host::HostService;
use std::time::Duration;
use storage::Storage;
use tauri::{
    menu::{Menu, MenuItem},
    tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent},
    AppHandle, Manager, WindowEvent,
};
use tauri_plugin_autostart::ManagerExt as AutoStartManagerExt;
use tauri_plugin_positioner::{Position, WindowExt};
use updates::UpdateService;

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
        if visible && focused {
            let _ = window.hide();
        } else {
            show_window(app);
        }
    }
}

fn show_window(app: &AppHandle) {
    if let Some(window) = app.get_webview_window("main") {
        let _ = window.move_window(Position::TrayCenter);
        let _ = window.show();
        let _ = window.set_focus();
    }
}

fn main() {
    if rustls::crypto::CryptoProvider::get_default().is_none() {
        rustls::crypto::ring::default_provider()
            .install_default()
            .expect("Could not install the Rustls ring crypto provider");
    }
    let mut velopack = velopack::VelopackApp::build().set_auto_apply_on_startup(false);
    velopack.run();
    tracing_subscriber::fmt().with_env_filter("info").init();
    tauri::Builder::default()
        .plugin(tauri_plugin_positioner::init())
        .plugin(
            tauri_plugin_autostart::Builder::new()
                .args(["--hidden"])
                .build(),
        )
        .plugin(tauri_plugin_notification::init())
        .setup(|app| {
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
                api.prevent_close();
                let _ = window.hide();
            }
            WindowEvent::Focused(false) => {
                // A tray panel can briefly lose focus while WebView2 changes
                // focused controls or Windows displays a native control. Wait
                // for that transition to settle before treating it as an
                // outside click.
                let window = window.clone();
                tauri::async_runtime::spawn(async move {
                    tokio::time::sleep(Duration::from_millis(250)).await;
                    if window.is_visible().unwrap_or(false) && !window.is_focused().unwrap_or(true)
                    {
                        let _ = window.hide();
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
            updates::get_update_context,
            updates::check_for_updates,
            updates::download_update,
            updates::apply_update,
            updates::open_release_page
        ])
        .run(tauri::generate_context!())
        .expect("WindFull Tauri host failed to start");
}
