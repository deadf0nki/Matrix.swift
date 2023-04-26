//
//  Matrix+Message.swift
//  
//
//  Created by Charles Wright on 3/20/23.
//

import Foundation

extension Matrix {
    public class Message: ObservableObject, Identifiable {
        @Published private(set) public var event: ClientEventWithoutRoomId
        private(set) public var encryptedEvent: ClientEventWithoutRoomId?
        public var room: Room
        public var sender: User
        
        @Published public var thumbnail: NativeImage?
        @Published private(set) public var reactions: [String:Set<UserId>]
        @Published private(set) public var replies: [Message]
        
        public var isEncrypted: Bool
        
        private var fetchThumbnailTask: Task<Void,Swift.Error>?
        
        public init(event: ClientEventWithoutRoomId, room: Room) {
            self.event = event
            self.room = room
            self.sender = room.session.getUser(userId: event.sender)
            self.reactions = [:]
            self.replies = []
            
            // Initialize the thumbnail
            if let messageContent = event.content as? Matrix.MessageContent {
                
                // Try thumbhash first
                if let thumbhashString = messageContent.thumbhash,
                   let thumbhashData = Data(base64Encoded: thumbhashString)
                {
                    self.thumbnail = thumbHashToImage(hash: thumbhashData)
                } else if let blurhash = messageContent.blurhash,
                          let thumbnailInfo = messageContent.thumbnail_info
                {
                    // Initialize from the blurhash
                    self.thumbnail = .init(blurHash: blurhash, size: CGSize(width: thumbnailInfo.w, height: thumbnailInfo.h))
                } else {
                    // No thumbhash, no blurhash, so we have nothing until we can fetch the real image
                    self.thumbnail = nil
                }
            }
            
            if event.type == M_ROOM_ENCRYPTED {
                self.isEncrypted = true
                self.encryptedEvent = event
                
                // Now try to decrypt
                let _ = Task {
                    try await decrypt()
                }
            } else {
                self.isEncrypted = false
                self.encryptedEvent = nil
            }
            
            // Swift Phase 1 init is complete ///////////////////////////////////////////////
            
            // Initialize reactions
            if let allReactions = room.relations[M_REACTION]?[event.eventId] {
                for reaction in allReactions {
                    if let content = reaction.content as? ReactionContent,
                       content.relationType == M_REACTION,
                       content.relatedEventId == event.eventId,
                       let key = content.relatesTo.key
                    {
                        // Ok, this is one we can use
                        if self.reactions[key] == nil {
                            self.reactions[key] = [reaction.sender.userId]
                        } else {
                            self.reactions[key]!.insert(reaction.sender.userId)
                        }
                    }
                }
            }
        }
        
        public var eventId: EventId {
            event.eventId
        }
        
        public var id: String {
            "\(eventId)"
        }
        
        public var roomId: RoomId {
            room.roomId
        }
        
        public var type: String {
            event.type
        }
        
        public var stateKey: String? {
            event.stateKey
        }
        
        public var content: Codable? {
            event.content
        }
        
        public var mimetype: String? {
            if let content = self.content as? MessageContent {
                return content.mimetype
            } else {
                return nil
            }
        }
        
        public lazy var timestamp: Date = Date(timeIntervalSince1970: TimeInterval(event.originServerTS)/1000.0)
        
        public var relatedEventId: EventId? {
            if let content = event.content as? RelatedEventContent {
                return content.relatedEventId
            }
            return nil
        }
        
        public var relationType: String? {
            if let content = event.content as? RelatedEventContent {
                return content.relationType
            }
            return nil
        }
        
        public var replyToEventId: EventId? {
            if let content = event.content as? RelatedEventContent {
                return content.replyToEventId
            }
            return nil
        }
        
        public var threadId: EventId? {
            if self.relationType == M_THREAD {
                return self.relatedEventId
            }
            return nil
        }
        
