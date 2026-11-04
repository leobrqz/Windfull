use aes_gcm::{
    aead::{Aead, KeyInit},
    Aes128Gcm, Nonce,
};
use rand::{rngs::OsRng, RngCore};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::{
    fs,
    path::{Path, PathBuf},
};

pub struct Storage {
    pub support_dir: PathBuf,
    pub data_dir: PathBuf,
}

#[derive(Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ServerIdentity {
    pub server_id: String,
    pub certificate_pem: String,
    pub private_key_pem: String,
    pub fingerprint: String,
}

impl Storage {
    pub fn open() -> Result<Self, String> {
        let roaming = std::env::var_os("APPDATA")
            .map(PathBuf::from)
            .ok_or_else(|| {
                "Não foi possível localizar a pasta AppData\\Roaming do usuário.".to_string()
            })?;
        // Flutter's Windows path_provider uses %APPDATA%/<CompanyName>/<ProductName>.
        // Runner.rc used these exact version-resource values.
        let support_dir = roaming.join("io.github.leobrqz").join("WindFull Server");
        let data_dir = support_dir.join("Windfull");
        fs::create_dir_all(&data_dir)
            .map_err(|e| format!("Não foi possível abrir o armazenamento WindFull: {e}"))?;
        Ok(Self {
            support_dir,
            data_dir,
        })
    }

    pub fn read_json(&self, name: &str) -> Result<Option<serde_json::Value>, String> {
        let path = self.data_dir.join(name);
        if !path.exists() {
            return Ok(None);
        }
        let bytes = fs::read(&path).map_err(|e| format!("Falha ao ler {}: {e}", path.display()))?;
        serde_json::from_slice(&bytes)
            .map(Some)
            .map_err(|e| format!("JSON inválido em {}: {e}", path.display()))
    }

    pub fn write_json(&self, name: &str, value: &impl Serialize) -> Result<(), String> {
        atomic_write(
            &self.data_dir.join(name),
            &serde_json::to_vec_pretty(value).map_err(|e| e.to_string())?,
        )
    }

    pub fn load_identity(&self) -> Result<ServerIdentity, String> {
        let legacy = self.read_legacy_secret("windfull.server_identity.v1")?;
        if let Some(secret) = legacy {
            let parsed: serde_json::Value = serde_json::from_str(&secret).map_err(|_| {
                "A identidade TLS antiga está corrompida; ela não será substituída.".to_string()
            })?;
            let server_id = parsed
                .get("serverId")
                .and_then(|v| v.as_str())
                .ok_or("A identidade TLS antiga não contém serverId.")?
                .to_string();
            let certificate_pem = parsed
                .get("certificatePem")
                .and_then(|v| v.as_str())
                .ok_or("A identidade TLS antiga não contém certificatePem.")?
                .to_string();
            let private_key_pem = parsed
                .get("privateKeyPem")
                .and_then(|v| v.as_str())
                .ok_or("A identidade TLS antiga não contém privateKeyPem.")?
                .to_string();
            let identity = validate_identity(ServerIdentity {
                server_id,
                certificate_pem,
                private_key_pem,
                fingerprint: String::new(),
            })?;
            return Ok(identity);
        }
        // Fresh installs get a new identity once; subsequent launches load the persisted identity.
        if legacy_secret_file(&self.support_dir, "windfull.server_identity.v1").exists() {
            return Err("A identidade TLS antiga existe, mas não pôde ser descriptografada; não foi criada uma identidade nova.".into());
        }
        let identity = generate_identity()?;
        let payload = serde_json::json!({"serverId":identity.server_id,"certificatePem":identity.certificate_pem,"privateKeyPem":identity.private_key_pem});
        self.write_legacy_secret("windfull.server_identity.v1", &payload.to_string())?;
        Ok(identity)
    }

