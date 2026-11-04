//! Samsung OCF local client. Wire framing follows CoAP RFC 7252 and the
//! representations are decoded as CBOR. This module contains no cloud calls.
use ciborium::value::Value;
use openssl::asn1::Asn1Time;
use openssl::bn::BigNum;
use openssl::ec::{EcGroup, EcKey};
use openssl::hash::MessageDigest;
use openssl::nid::Nid;
use openssl::pkey::PKey;
use openssl::ssl::{SslConnector, SslMethod, SslStream, SslVerifyMode};
use openssl::x509::{X509NameBuilder, X509};
use rand::Rng;
use serde::{Deserialize, Serialize};
use serde_json::{json, Map as JsonMap, Value as JsonValue};
use std::collections::HashMap;
use std::fs;
use std::io::{self, Read, Write};
use std::net::{Ipv4Addr, ToSocketAddrs, UdpSocket};
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

const DEVICE_UUID: &str = "ab0b0ac4-aae9-4958-a04d-8ec36fe1b2f9";
const OCF_MULTICAST: Ipv4Addr = Ipv4Addr::new(224, 0, 1, 187);
const DISCOVERY_PORT: u16 = 5683;
// Samsung's public OCF endpoint also answers directly on its observed local
// CoAP source port. This preserves the UDP peer tuple on Windows firewalls.
const SAMSUNG_PLAIN_PORT: u16 = 49153;
const COAP_ACK_TIMEOUT_MIN_MS: u64 = 1_000;
const COAP_ACK_TIMEOUT_MAX_MS: u64 = 1_500;
const COAP_MAX_RETRANSMITS: usize = 3;
const COAP_NOT_FOUND: u8 = (4 << 5) | 4;
const COAP_OBSERVE: u16 = 6;
const OCF_OBSERVABLE_BIT: u64 = 0x02;
const DTLS_PORTS: &[u16] = &[
    5684, 49152, 49153, 49154, 49155, 49156, 49157, 49158, 49159, 49160,
];
const SAMSUNG_PREFIX: &str = "x.com.samsung.da.";

#[derive(Debug)]
pub struct Error {
    pub code: &'static str,
    pub message: String,
    ocf_response_code: Option<u8>,
}

impl Error {
    fn new(code: &'static str, message: impl Into<String>) -> Self {
        Self {
            code,
            message: message.into(),
            ocf_response_code: None,
        }
    }
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Device {
    pub id: String,
    pub host: String,
    pub name: Option<String>,
    pub model: Option<String>,
    pub port: Option<u16>,
}

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Snapshot {
    pub power: Option<bool>,
    pub temperature: Option<f64>,
    pub ambient_temperature: Option<f64>,
    pub humidity: Option<f64>,
    pub instantaneous_power_w: Option<f64>,
    pub cumulative_energy_wh: Option<f64>,
    pub mode: Option<String>,
    pub fan_speed: Option<String>,
    pub wind_free: Option<bool>,
    #[serde(default)]
    pub raw_values: JsonMap<String, JsonValue>,
}

struct UdpIo(UdpSocket);
impl Read for UdpIo {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        self.0.recv(buf)
    }
}
impl Write for UdpIo {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        self.0.send(buf)
    }
    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

pub struct Appliance {
    stream: SslStream<UdpIo>,
    device: Device,
    message_id: u16,
    resource_catalog: Vec<ResourceLink>,
    pin_dir: std::path::PathBuf,
    server_fingerprint: String,
    expected_device_id: Option<String>,
    fast_requests: bool,
    fast_fallback_used: bool,
    fast_due_href: Option<String>,
    observed: HashMap<u8, ObservedResource>,
    resource_cache: HashMap<String, CachedResource>,
    unavailable_resources: HashMap<String, Instant>,
    poll_backoff: HashMap<String, Instant>,
    tree_cache: Option<(Value, Instant)>,
    observe_attempted_at: Option<Instant>,
}

#[derive(Clone, Debug)]
struct ResourceLink {
    href: String,
    resource_types: Vec<String>,
    interfaces: Vec<String>,
    observable: bool,
}

struct ObservedResource {
    href: String,
    sequence: Option<u32>,
    active: bool,
}

struct CachedResource {
    value: Value,
    updated: Instant,
}

struct CoapResponse {
    code: u8,
    payload: Option<Vec<u8>>,
    block2: Option<(u32, bool, u8)>,
    observe: Option<u32>,
    token: u8,
}

impl Appliance {
    pub fn connect(
        host: &str,
        requested_port: Option<u16>,
        data_dir: &Path,
    ) -> Result<Self, Error> {
        validate_host(host)?;
        let (cert, key) = ensure_identity(data_dir)?;
        let (device_id, mut candidates) = discover_host(host, Duration::from_secs(2))?;
        if let Some(port) = requested_port {
            candidates.retain(|candidate| *candidate == port);
            if candidates.is_empty() {
                return Err(Error::new(
                    "unsupported_device",
                    "The selected endpoint does not advertise the requested secure port",
                ));
            }
        }
        let mut last_error = Error::new(
            "device_unreachable",
            "No compatible local OCF endpoint answered",
        );
        for port in candidates {
            match Self::connect_port(host, port, &cert, &key, data_dir, Some(device_id.clone())) {
                Ok(mut appliance) => match appliance.read_identity() {
                    Ok(device) => {
                        appliance.device = device;
                        return Ok(appliance);
                    }
                    Err(error) => last_error = error,
                },
                Err(error) => last_error = error,
            }
        }
        Err(last_error)
    }

    fn connect_port(
        host: &str,
        port: u16,
        cert_pem: &str,
        key_pem: &str,
        data_dir: &Path,
        expected_device_id: Option<String>,
    ) -> Result<Self, Error> {
        let cert = X509::from_pem(cert_pem.as_bytes())
            .map_err(|_| Error::new("identity_error", "Could not load local device identity"))?;
        let key = PKey::private_key_from_pem(key_pem.as_bytes())
            .map_err(|_| Error::new("identity_error", "Could not load local device identity"))?;
        let mut builder = SslConnector::builder(SslMethod::dtls())
            .map_err(|_| Error::new("dtls_unavailable", "OpenSSL DTLS support is unavailable"))?;
        builder
            .set_cipher_list("ECDHE-ECDSA-AES128-GCM-SHA256")
            .map_err(|_| {
                Error::new(
                    "dtls_configuration",
                    "Required OCF DTLS cipher is unavailable",
                )
            })?;
        builder.set_certificate(&cert).map_err(|_| {
            Error::new(
                "identity_error",
                "Could not configure local device identity",
            )
        })?;
        builder.set_private_key(&key).map_err(|_| {
            Error::new(
                "identity_error",
                "Could not configure local device identity",
            )
        })?;
        // OCF appliance identities are self-signed. Permit the initial DTLS
        // handshake only so the leaf can be pinned by fingerprint below.
        builder.set_verify_callback(SslVerifyMode::PEER, |_, _| true);

        let address = (host, port)
            .to_socket_addrs()
            .map_err(|_| Error::new("invalid_host", "Could not resolve the appliance host"))?
            .find(|addr| addr.is_ipv4())
            .ok_or_else(|| Error::new("invalid_host", "An IPv4 appliance address is required"))?;
        let socket = UdpSocket::bind("0.0.0.0:0")
            .map_err(|_| Error::new("network_error", "Could not open a local UDP socket"))?;
        socket.connect(address).map_err(|_| {
            Error::new(
                "device_unreachable",
                "Could not reach the appliance on the local network",
            )
        })?;
        socket.set_read_timeout(Some(Duration::from_secs(4))).ok();
        socket.set_write_timeout(Some(Duration::from_secs(3))).ok();
        let connector = builder.build();
        let config = connector
            .configure()
            .map_err(|_| Error::new("dtls_configuration", "Could not configure DTLS"))?
            .verify_hostname(false)
            .use_server_name_indication(false);
        let stream = config.connect("ocf-device", UdpIo(socket)).map_err(|_| {
            Error::new(
                "authentication_or_timeout",
                "Local DTLS handshake failed; check the model, pairing state, and UDP firewall",
            )
        })?;
        let peer_cert = stream.ssl().peer_certificate().ok_or_else(|| {
            Error::new(
                "peer_certificate_missing",
                "The OCF appliance did not present a DTLS certificate",
            )
        })?;
        let fingerprint = peer_cert
            .digest(MessageDigest::sha256())
            .map_err(|_| {
                Error::new(
                    "certificate_error",
                    "Could not fingerprint the OCF appliance certificate",
                )
            })?
            .iter()
            .map(|byte| format!("{byte:02x}"))
            .collect::<String>();
        check_pin(data_dir, "host", host, &fingerprint)?;
        let mut rng = rand::thread_rng();
        Ok(Self {
            stream,
            device: Device {
                id: String::new(),
                host: host.into(),
                name: None,
                model: None,
                port: Some(port),
            },
            message_id: rng.gen(),
            resource_catalog: Vec::new(),
            pin_dir: data_dir.join("ocf-server-pins"),
            server_fingerprint: fingerprint,
            expected_device_id,
            fast_requests: false,
            fast_fallback_used: false,
            fast_due_href: None,
            observed: HashMap::new(),
            resource_cache: HashMap::new(),
            unavailable_resources: HashMap::new(),
            poll_backoff: HashMap::new(),
            tree_cache: None,
            observe_attempted_at: None,
        })
    }

    pub fn device(&self) -> &Device {
        &self.device
    }

    fn request(
        &mut self,
        method: u8,
        path: &str,
        payload: Option<&Value>,
    ) -> Result<(u8, Option<Value>), Error> {
        self.message_id = self.message_id.wrapping_add(1);
        let msg_id = self.message_id;
        let token = (msg_id & 0x7f) as u8;
        let message = encode_request(msg_id, token, method, path, payload)?;
        let response = self.exchange_confirmable(&message, msg_id, token)?;
        let value = response
            .payload
            .map(|payload| {
                ciborium::de::from_reader(payload.as_slice())
                    .map_err(|_| Error::new("invalid_response", "OCF payload was not valid CBOR"))
            })
            .transpose()?;
        Ok((response.code, value))
    }

    fn get(&mut self, path: &str) -> Result<Value, Error> {
        let mut payload = Vec::new();
        let mut block_number = 0_u32;
        let mut block_size = 6_u8;
        let mut response_code = 0_u8;
        let mid = self.message_id;
        let token = rand::thread_rng().gen_range(0..=0x7f);
        for block_count in 0..64 {
            self.message_id = self.message_id.wrapping_add(1);
            let response = self.request_once(
                1,
                path,
                None,
                token,
                if block_count == 0 {
                    None
                } else {
                    Some((block_number, block_size))
                },
            )?;
            response_code = response.code;
            if response.code >> 5 != 2 {
                let mut error = Error::new(
                    "ocf_rejected",
                    format!(
                        "The appliance rejected OCF resource {path} (code {}.{:02})",
                        response.code >> 5,
                        response.code & 0x1f
                    ),
                );
                error.ocf_response_code = Some(response.code);
                return Err(error);
            }
            let bytes = response.payload.ok_or_else(|| {
                Error::new(
                    "invalid_response",
                    "The appliance response contained no CBOR representation",
                )
            })?;
            payload.extend(bytes);
            let Some((number, more, szx)) = response.block2 else {
                break;
            };
            if !more {
                break;
            }
            block_number = number + 1;
            block_size = szx;
            if block_count == 63 {
                return Err(Error::new(
                    "invalid_response",
                    "OCF block transfer exceeded its safe limit",
                ));
            }
        }
        self.message_id = self.message_id.max(mid);
        let code = response_code;
        if code >> 5 != 2 {
            let mut error = Error::new(
                "ocf_rejected",
                format!(
                    "The appliance rejected OCF resource {path} (code {}.{:02})",
                    code >> 5,
                    code & 0x1f
                ),
            );
            error.ocf_response_code = Some(code);
            return Err(error);
        }
        ciborium::de::from_reader(payload.as_slice())
            .map(unwrap_single_map_envelope)
            .map_err(|_| Error::new("invalid_response", "OCF payload was not valid CBOR"))
    }

