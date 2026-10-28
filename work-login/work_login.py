#!/usr/bin/env python3
"""Launch the work desktop using a fresh, visible Chrome session."""

import argparse
from dataclasses import dataclass, field
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
from urllib.parse import urlsplit

REGION = "Europe, Middle East & Africa"
TIMEOUT = 120_000
CONFIG_NAMES = ("WORK_LOGIN_PORTAL", "WORK_LOGIN_HOSTS", "WORK_LOGIN_PATH", "WORK_LOGIN_NDS")
HOSTNAME = re.compile(r"(?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.)+[a-z0-9](?:[a-z0-9-]*[a-z0-9])?")


class LoginError(Exception):
    """A message safe to display without revealing credentials or page content."""


@dataclass(frozen=True)
class Config:
    login_url: str
    portal_hosts: frozenset
    portal_path: str
    desktop: str


@dataclass(repr=False)
class Credentials:
    username: str = field(repr=False)
    prefix: str = field(repr=False)
    password: str = field(repr=False)


def read_config():
    # Site details live in the environment, not this repository.
    values = [os.environ.get(name, "").strip() for name in CONFIG_NAMES]
    missing = [name for name, value in zip(CONFIG_NAMES, values) if not value]
    if missing:
        raise LoginError("Missing environment variables: " + ", ".join(missing))
    portal, hosts, portal_path, desktop = values
    portal = portal.lower()
    if not HOSTNAME.fullmatch(portal):
        raise LoginError("WORK_LOGIN_PORTAL must be a bare hostname, without https:// or a path.")
    # Comma-separated, so portal hosts can be added or removed without code changes.
    portal_hosts = frozenset(host.strip().lower() for host in hosts.split(",") if host.strip())
    if not portal_hosts or not all(HOSTNAME.fullmatch(host) for host in portal_hosts):
        raise LoginError("WORK_LOGIN_HOSTS must be a comma-separated list of bare hostnames.")
    # Compared exactly against the URL path, so it needs both slashes.
    if not re.fullmatch(r"/(?:[A-Za-z0-9._~-]+/)+", portal_path):
        raise LoginError("WORK_LOGIN_PATH must be a URL path starting and ending with '/'.")
    # The desktop name becomes the saved ICA filename, so keep it path-safe.
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", desktop):
        raise LoginError("WORK_LOGIN_NDS may only contain letters, digits, '.', '_' and '-'.")
    return Config(f"https://{portal}/", portal_hosts, portal_path, desktop)


def read_credentials():
    names = ("WORK_LOGIN_USERNAME", "WORK_LOGIN_TOKEN_PREFIX", "WORK_LOGIN_PASSWORD")
    # Remove these from this process's environment before starting Playwright.
    values = [os.environ.pop(name, "") for name in names]
    missing = [name for name, value in zip(names, values) if not value]
    if missing:
        raise LoginError("Missing environment variables: " + ", ".join(missing))
    if not re.fullmatch(r"[0-9]{4}|[0-9]{6}", values[1]):
        raise LoginError("WORK_LOGIN_TOKEN_PREFIX must contain 4 or 6 ASCII digits.")
    return Credentials(*values)


def make_passcode(prefix, token):
    if not re.fullmatch(r"[0-9]{6}|[0-9]{8}", token):
        raise LoginError("The RSA token must contain 6 or 8 ASCII digits.")
    passcode = prefix + token
    if not re.fullmatch(r"[0-9]{12}", passcode):
        raise LoginError("The prefix and RSA token must total exactly 12 digits.")
    # Keep this as text: converting to an integer would lose leading zeroes.
    return passcode


def browser_environment():
    # Do not pass vault sessions, credentials or debug settings to Chrome/open.
    allowed = ("PATH", "HOME", "TMPDIR", "USER", "LOGNAME", "LANG", "LC_ALL")
    return {name: os.environ[name] for name in allowed if name in os.environ}


def require_origin(url, expected):
    actual = urlsplit(url)
    trusted = urlsplit(expected)
    if (actual.scheme != "https" or actual.hostname != trusted.hostname
            or actual.port not in (None, 443) or actual.username or actual.password):
        raise LoginError("Stopped: an unexpected host was used for a credential page or download.")


def is_portal_home(url, config):
    actual = urlsplit(url)
    return (actual.scheme == "https" and actual.hostname in config.portal_hosts
            and actual.port in (None, 443)
            and actual.username is None and actual.password is None
            and actual.path == config.portal_path and actual.fragment == "!/home")


def prepare_login(page, config):
    page.goto(config.login_url, wait_until="load")
    toggle = page.locator("#samlToggle")
    toggle.wait_for(state="visible")
    require_origin(page.url, config.login_url)
    toggle.uncheck()
    page.locator("#regionListDropdown").select_option(label=REGION)
    page.locator("#login").wait_for(state="visible")
    page.locator("#passwd").wait_for(state="visible")
    page.locator("#loginBtn").wait_for(state="visible")
    if toggle.is_checked():
        raise LoginError("Could not disable the Microsoft Authenticator option.")


