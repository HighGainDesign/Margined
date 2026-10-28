import SwiftUI
import UIKit

struct MobileDiscussionSharingView: UIViewControllerRepresentable {
    let reader: MobileReaderState
    let share: MobileDiscussionShare
    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItemsConfiguration: share.configuration)
        controller.modalPresentationStyle = .pageSheet
        let shareID = share.id
        controller.completionWithItemsHandler = { [weak reader] _, _, _, _ in
            DispatchQueue.main.async { reader?.finishDiscussionShare(shareID) }
        }
        return controller
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
