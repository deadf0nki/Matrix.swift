//
//  Matrix+Session.swift
//  
//
//  Created by Charles Wright on 12/5/22.
//

import Foundation

#if !os(macOS)
import UIKit
#else
import AppKit
#endif

extension Matrix {
    public class Session: Matrix.Client, ObservableObject {
        @Published public var displayName: String?
        @Published public var avatarUrl: URL?
        @Published public var avatar: Matrix.NativeImage?
        @Published public var statusMessage: String?
        
        // cvw: Leaving these as comments for now, as they require us to define even more types
        //@Published public var device: MatrixDevice
        
        @Published public var rooms: [RoomId: Matrix.Room]
        @Published public var invitations: [RoomId: Matrix.InvitedRoom]
        
        // cvw: Stuff that we need to add, but haven't got to yet
        public var accountData: [Matrix.AccountDataType: Codable]

        // Need some private stuff that outside callers can't see
        private var dataStore: DataStore?
        private var syncRequestTask: Task<String?,Swift.Error>? // FIXME Use a TaskGroup to make this subordinate to the backgroundSyncTask
        private var syncToken: String? = nil
        private var syncRequestTimeout: Int = 30_000
        private var keepSyncing: Bool
        private var syncDelayNS: UInt64 = 30_000_000_000
        private var backgroundSyncTask: Task<UInt,Swift.Error>? // FIXME use a TaskGroup
        
        // FIXME: Derive this from our account data???
        // The type is `m.ignored_user_list` https://spec.matrix.org/v1.5/client-server-api/#mignored_user_list
        private var ignoreUserIds: [UserId] {
            guard let content = self.accountData[.mIgnoredUserList] as? IgnoredUserListContent
            else {
                return []
            }
            return content.ignoredUsers
        }

        // We need to use the Matrix 'recovery' feature to back up crypto keys etc
        // This saves us from struggling with UISI errors and unverified devices
        private var recoverySecretKey: Data?
        private var recoveryTimestamp: Date?
        
        public init(creds: Credentials,
                    syncToken: String? = nil, startSyncing: Bool = true,
                    displayname: String? = nil, avatarUrl: MXC? = nil, statusMessage: String? = nil,
                    recoverySecretKey: Data? = nil, recoveryTimestamp: Data? = nil,
                    storageType: StorageType = .persistent(preserve: true)
        ) async throws {
            self.rooms = [:]
            self.invitations = [:]
            self.accountData = [:]
                        
            self.keepSyncing = startSyncing
            // Initialize the sync tasks to nil so we can run super.init()
            self.syncRequestTask = nil
            self.backgroundSyncTask = nil
            
            // Another Swift annoyance.  It's hard (impossible) to have a hierarchy of objects that are all initialized together.
            // So we have to make the DataStore an optional in order for it to get a pointer to us.
            // And here we initialize it to nil so we can call super.init()
            self.dataStore = nil
            
            try super.init(creds: creds)

            // Phase 1 init is done -- Now we can reference `self`
            
            self.dataStore = try await GRDBDataStore(userId: creds.userId, type: storageType)

            
            // Ok now we're initialized as a valid Matrix.Client (super class)
            // Are we supposed to start syncing?
            if startSyncing {
                backgroundSyncTask = .init(priority: .background) {
                    var count: UInt = 0
                    while keepSyncing {
                        let token = try await sync()
                        count += 1
                    }
                    return count
                }
            }
        }
        
