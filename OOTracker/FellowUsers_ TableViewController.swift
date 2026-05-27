//
//  FellowUsers_ TableViewController.swift
//  OOTracker
//
//  Created by Terry Burdett on 5/18/26.
//

//  FellowUsers_TableViewController.swift
//  OTracker

import UIKit
import MultipeerConnectivity

class FellowUsers_TableViewController: UITableViewController {

    // MARK: - Properties

    let session = MultipeerSession()
    private var fellowUsers: [Fellow_User] = []

    
    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        session.delegate = self
        session.start()
        setupUI()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)

        // Do NOT stop the multipeer session when pushing ShareMap_TableViewController.
        // The session must stay alive while sharing files.
        if isMovingFromParent || isBeingDismissed {
            session.stop()
        }
        
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        session.delegate = self
        fellowUsers = session.fellowUsers
        print("👥 fellowUsers on appear: \(fellowUsers.map { $0.peerID.displayName })")
        tableView.reloadData()
    }
     
    // MARK: - UI Setup

    private func setupUI() {
        title = "Fellow Users"
        navigationController?.navigationBar.prefersLargeTitles = true

        tableView.register(FellowUserCell.self,
                          forCellReuseIdentifier: FellowUserCell.id)
        tableView.rowHeight = 64
        tableView.separatorInset = UIEdgeInsets(top: 0, left: 72, bottom: 0, right: 0)
        tableView.backgroundColor = .systemGroupedBackground

        let footer = UILabel()
        footer.text = "OTracker devices on the same network or nearby via Bluetooth will appear here."
        footer.font = UIFont.systemFont(ofSize: 13)
        footer.textColor = .secondaryLabel
        footer.textAlignment = .center
        footer.numberOfLines = 0
        footer.frame = CGRect(x: 0, y: 0, width: tableView.bounds.width, height: 60)
        tableView.tableFooterView = footer
    }

    func peerDidDisconnect(_ peer: MCPeerID) {}
    // MARK: - Table View

    override func tableView(_ tableView: UITableView,
                            numberOfRowsInSection section: Int) -> Int {
        fellowUsers.isEmpty ? 1 : fellowUsers.count
    }

    override func tableView(_ tableView: UITableView,
                            cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(
            withIdentifier: FellowUserCell.id, for: indexPath) as! FellowUserCell

        if fellowUsers.isEmpty {
            cell.configureEmpty()
        } else {
            cell.configure(with: fellowUsers[indexPath.row])
        }
        return cell
    }

    override func tableView(_ tableView: UITableView,
                            didSelectRowAt indexPath: IndexPath) {

        tableView.deselectRow(at: indexPath, animated: true)

        guard !fellowUsers.isEmpty else { return }

        let user = fellowUsers[indexPath.row]

        switch user.state {

        case .discovered:
            session.connect(to: user.peerID)

        case .connecting:
            return

        case .connected:
            let alert = UIAlertController(
                title: user.peerID.displayName,
                message: nil,
                preferredStyle: .actionSheet
            )

            alert.addAction(UIAlertAction(title: "Share Maps", style: .default) { _ in
                self.openShareMaps(for: user)
            })

            alert.addAction(UIAlertAction(title: "Disconnect", style: .destructive) { _ in
                self.session.stop()
                self.session.start()
                self.fellowUsers.removeAll()
                self.tableView.reloadData()
            })

            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))

            present(alert, animated: true)
        }
    }

    // MARK: - Swipe Actions

    override func tableView(_ tableView: UITableView,
                            trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath)
    -> UISwipeActionsConfiguration? {
        guard !fellowUsers.isEmpty else { return nil }

        let user = fellowUsers[indexPath.row]
        guard user.state == .connected else { return nil }

        let shareAction = UIContextualAction(style: .normal,
                                            title: "Share") { [weak self] _, _, done in
            self?.openShareMaps(for: user)
            done(true)
        }
        shareAction.backgroundColor = .systemBlue
        shareAction.image = UIImage(systemName: "square.and.arrow.up")

        return UISwipeActionsConfiguration(actions: [shareAction])
    }

    // MARK: - Navigation

    private func openShareMaps(for user: Fellow_User) {
        let vc = ShareMap_TableViewController(session: session, peer: user.peerID)
        navigationController?.pushViewController(vc, animated: true)
    }
}

// MARK: - MultipeerSessionDelegate

extension FellowUsers_TableViewController: MultipeerSessionDelegate {

    func fellowUsersDidChange(_ users: [Fellow_User]) {
        fellowUsers = users
        tableView.reloadData()
    }

