//
//  Matrix+Image.swift
//
//
//  Created by Charles Wright on 9/28/23.
//

import Foundation
import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

extension Matrix {
    public class Image: ObservableObject {
        
        public enum Source {
            case local
            case mxc(MXC)
            case encryptedFile(mEncryptedFile)
        }
        
        public enum Status {
            case loading
            case loaded(Data)
            case failed
        }
        
        //public let source: Source
        public let info: mImageInfo?
        //@Published private(set) public var data: Data?
        @Published private(set) public var state: (Source,Status)
        
        public init(data: Data, source: Source, info: mImageInfo? = nil) {
            self.info = info
            self.state = (source, .loaded(data))
        }
        
        public init(mxc: MXC, info: mImageInfo? = nil, session: Session) {
            let source: Source = .mxc(mxc)
            self.info = info
            self.state = (source, .loading)
            
            Task {
                let data = try await session.downloadData(mxc: mxc)
                await MainActor.run {
                    self.state = (source, .loaded(data))
                }
            }
        }
        
        public init(file: mEncryptedFile, info: mImageInfo? = nil, session: Session) {
            let source: Source = .encryptedFile(file)
            self.info = info
            self.state = (source, .loading)
            
            Task {
                let data = try await session.downloadAndDecryptData(file)
                await MainActor.run {
                    self.state = (source, .loaded(data))
                }
            }
        }
        
        public var data: Data? {
            if case let (_, .loaded(data)) = self.state {
                return data
            } else {
                return nil
            }
        }
        
        public var source: Source {
            let (source, _) = self.state
            return source
        }

        #if canImport(UIKit)
        public var uiImage: UIImage? {
            if let data = self.data {
                return UIImage(data: data)
            } else {
                return nil
            }
        }
        public lazy var image: SwiftUI.Image = SwiftUI.Image(uiImage: self.uiImage ?? UIImage())
        #elseif canImport(AppKit)
        public var nsImage: NSImage? {
            if let data = self.data {
                return NSImage(data: data)
            } else {
                return nil
            }
        }
        public lazy var image: SwiftUI.Image = SwiftUI.Image(nsImage: self.nsImage ?? NSImage())
        #endif
    }
}
