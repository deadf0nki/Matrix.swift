//
//  GRDBDataStore.swift
//  
//
//  Created by Charles Wright on 2/14/23.
//

import Foundation

import GRDB

public struct GRDBDataStore: DataStore {
    //let db: Database
    let dbQueue: DatabaseQueue
    var migrator: DatabaseMigrator
        
    // MARK: Migrations
    
    private mutating func runMigrations() throws {
        // First Migration -- Create the basic tables
        migrator.registerMigration("Create Tables") { db in
            
            // Events database
            try db.create(table: "timeline") { t in
                t.column("event_id", .text).unique().notNull()
                t.column("room_id", .text).notNull()
                t.column("sender", .text).notNull()
                t.column("type", .text).notNull()
                t.column("state_key", .text)
                t.column("origin_server_ts", .integer).notNull()
                t.column("content", .blob).notNull()
                t.column("unsigned", .blob)
                t.primaryKey(["event_id"])
            }
            
            // Room state events
            // This is almost the same schema as `timeline`, except:
            // * stateKey is NOT NULL
            // * primary key is (roomId, type, stateKey) instead of eventId
            try db.create(table: "state") { t in
                t.column("event_id", .text).notNull()
                t.column("room_id", .text).notNull()
                t.column("sender", .text).notNull()
                t.column("type", .text).notNull()
                t.column("state_key", .text).notNull()
                t.column("origin_server_ts", .integer).notNull()
                t.column("content", .blob).notNull()
                t.column("unsigned", .blob)
                t.primaryKey(["room_id", "type", "state_key"])
            }
            
            try db.create(table: "stripped_state") { t in
                t.column("room_id", .text).notNull()
                t.column("sender", .text).notNull()
                t.column("state_key", .text).notNull()
                t.column("type", .text).notNull()
                t.column("content", .blob).notNull()
                t.primaryKey(["room_id", "type", "state_key"])
            }
            
            try db.create(table: "rooms") { t in
                t.column("room_id", .text).unique().notNull()
                
                t.column("join_state", .text).notNull()
                
                //t.column("notification_count", .integer).notNull()
                //t.column("highlight_count", .integer).notNull()

                t.column("timestamp", .datetime).notNull()
                
                t.primaryKey(["room_id"])
            }
            
            // User profiles are explicitly key-value stores in order to
            // support more flexible profiles in the future.
            try db.create(table: "user_profiles") { t in
                t.column("user_id", .text).notNull()
                t.column("key", .text).notNull()
                t.column("value", .text).notNull()
                t.primaryKey(["user_id", "key"])
            }
            
            // We're cheating a little bit here, using the same table for
            // both room-level account data and global account data.
            // Use a roomId of "" for global account data that is not
            // specific to any given room.
            // In the Swift code, we would use `nil`, but SQL doesn't
            // like to have NULLs in primary keys.
            try db.create(table: "account_data") { t in
                t.column("user_id", .text).notNull()
                t.column("room_id", .text).notNull()
                t.column("type", .text).notNull()
                t.column("content", .blob)
                t.primaryKey(["user_id", "room_id", "type"])
            }
            
            // FIXME: Really this should move into a different type
            //        The existing data store is for all the stuff *inside* a session
            //        It has no notion of multiple sessions at all
            /*
            try db.create(table: "sessions") { t in
                t.column("userId", .text).notNull()
                t.column("deviceId", .text).notNull()
                t.column("accessToken", .text).notNull()
                t.column("homeserver", .text).notNull()
                
                t.column("displayname", .text)
                t.column("avatarUrl", .text)
                t.column("statusMessage", .text)
                
                t.column("syncToken", .text)
                t.column("syncing", .boolean)
                t.column("syncRequestTimeout", .integer).notNull()
                t.column("syncDelayNS", .integer).notNull()
                
                t.column("recoverySecretKey", .blob)
                t.column("recoveryTimestamp", .datetime)
                
                t.primaryKey(["userId"])
            }
            */
        }
        
        try migrator.migrate(dbQueue)
    }
    
    // MARK: init()
    
    public init(userId: UserId, type: StorageType) async throws {
        switch type {
        case .inMemory:
            self.dbQueue = DatabaseQueue()
        case .persistent(let preserve):
            let dirPath = [
                NSHomeDirectory(),
                ".matrix",
                Bundle.main.infoDictionary?["CFBundleName"] as? String ?? "matrix.swift",
                "\(userId)"
            ].joined(separator: "/")
            let filePath = dirPath + "/matrix.sqlite3"
            
            if !preserve {
                try FileManager.default.removeItem(atPath: filePath)
            }
            
            Matrix.logger.debug("Trying to open database at [\(filePath)]")
            if let queue = try? DatabaseQueue(path: filePath) {
                self.dbQueue = queue
            } else {
                Matrix.logger.debug("Failed to open database.  Maybe it doesn't exist?  Trying to create the path now...")
                let url = URL(fileURLWithPath: dirPath)
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                Matrix.logger.debug("Now trying again to create database")
                self.dbQueue = try DatabaseQueue(path: filePath)
            }
        }
        
        self.migrator = DatabaseMigrator()
        try runMigrations()
        
    }
    
