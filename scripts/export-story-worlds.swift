import AppKit
import ImageIO
import UniformTypeIdentifiers
let source=URL(fileURLWithPath:"macos/Resources/Library/story-worlds-v1.png")
guard let input=CGImageSourceCreateWithURL(source as CFURL,nil),let atlas=CGImageSourceCreateImageAtIndex(input,0,nil) else {fatalError("Missing illustrated worlds")}
let ids=["forest","stars","ocean","friends","magic","cozy"]
for (index,id) in ids.enumerated() {
    let cell=CGRect(x:(index%3)*atlas.width/3,y:(index/3)*atlas.height/2,width:atlas.width/3,height:atlas.height/2)
    guard let image=atlas.cropping(to:cell) else{fatalError("Invalid atlas cell")}
    for suffix in ["","-vision"] {
        let url=URL(fileURLWithPath:"macos/Resources/Scenes/world-\(id)\(suffix).png")
        guard let out=CGImageDestinationCreateWithURL(url as CFURL,UTType.png.identifier as CFString,1,nil) else {fatalError("Cannot save world")}
        CGImageDestinationAddImage(out,image,nil);guard CGImageDestinationFinalize(out) else{fatalError("Incomplete world")}
    }
}
print("Prepared six illustrated story worlds.")
