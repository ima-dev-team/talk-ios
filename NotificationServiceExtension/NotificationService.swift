//
// SPDX-FileCopyrightText: 2020 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-3.0-or-later
//

import UIKit
import UserNotifications
import SDWebImage

class NotificationService: UNNotificationServiceExtension {

    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var bestAttemptContent: UNMutableNotificationContent?
    private var sendMessageIntent: INSendMessageIntent?

    // TODO: We should share this for all extensions
    private func configureDatabase() -> Bool {
        // Configure database
        guard let containerBase = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupIdentifier) else {
            return false
        }

        let databaseUrl = containerBase.appending(path: kTalkDatabaseFolder, directoryHint: .isDirectory).appending(path: kTalkDatabaseFileName, directoryHint: .notDirectory)

        guard !FileManager.default.fileExists(atPath: databaseUrl.path()) else {
            print("Database does not exist -> main app needs to run before extension")

            return false
        }

        var currentSchemaVersion: UInt64 = 0

        // schemaVersionAtURL throws an exception when file is not readable
        do {
            currentSchemaVersion = try RLMRealm.schemaVersion(at: databaseUrl)
        } catch {
            print("Reading schemaVersion failed: \(error.localizedDescription)")

            return false
        }

        if currentSchemaVersion != kTalkDatabaseSchemaVersion {
            print("Current schemaVersion is \(currentSchemaVersion), app schemaVersion is \(kTalkDatabaseSchemaVersion)")
            print("Database needs migration -> don't open database from extension")

            return false
        }

        let configuration = RLMRealmConfiguration.default()
        configuration.fileURL = databaseUrl
        configuration.schemaVersion = kTalkDatabaseSchemaVersion
        configuration.objectClasses = [TalkAccount.self, NCRoom.self, ServerCapabilities.self, FederatedCapabilities.self]
        RLMRealmConfiguration.setDefault(configuration)

