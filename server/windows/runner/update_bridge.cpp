#include "update_bridge.h"

#include <Velopack.hpp>
#include <flutter/event_channel.h>
#include <flutter/event_stream_handler_functions.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <shellapi.h>

#include <algorithm>
#include <cctype>
#include <condition_variable>
#include <cstdint>
#include <deque>
#include <filesystem>
#include <fstream>
#include <functional>
#include <limits>
#include <memory>
#include <mutex>
#include <optional>
#include <regex>
#include <stdexcept>
#include <string>
#include <string_view>
#include <thread>
#include <vector>

namespace {
using Value = flutter::EncodableValue;
using Map = flutter::EncodableMap;
constexpr UINT kUpdaterMessage = WM_APP + 73;
constexpr char kPackageId[] = "io.github.leobrqz.windfull.windows";
constexpr char kChannel[] = "win-x64";
constexpr char kRepository[] = "https://github.com/leobrqz/Windfull";

std::filesystem::path ExecutablePath() {
  std::wstring buffer(32768, L'\0');
  const DWORD length = GetModuleFileNameW(nullptr, buffer.data(),
                                          static_cast<DWORD>(buffer.size()));
  if (length == 0 || length >= buffer.size()) {
    throw std::runtime_error("Could not locate the WindFull executable.");
  }
  buffer.resize(length);
  return std::filesystem::path(buffer);
}

std::string ReadText(const std::filesystem::path& path) {
  std::ifstream stream(path, std::ios::binary);
  if (!stream) return {};
  return {std::istreambuf_iterator<char>(stream),
          std::istreambuf_iterator<char>()};
}

std::string TrimNulls(std::string value) {
  while (!value.empty() && value.back() == '\0') value.pop_back();
  return value;
}

std::string ReadChannel(const std::filesystem::path& current) {
  const std::string manifest = ReadText(current / L"sq.version");
  constexpr std::string_view start = "<channel>";
  constexpr std::string_view end = "</channel>";
  const size_t position = manifest.find(start);
  if (position == std::string::npos) return {};
  const size_t finish = manifest.find(end, position + start.size());
  if (finish == std::string::npos) return {};
  return manifest.substr(position + start.size(), finish - position - start.size());
}

std::string ErrorCode(const std::string& message) {
  if (message == "not_managed" || message == "invalid_metadata" ||
      message == "invalid_state" || message == "insufficient_space" ||
      message == "folder_access" || message == "integrity" ||
      message == "timeout" || message == "offline") {
    return message;
  }
  std::string lower = message;
  std::transform(lower.begin(), lower.end(), lower.begin(),
                 [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
  if (lower.find("notinstalled") != std::string::npos ||
      lower.find("not installed") != std::string::npos ||
      lower.find("disabled") != std::string::npos) return "not_managed";
  if (lower.find("checksum") != std::string::npos ||
      lower.find("sha256") != std::string::npos) return "integrity";
  if (lower.find("timeout") != std::string::npos) return "timeout";
  if (lower.find("space") != std::string::npos) return "insufficient_space";
  if (lower.find("access denied") != std::string::npos ||
      lower.find("permission") != std::string::npos) return "folder_access";
  if (lower.find("connect") != std::string::npos ||
      lower.find("network") != std::string::npos ||
      lower.find("offline") != std::string::npos) return "offline";
  return "update_failed";
}

void CheckWritableAndSpace(const std::filesystem::path& root,
                           const std::filesystem::path& current,
                           uint64_t package_size) {
  const auto packages = root / L"packages";
  std::error_code error;
  std::filesystem::create_directories(packages, error);
  if (error) throw std::runtime_error("folder_access");

  uint64_t installed_size = 0;
  for (const auto& item : std::filesystem::recursive_directory_iterator(current)) {
    if (item.is_symlink()) throw std::runtime_error("folder_access");
    if (item.is_regular_file()) installed_size += item.file_size();
  }

  ULARGE_INTEGER available{};
  if (!GetDiskFreeSpaceExW(root.c_str(), &available, nullptr, nullptr)) {
    throw std::runtime_error("folder_access");
  }
  constexpr uint64_t reserve = 96ULL * 1024 * 1024;
  if (package_size > (std::numeric_limits<uint64_t>::max() - reserve) / 2 ||
      installed_size > std::numeric_limits<uint64_t>::max() - reserve - package_size * 2 ||
      available.QuadPart < package_size * 2 + installed_size + reserve) {
    throw std::runtime_error("insufficient_space");
  }

  const auto probe = packages / (L".windfull-write-" +
                                 std::to_wstring(GetCurrentProcessId()));
  HANDLE file = CreateFileW(probe.c_str(), GENERIC_WRITE | DELETE, 0, nullptr,
                            CREATE_NEW, FILE_ATTRIBUTE_TEMPORARY |
                                            FILE_FLAG_DELETE_ON_CLOSE,
                            nullptr);
  if (file == INVALID_HANDLE_VALUE) throw std::runtime_error("folder_access");
  CloseHandle(file);
}

void ValidateAsset(const Velopack::VelopackAsset& asset) {
  static const std::regex version_pattern(
      R"(^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$)");
  static const std::regex hash_pattern(R"(^[a-fA-F0-9]{64}$)");
  if (asset.PackageId != kPackageId || asset.Type != "Full" ||
      !std::regex_match(asset.Version, version_pattern) ||
      asset.FileName != std::string(kPackageId) + "-" + asset.Version +
                            "-" + kChannel + "-full.nupkg" ||
      !std::regex_match(asset.SHA256, hash_pattern) || asset.Size == 0 ||
      asset.NotesMarkdown.size() > 65536) {
    throw std::runtime_error("invalid_metadata");
  }
}
}  // namespace

struct UpdateBridge::Impl {
  HWND window;
  std::unique_ptr<flutter::MethodChannel<Value>> methods;
  std::unique_ptr<flutter::EventChannel<Value>> events;
  std::unique_ptr<flutter::EventSink<Value>> event_sink;
  std::mutex mutex;
  std::condition_variable wake;
  std::deque<std::function<void()>> tasks;
  std::deque<std::function<void()>> replies;
  bool stopping = false;
  bool busy = false;
  std::thread worker;

  // Only the updater worker reads or mutates these values.
  std::unique_ptr<Velopack::UpdateManager> manager;
  std::optional<Velopack::UpdateInfo> candidate;
  bool downloaded = false;
  bool managed = false;
  std::string version = WINDFULL_PRODUCT_VERSION;
  std::string channel;

  explicit Impl(flutter::BinaryMessenger* messenger, HWND hwnd) : window(hwnd) {
    methods = std::make_unique<flutter::MethodChannel<Value>>(
        messenger, "windfull/updater",
        &flutter::StandardMethodCodec::GetInstance());
    events = std::make_unique<flutter::EventChannel<Value>>(
        messenger, "windfull/updater_events",
        &flutter::StandardMethodCodec::GetInstance());
    events->SetStreamHandler(std::make_unique<
        flutter::StreamHandlerFunctions<Value>>(
        [this](const Value*,
               std::unique_ptr<flutter::EventSink<Value>> sink) {
          event_sink = std::move(sink);
          return nullptr;
        },
        [this](const Value*) {
          event_sink.reset();
          return nullptr;
        }));
    methods->SetMethodCallHandler(
        [this](const flutter::MethodCall<Value>& call,
               std::unique_ptr<flutter::MethodResult<Value>> result) {
          const std::string operation = call.method_name();
          if (operation == "openReleasePage") {
            const auto* url = call.arguments()
                                  ? std::get_if<std::string>(call.arguments())
                                  : nullptr;
            constexpr wchar_t release_url[] =
                L"https://github.com/leobrqz/Windfull/releases/latest";
            if (!url || *url !=
                            "https://github.com/leobrqz/Windfull/releases/latest") {
              result->Error("invalid_arguments", "Invalid release page URL.");
              return;
            }
            if (reinterpret_cast<INT_PTR>(ShellExecuteW(
                    window, L"open", release_url, nullptr, nullptr, SW_SHOWNORMAL)) <= 32) {
              result->Error("open_failed", "Could not open the official release page.");
              return;
            }
            result->Success();
            return;
          }
          if (operation != "getContext" && operation != "check" &&
              operation != "download" && operation != "apply") {
            result->NotImplemented();
            return;
          }
          if (call.arguments() &&
              !std::holds_alternative<std::monostate>(*call.arguments())) {
            result->Error("invalid_arguments", "No updater arguments expected.");
            return;
          }

          auto reply = std::shared_ptr<flutter::MethodResult<Value>>(
              std::move(result));
          {
            std::lock_guard<std::mutex> lock(mutex);
            if (busy || stopping) {
              reply->Error("busy", "An update operation is already running.");
              return;
            }
            busy = true;
            tasks.push_back([this, operation, reply] { Execute(operation, reply); });
          }
          wake.notify_one();
        });
    worker = std::thread([this] { Run(); });
  }

  void Post(std::function<void()> reply) {
    {
      std::lock_guard<std::mutex> lock(mutex);
      if (stopping) return;
      replies.push_back(std::move(reply));
    }
    PostMessageW(window, kUpdaterMessage, 0, 0);
  }

  void Run() {
    while (true) {
      std::function<void()> task;
      {
        std::unique_lock<std::mutex> lock(mutex);
        wake.wait(lock, [this] { return stopping || !tasks.empty(); });
        if (stopping) break;
        task = std::move(tasks.front());
        tasks.pop_front();
      }
      task();
      {
        std::lock_guard<std::mutex> lock(mutex);
        busy = false;
      }
    }
  }

  void EnsureManager() {
    if (manager) return;
    const auto executable = ExecutablePath();
    const auto current = executable.parent_path();
    channel = ReadChannel(current);
    Velopack::UpdateOptions options{false, std::string(kChannel), -1};
    manager = std::make_unique<Velopack::UpdateManager>(
        std::make_unique<Velopack::GithubSource>(kRepository, "", false),
        &options);
    const std::string app_id = TrimNulls(manager->GetAppId());
    managed = manager->IsPortable() && app_id == kPackageId && channel == kChannel;
    const std::string installed_version = TrimNulls(manager->GetCurrentVersion());
    if (!installed_version.empty()) version = installed_version;
  }

  void Execute(const std::string& operation,
               const std::shared_ptr<flutter::MethodResult<Value>>& result) {
    try {
      EnsureManager();
      if (operation == "getContext") {
        const Value value(Map{
            {Value("version"), Value(version)},
            {Value("managed"), Value(managed)},
            {Value("packageId"), Value(kPackageId)},
            {Value("channel"), Value(channel)},
        });
        Post([result, value] { result->Success(value); });
        return;
      }
      if (!managed) throw std::runtime_error("not_managed");

      if (operation == "check") {
        candidate.reset();
        downloaded = false;
        candidate = manager->CheckForUpdates();
        if (!candidate) {
          Post([result] { result->Success(Value()); });
          return;
        }
        const auto& asset = candidate->TargetFullRelease;
        ValidateAsset(asset);
        if (candidate->IsDowngrade) throw std::runtime_error("invalid_metadata");
        const Value value(Map{
            {Value("version"), Value(asset.Version)},
            {Value("packageId"), Value(asset.PackageId)},
            {Value("channel"), Value(kChannel)},
            {Value("notes"), Value(asset.NotesMarkdown)},
            {Value("releaseUrl"),
             Value(std::string(kRepository) + "/releases/tag/v" + asset.Version)},
        });
        Post([result, value] { result->Success(value); });
        return;
      }

      if (!candidate) throw std::runtime_error("invalid_state");
      if (operation == "download") {
        if (downloaded) throw std::runtime_error("invalid_state");
        const auto current = ExecutablePath().parent_path();
        CheckWritableAndSpace(current.parent_path(), current,
                              candidate->TargetFullRelease.Size);
        manager->DownloadUpdates(
            *candidate,
            [](void* state, size_t percent) {
              auto* bridge = static_cast<Impl*>(state);
              const auto progress = static_cast<int32_t>(
                  std::min<size_t>(percent, 100));
              bridge->Post([bridge, progress] {
                if (bridge->event_sink) {
                  bridge->event_sink->Success(Value(Map{
                      {Value("percent"), Value(progress)},
                  }));
                }
              });
            },
            this);
        downloaded = true;
        Post([result] { result->Success(Value()); });
        return;
      }

      if (operation == "apply") {
        if (!downloaded) throw std::runtime_error("invalid_state");
        manager->WaitExitThenApplyUpdates(*candidate, true, true, {});
        Post([result] { result->Success(Value()); });
        return;
      }
      throw std::runtime_error("invalid_state");
    } catch (const std::exception& error) {
      const std::string detail = error.what();
      const std::string code = ErrorCode(detail);
      Post([this, result, code, detail] {
        if (event_sink) {
          event_sink->Success(Value(Map{{Value("error"), Value(code)}}));
        }
        result->Error(code, detail);
      });
    } catch (...) {
      Post([result] { result->Error("update_failed", "Unknown updater failure."); });
    }
  }

  ~Impl() {
    methods->SetMethodCallHandler(nullptr);
    events->SetStreamHandler(nullptr);
    {
      std::lock_guard<std::mutex> lock(mutex);
      stopping = true;
      tasks.clear();
      replies.clear();
    }
    wake.notify_one();
    if (worker.joinable()) worker.join();
  }
};

UpdateBridge::UpdateBridge(flutter::BinaryMessenger* messenger, HWND window)
    : impl_(std::make_unique<Impl>(messenger, window)) {}

UpdateBridge::~UpdateBridge() = default;

bool UpdateBridge::RunStartup() {
  try {
    Velopack::VelopackApp::Build().SetAutoApplyOnStartup(false).Run();
    return true;
  } catch (const std::exception&) {
    return true;
  }
}

bool UpdateBridge::HandleMessage(UINT message) {
  if (message != kUpdaterMessage) return false;
  std::deque<std::function<void()>> replies;
  {
    std::lock_guard<std::mutex> lock(impl_->mutex);
    replies.swap(impl_->replies);
  }
  for (auto& reply : replies) reply();
  return true;
}