    fn get_resource(&mut self, href: &str) -> Result<Value, Error> {
        if self
            .unavailable_resources
            .get(href)
            .is_some_and(|retry_at| *retry_at > Instant::now())
        {
            return Err(Error::new(
                "resource_unavailable",
                "The appliance reports this optional resource as unavailable",
            ));
        }
        if self.fast_requests
            && self
                .poll_backoff
                .get(href)
                .is_some_and(|retry_at| *retry_at > Instant::now())
        {
            return self
                .resource_cache
                .get(href)
                .map(|cached| cached.value.clone())
                .ok_or_else(|| Error::new("state_pending", "Resource read is in brief backoff"));
        }
        let observe_active = self
            .observed
            .values()
            .any(|resource| resource.active && resource.href == href);
        let cached = self.resource_cache.get(href);
        let is_fresh =
            cached.is_some_and(|value| value.updated.elapsed() < resource_poll_interval(href));
        if observe_active && cached.is_some() {
            return Ok(cached.expect("checked above").value.clone());
        }
        if self.fast_requests {
            if is_fresh || self.fast_due_href.as_deref() != Some(href) || self.fast_fallback_used {
                return cached.map(|value| value.value.clone()).ok_or_else(|| {
                    Error::new(
                        "state_pending",
                        "Waiting for the next scheduled appliance resource read",
                    )
                });
            }
            self.fast_fallback_used = true;
        } else if is_fresh {
            return Ok(cached.expect("checked above").value.clone());
        }
        match self.get_resource_uncached(href) {
            Ok(value) => {
                self.unavailable_resources.remove(href);
                self.poll_backoff.remove(href);
                self.resource_cache.insert(
                    href.to_string(),
                    CachedResource {
                        value: value.clone(),
                        updated: Instant::now(),
                    },
                );
                Ok(value)
            }
            Err(error) => {
                if error.ocf_response_code.is_some_and(|code| code >> 5 == 4) {
                    self.unavailable_resources
                        .insert(href.to_string(), Instant::now() + Duration::from_secs(300));
                }
                if self.fast_requests && matches!(error.code, "timeout" | "network_error") {
                    self.poll_backoff
                        .insert(href.to_string(), Instant::now() + Duration::from_secs(2));
                    if let Some(cached) = self.resource_cache.get(href) {
                        return Ok(cached.value.clone());
                    }
                    return Err(Error::new(
                        "state_pending",
                        "Resource read is in brief backoff",
                    ));
                }
                Err(error)
            }
        }
    }

    fn get_resource_uncached(&mut self, href: &str) -> Result<Value, Error> {
        match self.get(href) {
            Ok(value) => Ok(value),
            Err(error)
                if error.code == "ocf_rejected"
                    && error.ocf_response_code == Some(COAP_NOT_FOUND) =>
            {
                // A discovered optional resource may be absent on some Samsung firmware.
                // A 4.04 cannot be fixed by retrying the same resource with another interface.
                Err(error)
            }
            Err(mut last_error) if last_error.code == "ocf_rejected" => {
                let interfaces = self
                    .resource_catalog
                    .iter()
                    .find(|link| link.href == href)
                    .map(|link| link.interfaces.clone())
                    .unwrap_or_default();
                for interface in interfaces {
                    let path = format!("{href}?if={interface}");
                    match self.get(&path) {
                        Ok(value) => return Ok(value),
                        Err(error) => {
                            let message = format!(
                                "{}; interface {interface}: {}",
                                last_error.message, error.message
                            );
                            last_error = error;
                            last_error.message = message;
                        }
                    }
                }
                Err(last_error)
            }
            Err(error) => Err(error),
        }
    }

    fn request_once(
        &mut self,
        method: u8,
        path: &str,
        payload: Option<&Value>,
        token: u8,
        block2: Option<(u32, u8)>,
    ) -> Result<CoapResponse, Error> {
        let (path, query) = path
            .split_once('?')
            .map_or((path, None), |(path, query)| (path, Some(query)));
        let message =
            encode_request_full(self.message_id, token, method, path, payload, query, block2)?;
        if self.fast_requests {
            self.exchange_confirmable_fast(&message, self.message_id, token)
        } else {
            self.exchange_confirmable(&message, self.message_id, token)
        }
    }

    fn exchange_confirmable(
        &mut self,
        message: &[u8],
        message_id: u16,
        token: u8,
    ) -> Result<CoapResponse, Error> {
        self.exchange_confirmable_with_policy(
            message,
            message_id,
            token,
            COAP_ACK_TIMEOUT_MIN_MS,
            COAP_ACK_TIMEOUT_MAX_MS,
            COAP_MAX_RETRANSMITS,
        )
    }

    fn exchange_confirmable_fast(
        &mut self,
        message: &[u8],
        message_id: u16,
        token: u8,
    ) -> Result<CoapResponse, Error> {
        self.exchange_confirmable_with_policy(message, message_id, token, 120, 200, 1)
    }

    fn exchange_confirmable_with_policy(
        &mut self,
        message: &[u8],
        message_id: u16,
        token: u8,
        timeout_min_ms: u64,
        timeout_max_ms: u64,
        max_retransmits: usize,
    ) -> Result<CoapResponse, Error> {
        // These requests are CON messages. Retry the identical MID/token so
        // the appliance can deduplicate a delayed response after packet loss.
        let mut ack_timeout_ms = rand::thread_rng().gen_range(timeout_min_ms..=timeout_max_ms);
        let mut acknowledged = false;
        let mut buf = [0_u8; 16 * 1024];
        for retransmission in 0..=max_retransmits {
            let timeout = Duration::from_millis(ack_timeout_ms);
            if retransmission == 0 || !acknowledged {
                self.stream.write_all(message).map_err(|_| {
                    Error::new(
                        "network_error",
                        "Could not send or resend the local OCF request",
                    )
                })?;
            }
            let deadline = Instant::now() + timeout;
            loop {
                let remaining = deadline.saturating_duration_since(Instant::now());
                if remaining.is_zero() {
                    break;
                }
                self.stream
                    .get_mut()
                    .0
                    .set_read_timeout(Some(remaining))
                    .map_err(|_| {
                        Error::new("network_error", "Could not configure OCF receive timeout")
                    })?;
                let n = match self.stream.read(&mut buf) {
                    Ok(n) => n,
                    Err(error)
                        if matches!(
                            error.kind(),
                            io::ErrorKind::TimedOut | io::ErrorKind::WouldBlock
                        ) =>
                    {
                        break;
                    }
                    Err(_) => {
                        return Err(Error::new(
                            "network_error",
                            "The local OCF connection was interrupted",
                        ));
                    }
                };
                if n < 4 {
                    continue;
                }
                let tkl = (buf[0] & 0x0f) as usize;
                let message_type = (buf[0] >> 4) & 0x03;
                let code = buf[1];
                if message_type == 2 && code == 0 && tkl == 0 {
                    if u16::from_be_bytes([buf[2], buf[3]]) == message_id {
                        acknowledged = true;
                    }
                    continue;
                }
                if message_type == 0 {
                    self.ack_confirmable(&buf[..n])?;
                }
                if n < 4 + tkl || tkl == 0 {
                    continue;
                }
                let packet_token = buf[4];
                if packet_token != token {
                    self.accept_observe_packet(&buf[..n]);
                    continue;
                }
                return decode_packet(&buf[..n]);
            }
            ack_timeout_ms = ack_timeout_ms.saturating_mul(2);
        }
        Err(Error::new(
            "timeout",
            "The appliance did not answer the local OCF request after retransmissions",
        ))
    }

    fn ack_confirmable(&mut self, packet: &[u8]) -> Result<(), Error> {
        if packet.len() < 4 || packet[0] >> 6 != 1 || (packet[0] >> 4) & 0x03 != 0 {
            return Ok(());
        }
        let ack = empty_ack(u16::from_be_bytes([packet[2], packet[3]]));
        self.stream.write_all(&ack).map_err(|_| {
            Error::new(
                "network_error",
                "Could not acknowledge a local OCF response",
            )
        })
    }

    fn post(&mut self, path: &str, payload: Value) -> Result<(), Error> {
        let (code, _) = self.request(2, path, Some(&payload))?;
        if code >> 5 != 2 {
            return Err(Error::new(
                "ocf_rejected",
                format!(
                    "The appliance rejected the requested change (code {}.{:02})",
                    code >> 5,
                    code & 0x1f
                ),
            ));
        }
        Ok(())
    }

    fn read_identity(&mut self) -> Result<Device, Error> {
        let data = self.get("oic/d")?;
        let id = text(&data, "di").ok_or_else(|| {
            Error::new(
                "unsupported_device",
                "The endpoint did not identify itself as an OCF device",
            )
        })?;
        if self
            .expected_device_id
            .as_deref()
            .is_some_and(|expected| expected != id)
        {
            return Err(Error::new(
                "device_changed",
                "The secure endpoint identity differs from public OCF discovery",
            ));
        }
        let name = text(&data, "n");
        let model = text(&data, "mnmo").or_else(|| text(&data, "model"));
        if !is_air_conditioner(&data) {
            return Err(Error::new(
                "unsupported_device",
                "The OCF device did not report the air-conditioner resource type",
            ));
        }
        let mut device = Device {
            id,
            host: self.device.host.clone(),
            name,
            model,
            port: self.device.port,
        };
        verify_and_store_pin(
            &self.pin_dir,
            &device.host,
            &device.id,
            &self.server_fingerprint,
        )?;
        let catalog = self.get("oic/res")?;
        self.resource_catalog = parse_resource_catalog(&catalog);
        if self.resource_catalog.is_empty() {
            return Err(Error::new(
                "invalid_response",
                "The appliance resource directory contained no resource links",
            ));
        }
        if self
            .resource_catalog
            .iter()
            .any(|link| link.href.starts_with("/hass/"))
        {
            if let Ok(Some(tree)) = self.read_device_tree() {
                device.model = tree_resource(&tree, "/information/vs/0")
                    .and_then(|rep| text(rep, "modelNum"))
                    .or(device.model);
            }
        }
        Ok(device)
    }

    pub fn read_state_fast(&mut self) -> Result<Snapshot, Error> {
        self.pump_observers()?;
        self.fast_requests = true;
        self.fast_fallback_used = false;
        self.fast_due_href = self.next_fallback_href();
        let result = self.read_state();
        self.fast_requests = false;
        self.fast_due_href = None;
        result
    }

    pub fn read_state(&mut self) -> Result<Snapshot, Error> {
        let mut snapshot = Snapshot::default();
        let mut collect = JsonMap::new();
        let mut tree_data = None;
        match self.read_device_tree() {
            Ok(Some(tree)) => {
                tree_data = Some(tree.clone());
                let safe = sanitize_json(cbor_to_json(&tree));
                collect.insert("/device/0".into(), safe.clone());
                add_tree_representations(&tree, &mut collect);
            }
            Ok(None) => {}
            Err(error) => {
                collect.insert(
                    "/device/0".into(),
                    json!({"readError": error.code, "message": error.message}),
                );
            }
        }
        if let Some(tree) = tree_data.as_ref() {
            read_snapshot_from_tree(tree, &mut snapshot);
        }
        let power_href = self.find_samsung_href(&["power"]);
        let set_temp_href = self
            .find_samsung_href(&["temperature", "desired"])
            .or_else(|| self.find_samsung_href(&["temperatures"]));
        let ambient_href = self.find_samsung_href(&["temperature", "current"]);
        let humidity_href = self
            .find_samsung_href(&["humidity"])
            .or_else(|| self.find_resource_href(&["humidity"]));
        let energy_href = self
            .find_samsung_href(&["energy", "consumption"])
            .or_else(|| self.find_resource_href(&["energy", "consumption"]));
        let mode_href = self.find_mode_href();
        let fan_href = self.find_samsung_href(&["wind", "strength"]);
        let windfree_href = self.find_samsung_href(&["mode", "convenient"]);
        let hass_state_href = self.find_samsung_href(&["hass", "state"]);
        for href in [
            power_href.as_deref(),
            set_temp_href.as_deref(),
            ambient_href.as_deref(),
            humidity_href.as_deref(),
            energy_href.as_deref(),
            mode_href.as_deref(),
            fan_href.as_deref(),
            windfree_href.as_deref(),
            hass_state_href.as_deref(),
        ]
        .into_iter()
        .flatten()
        {
            match self.get_resource(href) {
                Ok(value) => {
                    let json_value = cbor_to_json(&value);
                    if let Some(power) = text(&value, "power") {
                        snapshot.power = match power.as_str() {
                            "On" => Some(true),
                            "Off" => Some(false),
                            _ => None,
                        };
                    }
                    if Some(href) == set_temp_href.as_deref() {
                        if let Some(items) = get(&value, "items").and_then(as_array) {
                            if let Some(item) = items.first() {
                                snapshot.temperature = number(item, "desired");
                            }
                        }
                        if snapshot.temperature.is_none() {
                            snapshot.temperature = number(&value, "desired");
                        }
                    }
                    if Some(href) == ambient_href.as_deref() {
                        snapshot.ambient_temperature = number(&value, "temperature");
                    }
                    if Some(href) == humidity_href.as_deref() {
                        snapshot.humidity = humidity_value(&value);
                    }
                    if Some(href) == energy_href.as_deref() {
                        let values = energy_values(&value);
                        snapshot.instantaneous_power_w = values.0;
                        snapshot.cumulative_energy_wh = values.1;
                    }
                    if Some(href) == mode_href.as_deref() {
                        if let Some(modes) = get(&value, "modes") {
                            snapshot.mode = as_array(modes)
                                .and_then(|a| a.first())
                                .and_then(as_text)
                                .or_else(|| as_text(modes));
                        }
                    }
                    if Some(href) == fan_href.as_deref() {
                        snapshot.fan_speed = text(&value, "modes");
                    }
                    if Some(href) == windfree_href.as_deref() {
                        snapshot.wind_free =
                            text(&value, "modes").and_then(|mode| match mode.as_str() {
                                "Nano" | "NanoSleep" => Some(true),
                                "Off" => Some(false),
                                _ => None,
                            });
                    }
                    collect.insert(href.to_string(), json_value);
                }
                Err(error) if error.code == "timeout" || error.code == "network_error" => {
                    return Err(error)
                }
                Err(error) => {
                    collect.insert(
                        href.to_string(),
                        json!({"readError": error.code, "message": error.message}),
                    );
                }
            }
        }
        snapshot.raw_values = collect;
        self.register_state_observers();
        Ok(snapshot)
    }

