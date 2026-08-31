import XCTest
@testable import termy

final class ProjectOrderTests: XCTestCase {
    // MARK: - effective(discovered:preferred:)

    func test_noPreferredOrder_keepsDiscoveryOrder() {
        XCTAssertEqual(
            ProjectOrder.effective(discovered: ["api", "web"], preferred: []),
            ["api", "web"]
        )
    }

    func test_preferredOrder_overridesDiscoveryOrder() {
        XCTAssertEqual(
            ProjectOrder.effective(discovered: ["api", "web"], preferred: ["web", "api"]),
            ["web", "api"]
        )
    }

    func test_unplacedProject_appendsAfterPreferredOnes() {
        // Opening a new project must not reshuffle the chips the user placed.
        XCTAssertEqual(
            ProjectOrder.effective(
                discovered: ["api", "web", "docs"],
                preferred: ["web", "api"]
            ),
            ["web", "api", "docs"]
        )
    }

    func test_multipleUnplacedProjects_keepDiscoveryOrderAmongThemselves() {
        XCTAssertEqual(
            ProjectOrder.effective(
                discovered: ["api", "docs", "web", "infra"],
                preferred: ["web"]
            ),
            ["web", "api", "docs", "infra"]
        )
    }

    func test_closedProject_dropsOutOfPreferredOrder() {
        // `web`'s last pane closed — it must not linger as a phantom chip.
        XCTAssertEqual(
            ProjectOrder.effective(
                discovered: ["api", "docs"],
                preferred: ["web", "api", "docs"]
            ),
            ["api", "docs"]
        )
    }

    func test_duplicatePreferredEntries_areCollapsed() {
        XCTAssertEqual(
            ProjectOrder.effective(
                discovered: ["api", "web"],
                preferred: ["web", "web", "api"]
            ),
            ["web", "api"]
        )
    }

    func test_noProjects_yieldsEmptyOrder() {
        XCTAssertEqual(
            ProjectOrder.effective(discovered: [], preferred: ["web"]),
            [String]()
        )
    }

    // MARK: - moving(_:from:to:)

    func test_moveForward_landsAtDestinationIndex() {
        XCTAssertEqual(
            ProjectOrder.moving(["a", "b", "c", "d"], from: 0, to: 2),
            ["b", "c", "a", "d"]
        )
    }

    func test_moveBackward_landsAtDestinationIndex() {
        XCTAssertEqual(
            ProjectOrder.moving(["a", "b", "c", "d"], from: 3, to: 1),
            ["a", "d", "b", "c"]
        )
    }

    func test_moveToSameIndex_isNoOp() {
        XCTAssertEqual(
            ProjectOrder.moving(["a", "b", "c"], from: 1, to: 1),
            ["a", "b", "c"]
        )
    }

    func test_moveToLastIndex_appendsAtEnd() {
        XCTAssertEqual(
            ProjectOrder.moving(["a", "b", "c"], from: 0, to: 2),
            ["b", "c", "a"]
        )
    }

    func test_destinationBeyondBounds_clampsIntoRange() {
        XCTAssertEqual(
            ProjectOrder.moving(["a", "b", "c"], from: 0, to: 99),
            ["b", "c", "a"]
        )
        XCTAssertEqual(
            ProjectOrder.moving(["a", "b", "c"], from: 2, to: -5),
            ["c", "a", "b"]
        )
    }

    func test_sourceOutOfBounds_leavesOrderUntouched() {
        XCTAssertEqual(
            ProjectOrder.moving(["a", "b", "c"], from: 7, to: 0),
            ["a", "b", "c"]
        )
        XCTAssertEqual(
            ProjectOrder.moving([], from: 0, to: 0),
            [String]()
        )
    }

    // MARK: - insertionIndex(draggedCenterX:otherOrigins:otherWidths:firstMovable:)

