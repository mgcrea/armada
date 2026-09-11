// WARNING: scanTitle() below keeps the FIRST ai-title. Titles are rewritten throughout a
// session, so a real app must take the NEWEST one. See ../claude-code-sessions.md, "Titles".
//
// THROWAWAY SPIKE. Can a native app keep a live list of Claude Code sessions,
// with titles and working/idle state, from files on disk alone?
//
//   ~/.claude/sessions/<pid>.json          live registry (self-pruning)
//   ~/.claude/projects/<enc>/<sid>.jsonl   transcript: ai-title entry + write activity
//
// State is inferred, not read: a transcript write means working; silence past
// `idleAfter` means idle. The spike exists to measure where that lies.

import CoreServices
import Foundation

setvbuf(stdout, nil, _IOLBF, 0)

let home = FileManager.default.homeDirectoryForCurrentUser.path
let sessionsDir = "\(home)/.claude/sessions"
let projectsDir = "\(home)/.claude/projects"
let idleAfter: TimeInterval = 20

enum State: String { case working, idle }

struct Registry: Decodable {
  let pid: Int32
  let sessionId: String
  let cwd: String
  let name: String
}

final class Session {
  let reg: Registry
  var transcript: String?
  var title: String?
  var scanned: UInt64 = 0  // bytes already searched for ai-title; the scan resumes here
  var lastWrite: Date = .distantPast
  var state: State = .idle
  init(_ reg: Registry) { self.reg = reg }
}

var sessions: [String: Session] = [:]
var startupDone = false
let q = DispatchQueue(label: "session-watch")
let clock: DateFormatter = {
  let f = DateFormatter()
  f.dateFormat = "HH:mm:ss.SSS"
  return f
}()

func pad(_ s: String, _ n: Int) -> String { s.padding(toLength: n, withPad: " ", startingAt: 0) }

func log(_ event: String, _ s: Session, _ note: String = "") {
  print("\(clock.string(from: Date()))  \(pad(event, 8)) \(pad(s.reg.name, 20)) \(pad(s.state.rawValue, 8)) \(s.title ?? "(untitled)")\(note.isEmpty ? "" : "  \(note)")")
}

func alive(_ pid: Int32) -> Bool { kill(pid, 0) == 0 || errno == EPERM }

func fileDates(_ path: String) -> (modified: Date, created: Date)? {
  guard let a = try? FileManager.default.attributesOfItem(atPath: path),
    let m = a[.modificationDate] as? Date, let c = a[.creationDate] as? Date
  else { return nil }
  return (m, c)
}

func findTranscript(_ r: Registry) -> String? {
  let fm = FileManager.default
  let guesses = [
    r.cwd.replacingOccurrences(of: "/", with: "-"),
    String(r.cwd.map { $0.isLetter || $0.isNumber ? $0 : "-" }),
  ]
  for g in guesses where fm.fileExists(atPath: "\(projectsDir)/\(g)/\(r.sessionId).jsonl") {
    return "\(projectsDir)/\(g)/\(r.sessionId).jsonl"
  }
  // The encoding is internal and undocumented, so fall back to a search.
  for d in (try? fm.contentsOfDirectory(atPath: projectsDir)) ?? []
  where fm.fileExists(atPath: "\(projectsDir)/\(d)/\(r.sessionId).jsonl") {
    return "\(projectsDir)/\(d)/\(r.sessionId).jsonl"
  }
  return nil
}

let aiTitleNeedle = Data("ai-title".utf8)

/// Forward scan that stops at the first ai-title. The title is written once, near the
/// head, so this touches a few KB of a multi-MB transcript. Resumes from `scanned`, so an
/// untitled session is never re-read from the top.
func scanTitle(_ s: Session) {
  guard s.title == nil, let path = s.transcript, let fh = FileHandle(forReadingAtPath: path)
  else { return }
  defer { try? fh.close() }
  try? fh.seek(toOffset: s.scanned)
  var offset = s.scanned
  var carry = Data()
  while true {
    let chunk = fh.readData(ofLength: 1 << 16)
    if chunk.isEmpty { break }
    let buf = carry + chunk
    var start = buf.startIndex
    while let nl = buf[start...].firstIndex(of: 0x0A) {
      let line = buf[start..<nl]
      offset += UInt64(nl - start + 1)
      if line.range(of: aiTitleNeedle) != nil,
        let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
        obj["type"] as? String == "ai-title", let t = obj["aiTitle"] as? String
      {
        s.title = t
        s.scanned = offset
        return
      }
      start = buf.index(after: nl)
    }
    carry = Data(buf[start...])  // partial last line: never advance past it
  }
  s.scanned = offset
}

