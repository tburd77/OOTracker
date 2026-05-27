//
//  FileIO.swift
//  OOTracker
//
//  Created by Terry Burdett on 5/19/26.
//

import Foundation

let appFolders = ["OG_MapsFolder", "OG_DataFolder", "OG_TempMapFolder","OG_TempDataFolder"]

func createAppFolders() {
    let fileManager = FileManager.default
    let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]

    for folderName in appFolders {
        let folderURL = docs.appendingPathComponent(folderName)
        guard !fileManager.fileExists(atPath: folderURL.path) else { continue }

        do {
            try fileManager.createDirectory(at: folderURL,
                                            withIntermediateDirectories: true)
        } catch {
            print("⚠️ Could not create folder \(folderName): \(error)")
        }
    }
    
}