    func didReceiveTransferRequest(fileName: String,
                                   fileType: TransferItem.FileType,
                                   from peer: MCPeerID,
                                   handler: @escaping (Bool) -> Void) {
        TransferRequestHandler.askToReceive(
            fileName: fileName,
            fileType: fileType,
            from: peer,
            presentingViewController: self,
            openShareAfterAccept: {
                self.openShareMaps(
                    for: Fellow_User(peerID: peer, state: .connected)
                )
            },
            handler: handler
        )
    }

    func transferProgress(_ progress: Progress, fileName: String, from peer: MCPeerID) {}

    func transferComplete(item: TransferItem, from peer: MCPeerID) {
        openShareMaps(for: Fellow_User(peerID: peer, state: .connected))
    }

    func transferFailed(fileName: String, from peer: MCPeerID, error: Error?) {
        let msg = error?.localizedDescription ?? "Transfer was declined."
        let alert = UIAlertController(title: "Transfer Failed",
                                      message: "\(fileName): \(msg)",
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    func didReceiveConfirmation(fileName: String, from peer: MCPeerID) {}
}

// MARK: - FellowUserCell

class FellowUserCell: UITableViewCell {
    static let id = "FellowUserCell"

    private let avatarView = UIView()
    private let avatarLabel = UILabel()
    private let nameLabel = UILabel()
    private let statusLabel = UILabel()
    private let statusDot = UIView()

    override init(style: UITableViewCell.CellStyle,
                  reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        setupViews()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setupViews() {
        // Avatar circle
        avatarView.backgroundColor = .systemBlue.withAlphaComponent(0.15)
        avatarView.layer.cornerRadius = 22
        avatarView.translatesAutoresizingMaskIntoConstraints = false

        avatarLabel.font = UIFont.systemFont(ofSize: 18, weight: .semibold)
        avatarLabel.textColor = .systemBlue
        avatarLabel.textAlignment = .center
        avatarLabel.translatesAutoresizingMaskIntoConstraints = false
        avatarView.addSubview(avatarLabel)

        // Name
        nameLabel.font = UIFont.systemFont(ofSize: 16, weight: .medium)
        nameLabel.translatesAutoresizingMaskIntoConstraints = false

        // Status
        statusLabel.font = UIFont.systemFont(ofSize: 13)
        statusLabel.textColor = .secondaryLabel
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        // Status dot
        statusDot.layer.cornerRadius = 5
        statusDot.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(avatarView)
        contentView.addSubview(nameLabel)
        contentView.addSubview(statusLabel)
        contentView.addSubview(statusDot)

        NSLayoutConstraint.activate([
            avatarView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            avatarView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            avatarView.widthAnchor.constraint(equalToConstant: 44),
            avatarView.heightAnchor.constraint(equalToConstant: 44),

            avatarLabel.centerXAnchor.constraint(equalTo: avatarView.centerXAnchor),
            avatarLabel.centerYAnchor.constraint(equalTo: avatarView.centerYAnchor),

            nameLabel.topAnchor.constraint(equalTo: avatarView.topAnchor, constant: 4),
            nameLabel.leadingAnchor.constraint(equalTo: avatarView.trailingAnchor, constant: 12),
            nameLabel.trailingAnchor.constraint(equalTo: statusDot.leadingAnchor, constant: -8),

            statusLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 2),
            statusLabel.leadingAnchor.constraint(equalTo: avatarView.trailingAnchor, constant: 12),

            statusDot.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            statusDot.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            statusDot.widthAnchor.constraint(equalToConstant: 10),
            statusDot.heightAnchor.constraint(equalToConstant: 10),
        ])
    }

    func configure(with user: Fellow_User) {
        let name = user.peerID.displayName
        nameLabel.text = name
        avatarLabel.text = String(name.prefix(1)).uppercased()

        switch user.state {
        case .discovered:
            statusLabel.text = "Tap to connect"
            statusDot.backgroundColor = .systemOrange
            avatarView.backgroundColor = .systemOrange.withAlphaComponent(0.15)
            avatarLabel.textColor = .systemOrange
        case .connecting:
            statusLabel.text = "Connecting..."
            statusDot.backgroundColor = .systemYellow
            avatarView.backgroundColor = .systemYellow.withAlphaComponent(0.15)
            avatarLabel.textColor = .systemYellow
        case .connected:
            statusLabel.text = "Connected — Swipe to Share Map."
            statusDot.backgroundColor = .systemGreen
            avatarView.backgroundColor = .systemGreen.withAlphaComponent(0.15)
            avatarLabel.textColor = .systemGreen
        }
    }

    func configureEmpty() {
        avatarLabel.text = "?"
        nameLabel.text = "Searching for nearby users..."
        statusLabel.text = "Make sure both devices have OTracker open"
        statusDot.backgroundColor = .clear
        avatarView.backgroundColor = .systemGray5
        avatarLabel.textColor = .secondaryLabel
    }
}