    pub fn read_legacy_secret(&self, key: &str) -> Result<Option<String>, String> {
        let path = legacy_secret_file(&self.support_dir, key);
        if !path.exists() {
            return Ok(None);
        }
        let data = fs::read(&path)
            .map_err(|e| format!("Não foi possível ler a identidade protegida antiga: {e}"))?;
        let aes_key = legacy_key().ok_or_else(|| "A chave da identidade antiga não está disponível no Gerenciador de Credenciais do Windows.".to_string())?;
        if data.len() < 28 {
            return Err("O arquivo de identidade protegida antigo está truncado.".into());
        }
        let cipher = Aes128Gcm::new_from_slice(&aes_key)
            .map_err(|_| "Chave AES antiga inválida.".to_string())?;
        let mut combined = Vec::with_capacity(data.len() - 12);
        combined.extend_from_slice(&data[..12]);
        combined.extend_from_slice(&data[28..]);
        combined.extend_from_slice(&data[12..28]);
        let plain = cipher
            .decrypt(Nonce::from_slice(&data[..12]), combined.as_ref())
            .map_err(|_| {
                "Não foi possível validar/descriptografar a identidade antiga.".to_string()
            })?;
        let clean = plain.strip_suffix(&[0]).unwrap_or(&plain);
        String::from_utf8(clean.to_vec())
            .map(Some)
            .map_err(|_| "A identidade antiga não contém texto UTF-8 válido.".into())
    }

    pub fn write_legacy_secret(&self, key: &str, value: &str) -> Result<(), String> {
        let aes_key = ensure_legacy_key().ok_or_else(|| {
            "Não foi possível criar a chave protegida no Gerenciador de Credenciais do Windows."
                .to_string()
        })?;
        let cipher =
            Aes128Gcm::new_from_slice(&aes_key).map_err(|_| "Chave AES inválida.".to_string())?;
        let mut nonce = [0u8; 12];
        rand::thread_rng().fill_bytes(&mut nonce);
        let mut plain = value.as_bytes().to_vec();
        plain.push(0);
        let encrypted = cipher
            .encrypt(Nonce::from_slice(&nonce), plain.as_ref())
            .map_err(|_| "Não foi possível criptografar a identidade TLS.".to_string())?;
        if encrypted.len() < 16 {
            return Err("A identidade criptografada está inválida.".into());
        }
        let split = encrypted.len() - 16;
        let mut bytes = Vec::with_capacity(12 + encrypted.len());
        bytes.extend_from_slice(&nonce);
        bytes.extend_from_slice(&encrypted[split..]);
        bytes.extend_from_slice(&encrypted[..split]);
        atomic_write(&legacy_secret_file(&self.support_dir, key), &bytes)
    }
}

fn legacy_secret_file(support: &Path, key: &str) -> PathBuf {
    support.join(format!(
        "windfull_server_VGhpcyBpcyB0aGUgcHJlZml4IGZv_{key}.secure"
    ))
}

#[cfg(windows)]
fn legacy_key() -> Option<Vec<u8>> {
    use std::ptr;
    use windows_sys::Win32::Security::Credentials::{
        CredFree, CredReadW, CREDENTIALW, CRED_TYPE_GENERIC,
    };
    let target: Vec<u16> = "key_windfull_server_VGhpcyBpcyB0aGUgcHJlZml4IGZv_"
        .encode_utf16()
        .chain([0])
        .collect();
    let mut credential: *mut CREDENTIALW = ptr::null_mut();
    unsafe {
        if CredReadW(target.as_ptr(), CRED_TYPE_GENERIC, 0, &mut credential) == 0
            || credential.is_null()
        {
            return None;
        }
        let value = &*credential;
        let result = if value.CredentialBlobSize == 16 && !value.CredentialBlob.is_null() {
            Some(std::slice::from_raw_parts(value.CredentialBlob, 16).to_vec())
        } else {
            None
        };
        CredFree(credential as _);
        result
    }
}

