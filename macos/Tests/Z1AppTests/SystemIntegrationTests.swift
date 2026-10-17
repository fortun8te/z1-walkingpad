import Foundation
import Testing
import UserNotifications
@testable import Z1App

@MainActor
private final class NotificationFixture {
    var available = true
    var status: UNAuthorizationStatus = .denied
    var requestFails = false
    var submissionFails = false
    var requests = 0
    var submissions = 0
    var authorizationReads = 0

    func notifier() -> Notifier {
        Notifier(isAvailable: { self.available }, authorizationStatus: {
            self.authorizationReads += 1
            return self.status
        }, requestAuthorization: {
            self.requests += 1
            if self.requestFails { throw NSError(domain: "NotificationTests", code: 1) }
            self.status = .authorized
            return true
        }, submit: { _ in
            self.submissions += 1
            if self.submissionFails { throw NSError(domain: "NotificationTests", code: 2) }
        })
    }
}

@Suite(.serialized)
@MainActor
struct SystemIntegrationTests {
    @Test func notificationDeliveryReflectsExternalPermissionChanges() async {
        let fixture = NotificationFixture()
        let notifier = fixture.notifier()
        #expect(await !notifier.post(title: "Test", body: "Test", identifier: "denied"))
        #expect(fixture.submissions == 0)
        fixture.status = .authorized
        #expect(await notifier.post(title: "Test", body: "Test", identifier: "allowed"))
        #expect(fixture.submissions == 1)
        fixture.status = .denied
        #expect(await !notifier.post(title: "Test", body: "Test", identifier: "revoked"))
        #expect(fixture.submissions == 1)
        #expect(!notifier.authorized)
    }

    @Test func rejectedNotificationIsNotReportedAsAccepted() async {
        let fixture = NotificationFixture()
        fixture.status = .authorized
        fixture.submissionFails = true
        let notifier = fixture.notifier()
        #expect(await !notifier.post(title: "Test", body: "Test", identifier: "failed"))
        fixture.submissionFails = false
        #expect(await notifier.post(title: "Test", body: "Test", identifier: "retry"))
        #expect(fixture.submissions == 2)
    }

    @Test func unavailableNotificationCenterIsNeverAccessed() async {
        let fixture = NotificationFixture()
        fixture.available = false
        let notifier = fixture.notifier()
        await notifier.requestAuthorizationIfNeeded()
        #expect(await !notifier.post(title: "Test", body: "Test", identifier: "unavailable"))
        #expect(fixture.authorizationReads == 0)
        #expect(fixture.requests == 0)
        #expect(fixture.submissions == 0)
    }

    @Test func transientAuthorizationFailureCanBeRetriedWithoutDuplicateSuccessfulRequests() async {
        let fixture = NotificationFixture()
        fixture.requestFails = true
        let notifier = fixture.notifier()
        await notifier.requestAuthorizationIfNeeded()
        #expect(!notifier.authorized)
        fixture.requestFails = false
        await notifier.requestAuthorizationIfNeeded()
        #expect(notifier.authorized)
        await notifier.requestAuthorizationIfNeeded()
        #expect(fixture.requests == 2)
    }
}
