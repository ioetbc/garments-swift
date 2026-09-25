import Foundation
import CoreGraphics

nonisolated enum CanvasFixtures {
    static let products: [SampleProduct] = [
        .init(id: "jacquemus-blue-le-paysan-the-fonccio-shirt", title: "Jacquemus Blue Le Paysan The Fonccio Shirt", category: "Shirt", asset: "jacquemus-blue-le-paysan-the-fonccio-shirt", aspect: 1569.0/3472.0),
        .init(id: "lemaire-beige-loose-silk-shirt", title: "Lemaire Beige Loose Silk Shirt", category: "Shirt", asset: "lemaire-beige-loose-silk-shirt", aspect: 1401.0/3472.0),
        .init(id: "lemaire-taupe-military-shirt", title: "Lemaire Taupe Military Shirt", category: "Shirt", asset: "lemaire-taupe-military-shirt", aspect: 1393.0/3472.0),
        .init(id: "lemaire-white-long-sleeve-t-shirt", title: "Lemaire White Long Sleeve T-Shirt", category: "T-Shirt", asset: "lemaire-white-long-sleeve-t-shirt", aspect: 1456.0/3477.0),
        .init(id: "literary-sport-blue-james-perforated-running-t-shirt", title: "Literary Sport Blue James Perforated Running T-Shirt", category: "T-Shirt", asset: "literary-sport-blue-james-perforated-running-t-shirt", aspect: 1600.0/3365.0),
        .init(id: "shushu-tong-black-pointed-toe-heels", title: "Shushu/Tong Black Pointed Toe Heels", category: "Shoes", asset: "shushu-tong-black-pointed-toe-heels", aspect: 1600.0/983.0),
        .init(id: "shushu-tong-black-round-toe-mary-jane-heels", title: "Shushu/Tong Black Round Toe Mary Jane Heels", category: "Shoes", asset: "shushu-tong-black-round-toe-mary-jane-heels", aspect: 1600.0/1088.0),
        .init(id: "shushu-tong-white-bow-flat-sneakers", title: "Shushu/Tong White Bow Flat Sneakers", category: "Shoes", asset: "shushu-tong-white-bow-flat-sneakers", aspect: 1600.0/733.0),
        .init(id: "burberry-green-long-suede-coat", title: "Burberry Green Long Suede Coat", category: "Coat", asset: "burberry-green-long-suede-coat", aspect: 1554.0/3472.0),
        .init(id: "by-far-blue-carre-nappa-leather-heels", title: "By Far Blue Carre Nappa Leather Heels", category: "Shoes", asset: "by-far-blue-carre-nappa-leather-heels", aspect: 1600.0/811.0),
        .init(id: "dries-van-noten-beige-jacquard-duffle-coat", title: "Dries Van Noten Beige Jacquard Duffle Coat", category: "Coat", asset: "dries-van-noten-beige-jacquard-duffle-coat", aspect: 930.0/3368.0),
        .init(id: "jude-red-date-mule-heeled-sandals", title: "Jude Red Date Mule Heeled Sandals", category: "Shoes", asset: "jude-red-date-mule-heeled-sandals", aspect: 1600.0/942.0),
        .init(id: "lanvin-burgundy-jacquard-oversized-cardigan", title: "Lanvin Burgundy Jacquard Oversized Cardigan", category: "Cardigan", asset: "lanvin-burgundy-jacquard-oversized-cardigan", aspect: 1554.0/3464.0),
        .init(id: "vivienne-westwood-pink-pamela-turtleneck", title: "Vivienne Westwood Pink Pamela Turtleneck", category: "Turtleneck", asset: "vivienne-westwood-pink-pamela-turtleneck", aspect: 1394.0/3473.0),
        .init(id: "vivienne-westwood-pink-sophia-pin-heels", title: "Vivienne Westwood Pink Sophia Pin Heels", category: "Shoes", asset: "vivienne-westwood-pink-sophia-pin-heels", aspect: 1600.0/936.0),
        .init(id: "acne-studios-khaki-corduroy-trousers", title: "Acne Studios Khaki Corduroy Trousers", category: "Trousers", asset: "acne-studios-khaki-corduroy-trousers", aspect: 1479.0/3408.0),
        .init(id: "rick-owens-black-tower-bolan-cutoff-cargo-pants", title: "Rick Owens Black Tower Bolan Cutoff Cargo Pants", category: "Trousers", asset: "rick-owens-black-tower-bolan-cutoff-cargo-pants", aspect: 1600.0/3906.0),
        .init(id: "visvim-gray-carrol-trousers", title: "Visvim Gray Carrol Trousers", category: "Trousers", asset: "visvim-gray-carrol-trousers", aspect: 1600.0/3920.0)
    ]

    static func make(count: Int = 100) -> CanvasDocument {
        var d = CanvasDocument(products: Dictionary(uniqueKeysWithValues: products.map { ($0.id,$0) }))
        for i in 0..<max(0,count) {
            let product = products[i % products.count]
            let p = StickerPlacement(id: "seed-\(i)", productID: product.id,
                center: .init(), width: 340*min(1,product.aspect), height: 340/max(1,product.aspect))
            d.placements[p.id] = p; d.order.append(p.id)
        }
        return d
    }

    /// Small, repeatable compositions with generous space between each collection.
    /// Returns intentional memberships so proximity cannot merge neighbouring clusters.
    @discardableResult
    static func fit(_ document: inout CanvasDocument, viewport: CGSize) -> [[String]] {
        let items = document.order.compactMap { document.placements[$0] }
        guard !items.isEmpty, viewport.width > 0, viewport.height > 0 else { return [] }
        var clusters: [[StickerPlacement]] = []
        var cursor = 0
        let sizes = [4, 3, 5, 4, 5, 3]
        while cursor < items.count {
            let remaining = items.count - cursor
            var count = remaining <= 5 ? remaining : sizes[clusters.count % sizes.count]
            // Avoid leaving a final cluster of just one or two items.
            if remaining > count && remaining - count < 3 { count = remaining - 3 }
            var cluster = Array(items[cursor..<(cursor + count)])
            let topCount = (count + 1) / 2
            var x = 0.0
            for index in cluster.indices {
                if index == topCount { x = clusters.count.isMultiple(of: 2) ? 18 : 0 }
                let aspect = cluster[index].width / cluster[index].height
                let height = 210.0 - Double((index + clusters.count) % 3) * 18
                cluster[index].height = min(height, 156 / aspect)
                cluster[index].width = cluster[index].height * aspect
                cluster[index].center = .init(
                    x: x + cluster[index].width / 2,
                    y: index < topCount ? 210 - cluster[index].height / 2 : 226 + cluster[index].height / 2)
                x += cluster[index].width + 16
            }
            clusters.append(cluster)
            cursor += count
        }

        let bounds = clusters.map { CanvasGeometry.union($0) }
        let margin = min(28.0, min(viewport.width, viewport.height) * 0.06)
        let availableWidth = max(1, viewport.width - margin * 2)
        let availableHeight = max(1, viewport.height - margin * 2)
        let aspect = availableWidth / availableHeight
        let gap = 150.0
        let area = bounds.reduce(0.0) { $0 + ($1.width + gap) * ($1.height + gap) } * 1.8
        var fieldWidth = max(sqrt(area * aspect), (bounds.map { $0.width }.max() ?? 0) + gap)
        var fieldHeight = max(sqrt(area / aspect), (bounds.map { $0.height }.max() ?? 0) + gap)
        // A fixed seed gives an organic arrangement without shuffling it on each launch.
        var randomState: UInt64 = 0xCA_4A_5E
        func randomUnit() -> Double {
            randomState = randomState &* 6364136223846793005 &+ 1442695040888963407
            return Double(randomState >> 11) / Double(UInt64(1) << 53)
        }
        var scattered: [CGRect] = []
        for local in bounds {
            var position: CGRect?
            for attempt in 0..<2000 {
                if attempt > 0 && attempt.isMultiple(of: 200) {
                    fieldWidth *= 1.12
                    fieldHeight *= 1.12
                }
                let candidate = CGRect(
                    x: randomUnit() * (fieldWidth - local.width),
                    y: randomUnit() * (fieldHeight - local.height),
                    width: local.width, height: local.height)
                if scattered.allSatisfy({ CanvasGeometry.distance($0, candidate) >= gap }) {
                    position = candidate
                    break
                }
            }
            // Bound the search even for unusually large fixture collections.
            scattered.append(position ?? CGRect(
                x: (scattered.map { $0.maxX }.max() ?? 0) + gap,
                y: randomUnit() * fieldHeight, width: local.width, height: local.height))
        }
        let extent = scattered.reduce(CGRect.null) { $0.union($1) }
        // Never enlarge the resting gaps beyond the grouping distance.
        let scale = min(1, availableWidth / extent.width, availableHeight / extent.height)
        let originX = (viewport.width - extent.width * scale) / 2
        let originY = (viewport.height - extent.height * scale) / 2
        for (number, cluster) in clusters.enumerated() {
            for var placement in cluster {
                placement.center = .init(
                    x: originX + (scattered[number].minX - extent.minX + placement.center.x - bounds[number].minX) * scale,
                    y: originY + (scattered[number].minY - extent.minY + placement.center.y - bounds[number].minY) * scale)
                placement.width *= scale
                placement.height *= scale
                document.placements[placement.id] = placement
            }
        }
        return clusters.map { $0.map(\.id) }.filter { $0.count > 1 }
    }
}
