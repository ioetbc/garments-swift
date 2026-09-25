// Run with: swift ios/tools/generate-fixtures.swift <output directory>
import AppKit
import ImageIO
import UniformTypeIdentifiers
let out = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
let names = ["top", "jacket", "trousers", "shoes", "bag", "scarf"]
let ratios: [Double] = [1.2,0.94,0.65,1.8,0.92,1]
let colors: [NSColor] = [.init(srgbRed:0.86,green:0.83,blue:0.74,alpha:1), .systemYellow, .init(srgbRed:0.15,green:0.26,blue:0.41,alpha:1), .white, .init(srgbRed:0.19,green:0.37,blue:0.28,alpha:1), .systemOrange]
for i in 0..<names.count {
 let k = i % 6, edge = [512,1024,1536][i % 3]
 let w = Int(Double(edge)*min(1,ratios[k])), h = Int(Double(edge)/max(1,ratios[k]))
 let ctx = CGContext(data:nil,width:w,height:h,bitsPerComponent:8,bytesPerRow:w*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
 ctx.scaleBy(x:CGFloat(w)/100,y:CGFloat(h)/100)
 ctx.setFillColor(colors[k].cgColor)
 func polygon(_ points: [CGPoint]) { ctx.beginPath(); ctx.move(to: points[0]); for p in points.dropFirst() { ctx.addLine(to:p) }; ctx.closePath(); ctx.fillPath() }
 switch k {
 case 0,1: polygon([.init(x:0,y:70),.init(x:18,y:94),.init(x:37,y:100),.init(x:42,y:91),.init(x:58,y:91),.init(x:63,y:100),.init(x:82,y:94),.init(x:100,y:70),.init(x:80,y:57),.init(x:74,y:70),.init(x:74,y:0),.init(x:26,y:0),.init(x:26,y:70),.init(x:20,y:57)])
 case 2: polygon([.init(x:15,y:100),.init(x:85,y:100),.init(x:100,y:0),.init(x:59,y:0),.init(x:50,y:59),.init(x:41,y:0),.init(x:0,y:0)])
 case 3: ctx.fillEllipse(in:CGRect(x:0,y:0,width:100,height:42)); ctx.fillEllipse(in:CGRect(x:0,y:58,width:100,height:42))
 case 4: ctx.fill(CGRect(x:0,y:0,width:100,height:64)); ctx.setStrokeColor(colors[k].cgColor); ctx.setLineWidth(10); ctx.strokeEllipse(in:CGRect(x:24,y:48,width:52,height:47))
 default: ctx.fill(CGRect(x:0,y:0,width:100,height:100))
 }
 ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.18).cgColor); ctx.setLineWidth(1.4)
 for j in 1...4 { ctx.move(to:CGPoint(x:30+j*8,y:5)); ctx.addLine(to:CGPoint(x:30+j*8,y:k == 2 ? 95 : 62)); ctx.strokePath() }
 if k == 1 { ctx.setStrokeColor(NSColor.brown.cgColor); ctx.move(to:CGPoint(x:50,y:0)); ctx.addLine(to:CGPoint(x:50,y:91)); ctx.strokePath(); ctx.stroke(CGRect(x:57,y:44,width:12,height:17)) }
 if k == 5 { ctx.setStrokeColor(NSColor.white.cgColor); ctx.setLineWidth(3); ctx.stroke(CGRect(x:7,y:7,width:86,height:86)) }
 let name = names[k]
 let dest = CGImageDestinationCreateWithURL(out.appendingPathComponent(name+".png") as CFURL,UTType.png.identifier as CFString,1,nil)!
 CGImageDestinationAddImage(dest,ctx.makeImage()!,nil); CGImageDestinationFinalize(dest)
}
