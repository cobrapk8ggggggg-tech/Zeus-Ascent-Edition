import XCTest
import WebKit
import UIKit
#if canImport(ZEUSBrowser)
@testable import ZEUSBrowser
#else
@testable import ZEUSNext
#endif

@MainActor final class NativeComicTranslationTests:XCTestCase{
    func testReferrerPoliciesAndRenderInvalidation() throws {
        let page=URL(string:"https://reader.example/chapter?part=1#text")!,cdn=URL(string:"https://cdn.example/panel.webp")!
        XCTAssertNil(ComicImageFetch.referrer(page:page,destination:cdn,policy:"no-referrer"))
        XCTAssertEqual(ComicImageFetch.referrer(page:page,destination:cdn,policy:nil),"https://reader.example/")
        XCTAssertEqual(ComicImageFetch.referrer(page:page,destination:page,policy:nil),"https://reader.example/chapter?part=1")
        XCTAssertNil(ComicImageFetch.referrer(page:page,destination:URL(string:"http://cdn.example/panel.png")!,policy:nil))
        XCTAssertNil(ComicImageFetch.referrer(page:page,destination:URL(string:"https://reader.example:8443/panel.png")!,policy:"same-origin"))
        var p=ComicPreferences();let original=p.renderIdentity;p.inkStyle = .outline
        XCTAssertNotEqual(original,p.renderIdentity)
        let ink=p.renderIdentity;p.letterSpacing=2;XCTAssertNotEqual(ink,p.renderIdentity)
        XCTAssertEqual(ComicLetterCase.sentence.apply("HELLO! NEXT."),"Hello! Next.")
        let legacy=try JSONDecoder().decode(ComicPreferences.self,from:JSONEncoder().encode(ComicPreferences()))
        XCTAssertEqual(legacy.letterCase,.original)
    }
    func testGroupedReadingMenuIncludesBothTranslationModes() {
        XCTAssertTrue(BrowserActionGroup.reading.actions.contains(.translate))
        XCTAssertTrue(BrowserActionGroup.reading.actions.contains(.translateImages))
        XCTAssertNotEqual(BrowserAction.translate.identifier, BrowserAction.translateImages.identifier)
        XCTAssertEqual(SettingsCategory.imageTranslation.title, "ترجمة الصور والمانهوا")
    }
    private func renderer(_ size:CGSize)->UIGraphicsImageRenderer{let format=UIGraphicsImageRendererFormat();format.scale=1;return UIGraphicsImageRenderer(size:size,format:format)}
    func testContextWindowCacheSeparatesOwnedSpeechSubsets() {
        let first=[TranslationSegment(id:"upper",text:"HELLO")]
        let second=[TranslationSegment(id:"lower",text:"GOODBYE")]
        XCTAssertNotEqual(ComicIdentity.segmentIdentity(first),ComicIdentity.segmentIdentity(second))
        XCTAssertNotEqual(ComicIdentity.segmentIdentity(first),ComicIdentity.segmentIdentity(first+second))
        XCTAssertEqual(ComicIdentity.segmentIdentity(first),ComicIdentity.segmentIdentity(first))
    }
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
    func testArabicLetteringChangesActualPixelsInsideTheBalloon()throws{
        let raster=renderer(CGSize(width:320,height:200)).image{context in
            UIColor.white.setFill();context.fill(CGRect(x:0,y:0,width:320,height:200))
            ("HELLO" as NSString).draw(at:CGPoint(x:90,y:40),withAttributes:[.font:UIFont.systemFont(ofSize:32),.foregroundColor:UIColor.black])
        }
        let line=ComicLine(text:"HELLO",confidence:1,rect:CGRect(x:88,y:40,width:120,height:40))
        let speech=ComicSpeech(id:"0",text:"HELLO",lines:[line],rect:CGRect(x:55,y:20,width:210,height:90),vertical:false,balloon:true)
        let output=try ComicPixels.render(try XCTUnwrap(raster.cgImage),speeches:[speech],translations:[TranslationSegment(id:"0",text:"مرحبًا يا صديقي")],target:"ar",fontName:nil,fontScale:1,textColor:"163B72")
        let pixels=try XCTUnwrap(ComicPixels.rgba(output,width:320,height:200))
        var blue=0,outside=0
        for y in 0..<200{for x in 0..<320{let i=(y*320+x)*4
            if Int(pixels[i+2])>Int(pixels[i])+25 && Int(pixels[i+2])>Int(pixels[i+1])+15{blue+=1;if !speech.rect.contains(CGPoint(x:x,y:y)){outside+=1}}
        }}
        XCTAssertGreaterThan(blue,50,"CoreText must draw the selected color into the image")
        XCTAssertEqual(outside,0,"Arabic lettering must remain inside the original balloon")
        let attachment=XCTAttachment(image:UIImage(cgImage:output));attachment.name="Arabic lettering - actual pixels";attachment.lifetime = .keepAlways;add(attachment)
    }
    func testExplicitBaselineAngleAndRotatedLetteringStaysInsideBounds()throws{
        // A thought tail drifting down-right: three overlapping OCR lines.
        func line(_ x:CGFloat,_ y:CGFloat)->ComicLine{ComicLine(text:"TAIL",confidence:0.9,rect:CGRect(x:x,y:y,width:110,height:20),angle:atan2(48,120))}
        let lines=[line(10,20),line(70,44),line(130,68)]
        let grouped=ComicGeometry.group(lines,source:"en")
        XCTAssertEqual(grouped.count,1,"overlapping diagonal lines form one speech")
        XCTAssertEqual(grouped.first?.angle ?? 0,atan2(48,120),accuracy:0.02,"OCR baselines supply the lettering angle")
        let paragraph=lines.map{line -> ComicLine in var line=line;line.angle=0;return line}
        XCTAssertEqual(ComicGeometry.estimateAngle(paragraph),0,"indented paragraph centres must never tilt the translation")
        let speech=ComicSpeech(id:"tail",text:"TAIL\nTAIL\nTAIL",lines:lines,rect:CGRect(x:10,y:20,width:230,height:68),vertical:false,balloon:true,angle:ComicGeometry.estimateAngle(lines))
        let image=renderer(CGSize(width:260,height:160)).image{context in UIColor.white.setFill();context.fill(CGRect(x:0,y:0,width:260,height:160))}.cgImage!
        let drawn=try ComicPixels.render(image,speeches:[speech],translations:[TranslationSegment(id:"tail",text:"ترجمة")],target:"ar",fontName:nil,fontScale:1)
        let pixels=try XCTUnwrap(ComicPixels.rgba(drawn,width:260,height:160))
        var inside=0,outside=0
        for y in 0..<160{for x in 0..<260{
            let i=(y*260+x)*4,dark=Int(pixels[i])<128
            if !dark{continue}
            if speech.rect.insetBy(dx:-6,dy:-6).contains(CGPoint(x:x,y:y)){inside+=1}else{outside+=1}
        }}
        XCTAssertGreaterThan(inside,10,"rotated lettering must change pixels inside the speech area")
        XCTAssertEqual(outside,0,"rotated lettering must never paint outside the speech it belongs to")
        let attachment=XCTAttachment(image:UIImage(cgImage:drawn));attachment.name="Rotated tail lettering";attachment.lifetime = .keepAlways;add(attachment)
    }
    func testRealComicCropsRenderThroughProductionCoreText()async throws{
        struct Line:Decodable{var text:String;var confidence:Float;var x:Double;var y:Double;var width:Double;var height:Double;var glyphHeight:Double}
        struct Fixture:Decodable{var id:String;var lines:[Line];var image:String;var translation:String}
        let base="http://127.0.0.1:8765/comic-quality-fixtures"
        let (data,_)=try await URLSession.shared.data(from:URL(string:base)!)
        let names=try JSONDecoder().decode([String].self,from:data);XCTAssertGreaterThanOrEqual(names.count,6)
        for name in names where !name.hasPrefix("neural-"){
            let (data,_)=try await URLSession.shared.data(from:URL(string:base+"?name="+name)!)
            let fixture=try JSONDecoder().decode(Fixture.self,from:data)
            let image=try ComicPixels.decode(XCTUnwrap(Data(base64Encoded:fixture.image)))
            let lines=fixture.lines.map{ComicLine(text:$0.text,confidence:$0.confidence,rect:CGRect(x:$0.x,y:$0.y,width:$0.width,height:$0.height),glyphHeight:$0.glyphHeight)}
            let speeches=ComicBalloons.speeches(lines,image:image,source:"en")
            XCTAssertFalse(speeches.isEmpty)
            let translations=speeches.map{TranslationSegment(id:$0.id,text:fixture.translation)}
            let output=try ComicPixels.render(image,speeches:speeches,translations:translations,target:"ar",fontName:nil,fontScale:1,textColor:"163B72")
            let attachment=XCTAttachment(image:UIImage(cgImage:output));attachment.name="Real comic CoreText - "+fixture.id;attachment.lifetime = .keepAlways;add(attachment)
            let pixels=try XCTUnwrap(ComicPixels.rgba(output,width:output.width,height:output.height))
            XCTAssertTrue(stride(from:0,to:pixels.count,by:4).contains{Int(pixels[$0+2])>Int(pixels[$0])+25},"real comic crop must contain rendered Arabic")
        }
    }
    func testPinnedNeuralRestorationRemovesLetteringOnRealArtwork()async throws{
        struct Line:Decodable{var x:Double;var y:Double;var width:Double;var height:Double;var glyphHeight:Double}
        struct Fixture:Decodable{var lines:[Line];var image:String;var translation:String}
        let url=URL(string:"http://127.0.0.1:8765/comic-quality-fixtures?name=neural-title.json")!
        let(data,_)=try await URLSession.shared.data(from:url),fixture=try JSONDecoder().decode(Fixture.self,from:data)
        let image=try ComicPixels.decode(XCTUnwrap(Data(base64Encoded:fixture.image)))
        let lines=fixture.lines.map{ComicLine(text:"SOURCE",confidence:1,rect:CGRect(x:$0.x,y:$0.y,width:$0.width,height:$0.height),glyphHeight:$0.glyphHeight)}
        let bounds=lines.reduce(CGRect.null){$0.union($1.rect)}
        let speech=ComicSpeech(id:"cover",text:"TITLE",lines:lines,rect:bounds,vertical:false)
        let original=try XCTUnwrap(ComicPixels.rgba(image,width:image.width,height:image.height))
        XCTAssertFalse(ComicPixels.canClean(original,width:image.width,height:image.height,speech:speech),"Artwork must use the neural route instead of harmonic smearing")
        // The simulator test exercises inference independently of its jetsam stub;
        // production callers always retain the 1.2GB available-memory guard.
        let restored=try await ComicRestoration.shared.restore(image,speeches:[speech],requiredHeadroom:0)
        XCTAssertTrue(restored.restored.contains("cover"))
        let pixels=try XCTUnwrap(ComicPixels.rgba(restored.image,width:image.width,height:image.height))
        var before=0,after=0,outside=0
        for y in 0..<image.height{for x in 0..<image.width{let i=(y*image.width+x)*4
            if original[i]>235 && original[i+1]>235 && original[i+2]>235{before+=1}
            if pixels[i]>235 && pixels[i+1]>235 && pixels[i+2]>235{after+=1}
            if !lines.contains(where:{$0.rect.insetBy(dx:-20,dy:-20).contains(CGPoint(x:x,y:y))}) && (0..<4).contains(where:{original[i+$0] != pixels[i+$0]}){outside+=1}
        }}
        XCTAssertGreaterThan(before,1000);XCTAssertLessThan(after,Int(Double(before)*0.1),"The source white title ink must disappear")
        XCTAssertEqual(outside,0,"Restoration must preserve artwork beyond the owned text regions")
        let drawn=try ComicPixels.render(restored.image,speeches:[speech],translations:[TranslationSegment(id:"cover",text:fixture.translation)],target:"ar",fontName:nil,fontScale:1,requireCleanSource:true,precleanedIDs:restored.restored)
        for (name,output)in [("Neural original artwork",image),("Neural cleaned artwork",restored.image),("Neural Arabic artwork",drawn)]{let attachment=XCTAttachment(image:UIImage(cgImage:output));attachment.name=name;attachment.lifetime = .keepAlways;add(attachment)}
    }
    func testIncompleteCleanupDoesNotPaintOverOriginal()throws{
        let image=renderer(CGSize(width:200,height:100)).image{context in
            UIColor.white.setFill();context.fill(CGRect(x:0,y:0,width:200,height:100))
        }.cgImage!
        let line=ComicLine(text:"FALSE POSITIVE",confidence:0.8,rect:CGRect(x:30,y:30,width:140,height:30))
        let speech=ComicSpeech(id:"0",text:line.text,lines:[line],rect:line.rect,vertical:false)
        XCTAssertThrowsError(try ComicPixels.render(image,speeches:[speech],translations:[TranslationSegment(id:"0",text:"ترجمة")],target:"ar",fontName:nil,fontScale:1,requireCleanSource:true))
    }
    func testUnreadableTranslationKeepsOriginalInsteadOfMicroscopicLettering()throws{
        let image=renderer(CGSize(width:200,height:100)).image{context in
            UIColor.white.setFill();context.fill(CGRect(x:0,y:0,width:200,height:100))
            ("HELLO" as NSString).draw(at:CGPoint(x:40,y:30),withAttributes:[.font:UIFont.boldSystemFont(ofSize:30),.foregroundColor:UIColor.black])
        }.cgImage!
        let line=ComicLine(text:"HELLO",confidence:1,rect:CGRect(x:40,y:35,width:110,height:30))
        let speech=ComicSpeech(id:"0",text:line.text,lines:[line],rect:line.rect,vertical:false)
        XCTAssertThrowsError(try ComicPixels.render(image,speeches:[speech],translations:[TranslationSegment(id:"0",text:String(repeating:"هل يمكنكم مساعدتنا؟ ",count:20))],target:"ar",fontName:nil,fontScale:1,requireCleanSource:true))
    }
    func testUnplatedVerticalArabicKeepsWholeRotatedWords()throws{
        let image=renderer(CGSize(width:200,height:500)).image{context in UIColor.white.setFill();context.fill(CGRect(x:0,y:0,width:200,height:500))}.cgImage!
        let line=ComicLine(text:"VERTICAL TITLE",confidence:1,rect:CGRect(x:80,y:50,width:30,height:400),angle:.pi/2,glyphHeight:24)
        let speech=ComicSpeech(id:"0",text:line.text,lines:[line],rect:line.rect,vertical:true)
        let output=try ComicPixels.render(image,speeches:[speech],translations:[TranslationSegment(id:"0",text:"قاتل الظل")],target:"ar",fontName:nil,fontScale:1,textColor:"163B72")
        let pixels=try XCTUnwrap(ComicPixels.rgba(output,width:200,height:500));var bounds=CGRect.null
        for y in 0..<500{for x in 0..<200{let i=(y*200+x)*4;if Int(pixels[i+2])>Int(pixels[i])+25{bounds=bounds.union(CGRect(x:x,y:y,width:1,height:1))}}}
        XCTAssertGreaterThan(bounds.height,60);XCTAssertGreaterThan(bounds.height,bounds.width*2)
        XCTAssertTrue(speech.rect.insetBy(dx:-5,dy:-5).contains(bounds))
        let attachment=XCTAttachment(image:UIImage(cgImage:output));attachment.name="Whole Arabic words in a vertical caption";attachment.lifetime = .keepAlways;add(attachment)
    }
    func testNarrowArabicLayoutDoesNotSplitWordsIntoIsolatedGlyphs()throws{
        let value=try XCTUnwrap(ComicPixels.layout("المستقبل",rect:CGRect(x:0,y:0,width:20,height:400),target:"ar",fontName:nil,fontScale:1,maximumSize:40))
        XCTAssertLessThan(value.size,12,"A narrow column must fit the entire Arabic word, not stack isolated letters")
    }
    func testLargeSourceLetteringIsNotCappedAtBodyTextSize()throws{
        let value=try XCTUnwrap(ComicPixels.layout("استيقظ",rect:CGRect(x:0,y:0,width:500,height:240),target:"ar",fontName:nil,fontScale:1,maximumSize:180))
        XCTAssertGreaterThan(value.size,110,"large source SFX must retain its scale")
    }
    func testUnchangedBrandTextPreservesOriginalPixels()throws{
        let image=renderer(CGSize(width:240,height:100)).image{context in
            UIColor.red.setFill();context.fill(CGRect(x:0,y:0,width:240,height:100))
            ("ELFTOON.COM" as NSString).draw(at:CGPoint(x:20,y:35),withAttributes:[.font:UIFont.boldSystemFont(ofSize:24),.foregroundColor:UIColor.white])
        }.cgImage!
        let line=ComicLine(text:"ELFTOON.COM",confidence:1,rect:CGRect(x:20,y:35,width:190,height:30)),speech=ComicSpeech(id:"0",text:"ELFTOON.COM",lines:[line],rect:line.rect,vertical:false)
        let output=try ComicPixels.render(image,speeches:[speech],translations:[TranslationSegment(id:"0",text:"ELFTOON.COM")],target:"ar",fontName:nil,fontScale:1,requireCleanSource:true)
        XCTAssertEqual(ComicPixels.rgba(image,width:240,height:100),ComicPixels.rgba(output,width:240,height:100))
    }
    func testSourceFontCapPreventsOneWordFillingHugeBalloon()throws{
        let short=try XCTUnwrap(ComicPixels.layout("سجن",rect:CGRect(x:0,y:0,width:450,height:350),target:"ar",fontName:nil,fontScale:1,maximumSize:26))
        let long=try XCTUnwrap(ComicPixels.layout("عذرًا، لكن هل يمكنكم مساعدتنا؟",rect:CGRect(x:0,y:0,width:450,height:350),target:"ar",fontName:nil,fontScale:1,maximumSize:26))
        XCTAssertLessThanOrEqual(short.size,26);XCTAssertLessThanOrEqual(long.size,26)
        XCTAssertEqual(short.size,long.size,accuracy:0.5)
    }
    func testOneBalloonOwnsFragmentedAndNestedOCRLinesOnce()throws{
        let image=renderer(CGSize(width:500,height:400)).image{context in
            UIColor.black.setFill();context.fill(CGRect(x:0,y:0,width:500,height:400))
            UIColor.white.setFill();UIBezierPath(ovalIn:CGRect(x:50,y:30,width:400,height:330)).fill()
        }.cgImage!
        let lines=[ComicLine(text:"EXCUSE ME",confidence:0.9,rect:CGRect(x:160,y:120,width:180,height:24)),ComicLine(text:"BUT CAN YOU",confidence:0.9,rect:CGRect(x:145,y:155,width:210,height:24)),ComicLine(text:"HELP US?",confidence:0.9,rect:CGRect(x:170,y:190,width:160,height:24)),ComicLine(text:"ME",confidence:0.5,rect:CGRect(x:270,y:120,width:45,height:24))]
        let speeches=ComicBalloons.speeches(lines,image:image,source:"en")
        XCTAssertEqual(speeches.count,1);XCTAssertEqual(speeches.first?.lines.count,3)
        XCTAssertEqual(speeches.first?.angle,0)
        let translated=try ComicPixels.render(image,speeches:speeches,translations:[TranslationSegment(id:"0",text:"عذرًا، لكن هل يمكنكم مساعدتنا؟")],target:"ar",fontName:nil,fontScale:1)
        let attachment=XCTAttachment(image:UIImage(cgImage:translated));attachment.name="One balloon one paragraph - source sized Arabic";attachment.lifetime = .keepAlways;add(attachment)
    }
    func testCleanupRemovesOutlinedOriginalOnLightAndDarkGradients()throws{
        for dark in [false,true]{
            let size=CGSize(width:480,height:300)
            func raster(text:Bool)->CGImage{renderer(size).image{ctx in
                for y in 0..<300{let v=CGFloat(y)/1200+(dark ? 0.02:0.7);UIColor(red:v,green:v,blue:min(1,v+0.04),alpha:1).setFill();ctx.fill(CGRect(x:0,y:y,width:480,height:1))}
                if text{("EXCUSE ME" as NSString).draw(at:CGPoint(x:80,y:45),withAttributes:[.font:UIFont.boldSystemFont(ofSize:30),.foregroundColor:dark ? UIColor.white:UIColor.black,.strokeColor:dark ? UIColor.black:UIColor.white,.strokeWidth:-5])}
            }.cgImage!}
            let source=raster(text:true),truth=try XCTUnwrap(ComicPixels.rgba(raster(text:false),width:480,height:300))
            var pixels=try XCTUnwrap(ComicPixels.rgba(source,width:480,height:300))
            let line=ComicLine(text:"EXCUSE ME",confidence:1,rect:CGRect(x:80,y:49,width:180,height:30))
            ComicPixels.clean(&pixels,width:480,height:300,speech:ComicSpeech(id:"0",text:line.text,lines:[line],rect:line.rect,vertical:false))
            var error=0,total=0,remnants=0
            for y in 40..<85{for x in 70..<275{let i=(y*480+x)*4;for c in 0..<3{let difference=abs(Int(pixels[i+c])-Int(truth[i+c]));error+=difference;total+=1;if difference>35{remnants+=1}}}}
            XCTAssertLessThan(Double(error)/Double(total),3,"cleanup must recover the local gradient")
            XCTAssertLessThan(remnants,15,"source outlines and shadows must disappear before Arabic is drawn")
        }
    }
    func testOutlineInkAddsOppositeStrokeOverNoisyBackground()throws{
        // Dark striped SFX background: automatic ink is white, so the outline pass
        // must add black stroke pixels the plain fill never produces.
        func noisy()->CGImage{renderer(CGSize(width:200,height:100)).image{context in
            UIColor(red:0.15,green:0.15,blue:0.18,alpha:1).setFill();context.fill(CGRect(x:0,y:0,width:200,height:100))
            UIColor(red:0.3,green:0.3,blue:0.35,alpha:1).setFill()
            for x in stride(from:0,to:200,by:6){context.fill(CGRect(x:x,y:0,width:2,height:100))}
        }.cgImage!}
        let speech=ComicSpeech(id:"sfx",text:"DOKI",lines:[ComicLine(text:"DOKI",confidence:0.9,rect:CGRect(x:40,y:30,width:120,height:40))],rect:CGRect(x:40,y:30,width:120,height:40),vertical:false,balloon:false)
        func render(_ ink:ComicInkStyle)throws->CGImage{try ComicPixels.render(noisy(),speeches:[speech],translations:[TranslationSegment(id:"sfx",text:"دوكي")],target:"ar",fontName:nil,fontScale:1,ink:ink)}
        let plain=try render(.plain),outlined=try render(.outline)
        func dark(_ image:CGImage)throws->Int{let pixels=try XCTUnwrap(ComicPixels.rgba(image,width:200,height:100));var count=0
            for y in Int(speech.rect.minY)..<Int(speech.rect.maxY){for x in Int(speech.rect.minX)..<Int(speech.rect.maxX){let i=(y*200+x)*4;if Int(pixels[i])<90{count+=1}}};return count}
        XCTAssertGreaterThan(try dark(outlined),try dark(plain),"outline stroke must add opposite-ink pixels over the noisy background")
        let attachment=XCTAttachment(image:UIImage(cgImage:outlined));attachment.name="Outline ink over SFX";attachment.lifetime = .keepAlways;add(attachment)
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
    func testArabicOCRVisualOrderDoesNotReverseLatinTokensOrNumbers(){
        XCTAssertEqual(ComicBidi.logicalFromVisual("ابحرم"),"مرحبا")
        XCTAssertEqual(ComicBidi.logicalFromVisual(")ابحرم( ABC"),"ABC (مرحبا)")
        XCTAssertEqual(ComicBidi.logicalFromVisual("12.5"),"12.5")
        XCTAssertEqual(ComicBidi.logicalFromVisual("(ابحرم) ABC"),"ABC (مرحبا)")
        XCTAssertEqual(ComicBidi.logicalFromVisual("]ابحرم[ 12.5"),"12.5 [مرحبا]")
    }
    func testAutomaticArabicScriptUsesTheArabicRecognizer()async throws{
        let image=renderer(CGSize(width:700,height:220)).image{context in
            UIColor.white.setFill();context.fill(CGRect(x:0,y:0,width:700,height:220))
            ("مرحبًا بكم في هذا العالم الجميل" as NSString).draw(at:CGPoint(x:35,y:65),withAttributes:[.font:UIFont(name:"GeezaPro",size:42)!, .foregroundColor:UIColor.black])
        }.cgImage!
        let reading=try await ComicOCR.shared.read(image,source:"auto",mode:.balanced)
        XCTAssertEqual(reading.language,"ar","Arabic must not be overwritten by a Latin fallback recognizer")
        XCTAssertTrue(reading.lines.map(\.text).joined().unicodeScalars.contains{(0x0600...0x06FF).contains($0.value)})
    }
    func testVerticalJapanesePaddleReadsTopToBottom()async throws{
        try await ComicModelStore.shared.prepare(source:"ja")
        let image=renderer(CGSize(width:180,height:480)).image{context in
            UIColor.white.setFill();context.fill(CGRect(x:0,y:0,width:180,height:480))
            let font=UIFont(name:"HiraginoSans-W3",size:42) ?? UIFont.systemFont(ofSize:42)
            for (index,char) in "今日は良い天気".enumerated(){(String(char) as NSString).draw(at:CGPoint(x:60,y:35+index*48),withAttributes:[.font:font,.foregroundColor:UIColor.black])}
        }.cgImage!
        let lines=try await ComicPaddle.shared.read(image,source:"ja",careful:true)
        XCTAssertTrue(lines.map(\.text).joined().contains("今日は良い天気"),"vertical glyph orientation must retain top-to-bottom reading order")
    }
    func testAutomaticReadingRetainsMixedArabicAndEnglishLines()async throws{
        let image=renderer(CGSize(width:800,height:300)).image{context in
            UIColor.white.setFill();context.fill(CGRect(x:0,y:0,width:800,height:300))
            ("HELLO WORLD. This chapter contains a story and a long English caption." as NSString).draw(at:CGPoint(x:25,y:35),withAttributes:[.font:UIFont.systemFont(ofSize:28),.foregroundColor:UIColor.black])
            ("مرحبًا بكم في العالم الجميل" as NSString).draw(at:CGPoint(x:35,y:150),withAttributes:[.font:UIFont(name:"GeezaPro",size:40)!, .foregroundColor:UIColor.black])
        }.cgImage!
        let reading=try await ComicOCR.shared.read(image,source:"auto",mode:.balanced),text=reading.lines.map(\.text).joined(separator:" ")
        XCTAssertTrue(text.uppercased().contains("HELLO"));XCTAssertTrue(text.unicodeScalars.contains{(0x0600...0x06FF).contains($0.value)})
    }
    func testLanguageVoteUsesOwnedPanelInsteadOfNeighbourContext()async throws{
        let image=renderer(CGSize(width:800,height:500)).image{context in
            UIColor.white.setFill();context.fill(CGRect(x:0,y:0,width:800,height:500))
            for row in 0..<4{("مرحبًا بكم في العالم الجميل" as NSString).draw(at:CGPoint(x:35,y:25+row*70),withAttributes:[.font:UIFont(name:"GeezaPro",size:40)!, .foregroundColor:UIColor.black])}
            ("HELLO WORLD" as NSString).draw(at:CGPoint(x:60,y:385),withAttributes:[.font:UIFont.systemFont(ofSize:44),.foregroundColor:UIColor.black])
        }.cgImage!
        let reading=try await ComicOCR.shared.read(image,source:"auto",mode:.balanced,languageRegion:CGRect(x:0,y:350,width:800,height:150))
        XCTAssertEqual(ComicModelStore.recognizer(reading.language),"latin")
        XCTAssertTrue(reading.lines.map(\.text).joined().uppercased().contains("HELLO"))
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
        XCTAssertEqual(ComicPreferences().mode,.balanced)
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
    func testBackgroundPanelsKeepOriginalPixelsAfterApplyingOneRegion()async throws{
        let raster=renderer(CGSize(width:200,height:100)).image{context in
            UIColor.red.setFill();context.fill(CGRect(x:0,y:0,width:200,height:50));UIColor.blue.setFill();context.fill(CGRect(x:0,y:50,width:200,height:50))
        }
        let original=try XCTUnwrap(raster.pngData()).base64EncodedString()
        let controller=WKUserContentController();controller.addUserScript(WKUserScript(source:ComicTranslation.script,injectionTime:.atDocumentEnd,forMainFrameOnly:false,in:ComicTranslation.world))
        let config=WKWebViewConfiguration();config.userContentController=controller
        let view=WKWebView(frame:CGRect(x:0,y:0,width:390,height:700),configuration:config)
        view.loadHTMLString("<html><body><div style='width:200px;height:100px;background-image:url(data:image/png;base64,\(original));background-size:100% 100%;background-repeat:no-repeat'></div></body></html>",baseURL:URL(string:"https://comic.invalid"))
        let deadline=Date().addingTimeInterval(15)
        while Date()<deadline{if (try? await view.callAsyncJavaScript("return !!globalThis.zeusComic && document.images.length>0 && document.images[0].complete",arguments:[:],in:nil,contentWorld:ComicTranslation.world))as? Bool==true{break};try await Task.sleep(for:.milliseconds(100))}
        let result=try await view.callAsyncJavaScript("const c=zeusComic.scan(false).items[0],g=zeusComic.start(),region={x:0,y:0,width:200,height:50};const transfer=await zeusComic.capture(c.id,c.revision,region),data=zeusComic.take(transfer.token,0,transfer.length);if(!await zeusComic.apply(c.id,c.revision,data,region,'ar',g))throw Error('apply failed');const again=zeusComic.scan(false).items;if(again.length!==1)throw Error('lost background candidate');const next=await zeusComic.capture(c.id,c.revision,{x:0,y:50,width:200,height:50}),bytes=zeusComic.take(next.token,0,next.length);zeusComic.restore();return bytes;",arguments:[:],in:nil,contentWorld:ComicTranslation.world)as? String
        let bytes=try XCTUnwrap(Data(base64Encoded:try XCTUnwrap(result))),image=try ComicPixels.decode(bytes),pixels=try XCTUnwrap(ComicPixels.rgba(image,width:200,height:50))
        XCTAssertLessThan(pixels[0],10);XCTAssertGreaterThan(pixels[2],245,"Second window must capture the original blue lower half")
        let restored=try await view.evaluateJavaScript("document.querySelector('div').style.backgroundImage")as? String
        XCTAssertTrue(restored?.contains("data:image/png")==true)
    }
    func testEndToEndImagesDoNotTranslateDOMAndFontChangesReuseOCRAndProvider()async throws { try await runImagePipeline(crossOrigin:false) }
    func testCrossOriginNoReferrerImagesTranslateThroughNativeFetch()async throws { try await runImagePipeline(crossOrigin:true) }
    private func runImagePipeline(crossOrigin:Bool)async throws{
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model=BrowserModel(profiles:ProfileStore(root:root,downloadsRoot:root.appendingPathComponent("Downloads")),useBackgroundDownloads:false)
        model.data.settings.shieldsEnabled=false
        var provider=AIProviderConfiguration();provider.baseURL="http://127.0.0.1:8765/v1";provider.model="comic-"+UUID().uuidString;model.data.settings.aiProviders=[provider]
        var preferences=ComicPreferences();preferences.source="en";preferences.showUntranslated=true
        var translation=TranslationPreferences();translation.engine = .ai;translation.providerID=provider.id;preferences.translation=translation;model.data.settings.comicTranslation=preferences
        let tab=try XCTUnwrap(model.current);tab.url="http://127.0.0.1:8765/comic-end-to-end"
        let prepared=await model.prepare(tab),view=try XCTUnwrap(prepared),session=try XCTUnwrap(tab.comicTranslation)
        let scene=try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap{$0 as? UIWindowScene}.first)
        let window=UIWindow(windowScene:scene);window.frame=scene.screen.bounds;window.rootViewController=UIViewController();view.frame=window.bounds;window.rootViewController?.view.addSubview(view);window.windowLevel = .normal+1;window.makeKeyAndVisible()
        defer{tab.dispose();window.isHidden=true;try? FileManager.default.removeItem(at:root)}
        let source=renderer(CGSize(width:640,height:240)).image{context in UIColor.white.setFill();context.fill(CGRect(x:0,y:0,width:640,height:240));("HELLO WORLD" as NSString).draw(at:CGPoint(x:100,y:80),withAttributes:[.font:UIFont.systemFont(ofSize:48),.foregroundColor:UIColor.black])}
        let encoded=try XCTUnwrap(source.pngData()).base64EncodedString()
        var imageURL=URLComponents(string:"http://127.0.0.1:8766/comic-no-referrer.png")!
        imageURL.queryItems=[URLQueryItem(name:"image",value:encoded)]
        imageURL.percentEncodedQuery=imageURL.percentEncodedQuery?.replacingOccurrences(of:"+",with:"%2B")
        let sourceURL=crossOrigin ? imageURL.url!.absoluteString : "data:image/png;base64,"+encoded
        view.loadHTMLString("<html><body><p id='text'>Original page text stays unchanged.</p><img id='comic' referrerpolicy='no-referrer' style='width:100%;height:auto' src='\(sourceURL)'></body></html>",baseURL:URL(string:tab.url))
        var deadline=Date().addingTimeInterval(20)
        while Date()<deadline{if (try? await view.callAsyncJavaScript("return !!globalThis.zeusComic && document.images[0]?.complete",arguments:[:],in:nil,contentWorld:ComicTranslation.world))as? Bool==true{break};try await Task.sleep(for:.milliseconds(100))}
        if crossOrigin {
            let tainted=try await view.evaluateJavaScript("(()=>{try{const c=document.createElement('canvas');c.width=640;c.height=240;c.getContext('2d').drawImage(document.images[0],0,0);c.toDataURL();return false}catch(e){return e.name==='SecurityError'}})()")as? Bool
            XCTAssertEqual(tainted,true,"Fixture must exercise native fallback after canvas is tainted")
        }
        session.start();deadline=Date().addingTimeInterval(35)
        while Date()<deadline && (session.running||session.completed==0) && session.error==nil{try await Task.sleep(for:.milliseconds(100))}
        XCTAssertNil(session.error);XCTAssertGreaterThan(session.completed,0)
        let unchanged=try await view.evaluateJavaScript("document.querySelector('#text').textContent")as? String
        XCTAssertEqual(unchanged,"Original page text stays unchanged.")
        let sourceBefore=try await view.evaluateJavaScript("document.images[0].src")as? String
        XCTAssertTrue(sourceBefore?.hasPrefix("blob:")==true)
        let endpoint=URL(string:"http://127.0.0.1:8765/translation-requests?model="+provider.model)!
        let (firstData,_)=try await URLSession.shared.data(from:endpoint)
        let before=try XCTUnwrap(JSONSerialization.jsonObject(with:firstData)as? [[String]])
        XCTAssertFalse(before.isEmpty);let ocrBefore=session.ocrRuns,completeBefore=session.completed
        preferences.fontScale=0.65;preferences.textColor="163B72";model.data.settings.comicTranslation=preferences
        session.pause();session.start();deadline=Date().addingTimeInterval(25)
        while Date()<deadline && session.running && session.error==nil{try await Task.sleep(for:.milliseconds(100))}
        XCTAssertNil(session.error)
        XCTAssertEqual(session.completed,completeBefore,"Changing lettering must not count the same source as another image")
        XCTAssertEqual(session.ocrRuns,ocrBefore,"Changing lettering must reuse the original OCR result")
        let (secondData,_)=try await URLSession.shared.data(from:endpoint),after=try XCTUnwrap(JSONSerialization.jsonObject(with:secondData)as? [[String]])
        XCTAssertEqual(before.count,after.count,"Changing lettering must not spend another translation request")
        if let snapshot=try? await view.takeSnapshot(configuration:nil){let attachment=XCTAttachment(image:snapshot);attachment.name="Image-only end-to-end - Arabic custom color";attachment.lifetime = .keepAlways;add(attachment)}
        await session.toggleOriginal()
        XCTAssertTrue(session.showingOriginal)
        let visibleOriginal=try await view.evaluateJavaScript("document.images[0].src")as? String
        XCTAssertEqual(visibleOriginal,sourceURL)
        await session.toggleOriginal()
        deadline=Date().addingTimeInterval(25)
        while session.running && Date()<deadline {try await Task.sleep(for:.milliseconds(100))}
        XCTAssertFalse(session.showingOriginal);XCTAssertEqual(session.ocrRuns,ocrBefore)
        await session.restore()
        let original=try await view.evaluateJavaScript("document.images[0].src")as? String
        XCTAssertEqual(original,sourceURL)
        try await ComicMemory.shared.clear(profile:model.profile.id)
    }
    func testOCRAndTranslationCachesAreSeparateAndProfileScoped()async throws{
        let first=UUID(),second=UUID(),bytes=Data("reading".utf8)
        try await ComicMemory.shared.save(bytes,profile:first,layer:.reading,key:"same")
        let found=await ComicMemory.shared.data(profile:first,layer:.reading,key:"same"),other=await ComicMemory.shared.data(profile:second,layer:.reading,key:"same"),translation=await ComicMemory.shared.data(profile:first,layer:.translation,key:"same")
        XCTAssertEqual(found,bytes);XCTAssertNil(other);XCTAssertNil(translation);try await ComicMemory.shared.clear(profile:first)
    }
}
