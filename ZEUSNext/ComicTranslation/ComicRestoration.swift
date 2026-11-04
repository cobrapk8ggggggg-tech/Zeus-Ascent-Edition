import Foundation
import CoreGraphics
import OnnxRuntimeBindings
import ZeusComicRuntime

/// Sequential model execution bounds peak memory: CTD and LaMa never coexist.
/// Model output is composited only inside the validated, source-resolution ink mask.
actor ComicRestoration {
    static let shared = ComicRestoration()
    struct Result { var image: CGImage; var restored: Set<String>; var notice: String?; var retryable=false }
    private let environment = try! ORTEnv(loggingLevel: .error)
    private var current: ORTSession?
    private var currentName:String?
    private(set) var sessionLoads=0
    private var busy=false
    private var waiting:[UUID:CheckedContinuation<Void,Error>]=[:]
    private var minimumHeadroom:UInt64=1_200_000_000
    private func enqueue(_ id:UUID)async throws{
        try Task.checkCancellation()
        if !busy{return}
        try await withCheckedThrowingContinuation{(c:CheckedContinuation<Void,Error>) in waiting[id]=c}
    }
    private func cancelWaiting(_ id:UUID){waiting.removeValue(forKey:id)?.resume(throwing:CancellationError())}
    private func acquire()async throws{
        while busy{
            let id=UUID()
            try await withTaskCancellationHandler(operation:{try await self.enqueue(id)},onCancel:{Task{await self.cancelWaiting(id)}})
        }
        try Task.checkCancellation();busy=true
    }
    private func release(){busy=false;let pending=Array(waiting.values);waiting.removeAll();for task in pending{task.resume()}}
    func purge() { current = nil;currentName=nil }
    func prepare() async throws {
        for file in ["ctd.onnx", "lama.onnx"] {
            _ = try await ComicModelStore.shared.file(file, download: true)
            try Task.checkCancellation()
        }
    }
    private func session(_ name: String) async throws -> ORTSession {
        if currentName==name,let current{return current}
        current = nil;currentName=nil
        if zeus_comic_available_memory()<(name=="lama.onnx" ? minimumHeadroom:minimumHeadroom/2){throw ComicFailure.message("لم تتوفر ذاكرة كافية لترميم الخلفية؛ بقي الأصل.")}
        let url = try await ComicModelStore.shared.file(name, download: false)
        let options = try ORTSessionOptions()
        try options.setIntraOpNumThreads(2)
        try options.setGraphOptimizationLevel(.all)
        let value = try ORTSession(env: environment, modelPath: url.path, sessionOptions: options)
        current = value;currentName=name;sessionLoads+=1
        return value
    }
    private func tensor(_ floats: [Float], shape: [NSNumber]) throws -> ORTValue {
        let bytes = floats.withUnsafeBufferPointer { NSMutableData(bytes: $0.baseAddress!, length: $0.count * MemoryLayout<Float>.size) }
        return try ORTValue(tensorData: bytes, elementType: .float, shape: shape)
    }
    private func floats(_ value: ORTValue, count: Int) throws -> [Float] {
        let data = try value.tensorData()
        guard data.length == count * MemoryLayout<Float>.size else { throw ComicFailure.message("أبعاد خرج نموذج الترميم غير صالحة.") }
        return Array(UnsafeBufferPointer(start: data.bytes.assumingMemoryBound(to: Float.self), count: count))
    }
    // Copy RGB into a top-left letterbox. Reflection supplies LaMa context; CTD
    // uses black padding, matching its pinned reference preprocessing.
    private func input(_ rgba: [UInt8], width: Int, height: Int, edge: Int, reflected: Bool) -> (values: [Float], width: Int, height: Int) {
        let scale = min(Double(edge) / Double(width), Double(edge) / Double(height))
        let w = max(1, Int((Double(width) * scale).rounded())), h = max(1, Int((Double(height) * scale).rounded()))
        var result = [Float](repeating: 0, count: edge * edge * 3)
        func reflect(_ value: Int, _ limit: Int) -> Int {
            if limit <= 1 { return 0 }
            let period = 2 * (limit - 1), p = value % period
            return p < limit ? p : period - p
        }
        for y in 0..<edge { for x in 0..<edge {
            if !reflected && (x >= w || y >= h) { continue }
            let xx = reflected ? reflect(x, w) : x, yy = reflected ? reflect(y, h) : y
            let fx=max(0,min(Double(width-1),(Double(xx)+0.5)*Double(width)/Double(w)-0.5)),fy=max(0,min(Double(height-1),(Double(yy)+0.5)*Double(height)/Double(h)-0.5))
            let x0=Int(floor(fx)),y0=Int(floor(fy)),x1=min(width-1,x0+1),y1=min(height-1,y0+1),dx=Float(fx-Double(x0)),dy=Float(fy-Double(y0))
            for c in 0..<3 {
                func v(_ x:Int,_ y:Int)->Float{Float(rgba[(y*width+x)*4+c])/255}
                result[c*edge*edge+y*edge+x]=(v(x0,y0)*(1-dx)+v(x1,y0)*dx)*(1-dy)+(v(x0,y1)*(1-dx)+v(x1,y1)*dx)*dy
            }
        } }
        return (result, w, h)
    }
    private func hints(_ rgba: [UInt8], width: Int, height: Int) async throws -> [UInt8] {
        let a = input(rgba, width: width, height: height, edge: 1024, reflected: false)
        let s = try await session("ctd.onnx")
        let names = try s.outputNames(), inputs = try s.inputNames()
        guard names.count == 3, let name = inputs.first else { throw ComicFailure.message("واجهة كاشف حبر النص غير صالحة.") }
        let output = try s.run(withInputs: [name: tensor(a.values, shape: [1,3,1024,1024])], outputNames: Set([names[1]]), runOptions: nil)
        let values = try floats(output[names[1]]!, count: 1024 * 1024)
        var mask = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height { for x in 0..<width {
            let sx = min(a.width - 1, x * a.width / width), sy = min(a.height - 1, y * a.height / height)
            if values[sy * 1024 + sx] > 0.3 { mask[y * width + x] = 255 }
        } }
        return mask
    }
    private func inpaint(_ rgba: [UInt8], mask: [UInt8], width: Int, height: Int) async throws -> [UInt8] {
        let a = input(rgba, width: width, height: height, edge: 512, reflected: true)
        var m = [Float](repeating: 0, count: 512 * 512)
        for y in 0..<a.height { for x in 0..<a.width {
            let sx = min(width - 1, x * width / a.width), sy = min(height - 1, y * height / a.height)
            m[y * 512 + x] = mask[sy * width + sx] > 0 ? 1 : 0
        } }
        let s = try await session("lama.onnx"), names = try s.outputNames()
        guard let name = names.first else { throw ComicFailure.message("واجهة نموذج الترميم غير صالحة.") }
        let output = try s.run(withInputs: ["image": tensor(a.values, shape: [1,3,512,512]), "mask": tensor(m, shape: [1,1,512,512])], outputNames: Set([name]), runOptions: nil)
        let values = try floats(output[name]!, count: 512 * 512 * 3)
        var result = rgba
        for y in 0..<height { for x in 0..<width where mask[y * width + x] > 0 {
            let fx = min(Double(a.width - 1), (Double(x) + 0.5) * Double(a.width) / Double(width) - 0.5)
            let fy = min(Double(a.height - 1), (Double(y) + 0.5) * Double(a.height) / Double(height) - 0.5)
            let x0 = max(0, Int(floor(fx))), y0 = max(0, Int(floor(fy))), x1 = min(a.width - 1, x0 + 1), y1 = min(a.height - 1, y0 + 1)
            let dx = Float(max(0, fx - Double(x0))), dy = Float(max(0, fy - Double(y0)))
            for c in 0..<3 {
                func v(_ x: Int, _ y: Int) -> Float { values[c * 512 * 512 + y * 512 + x] }
                let value = (v(x0,y0)*(1-dx)+v(x1,y0)*dx)*(1-dy)+(v(x0,y1)*(1-dx)+v(x1,y1)*dx)*dy
                guard value.isFinite else { throw ComicFailure.message("خرج نموذج الترميم غير سليم؛ بقي الأصل.") }
                result[(y * width + x) * 4 + c] = UInt8(max(0,min(255,value.rounded())))
            }
        } }
        return result
    }
    private struct MaskedCrop{var id:String;var pixels:[UInt8];var mask:[UInt8];var bounds:CGRect;var width:Int;var height:Int;var boxes:[CGRect];var protected:CGRect;var retryMargin:Int}
    private func grow(_ mask:inout [UInt8],width:Int,height:Int,area:CGRect,radius:Int){
        mask.withUnsafeMutableBufferPointer{m in zeus_comic_grow_text_mask(m.baseAddress,Int32(width),Int32(height),Int32(area.minX),Int32(area.minY),Int32(area.maxX),Int32(area.maxY),Int32(radius))}
    }
    private func reconstructed(_ job:MaskedCrop,mask:[UInt8])async throws->[UInt8]{
        let r=job.protected
        let simple=job.pixels.withUnsafeBufferPointer{p in mask.withUnsafeBufferPointer{m in zeus_comic_simple_background(p.baseAddress,m.baseAddress,Int32(job.width),Int32(job.height),Int32(r.minX),Int32(r.minY),Int32(r.maxX),Int32(r.maxY)) != 0}}
        if simple{
            var clean=job.pixels
            job.pixels.withUnsafeBufferPointer{s in mask.withUnsafeBufferPointer{m in clean.withUnsafeMutableBufferPointer{c in zeus_comic_inpaint_mask(s.baseAddress,c.baseAddress,m.baseAddress,Int32(job.width),Int32(job.height),Int32(r.minX),Int32(r.minY),Int32(r.maxX),Int32(r.maxY))}}}
            if ComicPixels.inkResidue(job.pixels,clean:clean,mask:mask,width:job.width,height:job.height,boxes:job.boxes)<=0.08{return clean}
        }
        return try await inpaint(job.pixels,mask:mask,width:job.width,height:job.height)
    }
    private func paint(_ jobs:[MaskedCrop],into result:inout [UInt8],imageWidth:Int)async throws->Set<String>{
        var ids=Set<String>()
        for job in jobs{
            try Task.checkCancellation()
            do{
                var mask=job.mask
                var restored=try await reconstructed(job,mask:mask)
                if ComicPixels.inkResidue(job.pixels,clean:restored,mask:mask,width:job.width,height:job.height,boxes:job.boxes)>0.08{
                    // Long letter shadows can teach LaMa to reconstruct the
                    // original word. On retry hide the full OCR-owned line and
                    // its immediate margin, clipped to the protected interior.
                    for box in job.boxes{
                        let r=box.insetBy(dx:-CGFloat(job.retryMargin),dy:-CGFloat(job.retryMargin)).integral.intersection(job.protected)
                        guard !r.isNull else{continue}
                        for y in Int(r.minY)..<Int(r.maxY){for x in Int(r.minX)..<Int(r.maxX){mask[y*job.width+x]=255}}
                    }
                    restored=try await reconstructed(job,mask:mask)
                }
                try Task.checkCancellation()
                guard ComicPixels.inkResidue(job.pixels,clean:restored,mask:mask,width:job.width,height:job.height,boxes:job.boxes)<=0.08 else{continue}
                for y in 0..<job.height{for x in 0..<job.width where mask[y*job.width+x]>0{
                    let source=(y*job.width+x)*4,destination=((y+Int(job.bounds.minY))*imageWidth+x+Int(job.bounds.minX))*4
                    for c in 0..<4{result[destination+c]=restored[source+c]}
                }}
                ids.insert(job.id)
            }catch is CancellationError{throw CancellationError()}catch{/* Keep the original for this crop and continue with the remaining dialogues. */}
        }
        return ids
    }
    func restore(_ image: CGImage, speeches: [ComicSpeech], requiredHeadroom:UInt64=1_200_000_000, onPreparing: (@Sendable (Bool) async -> Void)? = nil) async throws -> Result {
        try await acquire();defer{release()};try Task.checkCancellation();minimumHeadroom=requiredHeadroom
        guard let original = ComicPixels.rgba(image, width: image.width, height: image.height) else { throw ComicFailure.message("تعذّر تجهيز ترميم الخلفية.") }
        let candidates = speeches.filter { !ComicPixels.canClean(original, width: image.width, height: image.height, speech: $0) }
        if candidates.isEmpty { return Result(image: image, restored: [], notice: nil) }
        await ComicOCR.shared.purge(); await ComicPaddle.shared.purge(); await ComicLocalTranslator.shared.unload(); current = nil;currentName=nil
        guard zeus_comic_available_memory() >= requiredHeadroom else {
            return Result(image: image, restored: [], notice: "لم تتوفر ذاكرة كافية لترميم بعض الخلفيات؛ احتُفظ بأصلها.", retryable:true)
        }
        await onPreparing?(true)
        do { try await prepare() } catch { await onPreparing?(false); throw error }
        await onPreparing?(false)
        defer { current = nil;currentName=nil }
        var result = original, ids = Set<String>(),jobs:[MaskedCrop]=[],pendingPixels=0
        for speech in candidates {
            try Task.checkCancellation()
            let sourceBounds=speech.balloon ? (speech.balloonBounds ?? speech.rect):speech.lines.reduce(CGRect.null) { $0.union($1.rect) }
            let bounds = sourceBounds.insetBy(dx: -48, dy: -48).integral.intersection(CGRect(x:0,y:0,width:image.width,height:image.height))
            // Sparse masks and source crops stay below 20 MB per chunk. Detect
            // the whole chunk with CTD, then switch once to LaMa for its patches.
            if pendingPixels+Int(bounds.width*bounds.height)>4_000_000 && !jobs.isEmpty{
                ids.formUnion(try await paint(jobs,into:&result,imageWidth:image.width));jobs=[];pendingPixels=0
            }
            guard bounds.width * bounds.height <= 1_000_000, let crop = image.cropping(to: bounds), let pixels = ComicPixels.rgba(crop,width:crop.width,height:crop.height) else { continue }
            var local = speech
            local.rect = speech.rect.offsetBy(dx: -bounds.minX, dy: -bounds.minY)
            local.flatCleanup=speech.flatCleanup?.offsetBy(dx:-Int(bounds.minX),dy:-Int(bounds.minY))
            local.balloonBounds=speech.balloonBounds?.offsetBy(dx:-bounds.minX,dy:-bounds.minY)
            local.lines = speech.lines.map { line in var line=line;line.rect=line.rect.offsetBy(dx:-bounds.minX,dy:-bounds.minY);line.words=line.words?.map{ComicWord(text:$0.text,rect:$0.rect.offsetBy(dx:-bounds.minX,dy:-bounds.minY))};return line }
            let neural:[UInt8]
            do{neural=try await hints(pixels,width:crop.width,height:crop.height)}
            catch is CancellationError{throw CancellationError()}catch{continue}
            try Task.checkCancellation()
            guard ComicPixels.ownsText(pixels,width:crop.width,height:crop.height,speech:local,evidence:neural)else{continue}
            var mask = [UInt8](repeating:0,count:crop.width*crop.height)
            pixels.withUnsafeBufferPointer { p in neural.withUnsafeBufferPointer { hints in mask.withUnsafeMutableBufferPointer { m in
                for line in local.lines {
                    let pad=max(3,min(line.rect.height,line.rect.width)*0.18)
                    let rect=line.rect.insetBy(dx:-pad,dy:-pad).intersection(local.balloon ? (local.balloonBounds ?? local.rect):CGRect(x:1,y:1,width:crop.width-2,height:crop.height-2)).integral
                    if !rect.isNull { zeus_comic_refine_text_mask(p.baseAddress,hints.baseAddress,m.baseAddress,Int32(crop.width),Int32(crop.height),Int32(rect.minX),Int32(rect.minY),Int32(rect.maxX),Int32(rect.maxY)) }
                }
            } } }
            let valid=pixels.withUnsafeBufferPointer{p in neural.withUnsafeBufferPointer{h in mask.withUnsafeBufferPointer{m in
                local.lines.allSatisfy{line in let r=line.rect.integral;return zeus_comic_neural_mask_valid(p.baseAddress,h.baseAddress,m.baseAddress,Int32(crop.width),Int32(crop.height),Int32(r.minX),Int32(r.minY),Int32(r.maxX),Int32(r.maxY)) != 0}
            }}}
            guard valid else{continue}
            try Task.checkCancellation()
            let glyphs=local.lines.map{min($0.rect.width,$0.rect.height)}.sorted(),glyph=glyphs[glyphs.count/2]
            let textBounds=local.lines.reduce(CGRect.null){$0.union($1.rect)}
            let protected=(local.balloon ? (local.balloonBounds ?? local.rect):textBounds.insetBy(dx:-max(8,min(18,glyph*0.4)),dy:-max(8,min(18,glyph*0.4)))).integral.intersection(CGRect(x:1,y:1,width:crop.width-2,height:crop.height-2))
            grow(&mask,width:crop.width,height:crop.height,area:protected,radius:2)
            if local.letteringInsideBalloon == true{
                // A thin glyph mask can leave a pale negative of the original
                // word on translucent paper. Hide the entire owned line inside
                // the proven paper rectangle; keep the existing glyph mask for
                // source letters extending beyond that rectangle.
                let safe=local.rect.integral.intersection(protected)
                let margin=CGFloat(max(8,min(18,Int(ceil(glyph*0.4)))))
                for box in local.lines.map(\.rect){
                    let r=box.insetBy(dx:-margin,dy:-margin).integral.intersection(safe)
                    guard !r.isNull else{continue}
                    for y in Int(r.minY)..<Int(r.maxY){for x in Int(r.minX)..<Int(r.maxX){mask[y*crop.width+x]=255}}
                }
            }
            jobs.append(MaskedCrop(id:speech.id,pixels:pixels,mask:mask,bounds:bounds,width:crop.width,height:crop.height,boxes:local.lines.map(\.rect),protected:protected,retryMargin:max(8,min(18,Int(ceil(glyph*0.4))))));pendingPixels+=crop.width*crop.height
        }
        if !jobs.isEmpty{ids.formUnion(try await paint(jobs,into:&result,imageWidth:image.width))}
        return Result(image: try ComicPixels.fromRGBA(result,width:image.width,height:image.height), restored:ids, notice:ids.count<candidates.count ? "احتُفظ ببعض النصوص الأصلية لتعذّر ترميمها كاملًا.":nil)
    }
}
