import SwiftUI
import UIKit
import UserNotifications

@main
/** Bootstraps the SwiftUI application and shared app store. */
struct CarIOSSwiftUIApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    /** Stores the store value. */
    @StateObject private var store = AppStore()

    /** Builds the SwiftUI view hierarchy for this view or scene. */
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

/** Bridges UIKit lifecycle, remote notifications, and foreground/background events into the SwiftUI store. */
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    /** Stores the store value. */
    weak var store: AppStore? {
        didSet {
            flushPendingMessages()
            openMessagesIfNeeded()
        }
    }
    /** Stores the should open messages value. */
    private var shouldOpenMessages = false
    /** Stores notification messages received before SwiftUI attaches the store. */
    private var pendingMessages: [PushMessage] = []

    /** Handles UIKit application lifecycle and notification delegate callbacks. */
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

    /** Notifies the store that the app is returning to the foreground. */
    func applicationWillEnterForeground(_ application: UIApplication) {
        store?.enterForeground()
    }

    /** Notifies the store that the app moved to the background. */
    func applicationDidEnterBackground(_ application: UIApplication) {
        store?.enterBackground()
    }

    /** Stops foreground communication before application termination. */
    func applicationWillTerminate(_ application: UIApplication) {
        store?.enterBackground()
    }

    /** Handles UIKit application lifecycle and notification delegate callbacks. */
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String, completionHandler: @escaping () -> Void) {
        completionHandler()
    }

    /** Handles UIKit application lifecycle and notification delegate callbacks. */
    func application(_ application: UIApplication, performFetchWithCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        completionHandler(.noData)
    }

    /** Handles UIKit application lifecycle and notification delegate callbacks. */
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02.2hhx", $0) }.joined()
        UserDefaults.standard.set(token, forKey: AppStorageKeys.deviceToken)
        DispatchQueue.main.async {
            self.store?.deviceToken = token
            self.store?.registerDeviceTokenWithServer()
            self.store?.sendDeviceTokenOverBle()
        }
    }

    /** Handles UIKit application lifecycle and notification delegate callbacks. */
    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        DispatchQueue.main.async {
            self.store?.lastError = error.localizedDescription
        }
    }

    /** Handles UIKit application lifecycle and notification delegate callbacks. */
    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any], fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        let message = PushMessage(id: UUID().uuidString, userInfo: userInfo, state: .received, actionId: "background")
        addMessage(message)
        completionHandler(.newData)
    }

    /** Handles foreground presentation and user interaction for notifications. */
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        let message = PushMessage(id: notification.request.identifier, content: notification.request.content, state: .willPresent, actionId: "*")
        addMessage(message)
        completionHandler([.banner, .list, .sound])
    }

    /** Handles foreground presentation and user interaction for notifications. */
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let request = response.notification.request
        let message = PushMessage(id: request.identifier, content: request.content, state: .received, actionId: response.actionIdentifier)
        addMessage(message)
        openMessagesFromNotification()
        completionHandler()
    }

    /** Adds the message immediately or defers it until the SwiftUI store is available. */
    private func addMessage(_ message: PushMessage) {
        guard let store else {
            pendingMessages.removeAll { $0.id == message.id }
            pendingMessages.insert(message, at: 0)
            return
        }
        store.addMessage(message)
    }

    /** Persists notification messages that arrived during cold launch before the store existed. */
    private func flushPendingMessages() {
        guard let store, !pendingMessages.isEmpty else { return }
        let messages = pendingMessages.reversed()
        pendingMessages.removeAll()
        messages.forEach { store.addMessage($0) }
    }

    /** Schedules navigation to messages after notification interaction. */
    private func openMessagesFromNotification() {
        shouldOpenMessages = true
        DispatchQueue.main.async {
            self.openMessagesIfNeeded()
        }
    }

    /** Consumes the pending message-navigation flag when the store is available. */
    private func openMessagesIfNeeded() {
        guard shouldOpenMessages, let store else { return }
        shouldOpenMessages = false
        store.openMessages()
    }
}
