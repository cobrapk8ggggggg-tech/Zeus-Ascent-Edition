import XCTest
import UIKit
import WebKit
@testable import ZEUSNext

@MainActor final class NativeComicTranslationTests:XCTestCase{
    func testOriginalAsuraConnectedBalloonAndSmallNotificationOCR()async throws{
        for (file,expected) in [("002.webp",["ALRIGHT","GUYS"]),("009.webp",["NOTIFICATION","UNDERGROUND"]) ]{
            let(data,_)=try await URLSession.shared.data(from:URL(string:"http://127.0.0.1:8781/images/"+file)!)
            let areas=file=="009.webp" ? [CGRect(x:0,y:12188,width:800,height:3812)]:[CGRect(x:0,y:0,width:800,height:3300)]
            for area in areas{
                let image=try ComicPixels.decodeRegion(data,region:ComicRegion(y:Int(area.minY),width:Int(area.width),height:Int(area.height),coreTop:0,coreBottom:Int(area.height)),expectedHeight:file=="009.webp" ? 16000:3300)
                let reading=try await ComicOCR.shared.read(image,source:"auto",mode:.fastest)
                let text=reading.lines.map(\.text).joined(separator:" ").uppercased()
                for token in expected{XCTAssertTrue(text.contains(token),"Fast local OCR missed \(token): \(text)")}
                let attachment=XCTAttachment(data:try JSONEncoder().encode(reading),uniformTypeIdentifier:"public.json");attachment.name="Asura actual fastest geometry "+file;attachment.lifetime = .keepAlways;add(attachment)
                if file=="002.webp"{
                    let first=reading.speeches.filter{$0.text.uppercased().contains("ALRIGHT")}
                    XCTAssertEqual(first.count,1)
                    XCTAssertFalse(first.contains{$0.text.uppercased().contains("GUYS")},"The upper connected lobe must be a separate provider segment")
                }
            }
        }
    }
    func testEntireOriginalChapterPreparesWithoutScrolling()async throws{
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model=BrowserModel(profiles:ProfileStore(root:root,downloadsRoot:root.appendingPathComponent("Downloads")),useBackgroundDownloads:false)
        model.data.settings.shieldsEnabled=false
        var prefs=ComicPreferences();prefs.mode = .fastest;prefs.engine = .google;prefs.restorationEnabled=true;prefs.readAhead=true;prefs.showUntranslated=true;prefs.source="auto"
        var translation=TranslationPreferences();translation.target="ar";prefs.translation=translation;model.data.settings.comicTranslation=prefs
        let tab=try XCTUnwrap(model.current);tab.url="http://127.0.0.1:8781/index.html"
        let prepared=await model.prepare(tab),view=try XCTUnwrap(prepared),session=try XCTUnwrap(tab.comicTranslation)
        let scene=try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap{$0 as? UIWindowScene}.first)
        let window=UIWindow(windowScene:scene);window.frame=scene.screen.bounds;window.rootViewController=UIViewController();view.frame=window.bounds;window.rootViewController?.view.addSubview(view);window.makeKeyAndVisible()
        defer{session.pause();tab.dispose();window.isHidden=true;try? FileManager.default.removeItem(at:root)}
        view.load(URLRequest(url:URL(string:tab.url)!))
        var deadline=Date().addingTimeInterval(30)
        while Date()<deadline{if (try? await view.evaluateJavaScript("document.images.length"))as? Int==27{break};try await Task.sleep(for:.milliseconds(200))}
        var audits:[[String:Any]]=[]
        session.onRegionAudit={reading,translations,reasons in
            guard let data=try? JSONEncoder().encode(reading),let geometry=try? JSONSerialization.jsonObject(with:data),
                  let texts=try? JSONEncoder().encode(translations),let translated=try? JSONSerialization.jsonObject(with:texts)else{return}
            audits.append(["reading":geometry,"translations":translated,"unresolved_reasons":reasons])
        }
        let began=Date();session.start();deadline=began.addingTimeInterval(1600);var idle:Date?,firstPaint:Double?
        while Date()<deadline{
            if firstPaint==nil && session.translatedTexts>0{firstPaint=Date().timeIntervalSince(began)}
            if session.running || session.phase == .waiting{idle=nil}else{if idle==nil{idle=Date()};if Date().timeIntervalSince(idle!)>10{break}}
            try await Task.sleep(for:.milliseconds(500))
        }
        let scroll=try await view.evaluateJavaScript("scrollY")as? Double;XCTAssertEqual(scroll,0)
        let states=try await view.callAsyncJavaScript("return [...document.images].map(i=>({index:i.dataset.pageIndex,painted:i.src.startsWith('blob:')||i.style.backgroundImage.includes('blob:'),loaded:i.complete,source:i.src.slice(0,100)}))",arguments:[:],in:nil,contentWorld:ComicTranslation.world)
        let rows=try XCTUnwrap(states as? [[String:Any]])
        XCTAssertEqual(rows.count,27);XCTAssertFalse(session.running,"Whole chapter exceeded the bounded test deadline")
        XCTAssertGreaterThan(session.detectedTexts,100,"The queue must discover dialogue far beyond the initial viewport")
        XCTAssertTrue(rows.contains{$0["index"]as? String=="25" && $0["painted"]as? Bool==true},"The last story image must be processed without a scroll")
        let report:[String:Any]=["source":"Asura chapter 2, 27 SHA-pinned originals","mode":"fastest, restoration on, Google Arabic","scroll":scroll ?? -1,"seconds":Date().timeIntervalSince(began),"first_paint_seconds":firstPaint.map{$0 as Any} ?? NSNull(),"detected":session.detectedTexts,"ready":session.translatedTexts,"regions":session.completed,"ocr_runs":session.ocrRuns,"phase_seconds":session.phaseSeconds,"region_audits":audits,"phase":session.phase.rawValue,"notice":session.contextNotice ?? "","error":session.error ?? "","images":rows]
        let attachment=XCTAttachment(data:try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]),uniformTypeIdentifier:"public.json");attachment.name="Asura entire chapter without scrolling measured results";attachment.lifetime = .keepAlways;add(attachment)
        for index in [1,2,3,5,9,17,25]{
            // Export the actual applied PNG patches, not a URL or early preview.
            let value=try await view.callAsyncJavaScript("const i=document.images[index],urls=[i.src,...[...i.style.backgroundImage.matchAll(/url\\([\"']?([^\"')]+)[\"']?\\)/g)].map(m=>m[1])].filter(u=>u.startsWith('blob:'));const out=[];for(const url of [...new Set(urls)]){const b=await(await fetch(url)).blob();if(b.type!=='image/png')continue;const bytes=new Uint8Array(await b.arrayBuffer());let raw='';for(let n=0;n<bytes.length;n+=8192)raw+=String.fromCharCode(...bytes.subarray(n,n+8192));out.push(btoa(raw));}return out;",arguments:["index":index],in:nil,contentWorld:ComicTranslation.world)
            for (part,encoded) in ((value as? [String]) ?? []).enumerated(){
                guard let data=Data(base64Encoded:encoded),let image=UIImage(data:data)else{XCTFail("Unreadable applied PNG");continue}
                let attachment=XCTAttachment(image:image);attachment.name="Asura original chapter applied image \(index) part \(part)";attachment.lifetime = .keepAlways;add(attachment)
            }
        }
    }
}
