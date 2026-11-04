import Foundation
import CoreGraphics
import UIKit
import Vision
import NaturalLanguage
#if canImport(MLKitTextRecognition)
import MLKitTextRecognition
import MLKitTextRecognitionChinese
import MLKitTextRecognitionJapanese
import MLKitTextRecognitionKorean
import MLKitVision
#endif

actor ComicOCR {
    static let shared=ComicOCR()
    #if canImport(MLKitTextRecognition)
    private var fastRecognizers:[String:TextRecognizer]=[:]
    #endif
    func purge(){
        #if canImport(MLKitTextRecognition)
        fastRecognizers.removeAll()
        #endif
    }
    func read(_ image:CGImage,source:String,mode:ComicReadingMode,languageRegion:CGRect? = nil,languageHint:String? = nil,onPreparing:(@Sendable (Bool) async -> Void)? = nil)async throws->ComicReading{
        try Task.checkCancellation()
        let probe:(String,[ComicLine])
        if source=="auto",let hint=languageHint,ComicModelStore.recognizer(hint) != "arabic"{probe=(hint,[])}
        else if source=="auto"{probe=try await Self.scriptProbe(image,region:languageRegion)}
        else if ComicModelStore.recognizer(source)=="arabic"{probe=(source,try Self.vision(image,languages:["ar-SA"],accurate:true))}
        else{probe=(source,[])}
        var detected=probe.0
        var fastSupported=ComicModelStore.recognizer(detected)=="latin" || ["ja","zh","ko"].contains(where:detected.hasPrefix)
        var fast=fastSupported ? try await self.fast(image,source:detected):[]
        if source=="auto",languageHint != nil,fast.isEmpty{
            return try await read(image,source:source,mode:mode,languageRegion:languageRegion,onPreparing:onPreparing)
        }
        // An empty first hypothesis is not evidence that the panel has no text.
        // Probe the other bundled scripts before downloading a recognizer or
        // caching an empty reading. Explicit user language always wins.
        if source == "auto",fastSupported,fast.isEmpty {
            for alternative in ["en","ko","ja","zh"] where alternative != detected {
                try Task.checkCancellation()
                let candidate=try await self.fast(image,source:alternative)
                if candidate.map(\.text).joined().filter({$0.isLetter}).count>=3 {
                    fast=candidate;detected=alternative;fastSupported=true;break
                }
            }
        }
        var lines=fast
        #if targetEnvironment(simulator)
        var runtime="Apple Vision (simulator only; ML Kit has no arm64 simulator slice)"
        #else
        var runtime="MLKit"
        #endif
        if mode != .fastest || !fastSupported {
            if !(await ComicModelStore.shared.isPrepared(source:detected)) {
                await onPreparing?(true)
                try await ComicModelStore.shared.prepare(source:detected)
                try Task.checkCancellation()
                await onPreparing?(false)
            }
            let accurate=try await ComicPaddle.shared.read(image,source:detected,careful:mode == .careful)
            #if targetEnvironment(simulator)
            runtime=fastSupported ? "Apple Vision+Paddle/ONNX (simulator)":"Paddle/ONNX"
            #else
            runtime=fastSupported ? "MLKit+Paddle/ONNX":"Paddle/ONNX"
            #endif
            lines=Self.merge(fast,accurate:accurate)
        }
        // Keep script-consistent readings from the same local Vision
        // probe. Covers mixed-language panels without poisoning the whole page's
        // recognizer choice or downloading every language model up front.
        if source=="auto" || ComicModelStore.recognizer(detected)=="arabic"{
            let primary=ComicModelStore.recognizer(detected)
            // Vision reports 0.5 even for accurate Arabic lines. Use its existing
            // geometry confidence floor; Paddle's 0.65 has a different scale.
            for sample in probe.1 where sample.confidence >= (Self.lineScript(sample.text)=="arabic" ? 0.3:0.65){
                let script=Self.lineScript(sample.text)
                let overlaps=lines.indices.filter{lines[$0].rect.intersection(sample.rect).area/min(max(1,lines[$0].rect.area),max(1,sample.rect.area))>0.6}
                if script != "latin" && script != "other" && (script != primary || overlaps.isEmpty || overlaps.contains{Self.lineScript(lines[$0].text) != script} || overlaps.allSatisfy{lines[$0].confidence<sample.confidence}){
                    lines=lines.enumerated().filter{!overlaps.contains($0.offset)}.map{$0.element};lines.append(sample)
                }else if script=="latin",overlaps.isEmpty,sample.confidence >= (primary=="latin" ? 0.8:0.95),sample.text.filter({$0.isLetter}).count>=2{lines.append(sample)}
            }
        }
        let initialLines=lines
        var speeches=ComicBalloons.speeches(lines,image:image,source:detected)
        // Closed dialogues with missing ink need another crop. Low-confidence
        // external lettering also needs a local Paddle read: Vision can report
        // a brush word as ALPIGHY, and ML Kit's iOS API has no calibrated score.
        let uncertain=fast.filter{$0.confidence<0.85}.map(\.rect)
        func difficult(_ speech:ComicSpeech)->Bool{
            guard !speech.balloon,(ComicModelStore.recognizer(detected)=="latin" || Self.lineScript(speech.text)=="latin") else{return false}
            return speech.lines.contains{line in uncertain.contains{r in r.intersection(line.rect).area/min(max(1,r.area),max(1,line.rect.area))>0.6}}
        }
        var repairUnavailable=false
        if fastSupported{
            // Context rows complete cut balloons, but must not spend the limited
            // repair budget before text owned by this part of the reader.
            let repairs=speeches.filter{$0.flatCleanup?.complete==false || difficult($0)}.sorted{left,right in
                let a=languageRegion?.contains(CGPoint(x:left.rect.midX,y:left.rect.midY)) ?? true
                let b=languageRegion?.contains(CGPoint(x:right.rect.midX,y:right.rect.midY)) ?? true
                if a != b{return a}
                if left.rect.minY != right.rect.minY{return left.rect.minY<right.rect.minY}
                return left.rect.minX<right.rect.minX
            }.prefix(mode == .fastest ? 3:8)
            var additional:[ComicLine]=[],replacements:[([ComicLine],[ComicLine])]=[]
            for speech in repairs{
                try Task.checkCancellation()
                let height=speech.lines.map{min($0.rect.width,$0.rect.height)}.sorted()
                let margin=difficult(speech) ? max(12,min(48,height[height.count/2]*0.4)):4
                let area=(speech.balloonBounds ?? speech.rect).insetBy(dx:-margin,dy:-margin).integral.intersection(CGRect(x:0,y:0,width:image.width,height:image.height))
                guard area.width*area.height<=500_000,let cut=image.cropping(to:area)else{continue}
                func shifted(_ input:[ComicLine])->[ComicLine]{input.map{line in
                    var value=line;value.rect=value.rect.offsetBy(dx:area.minX,dy:area.minY)
                    value.words=value.words?.map{ComicWord(text:$0.text,rect:$0.rect.offsetBy(dx:area.minX,dy:area.minY))};return value
                }}
                additional+=shifted(try await self.fast(cut,source:detected))
                if difficult(speech){
                    let repairSource=ComicModelStore.recognizer(detected)=="latin" ? detected:"en"
                    do{
                        if !(await ComicModelStore.shared.isPrepared(source:repairSource)){
                            await onPreparing?(true)
                            do{try await ComicModelStore.shared.prepare(source:repairSource)}catch{await onPreparing?(false);throw error}
                            await onPreparing?(false)
                        }
                        let precise=shifted(try await ComicPaddle.shared.read(cut,source:repairSource,careful:false)).filter{line in
                            line.confidence>=0.8 && speech.rect.contains(CGPoint(x:line.rect.midX,y:line.rect.midY))
                        }
                        // A confident short fragment must not replace a whole
                        // paragraph. Every old row and most letters need owners.
                        let covers=speech.lines.allSatisfy{old in precise.contains{fresh in fresh.rect.intersection(old.rect).area/max(1,old.rect.area)>=0.8}}
                        let preciseText=precise.map(\.text).joined()
                        let oldCount=speech.text.filter{$0.isLetter||$0.isNumber}.count
                        let newCount=preciseText.filter{$0.isLetter||$0.isNumber}.count
                        if !precise.isEmpty,covers,Double(newCount)>=Double(oldCount)*0.75{
                            replacements.append((speech.lines,precise))
                        }
                        if !runtime.contains("Paddle"){runtime+=" + targeted Paddle"}
                    }catch is CancellationError{throw CancellationError()}catch{repairUnavailable=true}
                }
            }
            if !additional.isEmpty{lines=Self.merge(lines,accurate:additional)}
            for (old,fresh) in replacements{
                lines.removeAll{line in old.contains{previous in line.rect.intersection(previous.rect).area/min(max(1,line.rect.area),max(1,previous.rect.area))>0.75}}
                lines+=fresh
            }
            if source=="auto",!replacements.isEmpty,ComicModelStore.recognizer(detected)=="latin"{
                let text=lines.map(\.text).joined(separator:" ")
                if text.split(whereSeparator:{$0.isWhitespace}).count>=5{
                    let recognizer=NLLanguageRecognizer();recognizer.processString(text)
                    if let language=recognizer.dominantLanguage,ComicModelStore.recognizer(language.rawValue)=="latin",recognizer.languageHypotheses(withMaximum:1)[language,default:0]>=0.6{detected=language.rawValue}
                }
            }
            if lines != initialLines{speeches=ComicBalloons.speeches(lines,image:image,source:detected)}
        }
        return ComicReading(lines:lines,speeches:speeches,language:detected,runtime:runtime,repairUnavailable:repairUnavailable)
    }

    // A stronger partial word cannot replace a complete fast line. Retain the
    // union of source bounds even when the readings agree on the full span.
    static func merge(_ fast:[ComicLine],accurate:[ComicLine])->[ComicLine]{
        var lines=fast
        for line in accurate where !lines.contains(where:{$0.rect.intersection(line.rect).area/min(max(1,$0.rect.area),max(1,line.rect.area))>0.5}){lines.append(line)}
        return lines.map{line in
            guard var replacement=accurate.filter({$0.rect.intersection(line.rect).area/max(1,line.rect.area)>0.85 && $0.confidence>line.confidence}).max(by:{$0.confidence<$1.confidence})else{return line}
            replacement.rect=replacement.rect.union(line.rect)
            return replacement
        }
    }
    static func scriptProbe(_ image:CGImage,region:CGRect?)async throws->(String,[ComicLine]){
        // This pass selects a script; actual reading still uses native-resolution
        // tiles. Two full-size multilingual passes on every webtoon strip were
        // substantially more expensive than the provider translation itself.
        let scale=min(1,2048/Double(max(image.width,image.height)))
        var probe=image
        if scale<1,let context=ComicPixels.context(width:max(1,Int(Double(image.width)*scale)),height:max(1,Int(Double(image.height)*scale))){
            context.interpolationQuality = .high
            context.draw(image,in:CGRect(x:0,y:0,width:context.width,height:context.height))
            probe=context.makeImage() ?? image
        }
        func originalCoordinates(_ input:[ComicLine])->[ComicLine]{
            let sx=CGFloat(image.width)/CGFloat(probe.width),sy=CGFloat(image.height)/CGFloat(probe.height)
            let transform=CGAffineTransform(scaleX:sx,y:sy)
            return input.map{line in
                var value=line;value.rect=line.rect.applying(transform)
                value.words=line.words?.map{ComicWord(text:$0.text,rect:$0.rect.applying(transform))}
                value.angle=atan2(sin(line.angle)*Double(sy),cos(line.angle)*Double(sx))
                return value
            }
        }
        var samples=originalCoordinates(try vision(probe,languages:["ar-SA","ko-KR","ja-JP","zh-Hans","ru-RU","en-US"],accurate:true,automatic:true))
        // Vision's automatic language choice can select English for a mixed
        // panel and omit its Arabic line. An explicit supported Arabic pass
        // supplies only Arabic-script candidates; it cannot replace Latin text.
        if try VNRecognizeTextRequest().supportedRecognitionLanguages().contains("ar-SA"){
            let arabic=originalCoordinates(try vision(probe,languages:["ar-SA"],accurate:true)).filter{lineScript($0.text)=="arabic" && $0.confidence>=0.3}
            for line in arabic{
                if let index=samples.firstIndex(where:{$0.rect.intersection(line.rect).area/min(max(1,$0.rect.area),max(1,line.rect.area))>0.6 && lineScript($0.text)=="arabic"}){
                    if line.confidence>=samples[index].confidence{samples[index]=line}
                }else{samples.append(line)}
            }
        }
        let owned=region.map{area in samples.filter{area.contains(CGPoint(x:$0.rect.midX,y:$0.rect.midY))}} ?? samples
        let text=(owned.isEmpty ? samples:owned).map(\.text).joined(separator:" ")
        let recognizer=NLLanguageRecognizer();recognizer.processString(text)
        let scalars=text.unicodeScalars.filter{$0.properties.isAlphabetic}
        let arabic=scalars.filter{(0x0600...0x06FF).contains($0.value)||(0x0750...0x077F).contains($0.value)||(0xFB50...0xFDFF).contains($0.value)||(0xFE70...0xFEFF).contains($0.value)}.count
        let hangul=scalars.filter{(0xAC00...0xD7AF).contains($0.value)}.count
        let kana=scalars.filter{(0x3040...0x30FF).contains($0.value)}.count
        let han=scalars.filter{(0x4E00...0x9FFF).contains($0.value)}.count
        let cyrillic=scalars.filter{(0x0400...0x052F).contains($0.value)}.count
        let latin=scalars.filter{$0.value<=0x024F}.count
        let cjk=kana>=2 || recognizer.dominantLanguage == .japanese ? "ja":"zh"
        let votes=[("ar",arabic),("ko",hangul),(cjk,han+kana),("ru",cyrillic),("latin",latin)]
        if let best=votes.max(by:{$0.1<$1.1}),best.1>=2,best.0 != "latin"{return(best.0,samples)}
        return(recognizer.dominantLanguage?.rawValue ?? "en",samples)
    }

    private static func lineScript(_ text:String)->String{
        let s=text.unicodeScalars.filter{$0.properties.isAlphabetic}
        let scores=[("arabic",s.filter{(0x0600...0x06FF).contains($0.value)||(0xFE70...0xFEFF).contains($0.value)}.count),("korean",s.filter{(0xAC00...0xD7AF).contains($0.value)}.count),("han",s.filter{(0x3040...0x30FF).contains($0.value)||(0x4E00...0x9FFF).contains($0.value)}.count),("cyrillic",s.filter{(0x0400...0x052F).contains($0.value)}.count),("latin",s.filter{$0.value<=0x024F}.count)]
        return scores.max(by:{$0.1<$1.1}).flatMap{$0.1>=2 ? $0.0:nil} ?? "other"
    }
    // ML Kit/Vision internally shrink very tall webtoon strips. Read bounded
    // overlapping tiles at their real resolution so small captions survive.
    private func fast(_ image:CGImage,source:String)async throws->[ComicLine]{
        var lines:[ComicLine]=[]
        for area in Self.tiles(width:image.width,height:image.height){
            try Task.checkCancellation()
            guard let cut=image.cropping(to:area)else{continue}
            var local=try await fastNative(cut,source:source)
            // Fast mode remains entirely local and never needs restoration models.
            if local.isEmpty{local=try Self.vision(cut,languages:[source],accurate:true)}
            let translated=local.map{line -> ComicLine in
                var value=line;value.rect=value.rect.offsetBy(dx:area.minX,dy:area.minY)
                value.words=value.words?.map{ComicWord(text:$0.text,rect:$0.rect.offsetBy(dx:area.minX,dy:area.minY))};return value
            }
            lines=Self.merge(lines,accurate:translated)
        }
        return lines
    }
    static func tiles(width:Int,height:Int)->[CGRect]{
        guard width>0,height>0 else{return []}
        let size=1536,overlap=128
        var result:[CGRect]=[],y=0
        while y<height{
            var x=0
            while x<width{
                result.append(CGRect(x:x,y:y,width:min(size,width-x),height:min(size,height-y)))
                if x+size>=width{break};x+=size-overlap
            }
            if y+size>=height{break};y+=size-overlap
        }
        return result
    }
    private func fastNative(_ image:CGImage,source:String)async throws->[ComicLine]{
        #if canImport(MLKitTextRecognition)
        let recognizer: TextRecognizer
        let script=source.hasPrefix("ko") ? "ko":source.hasPrefix("ja") ? "ja":source.hasPrefix("zh") ? "zh":"latin"
        if let saved=fastRecognizers[script]{recognizer=saved}
        else if source.hasPrefix("ko"){recognizer=TextRecognizer.textRecognizer(options:KoreanTextRecognizerOptions())}
        else if source.hasPrefix("ja"){recognizer=TextRecognizer.textRecognizer(options:JapaneseTextRecognizerOptions())}
        else if source.hasPrefix("zh"){recognizer=TextRecognizer.textRecognizer(options:ChineseTextRecognizerOptions())}
        else{recognizer=TextRecognizer.textRecognizer(options:TextRecognizerOptions())}
        if fastRecognizers[script]==nil{fastRecognizers.removeAll();fastRecognizers[script]=recognizer}
        let result=try await withCheckedThrowingContinuation{(c:CheckedContinuation<Text,Error>)in recognizer.process(VisionImage(image:UIImage(cgImage:image))){text,error in if let error{c.resume(throwing:error)}else if let text{c.resume(returning:text)}else{c.resume(throwing:ComicFailure.message("لم يُرجع OCR نتيجة."))}}}
        return result.blocks.flatMap(\.lines).map{line in
            let points=line.cornerPoints.map(\.cgPointValue)
            let angle=points.count>=2 ? atan2(Double(points[1].y-points[0].y),Double(points[1].x-points[0].x)):0
            return ComicLine(text:line.text,confidence:0.8,rect:line.frame,angle:angle,words:line.elements.map{ComicWord(text:$0.text,rect:$0.frame)})
        }
        #elseif targetEnvironment(simulator)
        // Exercise the same repair policy as ML Kit's uncalibrated 0.8 score.
        // Vision can assign 1.0 to a wrong brush word in a neighbouring-page
        // window. The independent script probe keeps its original confidence.
        return try Self.vision(image,languages:[source == "auto" ? "en-US":source],accurate:true).map{line in
            var value=line;value.confidence=min(value.confidence,0.8);return value
        }
        #else
        // Standalone builds without the SDK remain diagnosable, not falsely labelled ML Kit.
        throw ComicFailure.message("هذا البناء لا يتضمن ML Kit. استخدم بناء ترجمة الصور الكامل.")
        #endif
    }
    private static func vision(_ image:CGImage,languages:[String],accurate:Bool,automatic:Bool = false)throws->[ComicLine]{
        let request=VNRecognizeTextRequest();request.automaticallyDetectsLanguage=automatic;request.recognitionLevel=accurate ? .accurate:.fast;let aliases=["ko":"ko-KR","ja":"ja-JP","zh":"zh-Hans","en":"en-US","ar":"ar-SA"]
        let supported=try request.supportedRecognitionLanguages()
        let requested=languages.map{aliases[$0] ?? $0}.filter{supported.contains($0)}
        request.recognitionLanguages=requested.isEmpty ? ["en-US"]:requested;request.usesLanguageCorrection=false;request.minimumTextHeight=0.003
        try VNImageRequestHandler(cgImage:image,options:[:]).perform([request])
        return (request.results ?? []).compactMap{r in
            guard let value=r.topCandidates(1).first else{return nil}
            func pixels(_ b:CGRect)->CGRect{CGRect(x:b.minX*CGFloat(image.width),y:(1-b.maxY)*CGFloat(image.height),width:b.width*CGFloat(image.width),height:b.height*CGFloat(image.height))}
            var words:[ComicWord]=[]
            for word in value.string.split(whereSeparator:{$0.isWhitespace}){
                if let observation=try? value.boundingBox(for:word.startIndex..<word.endIndex){words.append(ComicWord(text:String(word),rect:pixels(observation.boundingBox)))}
            }
            if !value.string.contains(where:{$0.isWhitespace}),value.string.unicodeScalars.contains(where:{(0x3040...0x30ff).contains($0.value)||(0x4e00...0x9fff).contains($0.value)}){
                words=[]
                var start=value.string.startIndex
                while start<value.string.endIndex{
                    let end=value.string.index(after:start)
                    if let box=try? value.boundingBox(for:start..<end){words.append(ComicWord(text:String(value.string[start..<end]),rect:pixels(box.boundingBox)))}
                    start=end
                }
            }
            // Whitespace token ranges retain contractions and punctuation;
            // only lines spanning distinct shape owners use these fragments.
            return ComicLine(text:value.string,confidence:value.confidence,rect:pixels(r.boundingBox),angle:atan2(Double((r.topLeft.y-r.topRight.y)*CGFloat(image.height)),Double((r.topRight.x-r.topLeft.x)*CGFloat(image.width))),words:words.isEmpty ? nil:words)
        }
    }
}
private extension CGRect {var area:CGFloat {isNull ? 0:max(0,width)*max(0,height)}}
