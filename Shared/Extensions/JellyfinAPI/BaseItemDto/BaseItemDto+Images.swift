//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import BlurHashKit
import Factory
import Foundation
import JellyfinAPI
import UIKit

// TODO: figure out what to do about screen scaling with .main being deprecated
//       - maxWidth assume already scaled?
// TODO: change "series" image sources to "parent"
//       - for episodes and extras

extension BaseItemDto {

    // MARK: Item Images

    func imageURL(
        _ type: ImageType,
        index: Int? = nil,
        maxWidth: CGFloat? = nil,
        maxHeight: CGFloat? = nil,
        quality: Int? = nil,
        tag: String? = nil
    ) -> URL? {
        _imageURL(
            type,
            index: index,
            maxWidth: maxWidth,
            maxHeight: maxHeight,
            quality: quality,
            itemID: id ?? "",
            tag: tag
        )
    }

    // TODO: will server actually only have a single blurhash per type?
    //       - makes `firstBlurHash` redundant
    func blurHash(for type: ImageType) -> BlurHash? {
        guard let blurHashString = blurHashString(for: type) else {
            return nil
        }

        return BlurHash(string: blurHashString)
    }

    func blurHashString(for type: ImageType) -> String? {
        guard type != .logo else { return nil }

        if let tag = imageTags?[type.rawValue], let taggedBlurHash = imageBlurHashes?[type]?[tag] {
            return taggedBlurHash
        } else if let firstBlurHash = imageBlurHashes?[type]?.values.first {
            return firstBlurHash
        }

        return nil
    }

    func imageSource(
        _ type: ImageType,
        index: Int? = nil,
        maxWidth: CGFloat? = nil,
        maxHeight: CGFloat? = nil,
        quality: Int? = nil,
        tag: String? = nil
    ) -> ImageSource {
        _imageSource(
            type,
            index: index,
            maxWidth: maxWidth,
            maxHeight: maxHeight,
            quality: quality,
            tag: tag
        )
    }

    // MARK: Series Images

    /// - Note: Will force the creation of an image source even if it doesn't have a tag, due
    /// to episodes also retrieving series images in some areas. This may cause more 404s.
    func seriesImageURL(
        _ type: ImageType,
        index: Int? = nil,
        maxWidth: CGFloat? = nil,
        maxHeight: CGFloat? = nil,
        quality: Int? = nil
    ) -> URL? {
        _imageURL(
            type,
            index: index,
            maxWidth: maxWidth,
            maxHeight: maxHeight,
            quality: quality,
            itemID: seriesID ?? "",
            requireTag: false
        )
    }

    /// - Note: Will force the creation of an image source even if it doesn't have a tag, due
    /// to episodes also retrieving series images in some areas. This may cause more 404s.
    func seriesImageSource(
        _ type: ImageType,
        index: Int? = nil,
        maxWidth: CGFloat? = nil,
        maxHeight: CGFloat? = nil,
        quality: Int? = nil
    ) -> ImageSource {
        let url = _imageURL(
            type,
            index: index,
            maxWidth: maxWidth,
            maxHeight: maxHeight,
            quality: quality,
            itemID: seriesID ?? "",
            requireTag: false
        )

        return ImageSource(
            url: url,
            blurHash: nil
        )
    }

    // MARK: private

    func _imageURL(
        _ type: ImageType,
        index: Int? = nil,
        maxWidth: CGFloat?,
        maxHeight: CGFloat?,
        quality: Int?,
        itemID: String,
        tag: String? = nil,
        requireTag: Bool = true
    ) -> URL? {
        // tvOS renders its UI at a fixed 1x, so points == pixels. Read the display scale from the trait
        // environment (the modern replacement for the now-deprecated `UIScreen.main` — this is the one part
        // of upstream Swiftfin #2068 we adopt) but fall back to 1 when it's UNSPECIFIED: a trait collection's
        // `displayScale` is 0.0 when read outside a trait environment — e.g. our off-main prefetch and
        // model-owned image-source tasks — and 0 would zero the request out, so the server would return the
        // FULL-RESOLUTION image. (Apple docs: `UITraitCollection.displayScale` "default … is 0.0
        // (indicating unspecified)".) On tvOS the resolved value is always 1, so this matches the previous
        // `UIScreen.main.nativeScale` behavior exactly while dropping the deprecated API.
        let displayScale = UITraitCollection.current.displayScale
        let pixelScale = displayScale > 0 ? displayScale : 1

        let scaleWidth = maxWidth.map { Int($0 * pixelScale) }
        // NOTE (GuamaFlix): both dimensions are mapped independently — a maxHeight-ONLY request must still
        // send a size, else (both dims nil) the server returns the FULL-RESOLUTION image (e.g. every title
        // logo). Upstream #2068 independently made this same fix, validating ours.
        let scaleHeight = maxHeight.map { Int($0 * pixelScale) }
        let validQuality = quality.map { clamp($0, min: 1, max: 100) }

        let tag = tag ?? getImageTag(for: type)

        guard tag != nil || !requireTag else { return nil }

        guard let client = Container.shared.currentUserSession()?.client else { return nil }

        let parameters = Paths.GetItemImageParameters(
            maxWidth: scaleWidth,
            maxHeight: scaleHeight,
            quality: validQuality,
            tag: tag,
            format: type == .logo ? .png : nil,
            imageIndex: index
        )

        let request = Paths.getItemImage(
            itemID: itemID,
            imageType: type.rawValue,
            parameters: parameters
        )

        return client.url(with: request)
    }

    private func getImageTag(for type: ImageType) -> String? {
        switch type {
        case .backdrop:
            backdropImageTags?.first
        case .screenshot:
            screenshotImageTags?.first
        default:
            imageTags?[type.rawValue]
        }
    }

    private func _imageSource(
        _ type: ImageType,
        index: Int? = nil,
        maxWidth: CGFloat?,
        maxHeight: CGFloat?,
        quality: Int?,
        tag: String? = nil
    ) -> ImageSource {
        let url = _imageURL(
            type,
            index: index,
            maxWidth: maxWidth,
            maxHeight: maxHeight,
            quality: quality,
            itemID: id ?? "",
            tag: tag
        )
        let blurHash = blurHashString(for: type)

        return ImageSource(
            url: url,
            blurHash: blurHash
        )
    }
}
