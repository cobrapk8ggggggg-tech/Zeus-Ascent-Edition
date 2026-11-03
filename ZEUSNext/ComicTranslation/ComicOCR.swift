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
    func read(_ image:CGImage,source:String,mode:ComicReadingMode,languageRegion:CGRect? = nil,onPreparing:(@Sendable (Bool) async -> Void)? = nil)async throws->ComicReading{
        try Task.checkCancellation()
        let probe:(String,[ComicLine])
        if source=="auto"{probe=try await Self.scriptProbe(image,region:languageRegion)}
        else if ComicModelStore.recognizer(source)=="arabic"{probe=(source,try Self.vision(image,languages:["ar-SA"],accurate:true))}
        else{probe=(source,[])}
        var detected=probe.0
        var fastSupported=ComicModelStore.recognizer(detected)=="latin" || ["ja","zh","ko"].contains(where:detected.hasPrefix)
        var fast=fastSupported ? try await self.fast(image,source:detected):[]
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
            lines=mode == .careful ? accurate:Self.merge(fast,accurate:accurate)
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
                }else if script=="latin",primary != "latin",overlaps.isEmpty,sample.confidence>=0.95,sample.text.filter({$0.isLetter}).count>=3{lines.append(sample)}
            }
        }
        return ComicReading(lines:lines,speeches:ComicBalloons.speeches(lines,image:image,source:detected),language:detected,runtime:runtime)
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
        var samples=try vision(image,languages:["ar-SA","ko-KR","ja-JP","zh-Hans","ru-RU","en-US"],accurate:true,automatic:true)
        // Vision's automatic language choice can select English for a mixed
        // panel and omit its Arabic line. An explicit supported Arabic pass
        // supplies only Arabic-script candidates; it cannot replace Latin text.
        if try VNRecognizeTextRequest().supportedRecognitionLanguages().contains("ar-SA"){
            let arabic=try vision(image,languages:["ar-SA"],accurate:true).filter{lineScript($0.text)=="arabic" && $0.confidence>=0.3}
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
    private func fast(_ image:CGImage,source:String)async throws->[ComicLine]{
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
        return try Self.vision(image,languages:[source == "auto" ? "en-US":source],accurate:true)
        #else
        // Standalone builds without the SDK remain diagnosable, not falsely labelled ML Kit.
        throw ComicFailure.message("هذا البناء لا يتضمن ML Kit. استخدم بناء ترجمة الصور الكامل.")
        #endif
    }
    private static func vision(_ image:CGImage,languages:[String],accurate:Bool,automatic:Bool = false)throws->[ComicLine]{
        let request=VNRecognizeTextRequest();request.automaticallyDetectsLanguage=automatic;request.recognitionLevel=accurate ? .accurate:.fast;let aliases=["ko":"ko-KR","ja":"ja-JP","zh":"zh-Hans","en":"en-US","ar":"ar-SA"]
        let supported=try request.supportedRecognitionLanguages()
        let requested=languages.map{aliases[$0] ?? $0}.filter{supported.contains($0)}
        request.recognitionLanguages=requested.isEmpty ? ["en-US"]:requested;request.usesLanguageCorrection=false
        try VNImageRequestHandler(cgImage:image,options:[:]).perform([request])
        return (request.results ?? []).compactMap{r in
            guard let value=r.topCandidates(1).first else{return nil}
            func pixels(_ b:CGRect)->CGRect{CGRect(x:b.minX*CGFloat(image.width),y:(1-b.maxY)*CGFloat(image.height),width:b.width*CGFloat(image.width),height:b.height*CGFloat(image.height))}
            var words:[ComicWord]=[]
            value.string.enumerateSubstrings(in:value.string.startIndex..<value.string.endIndex,options:[.byWords,.substringNotRequired]){_,range,_,_ in
                if let observation=try? value.boundingBox(for:range){words.append(ComicWord(text:String(value.string[range]),rect:pixels(observation.boundingBox)))}
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
            // Keep punctuation attached and the original line text intact. Word
            // ranges are used only when one OCR line spans different lobes.
            if words.count>1{
                let parts=value.string.split(whereSeparator:{$0.isWhitespace}).map(String.init)
                if parts.count==words.count{for i in words.indices{words[i].text=parts[i]}}
                else if value.string.contains(where:{$0.isWhitespace}){words=[]}
            }
            return ComicLine(text:value.string,confidence:value.confidence,rect:pixels(r.boundingBox),angle:atan2(Double((r.topLeft.y-r.topRight.y)*CGFloat(image.height)),Double((r.topRight.x-r.topLeft.x)*CGFloat(image.width))),words:words.isEmpty ? nil:words)
        }
    }
}
private extension CGRect {var area:CGFloat {isNull ? 0:max(0,width)*max(0,height)}}
