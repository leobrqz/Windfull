#ifndef WINDFULL_UPDATE_BRIDGE_H_
#define WINDFULL_UPDATE_BRIDGE_H_

#include <flutter/binary_messenger.h>
#include <windows.h>

#include <memory>

class UpdateBridge {
 public:
  static bool RunStartup();

  UpdateBridge(flutter::BinaryMessenger* messenger, HWND window);
  ~UpdateBridge();

  bool HandleMessage(UINT message);

 private:
  struct Impl;
  std::unique_ptr<Impl> impl_;
};

#endif  // WINDFULL_UPDATE_BRIDGE_H_
