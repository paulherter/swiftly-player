import Foundation
import JellyfinKit

// Case: {"id","gen","file","reported","current"|null,"text"|null}
// Result: description(id,gen,file), dismantle of that, dismantle of `text`, applies.
let domainDownloadTask = Domain("download_task") { raw in
    let c = try srDict(raw)
    func parts(_ p: DownloadTask.Parts?) -> Any {
        guard let p else { return NSNull() }
        return ["id": p.id, "generation": p.generation, "file": p.file] as [String: Any]
    }
    let text = DownloadTask.description(id: srStr(c["id"]) ?? "", generation: srInt(c["gen"]) ?? 0,
                                        file: srStr(c["file"]) ?? "")
    return [
        "description": text,
        "round": parts(DownloadTask.dismantle(text)),
        "raw": parts(DownloadTask.dismantle(srStr(c["text"]))),
        "applies": DownloadTask.applies(reported: srInt(c["reported"]) ?? 0, current: srInt(c["current"])),
    ] as [String: Any]
}
