import XCTest
import UIKit
import ImageIO
import CryptoKit
@testable import ZEUSNext

@MainActor final class NativeComicTranslationTests:XCTestCase{
    struct Page:Decodable{var path:String;var sha256:String;var width:Int;var height:Int}
    struct Chapter:Decodable{var id:String;var language:String;var split:String;var pages:[Page]}
    struct Manifest:Decodable{var app_source_commit:String;var probe_source_commit:String;var quota:Int;var translation_engine:String;var chapters:[Chapter]}
    struct Window:Encodable{var origin_y:Int;var core_top:Int;var core_bottom:Int;var reading:ComicReading}
    struct Scan:Encodable{var source:String;var source_sha256:String;var selected:Int;var seconds:Double;var windows:[Window]}
    struct Candidate{var id:String;var page:Page;var chapter:Chapter;var box:[Double];var speech:ComicSpeech;var image:Data;var language:String}
    struct Result:Encodable{var id:String;var language:String;var detected_language:String;var chapter:String;var split:String;var source:String;var source_sha256:String;var box:[Double];var speech:ComicSpeech;var target:String;var translation:String;var translation_source:String;var route:String;var note:String;var seconds:Double}
    private let base="http://127.0.0.1:8765/"
    private func data(_ path:String)async throws->Data{
        let url=URL(string:base+path.addingPercentEncoding(withAllowedCharacters:.urlPathAllowed)!)!
        let (data,response)=try await URLSession.shared.data(from:url)
        guard (response as? HTTPURLResponse)?.statusCode==200 else{throw NSError(domain:"CorpusHTTP",code:(response as? HTTPURLResponse)?.statusCode ?? 0)}
        return data
    }
    private func attach(_ image:CGImage,_ name:String){let a=XCTAttachment(image:UIImage(cgImage:image));a.name=name;a.lifetime = .keepAlways;add(a)}
    private func jsonAttachment<T:Encodable>(_ value:T,_ name:String)throws{
        let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys,.withoutEscapingSlashes]
        let a=XCTAttachment(data:try encoder.encode(value),uniformTypeIdentifier:"public.json");a.name=name;a.lifetime = .keepAlways;add(a)
    }
    func testRealChapterCorpus()async throws{
        let manifest=try JSONDecoder().decode(Manifest.self,from:await data("native-manifest.json"))
        var candidates:[Candidate]=[],pageNotes:[Scan]=[]
        for chapter in manifest.chapters{
            var count=0
            let cap=max(3,Int(ceil(Double(manifest.quota)/Double(chapter.pages.count)))+2)
            // Revisit concrete full-page failures before filling the remaining
            // deterministic diagnostic quota. These are disclosed regressions,
            // not an unseen acceptance set.
            let regressions:Set<String>=["ko/7d0c0550-3a83-4107-b6ea-918ebe820309/009.jpg","ja/ad6defe1-80da-46a9-aca2-2464fb991d3f/001.png","violet/001.jpeg","violet/018.jpeg","violet/020.jpg"]
            for page in chapter.pages.sorted(by:{a,b in
                if regressions.contains(a.path) != regressions.contains(b.path){return regressions.contains(a.path)}
                return a.sha256<b.sha256
            }){
                if count>=manifest.quota{break}
                let began=Date();let bytes=try await data(page.path)
                XCTAssertEqual(SHA256.hash(data:bytes).map{String(format:"%02x",$0)}.joined(),page.sha256)
                var pageCount=0,windows:[Window]=[]
                for region in ComicGeometry.regions(width:page.width,height:page.height,maximumPixels:7_000_000){
                    let image=try ComicPixels.decodeRegion(bytes,region:region,expectedHeight:page.height)
                    let reading=try await ComicOCR.shared.read(image,source:"auto",mode:.balanced,languageRegion:CGRect(x:0,y:region.coreTop,width:region.width,height:region.coreBottom-region.coreTop))
                    windows.append(Window(origin_y:region.y,core_top:region.coreTop,core_bottom:region.coreBottom,reading:reading))
                    let ordered=reading.speeches.sorted{a,b in ComicIdentity.hash(a.text)<ComicIdentity.hash(b.text)}
                    for source in ordered{
                        if count>=manifest.quota || pageCount>=cap{break}
                        guard source.rect.maxY>CGFloat(region.coreTop),source.rect.minY<CGFloat(region.coreBottom)else{continue}
                        let sourceInk=source.lines.reduce(CGRect.null){$0.union($1.rect)}
                        let area=source.rect.union(sourceInk).insetBy(dx:-64,dy:-64).integral.intersection(CGRect(x:0,y:0,width:image.width,height:image.height))
                        guard area.width>12,area.height>12,area.width*area.height<=1_000_000,let crop=image.cropping(to:area)else{continue}
                        var local=source
                        let id="native-\(chapter.language)-\(chapter.id.prefix(8))-\(String(format:"%03d",count))"
                        local.id=id;local.rect=source.rect.offsetBy(dx:-area.minX,dy:-area.minY)
                        local.flatCleanup=source.flatCleanup?.offsetBy(dx:-Int(area.minX),dy:-Int(area.minY))
                        local.balloonBounds=source.balloonBounds?.offsetBy(dx:-area.minX,dy:-area.minY)
                        local.lines=source.lines.map{line in var line=line;line.rect=line.rect.offsetBy(dx:-area.minX,dy:-area.minY);line.words=line.words?.map{ComicWord(text:$0.text,rect:$0.rect.offsetBy(dx:-area.minX,dy:-area.minY))};return line}
                        candidates.append(Candidate(id:id,page:page,chapter:chapter,box:[Double(area.minX),Double(area.minY)+Double(region.y),Double(area.maxX),Double(area.maxY)+Double(region.y)],speech:local,image:try ComicPixels.png(crop),language:reading.language))
                        count+=1;pageCount+=1
                    }
                }
                pageNotes.append(Scan(source:page.path,source_sha256:page.sha256,selected:pageCount,seconds:Date().timeIntervalSince(began),windows:windows))
                print("CORPUS OCR \(chapter.language) \(chapter.id) \(count)/\(manifest.quota) \(page.path)")
            }
        }
        XCTAssertFalse(candidates.isEmpty,"native OCR must find real source text")
        var translations:[String:String]=[:],translationSource:[String:String]=[:]
        for target in ["ar","en"]{
            let subset=candidates.filter{($0.chapter.language.hasPrefix("ar") ? "en":"ar")==target}
            // The browser sends the page's OCR language to the provider.
            // Using provider-side "auto" here would hide a wrong language vote.
            for source in Set(subset.map(\.language)).sorted(){
              let selected=subset.filter{$0.language==source}
              for start in stride(from:0,to:selected.count,by:12){
                let batch=Array(selected[start..<min(selected.count,start+12)])
                do{
                    var preferences=TranslationPreferences();preferences.target=target
                    let result=try await ComicTextTranslator.translate(batch.map{TranslationSegment(id:$0.id,text:$0.speech.text)},source:source,target:target,preferences:preferences,provider:nil,secret:"",local:false,engine:.google)
                    for row in result{translations[row.id]=row.text;translationSource[row.id]="Google batch"}
                }catch let partial as ComicPartialTranslation{
                    let success=Dictionary(uniqueKeysWithValues:partial.translated.map{($0.id,$0.text)})
                    for row in batch{translations[row.id]=success[row.id] ?? row.speech.text;translationSource[row.id]=success[row.id]==nil ? "provider unavailable; original retained":"Google batch"}
                }catch{
                    for row in batch{translations[row.id]=row.speech.text;translationSource[row.id]="provider unavailable; original retained: \(error.localizedDescription)"}
                }
                try await Task.sleep(for:.seconds(1))
              }
            }
        }
        var results:[Result]=[]
        for candidate in candidates{
            let began=Date(),image=try ComicPixels.decode(candidate.image),speech=candidate.speech
            let target=candidate.chapter.language.hasPrefix("ar") ? "en":"ar",text=translations[candidate.id] ?? ""
            let values=[TranslationSegment(id:speech.id,text:text)]
            var clean=image,rendered=image,route="original",note="layout or cleanup declined"
            let eligible=ComicPixels.restorableSpeeches([speech],translations:values,width:image.width,height:image.height,target:target,fontName:nil,fontScale:1)
            let providerAvailable=translationSource[candidate.id]?.hasPrefix("Google")==true
            if !providerAvailable{note="provider unavailable; original pixels retained"}
            if providerAvailable && !eligible.isEmpty{
                let pixels=try XCTUnwrap(ComicPixels.rgba(image,width:image.width,height:image.height))
                if ComicPixels.canClean(pixels,width:image.width,height:image.height,speech:speech){
                    var copy=pixels
                    ComicPixels.clean(&copy,width:image.width,height:image.height,speech:speech,source:pixels)
                    clean=try ComicPixels.fromRGBA(copy,width:image.width,height:image.height)
                    do{let report=try ComicPixels.renderReport(image,speeches:[speech],translations:values,target:target,fontName:nil,fontScale:1,requireCleanSource:true);rendered=report.image;route=report.unresolved.isEmpty ? (speech.flatCleanup?.uniform==true ? "flat":"light"):"original";note=""}catch{note=error.localizedDescription}
                }else{
                    let restoration=try await ComicRestoration.shared.restore(image,speeches:[speech],requiredHeadroom:0)
                    if restoration.restored.contains(speech.id){
                        clean=restoration.image
                        do{let report=try ComicPixels.renderReport(clean,speeches:[speech],translations:values,target:target,fontName:nil,fontScale:1,requireCleanSource:true,precleanedIDs:restoration.restored,styleSource:image);rendered=report.image;route=report.unresolved.isEmpty ? "neural":"original";note=""}catch{note=error.localizedDescription}
                    }else{note=restoration.notice ?? note}
                }
            }
            if route=="original"{clean=image;rendered=image}
            attach(image,candidate.id+"-original");attach(clean,candidate.id+"-clean");attach(rendered,candidate.id+"-rendered")
            results.append(Result(id:candidate.id,language:candidate.chapter.language,detected_language:candidate.language,chapter:candidate.chapter.id,split:candidate.chapter.split,source:candidate.page.path,source_sha256:candidate.page.sha256,box:candidate.box,speech:speech,target:target,translation:text,translation_source:translationSource[candidate.id] ?? "none",route:route,note:note,seconds:Date().timeIntervalSince(began)))
            print("CORPUS RENDER \(candidate.id) \(route)")
        }
        try jsonAttachment(results,"native-corpus-cases");try jsonAttachment(pageNotes,"native-corpus-pages")
        try jsonAttachment(["app_source_commit":manifest.app_source_commit,"probe_source_commit":manifest.probe_source_commit,"memory_guard_bypassed":"simulator inference only","source_language_policy":"page OCR language, matching browser pipeline","quality_acceptance_proven":"false","cases":String(results.count)],"native-corpus-provenance")
        await ComicRestoration.shared.purge();await ComicPaddle.shared.purge();await ComicOCR.shared.purge()
    }
}
