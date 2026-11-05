import Testing
@testable import MTVCore

struct SubtitlePreferenceTests {
  @Test func prefersSystemThenEnglishThenOtherWithStableFallback() {
    #expect(SubtitlePreference.preferredIndex(languages: ["ja", "eng", "chi"], titles: ["A", "B", "C"], preferredLanguages: ["zh-Hans-CN"]) == 2)
    #expect(SubtitlePreference.preferredIndex(languages: ["ja", "eng"], titles: ["A", "B"], preferredLanguages: ["zh-CN"]) == 1)
    #expect(SubtitlePreference.preferredIndex(languages: ["ja", "ko"], titles: ["A", "B"], preferredLanguages: ["zh-CN"]) == 0)
    #expect(SubtitlePreference.preferredIndex(languages: [nil, nil], titles: ["Film.en.srt", "Film.简体.ass"], preferredLanguages: ["zh-CN"]) == 1)
    #expect(SubtitlePreference.preferredIndex(languages: ["eng", "fra"], titles: ["A", "B"], preferredLanguages: ["fr-FR"]) == 1)
    #expect(SubtitlePreference.preferredIndex(languages: [], titles: []) == nil)
    #expect(SubtitlePreference.preferredIndex(languages: [nil, nil], titles: ["Track 1 [English]", "Track 2 [Portuguese]"], preferredLanguages: ["pt-BR"]) == 1)
    #expect(SubtitlePreference.language("Track 2 [Norwegian Bokmål]") == "nb")
    #expect(SubtitlePreference.rank(language: nil, title: "To.All.The.Boys.zh.srt", preferredLanguages: ["zh-CN"]) == 0)
  }
}
