import XCTest
@testable import iAgentCore

final class WaveformSampleProjectorTests: XCTestCase {
  func testWideProjectionUsesTheWholeChronologicalHistoryWithoutLeadingRepeatFill() {
    let source = [0.11, 0.34, 0.18, 0.72]
    let projected = WaveformSampleProjector.project(source, count: 9)

    XCTAssertEqual(projected.count, 9)
    XCTAssertEqual(projected.first, source.first)
    XCTAssertEqual(projected.last, source.last)
    XCTAssertNotEqual(projected[1], source.first)
    XCTAssertNotEqual(Array(projected.prefix(5)), Array(repeating: source.first!, count: 5))
  }

  func testProjectionPreservesMonotonicSampleOrderAtAnyWidth() {
    let source = [0.1, 0.2, 0.4, 0.7, 0.9]

    for count in [2, 3, 8, 17] {
      let projected = WaveformSampleProjector.project(source, count: count)
      XCTAssertEqual(projected.count, count)
      XCTAssertTrue(zip(projected, projected.dropFirst()).allSatisfy(<=))
      XCTAssertEqual(projected.first, source.first)
      XCTAssertEqual(projected.last, source.last)
    }
  }

  func testEmptyAndSingleSampleHistoryRemainFiniteAndStable() {
    XCTAssertEqual(
      WaveformSampleProjector.project([], count: 4),
      Array(repeating: 0.06, count: 4)
    )
    XCTAssertEqual(
      WaveformSampleProjector.project([0.43], count: 4),
      Array(repeating: 0.43, count: 4)
    )
    XCTAssertEqual(WaveformSampleProjector.project([0.2], count: 0), [])
  }
}