    fn register_state_observers(&mut self) {
        if self
            .observe_attempted_at
            .is_some_and(|at| at.elapsed() < Duration::from_secs(60))
        {
            return;
        }
        self.observe_attempted_at = Some(Instant::now());
        let targets = self
            .state_resource_hrefs()
            .into_iter()
            .filter(|href| {
                self.resource_catalog
                    .iter()
                    .any(|link| link.href == *href && link.observable)
            })
            .collect::<Vec<_>>();
        for (slot, href) in targets.into_iter().enumerate() {
            if slot >= 128 {
                break;
            }
            if self
                .observed
                .values()
                .any(|resource| resource.href == href && resource.active)
            {
                continue;
            }
            let token = 0x80_u8.wrapping_add(slot as u8);
            self.observed.insert(
                token,
                ObservedResource {
                    href: href.clone(),
                    sequence: None,
                    active: false,
                },
            );
            self.message_id = self.message_id.wrapping_add(1);
            let message_id = self.message_id;
            let message =
                match encode_request_with_observe(message_id, token, 1, &href, None, Some(0)) {
                    Ok(message) => message,
                    Err(_) => {
                        self.observed.remove(&token);
                        continue;
                    }
                };
            let response = self.exchange_confirmable_fast(&message, message_id, token);
            match response {
                Ok(response) if response.code >> 5 == 2 && response.observe.is_some() => {
                    if let Some(observer) = self.observed.get_mut(&token) {
                        observer.active = true;
                    }
                    self.cache_observe_payload(
                        &href,
                        response.observe,
                        response.payload.as_deref(),
                    );
                }
                _ => {
                    self.observed.remove(&token);
                }
            }
        }
        let active = self
            .observed
            .values()
            .filter(|observer| observer.active)
            .count();
        let advertised = self
            .state_resource_hrefs()
            .iter()
            .filter(|href| {
                self.resource_catalog
                    .iter()
                    .any(|link| link.href == href.as_str() && link.observable)
            })
            .count();
        eprintln!(
            "INFO: OCF Observe active for {active}/{advertised} advertised state resources; remaining resources use scheduled polling"
        );
    }

    fn state_resource_hrefs(&self) -> Vec<String> {
        let mut targets = Vec::new();
        for fragments in [
            &(["power"][..]),
            &["temperature", "desired"][..],
            &["temperatures"][..],
            &["temperature", "current"][..],
            &["humidity"][..],
            &["energy", "consumption"][..],
            &["mode"][..],
            &["wind", "strength"][..],
            &["mode", "convenient"][..],
            &["hass", "state"][..],
        ] {
            let href = if *fragments == ["mode"][..] {
                self.find_mode_href()
            } else if *fragments == ["humidity"][..] {
                self.find_samsung_href(fragments)
                    .or_else(|| self.find_resource_href(fragments))
            } else if *fragments == ["energy", "consumption"][..] {
                self.find_samsung_href(fragments)
                    .or_else(|| self.find_resource_href(fragments))
            } else if *fragments == ["temperature", "desired"][..] {
                self.find_samsung_href(fragments)
                    .or_else(|| self.find_samsung_href(&["temperatures"]))
            } else {
                self.find_samsung_href(fragments)
            };
            if let Some(href) = href {
                if !targets.contains(&href) {
                    targets.push(href);
                }
            }
        }
        targets
    }

    fn next_fallback_href(&self) -> Option<String> {
        self.state_resource_hrefs()
            .into_iter()
            .filter(|href| {
                !self
                    .observed
                    .values()
                    .any(|resource| resource.active && resource.href == *href)
                    && !self
                        .unavailable_resources
                        .get(href)
                        .is_some_and(|retry_at| *retry_at > Instant::now())
                    && !self
                        .poll_backoff
                        .get(href)
                        .is_some_and(|retry_at| *retry_at > Instant::now())
            })
            .filter_map(|href| {
                let interval = resource_poll_interval(&href);
                let (age, missing) = self
                    .resource_cache
                    .get(&href)
                    .map(|resource| (resource.updated.elapsed(), false))
                    .unwrap_or((Duration::ZERO, true));
                let overdue = if missing {
                    f64::MAX
                } else {
                    age.as_secs_f64() / interval.as_secs_f64()
                };
                (missing || age >= interval).then_some((href, overdue))
            })
            .max_by(|(_, left), (_, right)| left.total_cmp(right))
            .map(|(href, _)| href)
    }

    fn cache_observe_payload(&mut self, href: &str, sequence: Option<u32>, payload: Option<&[u8]>) {
        let Some(payload) = payload else { return };
        let Ok(value) = ciborium::de::from_reader::<Value, _>(payload) else {
            return;
        };
        let value = unwrap_single_map_envelope(value);
        self.resource_cache.insert(
            href.to_string(),
            CachedResource {
                value,
                updated: Instant::now(),
            },
        );
        if let Some(sequence) = sequence {
            for observer in self
                .observed
                .values_mut()
                .filter(|entry| entry.href == href)
            {
                observer.sequence = Some(sequence);
            }
        }
    }

    fn accept_observe_packet(&mut self, packet: &[u8]) {
        let Ok(response) = decode_packet(packet) else {
            return;
        };
        if response.code >> 5 != 2 {
            return;
        }
        let Some(sequence) = response.observe else {
            return;
        };
        let Some(observer) = self.observed.get(&response.token) else {
            return;
        };
        if !observer.active {
            return;
        }
        if let Some(previous) = observer.sequence {
            let distance = sequence.wrapping_sub(previous) & 0x00ff_ffff;
            if distance == 0 || distance >= 0x0080_0000 {
                return;
            }
        }
        let href = observer.href.clone();
        self.cache_observe_payload(&href, Some(sequence), response.payload.as_deref());
    }

    fn pump_observers(&mut self) -> Result<(), Error> {
        if !self.observed.values().any(|observer| observer.active) {
            return Ok(());
        }
        let mut buf = [0_u8; 16 * 1024];
        self.stream
            .get_mut()
            .0
            .set_read_timeout(Some(Duration::from_millis(5)))
            .map_err(|_| Error::new("network_error", "Could not configure OCF receive timeout"))?;
        for _ in 0..64 {
            let n = match self.stream.read(&mut buf) {
                Ok(n) => n,
                Err(error)
                    if matches!(
                        error.kind(),
                        io::ErrorKind::TimedOut | io::ErrorKind::WouldBlock
                    ) =>
                {
                    break;
                }
                Err(_) => {
                    return Err(Error::new(
                        "network_error",
                        "The local OCF connection was interrupted",
                    ));
                }
            };
            if n < 5 {
                continue;
            }
            if (buf[0] >> 4) & 0x03 == 0 {
                self.ack_confirmable(&buf[..n])?;
            }
            self.accept_observe_packet(&buf[..n]);
        }
        Ok(())
    }

    pub fn read_capabilities(&mut self) -> Result<JsonValue, Error> {
        let mut resources = JsonMap::new();
        let mut tree_data = None;
        match self.read_device_tree() {
            Ok(Some(tree)) => {
                tree_data = Some(tree.clone());
                resources.insert("/device/0".into(), sanitize_json(cbor_to_json(&tree)));
                add_tree_representations(&tree, &mut resources);
            }
            Ok(None) => {}
            Err(error) => {
                resources.insert(
                    "/device/0".into(),
                    json!({"readError": error.code, "message": error.message}),
                );
            }
        }
        let candidates = self
            .resource_catalog
            .iter()
            .filter(|link| is_candidate_resource(link))
            .map(|link| link.href.clone())
            .collect::<Vec<_>>();
        for href in candidates {
            match self.get_resource(&href) {
                Ok(value) => {
                    resources.insert(href, cbor_to_json(&value));
                }
                Err(error) if error.code == "timeout" || error.code == "network_error" => {
                    return Err(error)
                }
                Err(error) => {
                    resources.insert(
                        href,
                        json!({"readError": error.code, "message": error.message}),
                    );
                }
            }
        }
        let tree_temp = tree_data
            .as_ref()
            .and_then(|tree| tree_resource(tree, "/temperatures/vs/0"))
            .and_then(|r| get(r, "items"))
            .and_then(as_array)
            .and_then(|v| v.first());
        let tree_temp_caps = tree_temp.map(|item| json!({"available": tree_data.as_ref().is_some_and(|tree| tree_resource(tree, "/temperature/desired/0").is_some()), "minimum": number(item, "minimum"), "maximum": number(item, "maximum"), "step": number(item, "increment")}));
        let tree_fans = tree_data
            .as_ref()
            .and_then(|tree| tree_resource(tree, "/wind/strength/vs/0"))
            .map(|r| text_array(r, "supportedModes"))
            .filter(|v| !v.is_empty());
        let tree_modes = tree_data
            .as_ref()
            .and_then(|tree| tree_resource(tree, "/mode/vs/0"))
            .map(|r| text_array(r, "supportedModes"))
            .filter(|v| !v.is_empty());
        let tree_windfree = tree_data
            .as_ref()
            .and_then(|tree| tree_resource(tree, "/mode/convenient/vs/0"))
            .map(|r| text_array(r, "supportedModes"))
            .filter(|v| !v.is_empty());
        Ok(json!({
            "power": self.find_actuator_href(&["power"]).is_some() || tree_data.as_ref().is_some_and(|tree| tree_resource(tree, "/power/vs/0").is_some()),
            "temperature": self.find_actuator_href(&["temperature", "desired"]).as_deref().map(|href| temperature_capability(&resources, Some(href))).or(tree_temp_caps).unwrap_or(json!({"available": false, "minimum": null, "maximum": null, "step": null})),
            "modes": self.find_actuator_mode_href().as_deref().map(|href| modes_capability(&resources, Some(href))).filter(|v| !v.is_null()).or_else(|| tree_modes.map(|v| json!(v.into_iter().filter(|m| ["Cool", "Dry", "Wind", "Auto", "Heat"].contains(&m.as_str())).collect::<Vec<_>>()))).unwrap_or(JsonValue::Null),
            "fanSpeeds": self.find_actuator_href(&["wind", "strength"]).as_deref().map(|href| fan_capability(&resources, Some(href))).filter(|v| !v.is_null()).or_else(|| tree_fans.map(|v| json!(v.into_iter().filter(|m| ["0", "1", "2", "3", "4"].contains(&m.as_str())).collect::<Vec<_>>()))).unwrap_or(JsonValue::Null),
            "windFree": self.find_actuator_href(&["mode", "convenient"]).as_deref().and_then(|href| windfree_capability(&resources, Some(href))).or_else(|| tree_windfree.map(|v| v.iter().any(|m| m == "Nano" || m == "NanoSleep"))),
            "resourceCatalog": self.resource_catalog.iter().map(|link| json!({"href":link.href,"resourceTypes":link.resource_types,"interfaces":link.interfaces})).collect::<Vec<_>>(),
            "rawResources": resources
        }))
    }

