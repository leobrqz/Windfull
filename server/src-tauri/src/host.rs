use crate::{
    bridge::{SamsungBridge, SharedBridge},
    model::*,
    storage::{ServerIdentity, Storage},
};
use axum::{
    body::Bytes,
    extract::{Path, State},
    http::{HeaderMap, Request, StatusCode},
    middleware::{self, Next},
    response::{IntoResponse, Response},
    routing::{get, post},
    Json, Router,
};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::{
    collections::BTreeMap,
    net::{IpAddr, Ipv4Addr, SocketAddr},
    sync::Arc,
    time::{Duration, SystemTime},
};
use tauri::{AppHandle, Emitter};
use tauri_plugin_notification::NotificationExt;
use tokio::{
    net::{TcpListener, UdpSocket},
    sync::Mutex,
    task::JoinHandle,
    time,
};

const API_PORT: u16 = 47657;
const DISCOVERY_PORT: u16 = 47656;
const MAX_BODY: usize = 8192;
const PAIR_LIFETIME: Duration = Duration::from_secs(180);

#[derive(Clone)]
pub struct HostService(Arc<HostInner>);

struct HostInner {
    app: AppHandle,
    storage: Storage,
    identity: ServerIdentity,
    state: Mutex<HostViewState>,
    bridge: SharedBridge,
    paired: Mutex<BTreeMap<String, PairedDevice>>,
    pending: Mutex<BTreeMap<String, PendingInternal>>,
    energy: Mutex<EnergyTracker>,
    network: Mutex<Vec<JoinHandle<()>>>,
    start_with_windows: Mutex<bool>,
    settings: Mutex<Value>,
    off_timer_ends_at: Mutex<Option<chrono::DateTime<chrono::Utc>>>,
    filter_runtime_seconds: Mutex<f64>,
    filter_reminder_notified: Mutex<bool>,
    filter_reminder_interval_hours: Mutex<u64>,
    alerts_enabled: Mutex<bool>,
    offline_alert_sent: Mutex<bool>,
    reconnect_attempt: Mutex<u32>,
    next_reconnect_at: Mutex<Option<time::Instant>>,
}

#[derive(Clone)]
struct PendingInternal {
    view: PendingPairing,
    client_id: String,
    secret_hash: String,
    expires: SystemTime,
    status: String,
}
#[derive(serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
struct StoredPairing {
    id: String,
    name: String,
    description: Option<String>,
    paired_at: String,
    last_seen_at: Option<String>,
    secret_hash: String,
}

impl HostService {
    pub async fn new(
        app: AppHandle,
        storage: Storage,
        identity: ServerIdentity,
        bridge_path: std::path::PathBuf,
    ) -> Result<Self, String> {
        let bridge = Arc::new(Mutex::new(SamsungBridge::new(
            bridge_path,
            storage.data_dir.clone(),
        )));
        let settings = storage
            .read_json("host_settings.json")?
            .unwrap_or(Value::Null);
        let mut energy = EnergyTracker::default();
        if let Some(saved) = settings.get("energyTracker") {
            energy = serde_json::from_value(saved.clone()).unwrap_or(energy);
        }
        let start_with_windows = settings
            .get("startWithWindows")
            .and_then(Value::as_bool)
            .unwrap_or(false);
        let alerts_enabled = settings
            .get("alertsEnabled")
            .and_then(Value::as_bool)
            .unwrap_or(true);
        let off_timer_ends_at = settings
            .get("offTimerEndsAt")
            .and_then(Value::as_str)
            .and_then(|v| chrono::DateTime::parse_from_rfc3339(v).ok())
            .map(|v| v.with_timezone(&chrono::Utc));
        let filter_runtime_seconds = settings
            .get("filterRuntimeSeconds")
            .and_then(Value::as_f64)
            .unwrap_or(0.0)
            .max(0.0);
        let filter_reminder_notified = settings
            .get("filterReminderNotified")
            .and_then(Value::as_bool)
            .unwrap_or(false);
        let filter_reminder_interval_hours = settings
            .get("filterReminderIntervalHours")
            .and_then(Value::as_u64)
            .filter(|h| *h > 0)
            .unwrap_or(500);
        let paired = if let Some(old) = storage.read_legacy_secret("windfull.paired_devices.v1")? {
            let values: Vec<StoredPairing> = serde_json::from_str(&old).map_err(|_| {
                "Os dispositivos pareados antigos estão inválidos; eles não serão sobrescritos."
                    .to_string()
            })?;
            let records: BTreeMap<_, _> = values
                .into_iter()
                .map(|d| {
                    let p = PairedDevice {
                        id: d.id.clone(),
                        name: d.name,
                        description: d.description,
                        paired_at: d.paired_at,
                        last_seen_at: d.last_seen_at,
                        secret_hash: d.secret_hash,
                    };
                    (d.id, p)
                })
                .collect();
            save_paired(&storage, &records)?;
            records
        } else {
            BTreeMap::new()
        };
        let result = Self(Arc::new(HostInner {
            app,
            storage,
            identity,
            state: Mutex::new(HostViewState::default()),
            bridge,
            paired: Mutex::new(paired),
            pending: Mutex::new(BTreeMap::new()),
            energy: Mutex::new(energy),
            network: Mutex::new(Vec::new()),
            start_with_windows: Mutex::new(start_with_windows),
            settings: Mutex::new(settings),
            off_timer_ends_at: Mutex::new(off_timer_ends_at),
            filter_runtime_seconds: Mutex::new(filter_runtime_seconds),
            filter_reminder_notified: Mutex::new(filter_reminder_notified),
            filter_reminder_interval_hours: Mutex::new(filter_reminder_interval_hours),
            alerts_enabled: Mutex::new(alerts_enabled),
            offline_alert_sent: Mutex::new(false),
            reconnect_attempt: Mutex::new(0),
            next_reconnect_at: Mutex::new(None),
        }));
        {
            let mut state = result.0.state.lock().await;
            state.energy_usage = result.0.energy.lock().await.view();
            state.paired_devices = result.0.paired.lock().await.values().cloned().collect();
            state.start_with_windows = start_with_windows;
            state.off_timer_ends_at = result
                .0
                .off_timer_ends_at
                .lock()
                .await
                .map(|v| v.to_rfc3339());
            state.filter_runtime_hours = *result.0.filter_runtime_seconds.lock().await / 3600.0;
            state.filter_reminder_interval_hours = filter_reminder_interval_hours;
            state.filter_reminder_due =
                state.filter_runtime_hours >= filter_reminder_interval_hours as f64;
            state.alerts_enabled = alerts_enabled;
        }
        Ok(result)
    }

