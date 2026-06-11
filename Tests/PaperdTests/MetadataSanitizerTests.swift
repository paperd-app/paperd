import Foundation
import Testing
import PaperdCore

/// 書誌マークアップのサニタイズ（→ docs/04 3節。壊れタイトルの回帰テスト）
@Suite("MetadataSanitizer")
struct MetadataSanitizerTests {
    @Test("MathML・JATSタグの除去（中身は残す）")
    func stripsMarkup() {
        // 実例に基づくケース
        #expect(MetadataSanitizer.clean(
            "First-principles determination of chemical potentials and vacancy formation energies in <mml:math xmlns:mml=\"http://www.w3.org/1998/Math/MathML\"><mml:mrow><mml:mi>PbTiO</mml:mi><mml:mn>3</mml:mn></mml:mrow></mml:math>")
            == "First-principles determination of chemical potentials and vacancy formation energies in PbTiO3")
        #expect(MetadataSanitizer.clean("Ferroelectric properties of Ba<sub><i>x</i></sub>Sr<sub>1−<i>x</i></sub>TiO<sub>3</sub>")
            == "Ferroelectric properties of BaxSr1−xTiO3")
        #expect(MetadataSanitizer.clean("Order–disorder character of PbTiO<sub>3</sub>")
            == "Order–disorder character of PbTiO3")
    }

    @Test("HTMLエンティティのデコード")
    func decodesEntities() {
        #expect(MetadataSanitizer.clean("Structure &amp; dynamics") == "Structure & dynamics")
        #expect(MetadataSanitizer.clean("walls in PbTiO&#x2083;") == "walls in PbTiO₃")
        #expect(MetadataSanitizer.clean("180&#176; domain walls") == "180° domain walls")
    }

    @Test("通常のタイトルは不変・冪等")
    func plainUnchanged() {
        let plain = "Attention Is All You Need: a < b comparison"
        // 「a < b」のような数式風の不等号はタグに見えない限り保持
        #expect(MetadataSanitizer.clean(plain) == plain)
        let once = MetadataSanitizer.clean("X<sub>2</sub>")
        #expect(MetadataSanitizer.clean(once) == once, "冪等")
    }

    @Test("apply / upsertStub のチョークポイントで効く")
    func appliedAtChokePoints() throws {
        let (store, root) = try makeTempLibrary()
        defer { cleanup(root) }
        // apply経由
        var meta = sampleResolved()
        meta.title = "Energies in <mml:math><mml:mi>SrTiO</mml:mi><mml:mn>3</mml:mn></mml:math>"
        var paper = Paper(title: "x")
        meta.apply(to: &paper)
        #expect(paper.title == "Energies in SrTiO3")
        // stub経由
        let citations = CitationStore(db: store.db)
        let stubId = try citations.upsertStub(.init(title: "Neutral defects in SrTiO<sub>3</sub> studied", doi: "10.1000/stub"))
        #expect(try store.paper(id: stubId)?.title == "Neutral defects in SrTiO3 studied")
    }
}
