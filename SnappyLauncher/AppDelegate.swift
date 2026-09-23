/// AppDelegate.swift

import Cocoa

@NSApplicationMain
class AppDelegate: NSObject, NSApplicationDelegate {

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        if #available(macOS 13, *) {
            terminate()
            return
        }
        // The helper's own identifier is the app's with ".Launcher" appended,
        // so a development helper launches the development app.
        let mainAppIdentifier = (Bundle.main.bundleIdentifier ?? "com.simarholonipaa.snappy.Launcher")
            .replacingOccurrences(of: ".Launcher", with: "")
        let running = NSWorkspace.shared.runningApplications
        let isRunning = !running.filter({$0.bundleIdentifier == mainAppIdentifier}).isEmpty
        
        if isRunning {
            self.terminate()
        } else {
            let killNotification = Notification.Name("killLauncher")
            DistributedNotificationCenter.default().addObserver(self,
                                                                selector: #selector(self.terminate),
                                                                name: killNotification,
                                                                object: mainAppIdentifier)
            let path = Bundle.main.bundlePath as NSString
            var components = path.pathComponents
            components.removeLast()
            components.removeLast()
            components.removeLast()
            components.append("MacOS")
            components.append("Snappy")
            let newPath = NSString.path(withComponents: components)
            NSWorkspace.shared.launchApplication(newPath)
        }
    }
    
    @objc func terminate() {
        NSApp.terminate(nil)
    }

}

