//
//  Matrix+User.swift
//  
//
//  Created by Charles Wright on 12/5/22.
//

import Foundation

extension Matrix {
    public class User: ObservableObject {
        public let userId: UserId
        public var session: Session
        @Published public var displayName: String?
        @Published public var avatarUrl: MXC?
        @Published public var avatar: NativeImage?
        @Published public var statusMessage: String?
                
        public init(userId: UserId, session: Session) {
            self.userId = userId
            self.session = session
            
            _ = Task {
                try await self.refreshProfile()
            }
        }
        
        public func refreshProfile() async throws {
            let newDisplayName: String?
            let newAvatarUrl: MXC?
            
            (newDisplayName, newAvatarUrl) = try await self.session.getProfileInfo(userId: userId)
            await MainActor.run {
                self.displayName = newDisplayName
                self.avatarUrl = newAvatarUrl
            }
        }
        
        public var isVerified: Bool {
            // FIXME: Query the crypto module and/or the server to find out whether we've verified this user
            false
        }
    }
}

extension Matrix.User: Identifiable {
    public var id: String {
        "\(self.userId)"
    }
}

extension Matrix.User: Equatable {
    public static func == (lhs: Matrix.User, rhs: Matrix.User) -> Bool {
        lhs.userId == rhs.userId
    }
}

extension Matrix.User: Hashable {
    public func hash(into hasher: inout Hasher) {
        self.userId.hash(into: &hasher)
    }
}