    // Chip row used below: a pinned 40pt ALL chip, then three 60pt project
    // chips with 6pt gaps — origins 0, 46, 112, 178.
    private let origins: [CGFloat] = [0, 46, 112, 178]
    private let widths: [CGFloat] = [40, 60, 60, 60]

    func test_draggedChipHeldOverItsOwnSlot_staysPut() {
        // Center over the first project slot (46..106) → insert at 1.
        XCTAssertEqual(
            ProjectOrder.insertionIndex(
                draggedCenterX: 76,
                otherOrigins: Array(origins.prefix(3)),
                otherWidths: Array(widths.prefix(3)),
                firstMovable: 1
            ),
            1
        )
    }

    func test_draggedPastNeighbourMidpoint_claimsItsSlot() {
        let others = Array(origins.prefix(3))
        let otherWidths = Array(widths.prefix(3))

        // Just short of the second chip's midpoint (46 + 30 = 76).
        XCTAssertEqual(
            ProjectOrder.insertionIndex(
                draggedCenterX: 75,
                otherOrigins: others,
                otherWidths: otherWidths,
                firstMovable: 1
            ),
            1
        )
        // Past it.
        XCTAssertEqual(
            ProjectOrder.insertionIndex(
                draggedCenterX: 77,
                otherOrigins: others,
                otherWidths: otherWidths,
                firstMovable: 1
            ),
            2
        )
    }

    func test_draggedToLeadingEdge_stopsAfterPinnedChip() {
        // Far left of everything — must not displace the pinned ALL chip.
        XCTAssertEqual(
            ProjectOrder.insertionIndex(
                draggedCenterX: -500,
                otherOrigins: Array(origins.prefix(3)),
                otherWidths: Array(widths.prefix(3)),
                firstMovable: 1
            ),
            1
        )
    }

    func test_noPinnedChip_allowsLeadingSlot() {
        XCTAssertEqual(
            ProjectOrder.insertionIndex(
                draggedCenterX: -500,
                otherOrigins: Array(origins.prefix(3)),
                otherWidths: Array(widths.prefix(3)),
                firstMovable: 0
            ),
            0
        )
    }

    func test_draggedPastTrailingEdge_clampsToLastSlot() {
        XCTAssertEqual(
            ProjectOrder.insertionIndex(
                draggedCenterX: 5_000,
                otherOrigins: origins,
                otherWidths: widths,
                firstMovable: 1
            ),
            4
        )
    }

    func test_singleRemainingChip_hasOnlyOneValidSlot() {
        XCTAssertEqual(
            ProjectOrder.insertionIndex(
                draggedCenterX: 999,
                otherOrigins: [0],
                otherWidths: [40],
                firstMovable: 1
            ),
            1
        )
    }

    // MARK: - Persistence

    func test_windowRecord_roundTripsProjectOrder() throws {
        let record = WindowRecord(
            frame: FrameRecord(x: 0, y: 0, width: 100, height: 100),
            rows: [[PaneRecord(cwd: "/x")]],
            projectOrder: ["web", "api"]
        )
        let data = try JSONEncoder().encode(record)
        let decoded = try JSONDecoder().decode(WindowRecord.self, from: data)

        XCTAssertEqual(decoded.projectOrder, ["web", "api"])
        XCTAssertEqual(decoded, record)
    }

    func test_windowRecord_withoutProjectOrder_decodesAsNil() throws {
        // Sessions written before drag-reorder shipped have no `projectOrder`.
        // They must still decode and fall back to discovery order.
        let legacy = """
        {
          "frame": {"x": 0, "y": 0, "width": 100, "height": 100},
          "rows": [[{"cwd": "/x"}]]
        }
        """
        let decoded = try JSONDecoder().decode(
            WindowRecord.self,
            from: Data(legacy.utf8)
        )

        XCTAssertNil(decoded.projectOrder)
        XCTAssertEqual(decoded.rows, [[PaneRecord(cwd: "/x")]])
    }
}