    pub fn set_power(&mut self, enabled: bool) -> Result<Snapshot, Error> {
        let payload = samsung_map(
            "power",
            Value::Text(if enabled { "On" } else { "Off" }.into()),
        );
        if let Some(href) = self.find_actuator_href(&["power"]) {
            self.require_actuator(&href)?;
            self.post(&href, payload)?;
        } else if self.tree_resource_for_write("/power/vs/0")?.is_some() {
            self.post("power/vs/0", payload)?;
        } else {
            return Err(Error::new(
                "unsupported_operation",
                "This air conditioner exposes no power control resource",
            ));
        }
        self.read_state()
    }

    pub fn set_temperature(&mut self, celsius: f64) -> Result<Snapshot, Error> {
        if !celsius.is_finite() {
            return Err(Error::new(
                "invalid_argument",
                "Temperature must be a finite Celsius value",
            ));
        }
        let direct_href = self.find_actuator_href(&["temperature", "desired"]);
        let tree_rep = if direct_href.is_none() {
            self.tree_resource_for_write("/temperature/desired/0")?
        } else {
            None
        };
        if direct_href.is_none() && tree_rep.is_none() {
            return Err(Error::new(
                "unsupported_operation",
                "This air conditioner exposes no target-temperature resource",
            ));
        }
        let (minimum, maximum, step) = if let Some(href) = direct_href.as_deref() {
            self.require_actuator(href)?;
            self.temperature_bounds(href)?
        } else {
            let info = self
                .tree_resource_for_write("/temperatures/vs/0")?
                .and_then(|r| {
                    get(&r, "items")
                        .and_then(as_array)
                        .and_then(|items| items.first().cloned())
                });
            (
                info.as_ref().and_then(|r| number(r, "minimum")),
                info.as_ref().and_then(|r| number(r, "maximum")),
                info.as_ref().and_then(|r| number(r, "increment")),
            )
        };
        if let Some(minimum) = minimum {
            if celsius < minimum {
                return Err(Error::new(
                    "invalid_argument",
                    format!("Temperature is below the appliance's reported minimum ({minimum})"),
                ));
            }
        }
        if let Some(maximum) = maximum {
            if celsius > maximum {
                return Err(Error::new(
                    "invalid_argument",
                    format!("Temperature exceeds the appliance's reported maximum ({maximum})"),
                ));
            }
        }
        if let (Some(minimum), Some(step)) = (minimum, step.filter(|step| *step > 0.0)) {
            let increment = (celsius - minimum) / step;
            if (increment - increment.round()).abs() > 1e-6 {
                return Err(Error::new(
                    "invalid_argument",
                    "Temperature does not match the appliance's reported increment",
                ));
            }
        }
        let encoded = if celsius.fract() == 0.0 {
            Value::Integer((celsius as i64).into())
        } else {
            Value::Float(celsius)
        };
        let payload = Value::Map(vec![(Value::Text("temperature".into()), encoded)]);
        if let Some(href) = direct_href {
            self.post(&href, payload)?;
        } else {
            self.post("temperature/desired/0", payload)?;
        }
        self.read_state()
    }

    pub fn set_value(&mut self, method: &str, value: &str) -> Result<Snapshot, Error> {
        match method {
            "setMode" => {
                let ocf = match value {
                    "cool" => "Cool",
                    "dry" => "Dry",
                    "fan" => "Wind",
                    "auto" => "Auto",
                    "heat" => "Heat",
                    _ => {
                        return Err(Error::new(
                            "unsupported_value",
                            "Unsupported operating mode",
                        ))
                    }
                };
                let href = self.find_actuator_mode_href();
                let payload = samsung_map("modes", Value::Array(vec![Value::Text(ocf.into())]));
                if let Some(href) = href {
                    self.require_actuator(&href)?;
                    self.require_option(&href, ocf)?;
                    self.post(&href, payload)?;
                } else {
                    self.post_tree_supported_value("/mode/vs/0", ocf, payload)?;
                }
            }
            "setFanSpeed" => {
                let ocf = match value {
                    "auto" => "0",
                    "low" => "1",
                    "medium" => "2",
                    "high" => "3",
                    "turbo" => "4",
                    _ => return Err(Error::new("unsupported_value", "Unsupported fan speed")),
                };
                let href = self.find_actuator_href(&["wind", "strength"]);
                let payload = samsung_map("modes", Value::Text(ocf.into()));
                if let Some(href) = href {
                    self.require_actuator(&href)?;
                    self.require_option(&href, ocf)?;
                    self.post(&href, payload)?;
                } else {
                    self.post_tree_supported_value("/wind/strength/vs/0", ocf, payload)?;
                }
            }
            "setWindFree" => {
                let mode = match value {
                    "true" => "Nano",
                    "false" => "Off",
                    _ => {
                        return Err(Error::new(
                            "invalid_argument",
                            "WindFree value must be true or false",
                        ))
                    }
                };
                let href = self.find_actuator_href(&["mode", "convenient"]);
                let payload = samsung_map("modes", Value::Text(mode.into()));
                if let Some(href) = href {
                    self.require_actuator(&href)?;
                    self.require_option(&href, mode)?;
                    self.post(&href, payload)?;
                } else {
                    self.post_tree_supported_value("/mode/convenient/vs/0", mode, payload)?;
                }
            }
            _ => {
                return Err(Error::new(
                    "unsupported_operation",
                    "Unsupported appliance operation",
                ))
            }
        }
        self.read_state()
    }

    fn find_samsung_href(&self, fragments: &[&str]) -> Option<String> {
        self.resource_catalog
            .iter()
            .find(|link| is_samsung_resource(link) && link_matches(link, fragments))
            .map(|link| link.href.clone())
    }

    fn find_resource_href(&self, fragments: &[&str]) -> Option<String> {
        self.resource_catalog
            .iter()
            .find(|link| {
                let matches_all = |value: &str| {
                    let value = value.to_ascii_lowercase();
                    fragments
                        .iter()
                        .all(|fragment| value.contains(&fragment.to_ascii_lowercase()))
                };
                matches_all(&link.href)
                    || link
                        .resource_types
                        .iter()
                        .any(|resource_type| matches_all(resource_type))
            })
            .map(|link| link.href.clone())
    }

    fn read_device_tree(&mut self) -> Result<Option<Value>, Error> {
        if let Some((tree, updated)) = &self.tree_cache {
            if updated.elapsed() < Duration::from_secs(2) {
                return Ok(Some(tree.clone()));
            }
        }
        let has_hass_route = self
            .resource_catalog
            .iter()
            .any(|link| link.href.starts_with("/hass/"));
        if !has_hass_route {
            return Ok(None);
        }
        let tree = self.get("device/0")?;
        for link in parse_resource_catalog(&tree) {
            if !self
                .resource_catalog
                .iter()
                .any(|existing| existing.href == link.href)
            {
                self.resource_catalog.push(link);
            }
        }
        self.tree_cache = Some((tree.clone(), Instant::now()));
        Ok(Some(tree))
    }

    fn tree_resource_for_write(&mut self, href: &str) -> Result<Option<Value>, Error> {
        Ok(self
            .read_device_tree()?
            .and_then(|tree| tree_resource(&tree, href).cloned()))
    }

    fn post_tree_supported_value(
        &mut self,
        href: &str,
        value: &str,
        payload: Value,
    ) -> Result<(), Error> {
        let Some(resource) = self.tree_resource_for_write(href)? else {
            return Err(Error::new(
                "unsupported_operation",
                "The OCF resource directory does not advertise this control",
            ));
        };
        if !text_array(&resource, "supportedModes")
            .iter()
            .any(|supported| supported == value)
        {
            return Err(Error::new(
                "unsupported_value",
                "The device tree does not list this value as supported",
            ));
        }
        self.post(href.trim_start_matches('/'), payload)
    }

    fn find_mode_href(&self) -> Option<String> {
        self.resource_catalog
            .iter()
            .find(|link| {
                let href = link.href.to_lowercase();
                is_samsung_resource(link)
                    && ((href.contains("mode") && !href.contains("convenient"))
                        || link.resource_types.iter().any(|resource_type| {
                            let resource_type = resource_type.to_lowercase();
                            resource_type.contains("mode") && !resource_type.contains("convenient")
                        }))
            })
            .map(|link| link.href.clone())
    }

    fn find_actuator_href(&self, fragments: &[&str]) -> Option<String> {
        find_actuator_resource(&self.resource_catalog, fragments).map(|link| link.href.clone())
    }

    fn find_actuator_mode_href(&self) -> Option<String> {
        self.resource_catalog
            .iter()
            .find(|link| {
                link.interfaces
                    .iter()
                    .any(|interface| interface == "oic.if.a")
                    && is_samsung_resource(link)
                    && ((link.href.to_lowercase().contains("mode")
                        && !link.href.to_lowercase().contains("convenient"))
                        || link.resource_types.iter().any(|resource_type| {
                            resource_type.to_lowercase().contains("mode")
                                && !resource_type.to_lowercase().contains("convenient")
                        }))
            })
            .map(|link| link.href.clone())
    }

    fn require_actuator(&self, href: &str) -> Result<(), Error> {
        if self.resource_catalog.iter().any(|link| {
            link.href == href
                && link
                    .interfaces
                    .iter()
                    .any(|interface| interface == "oic.if.a")
                && is_samsung_resource(link)
        }) {
            Ok(())
        } else {
            Err(Error::new(
                "unsupported_operation",
                "The OCF resource is not advertised as an actuator",
            ))
        }
    }

    fn require_option(&mut self, href: &str, requested: &str) -> Result<(), Error> {
        let resource = self.get(href)?;
        let options = get(&resource, "options")
            .and_then(as_array)
            .ok_or_else(|| {
                Error::new(
                    "unsupported_operation",
                    "The appliance did not advertise a list of supported values for this control",
                )
            })?;
        if options
            .iter()
            .filter_map(as_text)
            .any(|option| option == requested)
        {
            Ok(())
        } else {
            Err(Error::new(
                "unsupported_operation",
                "The appliance did not advertise the requested control value",
            ))
        }
    }

    fn temperature_bounds(
        &mut self,
        href: &str,
    ) -> Result<(Option<f64>, Option<f64>, Option<f64>), Error> {
        let resource = self.get(href)?;
        let value = if let Some(items) = get(&resource, "items")
            .and_then(as_array)
            .and_then(|items| items.first())
        {
            items
        } else {
            &resource
        };
        let minimum = ["min", "minimum", "minValue"]
            .iter()
            .find_map(|key| get(value, key).and_then(as_number));
        let maximum = ["max", "maximum", "maxValue"]
            .iter()
            .find_map(|key| get(value, key).and_then(as_number));
        let step = ["step", "increment"]
            .iter()
            .find_map(|key| get(value, key).and_then(as_number));
        Ok((minimum, maximum, step))
    }
}

fn empty_ack(message_id: u16) -> [u8; 4] {
    [0x60, 0x00, (message_id >> 8) as u8, message_id as u8]
}

