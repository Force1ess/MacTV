import Foundation
import Testing
@testable import MTVCore

struct CloudPhotoPageTests {
  @Test func metadataKeepsPaginationAndSeparatesNativePreviewURLs() throws {
    let raw: [String:Any] = ["items":[["reference":"photo123","title":"Photo.jpg","kind":"photo",
      "preview":"https://thumb.quark.cn/image.jpg?signature=fixture-private"]],"next":"2"]
    let page = try CloudPhotoPage(data:JSONSerialization.data(withJSONObject:raw),requester:"fixture.gallery")
    #expect(page.items[0].reference == "quark:photo123" && page.items[0].kind == .photo)
    #expect(page.next == "2" && page.previews["photo123"] != nil)
    #expect(!String(decoding:try page.encoded(),as:UTF8.self).contains("fixture-private"))
  }
  @Test func rejectsNonPhotosDirectURLsAndMalformedIDs() throws {
    for row: [String:Any] in [
      ["reference":"photo123","title":"Photo","kind":"video"],
      ["reference":"../escape","title":"Photo","kind":"photo"],
      ["reference":"photo123","title":"Photo","kind":"photo","url":"file:///not-read"]
    ] {
      #expect(throws: Error.self) { try CloudPhotoPage(data:JSONSerialization.data(withJSONObject:["items":[row]]),requester:"fixture.gallery") }
    }
    let raw: [String:Any] = ["items":[["reference":"photo123","title":"Photo","kind":"photo","preview":"https://quark.cn.attacker.invalid/photo.jpg"]]]
    #expect(try CloudPhotoPage(data:JSONSerialization.data(withJSONObject:raw),requester:"fixture.gallery").previews.isEmpty)
  }
}
