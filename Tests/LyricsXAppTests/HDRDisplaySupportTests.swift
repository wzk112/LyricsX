import Testing
@testable import LyricsXApp

@Test func edrEligibilityUsesPotentialRatherThanWhetherEDRIsAlreadyActive() {
    #expect(HDRDisplayCapability(potential: 4, current: 1).supported)
    #expect(HDRDisplayCapability(potential: 1.1, current: 1).supported)
    #expect(!HDRDisplayCapability(potential: 1, current: 1).supported)
    #expect(!HDRDisplayCapability(potential: 0, current: 4).supported)
    #expect(!HDRDisplayCapability(potential: .nan, current: 4).supported)
    #expect(!HDRDisplayCapability(potential: .infinity, current: 4).supported)
}

@Test func currentHeadroomIsSanitizedWithoutTreatingItAsEligibility() {
    #expect(HDRDisplayCapability(potential: 16, current: 1, builtIn: true).supported)
    #expect(HDRDisplayCapability(potential: 2, current: 5).currentHeadroom == 2)
    #expect(HDRDisplayCapability(potential: 4, current: .nan).currentHeadroom == 1)
    #expect(HDRDisplayCapability(potential: 1, current: 3).renderHeadroom == 1)
}