#[cfg(windows)]
fn ensure_legacy_key() -> Option<Vec<u8>> {
    use windows_sys::Win32::Security::Credentials::{
        CredWriteW, CREDENTIALW, CRED_PERSIST_LOCAL_MACHINE, CRED_TYPE_GENERIC,
    };
    let target: Vec<u16> = "key_windfull_server_VGhpcyBpcyB0aGUgcHJlZml4IGZv_"
        .encode_utf16()
        .chain([0])
        .collect();
    if let Some(existing) = legacy_key() {
        return Some(existing);
    }
    let mut key = [0u8; 16];
    rand::thread_rng().fill_bytes(&mut key);
    let credential = CREDENTIALW {
        Flags: 0,
        Type: CRED_TYPE_GENERIC,
        TargetName: target.as_ptr() as _,
        Comment: std::ptr::null_mut(),
        LastWritten: unsafe { std::mem::zeroed() },
        CredentialBlobSize: 16,
        CredentialBlob: key.as_mut_ptr(),
        Persist: CRED_PERSIST_LOCAL_MACHINE,
        AttributeCount: 0,
        Attributes: std::ptr::null_mut(),
        TargetAlias: std::ptr::null_mut(),
        UserName: std::ptr::null_mut(),
    };
    let saved = unsafe { CredWriteW(&credential, 0) } != 0;
    if saved {
        Some(key.to_vec())
    } else {
        None
    }
}

#[cfg(not(windows))]
fn legacy_key() -> Option<Vec<u8>> {
    None
}
#[cfg(not(windows))]
fn ensure_legacy_key() -> Option<Vec<u8>> {
    None
}

fn generate_identity() -> Result<ServerIdentity, String> {
    let certified = rcgen::generate_simple_self_signed(vec!["WindFull".into()])
        .map_err(|e| format!("Não foi possível criar identidade TLS: {e}"))?;
    let mut id = [0u8; 16];
    OsRng.fill_bytes(&mut id);
    let server_id = hex::encode(id);
    let cert_der = certified.cert.der().as_ref();
    Ok(ServerIdentity {
        server_id,
        certificate_pem: certified.cert.pem(),
        private_key_pem: certified.key_pair.serialize_pem(),
        fingerprint: hex::encode(Sha256::digest(cert_der)),
    })
}

fn validate_identity(mut identity: ServerIdentity) -> Result<ServerIdentity, String> {
    if identity.server_id.len() != 32
        || !identity
            .server_id
            .bytes()
            .all(|b| b.is_ascii_hexdigit() && !b.is_ascii_uppercase())
    {
        return Err(
            "serverId da identidade TLS inválido; a identidade não será substituída.".into(),
        );
    }
    let pem = identity
        .certificate_pem
        .split("-----BEGIN CERTIFICATE-----")
        .nth(1)
        .and_then(|v| v.split("-----END CERTIFICATE-----").next())
        .ok_or("Certificado TLS persistido inválido; identidade não substituída.")?;
    let der = base64::Engine::decode(
        &base64::engine::general_purpose::STANDARD,
        pem.split_whitespace().collect::<String>(),
    )
    .map_err(|_| "Certificado TLS persistido inválido; identidade não substituída.")?;
    identity.fingerprint = hex::encode(Sha256::digest(der));
    Ok(identity)
}

fn atomic_write(path: &Path, bytes: &[u8]) -> Result<(), String> {
    let temp = path.with_extension("tmp");
    fs::write(&temp, bytes).map_err(|e| format!("Falha ao gravar {}: {e}", temp.display()))?;
    #[cfg(windows)]
    {
        use std::os::windows::ffi::OsStrExt;
        use windows_sys::Win32::Storage::FileSystem::{
            MoveFileExW, MOVEFILE_REPLACE_EXISTING, MOVEFILE_WRITE_THROUGH,
        };
        let from: Vec<u16> = temp.as_os_str().encode_wide().chain([0]).collect();
        let to: Vec<u16> = path.as_os_str().encode_wide().chain([0]).collect();
        let ok = unsafe {
            MoveFileExW(
                from.as_ptr(),
                to.as_ptr(),
                MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH,
            )
        };
        if ok == 0 {
            return Err(format!(
                "Falha ao substituir {} atomicamente: {}",
                path.display(),
                std::io::Error::last_os_error()
            ));
        }
        Ok(())
    }
    #[cfg(not(windows))]
    {
        fs::rename(&temp, path).map_err(|e| format!("Falha ao finalizar {}: {e}", path.display()))
    }
}
