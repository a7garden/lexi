import Foundation

/// UUIDv7 생성기: 시각 정렬 정체성. iCloud 동기화와 PDC stable identity가 모두
/// "언제 만들어졌는지 추정 가능한 안정 ID"를 필요로 하므로 한 곳에서 만든다.
///
/// 레이아웃(RFC 9562): 48bit unix epoch ms | version 7 | 12bit random | variant 10 | 62bit random.
/// 같은 밀리초 안에서도 random 비트가 겹칠 수 있어 엄격한 단조성은 보장하지 않는다.
/// 동기화 ID로는 충돌 확률이 무시할 수준이고, 생성 순서 대략 정렬이면 충분하다.
public enum UUIDv7 {
    /// 지정 시각(기본 현재)을 타임스탬프로 하는 UUIDv7을 만든다.
    public static func generate(at date: Date = Date()) -> UUID {
        let millis = UInt64(
            (date.timeIntervalSince1970 * 1000).rounded(.down)
        ) & 0xFFFF_FFFF_FFFF

        var bytes = [UInt8](repeating: 0, count: 16)
        for offset in 0..<6 {
            bytes[offset] = UInt8((millis >> UInt64(8 * (5 - offset))) & 0xFF)
        }
        for offset in 6..<16 {
            bytes[offset] = UInt8.random(in: .min ... .max)
        }
        bytes[6] = (bytes[6] & 0x0F) | 0x70  // version 7
        bytes[8] = (bytes[8] & 0x3F) | 0x80  // variant 10xx

        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}