    public func close() async throws {
        try dbQueue.close()
    }
    
    // MARK: Events
    
    public func saveTimeline(events: [ClientEvent]) async throws {
        try await dbQueue.write { db in
            for event in events {
                try event.save(db)
            }
        }
    }
    
    public func saveTimeline(events: [ClientEventWithoutRoomId], in roomId: RoomId) async throws {
        let clientEvents = try events.map {
            try ClientEvent(from: $0, roomId: roomId)
        }
        try await dbQueue.write { db in
            for clientEvent in clientEvents {
                try clientEvent.save(db)
            }
        }
    }
    
    public func loadTimeline(for roomId: RoomId,
                             limit: Int = 25, offset: Int? = nil
    ) async throws -> [ClientEvent] {
        let roomIdColumn = ClientEvent.Columns.roomId
        let timestampColumn = ClientEvent.Columns.originServerTS
        let events = try await dbQueue.read { db -> [ClientEvent] in
            try ClientEvent
                .filter(roomIdColumn == "\(roomId)")
                .order(timestampColumn.desc)
                .limit(limit, offset: offset)
                .fetchAll(db)
        }
        return events
    }
    
    public func loadEvents(for roomId: RoomId, of types: [String],
                           limit: Int = 25, offset: Int? = nil
    ) async throws -> [ClientEvent] {
        let roomIdColumn = ClientEvent.Columns.roomId
        let typeColumn = ClientEvent.Columns.type
        let timestampColumn = ClientEvent.Columns.originServerTS
        
        let typeStrings = types.map { "\($0)" }
        
        let events = try await dbQueue.read { db -> [ClientEvent] in
            try ClientEvent
                .filter(roomIdColumn == "\(roomId)")
                .filter(typeStrings.contains(typeColumn))
                .order(timestampColumn.desc)
                .limit(limit, offset: offset)
                .fetchAll(db)
        }
        return events
    }
    
    public func loadState(for roomId: RoomId,
                          limit: Int = 0,
                          offset: Int? = nil
    ) async throws -> [ClientEventWithoutRoomId] {
        let roomIdColumn = ClientEvent.Columns.roomId
        // let stateKeyColumn = ClientEvent.Columns.stateKey
        let timestampColumn = ClientEvent.Columns.originServerTS
        let table = Table<ClientEvent>("state")
        let baseRequest = table.filter(roomIdColumn == "\(roomId)")
                               .order(timestampColumn.desc)
        let request = limit > 0 ? baseRequest.limit(limit, offset: offset) : baseRequest
        let clientEvents = try await dbQueue.read { db -> [ClientEvent] in
            try request.fetchAll(db)
        }
        let events = clientEvents.compactMap {
            try? ClientEventWithoutRoomId(content: $0.content,
                                          eventId: $0.eventId,
                                          originServerTS: $0.originServerTS,
                                          sender: $0.sender,
                                          stateKey: $0.stateKey,
                                          type: $0.type)
        }
        return events
    }
    
    public func loadEssentialState(for roomId: RoomId) async throws -> [ClientEventWithoutRoomId] {
        let roomIdColumn = ClientEvent.Columns.roomId
        let eventTypes = [
            M_ROOM_CREATE,
            M_ROOM_TOMBSTONE,
            M_ROOM_ENCRYPTION,
            M_ROOM_POWER_LEVELS,
            M_ROOM_NAME,
            M_ROOM_AVATAR,
            M_ROOM_TOPIC,
            M_SPACE_CHILD,
            M_SPACE_PARENT,
        ]
        let table = Table<ClientEvent>("state")
        let request = table.filter(sql: "room_id='\(roomId)' AND type IN (\(eventTypes.map({"'\($0)'"}).joined(separator: ",")))")
        let events = try await dbQueue.read { db in
            try request.fetchAll(db)
        }
        return events.compactMap {
            try? ClientEventWithoutRoomId(content: $0.content,
                                          eventId: $0.eventId,
                                          originServerTS: $0.originServerTS,
                                          sender: $0.sender,
                                          stateKey: $0.stateKey,
                                          type: $0.type)
        }
    }
    
    public func saveState(events: [ClientEventWithoutRoomId], in roomId: RoomId) async throws {
        let stateEvents = events.compactMap { event in
            try? StateEventRecord(from: event, in: roomId)
        }
        try await dbQueue.write { db in
            for stateEvent in stateEvents {
                try stateEvent.save(db)
            }
        }
    }
    
    public func saveState(events: [ClientEvent]) async throws {
        let stateEvents = events.compactMap { event in
            try? StateEventRecord(from: event)
        }
        try await dbQueue.write { db in
            for stateEvent in stateEvents {
                try stateEvent.save(db)
            }
        }
    }
    
    public func saveStrippedState(events: [StrippedStateEvent], roomId: RoomId) async throws {
        try await dbQueue.write { db in
            for event in events {
                let record = StrippedStateEventRecord(from: event, in: roomId)
                try record.save(db)
            }
        }
    }
    
