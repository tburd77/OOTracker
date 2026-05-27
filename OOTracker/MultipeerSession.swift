//
//  Fellow.swift
//  OOTracker
//
//  Created by Terry Burdett on 5/18/26.
//


//  MultipeerSession.swift
//  OTracker

import Foundation
import MultipeerConnectivity

// MARK: - Models

struct Fellow_User: Equatable {
    let peerID: MCPeerID
    var state: ConnectionState

    enum ConnectionState {
        case discovered
        case connecting
        case connected
    }

    static func == (lhs: Fellow_User, rhs: Fellow_User) -> Bool {
        lhs.peerID == rhs.peerID
    }
}

struct TransferItem {
    let name: String
    let url: URL
    let type: FileType
    var receivedFrom: String? = nil
    var hasMatchingOGT: Bool = false

    enum FileType {
        case map
        case data
    }
}

// MARK: - Delegate

protocol MultipeerSessionDelegate: AnyObject {
    func fellowUsersDidChange(_ users: [Fellow_User])
    func didReceiveTransferRequest(fileName: String, fileType: TransferItem.FileType,
                                   from peer: MCPeerID, handler: @escaping (Bool) -> Void)
    func transferProgress(_ progress: Progress, fileName: String, from peer: MCPeerID)
    func transferComplete(item: TransferItem, from peer: MCPeerID)
    func transferFailed(fileName: String, from peer: MCPeerID, error: Error?)
    func didReceiveConfirmation(fileName: String, from peer: MCPeerID)
    func peerDidDisconnect(_ peer: MCPeerID)
}

// MARK: - MultipeerSession

class MultipeerSession: NSObject {

    // MARK: - Constants
    static let serviceType = "otracker-p2p"
    static let inviteTimeout: TimeInterval = 30

    // MARK: - Properties
    let localPeer: MCPeerID
    private let session: MCSession
    private var advertiser: MCNearbyServiceAdvertiser?
    private var browser: MCNearbyServiceBrowser?
    weak var delegate: MultipeerSessionDelegate?
    private(set) var incomingMapsWithData = Set<String>()

    private struct PendingOutgoingTransfer {
        let items: [TransferItem]
        let peer: MCPeerID
    }

    private var pendingOutgoingTransfers: [String: PendingOutgoingTransfer] = [:]

    private(set) var fellowUsers: [Fellow_User] = [] {
        didSet { delegate?.fellowUsersDidChange(fellowUsers) }
    }

    // MARK: - Init

    init(displayName: String = UIDevice.current.name) {
        localPeer = MCPeerID(displayName: displayName)
        session = MCSession(peer: localPeer,
                           securityIdentity: nil,
                           encryptionPreference: .required)
        
        super.init()
        
        NotificationCenter.default.addObserver(
                self,
                selector: #selector(handleAppBackground),
                name: .appDidEnterBackground,
                object: nil
            )
        
        session.delegate = self
    }

    // MARK: - Start / Stop

    func start() {
        startAdvertising()
        startBrowsing()
    }

    func stop() {
        stopAdvertising()
        stopBrowsing()
        session.disconnect()
        fellowUsers.removeAll()
    }

    @objc private func handleAppBackground() {
        session.disconnect()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    private func startAdvertising() {
        advertiser = MCNearbyServiceAdvertiser(
            peer: localPeer,
            discoveryInfo: ["app": "otracker"],
            serviceType: MultipeerSession.serviceType
        )
        advertiser?.delegate = self
        advertiser?.startAdvertisingPeer()
    }

    private func stopAdvertising() {
        advertiser?.stopAdvertisingPeer()
        advertiser = nil
    }

    private func startBrowsing() {
        browser = MCNearbyServiceBrowser(
            peer: localPeer,
            serviceType: MultipeerSession.serviceType
        )
        browser?.delegate = self
        browser?.startBrowsingForPeers()
    }

    private func stopBrowsing() {
        browser?.stopBrowsingForPeers()
        browser = nil
    }

    // MARK: - Connection

    func connect(to peer: MCPeerID) {
        updateUser(peer, state: .connecting)
        browser?.invitePeer(peer,
                           to: session,
                           withContext: nil,
                           timeout: MultipeerSession.inviteTimeout)
    }

    func isConnected(to peer: MCPeerID) -> Bool {
        session.connectedPeers.contains(peer)
    }

    // MARK: - Transfer

    func sendMapAndMatchingDataIfAvailable(_ item: TransferItem, to peer: MCPeerID) {
        guard item.type == .map else {
            requestPermissionToSend(items: [item], displayItem: item, to: peer)
            return
        }

        let docs = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        )[0]

        let dataName = item.url
            .deletingPathExtension()
            .lastPathComponent + ".ogt"

        let dataURL = docs
            .appendingPathComponent("OG_DataFolder")
            .appendingPathComponent(dataName)

        if FileManager.default.fileExists(atPath: dataURL.path) {
            let dataItem = TransferItem(
                name: dataName,
                url: dataURL,
                type: .data
            )

            // If matching .ogt exists, request permission once,
            // then send data first and map second after receiver accepts.
            requestPermissionToSend(
                items: [dataItem, item],
                displayItem: item,
                to: peer
            )
        } else {
            // No matching .ogt exists, send only map after receiver accepts.
            requestPermissionToSend(
                items: [item],
                displayItem: item,
                to: peer
            )
        }
    }
    