        return true
    }

    // swiftlint:disable:next cyclomatic_complexity
    override func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        self.contentHandler = contentHandler
        self.bestAttemptContent = request.content.mutableCopy() as? UNMutableNotificationContent

        self.bestAttemptContent?.title = ""
        self.bestAttemptContent?.body = NSLocalizedString("You received a new notification", comment: "")

        guard self.configureDatabase() else {
            // Without a working database, nothing left to do here
            self.showBestAttemptNotification()
            return
        }

        // We don't want to use a memory cache in NSE, because we only have a total of 24MB before we get killed by the OS
        SDImageCache.shared.config.shouldCacheImagesInMemory = false

        let message = self.bestAttemptContent?.userInfo["subject"] as? String
        let signature = self.bestAttemptContent?.userInfo["signature"] as? String

        guard let message, let signature else {
            // Without a message or signature there's nothing left to do here
            self.showBestAttemptNotification()
            return
        }

        var pushNotification: NCPushNotification?
        var account: TalkAccount?

        for case let talkAccount as TalkAccount in TalkAccount.allObjects() {
            let decryptedMessage = NCPushNotificationsUtils.decryptPushNotification(withMessageBase64: message, withSignatureBase64: signature, forAccount: talkAccount)

            if let decryptedMessage {
                pushNotification = NCPushNotification(fromDecryptedString: decryptedMessage, withAccountId: talkAccount.accountId)
                account = TalkAccount(value: talkAccount)

                break
            }
        }

        guard let pushNotification, let account else {
            // At this point we tried everything to decrypt the received message
            // No need to wait for the extension timeout, nothing is happening anymore

            self.showBestAttemptNotification()
            return
        }

        if pushNotification.type == .NCPushNotificationTypeAdminNotification {
            // Test notification send through "occ notification:test-push --talk <userid>"
            // No need to increase the badge or query the server about it

            self.bestAttemptContent?.body = pushNotification.subject
            self.showBestAttemptNotification()
            return
        }

        if pushNotification.type == .NCPushNotificationTypeDelete
            || pushNotification.type == .NCPushNotificationTypeDeleteAll
            || pushNotification.type == .NCPushNotificationTypeDeleteMultiple {
            // The server sends this to tell us that one or more notifications are no longer
            // valid (e.g. the message was already read, possibly from this same device).
            // It never carries a subject, so - unlike every other type - it must not increase
            // the unread badge or produce a "new message" alert. Falling through to the
            // generic handling below used to increase the badge instead of decreasing it and
            // show a blank notification for every one of these.
            self.handleDeleteNotification(pushNotification, forAccount: account)
            return
        }

        // TODO: Can we just use the managed object we already had before?
        try? RLMRealm.default().transaction {
            let query = NSPredicate(format: "accountId = %@", account.accountId)

            // Update unread notifications counter for push notification account
            if let managedAccount = TalkAccount.objects(with: query).firstObject() as? TalkAccount {
                managedAccount.unreadBadgeNumber += 1
                managedAccount.unreadNotification = (managedAccount.active) ? false : true
            }
        }

        // Get the total number of unread notifications
        let unreadNotifications = NCDatabaseManager.sharedInstance().numberOfUnreadNotifications()

        self.bestAttemptContent?.body = pushNotification.bodyForRemoteAlerts()
        self.bestAttemptContent?.threadIdentifier = pushNotification.roomToken
        self.bestAttemptContent?.sound = .default
        self.bestAttemptContent?.badge = unreadNotifications as NSNumber

        if pushNotification.type == .NCPushNotificationTypeChat {
            // Set category for chat messages to allow interactive notifications
            self.bestAttemptContent?.categoryIdentifier = "CATEGORY_CHAT"
        }

        var userInfo: [String: Any] = [
            "pushNotification": pushNotification.jsonString,
            "accountId": pushNotification.accountId,
            "notificationId": pushNotification.notificationId
        ]

        self.bestAttemptContent?.userInfo = userInfo

        // Create title and body structure if there is a new line in the subject
        let components = pushNotification.subject.split(whereSeparator: \.isNewline)
        if components.count > 1 {
            self.bestAttemptContent?.title = String(components[0])
            self.bestAttemptContent?.body = components.dropFirst().joined(separator: "\n")
        }

        NCAPIController.shared.getServerNotification(withId: pushNotification.notificationId, forAccount: account) { serverNotification, dataDict, error in
            guard let serverNotification, let dataDict, error == nil else {
                // Even if the server request fails, we should try to create a conversation notifications
                self.createAndShowConversationNotification(withPushNotification: pushNotification)
                return
            }

            // Add the serverNotification as userInfo as well -> this can later be used to access the actions directly
            userInfo["serverNotification"] = dataDict
            self.bestAttemptContent?.userInfo = userInfo

            switch serverNotification.notificationType {
            case .chat:
                self.handleChatNotification(withServerNotification: serverNotification, withPushNotification: pushNotification, forAccount: account)
            case .recording:
                self.handleRecordingNotification(withServerNotification: serverNotification, withPushNotification: pushNotification, forAccount: account)
            case .federation:
                self.handleFederationNotification(withServerNotification: serverNotification, withPushNotification: pushNotification, forAccount: account)
            default:
                self.showBestAttemptNotification()
            }
        }
    }

    private func handleDeleteNotification(_ pushNotification: NCPushNotification, forAccount account: TalkAccount) {
        var notificationIdsToRemove: [Int] = []

        switch pushNotification.type {
        case .NCPushNotificationTypeDelete:
            notificationIdsToRemove = [pushNotification.notificationId]
        case .NCPushNotificationTypeDeleteMultiple:
            notificationIdsToRemove = (pushNotification.notificationIds as? [NSNumber])?.map { $0.intValue } ?? []
        default:
            // .NCPushNotificationTypeDeleteAll -> no specific ids, everything for this account goes
            break
        }

        // Bring the badge back down for the notification(s) this push refers to, instead of the
        // generic "+= 1" every other push type gets.
        try? RLMRealm.default().transaction {
            let query = NSPredicate(format: "accountId = %@", account.accountId)
            guard let managedAccount = TalkAccount.objects(with: query).firstObject() as? TalkAccount else { return }

            if pushNotification.type == .NCPushNotificationTypeDeleteAll {
                managedAccount.unreadBadgeNumber = 0
            } else {
                let removedCount = max(notificationIdsToRemove.count, 1)
                managedAccount.unreadBadgeNumber = max(managedAccount.unreadBadgeNumber - removedCount, 0)
            }

            managedAccount.unreadNotification = managedAccount.unreadBadgeNumber > 0
        }

        let updatedBadgeCount = NCDatabaseManager.sharedInstance().numberOfUnreadNotifications()
        let accountId = account.accountId
        let deleteType = pushNotification.type

        // Also remove the stale delivered notification(s) from the system notification center,
        // so they don't linger there after the badge already went down.
        let notificationCenter = UNUserNotificationCenter.current()
        notificationCenter.getDeliveredNotifications { notifications in
            let identifiersToRemove = notifications.filter { notification in
                guard let notificationAccountId = notification.request.content.userInfo["accountId"] as? String,
                      notificationAccountId == accountId else { return false }

                if deleteType == .NCPushNotificationTypeDeleteAll {
                    return true
                }

                guard let notificationId = notification.request.content.userInfo["notificationId"] as? Int else { return false }
                return notificationIdsToRemove.contains(notificationId)
            }.map { $0.request.identifier }

            if !identifiersToRemove.isEmpty {
                notificationCenter.removeDeliveredNotifications(withIdentifiers: identifiersToRemove)
            }

            // Don't turn this into a visible "new message" alert: keep the generic, non-empty
            // placeholder that was already set at the top of didReceive, just silence it and
            // sync the badge to the corrected value.
            self.bestAttemptContent?.sound = nil
            self.bestAttemptContent?.badge = updatedBadgeCount as NSNumber

            if #available(iOS 15.0, *) {
                self.bestAttemptContent?.interruptionLevel = .passive
            }

            self.showBestAttemptNotification()
        }
    }

    private func handleChatNotification(withServerNotification serverNotification: NCNotification, withPushNotification pushNotification: NCPushNotification, forAccount account: TalkAccount) {
        // Only try to adjust the title/body if there are rich parameters
        // E.g. for sensitive conversations, there are none, so we use the server provided title/body
        if !serverNotification.subjectRichParameters.isEmpty {
            let attributedMessage = NSAttributedString(string: serverNotification.message)
            let markdownMessage = SwiftMarkdownObjCBridge.parseMarkdown(markdownString: attributedMessage)

            self.bestAttemptContent?.title = serverNotification.chatMessageTitle
            self.bestAttemptContent?.body = markdownMessage.string
        }

        guard let fileDict = serverNotification.messageRichParameters["file"] as? [String: Any],
              let file = NCMessageFileParameter(dictionary: fileDict), file.previewAvailable else {

            // No file/no preview -> show notification
            self.createAndShowConversationNotification(withPushNotification: pushNotification)
            return
        }

        // First try to create the conversation notification, and only afterwards try to retrieve the image preview
        self.createConversationNotification(withPushNotification: pushNotification) {
            SDWebImageDownloader.shared.config.downloadTimeout = 25.0
            NCAPIController.shared.getPreviewForFile(file.parameterId, width: 0, height: 512, forAccount: account) { image, _ in
                if let image, let attachment = self.getNotificationAttachment(fromImage: image, forAccountId: account.accountId) {
                    self.bestAttemptContent?.attachments = [attachment]
                }

                self.showBestAttemptNotification()
            }
        }
    }

    private func handleRecordingNotification(withServerNotification serverNotification: NCNotification, withPushNotification pushNotification: NCPushNotification, forAccount account: TalkAccount) {
        self.bestAttemptContent?.categoryIdentifier = "CATEGORY_RECORDING"
        self.bestAttemptContent?.title = serverNotification.subject
        self.bestAttemptContent?.body = serverNotification.message

        self.createAndShowConversationNotification(withPushNotification: pushNotification)
    }

    private func handleFederationNotification(withServerNotification serverNotification: NCNotification, withPushNotification pushNotification: NCPushNotification, forAccount account: TalkAccount) {
        self.bestAttemptContent?.categoryIdentifier = "CATEGORY_FEDERATION"
        self.bestAttemptContent?.title = serverNotification.subject
        self.bestAttemptContent?.body = serverNotification.message

        NCDatabaseManager.sharedInstance().increasePendingFederationInvitation(forAccountId: account.accountId)
        self.createAndShowConversationNotification(withPushNotification: pushNotification)
    }

    private func createConversationNotification(withPushNotification pushNotification: NCPushNotification, withCompletionBlock completionBlock: @escaping () -> Void) {
        if let bestAttemptContent = self.bestAttemptContent, let room = NCDatabaseManager.sharedInstance().room(withToken: pushNotification.roomToken, forAccountId: pushNotification.accountId) {
            NCIntentController.sharedInstance().getInteractionFor(room, withTitle: bestAttemptContent.title) { sendMessageIntent in
                self.sendMessageIntent = sendMessageIntent
                completionBlock()
            }
        } else {
            completionBlock()
        }
    }

    private func createAndShowConversationNotification(withPushNotification pushNotification: NCPushNotification) {
        self.createConversationNotification(withPushNotification: pushNotification) {
            self.showBestAttemptNotification()
        }
    }

    private func showBestAttemptNotification() {
        guard let bestAttemptContent = self.bestAttemptContent else { return }

        // When we have a send message intent, we use it, otherwise we fall back to the non-conversation-notification one
        if let sendMessageIntent = self.sendMessageIntent, let updatedContent = try? bestAttemptContent.updating(from: sendMessageIntent) {
            self.contentHandler?(updatedContent)
        } else {
            self.contentHandler?(bestAttemptContent)
        }
    }

    private func getNotificationAttachment(fromImage image: UIImage, forAccountId accountId: String) -> UNNotificationAttachment? {
        guard let encodedAccountId = accountId.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed)
        else { return nil }

        let tempDirectoryPath = FileManager.default.temporaryDirectory.appending(path: "/download/").appending(path: encodedAccountId)

        // Make sure our download directory exists
        try? FileManager.default.createDirectory(at: tempDirectoryPath, withIntermediateDirectories: true)

        let fileName = "NotificationPreview_\(UUID().uuidString).jpg"
        let fileUrl = tempDirectoryPath.appending(path: fileName)

        // Write the received image to the temporary directory and create the corresponding attachment object
        if (try? image.jpegData(compressionQuality: 1.0)?.write(to: fileUrl, options: .atomic)) != nil {
            if let attachment = try? UNNotificationAttachment(identifier: fileName, url: fileUrl) {
                return attachment
            }
        }

        return nil
    }

    override func serviceExtensionTimeWillExpire() {
        // Called just before the extension will be terminated by the system.
        // Use this as an opportunity to deliver your "best attempt" at modified content, otherwise the original push payload will be used.
        self.showBestAttemptNotification()
    }

}
