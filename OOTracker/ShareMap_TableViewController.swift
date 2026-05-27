//
//  ShareMap _ TableViewController.swift
//  OOTracker
//
//  Created by Terry Burdett on 5/18/26.
//

//  ShareMap_TableViewController.swift
//  OTracker

import UIKit
import MultipeerConnectivity

class ShareMap_TableViewController: UITableViewController {

    // MARK: - Properties

    var session: MultipeerSession
    private let peer: MCPeerID
    private var localFiles: [TransferItem] = []
    private var confirmedFiles: [TransferItem] = []  // file names ACK'd by receiver
    private var receivedFiles: [TransferItem] = []
    private var activeTransfers: [String: Progress] = [:]
    private var incomingTransfers: [String: (progress: Progress, from: String, type: TransferItem.FileType)] = [:]
    private var incomingTransferOrder: [String] = []  
    // MARK: - Sections

    private enum Section: Int, CaseIterable {
        case local    // files available to send
        case confirmed  // SENT & CONFIRMED
        case received // files received from peer
    }

    // MARK: - Init

    init(session: MultipeerSession, peer: MCPeerID) {
        self.session = session
        self.peer = peer
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        session.delegate = self
        loadLocalFiles()
        setupUI()
    }

    // MARK: - UI Setup

    private func setupUI() {
        title = peer.displayName
        navigationController?.navigationBar.prefersLargeTitles = false

        tableView.register(MapFileCell.self,
                          forCellReuseIdentifier: MapFileCell.id)
        tableView.register(UITableViewCell.self,
                           forCellReuseIdentifier: "ConfirmedCell")
        tableView.register(ReceivedFileCell.self,
                          forCellReuseIdentifier: ReceivedFileCell.id)
        tableView.backgroundColor = .systemGroupedBackground
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 64
    }

    // MARK: - File Loading

    private func loadLocalFiles() {
        let docs = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        )[0]

        let mapsFolder = docs.appendingPathComponent("OG_MapsFolder")
        let dataFolder = docs.appendingPathComponent("OG_DataFolder")

        guard let mapFiles = try? FileManager.default.contentsOfDirectory(
            at: mapsFolder,
            includingPropertiesForKeys: [.fileSizeKey]
        ) else {
            localFiles = []
            tableView.reloadData()
            return
        }

        localFiles = mapFiles.compactMap { url in
            let ext = url.pathExtension.lowercased()

            guard ext == "jpg" || ext == "jpeg" || ext == "png" || ext == "pdf" || ext == "tif" || ext == "tiff" else {
                return nil
            }

            return TransferItem(
                name: url.lastPathComponent,
                url: url,
                type: .map
            )
        }
        .sorted { $0.name < $1.name }

