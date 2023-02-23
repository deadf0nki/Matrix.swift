//
//  DataStore.swift
//  
//
//  Created by Charles Wright on 2/14/23.
//

import Foundation

public enum StorageType: String {
    case inMemory
    case persistent
}

public protocol DataStore {
    var session: Matrix.Session { get }
    
    init(session: Matrix.Session, type: StorageType) async throws
    
    //init(userId: UserId, deviceId: String) async throws
    
    func save(events: [ClientEvent]) async throws
    
    func save(events: [ClientEventWithoutRoomId], in roomId: RoomId) async throws
    
    func loadEvents(for roomId: RoomId, limit: Int, offset: Int?) async throws -> [ClientEvent]
    
    // FIXME: Add all the other function prototypes that got built out in the GRDBDataStore
}