        // https://github.com/uhoreg/matrix-doc/blob/aggregations-reactions/proposals/2677-reactions.md
        public func addReaction(event: ClientEventWithoutRoomId) async {
            Matrix.logger.debug("Adding reaction message \(event.eventId) to message \(self.eventId)")
            guard let content = event.content as? ReactionContent,
                  content.relatesTo.eventId == self.eventId,
                  let key = content.relatesTo.key
            else {
                Matrix.logger.error("Not adding reaction: Couldn't parse reaction message content")
                return
            }
            await MainActor.run {
                if reactions[key] == nil {
                    reactions[key] = [event.sender]
                } else {
                    reactions[key]!.insert(event.sender)
                }
            }
            Matrix.logger.debug("Message \(self.eventId) now has \(self.reactions.keys.count) distinct reactions")
        }
        
        public func addReaction(message: Message) async {
            await self.addReaction(event: message.event)
        }
        
        public func addReply(message: Message) async {
            Matrix.logger.debug("Adding reply message \(message.eventId) to message \(self.eventId)")
            if message.replyToEventId == self.eventId && !self.replies.contains(message) {
                await MainActor.run {
                    self.replies.append(message)
                }
            }
            Matrix.logger.debug("Message \(self.eventId) now has \(self.replies.count) replies")
        }
        
        public func decrypt() async throws {
            guard self.event.type == M_ROOM_ENCRYPTED
            else {
                // Already decrypted!
                return
            }
            
            if let decryptedEvent = try? self.room.session.decryptMessageEvent(self.event, in: self.room.roomId) {
                await MainActor.run {
                    self.event = decryptedEvent
                }
                
                // Now we also need to update our thumbnail
                // Look for a placeholder
                if let messageContent = event.content as? Matrix.MessageContent {
                    if let thumbhashString = messageContent.thumbhash,
                       let thumbhashData = Data(base64Encoded: thumbhashString)
                    {
                        // Use the thumbhash if it's available
                        self.thumbnail = thumbHashToImage(hash: thumbhashData)
                    } else if let blurhash = messageContent.blurhash,
                              let thumbnailInfo = messageContent.thumbnail_info
                    {
                        // Fall back to blurhash
                        self.thumbnail = .init(blurHash: blurhash, size: CGSize(width: thumbnailInfo.w, height: thumbnailInfo.h))
                    } else {
                        self.thumbnail = nil
                    }

                }
                
                // Thumbnail
                try await fetchThumbnail()
            }
        }
        
        public func fetchThumbnail() async throws {
            guard event.type == M_ROOM_MESSAGE,
                  let content = event.content as? MessageContent
            else {
                return
            }
            
            if let task = self.fetchThumbnailTask {
                try await task.value
                return
            }
            
            
            self.fetchThumbnailTask = Task {
                guard let info = content.thumbnail_info
                else {
                    self.fetchThumbnailTask = nil
                    return
                }
                
                if let encryptedFile = content.thumbnail_file {
                    guard let data = try? await room.session.downloadAndDecryptData(encryptedFile)
                    else {
                        self.fetchThumbnailTask = nil
                        return
                    }
                    let image = NativeImage(data: data)
                    await MainActor.run {
                        self.thumbnail = image
                    }
                    self.fetchThumbnailTask = nil
                    return
                }
                
                if let mxc = content.thumbnail_url {
                    guard let data = try? await room.session.downloadData(mxc: mxc)
                    else {
                        self.fetchThumbnailTask = nil
                        return
                    }
                    let image = NativeImage(data: data)
                    await MainActor.run {
                        self.thumbnail = image
                    }
                }
                self.fetchThumbnailTask = nil
            }
        }
        
        public func sendReaction(_ reaction: String) async throws -> EventId {
            try await self.room.addReaction(reaction, to: eventId)
        }
    }
}

extension Matrix.Message: Equatable {
    public static func == (lhs: Matrix.Message, rhs: Matrix.Message) -> Bool {
        lhs.eventId == rhs.eventId && lhs.type == rhs.type
    }
}

extension Matrix.Message: Hashable {
    public func hash(into hasher: inout Hasher) {
        self.event.hash(into: &hasher)
    }
}
