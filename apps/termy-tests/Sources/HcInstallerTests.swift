import XCTest
@testable import termy

/// 설치 스크립트는 실행하지 않는다. 명령 문자열만 고정한다.
final class HcInstallerTests: XCTestCase {
    func testInstallerCommandIsOfficialScript() {
        XCTAssertEqual(HcInstaller.command, "curl -fsSL https://releases.herdr.dev/core/install.sh | sh")
    }
}