    private func requestPermissionToSend(
        items: [TransferItem],
        displayItem: TransferItem,
        to peer: MCPeerID
    ) {
        let transferID = UUID().uuidString

        pendingOutgoingTransfers[transferID] = PendingOutgoingTransfer(
            items: items,
            peer: peer
        )

        let typeText = displayItem.type == .map ? "map" : "data"
        let hasDataText = items.contains(where: { $0.type == .data }) ? "1" : "0"

        // REQUEST only. Do not call sendResource until ACCEPT is received.
        let meta = "REQUEST:\(transferID):\(displayItem.name):\(typeText):\(hasDataText)"

        guard let data = meta.data(using: .utf8) else { return }

        do {
            try session.send(data, toPeers: [peer], with: .reliable)
        } catch {
            DispatchQueue.main.async {
                self.delegate?.transferFailed(
                    fileName: displayItem.name,
                    from: peer,
                    error: error
                )
            }
            pendingOutgoingTransfers.removeValue(forKey: transferID)
        }
    }

    private func sendAcceptedTransfer(_ transfer: PendingOutgoingTransfer) {
        for item in transfer.items {
            sendFile(item, to: transfer.peer)
        }
    }

    private func sendFile(_ item: TransferItem, to peer: MCPeerID) {
        let progress = session.sendResource(
            at: item.url,
            withName: item.name,
            toPeer: peer
        ) { [weak self] error in
            DispatchQueue.main.async {
                if let error = error {
                    self?.delegate?.transferFailed(
                        fileName: item.name,
                        from: peer,
                        error: error
                    )
                }
            }
        }

        if let progress = progress {
            observeProgress(progress, fileName: item.name, peer: peer)
        }
    }

    func sendConfirmation(fileName: String, to peer: MCPeerID) {
        let msg = "ACK:\(fileName)"
        guard let data = msg.data(using: .utf8) else { return }
        try? session.send(data, toPeers: [peer], with: .reliable)
    }

    private func destinationURLForReceivedFile(
        resourceName: String,
        fileType: TransferItem.FileType,
        documentsURL: URL
    ) -> URL {

        switch fileType {
        case .map:
            return documentsURL
                .appendingPathComponent("OG_MapsFolder")
                .appendingPathComponent(resourceName)

        case .data:
            return documentsURL
                .appendingPathComponent("OG_DataFolder")
                .appendingPathComponent(resourceName)
        }
    }
    
    // MARK: - Helpers

    private func observeProgress(_ progress: Progress, fileName: String, peer: MCPeerID) {
        // Don't attach a second observer if one already exists for this file
        guard objc_getAssociatedObject(progress, &AssociatedKeys.obs) == nil else { return }
        
        let observation = progress.observe(\.fractionCompleted, options: [.new]) { [weak self] p, _ in
            DispatchQueue.main.async {
                self?.delegate?.transferProgress(p, fileName: fileName, from: peer)
            }
        }
        objc_setAssociatedObject(
            progress,
            &AssociatedKeys.obs,
            observation,
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
    }

    private func updateUser(_ peer: MCPeerID, state: Fellow_User.ConnectionState) {
        if let idx = fellowUsers.firstIndex(where: { $0.peerID == peer }) {
            fellowUsers[idx].state = state
        } else {
            fellowUsers.append(Fellow_User(peerID: peer, state: state))
        }
    }

    private func removeUser(_ peer: MCPeerID) {
        fellowUsers.removeAll { $0.peerID == peer }
        DispatchQueue.main.async {
            self.delegate?.peerDidDisconnect(peer)
        }
    }
}

// MARK: - Associated Keys
private enum AssociatedKeys {
    static var obs: UInt8 = 0 }

// MARK: - MCSessionDelegate

extension MultipeerSession: MCSessionDelegate {

    func session(_ session: MCSession, peer peerID: MCPeerID,
                 didChange state: MCSessionState) {
        DispatchQueue.main.async {
            switch state {
            case .connected:    self.updateUser(peerID, state: .connected)
            case .connecting:   self.updateUser(peerID, state: .connecting)
            case .notConnected: self.removeUser(peerID)
            @unknown default:   break
            }
        }
    }

