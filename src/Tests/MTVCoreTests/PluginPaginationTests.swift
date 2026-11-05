import Testing
@testable import MTVCore

struct PluginPaginationTests {
  @Test func doesNotLoseVideosAfterFilteredDocumentPage() {
    #expect(PluginPagination.mayAdvance(returnedIDs: [], knownIDs: ["film1"]))
    #expect(PluginPagination.mayAdvance(returnedIDs: ["film2"], knownIDs: ["film1"]))
    #expect(!PluginPagination.mayAdvance(returnedIDs: ["film1"], knownIDs: ["film1"]))
    #expect(PluginPagination.mayAdvance(returnedIDs: ["film1", "film2"], knownIDs: ["film1"]))
  }
}