    public func loadStrippedState(for roomId: RoomId) async throws -> [StrippedStateEvent] {
        let roomIdColumn = StrippedStateEventRecord.Columns.roomId
        let records = try await dbQueue.read { db in
            try StrippedStateEventRecord
                    .filter(roomIdColumn == "\(roomId)")
                    .fetchAll(db)
        }
        let events = records.map {
            StrippedStateEvent(sender: $0.sender,
                               stateKey: $0.stateKey,
                               type: $0.type,
                               content: $0.content)
        }
        return events
    }
    
    // MARK: Rooms
    
    public func getRecentRoomIds(limit: Int=20, offset: Int? = nil) async throws -> [RoomId] {
        let timestampColumn = RoomRecord.Columns.timestamp
        let records = try await dbQueue.read { db -> [RoomRecord] in
            try RoomRecord
                .order(timestampColumn.desc)
                .limit(limit, offset: offset)
                .fetchAll(db)
        }
        return records.map { $0.roomId }
    }
    
    public func getRoomIds(of roomType: String, limit: Int=20, offset: Int?=nil) async throws -> [RoomId] {
        let eventTypeColumn = StateEventRecord.Columns.type
        let stateKeyColumn = StateEventRecord.Columns.stateKey
        let records = try await dbQueue.read { db in
            let baseQuery = StateEventRecord
                .filter(eventTypeColumn == M_ROOM_CREATE)
                .filter(stateKeyColumn == roomType)
            let query = limit > 0 ? baseQuery.limit(limit, offset: offset) : baseQuery
            return try query.fetchAll(db)
        }
        let roomIds = records.map { $0.roomId }
        return roomIds
    }
    
    public func getJoinedRoomIds(for userId: UserId, limit: Int=20, offset: Int?=nil) async throws -> [RoomId] {
        let eventTypeColumn = StateEventRecord.Columns.type
        let stateKeyColumn = StateEventRecord.Columns.stateKey
        let records = try await dbQueue.read { db in
            let baseQuery = StateEventRecord
                .filter(eventTypeColumn == M_ROOM_MEMBER)
                .filter(stateKeyColumn == "\(userId)")
            let query = limit > 0 ? baseQuery.limit(limit, offset: offset) : baseQuery
            return try query.fetchAll(db)
        }
        let roomIds = records.compactMap { record -> RoomId? in
            // Is the membership state 'join' ???
            guard let content = record.content as? RoomMemberContent,
                  content.membership == .join
            else {
                return nil
            }
            return record.roomId
        }
        return roomIds
    }
    
    /* // Moving this up into the Session layer
    public func loadRoom(_ roomId: RoomId) async throws -> Matrix.Room? {
        let stateEvents = try await loadState(for: roomId)
        return try? Matrix.Room(roomId: roomId, session: self.session, initialState: stateEvents)
    }
    */
    
    public func saveRoomTimestamp(roomId: RoomId,
                                  state: RoomMemberContent.Membership,
                                  timestamp: UInt64
    ) async throws {
        try await dbQueue.write { db in
            let rec = RoomRecord(roomId: roomId, joinState: state, timestamp: timestamp)
            try rec.save(db)
        }
    }
    
    
    // MARK: User profiles
    
    public func loadProfileItem(_ item: String, for userId: UserId) async throws -> String? {
        let userIdColumn = UserProfileRecord.Columns.userId
        let keyColumn = UserProfileRecord.Columns.key
        let record = try await dbQueue.read { db -> UserProfileRecord? in
            try UserProfileRecord
                .filter(userIdColumn == "\(userId)")
                .filter(keyColumn == item)
                .fetchOne(db)
        }
        return record?.value
    }
    
    public func loadDisplayname(for userId: UserId) async throws -> String? {
        try await loadProfileItem("displayname", for: userId)
    }
    
    public func loadAvatarUrl(for userId: UserId) async throws -> MXC? {
        guard let string = try await loadProfileItem("avatar_url", for: userId)
        else {
            return nil
        }
        return MXC(string)
    }
    
    public func loadStatusMessage(for userId: UserId) async throws -> String? {
        try await loadProfileItem("status", for: userId)
    }
    
    public func saveProfileItem(_ item: String, _ value: String, for userId: UserId) async throws {
        let record = UserProfileRecord(userId: userId, key: item, value: value)
        try await dbQueue.write { db in
            try record.save(db)
        }
    }
    
    public func saveDisplayname(_ name: String, for userId: UserId) async throws {
        try await saveProfileItem("displayname", name, for: userId)
    }
    
    public func saveAvatarUrl(_ url: MXC, for userId: UserId) async throws {
        try await saveProfileItem("avatar_url", url.description, for: userId)
    }
    
    public func saveStatusMessage(_ msg: String, for userId: UserId) async throws {
        try await saveProfileItem("status", msg, for: userId)
    }
    
    // MARK: Account data
    
    public func loadAccountData(for userId: UserId, of type: String, in roomId: RoomId? = nil) async throws -> Codable {
        throw Matrix.Error("Not Implemented")
    }
}