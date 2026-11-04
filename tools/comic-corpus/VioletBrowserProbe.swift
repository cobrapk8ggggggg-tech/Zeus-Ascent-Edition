import XCTest
import UIKit
import WebKit
import CryptoKit
@testable import ZEUSNext

@MainActor final class NativeComicTranslationTests:XCTestCase{
    func testLiveVioletReaderFlatAndComplexBalloons()async throws{
        let pageURL="https://violetmanga.com/the-broken-ring-this-marriage-will-fail-anyway-chapter-1/"
        let imageURL="https://violetmanga.com/wp-content/uploads/manga/the-broken-ring-this-marriage-will-fail-anyway/1/1.jpeg"
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model=BrowserModel(profiles:ProfileStore(root:root,downloadsRoot:root.appendingPathComponent("Downloads")),useBackgroundDownloads:false)
        var preferences=ComicPreferences();preferences.mode = .fastest;preferences.engine = .google;preferences.restorationEnabled=false;preferences.showUntranslated=true;preferences.readAhead=false
        var translation=TranslationPreferences();translation.target="ar";preferences.translation=translation;model.data.settings.comicTranslation=preferences
        let tab=try XCTUnwrap(model.current);tab.url=pageURL
        let prepared=await model.prepare(tab),view=try XCTUnwrap(prepared),session=try XCTUnwrap(tab.comicTranslation)
        let scene=try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap{$0 as? UIWindowScene}.first)
        let window=UIWindow(windowScene:scene);window.frame=scene.screen.bounds;window.rootViewController=UIViewController();view.frame=window.bounds;window.rootViewController?.view.addSubview(view);window.windowLevel = .normal+1;window.makeKeyAndVisible()
        defer{tab.dispose();window.isHidden=true;try? FileManager.default.removeItem(at:root)}
        view.load(URLRequest(url:URL(string:pageURL)!))
        let loaded=Date();var deadline=Date().addingTimeInterval(60),found=false
        while Date()<deadline{
            let result=try? await view.callAsyncJavaScript("document.querySelector('#tcbp-overlay.is-visible .tcbp-close')?.click();const i=[...document.images].find(e=>e.currentSrc===expected&&e.complete&&e.naturalWidth===720);if(!i||!globalThis.zeusComic)return false;globalThis.__violetLiveTestPanel=i;globalThis.__violetOriginalPanels={};for(const e of document.images){for(const u of [e.currentSrc,e.src,e.getAttribute('data-src'),e.getAttribute('data-lazy-src')]){if(u)globalThis.__violetOriginalPanels[u]=e;}}window.scrollTo({top:i.getBoundingClientRect().top+scrollY+2,behavior:'instant'});return true;",arguments:["expected":imageURL],in:nil,contentWorld:ComicTranslation.world)
            if result as? Bool==true{found=true;break}
            try await Task.sleep(for:.milliseconds(250))
        }
        guard found else{
            let shot=try await view.takeSnapshot(configuration:nil);attach(shot,"Live Violet source unavailable")
            throw XCTSkip("The external Violet reader could not load its pinned image. This is not evidence that the image feature passed.")
        }
        var request=URLRequest(url:URL(string:imageURL)!);request.setValue(pageURL,forHTTPHeaderField:"Referer");request.setValue("Mozilla/5.0",forHTTPHeaderField:"User-Agent")
        let (source,response)=try await URLSession.shared.data(for:request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode,200)
        let expected="996af00e178db967b0a2f44a803770f6d2df0d5be46175898343d6f5fee6e9e8"
        let digest=SHA256.hash(data:source).map{String(format:"%02x",$0)}.joined();XCTAssertEqual(digest,expected)
        let began=Date();session.start();deadline=Date().addingTimeInterval(100);var firstPaint:Double?
        while Date()<deadline{
            if session.translatedTexts>0 && firstPaint==nil{firstPaint=Date().timeIntervalSince(began)}
            if session.completed>0 && session.translatedTexts>=4{break}
            if session.error != nil && !session.running{break}
            try await Task.sleep(for:.milliseconds(200))
        }
        let painted=(try? await view.callAsyncJavaScript("const i=globalThis.__violetLiveTestPanel;return !!i&&(i.src.startsWith('blob:')||i.style.backgroundImage.includes('blob:'));",arguments:[:],in:nil,contentWorld:ComicTranslation.world))as? Bool
        let report:[String:String]=["source_url":pageURL,"image_url":imageURL,"source_sha256":digest,"restoration_enabled":"false","mode":"fastest","source_language":"auto","translation_engine":"Google actual service","source_load_seconds":String(began.timeIntervalSince(loaded)),"first_paint_seconds":firstPaint.map{String($0)} ?? "none","elapsed_seconds":String(Date().timeIntervalSince(began)),"detected":String(session.detectedTexts),"translated":String(session.translatedTexts),"applied_regions":String(session.completed),"painted":String(painted ?? false),"error":session.error ?? "none","notice":session.contextNotice ?? "none","physical_device_quality_proven":"false"]
        let note=XCTAttachment(data:try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]),uniformTypeIdentifier:"public.json");note.name="live-violet-browser-report";note.lifetime = .keepAlways;add(note)
        // The chapter starts with a tall, deliberately empty image area. Show
        // its first actual dialogue in the screenshot, not only that background.
        _=try await view.callAsyncJavaScript("const i=globalThis.__violetLiveTestPanel;const r=i.getBoundingClientRect();document.querySelector('#tcbp-overlay.is-visible .tcbp-close')?.click();window.scrollTo({top:scrollY+r.top+1500*r.height/i.naturalHeight,behavior:'instant'});return true;",arguments:[:],in:nil,contentWorld:ComicTranslation.world)
        try await Task.sleep(for:.milliseconds(300))
        attach(try await view.takeSnapshot(configuration:nil),"Live Violet real site translated in the browser")
        let applied=try await view.callAsyncJavaScript("const i=globalThis.__violetLiveTestPanel;const b=await fetch(i.src).then(r=>r.blob());return await new Promise((resolve,reject)=>{const r=new FileReader();r.onload=()=>resolve(r.result.split(',')[1]);r.onerror=reject;r.readAsDataURL(b);});",arguments:[:],in:nil,contentWorld:ComicTranslation.world)as? String
        let appliedBytes=try XCTUnwrap(Data(base64Encoded:try XCTUnwrap(applied)))
        attach(try XCTUnwrap(UIImage(data:appliedBytes)),"Live Violet actual applied image pixels")
        XCTAssertGreaterThanOrEqual(session.detectedTexts,4);XCTAssertGreaterThanOrEqual(session.translatedTexts,4);XCTAssertGreaterThan(session.completed,0);XCTAssertEqual(painted,true)
        // Continue scrolling the real chapter, including its coloured captions,
        // connected balloons and outside lettering. Counts are observations, not
        // annotated recall or a claim that each source bubble was translated.
        let chapterURLs:[String]=["https://violetmanga.com/wp-content/uploads/manga/the-broken-ring-this-marriage-will-fail-anyway/1/0.jpeg", "https://violetmanga.com/wp-content/uploads/manga/the-broken-ring-this-marriage-will-fail-anyway/1/1.jpeg", "https://violetmanga.com/wp-content/uploads/manga/the-broken-ring-this-marriage-will-fail-anyway/1/2.jpeg", "https://violetmanga.com/wp-content/uploads/manga/the-broken-ring-this-marriage-will-fail-anyway/1/3.jpeg", "https://violetmanga.com/wp-content/uploads/manga/the-broken-ring-this-marriage-will-fail-anyway/1/4.jpeg", "https://violetmanga.com/wp-content/uploads/manga/the-broken-ring-this-marriage-will-fail-anyway/1/5.jpeg", "https://violetmanga.com/wp-content/uploads/manga/the-broken-ring-this-marriage-will-fail-anyway/1/6.jpeg", "https://violetmanga.com/wp-content/uploads/manga/the-broken-ring-this-marriage-will-fail-anyway/1/7.jpeg", "https://violetmanga.com/wp-content/uploads/manga/the-broken-ring-this-marriage-will-fail-anyway/1/8.jpeg", "https://violetmanga.com/wp-content/uploads/manga/the-broken-ring-this-marriage-will-fail-anyway/1/9.jpeg", "https://violetmanga.com/wp-content/uploads/manga/the-broken-ring-this-marriage-will-fail-anyway/1/10.jpeg", "https://violetmanga.com/wp-content/uploads/manga/the-broken-ring-this-marriage-will-fail-anyway/1/11.jpeg", "https://violetmanga.com/wp-content/uploads/manga/the-broken-ring-this-marriage-will-fail-anyway/1/12.jpeg", "https://violetmanga.com/wp-content/uploads/manga/the-broken-ring-this-marriage-will-fail-anyway/1/13.jpeg", "https://violetmanga.com/wp-content/uploads/manga/the-broken-ring-this-marriage-will-fail-anyway/1/14.jpeg", "https://violetmanga.com/wp-content/uploads/manga/the-broken-ring-this-marriage-will-fail-anyway/1/15.jpeg", "https://violetmanga.com/wp-content/uploads/manga/the-broken-ring-this-marriage-will-fail-anyway/1/16.jpeg", "https://violetmanga.com/wp-content/uploads/manga/the-broken-ring-this-marriage-will-fail-anyway/1/17.jpeg", "https://violetmanga.com/wp-content/uploads/manga/the-broken-ring-this-marriage-will-fail-anyway/1/18.jpeg", "https://violetmanga.com/wp-content/uploads/manga/the-broken-ring-this-marriage-will-fail-anyway/1/19.jpg", "https://violetmanga.com/wp-content/uploads/manga/the-broken-ring-this-marriage-will-fail-anyway/1/20.jpg", "https://violetmanga.com/wp-content/uploads/manga/the-broken-ring-this-marriage-will-fail-anyway/1/21.jpeg"]
        var pageReports:[[String:String]]=[]
        let normalDialoguePages:Set<Int>=[0,1,5,8,9,10,11,12,14,15,17,19]
        for(index,url)in chapterURLs.enumerated(){
            session.pause()
            // The final pages have translucent balloons with real artwork
            // showing through their paper. Keep every ordinary-page assertion,
            // and exercise their actual complex restoration after proving the
            // first scanning eighteen pages and proving the initial flat dialogues without it.
            if index==18{preferences.restorationEnabled=true;model.data.settings.comicTranslation=preferences}
            let pageBegan=Date();var available=false
            deadline=Date().addingTimeInterval(25)
            while Date()<deadline{
                let value=try? await view.callAsyncJavaScript("document.querySelector('#tcbp-overlay.is-visible .tcbp-close')?.click();globalThis.__violetChapterPanels ??= {};let i=globalThis.__violetChapterPanels[index];if(!i?.isConnected){const original=globalThis.__violetOriginalPanels[expected];i=original?.isConnected?original:[...document.images].find(e=>[e.currentSrc,e.src,e.getAttribute('data-src'),e.getAttribute('data-lazy-src')].includes(expected));if(i)globalThis.__violetChapterPanels[index]=i;}if(!i)return false;const r=i.getBoundingClientRect();window.scrollTo({top:r.top+scrollY+Math.min(1500,i.naturalHeight/2)*r.height/Math.max(1,i.naturalHeight),behavior:'instant'});await new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(resolve)));const b=i.getBoundingClientRect();return i.isConnected&&i.complete&&i.naturalWidth===720&&b.height>0&&b.bottom>0&&b.top<innerHeight;",arguments:["expected":url,"index":index],in:nil,contentWorld:ComicTranslation.world)
                if value as? Bool==true{available=true;break}
                try await Task.sleep(for:.milliseconds(200))
            }
            if !available{pageReports.append(["image":url,"loaded":"false","painted":"false"]);XCTFail("The live chapter image did not load: "+url);continue}
            let geometry=try await view.callAsyncJavaScript("const i=globalThis.__violetChapterPanels[index],r=i.getBoundingClientRect(),s=zeusComic.scan(false);return JSON.stringify({connected:i.isConnected,top:r.top,bottom:r.bottom,scroll:s.scroll,viewport:s.viewport,candidates:s.items.map(c=>({id:c.id,image:c.source.includes('/the-broken-ring-this-marriage-will-fail-anyway/1/')?c.source.split('/').pop():'other',top:c.y-s.scroll,height:c.h,pending:c.pending}))});",arguments:["index":index],in:nil,contentWorld:ComicTranslation.world)as? String ?? "unavailable"
            let detectedBefore=session.detectedTexts,translatedBefore=session.translatedTexts,ocrBefore=session.ocrRuns
            session.start();deadline=Date().addingTimeInterval(preferences.restorationEnabled==true ? 90:45);var pagePainted=false;var firstPagePaint:Double?;var idleSince:Date?
            while Date()<deadline{
                let value=try? await view.callAsyncJavaScript("const i=globalThis.__violetChapterPanels[index];return !!i&&(i.src.startsWith('blob:')||i.style.backgroundImage.includes('blob:'));",arguments:["index":index],in:nil,contentWorld:ComicTranslation.world)
                pagePainted=value as? Bool==true
                if pagePainted && firstPagePaint==nil{firstPagePaint=Date().timeIntervalSince(pageBegan)}
                // A blob can be the early simple-dialogue preview. Wait for
                // the worker to settle before inspecting or pausing this page;
                // otherwise the test cancels its still-running reconstruction.
                if session.running{idleSince=nil}else if let idleSince,Date().timeIntervalSince(idleSince)>1.5{break}else if idleSince==nil{idleSince=Date()}
                try await Task.sleep(for:.milliseconds(200))
            }
            pageReports.append(["image":url,"loaded":"true","painted":String(pagePainted),"restoration_enabled":String(preferences.restorationEnabled==true),"first_paint_seconds":firstPagePaint.map{String($0)} ?? "none","seconds":String(Date().timeIntervalSince(pageBegan)),"ocr_runs_delta":String(session.ocrRuns-ocrBefore),"viewport_before":geometry,"detected_delta":String(session.detectedTexts-detectedBefore),"translated_delta":String(session.translatedTexts-translatedBefore),"error":session.error ?? "none","notice":session.contextNotice ?? "none"])
            print("VIOLET LIVE PAGE \(index) painted=\(pagePainted) detected=\(session.detectedTexts) translated=\(session.translatedTexts) OCR=\(session.ocrRuns-ocrBefore) geometry=\(geometry)")
            if normalDialoguePages.contains(index){XCTAssertTrue(pagePainted,"A page with ordinary readable dialogue must paint: "+url)}
            if pagePainted{
                let bytes=try await view.callAsyncJavaScript("const i=globalThis.__violetChapterPanels[index];if(!i.src.startsWith('blob:'))return null;const b=await fetch(i.src).then(r=>r.blob());return await new Promise((resolve,reject)=>{const r=new FileReader();r.onload=()=>resolve(r.result.split(',')[1]);r.onerror=reject;r.readAsDataURL(b);});",arguments:["index":index],in:nil,contentWorld:ComicTranslation.world)as? String
                if let bytes,let data=Data(base64Encoded:bytes),let image=UIImage(data:data){attach(image,"Live Violet applied pixels page \(index)")}
            }
            if [0,5,12,18,20].contains(index){attach(try await view.takeSnapshot(configuration:nil),"Live Violet chapter page \(index)")}
        }
        session.pause()
        let sweep=XCTAttachment(data:try JSONSerialization.data(withJSONObject:pageReports,options:[.prettyPrinted,.sortedKeys]),uniformTypeIdentifier:"public.json");sweep.name="live-violet-full-chapter-observations";sweep.lifetime = .keepAlways;add(sweep)
    }
    private func attach(_ image:UIImage,_ name:String){let a=XCTAttachment(image:image);a.name=name;a.lifetime = .keepAlways;add(a)}
}
