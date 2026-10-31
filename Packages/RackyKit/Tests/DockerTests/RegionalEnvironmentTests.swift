import Testing

@testable import RackyDocker

/// F42: o computador usa o fuso e o idioma do Mac (UTC/en-US num IP brasileiro marca bot); valores estranhos não entram no ambiente.
@Suite struct RegionalEnvironmentTests {
    @Test func macTimeZoneAndLocaleGoToTheContainer() {
        #expect(ComputerProvisioner.regionalEnvironment(timeZone: "America/Sao_Paulo", locale: "pt-BR") == ["TZ=America/Sao_Paulo", "RACKY_LOCALE=pt-BR"])
        #expect(ComputerProvisioner.regionalEnvironment(timeZone: "Etc/GMT+3", locale: "en-US").count == 2)
    }

    @Test func unsafeValuesAreDropped() {
        #expect(ComputerProvisioner.regionalEnvironment(timeZone: "x; rm -rf /", locale: "pt BR\n").isEmpty)
        #expect(ComputerProvisioner.regionalEnvironment(timeZone: "", locale: "").isEmpty)
    }
}
