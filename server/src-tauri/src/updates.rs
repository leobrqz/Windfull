//! Approved Velopack updates for the managed Windows portable package.
//!
//! These Tauri commands deliberately expose separate check, download, and apply
//! steps. Calling `apply_update` is the user's explicit approval to restart.

use std::{
    fs::{self, OpenOptions},
    io::Write,
    path::{Path, PathBuf},
    sync::{mpsc, Mutex},
    thread,
};

use serde::Serialize;
use tauri::{AppHandle, Emitter, State};
use velopack::{sources::GithubSource, UpdateCheck, UpdateInfo, UpdateManager, UpdateOptions};

const PACKAGE_ID: &str = "io.github.leobrqz.windfull.windows";
const CHANNEL: &str = "win-x64";
const REPOSITORY: &str = "https://github.com/leobrqz/Windfull";
const RELEASE_PAGE: &str = "https://github.com/leobrqz/Windfull/releases/latest";
const RESERVED_FREE_SPACE: u64 = 96 * 1024 * 1024;

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct UpdateContext {
    current_version: String,
    managed: bool,
    package_id: String,
    channel: String,
}

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct UpdateCandidate {
    version: String,
    notes: String,
    package_id: String,
    channel: String,
    release_url: String,
}

#[derive(Clone, Serialize)]
struct UpdateProgress {
    percent: i16,
}

/// Tauri-managed update state. A missing Velopack installation is a supported
/// state for users who have not yet migrated to the managed portable ZIP.
pub struct UpdateService {
    manager: Option<UpdateManager>,
    install_root: Option<PathBuf>,
    managed: bool,
    current_version: String,
    candidate: Mutex<Option<UpdateInfo>>,
    downloaded: Mutex<bool>,
    busy: Mutex<bool>,
}

impl UpdateService {
    pub fn new() -> Self {
        let current_version = env!("CARGO_PKG_VERSION").to_owned();
        let options = UpdateOptions {
            AllowVersionDowngrade: false,
            ExplicitChannel: Some(CHANNEL.to_owned()),
            MaximumDeltasBeforeFallback: -1,
        };
        let manager = UpdateManager::new(
            GithubSource::new(REPOSITORY, None, false),
            Some(options),
            None,
        )
        .ok();

        let (install_root, managed, current_version) = match manager.as_ref() {
            Some(manager) => {
                let executable_dir = std::env::current_exe()
                    .ok()
                    .and_then(|path| path.parent().map(Path::to_path_buf));
                let root = executable_dir
                    .as_ref()
                    .and_then(|current| current.parent().map(Path::to_path_buf));
                let channel = executable_dir
                    .as_deref()
                    .map(read_channel)
                    .unwrap_or_default();
                let valid = manager.get_is_portable()
                    && manager.get_app_id() == PACKAGE_ID
                    && channel == CHANNEL
                    && root.is_some();
                let version = manager.get_current_version_as_string();
                (
                    root.filter(|_| valid),
                    valid,
                    if version.is_empty() {
                        current_version
                    } else {
                        version
                    },
                )
            }
            None => (None, false, current_version),
        };

        Self {
            manager,
            install_root,
            managed,
            current_version,
            candidate: Mutex::new(None),
            downloaded: Mutex::new(false),
            busy: Mutex::new(false),
        }
    }

    fn begin_operation(&self) -> Result<(), String> {
        let mut busy = self
            .busy
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        if *busy {
            return Err("invalid_state".to_owned());
        }
        *busy = true;
        Ok(())
    }

    fn end_operation(&self) {
        *self
            .busy
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner()) = false;
    }
}

impl Default for UpdateService {
    fn default() -> Self {
        Self::new()
    }
}

#[tauri::command]
pub fn get_update_context(service: State<'_, UpdateService>) -> UpdateContext {
    UpdateContext {
        current_version: service.current_version.clone(),
        managed: service.managed,
        package_id: PACKAGE_ID.to_owned(),
        channel: CHANNEL.to_owned(),
    }
}