fn ensure_identity(dir: &Path) -> Result<(String, String), Error> {
    fs::create_dir_all(dir).map_err(|_| {
        Error::new(
            "identity_storage",
            "Could not create local identity storage",
        )
    })?;
    let cert_path = dir.join("samsung-ocf-client.pem");
    let key_path = dir.join("samsung-ocf-client-key.pem");
    if cert_path.exists() != key_path.exists() {
        return Err(Error::new(
            "identity_incomplete",
            "The saved OCF identity is incomplete; refusing to replace only part of it",
        ));
    }
    if cert_path.exists() && key_path.exists() {
        let cert = fs::read_to_string(&cert_path)
            .map_err(|_| Error::new("identity_storage", "Could not read local OCF certificate"))?;
        let key = fs::read_to_string(&key_path)
            .map_err(|_| Error::new("identity_storage", "Could not read local OCF private key"))?;
        return Ok((cert, key));
    }
    let group = EcGroup::from_curve_name(Nid::X9_62_PRIME256V1).map_err(|_| {
        Error::new(
            "identity_generation",
            "Could not initialize local key generation",
        )
    })?;
    let ec = EcKey::generate(&group)
        .map_err(|_| Error::new("identity_generation", "Could not generate local device key"))?;
    let key = PKey::from_ec_key(ec)
        .map_err(|_| Error::new("identity_generation", "Could not generate local device key"))?;
    let mut name = X509NameBuilder::new()
        .map_err(|_| Error::new("identity_generation", "Could not create local certificate"))?;
    name.append_entry_by_nid(Nid::ORGANIZATIONALUNITNAME, &format!("uuid:{DEVICE_UUID}"))
        .map_err(|_| Error::new("identity_generation", "Could not create local certificate"))?;
    name.append_entry_by_text("CN", "Windfull Local OCF Client")
        .map_err(|_| Error::new("identity_generation", "Could not create local certificate"))?;
    let name = name.build();
    let mut builder = X509::builder()
        .map_err(|_| Error::new("identity_generation", "Could not create local certificate"))?;
    builder
        .set_version(2)
        .map_err(|_| Error::new("identity_generation", "Could not create local certificate"))?;
    builder
        .set_subject_name(&name)
        .map_err(|_| Error::new("identity_generation", "Could not create local certificate"))?;
    builder
        .set_issuer_name(&name)
        .map_err(|_| Error::new("identity_generation", "Could not create local certificate"))?;
    builder
        .set_pubkey(&key)
        .map_err(|_| Error::new("identity_generation", "Could not create local certificate"))?;
    let before = Asn1Time::days_from_now(0)
        .map_err(|_| Error::new("identity_generation", "Could not create local certificate"))?;
    let after = Asn1Time::days_from_now(3650)
        .map_err(|_| Error::new("identity_generation", "Could not create local certificate"))?;
    let serial = BigNum::from_u32(rand::thread_rng().gen())
        .map_err(|_| Error::new("identity_generation", "Could not create local certificate"))?
        .to_asn1_integer()
        .map_err(|_| Error::new("identity_generation", "Could not create local certificate"))?;
    builder
        .set_not_before(&before)
        .map_err(|_| Error::new("identity_generation", "Could not create local certificate"))?;
    builder
        .set_not_after(&after)
        .map_err(|_| Error::new("identity_generation", "Could not create local certificate"))?;
    builder
        .set_serial_number(&serial)
        .map_err(|_| Error::new("identity_generation", "Could not create local certificate"))?;
    builder
        .sign(&key, MessageDigest::sha256())
        .map_err(|_| Error::new("identity_generation", "Could not create local certificate"))?;
    let cert = builder
        .build()
        .to_pem()
        .map_err(|_| Error::new("identity_generation", "Could not create local certificate"))?;
    let private_key = key
        .private_key_to_pem_pkcs8()
        .map_err(|_| Error::new("identity_generation", "Could not create local private key"))?;
    fs::write(&cert_path, &cert)
        .map_err(|_| Error::new("identity_storage", "Could not save local OCF certificate"))?;
    fs::write(&key_path, &private_key)
        .map_err(|_| Error::new("identity_storage", "Could not save local OCF private key"))?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = fs::set_permissions(&key_path, fs::Permissions::from_mode(0o600));
    }
    Ok((
        String::from_utf8_lossy(&cert).into_owned(),
        String::from_utf8_lossy(&private_key).into_owned(),
    ))
}

fn pin_path(pin_dir: &Path, kind: &str, value: &str) -> PathBuf {
    let digest = stable_hash(&format!("{kind}:{value}"));
    let name = digest
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect::<String>();
    pin_dir.join(format!("{name}.sha256"))
}

fn stable_hash(value: &str) -> [u8; 32] {
    openssl::sha::sha256(value.as_bytes())
}

fn check_pin(data_dir: &Path, kind: &str, value: &str, fingerprint: &str) -> Result<(), Error> {
    let path = pin_path(&data_dir.join("ocf-server-pins"), kind, value);
    if path.exists() {
        let pinned = fs::read_to_string(path).map_err(|_| {
            Error::new(
                "pin_storage",
                "Could not read the saved OCF certificate pin",
            )
        })?;
        if pinned.trim() != fingerprint {
            return Err(Error::new(
                "certificate_changed",
                "The OCF appliance certificate changed since it was first trusted",
            ));
        }
    }
    Ok(())
}

fn verify_and_store_pin(
    pin_dir: &Path,
    host: &str,
    device_id: &str,
    fingerprint: &str,
) -> Result<(), Error> {
    let host_path = pin_path(pin_dir, "host", host);
    let id_path = pin_path(pin_dir, "device", device_id);
    let identity_path = host_path.with_extension("device");
    let identity_hash = stable_hash(device_id)
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect::<String>();
    for path in [&host_path, &id_path] {
        if path.exists() {
            let pinned = fs::read_to_string(path).map_err(|_| {
                Error::new(
                    "pin_storage",
                    "Could not read the saved OCF certificate pin",
                )
            })?;
            if pinned.trim() != fingerprint {
                return Err(Error::new(
                    "certificate_changed",
                    "The OCF appliance certificate changed since it was first trusted",
                ));
            }
        }
    }
    if identity_path.exists()
        && fs::read_to_string(&identity_path)
            .map_err(|_| {
                Error::new(
                    "pin_storage",
                    "Could not read the saved OCF device identity",
                )
            })?
            .trim()
            != identity_hash
    {
        return Err(Error::new(
            "device_changed",
            "A different OCF device identity appeared at this host address",
        ));
    }
    fs::create_dir_all(pin_dir).map_err(|_| {
        Error::new(
            "pin_storage",
            "Could not store the OCF appliance certificate pin",
        )
    })?;
    for path in [&host_path, &id_path] {
        if !path.exists() {
            fs::write(path, fingerprint).map_err(|_| {
                Error::new(
                    "pin_storage",
                    "Could not store the OCF appliance certificate pin",
                )
            })?;
        }
    }
    if !identity_path.exists() {
        fs::write(identity_path, identity_hash)
            .map_err(|_| Error::new("pin_storage", "Could not store the OCF device identity"))?;
    }
    Ok(())
}

fn discover_host(host: &str, timeout: Duration) -> Result<(String, Vec<u16>), Error> {
    let direct_timeout = timeout.min(Duration::from_millis(700));
    let read_public = |path: &str| {
        plain_get_on_port(host, path, SAMSUNG_PLAIN_PORT, direct_timeout)
            .or_else(|_| plain_get(host, path, timeout))
    };
    let device = read_public("oic/d")?;
    let id = text(&device, "di").ok_or_else(|| {
        Error::new(
            "unsupported_device",
            "The public OCF device document has no device identifier",
        )
    })?;
    if !is_air_conditioner(&device) {
        return Err(Error::new(
            "unsupported_device",
            "The public OCF device is not identified as an air conditioner",
        ));
    }
    let mut ports = Vec::new();
    if let Ok(directory) = read_public("oic/res?rt=oic.r.doxm") {
        ports.extend(advertised_ports(&directory));
    }
    if let Ok(doxm) = read_public("oic/sec/doxm") {
        ports.extend(secure_ports_from_doxm(&doxm));
    }
    ports.dedup();
    if ports.is_empty() {
        return Err(Error::new(
            "secure_endpoint_missing",
            "The air conditioner did not advertise an OCF secure endpoint",
        ));
    }
    Ok((id, ports))
}

fn plain_get(host: &str, path: &str, timeout: Duration) -> Result<Value, Error> {
    plain_get_on_port(host, path, DISCOVERY_PORT, timeout)
}

fn plain_get_on_port(host: &str, path: &str, port: u16, timeout: Duration) -> Result<Value, Error> {
    let dest = (host, port)
        .to_socket_addrs()
        .map_err(|_| Error::new("invalid_host", "Could not resolve appliance host"))?
        .find(|addr| addr.is_ipv4())
        .ok_or_else(|| Error::new("invalid_host", "An IPv4 appliance address is required"))?;
    let socket = UdpSocket::bind("0.0.0.0:0")
        .map_err(|_| Error::new("network_error", "Could not start OCF discovery"))?;
    socket
        .set_read_timeout(Some(Duration::from_millis(150)))
        .ok();
    let token = rand::thread_rng().gen::<u8>();
    let (path, query) = path
        .split_once('?')
        .map_or((path, None), |(path, query)| (path, Some(query)));
    let request = encode_request_full(rand::thread_rng().gen(), token, 1, path, None, query, None)?;
    socket.send_to(&request, dest).map_err(|_| {
        Error::new(
            "network_error",
            "Could not send local OCF discovery request",
        )
    })?;
    let deadline = Instant::now() + timeout;
    let mut buf = [0_u8; 16 * 1024];
    let mut datagrams = 0_u32;
    let mut target_datagrams = 0_u32;
    while Instant::now() < deadline {
        match socket.recv_from(&mut buf) {
            Ok((n, address)) => {
                datagrams += 1;
                if address.ip() != dest.ip() {
                    continue;
                }
                target_datagrams += 1;
                if !packet_has_token(&buf[..n], token) {
                    continue;
                }
                let (code, body) = decode_response(&buf[..n])?;
                if code >> 5 != 2 {
                    return Err(Error::new(
                        "ocf_rejected",
                        "The appliance refused public OCF discovery",
                    ));
                }
                if let Some(body) = body {
                    return Ok(body);
                }
            }
            Err(error)
                if error.kind() == io::ErrorKind::TimedOut
                    || error.kind() == io::ErrorKind::WouldBlock => {}
            Err(_) => break,
        }
    }
    Err(Error::new(
        "timeout",
        format!("No public OCF response received ({datagrams} datagrams; {target_datagrams} from target IP with unmatched token)"),
    ))
}

fn packet_has_token(packet: &[u8], token: u8) -> bool {
    packet.len() >= 5
        && packet[0] >> 6 == 1
        && packet[0] & 0x0f == 1
        && packet[1] != 0
        && packet[4] == token
}

fn is_air_conditioner(device: &Value) -> bool {
    text_array(device, "rt")
        .iter()
        .any(|resource_type| resource_type.starts_with("oic.d.airconditioner"))
}

fn secure_ports_from_doxm(value: &Value) -> Vec<u16> {
    fn visit(value: &Value, ports: &mut Vec<u16>) {
        match value {
            Value::Map(entries) => {
                let secure = entries.iter().find_map(|(key, value)| {
                    matches!(key, Value::Text(key) if key == "sec").then_some(value)
                });
                let port = entries.iter().find_map(|(key, value)| {
                    matches!(key, Value::Text(key) if key == "port")
                        .then(|| as_i64(value))
                        .flatten()
                });
                if secure.and_then(|value| match value {
                    Value::Bool(v) => Some(*v),
                    _ => None,
                }) == Some(true)
                {
                    if let Some(port) = port.and_then(|port| u16::try_from(port).ok()) {
                        ports.push(port);
                    }
                }
                for (_, child) in entries {
                    visit(child, ports);
                }
            }
            Value::Array(values) => {
                for child in values {
                    visit(child, ports);
                }
            }
            _ => {}
        }
    }
    let mut ports = Vec::new();
    visit(value, &mut ports);
    ports
}

