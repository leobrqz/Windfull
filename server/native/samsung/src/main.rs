#![cfg_attr(all(windows, not(test)), windows_subsystem = "windows")]

mod ocf;

use ocf::Appliance;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::io::{self, BufRead, Write};
use std::path::PathBuf;
use std::time::Duration;

#[derive(Deserialize)]
struct Request {
    id: Value,
    method: String,
    #[serde(default)]
    params: Value,
}

#[derive(Serialize)]
struct Response<'a> {
    id: &'a Value,
    ok: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    data: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    error: Option<ErrorBody>,
}

#[derive(Serialize)]
struct ErrorBody {
    code: &'static str,
    message: String,
}

fn main() {
    let data_dir = parse_data_dir().unwrap_or_else(|| {
        eprintln!("--data-dir is required");
        std::process::exit(2);
    });
    let stdin = io::stdin();
    let mut stdout = io::BufWriter::new(io::stdout().lock());
    let mut appliance: Option<Appliance> = None;

    for line in stdin.lock().lines() {
        let line = match line {
            Ok(line) => line,
            Err(_) => break,
        };
        let request: Request = match serde_json::from_str(&line) {
            Ok(request) => request,
            Err(_) => {
                let _ = writeln!(
                    stdout,
                    "{}",
                    json!({"id":null,"ok":false,"error":{"code":"invalid_request","message":"Malformed request"}})
                );
                let _ = stdout.flush();
                continue;
            }
        };
        let outcome = dispatch(&request, &data_dir, &mut appliance);
        let response = match outcome {
            Ok(data) => Response {
                id: &request.id,
                ok: true,
                data: Some(data),
                error: None,
            },
            Err(error) => Response {
                id: &request.id,
                ok: false,
                data: None,
                error: Some(error),
            },
        };
        if serde_json::to_writer(&mut stdout, &response).is_err()
            || writeln!(stdout).is_err()
            || stdout.flush().is_err()
        {
            break;
        }
        if request.method == "shutdown" {
            break;
        }
    }
    appliance.take();
}

fn parse_data_dir() -> Option<PathBuf> {
    let mut args = std::env::args_os().skip(1);
    while let Some(arg) = args.next() {
        if arg == "--data-dir" {
            return args.next().map(PathBuf::from);
        }
    }
    None
}

fn dispatch(
    request: &Request,
    data_dir: &PathBuf,
    appliance: &mut Option<Appliance>,
) -> Result<Value, ErrorBody> {
    let invalid = || ErrorBody {
        code: "invalid_argument",
        message: "Required argument is missing or invalid".into(),
    };
    match request.method.as_str() {
        "discover" => {
            let timeout = request
                .params
                .get("timeoutMs")
                .and_then(Value::as_u64)
                .unwrap_or(8000)
                .clamp(500, 30000);
            let devices = ocf::discover(data_dir, Duration::from_millis(timeout))
                .map_err(|e| protocol_error(e))?;
            serde_json::to_value(devices).map_err(|_| internal_error())
        }
        "connect" => {
            let host = request
                .params
                .get("host")
                .and_then(Value::as_str)
                .ok_or_else(invalid)?;
            let port = request
                .params
                .get("port")
                .and_then(Value::as_u64)
                .map(|p| p as u16);
            let connected = Appliance::connect(host, port, data_dir).map_err(protocol_error)?;
            let device = connected.device().clone();
            *appliance = Some(connected);
            serde_json::to_value(device).map_err(|_| internal_error())
        }
        "state" => {
            let state = appliance
                .as_mut()
                .ok_or_else(not_connected)?
                .read_state()
                .map_err(protocol_error)?;
            serde_json::to_value(state).map_err(|_| internal_error())
        }
        "liveState" => {
            let state = appliance
                .as_mut()
                .ok_or_else(not_connected)?
                .read_state_fast()
                .map_err(protocol_error)?;
            serde_json::to_value(state).map_err(|_| internal_error())
        }
        "capabilities" => {
            let value = appliance
                .as_mut()
                .ok_or_else(not_connected)?
                .read_capabilities()
                .map_err(protocol_error)?;
            Ok(value)
        }
        "setPower" => {
            let enabled = request
                .params
                .get("enabled")
                .and_then(Value::as_bool)
                .ok_or_else(invalid)?;
            let state = appliance
                .as_mut()
                .ok_or_else(not_connected)?
                .set_power(enabled)
                .map_err(protocol_error)?;
            serde_json::to_value(state).map_err(|_| internal_error())
        }
        "setTemperature" => {
            let celsius = request
                .params
                .get("celsius")
                .and_then(Value::as_f64)
                .ok_or_else(invalid)?;
            let state = appliance
                .as_mut()
                .ok_or_else(not_connected)?
                .set_temperature(celsius)
                .map_err(protocol_error)?;
            serde_json::to_value(state).map_err(|_| internal_error())
        }
        "setMode" | "setFanSpeed" | "setWindFree" => {
            let value = request
                .params
                .get("value")
                .and_then(Value::as_str)
                .ok_or_else(invalid)?;
            let state = appliance
                .as_mut()
                .ok_or_else(not_connected)?
                .set_value(&request.method, value)
                .map_err(protocol_error)?;
            serde_json::to_value(state).map_err(|_| internal_error())
        }
        "disconnect" => {
            *appliance = None;
            Ok(json!({"disconnected": true}))
        }
        "shutdown" => {
            *appliance = None;
            Ok(json!({"stopped": true}))
        }
        _ => Err(ErrorBody {
            code: "unknown_method",
            message: "Unsupported bridge method".into(),
        }),
    }
}

fn protocol_error(error: ocf::Error) -> ErrorBody {
    ErrorBody {
        code: error.code,
        message: error.message,
    }
}

fn not_connected() -> ErrorBody {
    ErrorBody {
        code: "not_connected",
        message: "No appliance is connected".into(),
    }
}

fn internal_error() -> ErrorBody {
    ErrorBody {
        code: "serialization_error",
        message: "Could not encode bridge response".into(),
    }
}
