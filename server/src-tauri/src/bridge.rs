use serde_json::{json, Value};
use std::{path::PathBuf, process::Stdio, sync::Arc, time::Duration};
use tokio::{
    io::{AsyncBufReadExt, AsyncWriteExt, BufReader},
    process::{Child, ChildStderr, ChildStdin, Command},
    sync::Mutex,
    task::JoinHandle,
    time::timeout,
};

pub struct SamsungBridge {
    executable: PathBuf,
    data_dir: PathBuf,
    child: Option<Child>,
    stdin: Option<ChildStdin>,
    stdout: Option<BufReader<tokio::process::ChildStdout>>,
    stderr_task: Option<JoinHandle<()>>,
    request_id: u64,
}

impl SamsungBridge {
    pub fn new(executable: PathBuf, data_dir: PathBuf) -> Self {
        Self {
            executable,
            data_dir,
            child: None,
            stdin: None,
            stdout: None,
            stderr_task: None,
            request_id: 0,
        }
    }

    async fn start(&mut self) -> Result<(), String> {
        if self.child.is_some() {
            return Ok(());
        }
        let mut child = Command::new(&self.executable)
            .arg("--data-dir")
            .arg(&self.data_dir)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .kill_on_drop(true)
            .spawn()
            .map_err(|e| format!("Não foi possível iniciar a ponte Samsung local: {e}"))?;
        self.stdin = child.stdin.take();
        self.stdout = child.stdout.take().map(BufReader::new);
        self.stderr_task = child.stderr.take().map(log_bridge_stderr);
        self.child = Some(child);
        tracing::info!("Samsung OCF bridge started");
        Ok(())
    }

    pub async fn call(&mut self, method: &str, params: Value) -> Result<Value, String> {
        let result = self.call_inner(method, params).await;
        if let Err(error) = &result {
            tracing::error!(target: "samsung_bridge", method, %error, "Samsung OCF request failed");
        }
        result
    }

    async fn call_inner(&mut self, method: &str, params: Value) -> Result<Value, String> {
        self.start().await?;
        self.request_id += 1;
        let id = self.request_id;
        let request = json!({"id": id, "method": method, "params": params});
        let input = serde_json::to_vec(&request).map_err(|e| e.to_string())?;
        let stdin = self
            .stdin
            .as_mut()
            .ok_or("A entrada da ponte Samsung foi fechada.")?;
        stdin
            .write_all(&input)
            .await
            .map_err(|e| format!("Falha ao enviar comando à ponte Samsung: {e}"))?;
        stdin
            .write_all(b"\n")
            .await
            .map_err(|e| format!("Falha ao enviar comando à ponte Samsung: {e}"))?;
        let stdout = self
            .stdout
            .as_mut()
            .ok_or("A saída da ponte Samsung foi fechada.")?;
        let mut line = String::new();
        timeout(Duration::from_secs(70), stdout.read_line(&mut line))
            .await
            .map_err(|_| "A ponte Samsung excedeu o tempo limite.".to_string())?
            .map_err(|e| format!("Falha ao ler resposta da ponte Samsung: {e}"))?;
        let response: Value = serde_json::from_str(&line)
            .map_err(|_| "A resposta da ponte Samsung não é JSON válido.".to_string())?;
        if response.get("id").and_then(Value::as_u64) != Some(id) {
            return Err("A resposta da ponte Samsung não corresponde ao comando enviado.".into());
        }
        if response.get("ok").and_then(Value::as_bool) != Some(true) {
            let error = response.get("error").cloned().unwrap_or_default();
            return Err(error
                .get("message")
                .and_then(Value::as_str)
                .unwrap_or("A operação OCF falhou.")
                .to_string());
        }
        Ok(response.get("data").cloned().unwrap_or(Value::Null))
    }

    pub async fn shutdown(&mut self) {
        if self.child.is_some() {
            let _ = self.call("shutdown", Value::Null).await;
        }
        if let Some(child) = self.child.as_mut() {
            let _ = timeout(Duration::from_secs(2), child.wait()).await;
        }
        self.child = None;
        self.stdin = None;
        self.stdout = None;
        if let Some(task) = self.stderr_task.take() {
            task.abort();
        }
    }
}

fn log_bridge_stderr(stderr: ChildStderr) -> JoinHandle<()> {
    tokio::spawn(async move {
        let mut lines = BufReader::new(stderr).lines();
        loop {
            match lines.next_line().await {
                Ok(Some(line)) => {
                    if let Some((level, message)) = line.split_once(": ") {
                        match level {
                            "DEBUG" => {
                                tracing::debug!(target: "samsung_bridge", %message, "Samsung OCF bridge")
                            }
                            "INFO" => {
                                tracing::info!(target: "samsung_bridge", %message, "Samsung OCF bridge")
                            }
                            "WARN" => {
                                tracing::warn!(target: "samsung_bridge", %message, "Samsung OCF bridge")
                            }
                            "ERROR" => {
                                tracing::error!(target: "samsung_bridge", %message, "Samsung OCF bridge")
                            }
                            _ => {
                                tracing::warn!(target: "samsung_bridge", message = %line, "Samsung OCF bridge stderr")
                            }
                        }
                    } else {
                        tracing::warn!(target: "samsung_bridge", message = %line, "Samsung OCF bridge stderr");
                    }
                }
                Ok(None) => break,
                Err(error) => {
                    tracing::error!(target: "samsung_bridge", %error, "Could not read Samsung OCF bridge stderr");
                    break;
                }
            }
        }
    })
}

pub type SharedBridge = Arc<Mutex<SamsungBridge>>;
