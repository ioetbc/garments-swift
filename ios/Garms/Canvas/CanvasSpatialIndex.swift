import Foundation
import CoreGraphics

nonisolated final class CanvasSpatialIndex {
    private struct Cell: Hashable { var x: Int; var y: Int }
    private var cells: [Cell: Set<String>] = [:]
    private var oversized: Set<String> = []
    private(set) var bounds: [String: CGRect] = [:]
    private func keys(_ r: CGRect, cap: Int) -> [Cell]? {
        guard !r.isNull, r.minX.isFinite, r.maxX.isFinite, r.minY.isFinite, r.maxY.isFinite,
              abs(r.minX) < 2e12, abs(r.maxX) < 2e12, abs(r.minY) < 2e12, abs(r.maxY) < 2e12 else { return nil }
        let x0 = Int(floor(r.minX/CanvasConfiguration.cell)), x1 = Int(floor(r.maxX/CanvasConfiguration.cell))
        let y0 = Int(floor(r.minY/CanvasConfiguration.cell)), y1 = Int(floor(r.maxY/CanvasConfiguration.cell))
        guard Double(x1-x0+1)*Double(y1-y0+1) <= Double(cap) else { return nil }
        return (x0...x1).flatMap { x in (y0...y1).map { Cell(x:x,y:$0) } }
    }
    func insert(_ p: StickerPlacement) { update(p) }
    func remove(_ id: String) {
        if let r = bounds.removeValue(forKey:id), let kk = keys(r,cap:CanvasConfiguration.maxItemCells) {
            for k in kk { cells[k]?.remove(id); if cells[k]?.isEmpty == true { cells[k] = nil } }
        }
        oversized.remove(id)
    }
    func update(_ p: StickerPlacement) {
        if bounds[p.id] == p.bounds { return }
        remove(p.id); bounds[p.id] = p.bounds
        if let kk = keys(p.bounds,cap:CanvasConfiguration.maxItemCells) { for k in kk { cells[k,default:[]].insert(p.id) } }
        else { oversized.insert(p.id) }
    }
    func query(_ rect: CGRect) -> Set<String> {
        let candidates: Set<String>
        if let kk = keys(rect,cap:CanvasConfiguration.maxQueryCells) { candidates = kk.reduce(oversized) { $0.union(cells[$1] ?? []) } }
        else { candidates = Set(bounds.keys) }
        return candidates.filter { bounds[$0]?.intersects(rect) == true }
    }
    func rebuild(_ d: CanvasDocument) { cells.removeAll(); bounds.removeAll(); oversized.removeAll(); for p in d.placements.values { insert(p) } }
}
nonisolated struct CanvasGroupLink: Hashable {
    let first: String
    let second: String
    init(_ a: String, _ b: String) { first = min(a,b); second = max(a,b) }
}

// Only the active drag preview creates connections. Proximity maintains existing groups.
nonisolated enum CanvasProximity {
    static func groups(document: CanvasDocument, index: CanvasSpatialIndex, preview: (moving: String, target: String)? = nil, previous: [[String]] = [], detached: Set<CanvasGroupLink> = []) -> [[String]] {
        var priorGroup: [String:Int] = [:]
        for (number, group) in previous.enumerated() { for id in group { priorGroup[id] = number } }
        // Followed canvases retain their source groups, independent of proximity.
        let guestIDs = Set(document.placements.values.filter { $0.canvasUsername != nil }.map(\.id))
        var visited = guestIDs
        var result = (document.namedGroups ?? []).compactMap { group -> [String]? in
            let members = group.members.filter { guestIDs.contains($0) }
            return members.isEmpty ? nil : members
        }
        for id in document.order where !visited.contains(id) {
            visited.insert(id)
            var members = [id], cursor = 0
            while cursor < members.count {
                guard let p = document.placements[members[cursor]] else { cursor += 1; continue }
                cursor += 1
                if let preview {
                    let linked = p.id == preview.moving ? preview.target : (p.id == preview.target ? preview.moving : nil)
                    if let linked, !guestIDs.contains(linked), !detached.contains(CanvasGroupLink(p.id,linked)), document.placements[linked] != nil, visited.insert(linked).inserted {
                        members.append(linked)
                    }
                }
                let radius = CanvasConfiguration.detachRadius
                for other in index.query(p.bounds.insetBy(dx:-radius,dy:-radius)).sorted() where !visited.contains(other) {
                    let wasGrouped = priorGroup[p.id] != nil && priorGroup[p.id] == priorGroup[other]
                    guard wasGrouped, !detached.contains(CanvasGroupLink(p.id,other)),
                          let q = document.placements[other], CanvasGeometry.distance(p.bounds,q.bounds) <= radius else { continue }
                    visited.insert(other); members.append(other)
                }
            }
            let recentMembers = document.namedGroups?.first(where: \.isRecentUploads)?.members ?? []
            if members.count > 1 || members.contains(where: recentMembers.contains) { result.append(members) }
        }
        return result
    }
}
