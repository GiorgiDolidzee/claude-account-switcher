import Foundation
import Testing
@testable import SwitcherCore

@Suite struct JSONFileTests {
    let fx = Fixture()
    var file: URL { fx.root.appendingPathComponent("f.json") }

    @Test func missingFileReadsNil() throws {
        #expect(try JSONFile.readObject(file) == nil)
    }

    @Test func nonObjectThrows() {
        fx.write("[1]", to: file)
        #expect(throws: JSONFileError.self) { try JSONFile.readObject(file) }
        fx.write("{", to: file)
        #expect(throws: JSONFileError.self) { try JSONFile.readObject(file) }
    }

    @Test func rawRoundTripKeepsEveryValueByteForByte() throws {
        let text = #"{ "a" : 1.1, "b":12345678901234, "c":"ü/x } , \" {", "d":true, "e":{"f":null,"g":[1,{"h":"]"}]}, "t":1731745012.123 }"#
        fx.write(text, to: file)
        var raw = try JSONFile.readRaw(file)!
        #expect(raw.keys == ["a", "b", "c", "d", "e", "t"])
        #expect(String(decoding: raw["a"]!, as: UTF8.self) == "1.1")
        #expect(String(decoding: raw["e"]!, as: UTF8.self) == #"{"f":null,"g":[1,{"h":"]"}]}"#)
        raw.remove("b")
        raw.set("new/key", Data(#"{"x":0.1}"#.utf8))
        try JSONFile.writeRaw(raw, to: file)
        #expect(fx.read(file) == #"{"a":1.1,"c":"ü/x } , \" {","d":true,"e":{"f":null,"g":[1,{"h":"]"}]},"t":1731745012.123,"new/key":{"x":0.1}}"#)
        let obj = try JSONFile.readObject(file)!
        #expect(obj["d"] as? Bool == true)
        #expect((obj["new/key"] as? [String: Any])?["x"] as? Double == 0.1)
    }

    @Test func rawRejectsBrokenFiles() {
        for bad in ["[1]", "{", #"{"a":}"#, #"{"a":1,}"#, #"{"a":1} x"#, "", #"{"a" 1}"#] {
            fx.write(bad, to: file)
            #expect(throws: JSONFileError.self, "\(bad)") { try JSONFile.readRaw(file) }
        }
        fx.write("{}", to: file)
        #expect((try? JSONFile.readRaw(file))?.keys == [])
    }

    @Test func writeKeepsMode() throws {
        fx.write("{}", to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: file.path)
        try JSONFile.writeObject(["a": 1], to: file)
        #expect(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int == 0o640)
    }

    @Test func newFileGets0600() throws {
        try JSONFile.writeObject(["a": 1], to: file)
        #expect(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int == 0o600)
    }

    @Test func emptyValues() {
        let empties: [Any?] = [nil, NSNull(), "", [Any](), [String: Any]()]
        for e in empties { #expect(JSONFile.isEmptyValue(e)) }
        for full in [0, false, "x", ["a"]] as [Any] { #expect(!JSONFile.isEmptyValue(full)) }
    }
}
