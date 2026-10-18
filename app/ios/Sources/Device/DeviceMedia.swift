import Photos
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The clipboard and the photo library for the device modules (D40).
/// Images travel as base64 PNG or JPEG; HEIC and other formats Pillow can't
/// read are converted to JPEG where a program wants pixels.
@MainActor
final class DeviceMedia {
    unowned let bridge: DeviceBridge

    init(bridge: DeviceBridge) {
        self.bridge = bridge
    }

    func perform(_ op: String, _ v: [String: Any]) async throws -> Any? {
        switch op {
        case "clipboard.get": return UIPasteboard.general.string ?? ""
        case "clipboard.set": UIPasteboard.general.string = v.string("text") ?? ""; return nil
        case "clipboard.getImage":
            let images = UIPasteboard.general.images ?? []
            let i = v.int("index") ?? 0
            return images.indices.contains(i) ? images[i].pngData()?.base64EncodedString() : nil
        case "clipboard.setImage":
            guard let data = v.string("data").flatMap({ Data(base64Encoded: $0) }), let image = UIImage(data: data) else {
                throw DeviceBridge.Failure.value("not an image")
            }
            if v.string("format") == "jpeg" {
                UIPasteboard.general.setData(data, forPasteboardType: UTType.jpeg.identifier)
            } else {
                UIPasteboard.general.image = image
            }
            return nil
        case "photos.capture": return await capture(front: v.string("camera") == "front")
        case "photos.pickImage": return await pickImages(multi: v.bool("multi") ?? false)
        case "photos.save": return try await save(v)
        default: return try await library(op, v)
        }
    }

    // MARK: camera and system picker (no library permission)

    private func capture(front: Bool) async -> Any? {
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else { return nil }
        let delegate = CameraDelegate()
        return await bridge.modal { finish in
            let picker = UIImagePickerController()
            picker.sourceType = .camera
            if front, UIImagePickerController.isCameraDeviceAvailable(.front) { picker.cameraDevice = .front }
            delegate.onFinish = { image in finish(image?.jpegData(compressionQuality: 0.92)?.base64EncodedString()) }
            picker.delegate = delegate
            objc_setAssociatedObject(picker, &CameraDelegate.key, delegate, .OBJC_ASSOCIATION_RETAIN)
            return picker
        }
    }

    private func pickImages(multi: Bool) async -> Any? {
        let delegate = PickerDelegate()
        return await bridge.modal { finish in
            var config = PHPickerConfiguration()
            config.filter = .images
            config.selectionLimit = multi ? 0 : 1
            let picker = PHPickerViewController(configuration: config)
            delegate.onFinish = { results in
                guard !results.isEmpty else { return finish(nil) }
                Task { @MainActor in
                    var out: [String] = []
                    for r in results {
                        if let data = await Self.loadImageData(r.itemProvider) { out.append(data.base64EncodedString()) }
                    }
                    finish(out)
                }
            }
            picker.delegate = delegate
            objc_setAssociatedObject(picker, &PickerDelegate.key, delegate, .OBJC_ASSOCIATION_RETAIN)
            return picker
        }
    }

