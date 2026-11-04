import Foundation
import Combine
import WebKit
import UIKit
import ImageIO
import CoreGraphics

@MainActor private final class ComicMessageRouter:NSObject,WKScriptMessageHandler{
    static let shared=ComicMessageRouter()
    let pages=NSMapTable<WKWebView,ComicTranslation>.weakToWeakObjects()
    func userContentController(_ controller:WKUserContentController,didReceive message:WKScriptMessage){if let view=message.webView{pages.object(forKey:view)?.receive(message)}}
}
@MainActor final class ComicTranslation:NSObject,ObservableObject{
    static let world=WKContentWorld.world(name:"ZEUS.ComicTranslation")
    static let script=Bundle.main.url(forResource:"comic-images",withExtension:"js").flatMap{try? String(contentsOf:$0,encoding:.utf8)} ?? ""
    weak var model:BrowserModel?
    weak var tab:BrowserTab?
    @Published var active=false
    @Published var running=false
    @Published var paused=false
    @Published var completed=0
    @Published private(set) var detectedTexts=0
    @Published private(set) var translatedTexts=0
    private var textCounts:[String:(Int,Int)]=[:]
    private func countTexts(_ job:String,detected:Int,translated:Int){textCounts[job]=(detected,translated);detectedTexts=textCounts.values.reduce(0){$0+$1.0};translatedTexts=textCounts.values.reduce(0){$0+$1.1}}
    private(set) var ocrRuns=0
    @Published var phase: ComicSessionPhase = .idle
    var stage: String { phase.title }
    @Published var showingOriginal = false
    @Published var diagnostics: [ComicDiagnostic] = []
    @Published var contextNotice: String?
    private var retryCounts: [String:Int] = [:]
    private var retries: [String:Task<Void,Never>] = [:]
    private var pendingImages = false
    private var sawImages = false
    private var sweepFailure = false
    private var resumeWhenVisible = false
    private var appliedRegions = Set<String>()
    @Published var error:String?
    @Published var storageNotice:String?
    private var work:Task<Void,Never>?
    private var epoch=UUID()
    private var lastRenderTicket: String?
    private var frames:[String:WKFrameInfo]=[:]
    private var documents:[String:ComicEnvelope]=[:]
    private var done=Set<String>()
    private var failed=Set<String>()
    private var pending=false
    private var readings:[String:ComicReading]=[:]
    private var languageHints:[String:String]=[:]
    private var textResults:[String:[TranslationSegment]]=[:]
    private var speechTexts:[String:String]=[:]
    private var fetched:[String:Data]=[:]
    private var fetchedOrder:[String]=[]
    private var observer:NSObjectProtocol?
    var preferences:ComicPreferences{model?.data.settings.comicTranslation ?? ComicPreferences()}
    init(model:BrowserModel,tab:BrowserTab){self.model=model;self.tab=tab;super.init();observer=NotificationCenter.default.addObserver(forName:UIApplication.didReceiveMemoryWarningNotification,object:nil,queue:.main){[weak self]_ in Task{@MainActor in self?.pause();await ComicOCR.shared.purge();await ComicPaddle.shared.purge();await ComicRestoration.shared.purge();await ComicLocalTranslator.shared.unload()}}}
    deinit{if let observer{NotificationCenter.default.removeObserver(observer)}}
    func attach(to view:WKWebView,installScript:Bool=true){
        ComicMessageRouter.shared.pages.setObject(self,forKey:view)
        view.configuration.userContentController.removeScriptMessageHandler(forName:"zeusComic",contentWorld:Self.world)
        view.configuration.userContentController.add(ComicMessageRouter.shared,contentWorld:Self.world,name:"zeusComic")
        if installScript{view.configuration.userContentController.addUserScript(WKUserScript(source:Self.script,injectionTime:.atDocumentEnd,forMainFrameOnly:false,in:Self.world))}
    }
    func receive(_ message:WKScriptMessage){
        guard let model,let tab,message.webView===tab.webView,model.profile.id==tab.profileID,!model.requiresUnlock,let body=message.body as? [String:String],let document=body["document"],document.count<80 else{return}
        if frames.count<64||frames[document] != nil{frames[document]=message.frameInfo}
        if preferences.automatic,model.current?.id==tab.id,!active{start()}
        if active,model.current?.id==tab.id{schedule()}
    }
    private func valid(_ ticket:UUID)throws{
        try Task.checkCancellation()
        guard ticket==epoch,let model,let tab,model.profile.id==tab.profileID,!model.requiresUnlock,tab.webView != nil,model.tabs.contains(where:{$0===tab})else{throw CancellationError()}
    }
    private func call(_ code:String,args:[String:Any]=[:],frame:WKFrameInfo?)async throws->Any{
        guard let view=tab?.webView else{throw CancellationError()}
        return try await view.callAsyncJavaScript(code,arguments:args,in:frame?.isMainFrame==true ? nil:frame,contentWorld:Self.world) ?? NSNull()
    }
    private var configurationIssue: String? {
        guard let model else{return nil}
        let prefs=preferences,translation=prefs.resolvedTranslation(model.data.settings)
        if prefs.localModel {
            return FileManager.default.fileExists(atPath:ComicLocalTranslator.modelURL.path) ? nil:"استورد نموذج GGUF من إعدادات الصور قبل بدء الترجمة المحلية."
        }
        if prefs.allowOnlineFallback == true{return nil}
        if prefs.engine.needsKey,AISecretVault.read(profile:model.profile.id,provider:"comic-"+prefs.engine.rawValue).trimmingCharacters(in:.whitespacesAndNewlines).isEmpty {
            return "أضف مفتاح \(prefs.engine.title) في إعدادات ترجمة الصور أو اختر محركًا دون مفتاح."
        }
        if translation.target=="ar",[ComicOnlineEngine.papago,.caiyun].contains(prefs.engine) {return "المحرك المختار لا يدعم العربية. اختر Google أو Microsoft أو مزودًا يدعمها."}
        if prefs.engine == .existing,translation.engine == .ai,!(model.data.settings.aiProviders ?? []).contains(where:{$0.id==translation.providerID}) {return "اختر مزود الذكاء الاصطناعي من إعدادات ترجمة الصور أولًا."}
        return nil
    }
    func start(){
        guard !showingOriginal,let model,let tab,!tab.isHome,!model.requiresUnlock,model.profile.id==tab.profileID else{return}
        ComicFonts.registerAll();active=true;paused=false;resumeWhenVisible=false;error=nil;failed.removeAll();retryCounts.removeAll()
        if let issue=configurationIssue {error=issue;phase = .failed;return}
        schedule()
    }
    func navigationStarted(){pause();active=false;showingOriginal=false;lastRenderTicket=nil;phase = .idle;appliedRegions.removeAll();diagnostics.removeAll();contextNotice=nil;completed=0;detectedTexts=0;translatedTexts=0;textCounts.removeAll();ocrRuns=0;done.removeAll();failed.removeAll();frames.removeAll();documents.removeAll();languageHints.removeAll();readings.removeAll();textResults.removeAll();speechTexts.removeAll();fetched.removeAll();fetchedOrder.removeAll();error=nil}
    func pause(){resumeWhenVisible=false;paused=true;phase = .paused;retries.values.forEach{$0.cancel()};retries.removeAll();let previousTicket=lastRenderTicket ?? epoch.uuidString;epoch=UUID();work?.cancel();work=nil;running=false;pending=false;Task{_ = try? await call("globalThis.zeusComic?.pause(ticket)",args:["ticket":previousTicket],frame:nil)};for frame in frames.values{Task{_ = try? await call("globalThis.zeusComic?.pause(ticket)",args:["ticket":previousTicket],frame:frame)}}}
    func suspend(){let resume = resumeWhenVisible || (active && !paused);pause();resumeWhenVisible=resume}
    func becameVisible(){if resumeWhenVisible || (!paused && (active||preferences.automatic)){resumeWhenVisible=false;start()}}
    func restore()async{pause();showingOriginal=false;active=false;phase = .idle;appliedRegions.removeAll();for frame in frames.values{_ = try? await call("globalThis.zeusComic?.restore()",frame:frame)};_ = try? await call("globalThis.zeusComic?.restore()",frame:nil);done.removeAll();failed.removeAll();completed=0;detectedTexts=0;translatedTexts=0;textCounts.removeAll();error=nil}
    func toggleOriginal() async {
        guard active else { return }
        let show = !showingOriginal
        let sourceTicket=lastRenderTicket
        pause()
        let ticket = epoch
        do {
            let arguments:[String:Any]=["show":show,"ticket":(sourceTicket.map{$0 as Any} ?? NSNull())]
            let changed=try await call("return zeusComic.setOriginal(show,ticket)",args:arguments,frame:nil)as? Bool
            guard changed == true else{throw CancellationError()}
            for (document,frame) in frames where !frame.isMainFrame {
                do { _ = try await call("return zeusComic.setOriginal(show,ticket)",args:arguments,frame:frame) }
                catch { frames[document]=nil;contextNotice="تعذّر تبديل عرض أحد الإطارات غير المتاحة." }
            }
            try valid(ticket)
            showingOriginal = show
            if !show { start() }
        } catch is CancellationError {} catch { record(error, at: .displaying) }
    }
    private func record(_ failure: Error, at phase: ComicSessionPhase) {
        let diagnostic = ComicDiagnostic.capture(failure, phase: phase)
        diagnostics.append(diagnostic)
        if diagnostics.count > 8 { diagnostics.removeFirst() }
        if failure is ComicHTTPFailure || failure is ComicFailure { error = failure.localizedDescription }
        else if diagnostic.domain == NSURLErrorDomain {
            error = diagnostic.code == NSURLErrorNoPermissionsToReadFile ? "تعذّرت قراءة بيانات الصورة. أعد المحاولة؛ تفاصيل المرحلة متاحة أدناه." : "تعذّر الاتصال بمصدر الصورة أو خدمة الترجمة. تحقق من الاتصال وأعد المحاولة."
        } else { error = "تعذّرت معالجة إحدى الصور. بقي الأصل متاحًا؛ يمكنك إعادة المحاولة أو تغيير وضع القراءة." }
    }
    private func schedule(){guard active && !paused else{return};if let issue=configurationIssue {error=issue;phase = .failed;return};if running{pending=true;return};guard active && !paused else{return};let ticket=epoch;running=true;pendingImages=false;sawImages=false;sweepFailure=false;phase = .waiting
        work=Task{[weak self]in guard let self else{return};defer{if epoch==ticket{running=false;work=nil
                if failed.isEmpty && !sweepFailure { error=nil }
                phase = (!failed.isEmpty || sweepFailure) ? (completed > 0 ? .partial : .failed) : (pendingImages || !sawImages ? .waiting : .completed)
                if pending{pending=false;schedule()}}}
            do{
                _ = try await call(Self.script,frame:nil)
                let id=try await call("return zeusComic.documentID",frame:nil)as? String ?? ""
                let children=frames.filter{!$0.value.isMainFrame}.map{($0.key,Optional($0.value))}
                for (document,frame) in [(id,Optional<WKFrameInfo>.none)]+children{
                    try valid(ticket)
                    do{try await sweep(document:document,frame:frame,ticket:ticket)}catch is CancellationError{throw CancellationError()}catch{if (error as NSError).domain==WKError.errorDomain,frame != nil{frames[document]=nil;continue};sweepFailure=true;self.record(error,at:phase)}
                }
            }catch is CancellationError{}catch{if epoch==ticket{sweepFailure=true;self.record(error,at:phase)}}
        }
    }
    private func sweep(document:String,frame:WKFrameInfo?,ticket:UUID)async throws{
        guard let model,let tab else{return}
        let owner=model.profile.id,prefs=preferences,translation=preferences.resolvedTranslation(model.data.settings)
        let provider=model.data.settings.aiProviders?.first{$0.id==translation.providerID}
        let translationMark=ComicIdentity.settings(prefs,translation:translation,provider:provider)+"|"+prefs.engine.rawValue+"|local:\(prefs.localModel)|"+ComicLocalTranslator.modelIdentity
        let mark=translationMark+"|"+prefs.renderIdentity
        let persistent=translation.keepsTranslations && !model.profile.isPrivate
        lastRenderTicket=ticket.uuidString
        let generation=try await call("return zeusComic.resume(mark,ticket)",args:["mark":mark,"ticket":ticket.uuidString],frame:frame)as? Int ?? 0
        let value=try await call("return zeusComic.scan(wake)",args:["wake":prefs.readAhead],frame:frame)
        let data=try JSONSerialization.data(withJSONObject:value),envelope=try JSONDecoder().decode(ComicEnvelope.self,from:data)
        guard envelope.document==document else{return};documents[document]=envelope;sawImages = sawImages || !envelope.items.isEmpty;pendingImages = pendingImages || envelope.items.contains(where: \.pending)
        let ordered=envelope.items.filter{!$0.pending&&$0.width>0&&$0.height>0}.sorted{a,b in
            let d1=max(0,a.y-envelope.scroll-envelope.viewport,envelope.scroll-a.y-a.h),d2=max(0,b.y-envelope.scroll-envelope.viewport,envelope.scroll-b.y-b.h);return d1<d2
        }
        // Bound new work, not the DOM prefix: already-completed images (including
        // fixed decorations) must never starve another visible chapter panel.
        var startedImages=0
        for candidate in ordered{
            try valid(ticket)
            let allRegions=ComicGeometry.regions(width:candidate.width,height:candidate.height,maximumPixels:7_000_000)
            let regions=ComicGeometry.prioritized(allRegions,candidate:candidate,scroll:envelope.scroll,viewport:envelope.viewport,readAhead:prefs.readAhead).filter{region in
                let job="\(document)|\(candidate.id)|\(candidate.revision)|\(region.y)|\(mark)"
                return !done.contains(job) && !failed.contains(job)
            }
            if allRegions.isEmpty{failed.insert(candidate.id);continue}
            if regions.isEmpty{continue}
            if try await call("return zeusComic.has(id,revision,mark)",args:["id":candidate.id,"revision":candidate.revision,"mark":mark],frame:frame)as? Bool==true{
                for region in regions{done.insert("\(document)|\(candidate.id)|\(candidate.revision)|\(region.y)|\(mark)")}
                continue
            }
            if startedImages >= (prefs.readAhead ? 16:4){pending=true;break}
            startedImages+=1
            for region in regions{
                let job="\(document)|\(candidate.id)|\(candidate.revision)|\(region.y)|\(mark)"
                do{
                    phase = .fetching
                    if !prefs.showUntranslated{_ = try await call("zeusComic.hold(id,revision)",args:["id":candidate.id,"revision":candidate.revision],frame:frame)}
                    let bytes=try await capture(candidate,region:region,frame:frame,ticket:ticket)
                    try valid(ticket)
                    let center=try await Task.detached{try ComicPixels.decode(bytes)}.value
                    let neighbours=ComicWindow.neighbours(of:candidate,in:envelope.items)
                    var before:CGImage?,after:CGImage?
                    let contextRows=max(0,min(256,(8_000_000/center.width-center.height)/2))
                    if contextRows>0,region.y==0,let previous=neighbours.before{
                        let height=min(previous.height,max(1,contextRows*previous.width/center.width)),area=ComicRegion(y:previous.height-height,width:previous.width,height:height,coreTop:0,coreBottom:height)
                        do { let context=try await capture(previous,region:area,frame:frame,ticket:ticket)
                            before=try await Task.detached{try ComicPixels.decode(context)}.value
                        } catch is CancellationError { throw CancellationError() } catch { contextNotice="بعض حدود الصور تُقرأ دون سياق الجوار لتعذّر تحميله." }
                    }
                    if contextRows>0,region.y+region.height==candidate.height,let next=neighbours.after{
                        let height=min(next.height,max(1,contextRows*next.width/center.width)),area=ComicRegion(y:0,width:next.width,height:height,coreTop:0,coreBottom:height)
                        do { let context=try await capture(next,region:area,frame:frame,ticket:ticket)
                            after=try await Task.detached{try ComicPixels.decode(context)}.value
                        } catch is CancellationError { throw CancellationError() } catch { contextNotice="بعض حدود الصور تُقرأ دون سياق الجوار لتعذّر تحميله." }
                    }
                    let window=try await Task.detached{try ComicWindow.join(center,before:before,after:after)}.value
                    let image=window.image,offset=window.offset
                    let imageHash=try await Task.detached{ComicIdentity.hash(try ComicPixels.png(image))}.value
                    // A cover's Latin title must not choose the script for the
                    // following Japanese/Arabic page. Hints belong to one image.
                    let languageHintKey=document+"|"+candidate.id+"|"+candidate.revision
                    let readingKey=imageHash+"|ocr-v21|\(prefs.source)|\(prefs.mode.rawValue)|vote:\(region.coreTop+offset):\(region.coreBottom-region.coreTop)"
                    phase = .recognizing
                    let reading:ComicReading
                    if let saved=readings[readingKey]{reading=saved}
                    else if persistent,let stored=await ComicMemory.shared.data(profile:owner,layer:.reading,key:readingKey),let saved=try? JSONDecoder().decode(ComicReading.self,from:stored){reading=saved}
                    else{ocrRuns+=1;reading=try await ComicOCR.shared.read(image,source:prefs.source,mode:prefs.mode,languageRegion:CGRect(x:0,y:region.coreTop+offset,width:region.width,height:region.coreBottom-region.coreTop),languageHint:languageHints[languageHintKey],onPreparing: { [weak self] preparing in
                            await MainActor.run { if self?.epoch == ticket { self?.phase = preparing ? .downloading:.recognizing } }
                        })
                        try valid(ticket)
                        if persistent{do{try await ComicMemory.shared.save(JSONEncoder().encode(reading),profile:owner,layer:.reading,key:readingKey)}catch{storageNotice="تعذّر حفظ قراءة الصورة؛ ستظل الجلسة الحالية متاحة."}}
                    }
                    if readings.count>=128{readings.removeAll()};readings[readingKey]=reading
                    if reading.lines.count>=2,!reading.language.isEmpty{languageHints[languageHintKey]=reading.language}
                    try valid(ticket)
                    // A speech touching this core is rendered from its complete context,
                    // then clipped to this core. Its neighbour renders the other half.
                    let core=reading.speeches.filter{$0.rect.maxY>CGFloat(region.coreTop+offset)&&$0.rect.minY<CGFloat(region.coreBottom+offset)}
                    let counted=core.filter{$0.rect.midY>=CGFloat(region.coreTop+offset)&&$0.rect.midY<CGFloat(region.coreBottom+offset)}
                    countTexts(job,detected:counted.count,translated:0)
                    if core.isEmpty{done.insert(job);_ = try await call("zeusComic.release(id)",args:["id":candidate.id],frame:frame);continue}
                    phase = .translating
                    let segments=core.map{TranslationSegment(id:$0.id,text:$0.text)}
                    let translationKey=readingKey+"|\(translationMark)|"+ComicIdentity.segmentIdentity(segments)
                    let translated:[TranslationSegment]
                    if let saved=textResults[translationKey]{translated=saved}
                    else if persistent,let stored=await ComicMemory.shared.data(profile:owner,layer:.translation,key:translationKey),let saved=try? JSONDecoder().decode([TranslationSegment].self,from:stored){translated=saved}
                    else{translated=try await translateSpeeches(segments,reading:reading,namespace:translationMark+"|"+ComicIdentity.hash(envelope.url),profile:owner,persistent:persistent,preferences:prefs,translation:translation,provider:provider,ticket:ticket)
                        try valid(ticket)
                        if persistent && translated.count==segments.count{do{try await ComicMemory.shared.save(JSONEncoder().encode(translated),profile:owner,layer:.translation,key:translationKey)}catch{storageNotice="تعذّر حفظ الترجمة على الجهاز."}}
                    }
                    if translated.count==segments.count{if textResults.count>=64{textResults.removeAll()};textResults[translationKey]=translated}
                    try valid(ticket);phase = .rendering
                    let renderedKey=translationKey+"|"+prefs.renderIdentity
                    let rendered:Data
                    var renderingPartial=translated.count != segments.count
                    if persistent,let stored=await ComicMemory.shared.data(profile:owner,layer:.rendered,key:renderedKey){rendered=stored;countTexts(job,detected:counted.count,translated:counted.count)}
                    else{
                        let lettering=translated.map{TranslationSegment(id:$0.id,text:prefs.letterCase.apply($0.text))}
                        let eligible=await Task.detached{ComicPixels.restorableSpeeches(core,translations:lettering,width:image.width,height:image.height,target:translation.target,fontName:prefs.fontName,fontScale:prefs.fontScale,letterSpacing:prefs.letterSpacing ?? 0)}.value
                        try valid(ticket)
                        // Paint ready flat/light dialogues before waiting for any
                        // complex artwork. One slow SFX must not hide the page.
                        if prefs.restorationEnabled ?? true{
                            let ready=await Task.detached{()->Int in
                                guard let pixels=ComicPixels.rgba(image,width:image.width,height:image.height)else{return 0}
                                return eligible.filter{ComicPixels.canClean(pixels,width:image.width,height:image.height,speech:$0)}.count
                            }.value
                            if ready>0 && ready<eligible.count{
                                let preview=try await Task.detached{()->(Data,[String]) in
                                    let report=try ComicPixels.renderReport(image,speeches:core,translations:lettering,target:translation.target,fontName:prefs.fontName,fontScale:prefs.fontScale,textColor:prefs.textColor,ink:prefs.inkStyle,letterSpacing:prefs.letterSpacing ?? 0,requireCleanSource:true)
                                    let area=CGRect(x:0,y:region.coreTop+offset,width:region.width,height:region.coreBottom-region.coreTop)
                                    guard let crop=report.image.cropping(to:area)else{throw ComicFailure.message("تعذّر تجهيز النصوص الجاهزة.")};return(try ComicPixels.png(crop),report.unresolved)
                                }.value
                                try valid(ticket)
                                let area=["x":0,"y":region.y+region.coreTop,"width":region.width,"height":region.coreBottom-region.coreTop]
                                if try await apply(preview.0,candidate:candidate,region:area,mark:mark,generation:generation,frame:frame,ticket:ticket){
                                    countTexts(job,detected:counted.count,translated:counted.filter{source in translated.contains{$0.id==source.id} && !preview.1.contains(source.id)}.count)
                                    appliedRegions.insert("\(document)|\(candidate.id)|\(candidate.revision)|\(region.y)");completed=appliedRegions.count
                                }
                            }
                        }
                        let restored:ComicRestoration.Result
                        if prefs.restorationEnabled ?? true{
                            restored=try await ComicRestoration.shared.restore(image,speeches:eligible,onPreparing:{ [weak self] preparing in
                                await MainActor.run{if self?.epoch==ticket{self?.phase=preparing ? .downloading:.rendering}}
                            })
                            try valid(ticket)
                            if let notice=restored.notice{contextNotice=notice;sweepFailure=true;renderingPartial=true}
                        }else{restored=ComicRestoration.Result(image:image,restored:[],notice:nil)}
                        let result=try await Task.detached{let drawing=try ComicPixels.renderReport(restored.image,speeches:core,translations:lettering,target:translation.target,fontName:prefs.fontName,fontScale:prefs.fontScale,textColor:prefs.textColor,ink:prefs.inkStyle,letterSpacing:prefs.letterSpacing ?? 0,requireCleanSource:true,precleanedIDs:restored.restored,styleSource:image)
                        // Only this core is applied. Recognition context is retained above/below.
                        let rect=CGRect(x:0,y:region.coreTop+offset,width:region.width,height:region.coreBottom-region.coreTop)
                        guard let crop=drawing.image.cropping(to:rect)else{throw ComicFailure.message("تعذّر قص منطقة الرسم.")};return (try ComicPixels.png(crop),drawing.unresolved)}.value
                        rendered=result.0
                        countTexts(job,detected:counted.count,translated:counted.filter{source in translated.contains{$0.id==source.id} && !result.1.contains(source.id)}.count)
                        if !result.1.isEmpty{renderingPartial=true;sweepFailure=true;contextNotice="احتُفظ ببعض النصوص الأصلية لعدم اكتمال تنظيفها أو ملاءمة خطها."}
                        try valid(ticket)
                        if persistent && !renderingPartial{do{try await ComicMemory.shared.save(rendered,profile:owner,layer:.rendered,key:renderedKey)}catch{storageNotice="تعذّر حفظ الصورة المترجمة؛ النص المحفوظ يظل متاحًا."}}
                    }
                    try valid(ticket);phase = .displaying
                    let outputRegion:[String:Int]=["x":0,"y":region.y+region.coreTop,"width":region.width,"height":region.coreBottom-region.coreTop]
                    let applied=try await apply(rendered,candidate:candidate,region:outputRegion,mark:mark,generation:generation,frame:frame,ticket:ticket)
                    guard applied else{throw ComicFailure.message("لم يسمح الموقع بعرض الصورة المترجمة؛ بقي الأصل متاحًا.")}
                    if renderingPartial{failed.insert(job)}else{done.insert(job)}
                    appliedRegions.insert("\(document)|\(candidate.id)|\(candidate.revision)|\(region.y)");completed=appliedRegions.count
                }catch is CancellationError{throw CancellationError()}catch{try valid(ticket);failed.insert(job);self.record(error,at:phase)
                    let diagnostic=ComicDiagnostic.capture(error,phase:phase),attempt=retryCounts[job,default:0]
                    if diagnostic.retryable && attempt<2 {
                        retryCounts[job]=attempt+1
                        retries[job]=Task { [weak self] in
                            defer{if self?.epoch==ticket{self?.retries[job]=nil}}
                            do { try await Task.sleep(for:.seconds(attempt == 0 ? 1:3));try Task.checkCancellation()
                                guard let self,self.epoch==ticket,self.active,!self.paused else{return}
                                self.failed.remove(job);self.schedule()
                            } catch {}
                        }
                    }
                    _ = try? await call("zeusComic.release(id)",args:["id":candidate.id],frame:frame)}
                await Task.yield()
                if pending{return}
            }
        }
        // Mark only an image whose every region reached a terminal successful state.
        for candidate in ordered{let regions=ComicGeometry.regions(width:candidate.width,height:candidate.height,maximumPixels:7_000_000);if !regions.isEmpty&&regions.allSatisfy({done.contains("\(document)|\(candidate.id)|\(candidate.revision)|\($0.y)|\(mark)")}){_ = try? await call("zeusComic.mark(id,revision,mark)",args:["id":candidate.id,"revision":candidate.revision,"mark":mark],frame:frame)}}
        _=tab
    }
    private func translateSpeeches(_ segments:[TranslationSegment],reading:ComicReading,namespace:String,profile:UUID,persistent:Bool,preferences:ComicPreferences,translation:TranslationPreferences,provider:AIProviderConfiguration?,ticket:UUID)async throws->[TranslationSegment]{
        let namespace=namespace+"|"+reading.language
        func key(_ text:String)->String{ComicIdentity.hash(namespace+"\0"+text)}
        var values:[String:String]=[:],failedTexts=Set<String>()
        for segment in segments{if let value=speechTexts[key(segment.text)]{values[segment.text]=value}}
        if persistent{let saved=await ComicMemory.shared.lookupText(segments,namespace:namespace,profile:profile);values.merge(saved){_,saved in saved}}
        try valid(ticket)
        var unique=Set<String>()
        let missing=segments.filter{values[$0.text]==nil&&unique.insert($0.text).inserted}
        if !missing.isEmpty{
            let preceding=reading.speeches.prefix(while:{$0.id != missing.first?.id}).suffix(4).map(\.text)
            let following=reading.speeches.drop(while:{$0.id != missing.last?.id}).dropFirst().prefix(4).map(\.text)
            let response:[TranslationSegment]
            do {
                response=try await ComicTextTranslator.translate(missing,source:reading.language,target:translation.target,preferences:translation,provider:provider,secret:AISecretVault.read(profile:profile,provider:translation.secretKey(provider:provider)),local:preferences.localModel,engine:preferences.engine,engineSecret:AISecretVault.read(profile:profile,provider:"comic-"+preferences.engine.rawValue),context:preceding,following:following)
            } catch is CancellationError { throw CancellationError() }
              catch let partial as ComicPartialTranslation {
                response=partial.translated
                let originals=Dictionary(uniqueKeysWithValues:missing.map{($0.id,$0.text)})
                failedTexts.formUnion(partial.failedIDs.compactMap{originals[$0]})
                contextNotice=partial.localizedDescription;sweepFailure=true
              } catch {
                try valid(ticket)
                guard preferences.allowOnlineFallback == true,!preferences.localModel,preferences.engine != .google else{throw error}
                contextNotice="استُخدم Google بعد تعذّر المحرك المختار، وفق إعداد الرجوع الذي فعّلته."
                do{response=try await ComicWebEngines.translate(missing,source:reading.language,target:translation.target,engine:.google,secret:"")}
                catch let partial as ComicPartialTranslation{
                    response=partial.translated
                    let originals=Dictionary(uniqueKeysWithValues:missing.map{($0.id,$0.text)})
                    failedTexts.formUnion(partial.failedIDs.compactMap{originals[$0]})
                    contextNotice=partial.localizedDescription;sweepFailure=true
                }
            }
            try valid(ticket)
            let originals=Dictionary(uniqueKeysWithValues:missing.map{($0.id,$0.text)})
            var fresh:[String:String]=[:]
            for item in response{if let original=originals[item.id]{fresh[original]=item.text}}
            guard fresh.count+failedTexts.count==missing.count else{throw ComicFailure.message("رد الترجمة لا يطابق الفقاعات.")}
            values.merge(fresh){_,new in new}
            if persistent,!(await ComicMemory.shared.saveText(fresh,namespace:namespace,profile:profile)){storageNotice="تعذّر حفظ بعض النصوص؛ قد تحتاج مساحة إضافية."}
        }
        try valid(ticket)
        if speechTexts.count>=8000{speechTexts.removeAll()}
        for (text,value)in values{speechTexts[key(text)]=value}
        return try segments.compactMap{segment -> TranslationSegment? in
            if let value=values[segment.text]{return TranslationSegment(id:segment.id,text:value)}
            if failedTexts.contains(segment.text){return nil}
            throw ComicFailure.message("ترجمة ناقصة.")
        }
    }
    private func capture(_ candidate:ComicCandidate,region:ComicRegion,frame:WKFrameInfo?,ticket:UUID)async throws->Data{
        do{
            let result=try await call("return await zeusComic.capture(id,revision,region)",args:["id":candidate.id,"revision":candidate.revision,"region":["x":region.x,"y":region.y,"width":region.width,"height":region.height]],frame:frame)as? [String:Any]
            guard let token=result?["token"]as? String,let length=result?["length"]as? Int,length>0,length<=33_554_432 else{throw ComicFailure.message("حمولة الصورة غير صالحة.")}
            defer{Task{_ = try? await call("zeusComic.drop(token)",args:["token":token],frame:frame)}}
            var output=Data();output.reserveCapacity(length)
            for offset in stride(from:0,to:length,by:65536){try valid(ticket);guard let part=try await call("return zeusComic.take(token,offset,count)",args:["token":token,"offset":offset,"count":min(65536,length-offset)],frame:frame)as? String,let bytes=Data(base64Encoded:part)else{throw ComicFailure.message("انقطع نقل الصورة.")};output.append(bytes)}
            guard output.count==length else{throw ComicFailure.message("صورة ناقصة.")};return output
        }catch{
            try valid(ticket)
            guard candidate.kind=="image",let tab,let model,let url=URL(string:candidate.source),["https","http"].contains(url.scheme),candidate.width>0,candidate.height>0 else{throw error}
            let data:Data,cacheKey=candidate.source+"|"+candidate.id+"|"+candidate.revision+"|"+(frame?.request.url?.absoluteString ?? tab.url)
            let canvasFailure=error
            if let cached=fetched[cacheKey]{data=cached}else{do { data=try await ComicImageFetch.fetch(url,page:frame?.request.url ?? tab.webView?.url,policy:candidate.referrerPolicy ?? tab.comicDocumentPolicies[(frame?.request.url ?? tab.webView?.url)?.absoluteString ?? ""],view:tab.webView,store:model.profiles.websiteDataStore(for:model.profile))
                } catch { diagnostics.append(ComicDiagnostic.capture(canvasFailure,phase:.fetching));if diagnostics.count>8{diagnostics.removeFirst()};throw error }
                fetched[cacheKey]=data;fetchedOrder.removeAll{$0==cacheKey};fetchedOrder.append(cacheKey)
                while fetchedOrder.count>4||fetched.values.reduce(0,{$0+$1.count})>33_554_432{let old=fetchedOrder.removeFirst();fetched[old]=nil}}
            if region.height<candidate.height,try await call("return zeusComic.hasBacking(id,revision)",args:["id":candidate.id,"revision":candidate.revision],frame:frame)as? Bool != true {
                let token=try await transfer(data,frame:frame,ticket:ticket)
                defer{Task{_ = try? await call("zeusComic.outputDrop(token)",args:["token":token],frame:frame)}}
                _ = try await call("zeusComic.outputOriginal(token,id,revision)",args:["token":token,"id":candidate.id,"revision":candidate.revision],frame:frame)
            }
            return try await Task.detached{let crop=try ComicPixels.decodeRegion(data,region:region,expectedHeight:candidate.height);return try ComicPixels.png(crop)}.value
        }
    }
    private func transfer(_ data:Data,frame:WKFrameInfo?,ticket:UUID)async throws->String {
        let token=UUID().uuidString
        _ = try await call("zeusComic.outputStart(token,length)",args:["token":token,"length":data.count],frame:frame)
        do { for start in stride(from:0,to:data.count,by:49152){try valid(ticket);_ = try await call("zeusComic.outputPart(token,offset,data)",args:["token":token,"offset":start,"data":data.subdata(in:start..<min(start+49152,data.count)).base64EncodedString()],frame:frame)}
        } catch {
            _ = try? await call("zeusComic.outputDrop(token)",args:["token":token],frame:frame)
            throw error
        }
        return token
    }
    private func apply(_ data:Data,candidate:ComicCandidate,region:[String:Int],mark:String,generation:Int,frame:WKFrameInfo?,ticket:UUID)async throws->Bool{
        guard data.count<=33_554_432 else{throw ComicFailure.message("الصورة المرسومة أكبر من حد النقل.")}
        let token=try await transfer(data,frame:frame,ticket:ticket)
        defer{Task{_ = try? await call("zeusComic.outputDrop(token)",args:["token":token],frame:frame)}}
        try valid(ticket)
        return try await call("return await zeusComic.outputApply(token,id,revision,region,mark,generation)",args:["token":token,"id":candidate.id,"revision":candidate.revision,"region":region,"mark":mark,"generation":generation],frame:frame)as? Bool ?? false
    }
}

