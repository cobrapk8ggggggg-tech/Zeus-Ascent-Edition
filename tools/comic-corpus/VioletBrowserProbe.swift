import XCTest
import UIKit
import WebKit
import CryptoKit
@testable import ZEUSNext

@MainActor final class NativeComicTranslationTests:XCTestCase{
    func testLiveVioletReaderWithRestorationDisabled()async throws{
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
            let result=try? await view.callAsyncJavaScript("const i=[...document.images].find(e=>e.currentSrc===expected&&e.complete&&e.naturalWidth===720);if(!i||!globalThis.zeusComic)return false;globalThis.__violetLiveTestPanel=i;window.scrollTo(0,i.getBoundingClientRect().top+scrollY+2);return true;",arguments:["expected":imageURL],in:nil,contentWorld:ComicTranslation.world)
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
        _=try await view.callAsyncJavaScript("const i=globalThis.__violetLiveTestPanel;const r=i.getBoundingClientRect();window.scrollTo(0,scrollY+r.top+1500*r.height/i.naturalHeight);return true;",arguments:[:],in:nil,contentWorld:ComicTranslation.world)
        try await Task.sleep(for:.milliseconds(300))
        attach(try await view.takeSnapshot(configuration:nil),"Live Violet real site translated in the browser")
        XCTAssertGreaterThanOrEqual(session.detectedTexts,4);XCTAssertGreaterThanOrEqual(session.translatedTexts,4);XCTAssertGreaterThan(session.completed,0);XCTAssertEqual(painted,true)
    }
    private func attach(_ image:UIImage,_ name:String){let a=XCTAttachment(image:image);a.name=name;a.lifetime = .keepAlways;add(a)}
}