    private static func loadImageData(_ provider: NSItemProvider) async -> Data? {
        await withCheckedContinuation { (c: CheckedContinuation<Data?, Never>) in
            provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                c.resume(returning: data.map(Self.decodable))
            }
        }
    }

    /// Image data Pillow can open: PNG, JPEG and GIF stay, the rest becomes JPEG.
    nonisolated static func decodable(_ data: Data) -> Data {
        let head = [UInt8](data.prefix(4))
        if head.starts(with: [0x89, 0x50, 0x4E, 0x47]) || head.starts(with: [0xFF, 0xD8]) || head.starts(with: [0x47, 0x49, 0x46]) { return data }
        return UIImage(data: data)?.jpegData(compressionQuality: 0.92) ?? data
    }

    private func save(_ v: [String: Any]) async throws -> Any? {
        guard let data = v.string("data").flatMap({ Data(base64Encoded: $0) }) else { throw DeviceBridge.Failure.value("not an image") }
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { throw DeviceBridge.Failure.permission("Adding photos") }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: nil)
        }
        return true
    }

    // MARK: the library

    private func authorize() async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized || status == .limited else { throw DeviceBridge.Failure.permission("Access to photos") }
    }

    private func library(_ op: String, _ v: [String: Any]) async throws -> Any? {
        try await authorize()
        switch op {
        case "photos.assets":
            if let id = v.string("collection") {
                guard let collection = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [id], options: nil).firstObject else { throw DeviceBridge.Failure.io("no such album") }
                return Self.list(PHAsset.fetchAssets(in: collection, options: Self.byDate())).map(Self.info)
            }
            let options = Self.byDate()
            options.includeHiddenAssets = v.bool("include_hidden") ?? false
            return Self.list(PHAsset.fetchAssets(with: v.string("media_type") == "video" ? .video : .image, options: options)).map(Self.info)
        case "photos.asset": return Self.info(try Self.asset(v.string("id")))
        case "photos.collections": return collections(v.string("kind") ?? "albums").map(Self.info)
        case "photos.image": return try await image(try Self.asset(v.string("id")), v)
        case "photos.setProperties":
            let asset = try Self.asset(v.string("id"))
            try await PHPhotoLibrary.shared().performChanges {
                let r = PHAssetChangeRequest(for: asset)
                if let f = v.bool("favorite") { r.isFavorite = f }
                if let h = v.bool("hidden") { r.isHidden = h }
                if let d = ISODate.parse(v.string("creation_date")) { r.creationDate = d }
                if let loc = v["location"] as? [String: Any], let lat = loc.double("latitude"), let lng = loc.double("longitude") {
                    r.location = CLLocation(coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lng), altitude: loc.double("altitude") ?? 0,
                                            horizontalAccuracy: 0, verticalAccuracy: 0, timestamp: Date())
                }
            }
            return Self.info(try Self.asset(asset.localIdentifier))
        case "photos.editContent":
            let asset = try Self.asset(v.string("id"))
            let jpeg = try bridge.fileData(v["file"], mount: v.mount)
            guard let input = await Self.editingInput(asset).value as? PHContentEditingInput else { throw DeviceBridge.Failure.io("the photo can't be edited") }
            let output = PHContentEditingOutput(contentEditingInput: input)
            output.adjustmentData = PHAdjustmentData(formatIdentifier: Bundle.main.bundleIdentifier ?? "terrarium", formatVersion: "1.0", data: Data())
            try jpeg.write(to: output.renderedContentURL)
            try await PHPhotoLibrary.shared().performChanges { PHAssetChangeRequest(for: asset).contentEditingOutput = output }
            return Self.info(try Self.asset(asset.localIdentifier))
        case "photos.delete":
            let assets = PHAsset.fetchAssets(withLocalIdentifiers: v["ids"] as? [String] ?? [], options: nil)
            try await PHPhotoLibrary.shared().performChanges { PHAssetChangeRequest.deleteAssets(assets) }
            return nil
        case "photos.revert":
            let assets = Self.list(PHAsset.fetchAssets(withLocalIdentifiers: v["ids"] as? [String] ?? [], options: nil))
            try await PHPhotoLibrary.shared().performChanges { for a in assets { PHAssetChangeRequest(for: a).revertAssetContentToOriginal() } }
            return nil
        case "photos.createAlbum":
            var id = ""
            try await PHPhotoLibrary.shared().performChanges {
                id = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: v.string("title") ?? "").placeholderForCreatedAssetCollection.localIdentifier
            }
            guard let c = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [id], options: nil).firstObject else { throw DeviceBridge.Failure.io("the album was not created") }
            return Self.info(c)
        case "photos.createAsset":
            let url = try bridge.fileURL(v["file"], mount: v.mount)
            var id = ""
            try await PHPhotoLibrary.shared().performChanges {
                id = PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: url)?.placeholderForCreatedAsset?.localIdentifier ?? ""
            }
            return Self.info(try Self.asset(id))
        case "photos.collection.add", "photos.collection.remove", "photos.collection.rename", "photos.collection.delete":
            guard let c = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [v.string("id") ?? ""], options: nil).firstObject else { throw DeviceBridge.Failure.io("no such album") }
            let assets = PHAsset.fetchAssets(withLocalIdentifiers: v["assets"] as? [String] ?? [], options: nil)
            try await PHPhotoLibrary.shared().performChanges {
                switch op {
                case "photos.collection.add": PHAssetCollectionChangeRequest(for: c)?.addAssets(assets)
                case "photos.collection.remove": PHAssetCollectionChangeRequest(for: c)?.removeAssets(assets)
                case "photos.collection.rename": PHAssetCollectionChangeRequest(for: c)?.title = v.string("title") ?? c.localizedTitle ?? ""
                default: PHAssetCollectionChangeRequest.deleteAssetCollections([c] as NSArray)
                }
            }
            if op == "photos.collection.delete" { return nil }
            return PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [c.localIdentifier], options: nil).firstObject.map(Self.info)
        case "photos.pick":
            let assets: [PHAsset]
            if let ids = v["ids"] as? [String] {
                let found = Dictionary(Self.list(PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)).map { ($0.localIdentifier, $0) }, uniquingKeysWith: { a, _ in a })
                assets = ids.compactMap { found[$0] }
            } else {
                let options = Self.byDate()
                options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
                assets = Self.list(PHAsset.fetchAssets(with: .image, options: options))
            }
            let multi = v.bool("multi") ?? false
            let picked = await bridge.modal { finish in
                UIHostingController(rootView: AssetGrid(title: v.string("title") ?? "", assets: assets, multi: multi, done: finish))
            }
            guard let ids = picked as? [String] else { return nil }
            let byID = Dictionary(assets.map { ($0.localIdentifier, $0) }, uniquingKeysWith: { a, _ in a })
            return ids.compactMap { byID[$0] }.map(Self.info)
        default:
            throw DeviceBridge.Failure(kind: "NotImplementedError", message: "device.\(op)")
        }
    }

    private func collections(_ kind: String) -> [PHAssetCollection] {
        let special: [String: PHAssetCollectionSubtype] = [
            "favorites": .smartAlbumFavorites, "recently_added": .smartAlbumRecentlyAdded,
            "selfies": .smartAlbumSelfPortraits, "screenshots": .smartAlbumScreenshots,
        ]
        if let subtype = special[kind] { return Self.list(PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: subtype, options: nil)) }
        return Self.list(PHAssetCollection.fetchAssetCollections(with: kind == "smart" ? .smartAlbum : .album, subtype: .any, options: nil))
    }

    private func image(_ asset: PHAsset, _ v: [String: Any]) async throws -> Any? {
        if let size = v["size"] as? [NSNumber], size.count == 2 {
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.resizeMode = .exact
            options.isNetworkAccessAllowed = true
            let target = CGSize(width: size[0].doubleValue, height: size[1].doubleValue)
            let image = await withCheckedContinuation { (c: CheckedContinuation<UIImage?, Never>) in
                var resumed = false
                PHImageManager.default().requestImage(for: asset, targetSize: target, contentMode: v.bool("crop") == true ? .aspectFill : .aspectFit, options: options) { image, info in
                    if (info?[PHImageResultIsDegradedKey] as? Bool) == true || resumed { return }
                    resumed = true
                    c.resume(returning: image)
                }
            }
            guard let data = image?.pngData() else { throw DeviceBridge.Failure.io("no image data") }
            return ["data": data.base64EncodedString(), "uti": UTType.png.identifier]
        }
        let options = PHImageRequestOptions()
        options.version = v.bool("original") == true ? .original : .current
        options.isNetworkAccessAllowed = true
        let (data, uti) = await withCheckedContinuation { (c: CheckedContinuation<(Data?, String?), Never>) in
            PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, uti, _, _ in c.resume(returning: (data, uti)) }
        }
        guard var data else { throw DeviceBridge.Failure.io("no image data") }
        var type = uti ?? UTType.jpeg.identifier
        if v.bool("decodable") == true {
            let converted = Self.decodable(data)
            if converted != data { type = UTType.jpeg.identifier }
            data = converted
        }
        return ["data": data.base64EncodedString(), "uti": type]
    }

    private static func editingInput(_ asset: PHAsset) async -> Unchecked {
        await withCheckedContinuation { c in
            let options = PHContentEditingInputRequestOptions()
            options.isNetworkAccessAllowed = true
            asset.requestContentEditingInput(with: options) { input, _ in c.resume(returning: Unchecked(value: input)) }
        }
    }

    // MARK: helpers

    private static func byDate() -> PHFetchOptions {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        return options
    }

    private static func list<T>(_ result: PHFetchResult<T>) -> [T] {
        var out: [T] = []
        result.enumerateObjects { item, _, _ in out.append(item) }
        return out
    }

    private static func asset(_ id: String?) throws -> PHAsset {
        guard let id, let a = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else {
            throw DeviceBridge.Failure.io("no asset with the id \(id ?? "")")
        }
        return a
    }

    private static func info(_ a: PHAsset) -> [String: Any] {
        var subtypes: [String] = []
        let names: [(PHAssetMediaSubtype, String)] = [
            (.photoPanorama, "photo_panorama"), (.photoHDR, "photo_hdr"), (.photoScreenshot, "photo_screenshot"),
            (.photoLive, "photo_live"), (.photoDepthEffect, "photo_depth_effect"), (.videoStreamed, "video_streamed"),
            (.videoHighFrameRate, "video_high_frame_rate"), (.videoTimelapse, "video_timelapse"),
        ]
        for (flag, name) in names where a.mediaSubtypes.contains(flag) { subtypes.append(name) }
        let location: Any = a.location.map { ["latitude": $0.coordinate.latitude, "longitude": $0.coordinate.longitude, "altitude": $0.altitude] } ?? NSNull()
        return [
            "local_id": a.localIdentifier, "pixel_width": a.pixelWidth, "pixel_height": a.pixelHeight,
            "media_type": a.mediaType == .video ? "video" : a.mediaType == .audio ? "audio" : "image", "media_subtypes": subtypes,
            "creation_date": ISODate.format(a.creationDate), "modification_date": ISODate.format(a.modificationDate),
            "hidden": a.isHidden, "favorite": a.isFavorite, "duration": a.duration, "location": location,
            "can_edit_content": a.canPerform(.content), "can_edit_properties": a.canPerform(.properties), "can_delete": a.canPerform(.delete),
        ]
    }

    private static func info(_ c: PHAssetCollection) -> [String: Any] {
        let subtype: String = switch c.assetCollectionSubtype {
        case .smartAlbumFavorites: "favorites"
        case .smartAlbumRecentlyAdded: "recently_added"
        case .smartAlbumSelfPortraits: "selfies"
        case .smartAlbumScreenshots: "screenshots"
        case .smartAlbumUserLibrary: "user_library"
        case .smartAlbumVideos: "videos"
        case .albumRegular: "regular"
        default: "other"
        }
        return [
            "local_id": c.localIdentifier, "title": c.localizedTitle ?? "", "type": c.assetCollectionType == .smartAlbum ? "smart_album" : "album",
            "subtype": subtype, "start_date": ISODate.format(c.startDate), "end_date": ISODate.format(c.endDate),
            "can_delete": c.canPerform(.delete), "can_add_assets": c.canPerform(.addContent),
            "can_remove_assets": c.canPerform(.removeContent), "can_rename": c.canPerform(.rename),
        ]
    }
}