    pub async fn start(&self) -> Result<(), String> {
        let result = self.start_inner().await;
        if let Err(error) = &result {
            let mut state = self.0.state.lock().await;
            state.status = "error".into();
            state.server_error = Some(error.clone());
            drop(state);
            self.emit().await;
        }
        result
    }

    async fn start_inner(&self) -> Result<(), String> {
        {
            let mut s = self.0.state.lock().await;
            s.status = "starting".into();
            s.server_error = None;
        }
        self.emit().await;
        let identity = self.0.identity.clone();
        let host = self.clone();
        let app = self.0.app.clone();
        let tcp = TcpListener::bind(SocketAddr::new(IpAddr::V4(Ipv4Addr::UNSPECIFIED), API_PORT))
            .await
            .map_err(|e| format!("Não foi possível iniciar HTTPS na porta {API_PORT}: {e}"))?;
        let listener = axum_server::from_tcp_rustls(
            tcp.into_std().map_err(|e| e.to_string())?,
            axum_server::tls_rustls::RustlsConfig::from_pem(
                identity.certificate_pem.as_bytes().to_vec(),
                identity.private_key_pem.as_bytes().to_vec(),
            )
            .await
            .map_err(|e| format!("Certificado TLS persistido inválido: {e}"))?,
        );
        let router = Router::new()
            .route("/v1/pairings", post(pair_create))
            .route("/v1/pairings/:request_id", get(pair_status))
            .route("/v1/state", get(api_state))
            .route("/v1/commands", post(api_command))
            .fallback(not_found)
            .method_not_allowed_fallback(method_not_allowed)
            .layer(middleware::from_fn(security_headers))
            .with_state(host.clone());
        let server_task = tokio::spawn(async move {
            let _ = listener.serve(router.into_make_service()).await;
        });
        self.0.network.lock().await.push(server_task);
        let mut state = self.0.state.lock().await;
        state.status = "ready".into();
        state.server_port = Some(API_PORT);
        state.certificate_fingerprint = Some(identity.fingerprint.clone());
        state.local_addresses = local_ip_address::list_afinet_netifas()
            .unwrap_or_default()
            .into_iter()
            .filter_map(|(_, ip)| {
                if ip.is_ipv4() && !ip.is_loopback() {
                    Some(ip.to_string())
                } else {
                    None
                }
            })
            .collect();
        drop(state);
        let host = self.clone();
        let udp = tokio::spawn(async move {
            udp_discovery(app, host, identity).await;
        });
        self.0.network.lock().await.push(udp);
        self.emit().await;
        let monitor = self.clone();
        let task = tokio::spawn(async move {
            let saved = monitor
                .0
                .storage
                .read_json("host_settings.json")
                .ok()
                .flatten()
                .unwrap_or(Value::Null);
            if let Some(address) = saved.get("applianceHost").and_then(Value::as_str) {
                let name = saved
                    .get("applianceName")
                    .and_then(Value::as_str)
                    .map(str::to_string);
                let id = saved
                    .get("applianceId")
                    .and_then(Value::as_str)
                    .map(str::to_string);
                let port = saved
                    .get("appliancePort")
                    .and_then(Value::as_u64)
                    .map(|v| v as u16);
                let connected = monitor
                    .0
                    .bridge
                    .lock()
                    .await
                    .call("connect", json!({"host":address,"port":port}))
                    .await;
                match connected {
                    Ok(mut device) => {
                        if let Some(id) = id {
                            device["id"] = json!(id);
                        }
                        if let Err(error) = monitor.refresh_appliance(device, name).await {
                            let mut s = monitor.0.state.lock().await;
                            s.appliance_connection = "error".into();
                            s.appliance_error = Some(error);
                        }
                    }
                    Err(error) => {
                        let mut s = monitor.0.state.lock().await;
                        s.appliance_connection = "disconnected".into();
                        s.appliance_error = Some(error);
                    }
                }
                monitor.emit().await;
            } else {
                let _ = monitor.discover().await;
            }
            let mut interval = time::interval(Duration::from_secs(20));
            interval.tick().await;
            let mut last_tick = time::Instant::now();
            loop {
                interval.tick().await;
                let now = time::Instant::now();
                let elapsed = now.duration_since(last_tick).as_secs_f64().min(60.0);
                last_tick = now;
                let (current, is_connected) = {
                    let s = monitor.0.state.lock().await;
                    (s.appliance.clone(), s.appliance_connection == "connected")
                };
                if is_connected && current.as_ref().and_then(|a| a.is_powered_on) == Some(true) {
                    let runtime = {
                        let mut seconds = monitor.0.filter_runtime_seconds.lock().await;
                        *seconds += elapsed;
                        *seconds
                    };
                    let _ = monitor
                        .set_values(&[("filterRuntimeSeconds", json!(runtime))])
                        .await;
                }
                let threshold = *monitor.0.filter_reminder_interval_hours.lock().await;
                let runtime = *monitor.0.filter_runtime_seconds.lock().await;
                if runtime >= threshold as f64 * 3600.0
                    && !*monitor.0.filter_reminder_notified.lock().await
                {
                    *monitor.0.filter_reminder_notified.lock().await = true;
                    let _ = monitor
                        .set_values(&[("filterReminderNotified", json!(true))])
                        .await;
                    monitor.alert("filterReminder","Lembrete de filtro","O tempo de uso acompanhado atingiu o intervalo do lembrete. Verifique e limpe o filtro do ar-condicionado.").await;
                }
                let mut refreshed = false;
                if is_connected {
                    if let Some(appliance) = current.clone() {
                        let timer_due = monitor
                            .0
                            .off_timer_ends_at
                            .lock()
                            .await
                            .is_some_and(|end| end <= chrono::Utc::now());
                        if timer_due {
                            *monitor.0.off_timer_ends_at.lock().await = None;
                            let _ = monitor.set_values(&[("offTimerEndsAt", Value::Null)]).await;
                            if let Err(error) = monitor.control("power", json!(false)).await {
                                monitor
                                    .alert(
                                        "offTimerFailed",
                                        "Temporizador não concluído",
                                        &format!(
                                            "Não foi possível desligar o ar-condicionado: {error}"
                                        ),
                                    )
                                    .await;
                            }
                        }
                        let device =
                            json!({"id":appliance.id,"host":appliance.host,"name":appliance.name});
                        if let Err(error) = monitor
                            .refresh_appliance(device, Some(appliance.name))
                            .await
                        {
                            let mut s = monitor.0.state.lock().await;
                            s.appliance_connection = "error".into();
                            s.appliance_error = Some(error);
                            drop(s);
                        } else {
                            refreshed = true;
                        }
                    }
                }
                let configured = monitor
                    .0
                    .settings
                    .lock()
                    .await
                    .get("applianceHost")
                    .and_then(Value::as_str)
                    .is_some();
                if !refreshed && configured {
                    let due = monitor
                        .0
                        .next_reconnect_at
                        .lock()
                        .await
                        .map_or(true, |at| at <= time::Instant::now());
                    if due {
                        match monitor.reconnect_saved().await {
                            Ok(()) => {
                                refreshed = true;
                                *monitor.0.reconnect_attempt.lock().await = 0;
                                *monitor.0.next_reconnect_at.lock().await = None;
                            }
                            Err(error) => {
                                let attempt = {
                                    let mut a = monitor.0.reconnect_attempt.lock().await;
                                    let current = *a;
                                    *a = (*a + 1).min(6);
                                    current
                                };
                                let delay = (2u64.saturating_mul(1u64 << attempt.min(5))).min(60);
                                *monitor.0.next_reconnect_at.lock().await =
                                    Some(time::Instant::now() + Duration::from_secs(delay));
                                let mut s = monitor.0.state.lock().await;
                                s.appliance_connection = if is_connected {
                                    "error"
                                } else {
                                    "disconnected"
                                }
                                .into();
                                s.appliance_error = Some(error);
                                drop(s);
                            }
                        }
                    }
                }
                if refreshed {
                    *monitor.0.offline_alert_sent.lock().await = false;
                } else if configured {
                    let should_alert = {
                        let mut sent = monitor.0.offline_alert_sent.lock().await;
                        if !*sent {
                            *sent = true;
                            true
                        } else {
                            false
                        }
                    };
                    if should_alert {
                        monitor
                            .alert(
                                "applianceOffline",
                                "Ar-condicionado offline",
                                "O WindFull perdeu a conexão local com o ar-condicionado.",
                            )
                            .await;
                    }
                }
                let mut expired = false;
                {
                    let mut pending = monitor.0.pending.lock().await;
                    for request in pending.values_mut() {
                        if request.status == "pending" && request.expires <= SystemTime::now() {
                            request.status = "expired".into();
                            expired = true;
                        }
                    }
                    pending.retain(|_, p| p.expires + Duration::from_secs(60) > SystemTime::now());
                }
                if expired {
                    monitor.emit().await;
                }
                monitor.emit().await;
            }
        });
        self.0.network.lock().await.push(task);
        Ok(())
    }

