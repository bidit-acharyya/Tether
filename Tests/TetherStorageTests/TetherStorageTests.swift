import SQLite3
import Testing

@testable import TetherStorage

@Test func systemSQLiteIsRecentEnough() {
    print("SQLite version:", String(cString: sqlite3_libversion()))
    #expect(sqlite3_libversion_number() >= 3_037_000)
}
