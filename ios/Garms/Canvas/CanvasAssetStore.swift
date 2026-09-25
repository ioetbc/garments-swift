import UIKit
import ImageIO

nonisolated struct AlphaMask: Sendable {
    let width: Int
    let height: Int
    let bytes: [UInt8]
    func hit(u: Double, v: Double) -> Bool {
        guard u >= 0, v >= 0, u <= 1, v <= 1 else { return false }
        return bytes[min(height-1,Int(v*Double(height)))*width+min(width-1,Int(u*Double(width)))] > 25
    }
}
nonisolated enum CanvasImageWorker {
    static func sourceURL(_ asset: String) -> URL? {
        guard !asset.contains("/"), !asset.contains("..") else { return nil }
        return Bundle.main.url(forResource:asset,withExtension:"png") ?? Bundle.main.url(forResource:asset,withExtension:"png",subdirectory:"Samples")
    }
    static func decode(url: URL, tier: Int) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL,nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(src,0,[kCGImageSourceCreateThumbnailFromImageAlways:true,kCGImageSourceCreateThumbnailWithTransform:true,kCGImageSourceThumbnailMaxPixelSize:tier,kCGImageSourceShouldCacheImmediately:true] as CFDictionary)
    }
    static func mask(_ image: CGImage) -> AlphaMask? {
        let w = image.width, h = image.height
        var rgba = [UInt8](repeating:0,count:w*h*4)
        let ok = rgba.withUnsafeMutableBytes { ptr -> Bool in
            guard let c = CGContext(data:ptr.baseAddress,width:w,height:h,bitsPerComponent:8,bytesPerRow:w*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            c.translateBy(x:0,y:CGFloat(h)); c.scaleBy(x:1,y:-1)
            c.draw(image,in:CGRect(x:0,y:0,width:w,height:h)); return true
        }
        return ok ? AlphaMask(width:w,height:h,bytes:stride(from:3,to:rgba.count,by:4).map { rgba[$0] }) : nil
    }
}
@MainActor final class CanvasAssetStore {
    struct Key: Hashable, Sendable { var asset: String; var tier: Int }
    private struct Entry { var image: CGImage; var stamp: Int; var cost: Int }
    private var cache: [Key:Entry] = [:]
    private var requests: Set<Key> = []
    private var queue: [Key] = []
    private var stamp = 0
    private var generation = 0
    private(set) var masks: [String:AlphaMask] = [:]
    private(set) var bytes = 0
    private(set) var inFlight = 0
    var needed: Set<Key> = []
    var changed: (() -> Void)?
    var failure: ((String) -> Void)?
    private var failed: Set<String> = []
    private var pressureUntil = Date.distantPast
    func tier(for pixels: Double) -> Int {
        if Date() < pressureUntil { return 128 }
        return CanvasConfiguration.tiers.first { Double($0) >= pixels } ?? 2048
    }
    func image(_ key: Key) -> CGImage? {
        stamp += 1
        if var e = cache[key] { e.stamp = stamp; cache[key] = e; return e.image }
        if !requests.contains(key), !failed.contains(key.asset) { requests.insert(key); queue.append(key) }
        return cache.filter { $0.key.asset == key.asset }.min { abs($0.key.tier-key.tier) < abs($1.key.tier-key.tier) }?.value.image
    }
    func reconcile() {
        queue.removeAll { key in if !needed.contains(key) { requests.remove(key); return true }; return false }
        evict(); pump()
    }
    private func pump() {
        while inFlight < 2, !queue.isEmpty {
            let key = queue.removeFirst(); inFlight += 1
            let gen = generation
            Task { [weak self] in
                let result = await Task.detached(priority:.userInitiated) { () -> (CGImage?, AlphaMask?) in
                    guard let url = CanvasImageWorker.sourceURL(key.asset) else { return (nil,nil) }
                    let image = CanvasImageWorker.decode(url:url,tier:key.tier)
                    let mask = CanvasImageWorker.decode(url:url,tier:192).flatMap(CanvasImageWorker.mask)
                    return (image,mask)
                }.value
                guard let self else { return }
                self.inFlight -= 1; self.requests.remove(key)
                if self.generation == gen, let image = result.0 {
                    self.stamp += 1; let cost = image.bytesPerRow*image.height
                    self.bytes -= self.cache[key]?.cost ?? 0
                    self.cache[key] = Entry(image:image,stamp:self.stamp,cost:cost); self.bytes += cost
                    if self.masks[key.asset] == nil { self.masks[key.asset] = result.1 }
                } else if result.0 == nil, self.failed.insert(key.asset).inserted { self.failure?("Missing sample artwork: \(key.asset). Check the bundled Samples folder.") }
                self.evict(); self.changed?(); self.pump()
            }
        }
    }
    private func evict() {
        for (key,e) in cache.sorted(by: { $0.value.stamp < $1.value.stamp }) where bytes > CanvasConfiguration.cacheBytes && !needed.contains(key) {
            cache[key] = nil; bytes -= e.cost
        }
    }
    func memoryWarning() {
        generation += 1; pressureUntil = Date().addingTimeInterval(20)
        cache.removeAll(); bytes = 0; needed.removeAll(); queue.removeAll(); requests.removeAll(); changed?()
    }
    func hit(_ p: StickerPlacement, product: SampleProduct, point: WorldPoint) -> Bool {
        guard p.bounds.contains(point.cg) else { return false }
        return masks[product.asset]?.hit(u:(point.x-p.bounds.minX)/p.width,v:(point.y-p.bounds.minY)/p.height) ?? true
    }
}
