import XCTest
import WebKit
import UIKit
#if canImport(ZEUSBrowser)
@testable import ZEUSBrowser
#else
@testable import ZEUSNext
#endif

@MainActor final class NativeComicTranslationTests:XCTestCase{
    private func renderer(_ size:CGSize)->UIGraphicsImageRenderer{let format=UIGraphicsImageRendererFormat();format.scale=1;return UIGraphicsImageRenderer(size:size,format:format)}
    func testRegionsOwnEveryRowExactlyOnceAndBoundPixels(){
        let regions=ComicGeometry.regions(width:1500,height:70000)
        XCTAssertGreaterThan(regions.count,10)
        var previous=0
        for region in regions{XCTAssertLessThanOrEqual(region.width*region.height,8_000_000);XCTAssertEqual(region.y+region.coreTop,previous);previous=region.y+region.coreBottom;XCTAssertLessThan(region.coreTop,region.coreBottom)}
        XCTAssertEqual(previous,70000);XCTAssertTrue(ComicGeometry.regions(width:0,height:1).isEmpty)
    }
    func testStripNeverCrossesUnloadedPanelAndPreservesPixelOrder()throws{
        func candidate(_ id:String,_ y:Double,pending:Bool=false)->ComicCandidate{ComicCandidate(id:id,source:"https://example.invalid/"+id,kind:"image",width:200,height:400,x:0,y:y,w:200,h:400,pending:pending,revision:"0")}
        let a=candidate("a",0),b=candidate("b",400),c=candidate("c",800)
        XCTAssertEqual(ComicWindow.neighbours(of:b,in:[a,b,c]).before?.id,"a")
        let gap=candidate("gap",400,pending:true)
        XCTAssertNil(ComicWindow.neighbours(of:a,in:[a,gap,c]).after)
        func image(_ color:UIColor)->CGImage{renderer(CGSize(width:20,height:20)).image{ctx in color.setFill();ctx.fill(CGRect(x:0,y:0,width:20,height:20))}.cgImage!}
        let joined=try ComicWindow.join(image(.green),before:image(.red),after:image(.blue))
        XCTAssertEqual(joined.offset,20);XCTAssertEqual(joined.image.height,60)
        let pixels=try XCTUnwrap(ComicPixels.rgba(joined.image,width:20,height:60))
        XCTAssertGreaterThan(pixels[0],200);XCTAssertGreaterThan(pixels[(40*20)*4+2],200)
    }
    func testNativeTallPNGRegionMatchesOriginal()throws{
        let image=renderer(CGSize(width:100,height:12000)).image{ctx in UIColor.red.setFill();ctx.fill(CGRect(x:0,y:0,width:100,height:12000))}
        let data=try XCTUnwrap(image.pngData()),region=ComicRegion(y:11000,width:100,height:1000,coreTop:0,coreBottom:1000)
        let decoded=try ComicPixels.decodeRegion(data,region:region)
        XCTAssertEqual(decoded.width,100);XCTAssertEqual(decoded.height,1000)
        let pixels=try XCTUnwrap(ComicPixels.rgba(decoded,width:100,height:1000));XCTAssertGreaterThan(pixels[0],200)
    }
    func testTallImageScrollJumpPrioritizesVisibleRegion(){
        let candidate=ComicCandidate(id:"long",source:"https://example.invalid/long.png",kind:"image",width:1000,height:70000,x:0,y:0,w:1000,h:70000,pending:false,revision:"0")
        let regions=ComicGeometry.regions(width:1000,height:70000)
        let queued=ComicGeometry.prioritized(regions,candidate:candidate,scroll:50000,viewport:800,readAhead:false)
        XCTAssertFalse(queued.isEmpty)
        XCTAssertTrue(queued.allSatisfy{$0.y+$0.coreBottom>=50000&&$0.y+$0.coreTop<=50800})
        XCTAssertFalse(queued.contains{$0.y==0})
    }
    func testCTCBlankRepeatedGlyphAndDictionaryValidation()throws{
        let dictionary=try ComicPaddle.dictionary("Global:\n  character_dict:\n  - 'ا'\n  - 'ب'\n")
        let result=ComicPaddle.ctc([0,1,0,0, 0,1,0,0, 1,0,0,0, 0,1,0,0, 0,0,1,0],steps:5,classes:4,dictionary:dictionary)
        XCTAssertEqual(result.0,"ااب");XCTAssertEqual(result.1,1)
        XCTAssertThrowsError(try ComicPaddle.dictionary("invalid"))
    }
    func testArabicCoreTextFitsAndColorIsValidated()throws{
        let layout=try XCTUnwrap(ComicPixels.layout("أين ذهب صديقي؟",rect:CGRect(x:0,y:0,width:160,height:90),target:"ar",fontName:nil,fontScale:1))
        XCTAssertLessThanOrEqual(layout.height,90);XCTAssertGreaterThan(layout.size,6)
        XCTAssertNil(ComicPixels.color("<script>"));XCTAssertNotNil(ComicPixels.color("#163B72"))
    }
    func testBalloonInteriorProtectsBordersAndProvidesRoomForArabic()throws{
        let image=renderer(CGSize(width:300,height:220)).image{context in
            UIColor.darkGray.setFill();context.fill(CGRect(x:0,y:0,width:300,height:220))
            UIColor.white.setFill();UIBezierPath(ovalIn:CGRect(x:50,y:30,width:200,height:160)).fill()
            UIColor.black.setFill();context.fill(CGRect(x:110,y:90,width:80,height:4))
        }.cgImage!
        let pixels=try XCTUnwrap(ComicPixels.rgba(image,width:300,height:220))
        let interior=try XCTUnwrap(ComicBalloons.interior(CGRect(x:100,y:80,width:100,height:40),pixels:pixels,width:300,height:220))
        XCTAssertGreaterThan(interior.width,150);XCTAssertGreaterThan(interior.height,100)
        XCTAssertGreaterThan(interior.minX,45);XCTAssertLessThan(interior.maxX,255)
    }
    func testGroupingDoesNotJoinAdjacentBalloons(){
        let lines=[ComicLine(text:"첫 줄",confidence:1,rect:CGRect(x:10,y:10,width:80,height:20)),ComicLine(text:"둘째 줄",confidence:1,rect:CGRect(x:10,y:35,width:80,height:20)),ComicLine(text:"다른 말",confidence:1,rect:CGRect(x:200,y:12,width:80,height:20))]
        let speeches=ComicGeometry.group(lines,source:"ko")
        XCTAssertEqual(speeches.count,2);XCTAssertTrue(speeches.contains{$0.lines.count==2})
    }
    func testActualLocalOCRReadsRasterText()async throws{
        let image=renderer(CGSize(width:640,height:180)).image{context in
            UIColor.white.setFill();context.fill(CGRect(x:0,y:0,width:640,height:180))
            ("HELLO WORLD" as NSString).draw(at:CGPoint(x:60,y:60),withAttributes:[.font:UIFont.systemFont(ofSize:52),.foregroundColor:UIColor.black])
        }.cgImage!
        let result=try await ComicOCR.shared.read(image,source:"en",mode:.fastest)
        XCTAssertTrue(result.lines.map(\.text).joined(separator:" ").uppercased().contains("HELLO"))
    }
    func testActualPinnedPaddleModelReadsRasterText()async throws{
        try await ComicModelStore.shared.prepare(source:"en")
        let image=renderer(CGSize(width:640,height:180)).image{context in
            UIColor.white.setFill();context.fill(CGRect(x:0,y:0,width:640,height:180))
            ("HELLO WORLD" as NSString).draw(at:CGPoint(x:60,y:60),withAttributes:[.font:UIFont.systemFont(ofSize:52),.foregroundColor:UIColor.black])
        }.cgImage!
        let lines=try await ComicPaddle.shared.read(image,source:"en",careful:false)
        XCTAssertTrue(lines.map(\.text).joined(separator:" ").uppercased().contains("HELLO"))
    }
    func testDeletedProfileCannotReceiveLateCacheWrites()async throws{
        let owner=UUID();try await ComicMemory.shared.clear(profile:owner,deleting:true)
        do{try await ComicMemory.shared.save(Data("late".utf8),profile:owner,layer:.translation,key:"key");XCTFail("deleted profile accepted a late result")}catch is CancellationError{}catch{XCTFail(error.localizedDescription)}
    }
    func testImageSettingsAreIndependentOfPageTranslation()throws{
        var data=ProfileData();var page=TranslationPreferences();page.target="fr";data.settings.translation=page
        var comic=ComicPreferences();var image=TranslationPreferences();image.target="ar";comic.translation=image;data.settings.comicTranslation=comic
        let decoded=try JSONDecoder().decode(ProfileData.self,from:JSONEncoder().encode(data))
        XCTAssertEqual(decoded.settings.translation?.target,"fr");XCTAssertEqual(decoded.settings.comicTranslation?.translation?.target,"ar")
        XCTAssertEqual(ComicPreferences().mode,.fastest)
    }
    func testActualWebKitSwapRestoreAndStaleResults()async throws{
        let image=renderer(CGSize(width:200,height:100)).image{c in UIColor.white.setFill();c.fill(CGRect(x:0,y:0,width:200,height:100));("ORIGINAL" as NSString).draw(at:CGPoint(x:20,y:30),withAttributes:[.foregroundColor:UIColor.black,.font:UIFont.systemFont(ofSize:20)])}
        let original=try XCTUnwrap(image.pngData()).base64EncodedString(),replacement=try XCTUnwrap(ComicPixels.png(XCTUnwrap(image.cgImage))).base64EncodedString()
        let controller=WKUserContentController();controller.addUserScript(WKUserScript(source:ComicTranslation.script,injectionTime:.atDocumentEnd,forMainFrameOnly:false,in:ComicTranslation.world))
        let config=WKWebViewConfiguration();config.userContentController=controller;let view=WKWebView(frame:CGRect(x:0,y:0,width:390,height:700),configuration:config)
        let html="<html><body><picture><source id='source' srcset='data:image/png;base64,\(original)'><img id='panel' width='200' height='100' src='data:image/png;base64,\(original)'></picture></body></html>"
        view.loadHTMLString(html,baseURL:URL(string:"https://comic.invalid"))
        let deadline=Date().addingTimeInterval(15)
        while Date()<deadline{if (try? await view.callAsyncJavaScript("return !!globalThis.zeusComic && document.images[0].complete",arguments:[:],in:nil,contentWorld:ComicTranslation.world))as? Bool==true{break};try await Task.sleep(for:.milliseconds(100))}
        let result=try await view.callAsyncJavaScript("await document.images[0].decode();const s=zeusComic.scan(false);const c=s.items[0];return {id:c.id,revision:c.revision,generation:zeusComic.start()};",arguments:[:],in:nil,contentWorld:ComicTranslation.world)as? [String:Any]
        let id=try XCTUnwrap(result?["id"]as? String),revision=try XCTUnwrap(result?["revision"]as? String)
        let arguments:[String:Any]=["id":id,"revision":revision,"data":replacement,"region":["x":0,"y":0,"width":200,"height":100],"mark":"ar","generation":result?["generation"]as? Int ?? 0]
        let applied=try await view.callAsyncJavaScript("return await zeusComic.apply(id,revision,data,region,mark,generation)",arguments:arguments,in:nil,contentWorld:ComicTranslation.world)as? Bool
        XCTAssertEqual(applied,true)
        let isolated = try await view.evaluateJavaScript("typeof globalThis.zeusComic") as? String
        XCTAssertEqual(isolated,"undefined")
        let removedSource = try await view.evaluateJavaScript("document.querySelector('#source').hasAttribute('srcset')") as? Bool
        XCTAssertEqual(removedSource,false)
        _ = try await view.callAsyncJavaScript("zeusComic.restore()",arguments:[:],in:nil,contentWorld:ComicTranslation.world)
        let restoredSource = try await view.evaluateJavaScript("document.querySelector('#source').hasAttribute('srcset')") as? Bool
        XCTAssertEqual(restoredSource,true)
        let stale = try await view.callAsyncJavaScript("return await zeusComic.apply(id,revision,data,region,mark,generation)",arguments:arguments,in:nil,contentWorld:ComicTranslation.world) as? Bool
        XCTAssertEqual(stale,false)
    }
    func testOCRAndTranslationCachesAreSeparateAndProfileScoped()async throws{
        let first=UUID(),second=UUID(),bytes=Data("reading".utf8)
        try await ComicMemory.shared.save(bytes,profile:first,layer:.reading,key:"same")
        let found=await ComicMemory.shared.data(profile:first,layer:.reading,key:"same"),other=await ComicMemory.shared.data(profile:second,layer:.reading,key:"same"),translation=await ComicMemory.shared.data(profile:first,layer:.translation,key:"same")
        XCTAssertEqual(found,bytes);XCTAssertNil(other);XCTAssertNil(translation);try await ComicMemory.shared.clear(profile:first)
    }
}