        // MARK: Sync
        // https://spec.matrix.org/v1.2/client-server-api/#get_matrixclientv3sync
        @Sendable
        private func syncRequestTaskOperation() async throws -> String? {
            var url = "/_matrix/client/v3/sync"
            var params = [
                "timeout": "\(syncRequestTimeout)",
            ]
            if let token = syncToken {
                params["since"] = token
            }
            print("/sync:\tCalling \(url)")
            let (data, response) = try await self.call(method: "GET", path: url, params: params)
            
            //let rawDataString = String(data: data, encoding: .utf8)
            //print("\n\n\(rawDataString!)\n\n")
            
            guard response.statusCode == 200 else {
                print("ERROR: /sync got HTTP \(response.statusCode) \(response.description)")
                self.syncRequestTask = nil
                //return self.syncToken
                return nil
            }
            
            let decoder = JSONDecoder()
            //decoder.keyDecodingStrategy = .convertFromSnakeCase
            guard let responseBody = try? decoder.decode(SyncResponseBody.self, from: data)
            else {
                self.syncRequestTask = nil
                let msg = "Could not decode /sync response"
                logger.error("\(msg)")
                throw Matrix.Error(msg)
            }
            
            // Process the sync response, updating local state if necessary
            // First thing to check: Did our sync token actually change?
            // Because if not, then we've already seen everything in this update
            if responseBody.nextBatch == self.syncToken {
                logger.debug("/sync:\tToken didn't change; Therefore no updates; Doing nothing")
                self.syncRequestTask = nil
                return syncToken
            }
            
            // Handle invites
            if let invitedRoomsDict = responseBody.rooms?.invite {
                print("/sync:\t\(invitedRoomsDict.count) invited rooms")
                for (roomId, info) in invitedRoomsDict {
                    print("/sync:\tFound invited room \(roomId)")
                    guard let events = info.inviteState?.events
                    else {
                        continue
                    }
                    
                    if let store = self.dataStore {
                        try await store.saveStrippedState(events: events, roomId: roomId)
                    }
                    
                    //if self.invitations[roomId] == nil {
                        let room = try InvitedRoom(session: self, roomId: roomId, stateEvents: events)
                        self.invitations[roomId] = room
                    //}
                }
            } else {
                print("/sync:\tNo invited rooms")
            }
            
            // Handle rooms where we're already joined
            if let joinedRoomsDict = responseBody.rooms?.join {
                print("/sync:\t\(joinedRoomsDict.count) joined rooms")
                for (roomId, info) in joinedRoomsDict {
                    print("/sync:\tFound joined room \(roomId)")
                    let stateEvents = info.state?.events ?? []
                    let timelineEvents = info.timeline?.events ?? []
                    let timelineStateEvents = timelineEvents.filter {
                        $0.stateKey != nil
                    }
                    
                    let roomTimestamp = timelineEvents.map { $0.originServerTS }.max()
                    
                    if let store = self.dataStore {
                        // First save the state events from before this timeline
                        // Then save the state events that came in during the timeline
                        // We do both in a single call so it all happens in one transaction in the database
                        let allStateEvents = stateEvents + timelineStateEvents
                        if !allStateEvents.isEmpty {
                            print("/sync:\tSaving state for room \(roomId)")
                            try await store.saveState(events: allStateEvents, in: roomId)
                        }
                        if !timelineEvents.isEmpty {
                            // Save the whole timeline so it can be displayed later
                            print("/sync:\tSaving timeline for room \(roomId)")
                            try await store.saveTimeline(events: timelineEvents, in: roomId)
                        }
                        
                        // Save the room summary with the latest timestamp
                        if let timestamp = roomTimestamp {
                            print("/sync:\tSaving timestamp for room \(roomId)")
                            try await store.saveRoomTimestamp(roomId: roomId, state: .join, timestamp: timestamp)
                        } else {
                            print("/sync:\tNo update to timestamp for room \(roomId)")
                        }
                    }

                    if let room = self.rooms[roomId] {
                        print("\tWe know this room already")
                        print("\t\(stateEvents.count) new state events")
                        print("\t\(timelineEvents.count) new timeline events")

                        // Update the room with the latest data from `info`
                        try await room.updateState(from: stateEvents)
                        try await room.updateTimeline(from: timelineEvents)
                        
                        if let unread = info.unreadNotifications {
                            print("\t\(unread.notificationCount) notifications")
                            print("\t\(unread.highlightCount) highlights")
                            room.notificationCount = unread.notificationCount
                            room.highlightCount = unread.highlightCount
                        }
                        
                    } else {
                        // Clearly the room is no longer in the 'invited' state
                        invitations.removeValue(forKey: roomId)
                        // FIXME Also purge any stripped state that we had been storing for this room
                        
                        if let room = try? Matrix.Room(roomId: roomId, session: self, initialState: stateEvents+timelineStateEvents, initialTimeline: timelineEvents) {
                            print("/sync:\tInitialized new Room object for \(roomId)")
                            await MainActor.run {
                                self.rooms[roomId] = room
                            }
                        } else {
                            print("/sync:\tError: Failed to initialize Room object for \(roomId)")
                        }
                    }
                    

                }
            } else {
                print("/sync:\tNo joined rooms")
            }
            
            // Handle rooms that we've left
            if let leftRoomsDict = responseBody.rooms?.leave {
                print("/sync:\t\(leftRoomsDict.count) left rooms")
                for (roomId, info) in leftRoomsDict {
                    print("/sync:\tFound left room \(roomId)")
                    // TODO: What should we do here?
                    // For now, just make sure these rooms are taken out of the other lists
                    invitations.removeValue(forKey: roomId)
                    rooms.removeValue(forKey: roomId)
                }
            } else {
                print("/sync:\tNo left rooms")
            }
            
            // FIXME: Do something with AccountData
            
            // FIXME: Handle to-device messages

            print("/sync:\tUpdating sync token...  awaiting MainActor")
            await MainActor.run {
                print("/sync:\tMainActor updating sync token to \(responseBody.nextBatch)")
                self.syncToken = responseBody.nextBatch
            }

            print("/sync:\tDone!")
            self.syncRequestTask = nil
            return responseBody.nextBatch
        
        }
        