pub fn discover(data_dir: &Path, timeout: Duration) -> Result<Vec<Device>, Error> {
    let (cert, key) = ensure_identity(data_dir)?;
    let socket = UdpSocket::bind("0.0.0.0:0")
        .map_err(|_| Error::new("network_error", "Could not start OCF network discovery"))?;
    socket
        .set_read_timeout(Some(Duration::from_millis(150)))
        .ok();
    let req = encode_request(rand::thread_rng().gen(), 1, 1, "oic/res", None)?;
    // Standard OCF discovery multicast. A separate manual-IP connect path is
    // available for networks that block multicast.
    let _ = socket.send_to(&req, (OCF_MULTICAST, DISCOVERY_PORT));
    if let Some(local) = local_ipv4() {
        let octets = local.octets();
        for suffix in 1..=254 {
            if suffix != octets[3] {
                let _ = socket.send_to(
                    &req,
                    (
                        Ipv4Addr::new(octets[0], octets[1], octets[2], suffix),
                        SAMSUNG_PLAIN_PORT,
                    ),
                );
            }
        }
    }
    let deadline = Instant::now() + timeout;
    let mut buf = [0_u8; 8192];
    let mut hosts = Vec::<String>::new();
    while Instant::now() < deadline {
        match socket.recv_from(&mut buf) {
            Ok((n, addr)) => {
                if !addr.ip().is_ipv4() || !packet_has_token(&buf[..n], 1) {
                    continue;
                }
                let host = addr.ip().to_string();
                if !hosts.contains(&host) {
                    hosts.push(host);
                }
                if let Ok((_, Some(value))) = decode_response(&buf[..n]) {
                    if let Some(ip) = advertised_host(&value) {
                        if !hosts.contains(&ip) {
                            hosts.push(ip);
                        }
                    }
                }
            }
            Err(e)
                if e.kind() == io::ErrorKind::WouldBlock || e.kind() == io::ErrorKind::TimedOut => {
            }
            Err(_) => break,
        }
    }
    let probe_deadline = Instant::now() + timeout.min(Duration::from_secs(30));
    let mut devices = Vec::new();
    for host in hosts {
        if Instant::now() >= probe_deadline {
            break;
        }
        let (expected_device_id, mut ports) = match discover_host(&host, Duration::from_millis(700))
        {
            Ok(discovery) => discovery,
            Err(_) => continue,
        };
        // Only advertised secure ports are tried, in preference order. Fallback
        // ports are available solely after explicit manual-IP discovery.
        ports.sort_by_key(|port| if DTLS_PORTS.contains(port) { 0 } else { 1 });
        ports.dedup();
        for port in ports {
            if Instant::now() >= probe_deadline {
                break;
            }
            if let Ok(mut ac) = Appliance::connect_port(
                &host,
                port,
                &cert,
                &key,
                data_dir,
                Some(expected_device_id.clone()),
            ) {
                if let Ok(device) = ac.read_identity() {
                    ac.device = device.clone();
                    devices.push(device);
                    break;
                }
            }
        }
    }
    Ok(devices)
}

fn local_ipv4() -> Option<Ipv4Addr> {
    let sock = UdpSocket::bind("0.0.0.0:0").ok()?;
    sock.connect((OCF_MULTICAST, DISCOVERY_PORT)).ok()?;
    match sock.local_addr().ok()?.ip() {
        std::net::IpAddr::V4(ip) if !ip.is_loopback() => Some(ip),
        _ => None,
    }
}

fn validate_host(host: &str) -> Result<(), Error> {
    if host.is_empty()
        || host.len() > 253
        || host
            .chars()
            .any(|c| c.is_whitespace() || c == '/' || c == '\\')
    {
        return Err(Error::new("invalid_host", "Appliance host is invalid"));
    }
    Ok(())
}

fn parse_resource_catalog(value: &Value) -> Vec<ResourceLink> {
    get(value, "links")
        .and_then(as_array)
        .into_iter()
        .flatten()
        .filter_map(|link| {
            Some(ResourceLink {
                href: text(link, "href")?,
                resource_types: text_array(link, "rt"),
                interfaces: text_array(link, "if"),
                observable: get(link, "p")
                    .and_then(|properties| get(properties, "bm"))
                    .and_then(as_number)
                    .filter(|bits| bits.is_finite() && *bits >= 0.0)
                    .is_some_and(|bits| (bits as u64 & OCF_OBSERVABLE_BIT) != 0),
            })
        })
        .collect()
}

fn resource_poll_interval(href: &str) -> Duration {
    let href = href.to_ascii_lowercase();
    if href.contains("energy") || href.contains("consumption") {
        Duration::from_secs(10)
    } else if href.contains("humidity") || href.contains("current") || href.contains("ambient") {
        Duration::from_secs(2)
    } else {
        Duration::from_millis(500)
    }
}

fn tree_entries(value: &Value) -> Vec<(String, &Value)> {
    as_array(value)
        .into_iter()
        .flatten()
        .filter_map(|entry| Some((text(entry, "href")?, get(entry, "rep")?)))
        .collect()
}

fn tree_resource<'a>(tree: &'a Value, href: &str) -> Option<&'a Value> {
    tree_entries(tree)
        .into_iter()
        .find(|(path, _)| path == href)
        .map(|(_, rep)| rep)
}

fn add_tree_representations(tree: &Value, output: &mut JsonMap<String, JsonValue>) {
    for (href, representation) in tree_entries(tree) {
        output.insert(href, sanitize_json(cbor_to_json(representation)));
    }
}

fn sensor_item(value: &Value) -> &Value {
    get(value, "items")
        .and_then(as_array)
        .and_then(|items| items.first())
        .unwrap_or(value)
}

fn humidity_value(value: &Value) -> Option<f64> {
    ["humidity", "relativeHumidity", "value"]
        .iter()
        .find_map(|key| number(sensor_item(value), key))
        .filter(|humidity| humidity.is_finite() && (0.0..=100.0).contains(humidity))
}

fn energy_values(value: &Value) -> (Option<f64>, Option<f64>) {
    let item = sensor_item(value);
    let watts = number(item, "instantaneousPower")
        .filter(|value| value.is_finite() && *value >= 0.0)
        .and_then(|value| {
            match text(item, "instantaneousPowerUnit")?
                .to_ascii_lowercase()
                .as_str()
            {
                "w" | "watt" | "watts" => Some(value),
                "kw" | "kilowatt" | "kilowatts" => Some(value * 1_000.0),
                _ => None,
            }
        });
    let watt_hours = number(item, "cumulativePower")
        .filter(|value| value.is_finite() && *value >= 0.0)
        .and_then(
            |value| match text(item, "cumulativeUnit")?.to_ascii_lowercase().as_str() {
                "wh" | "watt-hour" | "watt-hours" => Some(value),
                "kwh" | "kilowatt-hour" | "kilowatt-hours" => Some(value * 1_000.0),
                _ => None,
            },
        );
    (watts, watt_hours)
}

fn read_snapshot_from_tree(tree: &Value, snapshot: &mut Snapshot) {
    if let Some(rep) = tree_resource(tree, "/power/vs/0") {
        snapshot.power = text(rep, "power").and_then(|v| match v.as_str() {
            "On" => Some(true),
            "Off" => Some(false),
            _ => None,
        });
    }
    if let Some(rep) = tree_resource(tree, "/temperatures/vs/0") {
        if let Some(item) = get(rep, "items").and_then(as_array).and_then(|v| v.first()) {
            snapshot.temperature = number(item, "desired");
            snapshot.ambient_temperature = number(item, "current");
        }
    }
    snapshot.temperature = snapshot.temperature.or_else(|| {
        tree_resource(tree, "/temperature/desired/0").and_then(|v| number(v, "temperature"))
    });
    snapshot.ambient_temperature = snapshot.ambient_temperature.or_else(|| {
        tree_resource(tree, "/temperature/current/0").and_then(|v| number(v, "temperature"))
    });
    snapshot.humidity = snapshot.humidity.or_else(|| {
        tree_resource(tree, "/humidity/vs/0")
            .or_else(|| tree_resource(tree, "/humidity/0"))
            .and_then(humidity_value)
    });
    if snapshot.instantaneous_power_w.is_none() || snapshot.cumulative_energy_wh.is_none() {
        if let Some(value) = tree_resource(tree, "/energy/consumption/vs/0") {
            let (watts, watt_hours) = energy_values(value);
            snapshot.instantaneous_power_w = snapshot.instantaneous_power_w.or(watts);
            snapshot.cumulative_energy_wh = snapshot.cumulative_energy_wh.or(watt_hours);
        }
    }
    if let Some(rep) = tree_resource(tree, "/mode/vs/0") {
        snapshot.mode = get(rep, "modes")
            .and_then(as_array)
            .and_then(|v| v.first())
            .and_then(as_text)
            .or_else(|| as_text(get(rep, "modes")?));
    }
    snapshot.fan_speed = tree_resource(tree, "/wind/strength/vs/0").and_then(|v| text(v, "modes"));
    snapshot.wind_free = tree_resource(tree, "/mode/convenient/vs/0")
        .and_then(|v| text(v, "modes"))
        .and_then(|v| match v.as_str() {
            "Nano" | "NanoSleep" => Some(true),
            "Off" => Some(false),
            _ => None,
        });
}

fn sanitize_json(value: JsonValue) -> JsonValue {
    const PRIVATE_RESOURCE: &str = "/wirelessinfo/vs/0";
    match value {
        JsonValue::Array(values) => {
            JsonValue::Array(values.into_iter().map(sanitize_json).collect())
        }
        JsonValue::Object(values) => {
            let mut safe = JsonMap::new();
            for (key, value) in values {
                let lower = key.to_ascii_lowercase();
                if [
                    "serial",
                    "ssid",
                    "mac",
                    "otnduid",
                    "deviceid",
                    "credential",
                    "privatekey",
                ]
                .iter()
                .any(|needle| lower.contains(needle))
                {
                    continue;
                }
                if lower == "href" && value.as_str() == Some(PRIVATE_RESOURCE) {
                    safe.insert(key, json!("[redacted]"));
                } else {
                    safe.insert(key, sanitize_json(value));
                }
            }
            JsonValue::Object(safe)
        }
        other => other,
    }
}

fn unwrap_single_map_envelope(value: Value) -> Value {
    match value {
        Value::Array(mut entries)
            if entries.len() == 1 && matches!(entries.first(), Some(Value::Map(_))) =>
        {
            entries.remove(0)
        }
        other => other,
    }
}

fn is_candidate_resource(link: &ResourceLink) -> bool {
    let href = link.href.to_lowercase();
    let types = link
        .resource_types
        .iter()
        .map(|s| s.to_lowercase())
        .collect::<Vec<_>>();
    [
        "power",
        "temperature",
        "mode",
        "wind",
        "convenient",
        "autoclean",
        "energy",
        "filter",
        "humidity",
        "hass",
    ]
    .iter()
    .any(|name| {
        href.contains(name)
            || types
                .iter()
                .any(|resource_type| resource_type.contains(name))
    })
}

fn is_samsung_resource(link: &ResourceLink) -> bool {
    link.resource_types
        .iter()
        .any(|resource_type| resource_type.starts_with(SAMSUNG_PREFIX))
}

fn find_actuator_resource<'a>(
    catalog: &'a [ResourceLink],
    fragments: &[&str],
) -> Option<&'a ResourceLink> {
    catalog.iter().find(|link| {
        link.interfaces
            .iter()
            .any(|interface| interface == "oic.if.a")
            && is_samsung_resource(link)
            && link_matches(link, fragments)
    })
}

fn link_matches(link: &ResourceLink, fragments: &[&str]) -> bool {
    let href = link.href.to_lowercase();
    fragments
        .iter()
        .all(|fragment| href.contains(&fragment.to_lowercase()))
        || link.resource_types.iter().any(|resource_type| {
            let resource_type = resource_type.to_lowercase();
            resource_type.starts_with(SAMSUNG_PREFIX)
                && fragments
                    .iter()
                    .all(|fragment| resource_type.contains(&fragment.to_lowercase()))
        })
}

fn field<'a>(value: &'a JsonValue, key: &str) -> Option<&'a JsonValue> {
    value
        .get(key)
        .or_else(|| value.get(format!("{SAMSUNG_PREFIX}{key}")))
}

fn option_strings(value: &JsonValue) -> Option<Vec<String>> {
    field(value, "options")?.as_array().map(|values| {
        values
            .iter()
            .filter_map(JsonValue::as_str)
            .map(str::to_string)
            .collect()
    })
}

fn modes_capability(resources: &JsonMap<String, JsonValue>, href: Option<&str>) -> JsonValue {
    href.and_then(|href| resources.get(href))
        .and_then(option_strings)
        .map(|values| {
            values
                .into_iter()
                .filter(|value| ["Cool", "Dry", "Wind", "Auto", "Heat"].contains(&value.as_str()))
                .collect::<Vec<_>>()
        })
        .filter(|values| !values.is_empty())
        .map(|values| json!(values))
        .unwrap_or(JsonValue::Null)
}

fn fan_capability(resources: &JsonMap<String, JsonValue>, href: Option<&str>) -> JsonValue {
    href.and_then(|href| resources.get(href))
        .and_then(option_strings)
        .map(|values| {
            values
                .into_iter()
                .filter(|value| ["0", "1", "2", "3", "4"].contains(&value.as_str()))
                .collect::<Vec<_>>()
        })
        .filter(|values| !values.is_empty())
        .map(|values| json!(values))
        .unwrap_or(JsonValue::Null)
}

