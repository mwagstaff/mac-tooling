"""Dummy credentials, intercepted HTTPS pages, and no actual Citrix launch."""

import contextlib
import io
import json
import os
from pathlib import Path
import stat
import tempfile
import unittest
from unittest.mock import Mock, patch
from urllib.parse import urlsplit

from playwright.sync_api import sync_playwright, TimeoutError as PlaywrightTimeout

import work_login as login

ICA = b"[WFClient]\r\nVersion=2\r\n[ApplicationServers]\r\nTest=\r\n[Test]\r\nAddress=example.invalid\r\n"
CREDS = login.Credentials("dummy-user", "001234", "dummy-desktop-password")
CONFIG = login.Config("https://login.example.com/",
                      frozenset(("eu1.web-login.example.com", "eu2.web-login.example.com")),
                      "/portal/", "DESKTOP0001")


class ConfigTests(unittest.TestCase):
    def read(self, **overrides):
        env = {"WORK_LOGIN_PORTAL": "login.example.com",
               "WORK_LOGIN_HOSTS": "eu1.web-login.example.com,eu2.web-login.example.com",
               "WORK_LOGIN_PATH": "/portal/",
               "WORK_LOGIN_NDS": "DESKTOP0001", **overrides}
        with patch.dict(os.environ, env, clear=True):
            return login.read_config()

    def test_config_is_read_from_environment(self):
        self.assertEqual(self.read(), CONFIG)

    def test_host_list_tolerates_spacing_case_and_empty_entries(self):
        config = self.read(WORK_LOGIN_HOSTS=" EU1.web-login.example.com , ,eu3.web-login.example.com,")
        self.assertEqual(config.portal_hosts,
                         {"eu1.web-login.example.com", "eu3.web-login.example.com"})
        self.assertEqual(self.read(WORK_LOGIN_HOSTS="eu9.web-login.example.com").portal_hosts,
                         {"eu9.web-login.example.com"})

    def test_invalid_config_is_rejected(self):
        for name, value in [("WORK_LOGIN_PORTAL", "https://login.example.com/"),
                            ("WORK_LOGIN_PORTAL", "login.example.com/path"),
                            ("WORK_LOGIN_HOSTS", " , "),
                            ("WORK_LOGIN_HOSTS", "eu1.web-login.example.com,https://evil.invalid"),
                            ("WORK_LOGIN_HOSTS", "eu1.web-login.example.com;evil.invalid"),
                            ("WORK_LOGIN_PATH", "portal/"),
                            ("WORK_LOGIN_PATH", "/portal"),
                            ("WORK_LOGIN_PATH", "/portal/?x=1/"),
                            ("WORK_LOGIN_NDS", "../DESKTOP0001"),
                            ("WORK_LOGIN_NDS", "DESKTOP 0001")]:
            with self.subTest(name=name, value=value), \
                    self.assertRaisesRegex(login.LoginError, name):
                self.read(**{name: value})

    def test_missing_config_only_reports_variable_names(self):
        with patch.dict(os.environ, {}, clear=True):
            with self.assertRaisesRegex(login.LoginError, "WORK_LOGIN_PORTAL, WORK_LOGIN_HOSTS, WORK_LOGIN_PATH, WORK_LOGIN_NDS"):
                login.read_config()