    pub async fn shutdown(&self) {
        for task in self.0.network.lock().await.drain(..) {
            task.abort();
        }
        self.0.bridge.lock().await.shutdown().await;
        {
            let mut s = self.0.state.lock().await;
            s.status = "stopped".into();
            s.server_port = None;
            s.appliance_connection = "unknown".into();
        }
        self.emit().await;
    }

    pub async fn view(&self) -> HostViewState {
        let mut s = self.0.state.lock().await.clone();
        s.energy_usage = self.0.energy.lock().await.view();
        s.paired_devices = self.0.paired.lock().await.values().cloned().collect();
        s.start_with_windows = *self.0.start_with_windows.lock().await;
        s.pending_pairings = self.visible_pending().await;
        s.off_timer_ends_at = self
            .0
            .off_timer_ends_at
            .lock()
            .await
            .map(|v| v.to_rfc3339());
        s.filter_runtime_hours = *self.0.filter_runtime_seconds.lock().await / 3600.0;
        s.filter_reminder_interval_hours = *self.0.filter_reminder_interval_hours.lock().await;
        s.filter_reminder_due = s.filter_runtime_hours >= s.filter_reminder_interval_hours as f64;
        s.alerts_enabled = *self.0.alerts_enabled.lock().await;
        s
    }
    async fn emit(&self) {
        let _ = self.0.app.emit("host-state-changed", self.view().await);
    }
    async fn alert(&self, kind: &str, title: &str, message: &str) {
        if !*self.0.alerts_enabled.lock().await {
            return;
        }
        let created_at = chrono::Utc::now().to_rfc3339();
        let _ = self.0.app.emit(
            "host-alert",
            json!({"type":kind,"title":title,"message":message,"createdAt":created_at}),
        );
        let _ = self
            .0
            .app
            .notification()
            .builder()
            .title(title)
            .body(message)
            .show();
    }
    async fn set_values(&self, edits: &[(&str, Value)]) -> Result<(), String> {
        let mut settings = self.0.settings.lock().await;
        for (key, value) in edits {
            settings[*key] = value.clone()
        }
        self.0.storage.write_json("host_settings.json", &*settings)
    }
    async fn reconnect_saved(&self) -> Result<(), String> {
        let settings = self.0.settings.lock().await.clone();
        let address = settings
            .get("applianceHost")
            .and_then(Value::as_str)
            .ok_or("Nenhum endereço de aparelho está configurado.")?
            .to_string();
        let name = settings
            .get("applianceName")
            .and_then(Value::as_str)
            .map(str::to_string);
        let connected=self.0.bridge.lock().await.call("connect",json!({"host":address,"port":settings.get("appliancePort").and_then(Value::as_u64)})).await?;
        self.refresh_appliance(connected, name).await
    }
    async fn visible_pending(&self) -> Vec<PendingPairing> {
        self.0
            .pending
            .lock()
            .await
            .values()
            .filter(|p| p.status == "pending" && p.expires > SystemTime::now())
            .map(|p| p.view.clone())
            .collect()
    }

