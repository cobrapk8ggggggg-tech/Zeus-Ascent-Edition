import Foundation
import CoreGraphics
import CoreText
import ImageIO
import UIKit
import ZeusComicRuntime

enum ComicPixels {
    static func context(width:Int,height:Int)->CGContext?{CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue|CGBitmapInfo.byteOrder32Big.rawValue)}
    static func rgba(_ image:CGImage,width:Int,height:Int)->[UInt8]?{guard let c=context(width:width,height:height)else{return nil};c.interpolationQuality = .high;c.draw(image,in:CGRect(x:0,y:0,width:width,height:height));return c.data.map{Array(UnsafeBufferPointer(start:$0.assumingMemoryBound(to:UInt8.self),count:width*height*4))}}
    static func rotated(_ image:CGImage)->CGImage{guard let c=context(width:image.height,height:image.width)else{return image};c.translateBy(x:CGFloat(image.height),y:0);c.rotate(by:.pi/2);c.draw(image,in:CGRect(x:0,y:0,width:image.width,height:image.height));return c.makeImage() ?? image}
    static func decode(_ data:Data)throws->CGImage{guard let source=CGImageSourceCreateWithData(data as CFData,[kCGImageSourceShouldCache:false]as CFDictionary),let properties=CGImageSourceCopyPropertiesAtIndex(source,0,nil)as? [CFString:Any],let width=properties[kCGImagePropertyPixelWidth]as? Int,let height=properties[kCGImagePropertyPixelHeight]as? Int,width>0,height>0,width<=16_384,Int64(width)*Int64(height)<=16_000_000,let image=CGImageSourceCreateImageAtIndex(source,0,[kCGImageSourceShouldCacheImmediately:true]as CFDictionary)else{throw ComicFailure.message("تعذّر فك الصورة ضمن حد الذاكرة؛ لم تُخفض دقتها بصمت.")};return image}
    static func decodeRegion(_ data:Data,region:ComicRegion,expectedHeight:Int?=nil)throws->CGImage{
        if let source=CGImageSourceCreateWithData(data as CFData,[kCGImageSourceShouldCache:false]as CFDictionary),let properties=CGImageSourceCopyPropertiesAtIndex(source,0,nil)as? [CFString:Any]{
            let width=(properties[kCGImagePropertyPixelWidth]as? NSNumber)?.intValue,height=(properties[kCGImagePropertyPixelHeight]as? NSNumber)?.intValue
            guard width==region.width,expectedHeight==nil||height==expectedHeight else{throw ComicFailure.message("تغيرت أبعاد الصورة؛ لم تُستخدم إحداثيات لا تطابق الأصل.")}
        }
        let pointer=data.withUnsafeBytes{buffer in zeus_comic_decode_region(buffer.bindMemory(to:UInt8.self).baseAddress,UInt(data.count),Int32(region.x),Int32(region.y),Int32(region.width),Int32(region.height))}
        if let pointer{
            let pixels=Data(bytesNoCopy:pointer,count:region.width*region.height*4,deallocator:.custom{p,_ in zeus_comic_free_pixels(p.assumingMemoryBound(to:UInt8.self))})
            guard let provider=CGDataProvider(data:pixels as CFData),let result=CGImage(width:region.width,height:region.height,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:region.width*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.last.rawValue),provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent)else{throw ComicFailure.message("فشل إنشاء منطقة الصورة.")};return result
        }
        let image=try decode(data);guard image.width==region.width,expectedHeight==nil||image.height==expectedHeight,let crop=image.cropping(to:region.rect)else{throw ComicFailure.message("تعذّر فك المنطقة المطلوبة.")};return crop
    }
    static func png(_ image:CGImage)throws->Data{let output=NSMutableData();guard let destination=CGImageDestinationCreateWithData(output,"public.png" as CFString,1,nil)else{throw ComicFailure.message("تعذّر ترميز الصورة.")};CGImageDestinationAddImage(destination,image,nil);guard CGImageDestinationFinalize(destination)else{throw ComicFailure.message("فشل ترميز الصورة.")};return output as Data}
    static func render(_ image:CGImage,speeches:[ComicSpeech],translations:[TranslationSegment],target:String,fontName:String?,fontScale:Double,textColor:String? = nil,ink:ComicInkStyle = .plain,letterSpacing:Double = 0,requireCleanSource:Bool = false)throws->CGImage{
        guard let context=context(width:image.width,height:image.height),var pixels=rgba(image,width:image.width,height:image.height)else{throw ComicFailure.message("ذاكرة غير كافية للرسم.")}
        let original=pixels
        let translated=Dictionary(translations.map{($0.id,$0.text)},uniquingKeysWith:{$1})
        var prepared:[(CGRect,Placement,CGColor)]=[]
        for speech in speeches {
            guard let text=translated[speech.id],!text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else{continue}
            let source=speech.lines.reduce(CGRect.null){$0.union($1.rect)}
            guard !source.isNull else{continue}
            let pad=max(3,min(source.width,source.height)*0.12)
            let area=(speech.balloon ? speech.rect:source.insetBy(dx:-pad,dy:-pad)).intersection(CGRect(x:0,y:0,width:image.width,height:image.height)).integral
            guard area.width>6,area.height>6 else{continue}
            let background=backgroundColor(original,width:image.width,height:image.height,rect:area)
            // Anchor the em size to source glyph height, rather than balloon size.
            // A one-word translation must never grow to fill an entire balloon.
            let heights=speech.lines.map{CGFloat($0.glyphHeight ?? Double(min($0.rect.height,$0.rect.width)))}.sorted()
            let sourceSize=heights[heights.count/2]*1.3
            guard let placed=place(text,area:area,imageHeight:image.height,target:target,fontName:fontName,fontScale:fontScale,theta:CGFloat(speech.angle ?? 0),letterSpacing:letterSpacing,maximumSize:sourceSize)else{continue}
            if requireCleanSource && !canClean(original,width:image.width,height:image.height,speech:speech){continue}
            clean(&pixels,width:image.width,height:image.height,speech:speech)
            let automatic=background.0*0.2126+background.1*0.7152+background.2*0.0722>0.5 ? CGColor(gray:0.04,alpha:1):CGColor(gray:0.98,alpha:1)
            prepared.append((area,placed,textColor.flatMap(Self.color) ?? automatic))
        }
        // Finish every source mask before lettering. A later cleanup pass must
        // never erase an earlier Arabic glyph where source boxes touch.
        if requireCleanSource && prepared.isEmpty{throw ComicFailure.message("لم يُعتمد تنظيف النص كاملًا؛ بقيت الصورة الأصلية دون كتابة ترجمة فوقها.")}
        let data=Data(pixels)
        guard let provider=CGDataProvider(data:data as CFData),let cleaned=CGImage(width:image.width,height:image.height,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:image.width*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedLast.rawValue|CGBitmapInfo.byteOrder32Big.rawValue),provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent)else{throw ComicFailure.message("فشل تجهيز الصورة النظيفة.")}
        context.draw(cleaned,in:CGRect(x:0,y:0,width:image.width,height:image.height))
        for (area,placed,color) in prepared{letter(context,image:image,area:area,placed:placed,color:color,ink:ink)}
        guard let result=context.makeImage()else{throw ComicFailure.message("فشل رسم النص.")};return result
    }
    struct Placement{var layout:TextLayout;var box:CGRect;var theta:CGFloat}
    // Fit the translation inside the speech area. Non-zero theta (diagonal tails,
    // SFX streaks) shrinks the rectangle until its rotated bounding box stays inside;
    // rotated lettering must never paint outside the speech it belongs to.
    private static func place(_ text:String,area:CGRect,imageHeight:Int,target:String,fontName:String?,fontScale:Double,theta:CGFloat,letterSpacing:Double,maximumSize:CGFloat)->Placement?{
        if theta == 0{
            guard let value=layout(text,rect:area.insetBy(dx:2,dy:2),target:target,fontName:fontName,fontScale:fontScale,letterSpacing:letterSpacing,maximumSize:maximumSize)else{return nil}
            return Placement(layout:value,box:CGRect(x:-(area.width-4)/2,y:-value.height/2,width:area.width-4,height:value.height),theta:0)
        }
        var low:CGFloat=0.35,high:CGFloat=1,best:Placement?
        for _ in 0..<7{
            let scale=(low+high)/2,width=(area.width-6)*scale,height=(area.height-6)*scale
            guard width>2,height>2,let value=layout(text,rect:CGRect(x:0,y:0,width:width,height:height),target:target,fontName:fontName,fontScale:fontScale,letterSpacing:letterSpacing,maximumSize:maximumSize)else{high=scale;continue}
            let measured=CTFramesetterSuggestFrameSizeWithConstraints(CTFramesetterCreateWithAttributedString(value.text),CFRange(),nil,CGSize(width:width,height:CGFloat.greatestFiniteMagnitude),nil)
            let boundsWidth=ceil(measured.width)*abs(cos(theta))+ceil(measured.height)*abs(sin(theta)),boundsHeight=ceil(measured.width)*abs(sin(theta))+ceil(measured.height)*abs(cos(theta))
            if boundsWidth<=area.width-2,boundsHeight<=area.height-2{low=scale;best=Placement(layout:value,box:CGRect(x:-width/2,y:-value.height/2,width:width,height:value.height),theta:theta)}else{high=scale}
        }
        return best
    }
    // Draw one speech with the chosen ink. All passes share the same frame path so
    // stroke, shadow and fill stay perfectly registered on every font and rotation.
    private static func letter(_ context:CGContext,image:CGImage,area:CGRect,placed:Placement,color:CGColor,ink:ComicInkStyle){
        context.saveGState();context.textMatrix = .identity
        context.translateBy(x:area.midX,y:CGFloat(image.height)-area.midY)
        context.clip(to:CGRect(x:-area.width/2,y:-area.height/2,width:area.width,height:area.height))
        if placed.theta != 0{context.rotate(by:-placed.theta)}
        let attributed=NSMutableAttributedString(attributedString:placed.layout.text);attributed.addAttribute(NSAttributedString.Key(kCTForegroundColorAttributeName as String),value:color,range:NSRange(location:0,length:attributed.length))
        func draw(_ value:NSAttributedString){let frame=CTFramesetterCreateFrame(CTFramesetterCreateWithAttributedString(value),CFRange(),CGPath(rect:placed.box,transform:nil),nil);CTFrameDraw(frame,context)}
        switch ink{
        case .plain:draw(attributed)
        case .shadow:
            // Soft drop copy under the glyphs: readable over gradients and SFX.
            context.saveGState();context.translateBy(x:1.5,y:-1.5)
            let shade=NSMutableAttributedString(attributedString:attributed);shade.addAttribute(NSAttributedString.Key(kCTForegroundColorAttributeName as String),value:CGColor(gray:0,alpha:0.55),range:NSRange(location:0,length:shade.length));draw(shade);context.restoreGState();draw(attributed)
        case .outline:
            // Manga lettering: stroke the opposite ink first, then fill on top.
            let stroke=NSMutableAttributedString(attributedString:attributed);stroke.addAttribute(NSAttributedString.Key(kCTStrokeWidthAttributeName as String),value:12.0,range:NSRange(location:0,length:stroke.length));stroke.addAttribute(NSAttributedString.Key(kCTStrokeColorAttributeName as String),value:contrast(color),range:NSRange(location:0,length:stroke.length));draw(stroke);draw(attributed)
        }
        context.restoreGState()
    }
    private static func contrast(_ color:CGColor)->CGColor{
        let components=color.converted(to:CGColorSpace(name:CGColorSpace.sRGB)!,intent:.defaultIntent,options:nil)?.components ?? [1]
        let luminance=components.count>=3 ? 0.2126*components[0]+0.7152*components[1]+0.0722*components[2]:components.first ?? 1
        return luminance>0.5 ? CGColor(gray:0,alpha:1):CGColor(gray:1,alpha:1)
    }
    static func color(_ hex:String)->CGColor?{let value=hex.replacingOccurrences(of:"#",with:"");guard value.count==6,let n=UInt32(value,radix:16)else{return nil};return CGColor(red:CGFloat((n>>16)&255)/255,green:CGFloat((n>>8)&255)/255,blue:CGFloat(n&255)/255,alpha:1)}
    struct TextLayout{var text:NSAttributedString;var height:CGFloat;var size:CGFloat}
    static func layout(_ text:String,rect:CGRect,target:String,fontName:String?,fontScale:Double,letterSpacing:Double = 0,maximumSize:CGFloat = 96)->TextLayout?{
        guard rect.width>2,rect.height>2 else{return nil}
        let style=NSMutableParagraphStyle();style.alignment = .center;style.baseWritingDirection=TranslationPreferences.rtl(target) ? .rightToLeft:.leftToRight;style.lineBreakMode = .byWordWrapping
        // GeezaPro is iOS's native Arabic face: ArialMT defeats Arabic shaping inside
        // narrow balloons, so Arabic targets fall back to it unless a font is chosen.
        let resolved=fontName ?? (target.hasPrefix("ar") ? "GeezaPro":"ArialMT")
        var low:CGFloat=4,high=min(96,rect.height,maximumSize*CGFloat(min(1.5,max(0.5,fontScale)))) ,best:TextLayout?
        for _ in 0..<9{let size=(low+high)/2,font=CTFontCreateWithName(resolved as CFString,size,nil)
            let value=NSAttributedString(string:text,attributes:[NSAttributedString.Key(kCTFontAttributeName as String):font,.paragraphStyle:style,.kern:min(4,max(-1,letterSpacing))])
            let setter=CTFramesetterCreateWithAttributedString(value);var fit=CFRange();let measured=CTFramesetterSuggestFrameSizeWithConstraints(setter,CFRange(),nil,CGSize(width:rect.width,height:CGFloat.greatestFiniteMagnitude),&fit)
            if measured.height<=rect.height && measured.width<=rect.width+0.5 && fit.length==value.length{best=TextLayout(text:value,height:ceil(measured.height),size:size);low=size}else{high=size}
        }
        guard let best else{return nil}
        return best
    }
    private static func backgroundColor(_ pixels:[UInt8],width:Int,height:Int,rect:CGRect)->(CGFloat,CGFloat,CGFloat){
        var bins:[Int:(Int,Int,Int,Int)]=[:]
        let x0=max(0,Int(rect.minX)-3),x1=min(width-1,Int(rect.maxX)+3),y0=max(0,Int(rect.minY)-3),y1=min(height-1,Int(rect.maxY)+3)
        guard x1>=x0,y1>=y0 else{return(1,1,1)}
        for y in y0...y1{for x in x0...x1 where x<x0+3||x>x1-3||y<y0+3||y>y1-3{let i=(y*width+x)*4,r=Int(pixels[i]),g=Int(pixels[i+1]),b=Int(pixels[i+2]),key=(r/32)*64+(g/32)*8+b/32,old=bins[key] ?? (0,0,0,0);bins[key]=(old.0+r,old.1+g,old.2+b,old.3+1)}}
        guard let value=bins.values.max(by:{$0.3<$1.3}),value.3>0 else{return(1,1,1)}
        return(CGFloat(value.0)/CGFloat(value.3*255),CGFloat(value.1)/CGFloat(value.3*255),CGFloat(value.2)/CGFloat(value.3*255))
    }
    static func canClean(_ pixels:[UInt8],width:Int,height:Int,speech:ComicSpeech)->Bool{
        var source=pixels,mask=[UInt8](repeating:0,count:width*height)
        source.withUnsafeMutableBufferPointer{buffer in
            mask.withUnsafeMutableBufferPointer{m in
                for box in cleanupBoxes(width:width,height:height,speech:speech){
                    zeus_comic_text_mask(buffer.baseAddress,m.baseAddress,Int32(width),Int32(height),Int32(box.minX),Int32(box.minY),Int32(box.maxX),Int32(box.maxY))
                }
            }
        }
        return pixels.withUnsafeBufferPointer{buffer in mask.withUnsafeBufferPointer{m in
            speech.lines.allSatisfy{line in let b=line.rect.integral
                return zeus_comic_mask_coverage(buffer.baseAddress,m.baseAddress,Int32(width),Int32(height),Int32(b.minX),Int32(b.minY),Int32(b.maxX),Int32(b.maxY))>=0.95
            }
        }}
    }
    private static func cleanupBoxes(width:Int,height:Int,speech:ComicSpeech)->[CGRect]{
        let bounds=CGRect(x:1,y:1,width:max(0,width-2),height:max(0,height-2))
        let protected=speech.balloon ? speech.rect:bounds
        var boxes:[CGRect]=[]
        for line in speech.lines{
            // Include outlines, antialiasing and shadows outside tight OCR boxes.
            let pad=max(3,min(line.rect.height,line.rect.width)*0.18)
            var box=line.rect.insetBy(dx:-pad,dy:-pad).integral.intersection(protected).intersection(bounds)
            guard !box.isNull,box.width>2,box.height>2 else{continue}
            while let index=boxes.firstIndex(where:{!$0.intersection(box).isNull}){
                box=box.union(boxes.remove(at:index))
            }
            boxes.append(box)
        }
        return boxes
    }
    static func clean(_ pixels:inout [UInt8],width:Int,height:Int,speech:ComicSpeech){
        let boxes=cleanupBoxes(width:width,height:height,speech:speech)
        let source=pixels
        source.withUnsafeBufferPointer{original in
            pixels.withUnsafeMutableBufferPointer{buffer in
                for box in boxes{zeus_comic_inpaint_from_source(original.baseAddress,buffer.baseAddress,Int32(width),Int32(height),Int32(box.minX),Int32(box.minY),Int32(box.maxX),Int32(box.maxY))}
            }
        }
    }
}