func rescanRegistry() {
  var seen = Set<String>()
  for f in (try? FileManager.default.contentsOfDirectory(atPath: sessionsDir)) ?? []
  where f.hasSuffix(".json") {
    let path = "\(sessionsDir)/\(f)"
    // A registry file caught mid-write fails to decode; the next event picks it up.
    guard let data = FileManager.default.contents(atPath: path),
      let r = try? JSONDecoder().decode(Registry.self, from: data), alive(r.pid)
    else { continue }
    seen.insert(r.sessionId)
    guard sessions[r.sessionId] == nil else { continue }
    let s = Session(r)
    s.transcript = findTranscript(r)
    if let t = s.transcript, let d = fileDates(t) { s.lastWrite = d.modified }
    s.state = Date().timeIntervalSince(s.lastWrite) <= 5 ? .working : .idle
    scanTitle(s)
    sessions[r.sessionId] = s
    var note = ""
    if startupDone, let d = fileDates(path) {
      note = String(format: "(+%.0fms after registry file created)", Date().timeIntervalSince(d.created) * 1000)
    }
    log("ADDED", s, note)
  }
  for (id, s) in sessions where !seen.contains(id) {
    sessions[id] = nil
    log("REMOVED", s)
  }
}

func handle(_ paths: [String]) {
  var registryTouched = false
  for p in paths {
    if p.hasPrefix(sessionsDir) {
      registryTouched = true
      continue
    }
    guard p.hasPrefix(projectsDir), p.hasSuffix(".jsonl") else { continue }
    // <enc>/<sid>.jsonl is the transcript; <enc>/<sid>/... is subagent work for that session.
    let comps = p.dropFirst(projectsDir.count + 1).split(separator: "/")
    guard comps.count >= 2 else { continue }
    var id = String(comps[1])
    if id.hasSuffix(".jsonl") { id = String(id.dropLast(6)) }
    guard let s = sessions[id] else { continue }
    if s.transcript == nil, comps.count == 2 { s.transcript = p }
    let lag = fileDates(p).map { Date().timeIntervalSince($0.modified) * 1000 } ?? -1
    s.lastWrite = Date()
    if s.title == nil {
      scanTitle(s)
      if s.title != nil { log("TITLED", s) }
    }
    if s.state != .working {
      s.state = .working
      log("WORKING", s, String(format: "(+%.0fms after write)", lag))
    }
  }
  if registryTouched { rescanRegistry() }
}

func benchmark() {
  var scanT = 0.0, fullT = 0.0
  var scanBytes: UInt64 = 0, fullBytes = 0, titled = 0
  for s in sessions.values {
    guard let p = s.transcript else { continue }
    let probe = Session(s.reg)
    probe.transcript = p
    var t = Date()
    scanTitle(probe)
    scanT += Date().timeIntervalSince(t)
    scanBytes += probe.scanned
    if probe.title != nil { titled += 1 }
    t = Date()
    if let d = FileManager.default.contents(atPath: p) {
      fullBytes += d.count
      for line in d.split(separator: 0x0A) {
        _ = try? JSONSerialization.jsonObject(with: line)
      }
    }
    fullT += Date().timeIntervalSince(t)
  }
  print(
    String(
      format: "BENCH  title via forward scan: %.1fms reading %.2fMB | full read+parse: %.1fms reading %.1fMB | %d/%d titled",
      scanT * 1000, Double(scanBytes) / 1e6, fullT * 1000, Double(fullBytes) / 1e6, titled, sessions.count))
}

let callback: FSEventStreamCallback = { _, _, _, eventPaths, _, _ in
  let paths = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue() as! [String]
  handle(paths)
}

q.sync {
  let t = Date()
  rescanRegistry()
  print(String(format: "COLD   %d live sessions listed with titles in %.1fms", sessions.count, Date().timeIntervalSince(t) * 1000))
  benchmark()
  startupDone = true
}

var ctx = FSEventStreamContext(version: 0, info: nil, retain: nil, release: nil, copyDescription: nil)
let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer)
guard
  let stream = FSEventStreamCreate(
    kCFAllocatorDefault, callback, &ctx, [sessionsDir, projectsDir] as CFArray,
    FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.05, flags)
else { fatalError("FSEventStreamCreate failed") }
FSEventStreamSetDispatchQueue(stream, q)
FSEventStreamStart(stream)

// Idleness is the absence of events, so it needs a clock. A crashed session also leaves
// its registry file behind, so liveness is swept here too.
let timer = DispatchSource.makeTimerSource(queue: q)
timer.schedule(deadline: .now() + 1, repeating: 1)
timer.setEventHandler {
  let now = Date()
  for s in sessions.values where s.state == .working && now.timeIntervalSince(s.lastWrite) > idleAfter {
    s.state = .idle
    log("IDLE", s, String(format: "(silent %.0fs)", now.timeIntervalSince(s.lastWrite)))
  }
  if sessions.values.contains(where: { !alive($0.reg.pid) }) { rescanRegistry() }
}
timer.resume()
print("\(clock.string(from: Date()))  watching \(sessionsDir) + \(projectsDir)")
dispatchMain()
