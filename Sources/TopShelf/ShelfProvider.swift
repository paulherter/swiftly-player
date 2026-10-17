import TVServices

/// Fills the Top Shelf on the Apple TV home screen.
///
/// Deliberately makes no server request: the extension is called every time
/// focus lands on the app icon and then has a fraction of a second. An HTTPS
/// request would not finish in that time and the shelf would stay empty. It
/// only reads what the app stored when the home page was last opened - see
/// `ShelfPreview`.
final class ShelfProvider: TVTopShelfContentProvider {

    /// Deliberately the completion-handler variant, not the `async` one.
    ///
    /// `TVTopShelfContent` is not `Sendable`, and under Swift 6 such a value may
    /// not be returned across the actor boundary from an `async` override. The
    /// completion handler does not have that boundary - and it is not needed
    /// here: reading one small file takes no time.
    override func loadTopShelfContent(completionHandler: @escaping (TVTopShelfContent?) -> Void) {
        guard let preview = Shelf.read(), !preview.categories.isEmpty else {
            completionHandler(nil)
            return
        }

        let collections = preview.categories.map { category in
            let entries = category.entries.map { entryRecord -> TVTopShelfSectionedItem in
                let piece = TVTopShelfSectionedItem(identifier: entryRecord.id)
                piece.title = entryRecord.title
                piece.imageShape = category.landscape ? .hdtv : .poster
                if let image = entryRecord.image {
                    piece.setImageURL(image, for: .screenScale1x)
                    piece.setImageURL(image, for: .screenScale2x)
                }
                if let share = entryRecord.progress {
                    piece.playbackProgress = share
                }
                // Select opens the title page, Play starts immediately and resumes (Apple HIG,
                // Playing video). Anything that cannot be played directly - a series - opens
                // the app as a page on the second path too.
                piece.displayAction = URL(string: "swiftly://titel/\(entryRecord.id)")
                    .map(TVTopShelfAction.init(url:))
                piece.playAction = URL(string: "swiftly://abspielen/\(entryRecord.id)")
                    .map(TVTopShelfAction.init(url:))
                return piece
            }
            let collection = TVTopShelfItemCollection(items: entries)
            collection.title = category.title
            return collection
        }

        completionHandler(TVTopShelfSectionedContent(sections: collections))
    }
}