        tableView.reloadData()
    }
   // func peerDidDisconnect(_ peer: MCPeerID) {}
    func peerDidDisconnect(_ peer: MCPeerID) {
        // Only pop if we're connected to this specific peer
        guard peer == self.peer else { return }
        navigationController?.popViewController(animated: true)
    }
    
    private func matchingOGTExists(for item: TransferItem) -> Bool {
        let docs = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        )[0]

        let ogtName = item.url.deletingPathExtension().lastPathComponent + ".ogt"

        let ogtURL = docs
            .appendingPathComponent("OG_DataFolder")
            .appendingPathComponent(ogtName)

        return FileManager.default.fileExists(atPath: ogtURL.path)
    }
    // MARK: - Table View DataSource

    override func numberOfSections(in tableView: UITableView) -> Int {
        Section.allCases.count
    }

    override func tableView(_ tableView: UITableView,
                            numberOfRowsInSection section: Int) -> Int {
      //  switch Section(rawValue: section)! {
        guard let section = Section(rawValue: section) else { return 0 }
        switch section {
            case .local:    return localFiles.isEmpty ? 1 : localFiles.count
            case .confirmed:
                return confirmedFiles.isEmpty ? 0 : confirmedFiles.count
            case .received:
                let visibleIncoming = incomingTransferOrder
                    .filter { !$0.lowercased().hasSuffix(".ogt") }
                    .filter { incomingTransfers[$0] != nil }
                let count = visibleIncoming.count + receivedDisplayItems().count
                return count == 0 ? 1 : count
        }
    }

    override func tableView(_ tableView: UITableView,
                            titleForHeaderInSection section: Int) -> String? {
        
        guard let section = Section(rawValue: section) else { return nil }
        switch section {
        //switch Section(rawValue: section)! {
            case .local:    return "MY FILES"
            case .confirmed:
                return confirmedFiles.isEmpty ? nil : "SENT & CONFIRMED"
            case .received: return "RECEIVED FROM \(peer.displayName.uppercased())"
        }
    }

    override func tableView(_ tableView: UITableView,
                            cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        
        guard let section = Section(rawValue: indexPath.section) else { return UITableViewCell() }
        switch section {
       // switch Section(rawValue: indexPath.section)! {
            
        case .local:
            let cell = tableView.dequeueReusableCell(
                withIdentifier: MapFileCell.id, for: indexPath) as! MapFileCell
            if localFiles.isEmpty {
                cell.configureEmpty(message: "No maps or data files found.")
            } else {
                let item = localFiles[indexPath.row]
                let progress = activeTransfers[item.name]
                let hasOGT = matchingOGTExists(for: item)
                cell.configure(with: item, progress: progress, hasOGT: hasOGT)
            }
            return cell
        case .confirmed:
            let cell = tableView.dequeueReusableCell(
                withIdentifier: MapFileCell.id, for: indexPath) as! MapFileCell
            let item = confirmedFiles[indexPath.row]
            cell.configure(with: item, progress: nil, hasOGT: item.hasMatchingOGT)
            // Override the chevron to show a checkmark instead of upload arrow
            cell.setConfirmed()
            return cell
        case .received:
            let cell = tableView.dequeueReusableCell(
                withIdentifier: ReceivedFileCell.id,
                for: indexPath
            ) as! ReceivedFileCell

            let visibleIncoming = incomingTransferOrder
                .filter { !$0.lowercased().hasSuffix(".ogt") }
                .compactMap { key in
                    incomingTransfers[key].map { (key: key, value: $0) }
                }

            if visibleIncoming.isEmpty && receivedFiles.isEmpty {
                cell.configureEmpty()
                return cell
            }

            if indexPath.row < visibleIncoming.count {
                let entry = visibleIncoming[indexPath.row]
                cell.configureReceiving(
                    fileName: entry.key,
                    fileType: entry.value.type,
                    from: entry.value.from,
                    progress: entry.value.progress
                )
                return cell
            }

            let receivedIndex = indexPath.row - visibleIncoming.count
            let displayItems = receivedDisplayItems()

            guard receivedIndex >= 0, receivedIndex < displayItems.count else {
                cell.configureEmpty()
                return cell
            }

            cell.configure(with: displayItems[receivedIndex])
            return cell
        }
    }

    // MARK: - Table View Delegate

    override func tableView(_ tableView: UITableView,
                            didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard Section(rawValue: indexPath.section) == .local,
              !localFiles.isEmpty else { return }

        let item = localFiles[indexPath.row]
        session.sendMapAndMatchingDataIfAvailable(item, to: peer)
       // confirmSend(item: item)
    }

    // MARK: - Swipe to Save

    override func tableView(_ tableView: UITableView,
                            trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath)
    -> UISwipeActionsConfiguration? {

        guard Section(rawValue: indexPath.section) == .received else { return nil }

        let incomingCount = incomingTransfers.count
        guard indexPath.row >= incomingCount else { return nil }

        let displayItems = receivedDisplayItems()
        let receivedIndex = indexPath.row - incomingCount

        guard receivedIndex >= 0, receivedIndex < displayItems.count else { return nil }

        let item = displayItems[receivedIndex]

        let saveAction = UIContextualAction(style: .normal,
                                            title: "Save") { [weak self] _, _, done in
            self?.saveReceivedMapGroup(item)
            done(true)
        }

        saveAction.backgroundColor = .systemGreen
        saveAction.image = UIImage(systemName: "square.and.arrow.down")

        return UISwipeActionsConfiguration(actions: [saveAction])
    }

    // MARK: - Save Received File
    
    private func saveReceivedMapGroup(_ mapItem: TransferItem) {
        let docs = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        )[0]

        let mapsFolder = docs.appendingPathComponent("OG_MapsFolder")
        let dataFolder = docs.appendingPathComponent("OG_DataFolder")

        let mapBase = baseName(mapItem.name)
        let mapDest = mapsFolder.appendingPathComponent(mapItem.name)

        let dataItem = receivedFiles.first {
            $0.type == .data && baseName($0.name) == mapBase
        }

        let dataDest = dataItem.map {
            dataFolder.appendingPathComponent($0.name)
        }

        if FileManager.default.fileExists(atPath: mapDest.path) ||
            (dataDest != nil && FileManager.default.fileExists(atPath: dataDest!.path)) {

            confirmOverwriteMapGroup(
                mapItem: mapItem,
                dataItem: dataItem,
                mapDest: mapDest,
                dataDest: dataDest
            )
            return
        }

        copyReceivedMapGroup(
            mapItem: mapItem,
            dataItem: dataItem,
            mapDest: mapDest,
            dataDest: dataDest
        )
    }

    private func confirmOverwriteMapGroup(mapItem: TransferItem,
                                          dataItem: TransferItem?,
                                          mapDest: URL,
                                          dataDest: URL?) {
        let alert = UIAlertController(
            title: "File Exists",
            message: "\(mapItem.name) already exists. Replace it and its DATA file?",
            preferredStyle: .alert
        )

        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))

        alert.addAction(UIAlertAction(title: "Replace",
                                      style: .destructive) { [weak self] _ in
            self?.copyReceivedMapGroup(
                mapItem: mapItem,
                dataItem: dataItem,
                mapDest: mapDest,
                dataDest: dataDest
            )
        })

        present(alert, animated: true)
    }

    private func copyReceivedMapGroup(mapItem: TransferItem,
                                      dataItem: TransferItem?,
                                      mapDest: URL,
                                      dataDest: URL?) {
        do {
            try FileManager.default.createDirectory(
                at: mapDest.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

            if let dataDest {
                try FileManager.default.createDirectory(
                    at: dataDest.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
            }

            if FileManager.default.fileExists(atPath: mapDest.path) {
                try FileManager.default.removeItem(at: mapDest)
            }

            try FileManager.default.copyItem(at: mapItem.url, to: mapDest)

            if let dataItem, let dataDest {
                if FileManager.default.fileExists(atPath: dataDest.path) {
                    try FileManager.default.removeItem(at: dataDest)
                }

                try FileManager.default.copyItem(at: dataItem.url, to: dataDest)
            }

            let mapBase = baseName(mapItem.name)

            receivedFiles.removeAll {
                baseName($0.name) == mapBase
            }

           // incomingTransfers.removeAll()
          //  incomingTransferOrder.removeAll()  // ← add here
           // activeTransfers.removeAll()
            // Only remove the saved map and its matching .ogt, leave everything else
            incomingTransfers.removeValue(forKey: mapItem.name)
            incomingTransferOrder.removeAll { $0 == mapItem.name }

            if let dataItem {
                incomingTransfers.removeValue(forKey: dataItem.name)
                incomingTransferOrder.removeAll { $0 == dataItem.name }
            }

            // Only remove from activeTransfers if outgoing
            activeTransfers.removeValue(forKey: mapItem.name)
            if let dataItem {
                activeTransfers.removeValue(forKey: dataItem.name)
            }
            
            tableView.reloadData()
            showBanner(name: mapItem.name)
            loadLocalFiles()

        } catch {
            showError("Could not save \(mapItem.name): \(error.localizedDescription)")
        }
    }

    // MARK: - Helpers

    private func fileSizeString(for url: URL) -> String {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
            return ""
        }
        let mb = Double(size) / 1_048_576
        return mb >= 1 ? String(format: "%.1f MB", mb)
                       : String(format: "%d KB", size / 1024)
    }

    private func showBanner(name: String) {
        let banner = UILabel()
        banner.text = "  ✓  \(name) saved  "
        banner.font = UIFont.systemFont(ofSize: 14, weight: .semibold)
        banner.textColor = .white
        banner.backgroundColor = .systemGreen
        banner.layer.cornerRadius = 12
        banner.clipsToBounds = true
        banner.sizeToFit()
        banner.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(banner)

        NSLayoutConstraint.activate([
            banner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            banner.topAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
        ])

        UIView.animate(withDuration: 0.3, delay: 2.0, options: [],
                       animations: { banner.alpha = 0 }) { _ in
            banner.removeFromSuperview()
        }
    }

    private func showError(_ message: String, from peer: MCPeerID? = nil) {
        let fullMessage: String

        if let peer = peer {
            fullMessage = "\(peer.displayName): \(message)"
        } else {
            fullMessage = message
        }

        let alert = UIAlertController(
            title: "Transfer Error",
            message: fullMessage,
            preferredStyle: .alert
        )

        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}

// MARK: - MultipeerSessionDelegate

extension ShareMap_TableViewController: MultipeerSessionDelegate {

    func fellowUsersDidChange(_ users: [Fellow_User]) {
       /* if !users.contains(where: { $0.peerID == peer }) {
            // Peer disconnected
            navigationItem.title = "\(peer.displayName) — Disconnected"
            navigationItem.rightBarButtonItem = nil
        }*/
    }

    func didReceiveTransferRequest(fileName: String,
                                   fileType: TransferItem.FileType,
                                   from peer: MCPeerID,
                                   handler: @escaping (Bool) -> Void) {
        guard peer == self.peer else { return }

        TransferRequestHandler.askToReceive(
            fileName: fileName,
            fileType: fileType,
            from: peer,
            presentingViewController: self,
            handler: handler
        )
    }

    func transferProgress(_ progress: Progress,
                          fileName: String,
                          from peer: MCPeerID) {

        // Outgoing transfer from this phone
        if let idx = localFiles.firstIndex(where: { $0.name == fileName }) {
            activeTransfers[fileName] = progress  // ← moved inside the outgoing guard
            let ip = IndexPath(row: idx, section: Section.local.rawValue)
            if tableView.numberOfRows(inSection: Section.local.rawValue) > idx {
                tableView.reloadRows(at: [ip], with: .none)
            }
            return
        }

        // Matching DATA file being sent with a MAP
        if fileName.lowercased().hasSuffix(".ogt") {
            if let matchingMapIndex = localFiles.firstIndex(where: {
                $0.url.deletingPathExtension().lastPathComponent ==
                URL(fileURLWithPath: fileName).deletingPathExtension().lastPathComponent
            }) {
                activeTransfers[fileName] = progress  // ← moved inside the outgoing guard
                let ip = IndexPath(row: matchingMapIndex, section: Section.local.rawValue)
                if tableView.numberOfRows(inSection: Section.local.rawValue) > matchingMapIndex {
                    tableView.reloadRows(at: [ip], with: .none)
                }
                return
            }
        }

        // Actual incoming transfer
                let fileType: TransferItem.FileType =
                    fileName.lowercased().hasSuffix(".ogt") ? .data : .map

                incomingTransfers[fileName] = (
                    progress: progress,
                    from: peer.displayName,
                    type: fileType
                )

                if !incomingTransferOrder.contains(fileName) {
                    incomingTransferOrder.append(fileName)
                    // New transfer — reload section so cell appears
                    tableView.reloadSections(
                        IndexSet(integer: Section.received.rawValue),
                        with: .none
                    )
                    return
                }

                // Already showing — update progress bar directly, no reload
                let visibleIncoming = incomingTransferOrder
                    .filter { !$0.lowercased().hasSuffix(".ogt") }
                    .filter { incomingTransfers[$0] != nil }

                if let row = visibleIncoming.firstIndex(of: fileName) {
                    let ip = IndexPath(row: row, section: Section.received.rawValue)
                    if let cell = tableView.cellForRow(at: ip) as? ReceivedFileCell {
                        cell.updateProgress(Float(progress.fractionCompleted))
                    }
                }
            }

    func transferComplete(item: TransferItem, from peer: MCPeerID) {
        activeTransfers.removeValue(forKey: item.name)
        incomingTransfers.removeValue(forKey: item.name)
        incomingTransferOrder.removeAll { $0 == item.name }
        
        let received = TransferItem(
            name: item.name,
            url: item.url,
            type: item.type,
            receivedFrom: peer.displayName
        )

        // Replace existing entry if present, otherwise append
        if let idx = receivedFiles.firstIndex(where: { $0.name == item.name }) {
            receivedFiles[idx] = received
        } else {
            receivedFiles.append(received)
        }

        DispatchQueue.main.async {
            self.tableView.reloadData()
        }
    }

    func transferFailed(fileName: String,
                        from peer: MCPeerID,
                        error: Error?) {

        activeTransfers.removeValue(forKey: fileName)

        let msg = error != nil
            ? error!.localizedDescription
            : "Transfer was declined."

        showError("\(fileName) — \(msg)", from: peer)

        tableView.reloadData()
    }

    private func baseName(_ fileName: String) -> String {
        URL(fileURLWithPath: fileName)
            .deletingPathExtension()
            .lastPathComponent
    }

    private func receivedDisplayItems() -> [TransferItem] {
        let maps = receivedFiles.filter { $0.type == .map }

        // Only show standalone data items if no map is coming or already received
        let standaloneData = receivedFiles.filter { item in
            guard item.type == .data else { return false }
            let base = baseName(item.name)
            let mapReceived = maps.contains { baseName($0.name) == base }
            let mapIncoming = incomingTransfers.keys.contains {
                baseName($0) == base
            }
            return !mapReceived && !mapIncoming
        }

        let mapItems = maps.map { map -> TransferItem in
            var item = map
            let mapBase = baseName(map.name)
            item.hasMatchingOGT = receivedFiles.contains {
                $0.type == .data && baseName($0.name) == mapBase
            } || session.incomingMapsWithData.contains(map.name)
            return item
        }

        return (mapItems + standaloneData).sorted { $0.name < $1.name }
    }
    
    func didReceiveConfirmation(fileName: String, from peer: MCPeerID) {
        guard !fileName.lowercased().hasSuffix(".ogt") else { return }

        // Find the matching local file to get hasMatchingOGT
        if let item = localFiles.first(where: { $0.name == fileName }) {
            let hasOGT = matchingOGTExists(for: item)
            var confirmed = item
            confirmed.hasMatchingOGT = hasOGT

            if !confirmedFiles.contains(where: { $0.name == fileName }) {
                confirmedFiles.append(confirmed)
            }
        }

        tableView.reloadSections(
            IndexSet(integer: Section.confirmed.rawValue),
            with: .automatic
        )
    }
}

// MARK: - MapFileCell

class MapFileCell: UITableViewCell {
    static let id = "MapFileCell"

    private let mapTag = UILabel()
    private let dataTag = UILabel()
    private let tagStack = UIStackView()

    private let nameLabel = UILabel()
    private let sizeLabel = UILabel()
    private let progressView = UIProgressView(progressViewStyle: .default)
    private let chevron = UIImageView(image: UIImage(systemName: "arrow.up.circle"))

    override init(style: UITableViewCell.CellStyle,
                  reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        setupViews()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setupViews() {
        mapTag.font = .systemFont(ofSize: 11, weight: .bold)
        mapTag.textAlignment = .center
        mapTag.layer.cornerRadius = 6
        mapTag.clipsToBounds = true
        mapTag.text = "MAP"
        mapTag.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.15)
        mapTag.textColor = .systemBlue
        mapTag.translatesAutoresizingMaskIntoConstraints = false

        dataTag.font = .systemFont(ofSize: 11, weight: .bold)
        dataTag.textAlignment = .center
        dataTag.layer.cornerRadius = 6
        dataTag.clipsToBounds = true
        dataTag.text = "DATA"
        dataTag.backgroundColor = UIColor.systemGreen.withAlphaComponent(0.15)
        dataTag.textColor = .systemGreen
        dataTag.translatesAutoresizingMaskIntoConstraints = false

        tagStack.axis = .vertical
        tagStack.spacing = 4
        tagStack.alignment = .fill
        tagStack.translatesAutoresizingMaskIntoConstraints = false
        tagStack.addArrangedSubview(mapTag)
        tagStack.addArrangedSubview(dataTag)

        nameLabel.font = .systemFont(ofSize: 15)
        nameLabel.translatesAutoresizingMaskIntoConstraints = false

        sizeLabel.font = .systemFont(ofSize: 12)
        sizeLabel.textColor = .secondaryLabel
        sizeLabel.translatesAutoresizingMaskIntoConstraints = false

        progressView.progressTintColor = .systemBlue
        progressView.trackTintColor = .systemGray5
        progressView.layer.cornerRadius = 2
        progressView.clipsToBounds = true
        progressView.isHidden = true
        progressView.translatesAutoresizingMaskIntoConstraints = false

        chevron.tintColor = .systemBlue
        chevron.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(tagStack)
        contentView.addSubview(nameLabel)
        contentView.addSubview(sizeLabel)
        contentView.addSubview(progressView)
        contentView.addSubview(chevron)

        NSLayoutConstraint.activate([
            tagStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            tagStack.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),

            mapTag.widthAnchor.constraint(equalToConstant: 50),
            mapTag.heightAnchor.constraint(equalToConstant: 22),

            dataTag.widthAnchor.constraint(equalToConstant: 50),
            dataTag.heightAnchor.constraint(equalToConstant: 22),

            chevron.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            chevron.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            chevron.widthAnchor.constraint(equalToConstant: 24),
            chevron.heightAnchor.constraint(equalToConstant: 24),

            nameLabel.leadingAnchor.constraint(equalTo: tagStack.trailingAnchor, constant: 10),
            nameLabel.trailingAnchor.constraint(equalTo: chevron.leadingAnchor, constant: -10),
            nameLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),

            sizeLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            sizeLabel.trailingAnchor.constraint(equalTo: nameLabel.trailingAnchor),
            sizeLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 4),

            progressView.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            progressView.trailingAnchor.constraint(equalTo: nameLabel.trailingAnchor),
            progressView.topAnchor.constraint(equalTo: sizeLabel.bottomAnchor, constant: 8),
            progressView.heightAnchor.constraint(equalToConstant: 4),

            contentView.bottomAnchor.constraint(greaterThanOrEqualTo: sizeLabel.bottomAnchor, constant: 12),
            contentView.bottomAnchor.constraint(greaterThanOrEqualTo: progressView.bottomAnchor, constant: 12)
        ])
    }

    func configure(with item: TransferItem, progress: Progress?, hasOGT: Bool) {
        nameLabel.text = item.name
        nameLabel.textColor = .label
        chevron.isHidden = false

        mapTag.isHidden = false
        dataTag.isHidden = !hasOGT

        if let size = try? item.url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
            let mb = Double(size) / 1_048_576
            sizeLabel.text = mb >= 1
                ? String(format: "%.1f MB", mb)
                : String(format: "%d KB", size / 1024)
        }

        if let progress = progress, !progress.isFinished {
            progressView.isHidden = false
            progressView.setProgress(Float(progress.fractionCompleted), animated: true)
            chevron.image = UIImage(systemName: "arrow.up.circle.fill")
        } else {
            progressView.isHidden = true
            chevron.image = UIImage(systemName: "arrow.up.circle")
        }
    }

    func configureEmpty(message: String) {
        nameLabel.text = message
        nameLabel.textColor = .tertiaryLabel
        sizeLabel.text = nil

        mapTag.isHidden = true
        dataTag.isHidden = true

        progressView.isHidden = true
        chevron.isHidden = true
    }
    
    func setConfirmed() {
        chevron.image = UIImage(systemName: "checkmark.circle.fill")
        chevron.tintColor = .systemGreen
    }
}


