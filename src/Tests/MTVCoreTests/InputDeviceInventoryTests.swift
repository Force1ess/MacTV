import Testing
@testable import MTVCore

struct InputDeviceInventoryTests {
  @Test func deviceDiscoveryDoesNotGuessFromGenericConsumerOrMouse() {
    #expect(InputDeviceInventory.classify(name: "MiRemoteV", usagePage: 12, usage: 1)?.kind == "remote")
    #expect(InputDeviceInventory.classify(name: "Magic Trackpad", usagePage: 1, usage: 2)?.kind == "trackpad")
    #expect(InputDeviceInventory.classify(name: "", usagePage: 13, usage: 5)?.kind == "trackpad")
    #expect(InputDeviceInventory.classify(name: "Wireless Controller", usagePage: 1, usage: 5)?.kind == "controller")
    #expect(InputDeviceInventory.classify(name: "Bluetooth Mouse", usagePage: 1, usage: 2) == nil)
    #expect(InputDeviceInventory.classify(name: "Consumer Control", usagePage: 12, usage: 1) == nil)
    #expect(InputDeviceInventory.classify(name: "Keyboard", usagePage: 1, usage: 6) == nil)
  }
}