        public func sync() async throws -> String? {
            print("/sync:\tStarting sync()")
            
            /*
            // FIXME: Use a TaskGroup
            syncRequestTask = syncRequestTask ?? .init(priority: .background, operation: syncRequestTaskOperation)
            
            guard let task = syncRequestTask else {
                print("Error: /sync Failed to launch sync request task")
                return nil
            }
            print("/sync:\tAwaiting result of sync task")
            return try await task.value
            */
            
            if let task = syncRequestTask {
                return try await task.value
            } else {
                syncRequestTask = .init(priority: .background, operation: syncRequestTaskOperation)
                return try await syncRequestTask?.value
            }
        }

        
        public func pause() async throws {
            // pause() doesn't actually make any API calls
            // It just tells our own local sync task to take a break
            throw Matrix.Error("Not implemented yet")
        }
        
        public func close() async throws {
            // close() is like pause; it doesn't make any API calls
            // It just tells our local sync task to shut down
            throw Matrix.Error("Not implemented yet")
        }
        
        public func createRecovery(privateKey: Data) async throws {
            throw Matrix.Error("Not implemented yet")
        }
        
        public func deleteRecovery() async throws {
            throw Matrix.Error("Not implemented yet")
        }
        
        public func whoAmI() async throws -> UserId {
            return self.creds.userId
        }
        
        public override func getRoomStateEvents(roomId: RoomId) async throws -> [ClientEventWithoutRoomId] {
            let events = try await super.getRoomStateEvents(roomId: roomId)
            if let store = self.dataStore {
                try await store.saveState(events: events, in: roomId)
            }
            if let room = self.rooms[roomId] {
                try await room.updateState(from: events)
            }
            return events
        }
        
        public func getRoom(roomId: RoomId) async throws -> Matrix.Room? {
            if let existingRoom = self.rooms[roomId] {
                return existingRoom
            }
            
            // Apparently we don't already have a Room object for this one
            // Let's see if we can find the necessary data to construct it
            
            // Do we have this room in our data store?
            if let store = self.dataStore {
                let events = try await store.loadEssentialState(for: roomId)
                if events.count > 0 {
                    if let room = try? Matrix.Room(roomId: roomId, session: self, initialState: events) {
                        await MainActor.run {
                            self.rooms[roomId] = room
                        }
                        return room
                    }
                }
            }
            
            // Ok we didn't have the room state cached locally
            // Maybe the server knows about this room?
            let events = try await getRoomStateEvents(roomId: roomId)
            if let room = try? Matrix.Room(roomId: roomId, session: self, initialState: events, initialTimeline: []) {
                await MainActor.run {
                    self.rooms[roomId] = room
                }
                return room
            }
            
            // Looks like we got nothing
            return nil
        }
        
        public func getInvitedRoom(roomId: RoomId) async throws -> Matrix.InvitedRoom? {
            if let room = self.invitations[roomId] {
                return room
            }
            
            if let store = self.dataStore {
                let events = try await store.loadStrippedState(for: roomId)
                if let room = try? Matrix.InvitedRoom(session: self, roomId: roomId, stateEvents: events) {
                    await MainActor.run {
                        self.invitations[roomId] = room
                    }
                    return room
                }
            }
            
            // Whoops, looks like we couldn't find what we needed
            return nil
        }
    }
}
