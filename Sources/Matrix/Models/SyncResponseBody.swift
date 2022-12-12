//
//  SyncResponseBody.swift
//  
//
//  Created by Charles Wright on 12/8/22.
//

import Foundation

extension Matrix {
    
    struct AccountDataEvent: Decodable {
        var type: AccountDataType
        var content: Decodable
        
        enum CodingKeys: String, CodingKey {
            case type
            case content
        }
        
        init(from decoder: Decoder) throws {
            print("Decoding account data event")
            let container = try decoder.container(keyedBy: CodingKeys.self)
            
            self.type = try container.decode(AccountDataType.self, forKey: .type)
            print("\tGot type = \(self.type)")
            self.content = try Matrix.decodeAccountData(of: self.type, from: decoder)
        }
    }
    
    struct SyncResponseBody: Decodable {
        struct MinimalEventsContainer: Decodable {
            var events: [MinimalEvent]?
        }
        
        struct AccountData: Decodable {
            // Here we can't use the MinimalEvent type that we already defined
            // Because Matrix is batshit and puts crazy stuff into these `type`s
            var events: [AccountDataEvent]?
        }
        
        typealias Presence =  MinimalEventsContainer
        typealias Ephemeral = MinimalEventsContainer
        
        struct Rooms: Decodable {
            var invite: [RoomId: InvitedRoomSyncInfo]?
            var join: [RoomId: JoinedRoomSyncInfo]?
            var knock: [RoomId: KnockedRoomSyncInfo]?
            var leave: [RoomId: LeftRoomSyncInfo]?
        }
        
        struct InvitedRoomSyncInfo: Decodable {
            struct InviteState: Decodable {
                var events: [StrippedStateEvent]?
            }
            var inviteState: InviteState?
            
            enum CodingKeys: String, CodingKey {
                case inviteState = "invite_state"
            }
        }
        
        struct StateEventsContainer: Decodable {
            var events: [ClientEventWithoutRoomId]?
        }
        
        struct Timeline: Decodable {
            var events: [ClientEventWithoutRoomId]
            var limited: Bool?
            var prevBatch: String?
            
            enum CodingKeys: String, CodingKey {
                case events
                case limited
                case prevBatch = "prev_batch"
            }
        }
        
        struct JoinedRoomSyncInfo: Decodable {
            struct RoomSummary: Decodable {
                var heroes: [UserId]?
                var invitedMemberCount: Int?
                var joinedMemberCount: Int?
                
                enum CodingKeys: String, CodingKey {
                    case heroes = "m.heroes"
                    case invitedMemberCount = "m.invited_member_count"
                    case joinedMemberCount = "m.joined_member_count"
                }
            }
            struct UnreadNotificationCounts: Decodable {
                // FIXME: The spec gives the type for these as "Highlighted notification count" and "Total notification count" -- Hopefully it's a typo, and those should have been in the description column instead
                var highlightCount: Int
                var notificationCount: Int
                
                enum CodingKeys: String, CodingKey {
                    case highlightCount = "highlight_count"
                    case notificationCount = "notification_count"
                }
            }
            var accountData: AccountData?
            var ephemeral: Ephemeral?
            var state: StateEventsContainer?
            var summary: RoomSummary?
            var timeline: Timeline?
            var unreadNotifications: UnreadNotificationCounts?
            
            enum CodingKeys: String, CodingKey {
                case accountData = "account_data"
                case ephemeral
                case state
                case summary
                case timeline
                case unreadNotifications = "unread_notifications"
            }
        }
        
        struct KnockedRoomSyncInfo: Decodable {
            struct KnockState: Decodable {
                var events: [StrippedStateEvent]
            }
            var knockState: KnockState?
            
            enum CodingKeys: String, CodingKey {
                case knockState = "knock_state"
            }
        }
        
        struct LeftRoomSyncInfo: Decodable {
            var accountData: AccountData?
            var state: StateEventsContainer?
            var timeline: Timeline?
            
            enum CodingKeys: String, CodingKey {
                case accountData = "account_data"
                case state
                case timeline
            }
        }
        
        struct ToDevice: Decodable {
            var events: [ToDeviceEvent]
        }
        
        struct DeviceLists: Decodable {
            var changed: [UserId]?
            var left: [UserId]?
        }
        
        typealias OneTimeKeysCount = [String : Int]
        
        var accountData: AccountData?
        var deviceLists: DeviceLists?
        var deviceOneTimeKeysCount: OneTimeKeysCount?
        var nextBatch: String
        var presence: Presence?
        var rooms: Rooms?
        var toDevice: ToDevice?
        
        enum CodingKeys: String, CodingKey {
            case accountData = "account_data"
            case deviceLists = "device_lists"
            case deviceOneTimeKeysCount = "device_one_time_keys_count"
            case nextBatch = "next_batch"
            case presence
            case rooms
            case toDevice = "to_device"
        }
        
        init(from decoder: Decoder) throws {
            print("Decoding /sync response")
            let container = try decoder.container(keyedBy: CodingKeys.self)
            
            print("\tAccount data")
            self.accountData = try container.decodeIfPresent(AccountData.self, forKey: .accountData)
            
            print("\tDevice lists")
            self.deviceLists = try container.decodeIfPresent(DeviceLists.self, forKey: .deviceLists)
            
            print("\tDevice one-time keys count")
            self.deviceOneTimeKeysCount = try container.decodeIfPresent(OneTimeKeysCount.self, forKey: .deviceOneTimeKeysCount)
            
            print("\tNext batch")
            self.nextBatch = try container.decode(String.self, forKey: .nextBatch)
            
            print("\tPresence")
            self.presence = try container.decodeIfPresent(Presence.self, forKey: .presence)
            
            print("\tRooms")
            self.rooms = try container.decodeIfPresent(Rooms.self, forKey: .rooms)
            
            print("\tTo-Device")
            self.toDevice = try container.decodeIfPresent(ToDevice.self, forKey: .toDevice)
        }
    }
}