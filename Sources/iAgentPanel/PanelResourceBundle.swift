import Foundation

enum PanelResourceBundle {
  private static let packagedBundleName = "iAgentPanel_iAgentPanel.bundle"

  static let bundle: Bundle = {
    if let resourcesURL = Bundle.main.resourceURL,
       let packagedBundle = Bundle(
         url: resourcesURL.appendingPathComponent(packagedBundleName, isDirectory: true)
       ) {
      return packagedBundle
    }

    // Direct SwiftPM runs keep resources beside the build products. Access this
    // generated fallback lazily so packaged apps never depend on the checkout.
    return Bundle.module
  }()
}
