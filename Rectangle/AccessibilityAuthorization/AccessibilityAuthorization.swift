/// AccessibilityAuthorization.swift

import Foundation
import Cocoa

class AccessibilityAuthorization {
    
    private var accessibilityWindowController: NSWindowController?
    
    public func checkAccessibility(completion: @escaping () -> Void) -> Bool {
        // Ask with the prompt option rather than a bare AXIsProcessTrusted().
        // The bare check only reads the current answer; it is the prompting
        // variant that makes macOS register the app in System Settings ▸
        // Privacy & Security ▸ Accessibility. Without it the list stays empty,
        // and a first-time user has to find the + button and navigate to the
        // bundle themselves - which also means a grant can end up bound to
        // some other copy of the app, leaving AXIsProcessTrusted() true while
        // every real AX call is denied.
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        if !AXIsProcessTrustedWithOptions(options as CFDictionary) {

            accessibilityWindowController = NSStoryboard(name: "Main", bundle: nil).instantiateController(withIdentifier: "AccessibilityWindowController") as? NSWindowController

            NSApp.activate(ignoringOtherApps: true)
            accessibilityWindowController?.showWindow(self)
            pollAccessibility(completion: completion)
            return false
        } else {
            return true
        }
    }
    
    private func pollAccessibility(completion: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            if AXIsProcessTrusted() {
                self.accessibilityWindowController?.close()
                self.accessibilityWindowController = nil
                completion()
            } else {
                self.pollAccessibility(completion: completion)
            }
        }
    }
    
    func showAuthorizationWindow() {
        if accessibilityWindowController?.window?.isMiniaturized == true {
            accessibilityWindowController?.window?.deminiaturize(self)
        }
        NSApp.activate(ignoringOtherApps: true)
    }
    
}
