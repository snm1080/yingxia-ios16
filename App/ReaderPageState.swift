import Foundation
import CoreGraphics

/// The requested page and the page actually on screen advance independently while an image loads.
/// Tokens reject late successes and failures, including an earlier visit to the very same URL.
struct ReaderPageHandoff<Page: Equatable, Value> {
    struct Request: Equatable {
        let page: Page
        let generation: UInt64
    }
    private(set) var requested: Request?
    private(set) var displayed: (page: Page, value: Value)?
    private(set) var failure: String?
    private(set) var isLoading = false
    private var generation: UInt64 = 0

    mutating func begin(_ page: Page) -> Request {
        generation &+= 1
        let request = Request(page: page, generation: generation)
        requested = request
        failure = nil
        isLoading = true
        return request
    }

    @discardableResult mutating func finish(_ request: Request, value: Value) -> Bool {
        guard request == requested else { return false }
        displayed = (request.page, value)
        failure = nil
        isLoading = false
        return true
    }

    @discardableResult mutating func fail(_ request: Request, message: String) -> Bool {
        guard request == requested else { return false }
        failure = message
        isLoading = false
        return true
    }

    mutating func cancel() {
        generation &+= 1
        requested = nil
        failure = nil
        isLoading = false
    }
}

/// A logical page target can cross chapter boundaries before the destination's page count
/// is known. End-relative offsets keep previous/next symmetric during a pending chapter load.
struct ReaderPageIntent: Equatable {
    enum Resolution: Equatable {
        case page(Int)
        case chapter(ReaderPageIntent)
    }

    let chapter: Int
    let page: Int
    var fromEnd = false

    func stepped(_ distance: Int) -> Self { Self(chapter: chapter, page: page + distance, fromEnd: fromEnd) }

    func normalizedBoundary() -> Self {
        if !fromEnd && page < 0 { return Self(chapter: chapter - 1, page: page, fromEnd: true) }
        if fromEnd && page >= 0 { return Self(chapter: chapter + 1, page: page) }
        return self
    }

    func resolve(pageCount: Int) -> Resolution {
        guard pageCount > 0 else { return .page(0) }
        let index = fromEnd ? pageCount + page : page
        if index < 0 { return .chapter(Self(chapter: chapter - 1, page: index, fromEnd: true)) }
        if index >= pageCount { return .chapter(Self(chapter: chapter + 1, page: index - pageCount)) }
        return .page(index)
    }

    func clampedPage(pageCount: Int) -> Int {
        min(max(0, fromEnd ? pageCount + page : page), max(0, pageCount - 1))
    }
}

/// Right angles are laid out in their rotated bounds before zoom is applied. A SwiftUI
/// rotationEffect alone keeps the old frame and clips wide pages after a quarter turn.
enum ReaderPageRotation: Int, CaseIterable {
    case upright = 0, clockwise = 90, upsideDown = 180, counterclockwise = 270

    var next: Self { Self(rawValue: (rawValue + 90) % 360)! }
    var swapsAxes: Bool { rawValue % 180 != 0 }

    func bounds(for size: CGSize) -> CGSize {
        swapsAxes ? CGSize(width: size.height, height: size.width) : size
    }

    func fittedSize(image: CGSize, viewport: CGSize, fitHeight: Bool) -> CGSize {
        let rotated = bounds(for: image)
        guard rotated.width > 0, rotated.height > 0, viewport.width > 0, viewport.height > 0 else { return .zero }
        let factor = fitHeight ? min(viewport.width / rotated.width, viewport.height / rotated.height) : viewport.width / rotated.width
        return CGSize(width: image.width * factor, height: image.height * factor)
    }
}

/// Lazy rows may appear well below the screen. Progress follows the page crossing the
/// reading line instead, and keeps its current page when several tiny rotated strips fit.
enum ReaderVerticalViewport {
    static func visiblePage<Page: Hashable>(frames: [Page: CGRect], height: CGFloat, current: Page) -> Page? {
        guard height > 0 else { return nil }
        let line = min(80, height * 0.15)
        if let frame = frames[current], frame.minY <= line,
           frame.maxY > line || frame.minY >= 0 && frame.maxY > 0 { return current }
        return frames.filter { $0.value.maxY > line && $0.value.minY < height }
            .min { left, right in
                let leftDistance = max(0, left.value.minY - line)
                let rightDistance = max(0, right.value.minY - line)
                if leftDistance != rightDistance { return leftDistance < rightDistance }
                return left.value.minY < right.value.minY
            }?.key
    }
}
