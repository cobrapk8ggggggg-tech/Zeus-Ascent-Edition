import Foundation
import CoreGraphics
import CryptoKit

enum ComicReadingMode: String, Codable, CaseIterable { case fastest, balanced, careful
    var title: String { switch self { case .fastest: return "الأسرع"; case .balanced: return "متوازن"; case .careful: return "دقيق" } }
}
enum ComicInkStyle: String, Codable, CaseIterable { case plain, outline, shadow
    var title: String { switch self { case .plain: return "عادي"; case .outline: return "محدّد (حواف بارزة)"; case .shadow: return "مظلّل" } }
}
enum ComicLetterCase: String, Codable, CaseIterable {
    case original, upper, lower, sentence
    var title: String { switch self { case .original: return "كما في الأصل"; case .upper: return "أحرف كبيرة"; case .lower: return "أحرف صغيرة"; case .sentence: return "بداية الجملة" } }
    func apply(_ text: String) -> String {
        switch self {
        case .original: return text
        case .upper: return text.uppercased()
        case .lower: return text.lowercased()
        case .sentence:
            var beginning = true
            return text.lowercased().map { character in
                let value = beginning ? String(character).uppercased() : String(character)
                if character.isLetter { beginning = false }
                if ".!?؟。".contains(character) { beginning = true }
                return value
            }.joined()
        }
    }
}
enum ComicSessionPhase: String {
    case idle, waiting, fetching, recognizing, downloading, translating, rendering, displaying, paused, completed, partial, failed
    var title: String {
        switch self {
        case .idle: return "ترجمة الصور"
        case .waiting: return "بانتظار الصور"
        case .fetching: return "جلب الصورة"
        case .recognizing: return "قراءة الفقاعات"
        case .downloading: return "تجهيز النماذج"
        case .translating: return "ترجمة الحوار"
        case .rendering: return "رسم الترجمة"
        case .displaying: return "عرض الترجمة"
        case .paused: return "الترجمة متوقفة"
        case .completed: return "الصور المتاحة جاهزة"
        case .partial: return "اكتملت بعض الصور"
        case .failed: return "تعذّرت ترجمة الصور"
        }
    }
}
struct ComicDiagnostic: Identifiable {
    let id = UUID()
    let phase: ComicSessionPhase
    let domain: String
    let code: Int
    let status: Int?
    let retryable: Bool
    var detail: String { "\(phase.title) · \(domain) \(code)" + (status.map { " · HTTP \($0)" } ?? "") }
    static func capture(_ error: Error, phase: ComicSessionPhase) -> ComicDiagnostic {
        if let failure = error as? ComicHTTPFailure {
            return ComicDiagnostic(phase: phase, domain: "HTTP", code: failure.status, status: failure.status, retryable: failure.status == 429 || failure.status >= 500)
        }
        let value = error as NSError
        let retryable = value.domain == NSURLErrorDomain && [NSURLErrorTimedOut, NSURLErrorNetworkConnectionLost, NSURLErrorNotConnectedToInternet, NSURLErrorCannotConnectToHost].contains(value.code)
        return ComicDiagnostic(phase: phase, domain: value.domain, code: value.code, status: nil, retryable: retryable)
    }
}
struct ComicHTTPFailure: LocalizedError {
    let status: Int
    var errorDescription: String? { status == 403 ? "رفض خادم الصور الطلب. يمكنك إعادة المحاولة بعد التحقق من تحميل الصورة في الصفحة." : "تعذّر جلب الصورة من الخادم (\(status))." }
}
struct ComicPreferences: Codable, Equatable {
    static let sourceLanguages=TranslationPreferences.languages+[("el","Ελληνικά"),("hi","हिन्दी"),("th","ไทย"),("ta","தமிழ்"),("te","తెలుగు"),("uk","Українська")]
    var mode: ComicReadingMode = .balanced
    var source = "auto"
    var automatic = false
    var showUntranslated = false
    var readAhead = true
    var restorationEnabled: Bool?
    var fontName: String?
    var localModel = false
    var fontScale: Double = 1
    var textColor: String?
    var inkStyleRaw: String?
    var allowOnlineFallback: Bool?
    var letterCaseRaw: String?
    var letterSpacing: Double?
    var letterCase: ComicLetterCase { ComicLetterCase(rawValue: letterCaseRaw ?? "") ?? .original }
    var renderIdentity: String { "render-v7|restoration:\(restorationEnabled ?? true)|\(fontName ?? "default")|\(fontScale)|\(textColor ?? "auto")|\(inkStyle.rawValue)|\(letterCase.rawValue)|\(letterSpacing ?? 0)" }
    var inkStyle: ComicInkStyle { get { ComicInkStyle(rawValue: inkStyleRaw ?? "") ?? .plain } set { inkStyleRaw = newValue.rawValue } }
    var engine: ComicOnlineEngine = .existing
    var translation: TranslationPreferences?
    func resolvedTranslation(_ settings:BrowserSettings)->TranslationPreferences{
        var value=translation ?? TranslationPreferences()
        if value.cloudflare==nil{value.cloudflare=settings.translation?.cloudflare}
        return value
    }
}
struct ComicCandidate: Codable, Identifiable {
    var id: String
    var source: String
    var kind: String
    var width: Int
    var height: Int
    var x: Double
    var y: Double
    var w: Double
    var h: Double
    var pending: Bool
    var revision: String
    var referrerPolicy: String?
}
struct ComicEnvelope: Codable {
    var document: String
    var url: String
    var language: String
    var viewport: Double
    var scroll: Double
    var items: [ComicCandidate]
}
struct ComicRegion: Codable, Equatable {
    var x: Int = 0
    var y: Int
    var width: Int
    var height: Int
    var coreTop: Int
    var coreBottom: Int
    var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}