#[tauri::command]
pub async fn check_for_updates(
    service: State<'_, UpdateService>,
) -> Result<Option<UpdateCandidate>, String> {
    if !service.managed {
        return Err("not_managed".to_owned());
    }
    service.begin_operation()?;
    *service
        .candidate
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner()) = None;
    *service
        .downloaded
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner()) = false;
    let Some(manager) = service.manager.as_ref().cloned() else {
        service.end_operation();
        return Err("not_managed".to_owned());
    };
    let checked =
        match tauri::async_runtime::spawn_blocking(move || manager.check_for_updates()).await {
            Ok(result) => result.map_err(classify_error),
            Err(_) => Err("update_failed".to_owned()),
        };
    service.end_operation();

    match checked? {
        UpdateCheck::NoUpdateAvailable | UpdateCheck::RemoteIsEmpty => {
            *service
                .candidate
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner()) = None;
            *service
                .downloaded
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner()) = false;
            Ok(None)
        }
        UpdateCheck::UpdateAvailable(info) => {
            validate_update(&info)?;
            let asset = &info.TargetFullRelease;
            let candidate = UpdateCandidate {
                version: asset.Version.clone(),
                notes: asset.NotesMarkdown.clone(),
                package_id: asset.PackageId.clone(),
                channel: CHANNEL.to_owned(),
                release_url: format!("{REPOSITORY}/releases/tag/v{}", asset.Version),
            };
            *service
                .candidate
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner()) = Some(*info);
            *service
                .downloaded
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner()) = false;
            Ok(Some(candidate))
        }
    }
}

#[tauri::command]
pub async fn download_update(
    app: AppHandle,
    service: State<'_, UpdateService>,
) -> Result<(), String> {
    if !service.managed {
        return Err("not_managed".to_owned());
    }
    service.begin_operation()?;
    let result = download_update_inner(app, &service).await;
    service.end_operation();
    result
}

async fn download_update_inner(app: AppHandle, service: &UpdateService) -> Result<(), String> {
    let manager = service
        .manager
        .as_ref()
        .ok_or_else(|| "not_managed".to_owned())?
        .clone();
    let update = service
        .candidate
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
        .clone()
        .ok_or_else(|| "invalid_state".to_owned())?;
    let root = service
        .install_root
        .clone()
        .ok_or_else(|| "not_managed".to_owned())?;
    check_writable_and_space(&root, update.TargetFullRelease.Size)?;

    let (progress_tx, progress_rx) = mpsc::channel::<i16>();
    let progress_app = app.clone();
    let reporter = thread::spawn(move || {
        while let Ok(percent) = progress_rx.recv() {
            let _ = progress_app.emit(
                "update-progress",
                UpdateProgress {
                    percent: percent.clamp(0, 100),
                },
            );
        }
    });
    let download = tauri::async_runtime::spawn_blocking(move || {
        manager.download_updates(&update, Some(progress_tx))
    })
    .await
    .map_err(|_| "update_failed".to_owned())?
    .map_err(classify_error);
    let _ = reporter.join();
    download?;
    *service
        .downloaded
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner()) = true;
    Ok(())
}

#[tauri::command]
pub fn apply_update(app: AppHandle, service: State<'_, UpdateService>) -> Result<(), String> {
    if !service.managed {
        return Err("not_managed".to_owned());
    }
    service.begin_operation()?;
    let apply = (|| {
        if !*service
            .downloaded
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
        {
            return Err("invalid_state".to_owned());
        }
        let manager = service
            .manager
            .as_ref()
            .ok_or_else(|| "not_managed".to_owned())?;
        let update = service
            .candidate
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .clone()
            .ok_or_else(|| "invalid_state".to_owned())?;
        manager
            .wait_exit_then_apply_updates(&update, false, true, std::iter::empty::<String>())
            .map_err(classify_error)
    })();
    service.end_operation();
    apply?;
    // Velopack has started its helper and is waiting for this process to exit.
    app.exit(0);
    Ok(())
}

#[tauri::command]
pub fn open_release_page() -> Result<(), String> {
    std::process::Command::new("explorer.exe")
        .arg(RELEASE_PAGE)
        .spawn()
        .map(|_| ())
        .map_err(|_| "open_failed".to_owned())
}

fn validate_update(info: &UpdateInfo) -> Result<(), String> {
    let asset = &info.TargetFullRelease;
    if info.IsDowngrade
        || asset.PackageId != PACKAGE_ID
        || asset.Type != "Full"
        || !valid_semver(&asset.Version)
        || asset.FileName
            != format!(
                "{PACKAGE_ID}-{version}-{CHANNEL}-full.nupkg",
                version = asset.Version
            )
        || !valid_hash(&asset.SHA256)
        || asset.Size == 0
        || asset.NotesMarkdown.len() > 65_536
    {
        return Err("invalid_metadata".to_owned());
    }
    Ok(())
}