final class CameraDelegate: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
    nonisolated(unsafe) static var key: UInt8 = 0
    var onFinish: (UIImage?) -> Void = { _ in }
    func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
        onFinish(info[.originalImage] as? UIImage)
    }
    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { onFinish(nil) }
}

final class PickerDelegate: NSObject, PHPickerViewControllerDelegate {
    nonisolated(unsafe) static var key: UInt8 = 0
    var onFinish: ([PHPickerResult]) -> Void = { _ in }
    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) { onFinish(results) }
}

/// photos.pick_asset: a grid of the given assets' thumbnails.
private struct AssetGrid: View {
    let title: String
    let assets: [PHAsset]
    let multi: Bool
    let done: (Any?) -> Void
    @State private var selected: [String] = []

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 2)], spacing: 2) {
                    ForEach(assets, id: \.localIdentifier) { asset in
                        Thumbnail(asset: asset)
                            .overlay(alignment: .bottomTrailing) {
                                if selected.contains(asset.localIdentifier) {
                                    Image(systemName: "checkmark.circle.fill").font(.title3).foregroundStyle(.white, Color.accentColor).padding(4)
                                }
                            }
                            .onTapGesture {
                                if !multi { return done([asset.localIdentifier]) }
                                if let i = selected.firstIndex(of: asset.localIdentifier) { selected.remove(at: i) } else { selected.append(asset.localIdentifier) }
                            }
                    }
                }
            }
            .overlay { if assets.isEmpty { ContentUnavailableView("No Photos", systemImage: "photo.on.rectangle") } }
            .navigationTitle(title.isEmpty ? "Photos" : title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { done(nil) } }
                if multi { ToolbarItem(placement: .confirmationAction) { Button("Done") { done(selected) }.fontWeight(.semibold) } }
            }
        }
    }
}

private struct Thumbnail: View {
    let asset: PHAsset
    @State private var image: UIImage?

    var body: some View {
        Color(.secondarySystemFill)
            .aspectRatio(1, contentMode: .fill)
            .overlay { if let image { Image(uiImage: image).resizable().scaledToFill() } }
            .clipped()
            .task {
                let options = PHImageRequestOptions()
                options.deliveryMode = .opportunistic
                options.isNetworkAccessAllowed = true
                PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: 240, height: 240), contentMode: .aspectFill, options: options) { img, _ in
                    if let img { image = img }
                }
            }
    }
}