    pub async fn retry(&self) -> Result<(), String> {
        self.shutdown().await;
        self.start().await
    }

    pub async fn discover(&self) -> Result<(), String> {
        {
            let mut s = self.0.state.lock().await;
            s.is_discovering = true;
            s.discovery_error = None;
            s.discovered_appliances.clear();
        }
        self.emit().await;
        let result = self
            .0
            .bridge
            .lock()
            .await
            .call("discover", json!({"timeoutMs":8000}))
            .await;
        match result {
            Ok(items) => {
                let devices: Vec<DiscoveredAppliance> = items
                    .as_array()
                    .into_iter()
                    .flatten()
                    .filter_map(|v| {
                        Some(DiscoveredAppliance {
                            id: v.get("id")?.as_str()?.to_string(),
                            host: v.get("host")?.as_str()?.to_string(),
                            name: v
                                .get("name")
                                .and_then(Value::as_str)
                                .or_else(|| v.get("model").and_then(Value::as_str))
                                .unwrap_or("Ar-condicionado")
                                .to_string(),
                            is_reachable: Some(true),
                            is_powered_on: None,
                            target_temperature: None,
                            room_temperature: None,
                            port: v.get("port").and_then(Value::as_u64).map(|p| p as u16),
                        })
                    })
                    .collect();
                let mut s = self.0.state.lock().await;
                s.discovered_appliances = devices;
                s.has_searched_for_appliances = true;
                s.is_discovering = false;
                drop(s);
                self.emit().await;
                Ok(())
            }
            Err(error) => {
                let mut s = self.0.state.lock().await;
                s.is_discovering = false;
                s.discovery_error = Some(error.clone());
                drop(s);
                self.emit().await;
                Err(error)
            }
        }
    }

    pub async fn select_appliance(&self, id: String) -> Result<(), String> {
        let candidate = self
            .0
            .state
            .lock()
            .await
            .discovered_appliances
            .iter()
            .find(|v| v.id == id)
            .cloned()
            .ok_or("O aparelho selecionado não está mais na lista de descoberta.")?;
        self.connect_appliance(
            candidate.host,
            Some(candidate.name),
            Some(id),
            candidate.port,
        )
        .await
    }
    pub async fn configure_appliance(
        &self,
        host: String,
        name: Option<String>,
    ) -> Result<(), String> {
        let ip: IpAddr = host
            .trim()
            .parse()
            .map_err(|_| "Informe um endereço IP válido do ar-condicionado.")?;
        if !ip.is_ipv4() {
            return Err("Informe um endereço IPv4 válido do ar-condicionado.".into());
        }
        self.connect_appliance(
            host.trim().to_string(),
            name.filter(|n| !n.trim().is_empty()),
            None,
            None,
        )
        .await
    }

    async fn connect_appliance(
        &self,
        host: String,
        name: Option<String>,
        id: Option<String>,
        port: Option<u16>,
    ) -> Result<(), String> {
        let connected = self
            .0
            .bridge
            .lock()
            .await
            .call("connect", json!({"host":host,"port":port}))
            .await?;
        let dev_id = id
            .or_else(|| {
                connected
                    .get("id")
                    .and_then(Value::as_str)
                    .map(str::to_string)
            })
            .unwrap_or_default();
        self.set_values(&[
            ("applianceHost", json!(host)),
            ("applianceName", json!(name)),
            ("applianceId", json!(dev_id)),
            ("appliancePort", json!(port)),
        ])
        .await?;
        self.refresh_appliance(connected, name).await?;
        self.emit().await;
        Ok(())
    }

    async fn refresh_appliance(
        &self,
        device: Value,
        configured_name: Option<String>,
    ) -> Result<(), String> {
        let mut bridge = self.0.bridge.lock().await;
        let raw_state = bridge.call("state", Value::Null).await?;
        let caps = bridge.call("capabilities", Value::Null).await?;
        drop(bridge);
        let dev_id = device
            .get("id")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_string();
        let host = device
            .get("host")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_string();
        let model = device
            .get("model")
            .and_then(Value::as_str)
            .map(str::to_string);
        let name = configured_name
            .or_else(|| {
                device
                    .get("name")
                    .and_then(Value::as_str)
                    .map(str::to_string)
            })
            .or_else(|| {
                device
                    .get("model")
                    .and_then(Value::as_str)
                    .map(str::to_string)
            })
            .unwrap_or("Ar-condicionado".into());
        let modes_raw: Vec<String> = caps
            .get("modes")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
            .filter_map(Value::as_str)
            .map(str::to_string)
            .collect();
        let fan_raw: Vec<String> = caps
            .get("fanSpeeds")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
            .filter_map(Value::as_str)
            .map(str::to_string)
            .collect();
        let modes = modes_raw.iter().filter_map(|m| canonical_mode(m)).collect();
        let fans = fan_raw.iter().filter_map(|m| canonical_fan(m)).collect();
        let temp = caps.get("temperature");
        let mut features = BTreeMap::new();
        if caps.get("windFree").and_then(Value::as_bool) == Some(true) {
            features.insert(
                "windFree".into(),
                ApplianceFeatureState {
                    label: "WindFree".into(),
                    enabled: raw_state
                        .get("windFree")
                        .and_then(Value::as_bool)
                        .unwrap_or(false),
                },
            );
        }
        let appliance = ApplianceState {
            id: dev_id.clone(),
            name,
            host,
            model,
            is_powered_on: raw_state.get("power").and_then(Value::as_bool),
            target_temperature: number(&raw_state, "temperature"),
            room_temperature: number(&raw_state, "ambientTemperature"),
            humidity: number(&raw_state, "humidity"),
            instantaneous_power_w: number(&raw_state, "instantaneousPowerW"),
            cumulative_energy_wh: number(&raw_state, "cumulativeEnergyWh"),
            minimum_temperature: number(temp.unwrap_or(&Value::Null), "minimum"),
            maximum_temperature: number(temp.unwrap_or(&Value::Null), "maximum"),
            temperature_step: number(temp.unwrap_or(&Value::Null), "step"),
            mode: raw_state
                .get("mode")
                .and_then(Value::as_str)
                .and_then(canonical_mode),
            supported_modes: modes,
            fan_speed: raw_state
                .get("fanSpeed")
                .and_then(Value::as_str)
                .and_then(canonical_fan),
            fan_speeds: fans,
            features,
            raw_capabilities: caps.clone(),
        };
        if let Some(wh) = raw_state.get("cumulativeEnergyWh").and_then(Value::as_f64) {
            self.0.energy.lock().await.record(wh);
        }
        let mut s = self.0.state.lock().await;
        s.appliance = Some(appliance);
        s.selected_appliance_id = Some(dev_id);
        s.appliance_connection = "connected".into();
        s.appliance_error = None;
        self.persist_energy().await?;
        Ok(())
    }