// MARK: - ReceivedFileCell

class ReceivedFileCell: UITableViewCell {
    static let id = "ReceivedFileCell"

    private let mapTag = UILabel()
    private let ogtTag = UILabel()
    private let tagStack = UIStackView()
    
    private let nameLabel = UILabel()
    private let fromLabel = UILabel()
    private let saveHint = UILabel()
    private let progressView = UIProgressView(progressViewStyle: .default)
    
    override init(style: UITableViewCell.CellStyle,
                  reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        setupViews()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setupViews() {
        contentView.backgroundColor = .secondarySystemGroupedBackground
        contentView.layer.cornerRadius = 14
        contentView.layer.masksToBounds = true

        mapTag.font = .systemFont(ofSize: 11, weight: .bold)
        mapTag.textAlignment = .center
        mapTag.layer.cornerRadius = 8
        mapTag.clipsToBounds = true
        mapTag.text = "MAP"
        mapTag.backgroundColor = UIColor.systemTeal.withAlphaComponent(0.15)
        mapTag.textColor = .systemTeal

        ogtTag.font = .systemFont(ofSize: 11, weight: .bold)
        ogtTag.textAlignment = .center
        ogtTag.layer.cornerRadius = 8
        ogtTag.clipsToBounds = true
        ogtTag.text = "DATA"
        ogtTag.backgroundColor = UIColor.systemGreen.withAlphaComponent(0.15)
        ogtTag.textColor = .systemGreen

        tagStack.axis = .vertical
        tagStack.spacing = 4
        tagStack.alignment = .fill
        tagStack.translatesAutoresizingMaskIntoConstraints = false

        mapTag.translatesAutoresizingMaskIntoConstraints = false
        ogtTag.translatesAutoresizingMaskIntoConstraints = false

        tagStack.addArrangedSubview(mapTag)
        tagStack.addArrangedSubview(ogtTag)

        nameLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        nameLabel.numberOfLines = 1
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.translatesAutoresizingMaskIntoConstraints = false

        fromLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        fromLabel.textColor = .secondaryLabel
        fromLabel.translatesAutoresizingMaskIntoConstraints = false

        saveHint.font = .systemFont(ofSize: 12, weight: .regular)
        saveHint.textColor = .tertiaryLabel
        saveHint.text = "Tap to save"
        saveHint.translatesAutoresizingMaskIntoConstraints = false

        progressView.progressTintColor = .systemBlue
        progressView.trackTintColor = .systemGray5
        progressView.isHidden = true
        progressView.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(tagStack)
        contentView.addSubview(nameLabel)
        contentView.addSubview(fromLabel)
        contentView.addSubview(saveHint)
        contentView.addSubview(progressView)

        NSLayoutConstraint.activate([
            tagStack.leadingAnchor.constraint(
                equalTo: contentView.leadingAnchor,
                constant: 12
            ),
            tagStack.centerYAnchor.constraint(
                equalTo: contentView.centerYAnchor
            ),

            mapTag.widthAnchor.constraint(equalToConstant: 56),
            mapTag.heightAnchor.constraint(equalToConstant: 22),

            ogtTag.widthAnchor.constraint(equalToConstant: 56),
            ogtTag.heightAnchor.constraint(equalToConstant: 22),

            nameLabel.leadingAnchor.constraint(
                equalTo: tagStack.trailingAnchor,
                constant: 16
            ),
            nameLabel.trailingAnchor.constraint(
                equalTo: contentView.trailingAnchor,
                constant: -16
            ),
            nameLabel.topAnchor.constraint(
                equalTo: contentView.topAnchor,
                constant: 14
            ),

            fromLabel.leadingAnchor.constraint(
                equalTo: nameLabel.leadingAnchor
            ),
            fromLabel.trailingAnchor.constraint(
                equalTo: nameLabel.trailingAnchor
            ),
            fromLabel.topAnchor.constraint(
                equalTo: nameLabel.bottomAnchor,
                constant: 4
            ),

            saveHint.leadingAnchor.constraint(
                equalTo: nameLabel.leadingAnchor
            ),
            saveHint.trailingAnchor.constraint(
                equalTo: nameLabel.trailingAnchor
            ),
            saveHint.topAnchor.constraint(
                equalTo: fromLabel.bottomAnchor,
                constant: 4
            ),

            progressView.leadingAnchor.constraint(
                equalTo: nameLabel.leadingAnchor
            ),
            progressView.trailingAnchor.constraint(
                equalTo: nameLabel.trailingAnchor
            ),
            progressView.topAnchor.constraint(
                equalTo: fromLabel.bottomAnchor,
                constant: 8
            ),
            progressView.heightAnchor.constraint(equalToConstant: 4),

            contentView.bottomAnchor.constraint(
                greaterThanOrEqualTo: saveHint.bottomAnchor,
                constant: 14
            ),
            contentView.bottomAnchor.constraint(
                greaterThanOrEqualTo: progressView.bottomAnchor,
                constant: 14
            )
        ])
    }
    func configure(with item: TransferItem) {

        nameLabel.text = item.name
        nameLabel.textColor = .label

        saveHint.isHidden = false
        progressView.isHidden = true

        mapTag.isHidden = true
        ogtTag.isHidden = true

        switch item.type {

        case .map:
            mapTag.isHidden = false
            ogtTag.isHidden = !item.hasMatchingOGT

        case .data:
            mapTag.isHidden = true
            ogtTag.isHidden = false
        }

        if let from = item.receivedFrom {
            fromLabel.text = "From \(from)"
        }
    }

    func configureEmpty() {
        nameLabel.text = "No files received yet"
        nameLabel.textColor = .tertiaryLabel

        fromLabel.text = nil

        mapTag.isHidden = true
        ogtTag.isHidden = true

        saveHint.isHidden = true
        progressView.isHidden = true

        contentView.backgroundColor = .secondarySystemGroupedBackground
    }
    
    func configureReceiving(fileName: String,
                            fileType: TransferItem.FileType,
                            from: String,
                            progress: Progress) {

        nameLabel.text = fileName
        nameLabel.textColor = .label
        fromLabel.text = "Receiving from \(from)"
        saveHint.isHidden = true

        mapTag.isHidden = true
        ogtTag.isHidden = true

        switch fileType {

        case .map:
            mapTag.isHidden = false

        case .data:
            ogtTag.isHidden = false
        }

        progressView.isHidden = false
        progressView.setProgress(
            Float(progress.fractionCompleted),
            animated: true
        )

        contentView.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.06)
    }
    
    func updateProgress(_ value: Float) {
        progressView.setProgress(value, animated: true)
    }
}
