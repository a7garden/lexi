import Testing
import Foundation
@testable import LexiCore

@Suite struct LanguageDetectionTests {
    @Test func 한글이_포함된_용어는_한국어다() {
        #expect(LanguageDetector.detect("임베딩") == .korean)
        #expect(LanguageDetector.detect("iOS 앱 개발") == .korean)
    }

    @Test func 가나가_있으면_일본어다() {
        #expect(LanguageDetector.detect("こんばんは") == .japanese)
        #expect(LanguageDetector.detect("本当ですか") == .japanese)
    }

    @Test func 한자만_있으면_중국어로_판정한다() {
        #expect(LanguageDetector.detect("今天天气很好，我们要去公园散步") == .chinese)
        // 번체도 중국어다.
        #expect(LanguageDetector.detect("今天天氣很好") == .chinese)
        // 정책: 일본어는 실제 용례에서 가나를 거의 항상 포함하므로, 가나 없는 한자
        // 단독("寿司"처럼 양쪽으로 읽히는 용어)은 통계상 중국어로 고정 판정한다.
        #expect(LanguageDetector.detect("寿司") == .chinese)
    }


    @Test func 라틴_문장은_언어인식기가_가른다() {
        #expect(LanguageDetector.detect("An embedding represents meaning as a vector") == .english)
        #expect(LanguageDetector.detect("Bonjour comment allez-vous aujourd'hui") == .french)
        #expect(LanguageDetector.detect("Guten Morgen wie geht es dir heute") == .german)
        #expect(LanguageDetector.detect("Buenos días cómo estás hoy") == .spanish)
        #expect(LanguageDetector.detect("Привет как дела сегодня") == .russian)
    }

    @Test func 판단_근거가_없으면_미상이다() {
        #expect(LanguageDetector.detect("") == nil)
        #expect(LanguageDetector.detect("   ") == nil)
        #expect(LanguageDetector.detect("12345 !@#") == nil)
    }

    @Test func 저장된_태그는_지원_목록에서만_되돌린다() {
        #expect(EntryLanguage.decode("ko") == .korean)
        #expect(EntryLanguage.decode("xx") == nil)
        #expect(EntryLanguage.decode(nil) == nil)
    }
}