    pub async fn control(&self, kind: &str, value: Value) -> Result<(), String> {
        let appliance = self
            .0
            .state
            .lock()
            .await
            .appliance
            .clone()
            .ok_or("Nenhum aparelho conectado.")?;
        let (method, param) = match kind {
            "power" => {
                if appliance
                    .raw_capabilities
                    .get("power")
                    .and_then(Value::as_bool)
                    != Some(true)
                {
                    return Err("O aparelho não informou suporte ao controle de energia.".into());
                }
                ("setPower", json!({"enabled":value}))
            }
            "temperature" => {
                let v = value
                    .as_f64()
                    .filter(|v| v.is_finite())
                    .ok_or("Temperatura inválida.")?;
                let min = appliance
                    .minimum_temperature
                    .ok_or("O aparelho não anunciou limites completos de temperatura.")?;
                let max = appliance
                    .maximum_temperature
                    .ok_or("O aparelho não anunciou limites completos de temperatura.")?;
                let step = appliance
                    .temperature_step
                    .ok_or("O aparelho não anunciou o incremento de temperatura.")?;
                if v < min
                    || v > max
                    || step <= 0.0
                    || (((v - min) / step).round() - (v - min) / step).abs() > 0.000001
                {
                    return Err(
                        "Temperatura fora dos limites ou passo informado pelo aparelho.".into(),
                    );
                }
                ("setTemperature", json!({"celsius":v}))
            }
            "mode" => {
                let m = value.as_str().ok_or("Modo inválido.")?;
                if !appliance.supported_modes.iter().any(|x| x == m) {
                    return Err("Esse modo não foi informado como disponível pelo aparelho.".into());
                }
                ("setMode", json!({"value":bridge_mode(m)?}))
            }
            "fanSpeed" => {
                let m = value.as_str().ok_or("Velocidade inválida.")?;
                if !appliance.fan_speeds.iter().any(|x| x == m) {
                    return Err(
                        "Essa velocidade não foi informada como disponível pelo aparelho.".into(),
                    );
                }
                ("setFanSpeed", json!({"value":bridge_fan(m)?}))
            }
            "windFree" => {
                if !appliance.features.contains_key("windFree") {
                    return Err("WindFree não foi informado como disponível pelo aparelho.".into());
                }
                (
                    "setWindFree",
                    json!({"value":value.as_bool().ok_or("Valor inválido.")?.to_string()}),
                )
            }
            _ => return Err("Comando não reconhecido.".into()),
        };
        {
            let mut s = self.0.state.lock().await;
            s.busy_actions = vec![kind.to_string()];
        }
        let res = self.0.bridge.lock().await.call(method, param).await;
        {
            let mut s = self.0.state.lock().await;
            s.busy_actions.clear();
        }
        match res {
            Ok(_raw) => {
                let device = json!({"id":appliance.id,"host":appliance.host,"name":appliance.name,"model":appliance.model});
                self.refresh_appliance(device, Some(appliance.name)).await?;
                self.emit().await;
                Ok(())
            }
            Err(e) => {
                self.emit().await;
                Err(e)
            }
        }
    }

    pub async fn set_price(&self, price: f64) -> Result<(), String> {
        if !price.is_finite() || price <= 0.0 || price > 100.0 {
            return Err("Informe uma tarifa maior que zero e menor que R$ 100,00 por kWh.".into());
        }
        self.0.energy.lock().await.price_per_kwh = price;
        self.persist_energy().await?;
        self.emit().await;
        Ok(())
    }
    async fn persist_energy(&self) -> Result<(), String> {
        let energy =
            serde_json::to_value(&*self.0.energy.lock().await).map_err(|e| e.to_string())?;
        self.set_values(&[("energyTracker", energy)]).await
    }

    pub async fn set_startup(&self, enabled: bool) -> Result<(), String> {
        *self.0.start_with_windows.lock().await = enabled;
        self.set_values(&[("startWithWindows", json!(enabled))])
            .await?;
        self.emit().await;
        Ok(())
    }
    pub async fn set_off_timer(&self, hours: u8) -> Result<(), String> {
        if ![0, 1, 2, 4, 8].contains(&hours) {
            return Err("O temporizador aceita 1, 2, 4 ou 8 horas; zero cancela.".into());
        }
        let ends = if hours == 0 {
            None
        } else {
            Some(chrono::Utc::now() + chrono::Duration::hours(hours as i64))
        };
        *self.0.off_timer_ends_at.lock().await = ends;
        let text = ends.map(|v| v.to_rfc3339());
        self.set_values(&[("offTimerEndsAt", json!(text))]).await?;
        self.emit().await;
        Ok(())
    }
    pub async fn reset_filter_reminder(&self) -> Result<(), String> {
        *self.0.filter_runtime_seconds.lock().await = 0.0;
        *self.0.filter_reminder_notified.lock().await = false;
        self.set_values(&[
            ("filterRuntimeSeconds", json!(0)),
            ("filterReminderNotified", json!(false)),
        ])
        .await?;
        self.emit().await;
        Ok(())
    }
    pub async fn set_alerts_enabled(&self, enabled: bool) -> Result<(), String> {
        *self.0.alerts_enabled.lock().await = enabled;
        self.set_values(&[("alertsEnabled", json!(enabled))])
            .await?;
        self.emit().await;
        Ok(())
    }

