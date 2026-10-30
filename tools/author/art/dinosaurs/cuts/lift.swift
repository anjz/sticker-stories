// Subject lifting (Vision) on a crop: writes the foreground mask as a grey PNG the crop's size.
// Usage: swift lift.swift in.png out.png (make.py runs it on each crop)
import AppKit
import CoreImage
import Vision

let args = CommandLine.arguments
let url = URL(fileURLWithPath: args[1])
guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { fatalError("read") }
let request = VNGenerateForegroundInstanceMaskRequest()
let handler = VNImageRequestHandler(cgImage: image)
try handler.perform([request])
guard let result = request.results?.first else { fatalError("no subject") }
print("instances:", result.allInstances.count)
let buffer = try result.generateScaledMaskForImage(forInstances: result.allInstances, from: handler)
let ci = CIImage(cvPixelBuffer: buffer)
let ctx = CIContext()
guard let cg = ctx.createCGImage(ci, from: ci.extent) else { fatalError("mask") }
let rep = NSBitmapImageRep(cgImage: cg)
try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2]))
print("ok", cg.width, cg.height)
