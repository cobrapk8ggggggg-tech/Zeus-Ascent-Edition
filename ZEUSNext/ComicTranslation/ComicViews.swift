import SwiftUI
import CoreText
import UniformTypeIdentifiers

private enum ComicSettingsSection: String, CaseIterable {
    case reading = "القراءة", appearance = "المظهر", models = "النماذج والحفظ"
}

struct ComicSettingsSheet: View {
    @ObservedObject var model: BrowserModel
    var embedded = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.browserTheme) private var theme
    @State private var selectedSection = ComicSettingsSection.reading
    @State private var importingFont = false
    @State private var importingModel = false
    @State private var key = ""
    @State private var clientID = ""
    @State private var customColor = ""
    @State private var message: String?
    @State private var downloading = false
    @State private var downloadProgress = 0.0
    @State private var download: Task<Void,Never>?
    @State private var redraw: Task<Void,Never>?
    @State private var redrawGeneration = UUID()
    private var prefs: ComicPreferences { model.data.settings.comicTranslation ?? ComicPreferences() }
    private var translation: TranslationPreferences { prefs.resolvedTranslation(model.data.settings) }
    var body: some View {
        Group { if embedded { settingsForm } else { NavigationStack { settingsForm } } }
            .environment(\.layoutDirection,.rightToLeft)
            .tint(theme.accentColor)
            .presentationDetents([.medium,.large]).presentationDragIndicator(.visible)
            .onAppear { customColor = prefs.textColor ?? "" }
            .onChange(of:prefs.engine) { _,_ in key="";clientID="" }
            .fileImporter(isPresented:$importingFont,allowedContentTypes:[.data]) { result in
                do { var p=prefs;p.fontName=try ComicFonts.importFont(result.get());save(p) }
                catch { message=error.localizedDescription }
            }
            .fileImporter(isPresented:$importingModel,allowedContentTypes:[.data]) { result in
                Task { do { try await ComicLocalTranslator.shared.importModel(result.get());message="استُورد النموذج المحلي." }
                    catch { message=error.localizedDescription } }
            }
    }
    private var settingsForm: some View {
        Form {
            Section {
                VStack(alignment:.leading,spacing:12) {
                    Label("الكلمات في مكانها",systemImage:"character.viewfinder").font(.title2.bold())
                    Text("ترجمة فقاعات الصور إلى لغتك، وأنت تقرأ.").font(.subheadline).foregroundStyle(.secondary)
                    Button { model.current?.comicTranslation?.start();dismiss() } label: {
                        Label("ترجمة الصور الآن",systemImage:"sparkles").frame(maxWidth:.infinity,minHeight:44)
                    }.buttonStyle(.borderedProminent).accessibilityIdentifier("startImageTranslation")
                        .disabled(model.current?.isHome != false)
                }.padding(.vertical,6)
            }.listRowBackground(Color.clear)
            Section {
                Picker("إعدادات الصور",selection:$selectedSection) {
                    ForEach(ComicSettingsSection.allCases,id:\.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented)
            }.listRowBackground(Color.clear)
            switch selectedSection {
            case .reading: readingSettings;qualitySettings;engineSettings
            case .appearance: appearanceSettings
            case .models: storageSettings
            }
            if let message { Section { Label(message,systemImage:"info.circle").font(.callout).textSelection(.enabled) } }
        }
        .scrollContentBackground(.hidden).background(theme.backgroundColor)
        .navigationTitle("ترجمة الصور").navigationBarTitleDisplayMode(.inline)
        .toolbar { if !embedded { ToolbarItem(placement:.confirmationAction) { Button("تم") { dismiss() } } } }
    }
    private var readingSettings: some View {
        Section("اللغات والقراءة") {
            Picker("من",selection:binding(\.source)) {
                Text("اكتشاف تلقائي").tag("auto")
                ForEach(ComicPreferences.sourceLanguages,id:\.0) { Text($0.1).tag($0.0) }
            }
            Picker("إلى",selection:translationBinding(\.target)) {
                ForEach(TranslationPreferences.languages,id:\.0) { Text($0.1).tag($0.0) }
            }
            Picker("جودة القراءة",selection:binding(\.mode)) {
                ForEach(ComicReadingMode.allCases,id:\.self) { Text($0.title).tag($0) }
            }
            Text(prefs.mode == .fastest ? "قراءة محلية سريعة. اختر المتوازن أو الدقيق للخطوط الصغيرة والفقاعات المعقدة." : "تُجهّز حزمة لغة الصورة تلقائيًا عند الحاجة. الوضع الدقيق يعيد فحص المناطق الصغيرة.")
                .font(.footnote).foregroundStyle(.secondary)
            Toggle("ترجمة الصور تلقائيًا",isOn:binding(\.automatic))
            Text("الوضع المتوازن موصى به. اختر دقيقًا للنصوص الصغيرة أو المزخرفة.").font(.caption).foregroundStyle(.secondary)
            Toggle("عرض الأصل أثناء التجهيز",isOn:binding(\.showUntranslated))
            Toggle("تجهيز الفصل كاملًا مسبقًا",isOn:binding(\.readAhead))
            Toggle("ترميم الخلفيات المعقدة",isOn:Binding(get:{prefs.restorationEnabled ?? true},set:{var p=prefs;p.restorationEnabled=$0;save(p)}))
            Text("يعالج النص فوق الرسم على الجهاز عند توفر الذاكرة. ينزّل نموذجَي الترميم عند أول حاجة إليهما (نحو 303 م.ب). يمكنك إيقافه للاكتفاء بالتنظيف الخفيف.").font(.caption).foregroundStyle(.secondary)
        }
    }
    private var qualitySettings: some View {
        Section("قبول النتائج") {
            Toggle("تجاوز فحوص التنظيف وملاءمة النص",isOn:Binding(get:{prefs.bypassQualityChecks ?? false},set:{var p=prefs;p.bypassQualityChecks=$0;save(p)}))
            Text("معطّل افتراضيًا. عند تفعيله تُرسم الترجمة حتى مع بقايا النص الأصلي أو ضعف الملاءمة. لا يعوّض النصوص التي لم يكتشفها OCR أو أخطاء مزوّد الترجمة.").font(.caption).foregroundStyle(.secondary)
        }
    }
    private var engineSettings: some View {
        Section {
            Toggle("نموذج محلي دون شبكة",isOn:binding(\.localModel))
            if prefs.localModel {
                Button("استيراد نموذج GGUF",systemImage:"square.and.arrow.down") { importingModel=true }
                Text("يعمل على الجهاز دون انتقال إلى خدمة سحابية عند الفشل. يجب أن يدعم النموذج لغاتك وإرجاع JSON؛ الحد هو الأصغر من 2 GiB وثلث ذاكرة الجهاز.").font(.footnote).foregroundStyle(.secondary)
            } else {
                Picker("المحرك",selection:binding(\.engine)) {
                    ForEach(ComicOnlineEngine.allCases,id:\.self) { Text($0.title).tag($0) }
                }
                if prefs.engine == .existing {
                    Picker("خدمة ZEUS",selection:translationBinding(\.engine)) {
                        ForEach(TranslationEngine.allCases,id:\.self) { Text($0.title).tag($0) }
                    }
                    if translation.engine == .ai {
                        Picker("المزود",selection:translationBinding(\.providerID)) {
                            Text("اختر مزودًا").tag(nil as UUID?)
                            ForEach(model.data.settings.aiProviders ?? []) { Text($0.name).tag(Optional($0.id)) }
                        }
                    }
                }
                Toggle("استخدام Google عند فشل المحرك",isOn:Binding(get:{prefs.allowOnlineFallback ?? false},set:{var p=prefs;p.allowOnlineFallback=$0;save(p)}))
                Text("عند تفعيله قد تُرسل الكلمات إلى Google إذا تعذّر المحرك المختار؛ يظهر تنبيه عند استخدامه.").font(.footnote).foregroundStyle(.secondary)
                if prefs.engine.needsKey {
                    Text("واجهة API رسمية تحتاج حسابك ومفتاحك؛ تختلف عن خدمة الويب المجانية في Android.").font(.footnote).foregroundStyle(.secondary)
                    if prefs.engine == .papago { TextField("Client ID",text:$clientID).textInputAutocapitalization(.never).autocorrectionDisabled() }
                    SecureField("مفتاح الحساب",text:$key).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("حفظ المفتاح") {
                        do { try AISecretVault.save(prefs.engine == .papago ? clientID+"\n"+key:key,profile:model.profile.id,provider:"comic-"+prefs.engine.rawValue);key="";clientID="";message="حُفظ المفتاح في Keychain." }
                        catch { message=error.localizedDescription }
                    }.disabled(key.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
                }
                if translation.target == "ar",[ComicOnlineEngine.papago,.caiyun].contains(prefs.engine) {
                    Label("هذا المحرك لا يدعم العربية. اختر محركًا آخر.",systemImage:"exclamationmark.triangle").foregroundStyle(.orange)
                }
            }
        } header: { Text("الترجمة باستخدام") }
          footer: { Text("التعرف والرسم على الجهاز. تُرسل الكلمات فقط إلى المحرك المختار. هذا المسار مستقل عن ترجمة نص الصفحة.") }
    }
    private var appearanceSettings: some View {
        Group {
            Section {
                ComicLetteringPreview(preferences:prefs,target:translation.target)
                    .listRowInsets(EdgeInsets(top:8,leading:8,bottom:8,trailing:8))
            } header: { Text("معاينة حقيقية للرسم") }
              footer: { Text("تستخدم المعاينة محرك الرسم نفسه. النتيجة الفعلية تتكيف مع مساحة كل فقاعة.") }
            Section("الخط والحبر") {
                Picker("الخط",selection:binding(\.fontName)) {
                    Text("الافتراضي الذكي").tag(nil as String?)
                    ForEach(ComicFonts.systemNames + ComicFonts.names,id:\.self) { Text($0).tag(Optional($0)) }
                }
                Button("استيراد TTF / OTF / TTC",systemImage:"textformat") { importingFont=true }
                VStack(alignment:.leading) {
                    HStack { Text("حجم الخط");Spacer();Text("\(Int(prefs.fontScale*100))٪").monospacedDigit().foregroundStyle(.secondary) }
                    Slider(value:binding(\.fontScale),in:0.5...1.5,step:0.05).accessibilityLabel("حجم خط الصور")
                }
                Picker("نمط الحبر",selection:Binding(get:{prefs.inkStyle},set:{var p=prefs;p.inkStyle=$0;save(p)})) {
                    ForEach(ComicInkStyle.allCases,id:\.self) { Text($0.title).tag($0) }
                }
                Picker("لون الكلام",selection:binding(\.textColor)) {
                    Text("تلقائي حسب الخلفية").tag(nil as String?)
                    Text("أسود").tag(Optional("101010"));Text("أبيض").tag(Optional("FAFAFA"))
                    Text("أزرق داكن").tag(Optional("163B72"));Text("أحمر داكن").tag(Optional("8B2020"))
                    if let value=prefs.textColor,!["101010","FAFAFA","163B72","8B2020"].contains(value) { Text("مخصص").tag(Optional(value)) }
                }
                HStack {
                    TextField("#163B72",text:$customColor).textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityLabel("لون مخصص")
                    Button("تطبيق") { var p=prefs;p.textColor=customColor.isEmpty ? nil:customColor;save(p) }
                        .disabled(!customColor.isEmpty && ComicPixels.color(customColor)==nil)
                }
                Picker("حالة الأحرف",selection:Binding(get:{prefs.letterCase},set:{var p=prefs;p.letterCaseRaw=$0.rawValue;save(p)})) {
                    ForEach(ComicLetterCase.allCases,id:\.self) { Text($0.title).tag($0) }
                }
                VStack(alignment:.leading) {
                    Text("المسافة بين الحروف")
                    Slider(value:Binding(get:{prefs.letterSpacing ?? 0},set:{var p=prefs;p.letterSpacing=$0;save(p)}),in:-1...4,step:0.25)
                }
            }
        }
    }
    private var storageSettings: some View {
        Group {
            Section("مكان ترميم الخلفيات") {
                Toggle("تشغيل نماذج الترميم سحابيًا",isOn:Binding(get:{prefs.useCloudRestoration ?? false},set:{var p=prefs;p.useCloudRestoration=$0;save(p)}))
                if prefs.useCloudRestoration ?? false {
                    TextField("عنوان خادم الترميم HTTPS",text:Binding(get:{prefs.cloudRestorationURL ?? ""},set:{var p=prefs;p.cloudRestorationURL=$0;save(p)})).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    Text("يرسل بيانات النموذج مضغوطة دون فقد إلى الخادم الذي تحدده، مع توثيق حسابك. تُستخدم النماذج نفسها والأقنعة والرسم نفسها، دون تنزيل نماذج الترميم على الجهاز. يلزم خادم مجهز وحساب مسجّل؛ لا يُفعّل قبل تحديد الخادم.").font(.footnote).foregroundStyle(.secondary)
                }
            }
            Section("حزم قراءة الصور") {
                Text(prefs.source == "auto" ? "تُكتشف لغة الصورة وتُجهّز حزمتها تلقائيًا عند القراءة. للتجهيز المسبق اختر لغة المصدر في قسم القراءة." : "اللغة المحددة: \(ComicPreferences.sourceLanguages.first(where:{$0.0==prefs.source})?.1 ?? prefs.source)")
                    .font(.callout).foregroundStyle(.secondary)
                if downloading {
                    ProgressView(value:downloadProgress).accessibilityLabel("تجهيز ملفات نموذج القراءة")
                    Button("إلغاء التنزيل",role:.cancel) { download?.cancel() }
                } else {
                    Button("تجهيز حزمة اللغة مسبقًا",systemImage:"arrow.down.circle") { prepareModels() }.disabled(prefs.source == "auto")
                    Button("تجهيز ترميم الخلفيات مسبقًا",systemImage:"wand.and.stars") { prepareRestoration() }
                }
                Text("تُفحص أحجام الملفات وبصماتها قبل اعتمادها. الملفات المكتملة تبقى متاحة دون إعادة تنزيل.").font(.footnote).foregroundStyle(.secondary)
            }
            Section("الحفظ على الجهاز") {
                Toggle("حفظ النتائج على الجهاز",isOn:translationBinding(\.retainTranslations,default:false))
                Text("تغيير المظهر يعيد استخدام القراءة والترجمة المحفوظتين. التصفح الخاص يحتفظ بالنتائج في الذاكرة فقط.").font(.footnote).foregroundStyle(.secondary)
                Button("مسح حفظ صور هذا البروفايل",role:.destructive) {
                    let id=model.profile.id
                    Task { do { try await ComicMemory.shared.clear(profile:id);message="مُسحت النتائج المحفوظة." } catch { message=error.localizedDescription } }
                }
            }
        }
    }
    private func prepareRestoration(){
        downloading=true;downloadProgress=0
        download=Task{
            defer{downloading=false;download=nil}
            do{
                for (index,file) in ["ctd.onnx","lama.onnx"].enumerated(){
                    try Task.checkCancellation();_ = try await ComicModelStore.shared.file(file,download:true);downloadProgress=Double(index+1)/2
                }
                message="نماذج ترميم الخلفية جاهزة."
            }catch is CancellationError{message="أُلغي تجهيز الترميم."}catch{message=error.localizedDescription}
        }
    }
    private func prepareModels() {
        let source=prefs.source;downloading=true;downloadProgress=0
        download=Task {
            defer { downloading=false;download=nil }
            do {
                try await ComicModelStore.shared.prepare(source:source,onProgress:{ done,total in
                    await MainActor.run { downloadProgress=Double(done)/Double(total) }
                })
                message="حزمة القراءة جاهزة."
            } catch is CancellationError { message="أُلغي التنزيل؛ يمكنك استكمال تجهيز الحزمة لاحقًا." }
              catch { message=Task.isCancelled ? "أُلغي تجهيز الحزمة.":error.localizedDescription }
        }
    }
    private func save(_ value:ComicPreferences) {
        model.data.settings.comicTranslation=value;model.persist()
        if let session=model.current?.comicTranslation,session.active {
            let resume = !session.paused || redraw != nil
            session.pause();redraw?.cancel();let ticket=UUID();redrawGeneration=ticket
            if resume { redraw=Task { defer { if redrawGeneration==ticket { redraw=nil } };do { try await Task.sleep(for:.milliseconds(250));try Task.checkCancellation();if session.active { session.start() } } catch {} } }
        }
    }
    private func binding<T>(_ path:WritableKeyPath<ComicPreferences,T>)->Binding<T> { Binding(get:{prefs[keyPath:path]},set:{var p=prefs;p[keyPath:path]=$0;save(p)}) }
    private func translationBinding<T>(_ path:WritableKeyPath<TranslationPreferences,T>)->Binding<T> { Binding(get:{translation[keyPath:path]},set:{var t=translation;t[keyPath:path]=$0;var p=prefs;p.translation=t;save(p)}) }
    private func translationBinding(_ path:WritableKeyPath<TranslationPreferences,Bool?>,default fallback:Bool)->Binding<Bool> { Binding(get:{translation[keyPath:path] ?? fallback},set:{var t=translation;t[keyPath:path]=$0;var p=prefs;p.translation=t;save(p)}) }
}

private struct ComicLetteringPreview: View {
    let preferences: ComicPreferences
    let target: String
    @State private var image: UIImage?
    @State private var failed = false
    var body: some View {
        Group {
            if let image { Image(uiImage:image).resizable().scaledToFit() }
            else { RoundedRectangle(cornerRadius:24).fill(.secondary.opacity(0.1)).overlay { if failed { Text("تعذّر رسم المعاينة").font(.caption) } else { ProgressView() } } }
        }.overlay(alignment:.bottom) { if failed { Text("تعذّر تحديث المعاينة بالإعداد الحالي").font(.caption).padding(8).background(.regularMaterial,in:Capsule()) } }
        .frame(minHeight:150,maxHeight:220).clipShape(RoundedRectangle(cornerRadius:20))
            .accessibilityElement(children:.ignore).accessibilityLabel("معاينة خط الترجمة داخل فقاعة").accessibilityIdentifier("comicLetteringPreview")
            .task(id:preferences.renderIdentity+target) { await render() }
    }
    @MainActor private func render() async {
        let format=UIGraphicsImageRendererFormat();format.scale=1
        let source=UIGraphicsImageRenderer(size:CGSize(width:420,height:240),format:format).image { context in
            UIColor(red:0.09,green:0.14,blue:0.22,alpha:1).setFill();context.fill(CGRect(x:0,y:0,width:420,height:240))
            UIColor.white.setFill();UIBezierPath(ovalIn:CGRect(x:48,y:24,width:324,height:192)).fill()
            ("HELLO WORLD" as NSString).draw(in:CGRect(x:120,y:96,width:180,height:36),withAttributes:[.font:UIFont.boldSystemFont(ofSize:22),.foregroundColor:UIColor.black])
        }
        guard let raster=source.cgImage else{return}
        let text=TranslationPreferences.rtl(target) ? "لنبدأ المغامرة!\nالعالم ينتظرنا." : "Let the adventure begin!"
        let speech=ComicSpeech(id:"preview",text:"HELLO WORLD",lines:[ComicLine(text:"HELLO WORLD",confidence:1,rect:CGRect(x:120,y:96,width:180,height:36))],rect:CGRect(x:96,y:60,width:228,height:120),vertical:false,balloon:true)
        do {
            let prefs=preferences
            let data=try await Task.detached { try ComicPixels.png(ComicPixels.render(raster,speeches:[speech],translations:[TranslationSegment(id:"preview",text:prefs.letterCase.apply(text))],target:target,fontName:prefs.fontName,fontScale:prefs.fontScale,textColor:prefs.textColor,ink:prefs.inkStyle,letterSpacing:prefs.letterSpacing ?? 0)) }.value
            try Task.checkCancellation();image=UIImage(data:data);failed=false
        } catch is CancellationError {} catch { failed=true }
    }
}

struct ComicTranslationCard: View {
    @ObservedObject var session: ComicTranslation
    let settings: ()->Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var expanded = false
    @State private var switching = false
    var body: some View {
        if session.active {
            VStack(alignment:.leading,spacing:12) {
                ViewThatFits(in:.horizontal) {
                    HStack(spacing:12) { status;Spacer(minLength:8);controls }
                    VStack(alignment:.leading,spacing:8) { status;controls.frame(maxWidth:.infinity,alignment:.trailing) }
                }
                if expanded {
                    if let error=session.error { Label(error,systemImage:"exclamationmark.triangle").font(.callout).foregroundStyle(.orange) }
                    if let notice=session.contextNotice { Text(notice).font(.caption).foregroundStyle(.secondary) }
                    if let notice=session.storageNotice { Text(notice).font(.caption).foregroundStyle(.secondary) }
                    if !session.diagnostics.isEmpty {
                        DisclosureGroup("تفاصيل التشخيص") {
                            ForEach(session.diagnostics) { Text($0.detail).font(.caption.monospaced()).textSelection(.enabled) }
                        }.font(.caption)
                    }
                    HStack {
                        if session.phase == .failed || session.phase == .partial { Button("إعادة المحاولة",systemImage:"arrow.clockwise") { session.start() }.disabled(session.showingOriginal) }
                        Spacer()
                        Button("إنهاء الترجمة",role:.destructive) { Task { await session.restore() } }
                    }.font(.subheadline).frame(minHeight:44)
                }
            }
            .padding(12).glassSurface(24).frame(maxWidth:560)
            .padding(.horizontal,12).padding(.bottom,12)
            .environment(\.layoutDirection,.rightToLeft)
            .animation(reduceMotion ? nil:.spring(response:0.32,dampingFraction:0.9),value:expanded)
            .transition(.opacity).accessibilityIdentifier("imageTranslationCard")
        }
    }
    private var status: some View {
        Button { expanded.toggle() } label: {
            HStack(spacing:10) {
                if session.running { ProgressView().controlSize(.small) }
                else { Image(systemName:session.error == nil ? "character.viewfinder":"exclamationmark.circle").foregroundStyle(session.error == nil ? Color.accentColor:Color.orange) }
                VStack(alignment:.leading,spacing:3) {
                    Text(session.showingOriginal ? "عرض الأصل":session.phase.title).font(.subheadline.weight(.semibold))
                    Text(session.detectedTexts == 0 && session.phase == .completed ? "لم يُعثر على نص في الصور المتاحة":"\(session.detectedTexts) نصوص مكتشفة · \(session.translatedTexts) مترجمة")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
                Image(systemName:expanded ? "chevron.down":"chevron.up").font(.caption2).foregroundStyle(.secondary)
            }.frame(minHeight:44).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel("حالة ترجمة الصور وتفاصيلها").accessibilityValue("\(session.detectedTexts) نصوص مكتشفة · \(session.translatedTexts) مترجمة").accessibilityIdentifier("imageTranslationStatus")
    }
    private var controls: some View {
        HStack(spacing:2) {
            Button {
                switching=true
                Task { await session.toggleOriginal();switching=false }
            } label: { Image(systemName:session.showingOriginal ? "character.viewfinder":"photo").frame(minWidth:44,minHeight:44) }
                .disabled(switching).accessibilityLabel(session.showingOriginal ? "عرض الترجمة":"عرض الأصل")
                .accessibilityIdentifier("imageTranslationOriginal")
            if session.running {
                Button { session.pause() } label: { Image(systemName:"pause.fill").frame(minWidth:44,minHeight:44) }.accessibilityLabel("إيقاف الترجمة مؤقتًا")
            } else if session.paused && !session.showingOriginal {
                Button { session.start() } label: { Image(systemName:"play.fill").frame(minWidth:44,minHeight:44) }.accessibilityLabel("متابعة ترجمة الصور")
            }
            Button(action:settings) { Image(systemName:"slider.horizontal.3").frame(minWidth:44,minHeight:44) }.accessibilityLabel("إعدادات ترجمة الصور")
                .accessibilityIdentifier("imageTranslationSettings")
        }.buttonStyle(.plain)
    }
}
@MainActor enum ComicFonts{
    static let root=ComicModelStore.root.appendingPathComponent("Fonts")
    // Arabic system faces available on every iOS device without importing anything.
    static let systemNames=["GeezaPro","Damascus","Baghdad","AlBayan","Sana","Nadeem"]
    static var names:[String]{registerAll();return (try? FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:nil))?.compactMap{url in guard let descriptors=CTFontManagerCreateFontDescriptorsFromURL(url as CFURL)as? [CTFontDescriptor],let first=descriptors.first else{return nil};return CTFontDescriptorCopyAttribute(first,kCTFontNameAttribute)as? String}.sorted() ?? []}
    static func registerAll(){for url in (try? FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:nil)) ?? []{CTFontManagerRegisterFontsForURL(url as CFURL,.process,nil)}}
    static func importFont(_ url:URL)throws->String{
        let scoped=url.startAccessingSecurityScopedResource();defer{if scoped{url.stopAccessingSecurityScopedResource()}}
        guard ["ttf","otf","ttc"].contains(url.pathExtension.lowercased()),(try url.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? Int.max)<=16_777_216,let descriptors=CTFontManagerCreateFontDescriptorsFromURL(url as CFURL)as? [CTFontDescriptor],let first=descriptors.first,let name=CTFontDescriptorCopyAttribute(first,kCTFontNameAttribute)as? String else{throw ComicFailure.message("اختر خط TTF أو OTF أو TTC صالحًا بحجم لا يتجاوز 16 MiB.")}
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let target=root.appendingPathComponent(UUID().uuidString+"."+url.pathExtension.lowercased());try FileManager.default.copyItem(at:url,to:target)
        var error:Unmanaged<CFError>?;guard CTFontManagerRegisterFontsForURL(target as CFURL,.process,&error)else{try? FileManager.default.removeItem(at:target);throw ComicFailure.message("تعذّر تسجيل الخط.")};return name
    }
}