class CredentialsTests(unittest.TestCase):
    def test_leading_zeroes_are_preserved(self):
        self.assertEqual(login.make_passcode("001234", "000056"), "001234000056")
        self.assertEqual(login.make_passcode("0012", "00003456"), "001200003456")

    def test_bad_token_formats_and_lengths_are_rejected(self):
        for prefix, token in [("123456", "12345"), ("1234", "123456"),
                              ("123456", "１２３４５６"), ("123456", "12345x"),
                              ("123456", " 123456"), ("123456", "12345678")]:
            with self.subTest(prefix=prefix, token=token):
                with self.assertRaises(login.LoginError):
                    login.make_passcode(prefix, token)

    def test_credentials_are_removed_from_child_environment(self):
        env = {"WORK_LOGIN_USERNAME": CREDS.username,
               "WORK_LOGIN_TOKEN_PREFIX": CREDS.prefix,
               "WORK_LOGIN_PASSWORD": CREDS.password,
               "BW_SESSION": "dummy-vault-session", "PATH": "/usr/bin"}
        with patch.dict(os.environ, env, clear=True):
            credentials = login.read_credentials()
            self.assertEqual(credentials.password, CREDS.password)
            self.assertFalse(any(name.startswith("WORK_LOGIN_") for name in os.environ))
            self.assertEqual(login.browser_environment(), {"PATH": "/usr/bin"})
            self.assertNotIn(CREDS.password, repr(credentials))

    def test_missing_credentials_only_reports_variable_names(self):
        with patch.dict(os.environ, {}, clear=True):
            with self.assertRaisesRegex(login.LoginError, "WORK_LOGIN_USERNAME"):
                login.read_credentials()

    def test_untrusted_origins_are_rejected(self):
        for url in ("http://login.example.com/", "https://login.example.com.evil.invalid/",
                    "https://evil.invalid/login.example.com", "https://login.example.com:444/",
                    "https://user@login.example.com/"):
            with self.subTest(url=url), self.assertRaises(login.LoginError):
                login.require_origin(url, CONFIG.login_url)
        login.require_origin("https://login.example.com:443/logon/LogonPoint/tmindex.html", CONFIG.login_url)

    def test_launch_uses_argument_list_and_sanitized_environment(self):
        path = Path("/tmp/desktop with spaces.ica")
        with patch.object(login.subprocess, "run") as run:
            login.open_ica(path)
        self.assertEqual(run.call_args.args[0], ["/usr/bin/open", str(path)])
        self.assertNotIn("WORK_LOGIN_PASSWORD", run.call_args.kwargs["env"])
        self.assertTrue(run.call_args.kwargs["check"])

    def test_untrusted_download_host_is_rejected_before_reading_file(self):
        download = Mock(url="https://evil.invalid/desktop.ica")
        with tempfile.TemporaryDirectory() as temporary:
            with self.assertRaises(login.LoginError):
                login.save_ica(download, Path(temporary), "https://eu1.web-login.example.com", CONFIG.desktop)
            self.assertEqual(list(Path(temporary).iterdir()), [])
        download.path.assert_not_called()

    def test_only_known_https_emea_home_pages_are_accepted(self):
        for host in ("eu1.web-login.example.com", "eu2.web-login.example.com"):
            self.assertTrue(login.is_portal_home(f"https://{host}/portal/#!/home", CONFIG))
        for url in ("http://eu2.web-login.example.com/portal/#!/home",
                    "https://eu2.web-login.example.com.evil.invalid/portal/#!/home",
                    "https://us1.web-login.example.com/portal/#!/home",
                    "https://eu3.web-login.example.com/portal/#!/home",
                    "https://eu2.web-login.example.com:444/portal/#!/home",
                    "https://user@eu2.web-login.example.com/portal/#!/home",
                    "https://eu2.web-login.example.com/portal/#!/help",
                    "https://eu2.web-login.example.com/other/#!/home"):
            with self.subTest(url=url):
                self.assertFalse(login.is_portal_home(url, CONFIG))


class BrowserFlowTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.playwright = sync_playwright().start()
        cls.browser = cls.playwright.chromium.launch(
            channel="chrome", headless=True, chromium_sandbox=True,
            env=login.browser_environment())

    @classmethod
    def tearDownClass(cls):
        cls.browser.close()
        cls.playwright.stop()

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.context = self.browser.new_context(accept_downloads=True, service_workers="block")
        self.addCleanup(self.context.close)
        self.context.set_default_timeout(2500)
        self.page = self.context.new_page()
        self.posts = []
        self.unexpected = []
        self.payload = ICA
        self.filename = "server-name.ica"
        self.portal_host = "eu1.web-login.example.com"
        self.portal_fragment = "!/home"
        self.redirect = "/logon/LogonPoint/tmindex.html"
        self.context.route("**/*", self.route)
        self.context.set_offline(True)

    def route(self, route):
        request = route.request
        url = urlsplit(request.url)
        if url.hostname not in ("login.example.com", "eu1.web-login.example.com",
                                "eu2.web-login.example.com", "evil.invalid"):
            self.unexpected.append(request.url)
            route.abort()
            return
        if url.path == "/":
            # A script redirect creates a separately intercepted request.
            # Playwright routing does not re-intercept HTTP redirect chains.
            route.fulfill(content_type="text/html", body=
                          f"<script>location.replace({json.dumps(self.redirect)})</script>")
        elif url.path == "/logon/LogonPoint/tmindex.html":
            # Start with Authenticator enabled and a different region, then
            # add the form after load to exercise readiness rather than sleeps.
            route.fulfill(content_type="text/html", body="""
                <script>window.addEventListener('load', () => setTimeout(() => {
                  document.body.innerHTML = `
                    <input id="samlToggle" type="checkbox" checked
                           onchange="document.querySelector('#passwd').hidden=this.checked">
                    <input id="login"><input id="passwd" type="password" hidden>
                    <select id="regionListDropdown">
                      <option value="us">Americas</option>
                      <option value="eu">Europe, Middle East &amp; Africa</option>
                    </select>
                    <a href="#" id="loginBtn">Login</a>`;
                  document.querySelector('#loginBtn').onclick = async event => {
                    event.preventDefault();
                    await fetch('/capture', {method:'POST', body:JSON.stringify({
                      username:document.querySelector('#login').value,
                      passcode:document.querySelector('#passwd').value,
                      authenticator:document.querySelector('#samlToggle').checked,
                      region:document.querySelector('#regionListDropdown').value
                    })});
                    location.href='https://eu1.web-login.example.com/portal/#!/home';
                  };
                }, 20));</script><body></body>
            """.replace("eu1.web-login.example.com", self.portal_host)
                .replace("#!/home", "#" + self.portal_fragment))
        elif url.path == "/capture":
            self.posts.append(json.loads(request.post_data))
            route.fulfill(body="ok")
        elif url.path == "/portal/":
            route.fulfill(content_type="text/html", body="""
                <input type="password" hidden>
                <a class="desktop-link" href="/wrong-desktop">
                  <div><div class="nds-name ng-binding">DESKTOP0001-OTHER</div></div>
                </a>
                <div id="desktops"></div>
                <script>setTimeout(() => {
                  document.querySelector('#desktops').innerHTML = `
                    <a class="desktop-link" href="#" id="correct">
                      <div><div class="nds-name ng-binding"> DESKTOP0001 </div></div>
                    </a>`;
                  document.querySelector('#correct').onclick = event => {
                    event.preventDefault();
                    setTimeout(() => {
                      const form = document.createElement('form');
                      form.innerHTML='<input type="password"><button>Launch</button>';
                      form.onsubmit = async event => {
                        event.preventDefault();
                        await fetch('/capture', {method:'POST', body:JSON.stringify({
                          password:form.querySelector('input').value
                        })});
                        location.href='/launch.ica';
                      };
                      document.body.append(form);
                    }, 20);
                  };
                }, 20);</script>
            """)
        elif url.path == "/launch.ica":
            route.fulfill(body=self.payload, headers={
                "Content-Type": "application/x-ica",
                "Content-Disposition": f'attachment; filename="{self.filename}"'})
        else:
            self.unexpected.append(request.url)
            route.abort()

    def run_flow(self):
        with contextlib.redirect_stdout(io.StringIO()) as output:
            login.prepare_login(self.page, CONFIG)
            download, self.portal_origin = login.download_desktop(self.page, CONFIG, CREDS, "001234000056")
        self.assertNotIn(CREDS.password, output.getvalue())
        self.assertNotIn("001234000056", output.getvalue())
        return download

    def test_full_flow_and_existing_download_is_not_overwritten(self):
        existing = self.root / f"{CONFIG.desktop}.ica"
        existing.write_bytes(b"old session")
        download = self.run_flow()
        path = login.save_ica(download, self.root, self.portal_origin, CONFIG.desktop)
        self.assertEqual(self.posts, [
            {"username": CREDS.username, "passcode": "001234000056",
             "authenticator": False, "region": "eu"},
            {"password": CREDS.password}])
        self.assertEqual(self.unexpected, [])
        self.assertEqual(path.name, f"{CONFIG.desktop} (1).ica")
        self.assertEqual(path.read_bytes(), ICA)
        self.assertEqual(existing.read_bytes(), b"old session")
        self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)

    def test_eu2_redirect_completes_password_and_download_flow(self):
        self.portal_host = "eu2.web-login.example.com"
        download = self.run_flow()
        path = login.save_ica(download, self.root, self.portal_origin, CONFIG.desktop)
        self.assertEqual(self.portal_origin, "https://eu2.web-login.example.com")
        self.assertEqual(self.posts[-1], {"password": CREDS.password})
        self.assertEqual(len(self.posts), 2)
        self.assertEqual(path.read_bytes(), ICA)
        self.assertEqual(self.unexpected, [])

    def test_download_is_pinned_to_selected_portal_host(self):
        self.portal_host = "eu2.web-login.example.com"
        download = self.run_flow()
        with self.assertRaises(login.LoginError):
            login.save_ica(download, self.root, "https://eu1.web-login.example.com", CONFIG.desktop)
        self.assertEqual(list(self.root.iterdir()), [])

    def test_portal_timeout_reports_stage_without_sensitive_url_or_retry(self):
        self.portal_fragment = "!/pending-secret"
        with patch.object(login, "TIMEOUT", 300):
            with self.assertRaisesRegex(login.LoginError, "EMEA desktop portal") as error:
                self.run_flow()
        self.assertNotIn("pending-secret", str(error.exception))
        self.assertEqual(len(self.posts), 1)

    def test_check_prepares_form_without_entering_credentials(self):
        login.prepare_login(self.page, CONFIG)
        self.assertFalse(self.page.locator("#samlToggle").is_checked())
        self.assertEqual(self.page.locator("#regionListDropdown").input_value(), "eu")
        self.assertEqual(self.page.locator("#login").input_value(), "")
        self.assertEqual(self.page.locator("#passwd").input_value(), "")
        self.assertEqual(self.posts, [])

    def test_redirect_to_untrusted_host_stops_before_entering_credentials(self):
        self.redirect = "https://evil.invalid/logon/LogonPoint/tmindex.html"
        with self.assertRaises(login.LoginError):
            login.prepare_login(self.page, CONFIG)
        self.assertEqual(self.posts, [])
        self.assertEqual(self.page.locator("#login").input_value(), "")

    def test_missing_password_does_not_trigger_another_login_attempt(self):
        self.context.route("**/portal/", lambda route: route.fulfill(
            content_type="text/html", body='<a class="desktop-link" href="#">'
            '<div class="nds-name ng-binding">DESKTOP0001</div></a>'))
        with self.assertRaises(PlaywrightTimeout):
            self.run_flow()
        self.assertEqual(len(self.posts), 1)

    def test_untrusted_desktop_password_page_stops_before_password_fill(self):
        self.context.route("**/portal/", lambda route: route.fulfill(
            content_type="text/html", body='<a class="desktop-link" '
            'href="https://evil.invalid/password">'
            '<div class="nds-name ng-binding">DESKTOP0001</div></a>'))
        self.context.route("https://evil.invalid/password", lambda route: route.fulfill(
            content_type="text/html", body='<input type="password">'))
        with self.assertRaises(login.LoginError):
            self.run_flow()
        self.assertEqual(len(self.posts), 1)
        self.assertEqual(self.page.locator('input[type="password"]').input_value(), "")

    def test_password_page_cannot_switch_between_trusted_portal_hosts(self):
        self.portal_host = "eu2.web-login.example.com"
        self.context.route("**/portal/", lambda route: route.fulfill(
            content_type="text/html", body='<a class="desktop-link" '
            'href="https://eu1.web-login.example.com/password">'
            '<div class="nds-name ng-binding">DESKTOP0001</div></a>'))
        self.context.route("https://eu1.web-login.example.com/password", lambda route: route.fulfill(
            content_type="text/html", body='<input type="password">'))
        with self.assertRaises(login.LoginError):
            self.run_flow()
        self.assertEqual(len(self.posts), 1)
        self.assertEqual(self.page.locator('input[type="password"]').input_value(), "")

    def test_html_disguised_as_ica_is_not_saved(self):
        self.payload = b"<html>Authentication failed</html>"
        download = self.run_flow()
        with self.assertRaises(login.LoginError):
            login.save_ica(download, self.root, self.portal_origin, CONFIG.desktop)
        self.assertEqual(list(self.root.iterdir()), [])

    def test_wrong_file_extension_is_not_saved(self):
        self.filename = "launch.html"
        download = self.run_flow()
        with self.assertRaises(login.LoginError):
            login.save_ica(download, self.root, self.portal_origin, CONFIG.desktop)
        self.assertEqual(list(self.root.iterdir()), [])

    def test_existing_symlink_is_not_followed(self):
        target = self.root / "keep.txt"
        target.write_text("keep")
        (self.root / f"{CONFIG.desktop}.ica").symlink_to(target)
        download = self.run_flow()
        path = login.save_ica(download, self.root, self.portal_origin, CONFIG.desktop)
        self.assertEqual(target.read_text(), "keep")
        self.assertEqual(path.read_bytes(), ICA)


if __name__ == "__main__":
    unittest.main()