fn windfree_capability(resources: &JsonMap<String, JsonValue>, href: Option<&str>) -> Option<bool> {
    let resource = resources.get(href?)?;
    let options = option_strings(resource)?;
    Some(
        options
            .iter()
            .any(|value| value == "Nano" || value == "NanoSleep"),
    )
}

fn temperature_capability(resources: &JsonMap<String, JsonValue>, href: Option<&str>) -> JsonValue {
    let Some(resource) = href.and_then(|href| resources.get(href)) else {
        return json!({"available": false, "minimum": null, "maximum": null, "step": null});
    };
    let values = resource
        .get("items")
        .and_then(JsonValue::as_array)
        .and_then(|items| items.first())
        .unwrap_or(resource);
    let find_number = |keys: &[&str]| {
        keys.iter()
            .find_map(|key| field(values, key).and_then(JsonValue::as_f64))
    };
    json!({"available": true, "minimum": find_number(&["min", "minimum", "minValue"]), "maximum": find_number(&["max", "maximum", "maxValue"]), "step": find_number(&["step", "increment"])})
}

fn advertised_host(value: &Value) -> Option<String> {
    let links = get(value, "links").and_then(as_array)?;
    links
        .iter()
        .filter_map(|link| get(link, "eps").and_then(as_array))
        .flatten()
        .filter_map(as_text)
        .find_map(|endpoint| {
            endpoint
                .strip_prefix("coaps://")
                .and_then(|s| s.split(':').next())
                .map(str::to_string)
        })
}

fn advertised_ports(value: &Value) -> Vec<u16> {
    let mut ports = Vec::new();
    if let Some(links) = get(value, "links").and_then(as_array) {
        for link in links {
            if let Some(endpoints) = get(link, "eps").and_then(as_array) {
                for endpoint in endpoints.iter().filter_map(as_text) {
                    if let Some(port) = endpoint
                        .strip_prefix("coaps://")
                        .and_then(|s| s.rsplit_once(':').map(|(_, p)| p.trim_end_matches('/')))
                        .and_then(|p| p.parse::<u16>().ok())
                    {
                        ports.push(port);
                    }
                }
            }
            if text(link, "href").as_deref() == Some("/oic/sec/doxm") {
                if let Some(port) = get(link, "p")
                    .and_then(|p| get(p, "port"))
                    .and_then(as_i64)
                    .and_then(|p| u16::try_from(p).ok())
                {
                    ports.push(port);
                }
            }
        }
    }
    ports
}

fn samsung_map(key: &str, value: Value) -> Value {
    Value::Map(vec![(Value::Text(format!("{SAMSUNG_PREFIX}{key}")), value)])
}

fn text(value: &Value, key: &str) -> Option<String> {
    get(value, key).and_then(as_text)
}
fn number(value: &Value, key: &str) -> Option<f64> {
    get(value, key).and_then(as_number)
}
fn get<'a>(value: &'a Value, key: &str) -> Option<&'a Value> {
    let entries = match value {
        Value::Map(entries) => entries,
        _ => return None,
    };
    entries.iter().find_map(|(k, v)| match k {
        Value::Text(name) if name == key || name == &format!("{SAMSUNG_PREFIX}{key}") => Some(v),
        _ => None,
    })
}
fn as_text(value: &Value) -> Option<String> {
    match value {
        Value::Text(s) => Some(s.clone()),
        _ => None,
    }
}
fn as_number(value: &Value) -> Option<f64> {
    match value {
        Value::Integer(i) => i128::try_from(*i).ok().map(|i| i as f64),
        Value::Float(n) => Some(*n),
        Value::Text(s) => s.parse().ok(),
        _ => None,
    }
}
fn as_i64(value: &Value) -> Option<i64> {
    as_number(value).map(|n| n as i64)
}
fn as_array(value: &Value) -> Option<&Vec<Value>> {
    match value {
        Value::Array(a) => Some(a),
        _ => None,
    }
}
fn text_array(value: &Value, key: &str) -> Vec<String> {
    get(value, key)
        .and_then(as_array)
        .map(|a| a.iter().filter_map(as_text).collect())
        .unwrap_or_default()
}

fn cbor_to_json(value: &Value) -> JsonValue {
    match value {
        Value::Null => JsonValue::Null,
        Value::Bool(v) => json!(v),
        Value::Integer(v) => i128::try_from(*v)
            .ok()
            .map(|i| json!(i))
            .unwrap_or(JsonValue::Null),
        Value::Float(v) => json!(v),
        Value::Text(v) => json!(v),
        Value::Bytes(v) => json!(v),
        Value::Array(values) => JsonValue::Array(values.iter().map(cbor_to_json).collect()),
        Value::Map(entries) => {
            let mut map = JsonMap::new();
            for (key, value) in entries {
                if let Value::Text(key) = key {
                    map.insert(key.clone(), cbor_to_json(value));
                }
            }
            JsonValue::Object(map)
        }
        _ => JsonValue::Null,
    }
}

fn encode_request(
    mid: u16,
    token: u8,
    method: u8,
    path: &str,
    payload: Option<&Value>,
) -> Result<Vec<u8>, Error> {
    encode_request_full(mid, token, method, path, payload, None, None)
}

fn encode_request_full(
    mid: u16,
    token: u8,
    method: u8,
    path: &str,
    payload: Option<&Value>,
    query: Option<&str>,
    block2: Option<(u32, u8)>,
) -> Result<Vec<u8>, Error> {
    encode_request_full_with_observe(mid, token, method, path, payload, query, block2, None)
}

fn encode_request_with_observe(
    mid: u16,
    token: u8,
    method: u8,
    path: &str,
    payload: Option<&Value>,
    observe: Option<u32>,
) -> Result<Vec<u8>, Error> {
    encode_request_full_with_observe(mid, token, method, path, payload, None, None, observe)
}

fn encode_request_full_with_observe(
    mid: u16,
    token: u8,
    method: u8,
    path: &str,
    payload: Option<&Value>,
    query: Option<&str>,
    block2: Option<(u32, u8)>,
    observe: Option<u32>,
) -> Result<Vec<u8>, Error> {
    let mut message = vec![0x41, method, (mid >> 8) as u8, mid as u8, token];
    let mut last_option = 0_u16;
    if let Some(value) = observe {
        let bytes = value.to_be_bytes();
        let first_nonzero = bytes.iter().position(|byte| *byte != 0);
        let encoded = first_nonzero.map_or(&[][..], |index| &bytes[index..]);
        encode_option(&mut message, &mut last_option, COAP_OBSERVE, encoded)?;
    }
    for segment in path.trim_matches('/').split('/') {
        let value = segment.as_bytes();
        encode_option(&mut message, &mut last_option, 11, value)?;
    }
    if payload.is_some() {
        encode_option(&mut message, &mut last_option, 12, &[60])?;
    }
    if let Some(query) = query {
        encode_option(&mut message, &mut last_option, 15, query.as_bytes())?;
    }
    // OCF resources use application/cbor for GET responses as well as writes.
    encode_option(&mut message, &mut last_option, 17, &[60])?;
    if let Some((number, size_exponent)) = block2 {
        let value = (number << 4) | (size_exponent as u32 & 0x07);
        let bytes = value.to_be_bytes();
        let first_nonzero = bytes.iter().position(|byte| *byte != 0);
        let encoded = first_nonzero.map_or(&[][..], |index| &bytes[index..]);
        encode_option(&mut message, &mut last_option, 23, encoded)?;
    }
    if let Some(payload) = payload {
        message.push(0xff);
        ciborium::ser::into_writer(payload, &mut message)
            .map_err(|_| Error::new("encoding_error", "Could not encode OCF CBOR payload"))?;
    }
    Ok(message)
}

fn encode_option(
    out: &mut Vec<u8>,
    last: &mut u16,
    number: u16,
    value: &[u8],
) -> Result<(), Error> {
    if number < *last {
        return Err(Error::new(
            "encoding_error",
            "CoAP options are out of order",
        ));
    }
    let delta = number - *last;
    let (delta_nibble, delta_ext) = option_nibble(delta as usize)?;
    let (length_nibble, length_ext) = option_nibble(value.len())?;
    out.push((delta_nibble << 4) | length_nibble);
    out.extend(delta_ext);
    out.extend(length_ext);
    out.extend(value);
    *last = number;
    Ok(())
}

fn option_nibble(value: usize) -> Result<(u8, Vec<u8>), Error> {
    match value {
        0..=12 => Ok((value as u8, vec![])),
        13..=268 => Ok((13, vec![(value - 13) as u8])),
        269..=65804 => Ok((14, ((value - 269) as u16).to_be_bytes().to_vec())),
        _ => Err(Error::new("encoding_error", "CoAP option is too large")),
    }
}

fn decode_response(data: &[u8]) -> Result<(u8, Option<Value>), Error> {
    let response = decode_packet(data)?;
    let value = response
        .payload
        .map(|payload| {
            ciborium::de::from_reader(payload.as_slice())
                .map(unwrap_single_map_envelope)
                .map_err(|_| Error::new("invalid_response", "OCF payload was not valid CBOR"))
        })
        .transpose()?;
    Ok((response.code, value))
}

fn decode_packet(data: &[u8]) -> Result<CoapResponse, Error> {
    if data.len() < 4 || data[0] >> 6 != 1 {
        return Err(Error::new("invalid_response", "Malformed CoAP response"));
    }
    let tkl = (data[0] & 0x0f) as usize;
    if tkl > 8 || data.len() < 4 + tkl {
        return Err(Error::new("invalid_response", "Malformed CoAP token"));
    }
    let code = data[1];
    let token = data.get(4).copied().unwrap_or_default();
    let mut cursor = 4 + tkl;
    let mut option_number = 0_u16;
    let mut block2 = None;
    let mut observe = None;
    while cursor < data.len() {
        if data[cursor] == 0xff {
            cursor += 1;
            if cursor == data.len() {
                return Err(Error::new("invalid_response", "Empty CoAP payload"));
            }
            return Ok(CoapResponse {
                code,
                payload: Some(data[cursor..].to_vec()),
                block2,
                observe,
                token,
            });
        }
        let header = data[cursor];
        cursor += 1;
        let (delta, after_delta) = decode_nibble((header >> 4) as usize, data, cursor)?;
        cursor = after_delta;
        let (length, after_length) = decode_nibble((header & 0x0f) as usize, data, cursor)?;
        cursor = after_length;
        option_number = option_number
            .checked_add(delta as u16)
            .ok_or_else(|| Error::new("invalid_response", "Invalid CoAP option"))?;
        if cursor + length > data.len() {
            return Err(Error::new("invalid_response", "Truncated CoAP option"));
        }
        if option_number == 23 {
            let mut value = 0_u32;
            for byte in &data[cursor..cursor + length] {
                value = (value << 8) | *byte as u32;
            }
            block2 = Some((value >> 4, (value & 0x08) != 0, (value & 0x07) as u8));
        } else if option_number == COAP_OBSERVE {
            if length > 3 {
                return Err(Error::new("invalid_response", "Invalid CoAP Observe value"));
            }
            let mut value = 0_u32;
            for byte in &data[cursor..cursor + length] {
                value = (value << 8) | *byte as u32;
            }
            observe = Some(value & 0x00ff_ffff);
        }
        cursor += length;
    }
    Ok(CoapResponse {
        code,
        payload: None,
        block2,
        observe,
        token,
    })
}