    pub async fn approve(&self, id: String) -> Result<(), String> {
        let mut pending = self.0.pending.lock().await;
        let req = pending
            .get(&id)
            .cloned()
            .ok_or("Esta solicitação de pareamento não está mais pendente.")?;
        if req.status != "pending" || req.expires <= SystemTime::now() {
            return Err("O pedido de pareamento expirou ou não está pendente.".into());
        }
        let record = PairedDevice {
            id: req.client_id.clone(),
            name: req.view.device_name,
            description: req.view.device_description,
            paired_at: chrono::Utc::now().to_rfc3339(),
            last_seen_at: None,
            secret_hash: req.secret_hash,
        };
        let mut paired = self.0.paired.lock().await;
        let mut updated = paired.clone();
        updated.insert(record.id.clone(), record);
        save_paired(&self.0.storage, &updated)?;
        *paired = updated;
        if let Some(request) = pending.get_mut(&id) {
            request.status = "approved".into();
        }
        drop(paired);
        drop(pending);
        self.emit().await;
        Ok(())
    }
    pub async fn reject(&self, id: String) -> Result<(), String> {
        let mut pending = self.0.pending.lock().await;
        let p = pending
            .get_mut(&id)
            .ok_or("Esta solicitação de pareamento não está mais pendente.")?;
        if p.status != "pending" {
            return Err("Esta solicitação de pareamento não está mais pendente.".into());
        }
        p.status = "rejected".into();
        drop(pending);
        self.emit().await;
        Ok(())
    }
    pub async fn revoke(&self, id: String) -> Result<(), String> {
        let mut paired = self.0.paired.lock().await;
        if !paired.contains_key(&id) {
            return Err("O dispositivo não está pareado.".into());
        }
        let mut updated = paired.clone();
        updated.remove(&id);
        save_paired(&self.0.storage, &updated)?;
        *paired = updated;
        drop(paired);
        self.emit().await;
        Ok(())
    }
}

fn save_paired(storage: &Storage, records: &BTreeMap<String, PairedDevice>) -> Result<(), String> {
    let stored: Vec<_> = records
        .values()
        .map(|d| StoredPairing {
            id: d.id.clone(),
            name: d.name.clone(),
            description: d.description.clone(),
            paired_at: d.paired_at.clone(),
            last_seen_at: d.last_seen_at.clone(),
            secret_hash: d.secret_hash.clone(),
        })
        .collect();
    let json = serde_json::to_string(&stored).map_err(|e| e.to_string())?;
    storage.write_legacy_secret("windfull.paired_devices.v1", &json)
}
fn number(v: &Value, k: &str) -> Option<f64> {
    v.get(k).and_then(Value::as_f64)
}
fn canonical_mode(v: &str) -> Option<String> {
    match v.to_ascii_lowercase().as_str() {
        "cool" => Some("cool".into()),
        "dry" => Some("dry".into()),
        "wind" | "fan" => Some("fan".into()),
        "auto" => Some("auto".into()),
        "heat" => Some("heat".into()),
        _ => None,
    }
}
fn bridge_mode(v: &str) -> Result<&'static str, String> {
    match v {
        "cool" => Ok("cool"),
        "dry" => Ok("dry"),
        "fan" => Ok("fan"),
        "auto" => Ok("auto"),
        "heat" => Ok("heat"),
        _ => Err("Modo não suportado.".into()),
    }
}
fn canonical_fan(v: &str) -> Option<String> {
    match v.to_ascii_lowercase().as_str() {
        "0" | "auto" => Some("auto".into()),
        "1" | "low" => Some("low".into()),
        "2" | "medium" => Some("medium".into()),
        "3" | "high" => Some("high".into()),
        "4" | "turbo" => Some("turbo".into()),
        _ => None,
    }
}
fn bridge_fan(v: &str) -> Result<&'static str, String> {
    match v {
        "auto" => Ok("auto"),
        "low" => Ok("low"),
        "medium" => Ok("medium"),
        "high" => Ok("high"),
        "turbo" => Ok("turbo"),
        _ => Err("Velocidade não suportada.".into()),
    }
}

async fn udp_discovery(app: AppHandle, host: HostService, identity: ServerIdentity) {
    let socket = match UdpSocket::bind((Ipv4Addr::UNSPECIFIED, DISCOVERY_PORT)).await {
        Ok(s) => s,
        Err(e) => {
            let _ = host
                .fail_server(format!("Não foi possível iniciar descoberta UDP: {e}"))
                .await;
            return;
        }
    };
    let mut buf = [0u8; 128];
    loop {
        let (n, peer) = match socket.recv_from(&mut buf).await {
            Ok(v) => v,
            Err(_) => break,
        };
        if &buf[..n] != b"WINDFULL_DISCOVER_V1" {
            continue;
        }
        let announce = json!({"protocol":"windfull/1","id":identity.server_id,"name":"WindFull para Windows","port":API_PORT,"fingerprint":identity.fingerprint});
        if let Ok(bytes) = serde_json::to_vec(&announce) {
            let _ = socket.send_to(&bytes, peer).await;
        }
    }
    drop(app)
}

impl HostService {
    pub async fn fail_server(&self, error: String) {
        let mut s = self.0.state.lock().await;
        s.status = "error".into();
        s.server_error = Some(error);
        drop(s);
        self.emit().await;
    }
}

