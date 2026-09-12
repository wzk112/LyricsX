import Testing
@testable import LyricsXApp

@Test func hdrEligibilityUsesHardwarePotentialRatherThanWhetherHDRIsAlreadyActive() {
    #expect(HDRDisplayCapability(potential: 4, current: 1).supported)
    #expect(HDRDisplayCapability(potential: 1.1, current: 1).supported)
    #expect(!HDRDisplayCapability(potential: 1, current: 1).supported)
    #expect(!HDRDisplayCapability(potential: 0, current: 4).supported)
    #expect(!HDRDisplayCapability(potential: .nan, current: 4).supported)
    #expect(!HDRDisplayCapability(potential: .infinity, current: 4).supported)
}
