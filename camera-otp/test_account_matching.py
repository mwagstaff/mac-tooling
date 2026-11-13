"""Exercise the production account matcher without opening a camera."""
from pathlib import Path
import subprocess
import tempfile

source = Path(__file__).with_name("camera_otp.swift").read_text()
matcher = source.split("/// The RSA app shows", 1)[0]
tests = r'''
func line(_ text: String, _ y: Double, _ x: Double = 0.1, _ w: Double = 0.7, _ h: Double = 0.03) -> AccountText {
    AccountText(text: text, box: CGRect(x: x, y: y, width: w, height: h))
}
let target = "Cloudflare: person@example.com"
let label = line(target, 0.6)
func check(_ lines: [AccountText], _ expected: String?, _ name: String) {
    precondition(AccountCode.match(lines, account: target) == expected, name)
}
check([line("Other: person@example.com", 0.9), line("999 999", 0.84), label, line("012 345", 0.54)], "012345", "select correct row, preserve zero")
check([line("CLOUDFLARE: person@example.com", 0.6), line("012345", 0.54)], "012345", "case and spacing")
check([label, line("012", 0.54, 0.1, 0.1), line("345", 0.54, 0.23, 0.1)], "012345", "split code")
check([label, line("000 000", 0.54)], "000000", "no RSA placeholder gate")
check([label, line("１２３４５６", 0.54)], nil, "ASCII only")
check([label, line("1234567", 0.54)], nil, "no partial matches")
check([label, line("account 123456", 0.54)], nil, "no embedded code")
check([line("Cloudflare: someone@example.com", 0.6), line("123456", 0.54)], nil, "wrong account")
check([label, label, line("123456", 0.54)], nil, "duplicate labels")
check([label, line("Other account", 0.55), line("123456", 0.49)], nil, "intervening label")
check([label, line("123456", 0.3)], nil, "distant code")
check([label, line("123456", 0.7)], nil, "code above label")
check([label, line("123456", 0.54, 0.9, 0.08)], nil, "different column")
check([label, line("123456", 0.54, 0.1, 0.2), line("654321", 0.54, 0.4, 0.2)], nil, "ambiguous row")
check([label, line("123", 0.54, 0.1, 0.1), line("456", 0.54, 0.7, 0.1)], nil, "unrelated halves")
var uncertain = line("123456", 0.54)
uncertain.confidence = 0.5
check([label, uncertain, line("654321", 0.48)], nil, "never skip an uncertain row")
print("16 account-matching checks passed")
'''
with tempfile.TemporaryDirectory() as directory:
    path = Path(directory)
    (path / "main.swift").write_text(matcher + tests)
    subprocess.run(["swiftc", str(path / "main.swift"), "-o", str(path / "test")], check=True)
    subprocess.run([str(path / "test")], check=True)
