//
//  TransferRequestHandler.swift
//

import UIKit
import MultipeerConnectivity

enum TransferRequestHandler {

    static func askToReceive(
        fileName: String,
        fileType: TransferItem.FileType,
        from peer: MCPeerID,
        presentingViewController: UIViewController,
        openShareAfterAccept: (() -> Void)? = nil,
        handler: @escaping (Bool) -> Void
    ) {
        if fileType == .map && mapAlreadyExists(fileName: fileName) {
            askToReplaceExistingMap(
                fileName: fileName,
                from: peer,
                presentingViewController: presentingViewController,
                openShareAfterAccept: openShareAfterAccept,
                handler: handler
            )
            return
        }

        showNormalReceiveAlert(
            fileName: fileName,
            from: peer,
            presentingViewController: presentingViewController,
            openShareAfterAccept: openShareAfterAccept,
            handler: handler
        )
    }

    private static func mapAlreadyExists(fileName: String) -> Bool {
        let docs = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        )[0]

        let existingURL = docs
            .appendingPathComponent("OG_MapsFolder")
            .appendingPathComponent(fileName)

        return FileManager.default.fileExists(atPath: existingURL.path)
    }

    private static func askToReplaceExistingMap(
        fileName: String,
        from peer: MCPeerID,
        presentingViewController: UIViewController,
        openShareAfterAccept: (() -> Void)?,
        handler: @escaping (Bool) -> Void
    ) {
        let alert = UIAlertController(
            title: "Map Already Exists",
            message: "\(fileName) already exists.\nReplace it with the map from \(peer.displayName)?",
            preferredStyle: .alert
        )

        alert.addAction(UIAlertAction(title: "Decline", style: .cancel) { _ in
            handler(false)
        })

        alert.addAction(UIAlertAction(title: "Replace", style: .destructive) { _ in
            handler(true)
            openShareAfterAccept?()
        })

        presentingViewController.present(alert, animated: true)
    }

    private static func showNormalReceiveAlert(
        fileName: String,
        from peer: MCPeerID,
        presentingViewController: UIViewController,
        openShareAfterAccept: (() -> Void)?,
        handler: @escaping (Bool) -> Void
    ) {
        let alert = UIAlertController(
            title: "Incoming Transfer",
            message: "\(peer.displayName) wants to send \(fileName)",
            preferredStyle: .alert
        )

        var countdown = 30
        var timer: Timer?

        let acceptAction = UIAlertAction(title: "Accept (30)", style: .default) { _ in
            timer?.invalidate()
            handler(true)
            openShareAfterAccept?()
        }

        let declineAction = UIAlertAction(title: "Decline", style: .cancel) { _ in
            timer?.invalidate()
            handler(false)
        }

        alert.addAction(declineAction)
        alert.addAction(acceptAction)

        presentingViewController.present(alert, animated: true) {
            timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { t in
                countdown -= 1

                if countdown <= 0 {
                    t.invalidate()
                    alert.dismiss(animated: true) {
                        handler(false)
                    }
                } else {
                    acceptAction.setValue("Accept (\(countdown))", forKey: "title")
                }
            }
        }
    }
}
