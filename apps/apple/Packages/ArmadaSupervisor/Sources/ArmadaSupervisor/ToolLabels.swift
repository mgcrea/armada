/// What the overlay says while a tool runs, so a pause of a few seconds reads as work.
///
/// Keyed by the bare tool name, so both `armada_get_fleet` and the prefixed
/// `mcp__armada__armada_get_fleet` that `claude` reports resolve to the same line.
public enum ToolLabels {
  public static func label(for toolName: String) -> String {
    let name = toolName.components(separatedBy: "__").last ?? toolName
    return switch name {
    case "armada_needs_attention": "Checking who needs you…"
    case "armada_get_fleet": "Looking over your sessions…"
    case "armada_get_session": "Looking at that session…"
    case "armada_get_usage": "Checking your plan limits…"
    case "armada_get_projects": "Looking at your projects…"
    case "armada_read_transcript": "Reading what it said…"
    case "armada_start_session": "Starting a session…"
    default: "Working…"
    }
  }
}
