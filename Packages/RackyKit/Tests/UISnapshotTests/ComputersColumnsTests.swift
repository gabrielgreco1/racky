import Foundation
import Testing

@testable import RackyUI

/// A tabela de Computers cabe na coluna do meio: com os dois painéis abertos ela cortava o nome e os botões e `Last Used` ficava
/// por baixo de `Open Run Folder`. Agora as colunas de menos peso saem e a ponta direita fica para os botões.
struct ComputersColumnsTests {
    @Test func wideShowsEveryColumnAndNarrowDropsTheLightOnesFirst() {
        #expect(ComputersColumns.fitting(1400).hidden.isEmpty)
        let medium = ComputersColumns.fitting(ComputersColumns.all.required - 1)
        #expect(medium.hidden == [.lease], "Lease sai primeiro")
        let narrow = ComputersColumns.fitting(560)
        #expect(narrow.hidden.isSuperset(of: [.lease, .mode, .proxy]))
        for width in stride(from: 700, through: 1400, by: 50) {
            let columns = ComputersColumns.fitting(CGFloat(width))
            #expect(columns.required <= CGFloat(width), "nunca passa da página em \(width)")
        }
    }
}
