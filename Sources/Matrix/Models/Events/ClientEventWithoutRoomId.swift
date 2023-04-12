//
//  ClientEventWithoutRoomId.swift
//
//
//  Created by Charles Wright on 5/19/22.
//

import Foundation
import AnyCodable

// Used for the /sync API
// Normally this would be defined in-line in the only place where it's used,
// but since it's much bigger than most random data-transfer object types,
// this one gets its own file.
public struct ClientEventWithoutRoomId: Matrix.Event, Codable {
    public let eventId: String
    public let originServerTS: UInt64
    //public let roomId: String
    public let sender: UserId
    public let stateKey: String?
    public let type: String
    public let content: Codable
    public let unsigned: UnsignedData?
    
    public enum CodingKeys: String, CodingKey {
        case content
        case eventId = "event_id"
        case originServerTS = "origin_server_ts"
        //case roomId = "room_id"
        case sender
        case stateKey = "state_key"
        case type
        case unsigned
    }
    
    public init(content: Codable, eventId: String, originServerTS: UInt64, sender: UserId,
                stateKey: String? = nil, type: String,
                unsigned: UnsignedData? = nil) throws {
        self.content = content
        self.eventId = eventId
        self.originServerTS = originServerTS
        self.sender = sender
        self.stateKey = stateKey
        self.type = type
        self.unsigned = unsigned
    }
    
    public init(from: ClientEvent) throws {
        try self.init(content: from.content, eventId: from.eventId,
                      originServerTS: from.originServerTS,
                      sender: from.sender, type: from.type,
                      unsigned: from.unsigned)
    }
    
    public init(from decoder: Decoder) throws {
        //Matrix.logger.debug("Decoding ClientEventWithoutRoomId")
        let container = try decoder.container(keyedBy: CodingKeys.self)
        
        let eventId = try container.decode(String.self, forKey: .eventId)
        //Matrix.logger.debug("  eventId = \(eventId)")
        self.eventId = eventId
        
        self.originServerTS = try container.decode(UInt64.self, forKey: .originServerTS)
        //self.roomId = try container.decode(String.self, forKey: .roomId)
        self.sender = try container.decode(UserId.self, forKey: .sender)
        self.stateKey = try container.decodeIfPresent(String.self, forKey: .stateKey)
        
        let type = try container.decode(String.self, forKey: .type)
        //Matrix.logger.debug("  type = \(type)")
        self.type = type
        
        self.unsigned = try container.decodeIfPresent(UnsignedData.self, forKey: .unsigned)
         
        self.content = try Matrix.decodeEventContent(of: self.type, from: decoder)
        //Matrix.logger.debug("  done with event \(eventId)")
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(eventId, forKey: .eventId)
        try container.encode(originServerTS, forKey: .originServerTS)
        try container.encode(sender, forKey: .sender)
        try container.encodeIfPresent(stateKey, forKey: .stateKey)
        try container.encode(type, forKey: .type)
        try container.encodeIfPresent(unsigned, forKey: .unsigned)
        try container.encode(AnyCodable(content), forKey: .content)
    }
}

extension ClientEventWithoutRoomId: Equatable {
    public static func == (lhs: ClientEventWithoutRoomId, rhs: ClientEventWithoutRoomId) -> Bool {
        lhs.eventId == rhs.eventId
    }
}

extension ClientEventWithoutRoomId: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(eventId)
    }    
}

extension ClientEventWithoutRoomId: Comparable {
    public static func < (lhs: ClientEventWithoutRoomId, rhs: ClientEventWithoutRoomId) -> Bool {
        lhs.originServerTS < rhs.originServerTS
    }
}
