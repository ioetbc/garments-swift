import Foundation
import CoreGraphics

nonisolated enum CanvasFixtures {
    static let users: [CanvasProfile] = [
        .init(username: "genevieve_123", displayName: "Genevieve"),
        .init(username: "daisy", displayName: "Daisy")
    ]

    static func matchingUsers(_ query: String) -> [CanvasProfile] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "@"))
        return users.filter { term.isEmpty || $0.username.contains(term) || $0.displayName.lowercased().contains(term) }
    }

    static func canvas(for user: CanvasProfile) -> CanvasDocument {
        let offset = (users.firstIndex(of: user) ?? 0) * 5
        var document = CanvasDocument(username: user.username)
        let isGenevieve = user.username == "genevieve_123"
        let count = isGenevieve ? 16 * 30 : 16 * 20
        for index in 0..<count {
            var product = products[(index % 16 + offset) % products.count]
            product.id = "\(user.username)/\(product.id)"
            document.products[product.id] = product
            let placement = StickerPlacement(id: "\(user.username)/item-\(index)", productID: product.id,
                canvasUsername: user.username, center: .init(),
                width: CanvasConfiguration.initialImageEdge * min(1, product.aspect),
                height: CanvasConfiguration.initialImageEdge / max(1, product.aspect))
            document.placements[placement.id] = placement
            document.order.append(placement.id)
        }
        let memberships = fit(&document, viewport: CGSize(width: 900, height: 800))
        let names = ["Everyday favourites", "Summer wishlist", "Going out", "Vintage finds"]
        let colours: [CanvasGroupColour?] = [
            nil, nil, nil,
            .init(red: 0.96, green: 0.83, blue: 0.85),
            .init(red: 0.98, green: 0.89, blue: 0.76),
            .init(red: 0.97, green: 0.95, blue: 0.76),
            .init(red: 0.83, green: 0.92, blue: 0.81),
            .init(red: 0.79, green: 0.92, blue: 0.91),
            .init(red: 0.82, green: 0.89, blue: 0.98),
            .init(red: 0.89, green: 0.83, blue: 0.96)
        ]
        // Give each canvas a repeatable random mix, including uncoloured groups.
        var colourSeed: UInt64 = isGenevieve ? 0x6E_6E : 0xDA_15
        var colouredGroupCount = 0
        document.namedGroups = memberships.enumerated().map { index, members in
            colourSeed = colourSeed &* 6364136223846793005 &+ 1442695040888963407
            var colour = colours[Int((colourSeed >> 32) % UInt64(colours.count))]
            // Remove half of the coloured backgrounds, preserving the remaining colours.
            if colour != nil {
                colouredGroupCount += 1
                if !colouredGroupCount.isMultiple(of: 2) { colour = nil }
            }
            return CanvasNamedGroup(id: "\(user.username)/group-\(index)", members: members,
                name: names[(index + offset) % names.count],
                backgroundColour: colour)
        }
        return document
    }

    static let products: [SampleProduct] = [
        .init(id: "jacquemus-blue-le-paysan-the-fonccio-shirt", title: "Jacquemus Blue Le Paysan The Fonccio Shirt", category: "Shirt", asset: "jacquemus-blue-le-paysan-the-fonccio-shirt", aspect: 1569.0/3472.0, product_url: "https://www.vinted.co.uk/items/10134567125-next-top"),
        .init(id: "lemaire-beige-loose-silk-shirt", title: "Lemaire Beige Loose Silk Shirt", category: "Shirt", asset: "lemaire-beige-loose-silk-shirt", aspect: 1401.0/3472.0, product_url: "https://www.vinted.co.uk/items/10134567125-next-top"),
        .init(id: "lemaire-taupe-military-shirt", title: "Lemaire Taupe Military Shirt", category: "Shirt", asset: "lemaire-taupe-military-shirt", aspect: 1393.0/3472.0, product_url: "https://www.vinted.co.uk/items/10134567125-next-top"),
        .init(id: "lemaire-white-long-sleeve-t-shirt", title: "Lemaire White Long Sleeve T-Shirt", category: "T-Shirt", asset: "lemaire-white-long-sleeve-t-shirt", aspect: 1456.0/3477.0, product_url: "https://www.ebay.co.uk/itm/257755143287"),
        .init(id: "literary-sport-blue-james-perforated-running-t-shirt", title: "Literary Sport Blue James Perforated Running T-Shirt", category: "T-Shirt", asset: "literary-sport-blue-james-perforated-running-t-shirt", aspect: 1600.0/3365.0, product_url: "https://www.ebay.co.uk/itm/257755143287"),
        .init(id: "shushu-tong-black-pointed-toe-heels", title: "Shushu/Tong Black Pointed Toe Heels", category: "Shoes", asset: "shushu-tong-black-pointed-toe-heels", aspect: 1600.0/983.0, product_url: "https://www.ssense.com/en-nl/women/product/bottega-veneta/off-white-cotton-and-silk-toile-minidress/19768971"),
        .init(id: "shushu-tong-black-round-toe-mary-jane-heels", title: "Shushu/Tong Black Round Toe Mary Jane Heels", category: "Shoes", asset: "shushu-tong-black-round-toe-mary-jane-heels", aspect: 1600.0/1088.0, product_url: "https://www.ssense.com/en-nl/women/product/bottega-veneta/off-white-cotton-and-silk-toile-minidress/19768971"),
        .init(id: "shushu-tong-white-bow-flat-sneakers", title: "Shushu/Tong White Bow Flat Sneakers", category: "Shoes", asset: "shushu-tong-white-bow-flat-sneakers", aspect: 1600.0/733.0, product_url: "https://www.ssense.com/en-nl/women/product/bottega-veneta/off-white-cotton-and-silk-toile-minidress/19768971"),
        .init(id: "burberry-green-long-suede-coat", title: "Burberry Green Long Suede Coat", category: "Coat", asset: "burberry-green-long-suede-coat", aspect: 1554.0/3472.0, product_url: "https://www.vinted.com/items/9889612495-sweatshirt"),
        .init(id: "by-far-blue-carre-nappa-leather-heels", title: "By Far Blue Carre Nappa Leather Heels", category: "Shoes", asset: "by-far-blue-carre-nappa-leather-heels", aspect: 1600.0/811.0, product_url: "https://www.vinted.com/items/9889612495-sweatshirt"),
        .init(id: "dries-van-noten-beige-jacquard-duffle-coat", title: "Dries Van Noten Beige Jacquard Duffle Coat", category: "Coat", asset: "dries-van-noten-beige-jacquard-duffle-coat", aspect: 930.0/3368.0, product_url: "https://www.vinted.com/items/9889612495-sweatshirt"),
        .init(id: "jude-red-date-mule-heeled-sandals", title: "Jude Red Date Mule Heeled Sandals", category: "Shoes", asset: "jude-red-date-mule-heeled-sandals", aspect: 1600.0/942.0, product_url: "https://www.vinted.com/items/9889612495-sweatshirt"),
        .init(id: "lanvin-burgundy-jacquard-oversized-cardigan", title: "Lanvin Burgundy Jacquard Oversized Cardigan", category: "Cardigan", asset: "lanvin-burgundy-jacquard-oversized-cardigan", aspect: 1554.0/3464.0, product_url: "https://www.vinted.com/items/9889612495-sweatshirt"),
        .init(id: "vivienne-westwood-pink-pamela-turtleneck", title: "Vivienne Westwood Pink Pamela Turtleneck", category: "Turtleneck", asset: "vivienne-westwood-pink-pamela-turtleneck", aspect: 1394.0/3473.0, product_url: "https://www.vinted.com/items/9889612495-sweatshirt"),
        .init(id: "vivienne-westwood-pink-sophia-pin-heels", title: "Vivienne Westwood Pink Sophia Pin Heels", category: "Shoes", asset: "vivienne-westwood-pink-sophia-pin-heels", aspect: 1600.0/936.0, product_url: "https://www.vinted.com/items/9889612495-sweatshirt"),
        .init(id: "acne-studios-khaki-corduroy-trousers", title: "Acne Studios Khaki Corduroy Trousers", category: "Trousers", asset: "acne-studios-khaki-corduroy-trousers", aspect: 1479.0/3408.0, product_url: "https://www.vinted.com/items/9889612495-sweatshirt"),
        .init(id: "rick-owens-black-tower-bolan-cutoff-cargo-pants", title: "Rick Owens Black Tower Bolan Cutoff Cargo Pants", category: "Trousers", asset: "rick-owens-black-tower-bolan-cutoff-cargo-pants", aspect: 1600.0/3906.0, product_url: "https://www.vinted.com/items/9889612495-sweatshirt"),
        .init(id: "visvim-gray-carrol-trousers", title: "Visvim Gray Carrol Trousers", category: "Trousers", asset: "visvim-gray-carrol-trousers", aspect: 1600.0/3920.0, product_url: "https://www.vinted.com/items/9889612495-sweatshirt")
    ]

    static func make(count: Int = 100) -> CanvasDocument {
        var d = CanvasDocument(products: Dictionary(uniqueKeysWithValues: products.map { ($0.id,$0) }))
        for i in 0..<max(0,count) {
            let product = products[i % products.count]
            let p = StickerPlacement(id: "seed-\(i)", productID: product.id,
                center: .init(), width: CanvasConfiguration.initialImageEdge * min(1, product.aspect),
                height: CanvasConfiguration.initialImageEdge / max(1, product.aspect))
            d.placements[p.id] = p; d.order.append(p.id)
        }
        return d
    }

    /// Repeatable compositions at the same initial size as imported images.
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
                let edge = CanvasConfiguration.initialImageEdge
                cluster[index].height = edge / max(1, aspect)
                cluster[index].width = cluster[index].height * aspect
                cluster[index].center = .init(
                    x: x + cluster[index].width / 2,
                    y: index < topCount ? edge - cluster[index].height / 2 : edge + 16 + cluster[index].height / 2)
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
        // Open on the first collection without shrinking the whole canvas to the viewport.
        let originX = viewport.width / 2 - scattered[0].midX
        let originY = viewport.height / 2 - scattered[0].midY
        for (number, cluster) in clusters.enumerated() {
            for var placement in cluster {
                placement.center = .init(
                    x: originX + scattered[number].minX + placement.center.x - bounds[number].minX,
                    y: originY + scattered[number].minY + placement.center.y - bounds[number].minY)
                document.placements[placement.id] = placement
            }
        }
        return clusters.map { $0.map(\.id) }.filter { $0.count > 1 }
    }
}