def download_desktop(page, config, credentials, passcode):
    from playwright.sync_api import TimeoutError as PlaywrightTimeout

    require_origin(page.url, config.login_url)
    page.locator("#login").fill(credentials.username)
    require_origin(page.url, config.login_url)
    page.locator("#passwd").fill(passcode)
    require_origin(page.url, config.login_url)
    page.locator("#loginBtn").click()

    print("Waiting for the desktop portal…", flush=True)
    try:
        page.wait_for_url(lambda url: is_portal_home(url, config),
                          wait_until="load", timeout=TIMEOUT)
    except PlaywrightTimeout:
        raise LoginError("The EMEA desktop portal did not become ready in time. "
                         "No login was retried.") from None
    portal_url = page.url
    if not is_portal_home(portal_url, config):
        raise LoginError("Stopped: the desktop portal changed before it could be verified.")
    # Pin subsequent password entry and the download to this login's host.
    portal_origin = "https://" + urlsplit(portal_url).hostname
    print(f"Desktop portal loaded; locating {config.desktop}…", flush=True)
    name = page.locator("div.nds-name.ng-binding").filter(
        has_text=re.compile(r"^\s*" + re.escape(config.desktop) + r"\s*$"))
    desktop = page.locator("a.desktop-link").filter(has=name)
    desktop.wait_for(state="visible")
    require_origin(page.url, portal_origin)

    # Register before clicking, so even a quick download cannot be missed.
    with page.expect_download(timeout=TIMEOUT) as pending:
        desktop.click()
        print("Waiting for the desktop password prompt…", flush=True)
        password = page.locator('input[type="password"]:visible')
        password.wait_for(state="visible")
        require_origin(page.url, portal_origin)
        password.fill(credentials.password)
        require_origin(page.url, portal_origin)
        # The portal's password dialog is expected to submit on Enter.
        password.press("Enter")
        print("Waiting for the ICA download…", flush=True)
    return pending.value, portal_origin


def save_ica(download, downloads_dir, portal_origin, desktop):
    url = download.url.removeprefix("blob:")
    require_origin(url, portal_origin)
    if Path(download.suggested_filename).suffix.lower() != ".ica":
        raise LoginError("Stopped: the portal did not download an ICA file.")
    if download.failure():
        raise LoginError("The ICA download failed.")
    # path() waits for completion. Never scan Downloads for a possibly stale file.
    payload = Path(download.path()).read_bytes()
    if not all(re.search(rb"(?im)^\[" + section + rb"\]\r?$", payload)
               for section in (b"WFClient", b"ApplicationServers")):
        raise LoginError("Stopped: the download does not contain an ICA configuration.")
    downloads_dir.mkdir(parents=True, exist_ok=True)
    suffix = 0
    while True:
        name = f"{desktop}{f' ({suffix})' if suffix else ''}.ica"
        destination = downloads_dir / name
        try:
            # Exclusive creation avoids overwriting existing files or symlinks.
            fd = os.open(destination, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            break
        except FileExistsError:
            suffix += 1
    try:
        with os.fdopen(fd, "wb") as output:
            output.write(payload)
    except BaseException:
        destination.unlink(missing_ok=True)
        raise
    return destination


def open_ica(path):
    # Citrix Workspace must be installed and registered as the .ica handler.
    subprocess.run(["/usr/bin/open", str(path)], check=True,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                   env=browser_environment())


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true",
                        help="check the public login controls without credentials or submission")
    args = parser.parse_args()
    if sys.platform != "darwin":
        raise LoginError("This launcher requires macOS, Google Chrome and Citrix Workspace.")
    os.umask(0o077)
    config = read_config()
    credentials = None if args.check else read_credentials()
    # Disable Playwright debugging before importing it; call logs can contain fills.
    for name in ("DEBUG", "PWDEBUG", "PW_LOG", "BW_SESSION", *CONFIG_NAMES,
                 "WORK_LOGIN_USERNAME", "WORK_LOGIN_TOKEN_PREFIX", "WORK_LOGIN_PASSWORD"):
        os.environ.pop(name, None)
    try:
        from playwright.sync_api import sync_playwright
        if not args.check:
            from token_prompt import prompt_token
    except ImportError:
        raise LoginError("Login dependencies are missing. Follow work-login/README.md to update the venv.") from None

    passcode = None
    if not args.check:
        if not sys.stdin.isatty():
            raise LoginError("Run from an interactive terminal to enter the RSA token securely.")
        passcode = make_passcode(credentials.prefix, prompt_token())

    print("Opening the work login page…", flush=True)
    with tempfile.TemporaryDirectory(prefix="work-login-") as temporary:
        with sync_playwright() as playwright:
            browser = playwright.chromium.launch(
                channel="chrome", headless=False, chromium_sandbox=True,
                downloads_path=temporary, env=browser_environment())
            try:
                context = browser.new_context(accept_downloads=True)
                context.set_default_timeout(TIMEOUT)
                page = context.new_page()
                prepare_login(page, config)
                if args.check:
                    print("Login controls verified; no credentials entered or login submitted.")
                    return
                download, portal_origin = download_desktop(page, config, credentials, passcode)
                path = save_ica(download, Path.home() / "Downloads", portal_origin, config.desktop)
            finally:
                browser.close()

    print(f"Opening {path.name} with the registered Citrix application…", flush=True)
    open_ica(path)
    print("ICA file handed to macOS. Check Citrix Viewer for the desktop connection.")


if __name__ == "__main__":
    try:
        main()
    except (KeyboardInterrupt, EOFError):
        print("\nCancelled. No automatic retry.", file=sys.stderr)
        sys.exit(130)
    except LoginError as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
    except Exception:
        # Playwright exceptions can include entered values, URLs and page content.
        print("Stopped at the last reported stage. No automatic retry. "
              "Check Chrome/Citrix installation and the work-login README. "
              "Diagnostic details are suppressed to protect credentials.", file=sys.stderr)
        sys.exit(1)
