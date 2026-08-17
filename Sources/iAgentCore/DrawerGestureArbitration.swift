import Foundation

/// A reference-semantic action gate shared by the UIKit drawer recognizers and
/// SwiftUI controls inside the drawer.
///
/// A SwiftUI `Environment` value can be a frame behind a UIKit gesture callback.
/// Keeping the current interaction state in this shared object makes the check
/// synchronous at button-action time, including the finger-up event that ends a
/// pan over a different row.
public final class DrawerActivationGate: @unchecked Sendable {
  private let lock = NSLock()
  private var blocked = false

  public init() {}

  public var blocksActivation: Bool {
    lock.lock()
    defer { lock.unlock() }
    return blocked
  }

  public func setBlocked(_ isBlocked: Bool) {
    lock.lock()
    blocked = isBlocked
    lock.unlock()
  }

  /// Runs `action` only when no drawer/content pan owns the current touch.
  @discardableResult
  public func performIfAllowed(_ action: () -> Void) -> Bool {
    lock.lock()
    let isAllowed = !blocked
    lock.unlock()

    guard isAllowed else { return false }
    action()
    return true
  }
}

/// Deterministic ownership policy for horizontal page swipes. The policy has no
/// edge-location requirement; local controls such as a Notes delete swipe can
/// explicitly retain ownership for the current touch sequence.
public enum PageSwipeGestureArbitration {
  public static func shouldTrack(
    horizontalTranslation: Double,
    verticalTranslation: Double,
    localHorizontalGestureIsActive: Bool
  ) -> Bool {
    !localHorizontalGestureIsActive
      && abs(horizontalTranslation) > abs(verticalTranslation) * 1.15
  }

  /// Returns +1 for the next page, -1 for the previous page, or nil when the
  /// release was too short/vertical or is owned by a local horizontal gesture.
  public static func pageDelta(
    predictedHorizontalTranslation: Double,
    predictedVerticalTranslation: Double,
    localHorizontalGestureIsActive: Bool
  ) -> Int? {
    guard !localHorizontalGestureIsActive,
          abs(predictedHorizontalTranslation) > abs(predictedVerticalTranslation) * 1.1,
          abs(predictedHorizontalTranslation) > 58
    else { return nil }

    return predictedHorizontalTranslation < 0 ? 1 : -1
  }
}

/// Direction gate for row-local horizontal actions that live inside a vertical
/// drawer scroll view. Returning `false` from the UIKit recognizer delegate
/// before recognition lets the enclosing scroll view own the complete touch.
public enum HorizontalRowSwipeGestureArbitration {
  public static func shouldBegin(
    horizontalVelocity: Double,
    verticalVelocity: Double
  ) -> Bool {
    abs(horizontalVelocity) > abs(verticalVelocity) * 1.15
  }
}

/// The single owner selected for one vertical touch sequence inside a drawer.
/// Ownership never changes until the finger lifts, preventing a scroll from
/// turning into a drawer drag (or vice versa) partway through the gesture.
public enum DrawerPanOwner: Equatable, Sendable {
  case drawer
  case content
  case ignored
}

public enum DrawerGestureArbitration {
  public static let topTolerance = 1.5
  public static let velocityThreshold = 520.0
  public static let distanceFraction = 0.28

  /// Selects exactly one owner from the gesture's initial velocity and the
  /// content position at touch start.
  public static func owner(
    isExpanded: Bool,
    contentOffset: Double,
    topOffset: Double,
    horizontalVelocity: Double,
    verticalVelocity: Double
  ) -> DrawerPanOwner {
    guard abs(verticalVelocity) > abs(horizontalVelocity) else { return .ignored }

    if isExpanded {
      let contentIsAtTop = contentOffset <= topOffset + topTolerance
      return contentIsAtTop && verticalVelocity > 0 ? .drawer : .content
    }

    return verticalVelocity < 0 ? .drawer : .ignored
  }

  /// Resolves the destination detent using both intentional travel and a fast
  /// flick. The decision is symmetric in both directions and never depends on
  /// an intermediate content offset.
  public static func targetIsExpanded(
    startedExpanded: Bool,
    translation: Double,
    verticalVelocity: Double,
    detentTravel: Double
  ) -> Bool {
    let distanceThreshold = max(44, detentTravel * distanceFraction)

    if startedExpanded {
      let shouldCollapse = translation > distanceThreshold
        || verticalVelocity > velocityThreshold
      return !shouldCollapse
    }

    return translation < -distanceThreshold
      || verticalVelocity < -velocityThreshold
  }
}