async fn pair_create(
    State(host): State<HostService>,
    headers: HeaderMap,
    body: Bytes,
) -> impl IntoResponse {
    let no_origin = reject_origin(&headers);
    if let Some(x) = no_origin {
        return x;
    }
    if body.len() > MAX_BODY {
        return error(
            StatusCode::PAYLOAD_TOO_LARGE,
            "body_too_large",
            "O corpo da solicitação excede o limite permitido.",
        );
    }
    if !is_json(&headers) {
        return error(
            StatusCode::UNSUPPORTED_MEDIA_TYPE,
            "content_type_required",
            "Envie o corpo como application/json.",
        );
    }
    let body: Value = match serde_json::from_slice(&body) {
        Ok(v) => v,
        Err(_) => {
            return error(
                StatusCode::BAD_REQUEST,
                "invalid_json",
                "O corpo JSON está malformado.",
            )
        }
    };
    let id = body.get("requestId").and_then(Value::as_str).unwrap_or("");
    let client = body.get("clientId").and_then(Value::as_str).unwrap_or("");
    let secret = body.get("secret").and_then(Value::as_str).unwrap_or("");
    let raw_name = body
        .get("clientName")
        .and_then(Value::as_str)
        .unwrap_or("")
        .trim();
    if !hex32(id)
        || !hex32(client)
        || secret.len() != 64
        || !secret
            .bytes()
            .all(|b| b.is_ascii_hexdigit() && !b.is_ascii_uppercase())
        || raw_name.is_empty()
        || raw_name.encode_utf16().count() > 120
    {
        return error(
            StatusCode::BAD_REQUEST,
            "invalid_pairing_request",
            "Dados de pareamento inválidos.",
        );
    }
    let name = sanitize_client_name(raw_name);
    let secret_hash = hex::encode(Sha256::digest(secret.as_bytes()));
    let mut pending = host.0.pending.lock().await;
    pending.retain(|_, p| p.expires + Duration::from_secs(60) > SystemTime::now());
    if let Some(old) = pending.get(id) {
        if old.client_id != client || old.secret_hash != secret_hash {
            return error(
                StatusCode::CONFLICT,
                "request_id_conflict",
                "O identificador de solicitação já está em uso.",
            );
        }
        return (StatusCode::ACCEPTED, Json(json!({"status":old.status}))).into_response();
    }
    if pending
        .values()
        .filter(|p| p.status == "pending" && p.expires > SystemTime::now())
        .count()
        >= 10
    {
        return error(
            StatusCode::TOO_MANY_REQUESTS,
            "too_many_pairing_requests",
            "O computador já tem solicitações pendentes demais.",
        );
    }
    let code = pairing_code(id, &host.0.identity.fingerprint);
    let expiration = SystemTime::now() + PAIR_LIFETIME;
    let expires_at = chrono::Utc::now() + chrono::Duration::seconds(180);
    let view = PendingPairing {
        id: id.to_string(),
        device_name: name,
        device_description: None,
        verification_code: code,
        expires_at: expires_at.to_rfc3339(),
    };
    pending.insert(
        id.into(),
        PendingInternal {
            view,
            client_id: client.into(),
            secret_hash,
            expires: expiration,
            status: "pending".into(),
        },
    );
    drop(pending);
    host.emit().await;
    (StatusCode::ACCEPTED, Json(json!({"status":"pending"}))).into_response()
}
async fn pair_status(
    State(host): State<HostService>,
    Path(id): Path<String>,
    headers: HeaderMap,
) -> impl IntoResponse {
    if let Some(x) = reject_origin(&headers) {
        return x;
    }
    if !hex32(&id) {
        return error(
            StatusCode::NOT_FOUND,
            "pairing_not_found",
            "Solicitação de pareamento não encontrada ou expirada.",
        );
    }
    if let Err(x) = host.authorize(&headers, Some(&id)).await {
        return x;
    }
    let p = host.0.pending.lock().await.get(&id).cloned();
    match p {
        Some(mut p) => {
            if p.expires <= SystemTime::now() && p.status == "pending" {
                p.status = "expired".into();
                host.0.pending.lock().await.insert(id, p.clone());
                host.emit().await;
            }
            (StatusCode::OK, Json(json!({"status":p.status}))).into_response()
        }
        None => error(
            StatusCode::NOT_FOUND,
            "pairing_not_found",
            "Solicitação de pareamento não encontrada ou expirada.",
        ),
    }
}
async fn api_state(State(host): State<HostService>, headers: HeaderMap) -> impl IntoResponse {
    if let Some(x) = reject_origin(&headers) {
        return x;
    }
    if let Err(x) = host.authorize(&headers, None).await {
        return x;
    }
    let s = host.view().await;
    let a = s.appliance;
    let connected = s.appliance_connection == "connected" && a.is_some();
    let (device, state, caps) = if let Some(a) = a.filter(|_| connected) {
        (
            json!({"id":a.id,"name":a.name,"host":a.host}),
            json!({"power":a.is_powered_on,"temperature":a.target_temperature,"ambientTemperature":a.room_temperature,"humidity":a.humidity,"instantaneousPowerW":a.instantaneous_power_w,"cumulativeEnergyWh":a.cumulative_energy_wh,"mode":a.mode,"fanSpeed":a.fan_speed,"windFree":a.features.get("windFree").map(|f|f.enabled)}),
            json!({"power":a.raw_capabilities.get("power").and_then(Value::as_bool)==Some(true),"temperature":if a.temperature_step.is_some(){json!({"min":a.minimum_temperature,"max":a.maximum_temperature,"step":a.temperature_step})}else{Value::Null},"modes":a.supported_modes,"fanSpeeds":a.fan_speeds,"windFree":a.features.contains_key("windFree")}),
        )
    } else {
        (
            Value::Null,
            Value::Null,
            json!({"power":false,"temperature":null,"modes":[],"fanSpeeds":[],"windFree":false}),
        )
    };
    let result = json!({"connected":connected,"device":device,"state":state,"capabilities":caps,"error":s.appliance_error,"energy":s.energy_usage});
    (StatusCode::OK, Json(result)).into_response()
}
async fn api_command(
    State(host): State<HostService>,
    headers: HeaderMap,
    body: Bytes,
) -> impl IntoResponse {
    if let Some(x) = reject_origin(&headers) {
        return x;
    }
    if let Err(x) = host.authorize(&headers, None).await {
        return x;
    }
    if body.len() > MAX_BODY {
        return error(
            StatusCode::PAYLOAD_TOO_LARGE,
            "body_too_large",
            "O corpo da solicitação excede o limite permitido.",
        );
    }
    if !is_json(&headers) {
        return error(
            StatusCode::UNSUPPORTED_MEDIA_TYPE,
            "content_type_required",
            "Envie o corpo como application/json.",
        );
    }
    let body: Value = match serde_json::from_slice(&body) {
        Ok(v) => v,
        Err(_) => {
            return error(
                StatusCode::BAD_REQUEST,
                "invalid_json",
                "O corpo JSON está malformado.",
            )
        }
    };
    let kind = body.get("type").and_then(Value::as_str).unwrap_or("");
    let Some(value) = body.get("value").cloned() else {
        return error(
            StatusCode::BAD_REQUEST,
            "invalid_command",
            "Comando inválido.",
        );
    };
    let valid = match kind {
        "power" | "windFree" => value.is_boolean(),
        "temperature" => value.as_f64().is_some_and(f64::is_finite),
        "mode" | "fanSpeed" => value.is_string(),
        _ => false,
    };
    if !valid {
        return error(
            StatusCode::BAD_REQUEST,
            "invalid_value",
            "O valor enviado para o comando é inválido.",
        );
    }
    let action = match kind {
        "power" => host.control("power", value).await,
        "temperature" => host.control("temperature", value).await,
        "mode" => host.control("mode", value).await,
        "fanSpeed" => host.control("fanSpeed", value).await,
        "windFree" => host.control("windFree", value).await,
        _ => {
            return error(
                StatusCode::BAD_REQUEST,
                "unsupported_command",
                "Comando não reconhecido.",
            )
        }
    };
    match action {
        Ok(()) => api_state(State(host), headers).await.into_response(),
        Err(e) => error(StatusCode::BAD_GATEWAY, "appliance_command_failed", &e),
    }
}

