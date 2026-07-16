#if os(macOS)
  import CodexCore
  import Darwin
  import Foundation

  do {
    try await CodeModeProcessHost.run()
  } catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    exit(1)
  }
#endif
