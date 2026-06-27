import SwiftUI
import UIKit
import UserNotifications

@main
struct CarIOSSwiftUIApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = AppStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .onAppear {
                    appDelegate.store = store
                    store.start()
                    store.sendDeviceTokenOverBle()
                }
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    weak var store: AppStore? {
        didSet {
            openMessagesIfNeeded()
        }
    }
    private var shouldOpenMessages = false

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        application.isIdleTimerDisabled = true
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .badge, .sound]) { granted, error in
            DispatchQueue.main.async {
                self.store?.notificationAuthorization = granted ? "Granted" : "Denied"
                if let error {
                    self.store?.lastError = error.localizedDescription
                }
            }
        }
        application.registerForRemoteNotifications()
        return true
    }

    func applicationWillEnterForeground(_ application: UIApplication) {
        store?.enterForeground()
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        store?.enterBackground()
    }

    func applicationWillTerminate(_ application: UIApplication) {
        store?.enterBackground()
    }

    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String, completionHandler: @escaping () -> Void) {
        completionHandler()
    }

    func application(_ application: UIApplication, performFetchWithCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        completionHandler(.noData)
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02.2hhx", $0) }.joined()
        UserDefaults.standard.set(token, forKey: AppStorageKeys.deviceToken)
        DispatchQueue.main.async {
            self.store?.deviceToken = token
            self.store?.registerDeviceTokenWithServer()
            self.store?.sendDeviceTokenOverBle()
        }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        DispatchQueue.main.async {
            self.store?.lastError = error.localizedDescription
        }
    }

    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any], fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        store?.addMessage(from: userInfo, state: .received, actionId: "background")
        completionHandler(.newData)
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        store?.addMessage(from: notification.request.content, id: notification.request.identifier, state: .willPresent, actionId: "*")
        completionHandler([.banner, .list, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let request = response.notification.request
        store?.addMessage(from: request.content, id: request.identifier, state: .received, actionId: response.actionIdentifier)
        openMessagesFromNotification()
        completionHandler()
    }

    private func openMessagesFromNotification() {
        shouldOpenMessages = true
        DispatchQueue.main.async {
            self.openMessagesIfNeeded()
        }
    }

    private func openMessagesIfNeeded() {
        guard shouldOpenMessages, let store else { return }
        shouldOpenMessages = false
        store.openMessages()
    }
}