impl HostService {
    async fn authorize(
        &self,
        headers: &HeaderMap,
        pairing: Option<&str>,
    ) -> Result<(), axum::response::Response> {
        let client = headers
            .get("X-Windfull-Client")
            .and_then(|v| v.to_str().ok())
            .unwrap_or("");
        let token = headers
            .get("authorization")
            .and_then(|v| v.to_str().ok())
            .and_then(|v| v.strip_prefix("Bearer "))
            .unwrap_or("");
        if !hex32(client)
            || token.len() != 64
            || !token
                .bytes()
                .all(|b| b.is_ascii_hexdigit() && !b.is_ascii_uppercase())
        {
            return Err(error(
                StatusCode::UNAUTHORIZED,
                "unauthorized",
                "Credencial inválida ou dispositivo revogado.",
            ));
        }
        let hash = hex::encode(Sha256::digest(token.as_bytes()));
        let okay = if let Some(id) = pairing {
            self.0
                .pending
                .lock()
                .await
                .get(id)
                .is_some_and(|p| p.client_id == client && p.secret_hash == hash)
        } else {
            self.0
                .paired
                .lock()
                .await
                .get(client)
                .is_some_and(|d| constant_time_eq(&d.secret_hash, &hash))
        };
        if okay {
            Ok(())
        } else {
            Err(error(
                StatusCode::UNAUTHORIZED,
                "unauthorized",
                "Credencial inválida ou dispositivo revogado.",
            ))
        }
    }
}

fn reject_origin(headers: &HeaderMap) -> Option<axum::response::Response> {
    if headers.contains_key("origin") {
        Some(error(
            StatusCode::FORBIDDEN,
            "web_origin_rejected",
            "A API local não aceita solicitações de páginas web.",
        ))
    } else {
        None
    }
}

async fn not_found() -> axum::response::Response {
    error(StatusCode::NOT_FOUND, "not_found", "Rota não encontrada.")
}

async fn method_not_allowed() -> axum::response::Response {
    let mut response = error(
        StatusCode::METHOD_NOT_ALLOWED,
        "method_not_allowed",
        "Método HTTP não permitido.",
    );
    response
        .headers_mut()
        .insert("allow", "GET, POST".parse().unwrap());
    response
}

async fn security_headers(request: Request<axum::body::Body>, next: Next) -> Response {
    let origin = request.headers().contains_key("origin");
    let mut response = if origin {
        error(
            StatusCode::FORBIDDEN,
            "web_origin_rejected",
            "A API local não aceita solicitações de páginas web.",
        )
    } else {
        next.run(request).await
    };
    response
        .headers_mut()
        .insert("cache-control", "no-store".parse().unwrap());
    response
        .headers_mut()
        .insert("x-content-type-options", "nosniff".parse().unwrap());
    response
}

fn is_json(headers: &HeaderMap) -> bool {
    headers
        .get("content-type")
        .and_then(|value| value.to_str().ok())
        .and_then(|value| value.split(';').next())
        .is_some_and(|mime| mime.trim().eq_ignore_ascii_case("application/json"))
}

fn sanitize_client_name(raw: &str) -> String {
    let cleaned = raw
        .chars()
        .filter(|character| (*character as u32) >= 32 && *character != '\u{7f}')
        .collect::<String>();
    let cleaned = cleaned.trim();
    if cleaned.is_empty() {
        return "Dispositivo Android".into();
    }
    cleaned.chars().take(80).collect()
}

fn error(status: StatusCode, code: &str, message: &str) -> axum::response::Response {
    (
        status,
        Json(json!({"error":{"code":code,"message":message}})),
    )
        .into_response()
}
fn hex32(v: &str) -> bool {
    v.len() == 32
        && v.bytes()
            .all(|b| b.is_ascii_hexdigit() && !b.is_ascii_uppercase())
}
fn constant_time_eq(a: &str, b: &str) -> bool {
    if a.len() != b.len() {
        return false;
    }
    a.bytes()
        .zip(b.bytes())
        .fold(0u8, |diff, (x, y)| diff | (x ^ y))
        == 0
}
fn pairing_code(request_id: &str, fingerprint: &str) -> String {
    let hash = Sha256::digest(format!("windfull-pair-v1:{request_id}:{fingerprint}").as_bytes());
    let value = u32::from_be_bytes([hash[0], hash[1], hash[2], hash[3]]) % 1_000_000;
    format!("{value:06}")
}
