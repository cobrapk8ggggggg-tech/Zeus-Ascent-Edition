import Foundation
import CoreGraphics
import ZeusComicRuntime

/// Recover closed, nearly uniform balloon interiors around recognised lines.
/// The search is bounded; textured/open regions keep their OCR geometry.
enum ComicBalloons {
    static func speeches(_ lines:[ComicLine],image:CGImage,source:String)->[ComicSpeech]{
        guard let pixels=ComicPixels.rgba(image,width:image.width,height:image.height)else{return ComicGeometry.group(lines,source:source)}
        let lines=ComicGeometry.uniqueLines(lines)
        var plates:[Plate]=[]
        // Probe paragraphs as well as individual lines: a small line's search
        // window can end inside a large balloon and miss its enclosure.
        let probes=ComicGeometry.group(lines,source:source).map(\.rect)+lines.map(\.rect)
        for probe in probes{
            guard let plate=closedInterior(probe,pixels:pixels,width:image.width,height:image.height,textBounds:lines.map(\.rect))else{continue}
            if let index=plates.firstIndex(where:{overlap($0.rect,plate.rect)>0.7}){
                if plate.rect.width*plate.rect.height>plates[index].rect.width*plates[index].rect.height{plates[index]=plate}
            }else{plates.append(plate)}
        }
        // Give every OCR line exactly one owner, including lines whose own
        // flood-fill failed. Otherwise the balloon and an orphan line both draw.
        var owned=[[ComicLine]](repeating:[],count:plates.count),unplated:[ComicLine]=[]
        for line in lines{
            let candidates=plates.indices.filter{plates[$0].rect.insetBy(dx:2,dy:2).contains(line.rect)}
            if let index=candidates.min(by:{plates[$0].rect.width*plates[$0].rect.height<plates[$1].rect.width*plates[$1].rect.height}){owned[index].append(line)}else{unplated.append(line)}
        }
        var result:[ComicSpeech]=[]
        for index in plates.indices{
            let plate=plates[index],lines=owned[index]
            guard !lines.isEmpty else{continue}
            for (lines,lobe) in split(lines,plate:plate){
                let vertical=lines.allSatisfy{$0.rect.height>$0.rect.width*1.5}
                let ordered=ComicGeometry.orderedLines(lines,vertical:vertical)
                let area=safeRectangle(lobe,plate:plate,lines:lines)
                result.append(ComicSpeech(id:"",text:ordered.map(\.text).joined(separator:vertical ? "":" "),lines:ordered,rect:area,vertical:vertical,balloon:true,flatCleanup:flatCleanup(plate,lines:lines,lobe:lobe,pixels:pixels,width:image.width,height:image.height),angle:vertical ? nil:ComicGeometry.estimateAngle(lines),balloonBounds:lobe))
            }
        }
        result+=ComicGeometry.group(unplated,source:source)
        result.sort{a,b in if abs(a.rect.minY-b.rect.minY)<min(a.rect.height,b.rect.height)*0.35{return source.hasPrefix("ja") ? a.rect.midX>b.rect.midX:a.rect.midX<b.rect.midX};return a.rect.minY<b.rect.minY}
        return result.enumerated().map{i,s in var s=s;s.id=String(i);return s}
    }
    private static func safeRectangle(_ lobe:CGRect,plate:Plate,lines:[ComicLine])->CGRect{
        let origin=CGPoint(x:plate.rect.minX-1,y:plate.rect.minY-1),area=lobe.offsetBy(dx:-origin.x,dy:-origin.y).integral
        let boxes:[Int32]=lines.flatMap{line in let r=line.rect.offsetBy(dx:-origin.x,dy:-origin.y);return [Int32(floor(r.minX)),Int32(floor(r.minY)),Int32(ceil(r.maxX)),Int32(ceil(r.maxY))]}
        var output=[Int32](repeating:0,count:4)
        let valid=plate.mask.withUnsafeBufferPointer{p in boxes.withUnsafeBufferPointer{b in output.withUnsafeMutableBufferPointer{o in zeus_comic_lettering_box(p.baseAddress,Int32(plate.width),Int32(plate.height),Int32(area.minX),Int32(area.minY),Int32(area.maxX),Int32(area.maxY),b.baseAddress,Int32(lines.count),o.baseAddress) != 0}}}
        if valid{return CGRect(x:CGFloat(output[0])+origin.x,y:CGFloat(output[1])+origin.y,width:CGFloat(output[2]-output[0]),height:CGFloat(output[3]-output[1]))}
        return lines.reduce(CGRect.null){$0.union($1.rect)}.insetBy(dx:-3,dy:-3).intersection(lobe.insetBy(dx:2,dy:2))
    }
    private static func overlap(_ a:CGRect,_ b:CGRect)->CGFloat{let intersection=a.intersection(b);guard !intersection.isNull else{return 0};return intersection.width*intersection.height/max(1,min(a.width*a.height,b.width*b.height))}
    private struct Plate{var rect:CGRect;var mask:[UInt8];var width:Int;var height:Int;var color:[UInt8];var uniform:Bool}
    private static func flatCleanup(_ plate:Plate,lines:[ComicLine],lobe:CGRect,pixels:[UInt8],width:Int,height:Int)->ComicFlatCleanup?{
        let x=Int(plate.rect.minX)-1,y=Int(plate.rect.minY)-1
        let area=lobe.offsetBy(dx:-CGFloat(x),dy:-CGFloat(y)).integral
        let boxes:[Int32]=lines.flatMap{line in
            let pad=max(8,min(line.rect.width,line.rect.height)*0.3),r=line.rect.insetBy(dx:-pad,dy:-pad)
            return [Int32(floor(r.minX)-CGFloat(x)),Int32(floor(r.minY)-CGFloat(y)),Int32(ceil(r.maxX)-CGFloat(x)),Int32(ceil(r.maxY)-CGFloat(y))]
        }
        var mask=[UInt8](repeating:0,count:plate.width*plate.height)
        var complete=plate.mask.withUnsafeBufferPointer{p in boxes.withUnsafeBufferPointer{b in mask.withUnsafeMutableBufferPointer{m in zeus_comic_flat_balloon_mask(p.baseAddress,m.baseAddress,Int32(plate.width),Int32(plate.height),Int32(area.minX),Int32(area.minY),Int32(area.maxX),Int32(area.maxY),b.baseAddress,Int32(lines.count)) != 0}}}
        if complete{
            var source:[UInt8]=[];source.reserveCapacity(plate.width*plate.height*4)
            for yy in 0..<plate.height{let start=((yy+y)*width+x)*4;source.append(contentsOf:pixels[start..<start+plate.width*4])}
            complete=source.withUnsafeBufferPointer{p in mask.withUnsafeBufferPointer{m in lines.allSatisfy{line in
                let r=line.rect.offsetBy(dx:-CGFloat(x),dy:-CGFloat(y)).integral
                return zeus_comic_mask_coverage(p.baseAddress,m.baseAddress,Int32(plate.width),Int32(plate.height),Int32(r.minX),Int32(r.minY),Int32(r.maxX),Int32(r.maxY))>=0.95
            }}}
        }
        if !plate.uniform && !complete{return nil}
        var runs:[Int]=[]
        if complete{for yy in 0..<plate.height{
            var xx=0
            while xx<plate.width{
                guard mask[yy*plate.width+xx]>0 else{xx+=1;continue}
                let start=xx
                while xx<plate.width&&mask[yy*plate.width+xx]>0{xx+=1}
                runs += [start+x,yy+y,xx-start]
            }
        }}
        return ComicFlatCleanup(color:plate.color,uniform:plate.uniform,runs:runs,complete:complete)
    }
    // A line may contain words from both connected balloons. Only split that
    // line when its measured word boxes acquire different shape owners.
    private static func split(_ lines:[ComicLine],plate:Plate)->[([ComicLine],CGRect)]{
        let origin=CGPoint(x:plate.rect.minX-1,y:plate.rect.minY-1)
        let atoms=lines.flatMap{line -> [ComicLine] in
            guard let words=line.words,words.count>1 else{return [line]}
            return words.map{ComicLine(text:$0.text,confidence:line.confidence,rect:$0.rect,angle:line.angle,glyphHeight:line.glyphHeight)}
        }
        let boxes:[Int32]=atoms.flatMap{r in [Int32(floor(r.rect.minX-origin.x)),Int32(floor(r.rect.minY-origin.y)),Int32(ceil(r.rect.maxX-origin.x)),Int32(ceil(r.rect.maxY-origin.y))]}
        var owners=[Int32](repeating:0,count:atoms.count),bounds=[Int32](repeating:0,count:atoms.count*4)
        let count=plate.mask.withUnsafeBufferPointer{m in boxes.withUnsafeBufferPointer{b in owners.withUnsafeMutableBufferPointer{o in bounds.withUnsafeMutableBufferPointer{r in zeus_comic_balloon_lobes(m.baseAddress,Int32(plate.width),Int32(plate.height),b.baseAddress,Int32(atoms.count),o.baseAddress,r.baseAddress)}}}}
        guard count>1 else{return [(lines,plate.rect)]}
        var groups=[[ComicLine]](repeating:[],count:Int(count)),cursor=0
        for line in lines{
            let size=max(1,line.words?.count ?? 0),assigned=Set(owners[cursor..<cursor+size])
            if assigned.count==1,let owner=assigned.first{groups[Int(owner)].append(line)}
            else{
                for owner in assigned{
                    let fragments=(cursor..<cursor+size).filter{owners[$0]==owner}.map{atoms[$0]}
                    let vertical=line.rect.height>line.rect.width*1.5
                    let ordered=ComicGeometry.orderedLines(fragments,vertical:vertical)
                    var fragment=line
                    fragment.text=ordered.map(\.text).joined(separator:line.text.contains(where:{$0.isWhitespace}) ? " ":"")
                    fragment.rect=fragments.reduce(CGRect.null){$0.union($1.rect)}
                    fragment.words=ordered.map{ComicWord(text:$0.text,rect:$0.rect)}
                    groups[Int(owner)].append(fragment)
                }
            }
            cursor+=size
        }
        return groups.indices.compactMap{i in
            guard !groups[i].isEmpty else{return nil}
            let r=bounds[i*4..<i*4+4].map{CGFloat($0)}
            return (groups[i],CGRect(x:r[0]+origin.x,y:r[1]+origin.y,width:r[2]-r[0],height:r[3]-r[1]).intersection(plate.rect))
        }
    }
    static func interior(_ text:CGRect,pixels:[UInt8],width:Int,height:Int)->CGRect?{closedInterior(text,pixels:pixels,width:width,height:height)?.rect}
    private static func closedInterior(_ text:CGRect,pixels:[UInt8],width:Int,height:Int,textBounds:[CGRect] = [])->Plate?{
        guard text.width>2,text.height>2,pixels.count>=width*height*4 else{return nil}
        var margin=min(600,max(240,max(text.width*1.6,text.height*4)))
        var roi=text.insetBy(dx:-margin,dy:-margin).integral.intersection(CGRect(x:0,y:0,width:width,height:height))
        while roi.width*roi.height>1_000_000 && margin>16{
            margin*=0.85
            roi=text.insetBy(dx:-margin,dy:-margin).integral.intersection(CGRect(x:0,y:0,width:width,height:height))
        }
        guard !roi.isNull,roi.width*roi.height<=1_000_000 else{return nil}
        let left=Int(roi.minX),top=Int(roi.minY),rw=Int(roi.width),rh=Int(roi.height)
        var bins:[Int:(Int,Int,Int,Int)]=[:],seeds:[Int]=[]
        for yy in 0..<7{for xx in 0..<7{let x=min(width-1,max(0,Int(text.minX+text.width*CGFloat(xx+1)/8))),y=min(height-1,max(0,Int(text.minY+text.height*CGFloat(yy+1)/8))),i=(y*width+x)*4
            let r=Int(pixels[i]),g=Int(pixels[i+1]),b=Int(pixels[i+2]),key=(r/32)*64+(g/32)*8+b/32,old=bins[key] ?? (0,0,0,0);bins[key]=(old.0+r,old.1+g,old.2+b,old.3+1);seeds.append((y-top)*rw+x-left)}}
        guard let background=bins.values.max(by:{$0.3<$1.3})else{return nil}
        let red=background.0/background.3,green=background.1/background.3,blue=background.2/background.3
        func matches(_ index:Int)->Bool{let p=((index/rw+top)*width+index%rw+left)*4;return abs(Int(pixels[p])-red)+abs(Int(pixels[p+1])-green)+abs(Int(pixels[p+2])-blue)<75}
        var seen=[UInt8](repeating:0,count:rw*rh),best:Plate?
        let maximum=min(800_000,Int(roi.width*roi.height))
        for seed in seeds where seed>=0&&seed<seen.count&&seen[seed]==0&&matches(seed){
            var queue=[seed],head=0,minX=seed%rw,maxX=minX,minY=seed/rw,maxY=minY
            seen[seed]=1
            while head<queue.count&&queue.count<=maximum{let current=queue[head];head+=1;let x=current%rw,y=current/rw
                minX=min(minX,x);maxX=max(maxX,x);minY=min(minY,y);maxY=max(maxY,y)
                if x==0||y==0||x==rw-1||y==rh-1{return nil}
                for(dx,dy)in [(-1,0),(1,0),(0,-1),(0,1)]{let nx=x+dx,ny=y+dy;if nx>=0&&nx<rw&&ny>=0&&ny<rh{let n=ny*rw+nx;if seen[n]==0&&matches(n){seen[n]=1;queue.append(n)}}}
            }
            guard queue.count<=maximum,CGFloat(queue.count)>text.width*text.height*0.5 else{continue}
            let bounds=CGRect(x:left+minX,y:top+minY,width:maxX-minX+1,height:maxY-minY+1)
            if bounds.insetBy(dx:-2,dy:-2).contains(text),best==nil||bounds.width*bounds.height>best!.rect.width*best!.rect.height{
                let mw=maxX-minX+3,mh=maxY-minY+3
                var mask=[UInt8](repeating:0,count:mw*mh)
                for p in queue{mask[(p/rw-minY+1)*mw+p%rw-minX+1]=255}
                let exclusions:[Int32]=(textBounds.isEmpty ? [text]:textBounds).flatMap{r in [Int32(floor(r.minX)-4),Int32(floor(r.minY)-4),Int32(ceil(r.maxX)+4),Int32(ceil(r.maxY)+4)]}
                let edge=pixels.withUnsafeBufferPointer{p in mask.withUnsafeBufferPointer{m in exclusions.withUnsafeBufferPointer{b in zeus_comic_plate_has_edge(p.baseAddress,Int32(width),Int32(height),m.baseAddress,Int32(mw),Int32(mh),Int32(bounds.minX)-1,Int32(bounds.minY)-1,b.baseAddress,Int32(exclusions.count/4)) != 0}}}
                guard edge else{continue}
                var color=[UInt8](repeating:0,count:3)
                let uniform=pixels.withUnsafeBufferPointer{p in mask.withUnsafeBufferPointer{m in color.withUnsafeMutableBufferPointer{c in zeus_comic_plate_color(p.baseAddress,Int32(width),Int32(height),m.baseAddress,Int32(mw),Int32(mh),Int32(bounds.minX)-1,Int32(bounds.minY)-1,c.baseAddress) != 0}}}
                best=Plate(rect:bounds,mask:mask,width:mw,height:mh,color:color,uniform:uniform)
            }
        }
        return best
    }
}
