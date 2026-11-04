use chrono::Timelike;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::BTreeMap;

#[derive(Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct HostViewState {
    pub status: String,
    pub server_error: Option<String>,
    pub local_addresses: Vec<String>,
    pub server_port: Option<u16>,
    pub certificate_fingerprint: Option<String>,
    pub is_discovering: bool,
    pub has_searched_for_appliances: bool,
    pub discovered_appliances: Vec<DiscoveredAppliance>,
    pub discovery_error: Option<String>,
    pub selected_appliance_id: Option<String>,
    pub appliance_connection: String,
    pub appliance_error: Option<String>,
    pub appliance: Option<ApplianceState>,
    pub energy_usage: EnergyUsageState,
    pub pending_pairings: Vec<PendingPairing>,
    pub paired_devices: Vec<PairedDevice>,
    pub busy_actions: Vec<String>,
    pub start_with_windows: bool,
    pub off_timer_ends_at: Option<String>,
    pub filter_runtime_hours: f64,
    pub filter_reminder_due: bool,
    pub filter_reminder_interval_hours: u64,
    pub alerts_enabled: bool,
}

impl Default for HostViewState {
    fn default() -> Self {
        Self {
            status: "starting".into(),
            server_error: None,
            local_addresses: vec![],
            server_port: None,
            certificate_fingerprint: None,
            is_discovering: false,
            has_searched_for_appliances: false,
            discovered_appliances: vec![],
            discovery_error: None,
            selected_appliance_id: None,
            appliance_connection: "unknown".into(),
            appliance_error: None,
            appliance: None,
            energy_usage: EnergyUsageState::default(),
            pending_pairings: vec![],
            paired_devices: vec![],
            busy_actions: vec![],
            start_with_windows: false,
            off_timer_ends_at: None,
            filter_runtime_hours: 0.0,
            filter_reminder_due: false,
            filter_reminder_interval_hours: 500,
            alerts_enabled: true,
        }
    }
}

#[derive(Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct EnergyUsageState {
    #[serde(rename = "todayKWh")]
    pub today_kwh: f64,
    #[serde(rename = "hourlyKWh")]
    pub hourly_kwh: Vec<f64>,
    #[serde(rename = "pricePerKWh")]
    pub price_per_kwh: f64,
    pub monthly_estimate: f64,
    #[serde(rename = "meterKWh")]
    pub meter_kwh: Option<f64>,
    pub last_sample_at: Option<String>,
    pub has_baseline: bool,
}

#[derive(Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DiscoveredAppliance {
    pub id: String,
    pub name: String,
    pub host: String,
    pub is_reachable: Option<bool>,
    pub is_powered_on: Option<bool>,
    pub target_temperature: Option<f64>,
    pub room_temperature: Option<f64>,
    pub port: Option<u16>,
}

#[derive(Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ApplianceState {
    pub id: String,
    pub name: String,
    pub host: String,
    pub model: Option<String>,
    pub is_powered_on: Option<bool>,
    pub target_temperature: Option<f64>,
    pub room_temperature: Option<f64>,
    pub humidity: Option<f64>,
    pub instantaneous_power_w: Option<f64>,
    pub cumulative_energy_wh: Option<f64>,
    pub minimum_temperature: Option<f64>,
    pub maximum_temperature: Option<f64>,
    pub temperature_step: Option<f64>,
    pub mode: Option<String>,
    pub supported_modes: Vec<String>,
    pub fan_speed: Option<String>,
    pub fan_speeds: Vec<String>,
    pub features: BTreeMap<String, ApplianceFeatureState>,
    #[serde(skip)]
    pub raw_capabilities: Value,
}

#[derive(Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ApplianceFeatureState {
    pub label: String,
    pub enabled: bool,
}

#[derive(Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PendingPairing {
    pub id: String,
    pub device_name: String,
    pub device_description: Option<String>,
    pub verification_code: String,
    pub expires_at: String,
}

#[derive(Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PairedDevice {
    pub id: String,
    pub name: String,
    pub description: Option<String>,
    pub paired_at: String,
    pub last_seen_at: Option<String>,
    #[serde(skip_serializing)]
    pub secret_hash: String,
}

#[derive(Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct EnergyTracker {
    #[serde(rename = "pricePerKWh")]
    pub price_per_kwh: f64,
    day: Option<String>,
    #[serde(rename = "hourlyWattHours")]
    hourly_watt_hours: Vec<f64>,
    #[serde(rename = "lastMeterWattHours")]
    last_meter_watt_hours: Option<f64>,
    #[serde(rename = "lastSampleAt")]
    last_sample_at: Option<String>,
}

impl EnergyTracker {
    pub fn view(&self) -> EnergyUsageState {
        let hours = if self.hourly_watt_hours.len() == 24 {
            self.hourly_watt_hours.clone()
        } else {
            vec![0.0; 24]
        };
        let today = hours.iter().sum::<f64>() / 1000.0;
        EnergyUsageState {
            today_kwh: today,
            hourly_kwh: hours.iter().map(|v| v / 1000.0).collect(),
            price_per_kwh: if self.price_per_kwh > 0.0 {
                self.price_per_kwh
            } else {
                0.95
            },
            monthly_estimate: today
                * 30.0
                * if self.price_per_kwh > 0.0 {
                    self.price_per_kwh
                } else {
                    0.95
                },
            meter_kwh: self.last_meter_watt_hours.map(|v| v / 1000.0),
            last_sample_at: self.last_sample_at.clone(),
            has_baseline: self.last_meter_watt_hours.is_some(),
        }
    }
    pub fn record(&mut self, wh: f64) {
        if !wh.is_finite() || wh < 0.0 {
            return;
        }
        let current = chrono::Local::now();
        let now = current.to_rfc3339();
        let day = current.format("%Y-%m-%d").to_string();
        let previous_day = self
            .last_sample_at
            .as_deref()
            .and_then(|s| chrono::DateTime::parse_from_rfc3339(s).ok())
            .map(|d| {
                d.with_timezone(&chrono::Local)
                    .format("%Y-%m-%d")
                    .to_string()
            });
        if self.day.as_deref() != Some(day.as_str()) {
            self.day = Some(day.clone());
            self.hourly_watt_hours = vec![0.0; 24];
        }
        if self.hourly_watt_hours.len() != 24 {
            self.hourly_watt_hours = vec![0.0; 24];
        }
        if let (Some(previous), Some(at)) = (
            self.last_meter_watt_hours,
            self.last_sample_at
                .as_deref()
                .and_then(|s| chrono::DateTime::parse_from_rfc3339(s).ok()),
        ) {
            let elapsed_hours = (current.with_timezone(at.offset()) - at)
                .num_seconds()
                .max(0) as f64
                / 3600.0;
            if previous_day.as_deref() == Some(day.as_str())
                && elapsed_hours > 0.0
                && wh >= previous
            {
                let delta = wh - previous;
                let plausible = (10000.0 * elapsed_hours).max(250.0);
                if delta > 0.0 && delta <= plausible {
                    self.hourly_watt_hours[current.hour() as usize] += delta;
                }
            }
        }
        self.last_meter_watt_hours = Some(wh);
        self.last_sample_at = Some(now);
    }
}

impl Default for EnergyTracker {
    fn default() -> Self {
        Self {
            price_per_kwh: 0.95,
            day: None,
            hourly_watt_hours: vec![0.0; 24],
            last_meter_watt_hours: None,
            last_sample_at: None,
        }
    }
}