fn valid_semver(version: &str) -> bool {
    let parts: Vec<_> = version.split('.').collect();
    parts.len() == 3
        && parts.iter().all(|part| {
            !part.is_empty()
                && part.bytes().all(|byte| byte.is_ascii_digit())
                && (part == &"0" || !part.starts_with('0'))
        })
}

fn valid_hash(hash: &str) -> bool {
    hash.len() == 64 && hash.bytes().all(|byte| byte.is_ascii_hexdigit())
}

fn read_channel(current_dir: &Path) -> String {
    let Ok(manifest) = fs::read_to_string(current_dir.join("sq.version")) else {
        return String::new();
    };
    let Some((_, rest)) = manifest.split_once("<channel>") else {
        return String::new();
    };
    rest.split_once("</channel>")
        .map(|(channel, _)| channel.to_owned())
        .unwrap_or_default()
}

fn check_writable_and_space(root: &Path, package_size: u64) -> Result<(), String> {
    let current = std::env::current_exe()
        .map_err(|_| "folder_access".to_owned())?
        .parent()
        .map(Path::to_path_buf)
        .ok_or_else(|| "folder_access".to_owned())?;
    let packages = root.join("packages");
    fs::create_dir_all(&packages).map_err(|_| "folder_access".to_owned())?;

    let installed_size = directory_size_without_links(&current)?;
    let required_space = package_size
        .checked_mul(2)
        .and_then(|size| size.checked_add(installed_size))
        .and_then(|size| size.checked_add(RESERVED_FREE_SPACE))
        .ok_or_else(|| "insufficient_space".to_owned())?;
    let available = available_space(root)?;
    if available < required_space {
        return Err("insufficient_space".to_owned());
    }

    let probe = packages.join(format!(".windfull-write-{}", std::process::id()));
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&probe)
        .map_err(|_| "folder_access".to_owned())?;
    let write_result = file.write_all(b"WindFull update permission check");
    drop(file);
    if write_result.is_err() {
        let _ = fs::remove_file(&probe);
        return Err("folder_access".to_owned());
    }
    fs::remove_file(probe).map_err(|_| "folder_access".to_owned())?;
    Ok(())
}

fn directory_size_without_links(directory: &Path) -> Result<u64, String> {
    let mut total = 0u64;
    for entry in fs::read_dir(directory).map_err(|_| "folder_access".to_owned())? {
        let entry = entry.map_err(|_| "folder_access".to_owned())?;
        let metadata =
            fs::symlink_metadata(entry.path()).map_err(|_| "folder_access".to_owned())?;
        if metadata.file_type().is_symlink() {
            return Err("folder_access".to_owned());
        }
        if metadata.is_dir() {
            total = total
                .checked_add(directory_size_without_links(&entry.path())?)
                .ok_or_else(|| "insufficient_space".to_owned())?;
        } else if metadata.is_file() {
            total = total
                .checked_add(metadata.len())
                .ok_or_else(|| "insufficient_space".to_owned())?;
        }
    }
    Ok(total)
}

fn available_space(root: &Path) -> Result<u64, String> {
    #[cfg(windows)]
    {
        use std::{iter, os::windows::ffi::OsStrExt};
        use windows_sys::Win32::Storage::FileSystem::GetDiskFreeSpaceExW;

        let wide: Vec<u16> = root
            .as_os_str()
            .encode_wide()
            .chain(iter::once(0))
            .collect();
        let mut available = 0u64;
        // SAFETY: the path is NUL terminated and all output pointers are valid.
        let result = unsafe {
            GetDiskFreeSpaceExW(
                wide.as_ptr(),
                &mut available,
                std::ptr::null_mut(),
                std::ptr::null_mut(),
            )
        };
        if result == 0 {
            Err("folder_access".to_owned())
        } else {
            Ok(available)
        }
    }
    #[cfg(not(windows))]
    {
        let _ = root;
        Err("not_managed".to_owned())
    }
}

fn classify_error(error: impl std::fmt::Debug) -> String {
    let message = format!("{error:?}").to_ascii_lowercase();
    if message.contains("timeout") || message.contains("timed out") {
        "timeout".to_owned()
    } else if message.contains("checksum")
        || message.contains("sha256")
        || message.contains("integrity")
    {
        "integrity".to_owned()
    } else if message.contains("space") {
        "insufficient_space".to_owned()
    } else if message.contains("permission") || message.contains("access denied") {
        "folder_access".to_owned()
    } else if message.contains("network") || message.contains("connect") || message.contains("http")
    {
        "offline".to_owned()
    } else {
        "update_failed".to_owned()
    }
}
