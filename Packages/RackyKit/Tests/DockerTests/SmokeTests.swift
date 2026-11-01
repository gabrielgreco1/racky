import Testing
@testable import RackyDocker

@Suite struct DockerTestsSmoke {
    @Test func moduleLinks() {
        #expect(RackyDockerModule.name == "RackyDocker")
    }
}
