import Foundation
import MTVCore

/// Photo connections are resources, not separately installed plugins. This
/// platform port is shared by any experience declaring the photos capability.
enum PhotoResources {
  static func release(owner: String) async {
    NativeLibrary.shared.release(pluginID:owner)
    await CloudPhotos.shared.release(owner:owner)
  }
  enum Failure: Error { case mediaApprovalRequired(owner: String, host: String) }
  static func browse(owner: String, input: [String:String], cancellation: NativeLibraryCancellation) async throws -> Data {
    let reference = input["reference"] ?? ""
    if reference.hasPrefix("quark:") {
      return try await CloudPhotos.shared.browse(requester:owner,input:input)
    }
    let local = try await NativeLibrary.shared.requestAsync(pluginID:owner,services:["pictures"],service:"pictures",input:input,cancellation:cancellation)
    guard reference.isEmpty, input["query"]?.isEmpty != false else { return local }
    let cloud = try await CloudPhotos.shared.browse(requester:owner,input:["entry":"true"])
    guard var page = try JSONSerialization.jsonObject(with:local) as? [String:Any],
      let items = page["items"] as? [[String:Any]],
      let connection = try JSONSerialization.jsonObject(with:cloud) as? [String:Any],
      let connections = connection["items"] as? [[String:Any]] else { throw MTVError.message("Invalid photo resources") }
    page["items"] = items + connections
    return try JSONSerialization.data(withJSONObject:page)
  }
  static func artwork(owner: String, reference: String) async throws -> String? {
    if reference.hasPrefix("quark:") { return await CloudPhotos.shared.preview(owner:owner,reference:reference) }
    return try NativeLibrary.shared.asset(pluginID:owner,services:["pictures"],reference:reference,kind:.photo).absoluteString
  }
  static func read(owner: String, reference: String) async throws -> Data {
    if reference.hasPrefix("quark:") {
      do { return try await CloudPhotos.shared.data(owner:owner,reference:reference) }
      catch CloudPhotoFailure.mediaApprovalRequired(let host) { throw Failure.mediaApprovalRequired(owner:"mtv.quark",host:host) }
    }
    let url = try NativeLibrary.shared.asset(pluginID:owner,services:["pictures"],reference:reference,kind:.photo)
    let access = NativeLibrary.shared.fileAccess(pluginID:owner,reference:reference,url:url)
    return try await Task.detached(priority:.utility) { try ScopedFileReader.read(url,access:access,maximumBytes:15_000_000) }.value
  }
}
