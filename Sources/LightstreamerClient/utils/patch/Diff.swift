/*
 * Copyright (C) 2021 Lightstreamer Srl
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */
import Foundation

private let a_CODE = code("a")
private let A_CODE = code("A")
private let VARINT_RADIX = code("z") - code("a") + 1

private func code(_ c: Character) -> Int {
    let points = c.unicodeScalars
    let point = points[points.startIndex].value
    return Int(point)
}

typealias DiffPatch = String

class DiffDecoder {
    let diff: String
    let base: String
    var diffPos: String.Index
    var basePos: String.Index
    var buf = ""
    
    public static func apply(_ base: String, _ diff: String) throws -> String {
        return try DiffDecoder(base, diff).decode()
    }
    
    public init(_ base: String, _ diff: String) {
        self.diff = diff
        self.base = base
        self.diffPos = diff.startIndex
        self.basePos = base.startIndex
    }
    
    public func decode() throws -> String {
        while (true) {
            if (diffPos == diff.endIndex) {
                break
            }
            try applyCopy()
            if (diffPos == diff.endIndex) {
                break
            }
            try applyAdd()
            if (diffPos == diff.endIndex) {
                break
            }
            try applyDel()
        }
        return buf
    }
    
    func applyCopy() throws {
        let count = try decodeVarint()
        if (count > 0) {
            try appendToBuf(base, basePos, count)
            basePos = try index(base, basePos, offsetBy: count)
        }
    }
    
    func applyAdd() throws {
        let count = try decodeVarint()
        if (count > 0) {
            try appendToBuf(diff, diffPos, count)
            diffPos = try index(diff, diffPos, offsetBy: count)
        }
    }
    
    func applyDel() throws {
        let count = try decodeVarint()
        if (count > 0) {
            basePos = try index(base, basePos, offsetBy: count)
        }
    }
    
    func decodeVarint() throws -> Int {
        // the number is encoded with letters as digits
        var n = 0;
        while (true) {
            let c = try charAt(diff, diffPos)
            diffPos = try index(diff, diffPos, offsetBy: 1)
            if (c >= a_CODE && c < (a_CODE + VARINT_RADIX)) {
                // small letters used to mark the end of the number
                return n * VARINT_RADIX + (c - a_CODE)
            } else {
                if (c >= A_CODE && c < (A_CODE + VARINT_RADIX)) {
                    n = n * VARINT_RADIX + (c - A_CODE)
                } else {
                    throw InternalException.IllegalStateException("Bad TLCP-diff: the code point \(c) is not in the range A-Z")
                }
            }
        }
    }
    
    func charAt(_ s: String, _ pos: String.Index) throws -> Int {
        if pos == s.endIndex {
            throw InternalException.IllegalStateException("Bad TLCP-diff: Index out of range: pos=\(pos) length=\(s.count)")
        }
        return code(s[pos])
    }
    
    func index(_ s: String, _ pos: String.Index, offsetBy offset: Int) throws -> String.Index {
        if let i = s.index(pos, offsetBy: offset, limitedBy: s.endIndex) {
            return i
        }
        throw InternalException.IllegalStateException("Bad TLCP-diff: Index out of range: startIndex=\(pos) count=\(offset) length=\(s.count)")
    }
    
    func appendToBuf(_ s: String, _ startIndex: String.Index, _ count: Int) throws {
        let endIndex = try index(s, startIndex, offsetBy: count)
        buf.append(contentsOf: s[startIndex..<endIndex])
    }
}