@MainActor enum ComicImageFetch{
    nonisolated static func referrer(page: URL, destination: URL, policy: String?) -> String? {
        guard ["http","https"].contains(page.scheme),["http","https"].contains(destination.scheme),
              var components=URLComponents(url:page,resolvingAgainstBaseURL:false) else{return nil}
        components.user=nil;components.password=nil;components.fragment=nil
        let full=components.url?.absoluteString
        components.path="/";components.query=nil
        let origin=components.url?.absoluteString
        let same=page.scheme==destination.scheme && page.host==destination.host && (page.port ?? (page.scheme=="https" ? 443:80))==(destination.port ?? (destination.scheme=="https" ? 443:80))
        let downgrade=page.scheme=="https" && destination.scheme=="http"
        switch policy?.lowercased() {
        case "no-referrer":return nil
        case "same-origin":return same ? full:nil
        case "origin":return origin
        case "strict-origin":return downgrade ? nil:origin
        case "origin-when-cross-origin":return same ? full:origin
        case "unsafe-url":return full
        case "no-referrer-when-downgrade":return downgrade ? nil:full
        default:return downgrade ? nil:(same ? full:origin)
        }
    }
    static func fetch(_ url:URL,page:URL?,policy:String?,view:WKWebView?,store:WKWebsiteDataStore)async throws->Data{
        guard url.user==nil,url.password==nil,let host=url.host,let page else{throw URLError(.badURL)}
        // Do not turn page-controlled image addresses into access to local services.
        let privateHost=host=="localhost"||host=="::1"||host.hasPrefix("127.")||host.hasPrefix("10.")||host.hasPrefix("192.168.")||host.hasSuffix(".local")||host.hasPrefix("169.254.")
        guard !privateHost||page.host==host else{throw URLError(.noPermissionsToReadFile)}
        let cookies=await withCheckedContinuation{c in store.httpCookieStore.getAllCookies{c.resume(returning:$0)}}
        let configuration=URLSessionConfiguration.ephemeral;configuration.httpCookieStorage=nil;configuration.httpShouldSetCookies=false;configuration.urlCache=nil
        let session=URLSession(configuration:configuration,delegate:ComicImageRedirects(cookies:cookies,origin:url,page:page,policy:policy),delegateQueue:nil);defer{session.invalidateAndCancel()}
        var request=URLRequest(url:url);request.allHTTPHeaderFields=DownloadFiles.cookieHeaders(cookies,for:url);request.setValue(referrer(page:page,destination:url,policy:policy),forHTTPHeaderField:"Referer")
        let agent: String?
        if let custom=view?.customUserAgent {agent=custom}
        else if let view {agent=(try? await view.evaluateJavaScript("navigator.userAgent")) as? String}
        else {agent=nil}
        request.setValue(agent,forHTTPHeaderField:"User-Agent")
        let (file,response)=try await session.download(for:request)
        defer{try? FileManager.default.removeItem(at:file)}
        if let status=(response as? HTTPURLResponse)?.statusCode,status != 200 { throw ComicHTTPFailure(status:status) }
        guard response.mimeType?.hasPrefix("image/")==true,(try file.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? Int.max)<=33_554_432 else{throw URLError(.cannotDecodeContentData)}
        return try await Task.detached{try Data(contentsOf:file)}.value
    }
}
private final class ComicImageRedirects:NSObject,URLSessionDownloadDelegate,@unchecked Sendable{
    func urlSession(_ session:URLSession,downloadTask:URLSessionDownloadTask,didFinishDownloadingTo location:URL){}
    func urlSession(_ session:URLSession,downloadTask:URLSessionDownloadTask,didWriteData bytesWritten:Int64,totalBytesWritten:Int64,totalBytesExpectedToWrite:Int64){if totalBytesWritten>33_554_432||totalBytesExpectedToWrite>33_554_432{downloadTask.cancel()}}
    let cookies:[HTTPCookie];let origin:URL;let page:URL;let policy:String?
    init(cookies:[HTTPCookie],origin:URL,page:URL,policy:String?){self.cookies=cookies;self.origin=origin;self.page=page;self.policy=policy}
    func urlSession(_ session:URLSession,task:URLSessionTask,willPerformHTTPRedirection response:HTTPURLResponse,newRequest request:URLRequest,completionHandler:@escaping(URLRequest?)->Void){
        guard let url=request.url,url.scheme=="https"||url.scheme==origin.scheme,url.host==origin.host else{completionHandler(nil);return}
        var next=request;next.setValue(ComicImageFetch.referrer(page:page,destination:url,policy:policy),forHTTPHeaderField:"Referer");next.setValue(nil,forHTTPHeaderField:"Cookie");for(k,v)in DownloadFiles.cookieHeaders(cookies,for:url){next.setValue(v,forHTTPHeaderField:k)};completionHandler(next)
    }
}
