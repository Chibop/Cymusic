// Optional host-side regression fixture. Compile with -D SHELF_LYRICS_CHECKS alongside ShelfLyrics.
#if SHELF_LYRICS_CHECKS
@main enum SyncedLyricsTimingChecks {
  static func main() {
    let lines = ShelfLyrics.parse("""
      [offset:+100]
      [00:06.1]Plain line
      [00:01.1][00:04.1]前 <00:01.600>你 <00:02.100>好<00:02.600>
      [00:08.1]
      No guessed timing
      """)
    precondition(lines.map(\.time) == [1, 4, 6, 8])
    precondition(lines.map(\.text) == ["前 你 好", "前 你 好", "Plain line", ""])
    for (time, expected): (Double, Int?) in [(0.999, nil), (1, 0), (3.999, 0), (4, 1), (8, 3), (6, 2), (0, nil)] {
      precondition(ShelfLyrics.index(at: time, in: lines) == expected)
    }
    for (time, expected): (Double, Int?) in [(1.499, nil), (1.5, 1), (1.999, 1), (2, 2), (2.499, 2), (2.5, nil)] {
      precondition(lines[0].activePart(at: time) == expected)
      precondition(lines[1].activePart(at: time + 3) == expected)
    }
    precondition(lines[2].parts.isEmpty && lines[2].activePart(at: 7) == nil)
    precondition(ShelfLyrics.parse("untimed only").isEmpty)
    let reversed = ShelfLyrics.parse("[00:00]<00:02>A<00:01>B")[0]
    precondition(reversed.text == "AB" && reversed.parts.isEmpty)
    let delayed = ShelfLyrics.parse("[offset:-150]\n[00:00:125]delayed")[0]
    precondition(delayed.time == 0.275)
    print("Synced lyrics timing boundaries passed")
  }
}
#endif
