import Foundation
import ZeusComicRuntime

/// Lossless float32 tensors: the native reader retains the same masks,
/// resizing, postprocessing and lettering. The server only runs pinned ONNX.
enum ComicCloudRestoration {
    static func pack(_ values:[Float])throws->String{
        let raw=values.withUnsafeBytes{Data($0)}
        var compressed=Data(count:raw.count+raw.count/100+1024)
        let capacity=compressed.count
        let count=raw.withUnsafeBytes{input in compressed.withUnsafeMutableBytes{output in
            zeus_comic_deflate(input.bindMemory(to:UInt8.self).baseAddress,UInt(raw.count),output.bindMemory(to:UInt8.self).baseAddress,UInt(capacity))
        }}
        guard count>0 else{throw ComicFailure.message("تعذر ضغط بيانات الترميم دون فقد.")}
        compressed.count=Int(count);return compressed.base64EncodedString()
    }
    static func unpack(_ encoded:String,count:Int)throws->[Float]{
        guard count>0,count<=4_194_304,encoded.count<=24_000_000,let compressed=Data(base64Encoded:encoded)else{throw ComicFailure.message("خرج الترميم السحابي غير صالح.")}
        var raw=Data(count:count*4)
        let valid=compressed.withUnsafeBytes{input in raw.withUnsafeMutableBytes{output in
            zeus_comic_inflate(input.bindMemory(to:UInt8.self).baseAddress,UInt(compressed.count),output.bindMemory(to:UInt8.self).baseAddress,UInt(count*4))
        }}
        guard valid != 0 else{throw ComicFailure.message("بيانات الترميم السحابي غير مكتملة.")}
        var values=[Float](repeating:0,count:count)
        values.withUnsafeMutableBytes{raw.copyBytes(to:$0)}
        guard values.allSatisfy(\.isFinite)else{throw ComicFailure.message("خرج الترميم السحابي غير سليم.")};return values
    }
    static func infer(_ model:String,inputs:[String:[Float]],endpoint:URL)async throws->[Float]{
        guard ["ctd.onnx","lama.onnx"].contains(model),endpoint.scheme=="https",endpoint.user==nil,endpoint.password==nil,endpoint.query==nil,endpoint.fragment==nil else{throw ComicFailure.message("حدد عنوان HTTPS لخادم الترميم في إعدادات الصور.")}
        var packed:[String:String]=[:]
        for(key,value)in inputs{packed[key]=try pack(value)}
        let body=try JSONSerialization.data(withJSONObject:["version":1,"model":model,"inputs":packed])
        let data=try await NativeCloudAccountAPI.comicInference(endpoint:endpoint,body:body)
        struct Response:Decodable{var version:Int;var model:String;var sha256:String;var output:String}
        let result=try JSONDecoder().decode(Response.self,from:data)
        guard result.version==1,result.model==model,result.sha256==ComicModelStore.catalog.first(where:{$0.name==model})?.sha256 else{throw ComicFailure.message("الخادم لا يشغّل نموذج الترميم المعتمد نفسه.")}
        return try unpack(result.output,count:model=="ctd.onnx" ? 1024*1024:512*512*3)
    }
}
