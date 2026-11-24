import BuildSlotCore
import Foundation

// The dispatch on `--as`, `run`, `status` and `install` comes with the acquire loop; until
// then the tool only says how it is meant to be called. 64 is EX_USAGE.
let usage = """
  usage: buildslot --as swift|xcodebuild [arguments...]
         buildslot run -- <command> [arguments...]
         buildslot status [--json]
         buildslot install [--bin-dir DIR]
         buildslot uninstall

  """
FileHandle.standardError.write(Data(usage.utf8))
exit(64)
