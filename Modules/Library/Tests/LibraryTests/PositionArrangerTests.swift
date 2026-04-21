import Foundation
import Testing
@testable import Library

@Suite("PositionArranger")
struct PositionArrangerTests {
    // MARK: - Empty / append

    @Test("append into empty playlist uses firstPosition")
    func appendEmpty() {
        #expect(PositionArranger.appendPosition(after: []) == PositionArranger.step)
    }

    @Test("append after existing adds one step")
    func appendAfter() {
        #expect(PositionArranger.appendPosition(after: [1024, 2048]) == 3072)
    }

    @Test("insert at end equals append")
    func insertEndEqualsAppend() {
        let positions = [1024, 2048, 3072]
        let result = PositionArranger.insertPosition(at: positions.count, in: positions)
        #expect(result == 4096)
    }

    // MARK: - Single insert

    @Test("insert at middle picks midpoint")
    func insertMiddle() {
        let result = PositionArranger.insertPosition(at: 1, in: [1024, 2048])
        #expect(result == 1536)
    }

    @Test("insert at start with headroom uses first - step")
    func insertFrontWithHeadroom() {
        let result = PositionArranger.insertPosition(at: 0, in: [2048, 3072])
        #expect(result == 1024)
    }

    @Test("insert at start with no headroom halves first")
    func insertFrontNoHeadroom() {
        let result = PositionArranger.insertPosition(at: 0, in: [100])
        #expect(result == 50)
    }

    @Test("insert at past-end index clamps to append")
    func insertClampsPastEnd() {
        let result = PositionArranger.insertPosition(at: 999, in: [1024])
        #expect(result == 2048)
    }

    // MARK: - Block insert

    @Test("block insert at end produces monotonic positions")
    func blockInsertEnd() {
        let (positions, repack) = PositionArranger.insertPositions(count: 3, at: 2, in: [1024, 2048])
        #expect(positions == [3072, 4096, 5120])
        #expect(repack == false)
    }

    @Test("block insert into empty returns stepped sequence")
    func blockInsertEmpty() {
        let (positions, repack) = PositionArranger.insertPositions(count: 4, at: 0, in: [])
        #expect(positions == [1024, 2048, 3072, 4096])
        #expect(repack == false)
    }

    @Test("block insert in middle with wide gap fits without repack")
    func blockInsertMiddleWide() throws {
        let (positions, repack) = PositionArranger.insertPositions(
            count: 3,
            at: 1,
            in: [0, 4096]
        )
        #expect(positions.count == 3)
        for i in 1 ..< positions.count {
            #expect(positions[i] > positions[i - 1])
        }
        #expect(try #require(positions.first) > 0)
        #expect(try #require(positions.last) < 4096)
        #expect(repack == false)
    }

    @Test("block insert in middle with tight gap signals repack")
    func blockInsertMiddleTight() {
        let (_, repack) = PositionArranger.insertPositions(
            count: 3,
            at: 1,
            in: [0, 2]
        )
        #expect(repack == true)
    }

    // MARK: - Repack

    @Test("repackedPositions is 1024-stepped")
    func repackedPositions() {
        #expect(PositionArranger.repackedPositions(count: 0) == [])
        #expect(PositionArranger.repackedPositions(count: 3) == [1024, 2048, 3072])
    }

    @Test("needsRepack detects adjacent collisions")
    func needsRepack() {
        #expect(PositionArranger.needsRepack([1, 2, 3]) == true)
        #expect(PositionArranger.needsRepack([1000, 2000]) == false)
        #expect(PositionArranger.needsRepack([]) == false)
        #expect(PositionArranger.needsRepack([42]) == false)
    }

    // MARK: - applyMove (SwiftUI semantics)

    @Test("applyMove forward shifts elements correctly")
    func applyMoveForward() {
        // Same semantics as Array.move(fromOffsets: [1], toOffset: 4) on [A,B,C,D,E] -> [A,C,D,B,E]
        let result = PositionArranger.applyMove(
            ["A", "B", "C", "D", "E"],
            fromOffsets: IndexSet([1]),
            toOffset: 4
        )
        #expect(result == ["A", "C", "D", "B", "E"])
    }

    @Test("applyMove backward shifts elements correctly")
    func applyMoveBackward() {
        // move(fromOffsets:[3], toOffset:1) on [A,B,C,D] -> [A,D,B,C]
        let result = PositionArranger.applyMove(
            ["A", "B", "C", "D"],
            fromOffsets: IndexSet([3]),
            toOffset: 1
        )
        #expect(result == ["A", "D", "B", "C"])
    }

    @Test("applyMove with multiple source indices preserves relative order")
    func applyMoveMultiple() {
        let result = PositionArranger.applyMove(
            ["A", "B", "C", "D", "E"],
            fromOffsets: IndexSet([0, 2]),
            toOffset: 5
        )
        #expect(result == ["B", "D", "E", "A", "C"])
    }

    @Test("applyMove with empty source is a no-op")
    func applyMoveEmpty() {
        let result = PositionArranger.applyMove([1, 2, 3], fromOffsets: IndexSet(), toOffset: 2)
        #expect(result == [1, 2, 3])
    }
}