fn decode_nibble(nibble: usize, data: &[u8], cursor: usize) -> Result<(usize, usize), Error> {
    match nibble {
        0..=12 => Ok((nibble, cursor)),
        13 if cursor < data.len() => Ok((13 + data[cursor] as usize, cursor + 1)),
        14 if cursor + 1 < data.len() => Ok((
            269 + u16::from_be_bytes([data[cursor], data[cursor + 1]]) as usize,
            cursor + 2,
        )),
        _ => Err(Error::new(
            "invalid_response",
            "Invalid CoAP option encoding",
        )),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn request_encodes_uri_segments_and_cbor_content_format_and_accept() {
        let payload = samsung_map("power", Value::Text("On".into()));
        let bytes = encode_request(0x1234, 0x34, 2, "power/vs/0", Some(&payload)).unwrap();
        assert_eq!(&bytes[..5], &[0x41, 2, 0x12, 0x34, 0x34]);
        assert_eq!(
            &bytes[5..13],
            &[0xb5, b'p', b'o', b'w', b'e', b'r', 0x02, b'v']
        );
        assert_eq!(
            &bytes[13..],
            &[
                b's', 0x01, b'0', 0x11, 60, 0x51, 60, 0xff, 0xa1, 0x76, b'x', b'.', b'c', b'o',
                b'm', b'.', b's', b'a', b'm', b's', b'u', b'n', b'g', b'.', b'd', b'a', b'.', b'p',
                b'o', b'w', b'e', b'r', 0x62, b'O', b'n',
            ]
        );
    }

    #[test]
    fn empty_ack_uses_the_confirmable_response_message_id() {
        assert_eq!(empty_ack(0x1234), [0x60, 0x00, 0x12, 0x34]);
    }

    #[test]
    fn decodes_success_cbor_and_rejects_malformed_packets() {
        let packet = [0x61, 0x45, 0x00, 0x01, 0x01, 0xff, 0xa1, 0x61, b'x', 0x01];
        let (code, body) = decode_response(&packet).unwrap();
        assert_eq!(code, 0x45);
        assert_eq!(as_i64(get(&body.unwrap(), "x").unwrap()), Some(1));
        assert!(decode_response(&[0x40]).is_err());
    }

    #[test]
    fn cbor_helpers_accept_prefixed_and_standard_keys() {
        let data = Value::Map(vec![
            (
                Value::Text("x.com.samsung.da.power".into()),
                Value::Text("On".into()),
            ),
            (Value::Text("temperature".into()), Value::Float(23.5)),
        ]);
        assert_eq!(text(&data, "power").as_deref(), Some("On"));
        assert_eq!(number(&data, "temperature"), Some(23.5));
    }

    #[test]
    fn doxm_secure_endpoint_requires_secure_flag_and_keeps_advertised_port() {
        let doxm = Value::Map(vec![(
            Value::Text("doxms".into()),
            Value::Array(vec![Value::Map(vec![(
                Value::Text("p".into()),
                Value::Map(vec![
                    (Value::Text("sec".into()), Value::Bool(true)),
                    (Value::Text("port".into()), Value::Integer(49154.into())),
                ]),
            )])]),
        )]);
        assert_eq!(secure_ports_from_doxm(&doxm), vec![49154]);
    }

    #[test]
    fn single_map_ocf_envelope_preserves_advertised_secure_port() {
        let envelope = Value::Array(vec![Value::Map(vec![(
            Value::Text("links".into()),
            Value::Array(vec![Value::Map(vec![
                (
                    Value::Text("href".into()),
                    Value::Text("/oic/sec/doxm".into()),
                ),
                (
                    Value::Text("p".into()),
                    Value::Map(vec![
                        (Value::Text("sec".into()), Value::Bool(true)),
                        (Value::Text("port".into()), Value::Integer(49154.into())),
                    ]),
                ),
            ])]),
        )])]);
        let normalized = unwrap_single_map_envelope(envelope);
        assert_eq!(advertised_ports(&normalized), vec![49154]);
    }

    #[test]
    fn public_discovery_filters_air_conditioner_before_dtls() {
        let tv = Value::Map(vec![(
            Value::Text("rt".into()),
            Value::Array(vec![Value::Text("oic.d.tv".into())]),
        )]);
        let ac = Value::Map(vec![(
            Value::Text("rt".into()),
            Value::Array(vec![
                Value::Text("oic.wk.d".into()),
                Value::Text("oic.d.airconditioner".into()),
            ]),
        )]);
        assert!(!is_air_conditioner(&tv));
        assert!(is_air_conditioner(&ac));
    }

    #[test]
    fn discovery_packet_requires_a_valid_matching_coap_token() {
        let response = [0x41, 0x45, 0x12, 0x34, 0x9a];
        assert!(packet_has_token(&response, 0x9a));
        assert!(!packet_has_token(&response, 0x9b));
        assert!(!packet_has_token(&[0x40, 0x45, 0, 1], 0));
        assert!(!packet_has_token(&[0x42, 0x45, 0, 1, 0], 0));
    }

    #[test]
    fn actuator_capabilities_only_include_values_the_appliance_advertises() {
        let mut resources = JsonMap::new();
        resources.insert(
            "/mode/vs/0".into(),
            json!({"options": ["Cool", "Dry", "Wind", "Light_On"]}),
        );
        resources.insert(
            "/wind/strength/vs/0".into(),
            json!({"options": ["0", "1", "2", "3"]}),
        );
        assert_eq!(
            modes_capability(&resources, Some("/mode/vs/0")),
            json!(["Cool", "Dry", "Wind"])
        );
        assert_eq!(
            fan_capability(&resources, Some("/wind/strength/vs/0")),
            json!(["0", "1", "2", "3"])
        );
        assert_eq!(modes_capability(&JsonMap::new(), None), JsonValue::Null);
    }

    #[test]
    fn classic_windfree_routes_require_advertised_actuator_links() {
        let link = |href: &str, resource_type: &str, interface: &str| {
            Value::Map(vec![
                (Value::Text("href".into()), Value::Text(href.into())),
                (
                    Value::Text("rt".into()),
                    Value::Array(vec![Value::Text(resource_type.into())]),
                ),
                (
                    Value::Text("if".into()),
                    Value::Array(vec![Value::Text(interface.into())]),
                ),
            ])
        };
        let catalog = parse_resource_catalog(&Value::Map(vec![(
            Value::Text("links".into()),
            Value::Array(vec![
                link("/power/vs/0", "x.com.samsung.da.power", "oic.if.a"),
                link(
                    "/temperature/desired/read",
                    "x.com.samsung.da.temperature",
                    "oic.if.r",
                ),
                link(
                    "/temperature/desired/0",
                    "x.com.samsung.da.temperature",
                    "oic.if.a",
                ),
                link("/mode/vs/0", "x.com.samsung.da.mode", "oic.if.a"),
                link(
                    "/wind/strength/vs/0",
                    "x.com.samsung.da.wind.strength",
                    "oic.if.a",
                ),
                link(
                    "/mode/convenient/vs/0",
                    "x.com.samsung.da.mode.convenient",
                    "oic.if.a",
                ),
                link(
                    "/wind/direction/vs/0",
                    "x.com.samsung.da.wind.direction",
                    "oic.if.a",
                ),
                link(
                    "/option/autoclean/vs/0",
                    "x.com.samsung.da.option.autoclean",
                    "oic.if.a",
                ),
                link(
                    "/energy/consumption/vs/0",
                    "x.com.samsung.da.energy.consumption",
                    "oic.if.rw",
                ),
            ]),
        )]));

        for (fragments, expected) in [
            (vec!["power"], "/power/vs/0"),
            (vec!["temperature", "desired"], "/temperature/desired/0"),
            (vec!["wind", "strength"], "/wind/strength/vs/0"),
            (vec!["mode", "convenient"], "/mode/convenient/vs/0"),
        ] {
            assert_eq!(
                find_actuator_resource(&catalog, &fragments).map(|link| link.href.as_str()),
                Some(expected)
            );
        }
        for expected in [
            "/wind/direction/vs/0",
            "/option/autoclean/vs/0",
            "/energy/consumption/vs/0",
        ] {
            assert!(catalog
                .iter()
                .find(|link| link.href == expected)
                .is_some_and(is_candidate_resource));
        }
    }

    #[test]
    fn directory_catalog_preserves_unrecognized_resource_types_and_interfaces() {
        let resource = Value::Map(vec![(
            Value::Text("links".into()),
            Value::Array(vec![Value::Map(vec![
                (
                    Value::Text("href".into()),
                    Value::Text("/custom/feature/0".into()),
                ),
                (
                    Value::Text("rt".into()),
                    Value::Array(vec![Value::Text("x.vendor.custom".into())]),
                ),
                (
                    Value::Text("if".into()),
                    Value::Array(vec![Value::Text("oic.if.a".into())]),
                ),
            ])]),
        )]);
        let catalog = parse_resource_catalog(&resource);
        assert_eq!(catalog.len(), 1);
        assert_eq!(catalog[0].href, "/custom/feature/0");
        assert_eq!(catalog[0].resource_types, vec!["x.vendor.custom"]);
        assert_eq!(catalog[0].interfaces, vec!["oic.if.a"]);
    }

    #[test]
    fn device_tree_entries_supply_state_and_capability_data() {
        let tree = Value::Array(vec![
            Value::Map(vec![
                (
                    Value::Text("href".into()),
                    Value::Text("/power/vs/0".into()),
                ),
                (
                    Value::Text("rep".into()),
                    Value::Map(vec![(
                        Value::Text(format!("{SAMSUNG_PREFIX}power")),
                        Value::Text("On".into()),
                    )]),
                ),
            ]),
            Value::Map(vec![
                (
                    Value::Text("href".into()),
                    Value::Text("/temperatures/vs/0".into()),
                ),
                (
                    Value::Text("rep".into()),
                    Value::Map(vec![(
                        Value::Text(format!("{SAMSUNG_PREFIX}items")),
                        Value::Array(vec![Value::Map(vec![
                            (Value::Text("desired".into()), Value::Integer(24.into())),
                            (Value::Text("current".into()), Value::Integer(27.into())),
                            (Value::Text("minimum".into()), Value::Integer(16.into())),
                            (Value::Text("maximum".into()), Value::Integer(30.into())),
                            (Value::Text("increment".into()), Value::Integer(1.into())),
                        ])]),
                    )]),
                ),
            ]),
            Value::Map(vec![
                (
                    Value::Text("href".into()),
                    Value::Text("/wind/strength/vs/0".into()),
                ),
                (
                    Value::Text("rep".into()),
                    Value::Map(vec![(
                        Value::Text(format!("{SAMSUNG_PREFIX}supportedModes")),
                        Value::Array(
                            ["0", "1", "2", "3", "4"]
                                .iter()
                                .map(|value| Value::Text((*value).into()))
                                .collect(),
                        ),
                    )]),
                ),
            ]),
        ]);
        let mut snapshot = Snapshot::default();
        read_snapshot_from_tree(&tree, &mut snapshot);
        assert_eq!(snapshot.power, Some(true));
        assert_eq!(snapshot.temperature, Some(24.0));
        assert_eq!(snapshot.ambient_temperature, Some(27.0));
        assert_eq!(
            text_array(
                tree_resource(&tree, "/wind/strength/vs/0").unwrap(),
                "supportedModes"
            ),
            ["0", "1", "2", "3", "4"]
        );
        let resources = parse_resource_catalog(&tree);
        assert!(
            resources.is_empty(),
            "the compact tree has no advertised resource metadata"
        );
    }

    #[test]
    fn raw_tree_redaction_removes_private_identifiers() {
        let value = json!({"href":"/wirelessinfo/vs/0", "rep":{"serialNumber":"secret", "ssid":"private", "macAddress":"private", "modelNum":"model-A", "power":"On"}});
        let safe = sanitize_json(value);
        let encoded = safe.to_string();
        assert!(!encoded.contains("secret"));
        assert!(!encoded.contains("private"));
        assert!(encoded.contains("model-A"));
        assert!(encoded.contains("On"));
    }

    #[test]
    fn block2_response_option_is_decoded_without_consuming_payload() {
        // Confirmable response, Block2 option 23 = block 1, more=true, SZX=0.
        let response = [0x60, 0x45, 0x00, 0x01, 0xd1, 0x0a, 0x18, 0xff, 0xa0];
        let parsed = decode_packet(&response).unwrap();
        assert_eq!(parsed.block2, Some((1, true, 0)));
        assert_eq!(parsed.payload, Some(vec![0xa0]));
    }

    #[test]
    fn server_fingerprint_and_device_identity_pins_reject_silent_changes() {
        let nonce = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let data_dir = std::env::temp_dir().join(format!("windfull-pin-test-{nonce}"));
        let pin_dir = data_dir.join("ocf-server-pins");
        verify_and_store_pin(&pin_dir, "192.0.2.4", "device-a", "fingerprint-a").unwrap();
        assert!(check_pin(&data_dir, "host", "192.0.2.4", "fingerprint-b").is_err());
        assert!(verify_and_store_pin(&pin_dir, "192.0.2.4", "device-a", "fingerprint-b").is_err());
        assert!(verify_and_store_pin(&pin_dir, "192.0.2.4", "device-b", "fingerprint-a").is_err());
        std::fs::remove_dir_all(data_dir).unwrap();
    }
}
