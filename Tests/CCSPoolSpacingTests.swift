import XCTest
@testable import Codenotch

/// Homelab fork: a CCS pool card can be nearly as tall as the screen. On a side
/// edge it must neither collapse the gaps between rings nor push the panel off
/// screen.
@MainActor
final class CCSPoolSpacingTests: XCTestCase {
    private func pool(_ name: String) -> ProviderSnapshot {
        let windows = (0..<40).map { index in
            LimitWindow(id: "w\(index)", group: "Account \(index / 8)", label: "Row \(index)",
                        usedFraction: 0.2)
        }
        return ProviderSnapshot(id: "ccs-pool-" + name.lowercased(), displayName: name,
                                glyph: .claude, fidelity: .official, status: .ok, windows: windows)
    }

    func testTallPoolCardsKeepRingSpacingAndPanelOnSideEdges() {
        let vm = NotchViewModel()
        vm.updateSnapshots([pool("Animou"), pool("Dotsafe")])
        vm.screenSize = CGSize(width: 1512, height: 982)
        for size in NotchSize.allCases {
            vm.sizeScale = size.scale
            for edge in [NotchEdge.left, .right] {
                vm.edge = edge
                XCTAssertEqual(vm.cellSpacing, NotchLayout.cellSpacing, "\(edge) \(size)")
                XCTAssertLessThanOrEqual(vm.panelSize.height, vm.screenSize.height + 0.1, "\(edge) \(size)")
                XCTAssertGreaterThanOrEqual(vm.slack, NotchLayout.cardCorner, "\(edge) \(size)")
            }
        }
    }
}
