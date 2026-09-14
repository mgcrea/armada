import Foundation

/// The lines of a newline-delimited JSON buffer, walked one at a time without copying
/// the buffer.
///
/// **One helper where there were six copies of the same two lines**, each of which
/// split the whole buffer into an array before looking at any of it, and two of which
/// then copied every line into a `Data` of its own. On the deep scan that held a 50MB
/// transcript two and three times over, for parsers that nearly always stop at the
/// first match from the end. These yield slices of the caller's buffer, in whichever
/// direction the parser reads, and stop when the parser does.
///
/// **`droppingFirstLine` is the contract every tail reader relies on.** A read that did
/// not start at byte zero almost certainly starts part-way through a line, and that
/// fragment is not parseable JSON. Set, the first non-empty line is skipped in both
/// directions. Empty lines are never yielded, matching the
/// `split(separator:omittingEmptySubsequences: true)` the copies used, so a buffer that
/// happens to open on a newline still loses its first *non-empty* line.
nonisolated enum JSONLines {
  /// Newest line first: what every "the last X in the file" parser wants.
  static func newestFirst(_ buffer: Data, droppingFirstLine: Bool) -> NewestFirst {
    NewestFirst(
      buffer: buffer, floor: floor(of: buffer, droppingFirstLine: droppingFirstLine),
      cursor: buffer.endIndex)
  }

  /// Oldest line first, for the readers that want the first match or the whole series.
  static func oldestFirst(_ buffer: Data, droppingFirstLine: Bool) -> OldestFirst {
    OldestFirst(buffer: buffer, cursor: floor(of: buffer, droppingFirstLine: droppingFirstLine))
  }

  nonisolated struct NewestFirst: Sequence, IteratorProtocol {
    let buffer: Data
    /// Nothing before this index is yielded.
    let floor: Data.Index
    /// The exclusive end of the part not yet walked.
    var cursor: Data.Index

    mutating func next() -> Data? {
      let (base, floor) = (buffer.startIndex, self.floor)
      while cursor > floor {
        let end = cursor
        let start = buffer.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Data.Index in
          var index = end - 1
          while index >= floor, raw[index - base] != 0x0A { index -= 1 }
          return index + 1
        }
        // Onto the newline that ended the search, or below the floor when there was none.
        cursor = start - 1
        if start < end { return buffer[start..<end] }
      }
      return nil
    }
  }

  nonisolated struct OldestFirst: Sequence, IteratorProtocol {
    let buffer: Data
    /// The start of the part not yet walked.
    var cursor: Data.Index

    mutating func next() -> Data? {
      let (base, end) = (buffer.startIndex, buffer.endIndex)
      while cursor < end {
        let start = cursor
        let stop = buffer.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Data.Index in
          var index = start
          while index < end, raw[index - base] != 0x0A { index += 1 }
          return index
        }
        cursor = stop + 1
        if stop > start { return buffer[start..<stop] }
      }
      return nil
    }
  }

  /// Where the first line worth reading starts: the buffer's start, or just past the
  /// leading fragment and any newlines before it.
  private static func floor(of buffer: Data, droppingFirstLine: Bool) -> Data.Index {
    guard droppingFirstLine else { return buffer.startIndex }
    var first = OldestFirst(buffer: buffer, cursor: buffer.startIndex)
    guard let fragment = first.next() else { return buffer.endIndex }
    return fragment.endIndex
  }
}
