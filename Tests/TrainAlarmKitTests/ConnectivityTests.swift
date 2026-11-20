import Foundation
import Testing
import TrainAlarmKit

@Suite struct ConnectivityMachineTests {
    /// Feeds probe results, advancing the clock by each returned delay.
    private struct Run {
        var machine = ConnectivityMachine()
        var clock = Date(timeIntervalSince1970: 0)
        var delays: [TimeInterval] = []

        mutating func probe(_ success: Bool) {
            let delay = machine.record(success: success, at: clock)
            delays.append(delay)
            clock.addTimeInterval(delay)
        }
    }

    @Test func dropoutRecoversWithBackoffThenClears() {
        var run = Run()
        run.probe(true)
        #expect(run.machine.state == .online)

        let wentDown = run.clock
        run.probe(false)
        run.probe(false)
        #expect(run.machine.state == .offline(since: wentDown))

        let cameBack = run.clock
        run.probe(true)
        #expect(run.machine.state == .recovering(since: cameBack))
        run.probe(true)
        run.probe(true)
        run.probe(true)
        #expect(run.machine.state == .recovering(since: cameBack))
        run.probe(true)
        #expect(run.machine.state == .online)

        // online 15 s, offline every 3 s, then 1, 2, 4, 8 s until a clean 15 s window.
        #expect(run.delays == [15, 3, 3, 1, 2, 4, 8, 15])
    }

    @Test func failureDuringRecoveryGoesBackOffline() {
        var run = Run()
        run.probe(false)
        run.probe(true)
        let failedAgain = run.clock
        run.probe(false)
        #expect(run.machine.state == .offline(since: failedAgain))
        #expect(run.delays.last == 3)
    }
}