    func session(_ session: MCSession, didReceive data: Data,
                 fromPeer peerID: MCPeerID) {
        guard let msg = String(data: data, encoding: .utf8) else { return }

        if msg.hasPrefix("ACK:") {
            let fileName = String(msg.dropFirst(4))
            DispatchQueue.main.async {
                self.delegate?.didReceiveConfirmation(fileName: fileName, from: peerID)
            }
            return
        }

        if msg.hasPrefix("REQUEST:") {
            let parts = msg.dropFirst(8).components(separatedBy: ":")
            guard parts.count >= 4 else { return }

            let transferID = parts[0]
            let fileName = parts[1]
            let fileType: TransferItem.FileType = parts[2] == "map" ? .map : .data
            let hasMatchingData = parts[3] == "1"

            if fileType == .map && hasMatchingData {
                incomingMapsWithData.insert(fileName)
            }

            DispatchQueue.main.async {
                self.delegate?.didReceiveTransferRequest(
                    fileName: fileName,
                    fileType: fileType,
                    from: peerID
                ) { accepted in
                    let response = accepted
                        ? "ACCEPT:\(transferID)"
                        : "DECLINE:\(transferID):\(fileName)"

                    guard let responseData = response.data(using: .utf8) else { return }

                    try? self.session.send(
                        responseData,
                        toPeers: [peerID],
                        with: .reliable
                    )

                    if !accepted {
                        self.incomingMapsWithData.remove(fileName)
                    }
                }
            }
            return
        }

        if msg.hasPrefix("ACCEPT:") {
            let transferID = String(msg.dropFirst(7))

            guard let pending = pendingOutgoingTransfers.removeValue(forKey: transferID) else {
                return
            }

            sendAcceptedTransfer(pending)
            return
        }

        if msg.hasPrefix("DECLINE:") {
            // DECLINE:transferID:fileName
            let parts = msg.dropFirst(8).components(separatedBy: ":")
            let transferID = parts.first ?? ""
            let fileName = parts.count >= 2 ? parts[1] : "Transfer"

            pendingOutgoingTransfers.removeValue(forKey: transferID)

            DispatchQueue.main.async {
                self.delegate?.transferFailed(
                    fileName: fileName,
                    from: peerID,
                    error: nil
                )
            }
            return
        }
    }

    func session(_ session: MCSession,
                 didStartReceivingResourceWithName resourceName: String,
                 fromPeer peerID: MCPeerID, with progress: Progress) {
        guard !resourceName.lowercased().hasSuffix(".ogt") else { return }
        observeProgress(progress, fileName: resourceName, peer: peerID)
    }

    func session(_ session: MCSession,
                 didFinishReceivingResourceWithName resourceName: String,
                 fromPeer peerID: MCPeerID, at localURL: URL?,
                 withError error: Error?) {

        guard error == nil, let tempURL = localURL else {
            DispatchQueue.main.async {
                self.delegate?.transferFailed(fileName: resourceName, from: peerID, error: error)
            }
            return
        }

        let ext = (resourceName as NSString).pathExtension.lowercased()
        let fileType: TransferItem.FileType = ext == "jpg" ? .map : .data

        let docs = FileManager.default.urls(for: .documentDirectory,
                                            in: .userDomainMask)[0]
        
        let stagingURL = destinationURLForReceivedFile(
            resourceName: resourceName,
            fileType: fileType,
            documentsURL: docs
        )

        do {
            let stagingDir = stagingURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: stagingDir, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: stagingURL.path) {
                try FileManager.default.removeItem(at: stagingURL)
            }
            try FileManager.default.moveItem(at: tempURL, to: stagingURL)

            let hasMatchingOGT = fileType == .map && incomingMapsWithData.contains(resourceName)

            let item = TransferItem(
                name: resourceName,
                url: stagingURL,
                type: fileType,
                receivedFrom: peerID.displayName,
                hasMatchingOGT: hasMatchingOGT
            )

            if hasMatchingOGT {
                incomingMapsWithData.remove(resourceName)
            }

            DispatchQueue.main.async {
                self.delegate?.transferComplete(item: item, from: peerID)
                self.sendConfirmation(fileName: resourceName, to: peerID)
            }
        } catch {
            DispatchQueue.main.async {
                self.delegate?.transferFailed(fileName: resourceName,
                                              from: peerID, error: error)
            }
        }

       // _ = folder // used when user accepts via swipe
    }

    func session(_ session: MCSession, didReceive stream: InputStream,
                 withName streamName: String, fromPeer peerID: MCPeerID) {}
}

// MARK: - MCNearbyServiceAdvertiserDelegate

extension MultipeerSession: MCNearbyServiceAdvertiserDelegate {

    func advertiser(_ advertiser: MCNearbyServiceAdvertiser,
                    didReceiveInvitationFromPeer peerID: MCPeerID,
                    withContext context: Data?,
                    invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        // Auto-accept connection — transfer approval is handled per-file
        invitationHandler(true, session)
    }
}

// MARK: - MCNearbyServiceBrowserDelegate

extension MultipeerSession: MCNearbyServiceBrowserDelegate {

    func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID,
                 withDiscoveryInfo info: [String: String]?) {
        guard info?["app"] == "otracker" else { return }
        DispatchQueue.main.async {
            self.updateUser(peerID, state: .discovered)
        }
    }

    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        DispatchQueue.main.async {
            self.removeUser(peerID)
        }
    }
}