struct ComicLine: Codable, Equatable {
    var text: String
    var confidence: Float
    var rect: CGRect
    var angle: Double = 0
    var glyphHeight: Double? = nil
}
struct ComicSpeech: Codable, Equatable {
    var id: String
    var text: String
    var lines: [ComicLine]
    var rect: CGRect
    var vertical: Bool
    var balloon: Bool = false
    // Optional so cached results from older revisions keep decoding.
    var angle: Double? = nil
}
struct ComicReading: Codable { var lines: [ComicLine]; var speeches: [ComicSpeech]; var language: String; var runtime: String }
struct ComicCachedResult: Codable { var version = 1; var reading: ComicReading; var translations: [TranslationSegment] }
enum ComicFailure: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let s) = self { return s }; return nil }
}
enum ComicIdentity {
    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func hash(_ text: String) -> String { hash(Data(text.utf8)) }
    static func segmentIdentity(_ segments:[TranslationSegment])->String {
        hash(segments.map{$0.id+"\0"+$0.text}.joined(separator:"\n"))
    }
    static func settings(_ preferences: ComicPreferences, translation: TranslationPreferences, provider: AIProviderConfiguration?) -> String {
        hash("comic-v13|fallback:\(preferences.allowOnlineFallback ?? false)|\(preferences.mode.rawValue)|\(preferences.source)|\(translation.target)|" + TranslationMemory.namespace(page: "comic://content", preferences: translation, provider: provider))
    }
}
enum ComicGeometry {
    // Overlap is context, not output ownership. Every source row belongs to one core.
    static func regions(width: Int, height: Int, maximumPixels: Int = 8_000_000) -> [ComicRegion] {
        guard width > 0, height > 0, width <= 16_384, height <= 1_000_000, maximumPixels >= width else { return [] }
        let rowBudget=maximumPixels/width
        let overlap = min(256, max(16, width / 8), max(0,(rowBudget-64)/2))
        let step = max(1, min(4096, rowBudget - overlap * 2))
        return stride(from: 0, to: height, by: step).map { top in
            let begin = max(0, top - overlap), end = min(height, top + step + overlap)
            return ComicRegion(y: begin, width: width, height: end - begin, coreTop: top - begin, coreBottom: min(height, top + step) - begin)
        }
    }
    static func prioritized(_ regions:[ComicRegion],candidate:ComicCandidate,scroll:Double,viewport:Double,readAhead:Bool)->[ComicRegion]{
        guard candidate.height>0,viewport>0 else{return []}
        func bounds(_ r:ComicRegion)->(Double,Double){let scale=candidate.h/Double(candidate.height);return(candidate.y+Double(r.y+r.coreTop)*scale,candidate.y+Double(r.y+r.coreBottom)*scale)}
        func distance(_ r:ComicRegion)->Double{let (top,bottom)=bounds(r);return max(0,top-scroll-viewport,scroll-bottom)}
        return regions.filter{r in let(top,bottom)=bounds(r);return bottom>=scroll-(readAhead ? viewport:0)&&top<=scroll+viewport*(readAhead ? 8:1)}.sorted{distance($0)<distance($1)}
    }
    static func estimateAngle(_ lines:[ComicLine])->Double{
        // Baseline orientation comes from the OCR quadrilateral. The drift of
        // separate line centres describes paragraph alignment, never glyph tilt.
        let angles=lines.filter { $0.rect.width > $0.rect.height && $0.confidence >= 0.5 }.map(\.angle).sorted()
        guard !angles.isEmpty else{return 0}
        let median=angles[angles.count/2]
        guard abs(median)>=2 * .pi/180,abs(median)<=35 * .pi/180,
              angles.allSatisfy({abs($0-median)<5 * .pi/180})else{return 0}
        return median
    }
    static func orderedLines(_ lines:[ComicLine],vertical:Bool)->[ComicLine]{
        if vertical{return lines.sorted{$0.rect.midX>$1.rect.midX}}
        var rows:[[ComicLine]]=[]
        for line in lines.sorted(by:{$0.rect.midY<$1.rect.midY}){
            if let index=rows.firstIndex(where:{row in abs(row[0].rect.midY-line.rect.midY)<min(row[0].rect.height,line.rect.height)*0.5}){rows[index].append(line)}else{rows.append([line])}
        }
        return rows.flatMap{$0.sorted{$0.rect.minX<$1.rect.minX}}
    }
    static func uniqueLines(_ input:[ComicLine])->[ComicLine]{
        let candidates=input.filter{line in
            let letters=line.text.filter{$0.isLetter || $0.isNumber}.count
            return letters>0 && line.rect.width>2 && line.rect.height>3 && line.confidence>=0.3
        }.sorted { $0.rect.width * $0.rect.height > $1.rect.width * $1.rect.height }
        var result:[ComicLine]=[]
        for line in candidates {
            let duplicate=result.contains { other in
                let overlap=line.rect.intersection(other.rect)
                return !overlap.isNull && overlap.width*overlap.height/(line.rect.width*line.rect.height)>0.75
            }
            if !duplicate{result.append(line)}
        }
        return result
    }
    static func group(_ input: [ComicLine], source: String) -> [ComicSpeech] {
        let lines = uniqueLines(input)
        var groups: [[ComicLine]] = []
        for line in lines.sorted(by: { $0.rect.minY < $1.rect.minY }) {
            // Select among compatible groups: a nearer adjacent balloon must not
            // hide the correct group above this line.
            let compatible=groups.indices.filter{i in
                guard let last=groups[i].last else{return false}
                let gap=line.rect.minY-last.rect.maxY
                let overlap=min(line.rect.maxX,last.rect.maxX)-max(line.rect.minX,last.rect.minX)
                let vertical=line.rect.height>line.rect.width*1.5 && last.rect.height>last.rect.width*1.5
                if vertical{
                    let columnGap=max(line.rect.minX-last.rect.maxX,last.rect.minX-line.rect.maxX)
                    let verticalOverlap=min(line.rect.maxY,last.rect.maxY)-max(line.rect.minY,last.rect.minY)
                    return columnGap<max(line.rect.width,last.rect.width)*1.1 && verticalOverlap>min(line.rect.height,last.rect.height)*0.6
                }
                let rowOverlap=min(line.rect.maxY,last.rect.maxY)-max(line.rect.minY,last.rect.minY)
                let horizontalGap=max(line.rect.minX-last.rect.maxX,last.rect.minX-line.rect.maxX)
                let sameRow=rowOverlap>min(line.rect.height,last.rect.height)*0.6 && horizontalGap<max(line.rect.height,last.rect.height)*1.2
                let nextRow=gap >= -min(line.rect.height,last.rect.height)*0.5 && gap<max(line.rect.height,last.rect.height)*1.2 && overlap>min(line.rect.width,last.rect.width)*0.3
                return sameRow || nextRow
            }
            if let i=compatible.min(by:{abs(groups[$0].last!.rect.midY-line.rect.midY)<abs(groups[$1].last!.rect.midY-line.rect.midY)}){groups[i].append(line);continue}
            groups.append([line])
        }
        let japanese = source.hasPrefix("ja")
        let dialogue=groups.filter{group in
            guard group.count==1,let text=group.first?.text.trimmingCharacters(in:.whitespacesAndNewlines),text.count==1,let scalar=text.unicodeScalars.first else{return true}
            // Isolated Latin labels outside a closed balloon are usually logos
            // or diagram markers. Keep them rather than lettering over artwork.
            return !(scalar.value<0x0250 && scalar.properties.isAlphabetic)
        }
        return dialogue.enumerated().map { index, group in
            let bounds = group.reduce(CGRect.null) { $0.union($1.rect) }
            let vertical = group.allSatisfy { $0.rect.height > $0.rect.width * 1.5 }
            let ordered = orderedLines(group,vertical:vertical)
            return ComicSpeech(id: String(index), text: ordered.map(\.text).joined(separator: vertical ? "" : " "), lines: ordered, rect: bounds, vertical: vertical, balloon: false, angle: vertical ? nil:ComicGeometry.estimateAngle(group))
        }.sorted { a,b in
            if abs(a.rect.minY-b.rect.minY) < min(a.rect.height,b.rect.height)*0.35 { return japanese ? a.rect.midX > b.rect.midX : a.rect.midX < b.rect.midX }
            return a.rect.minY < b.rect.minY
        }.enumerated().map { i,s in var s=s; s.id=String(i);return s }
    }
}
