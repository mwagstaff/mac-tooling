# Work login

Launches your work desktop using RSA SecurID, the EMEA portal, and Citrix Workspace.
Requires macOS, Google Chrome, Python 3.10+ supported by Playwright, and Citrix
Workspace registered to open `.ica` files. It uses a separate, temporary Chrome
profile, so it does not reuse your normal browser session or extensions.

## Setup

Python 3.14 is available on this Mac:

```sh
cd ~/dev/mac-tooling/work-login
python3.14 -m venv .venv
.venv/bin/python -m pip install -r requirements.txt
```

No separate Chromium download is needed: Playwright uses installed Google Chrome.
After updating the script, rerun the `pip install -r requirements.txt` command
above to install any new dependencies, including the token prompt and macOS
clipboard support.

Supply these exported variables through your existing password-manager-backed
shell environment:

| Variable | Value |
| --- | --- |
| `WORK_LOGIN_USERNAME` | Your work username |
| `WORK_LOGIN_TOKEN_PREFIX` | The 4- or 6-digit SecurID PIN/prefix |
| `WORK_LOGIN_PASSWORD` | The password requested after choosing the desktop |
| `WORK_LOGIN_PORTAL` | Bare hostname of the login page, without `https://` or a path |
| `WORK_LOGIN_HOSTS` | Comma-separated bare hostnames the login may redirect to |
| `WORK_LOGIN_PATH` | Portal path on those hosts, starting and ending with `/` |
| `WORK_LOGIN_NDS` | Exact desktop name shown in the portal |

`WORK_LOGIN_HOSTS` is read on every run, so add or remove portal hosts by
editing that secret and running `bw-reload`. Spaces around commas and empty
entries are ignored. The site details are not secret in the same way as the
credentials, but they are kept in the vault so this public repository does not
name the employer, its hosts or the desktop.

Keep secrets out of this repository, command arguments and shell history. The
script does not create a `.env` file or change your password manager setup.

## Run

```sh
~/dev/mac-tooling/work-login/login.sh
```

Enter a fresh RSA token at the terminal prompt. The digits are shown (the token
alone is not a secret) so you can check them, and Backspace works normally. Press Enter to submit typed or pasted input.
Alternatively, **copy a new token from the RSA app while the prompt is open**:
the script detects the clipboard change and automatically continues if the
new text is exactly six ASCII digits. No paste or Enter is needed in that case.
Or **hold the phone up to the Mac's camera**: a small preview window opens
when the prompt does, and the token is entered and submitted automatically as
soon as it is read, with no key press. The RSA app shows `000000` while it
loads, so that reading is held for up to 5 seconds in case it changes, then
accepted as genuine. This uses
[`camera-otp`](../camera-otp/camera-otp.sh) (on-device OCR, no Internet), which
compiles itself on the first run and needs your terminal app to have Camera
permission. The window does not take keyboard focus, so typing still works, and
the camera is switched off as soon as the prompt finishes by any route. If the
camera is unavailable or you close its window, typing and the clipboard still work.
Leading zeroes are preserved. The token and prefix must still total exactly
12 digits; manual entry continues to support 6- or 8-digit tokens.

The clipboard watcher polls macOS's change counter every 200 ms, starting when
the prompt opens. It does not read existing clipboard text, and a new copy of
the same text still counts as a change. Nonmatching text is ignored, including
whitespace, longer numbers, and non-ASCII digits. Any newly copied six-digit
text is eligible; the script cannot verify which app copied it. A matching
copy replaces any partially typed token and immediately submits the prompt.
Watching stops on submission or cancellation, and the script never clears or
modifies your clipboard. If clipboard access fails, manual entry remains
available. The token is not stored in prompt history.

The script opens Chrome, waits for the redirected form, unchecks Microsoft
Authenticator, selects EMEA, fills the login form, and submits once. It waits
for `<WORK_LOGIN_PATH>#!/home` on one of the `WORK_LOGIN_HOSTS`, selects the exact
desktop name from `WORK_LOGIN_NDS`, fills its visible
password field, and presses Enter. Password entry and the ICA download must
remain on the exact portal host selected by that login; other hosts are rejected.

The password step assumes a single visible password input in the same browser
tab and that Enter submits it. That authenticated dialog has not been inspected
live. An iframe, popup, different submit mechanism, changed host or extra
authentication challenge may require adjusting the script. It stops on a
timeout or unexpected page; it never retries a submitted token or password.

The current run's completed ICA download is saved to
`~/Downloads/<WORK_LOGIN_NDS>.ica`, with a numbered suffix if that name already
exists. It checks the download host, extension and ICA sections before saving,
creates the file with mode `0600`, and opens that exact file using macOS's
registered `.ica` handler. Install/configure Citrix Workspace if macOS opens it
in another application. A successful handoff does not prove the remote desktop
connected. ICA files may contain session tickets; remove the saved file when
Citrix no longer needs it.

Credentials are read only by this script and are removed from its environment
before Playwright starts. Chrome and `open` receive a small allowlist of normal
environment variables. TLS verification and the Chromium sandbox remain enabled.
There are no screenshots, traces, saved cookies or credential logs. Playwright
debug settings are removed, and errors omit raw details that could contain
secrets. Credentials still exist in process memory while the script runs, and
the parent shell retains its original exported variables. Ctrl-C cancels the
run; normal completion or failure closes the isolated browser.

## Checks

To check the public form without reading credentials, prompting for a token or
submitting a login (it still needs the four site variables):

```sh
~/dev/mac-tooling/work-login/login.sh --check
```

Run the local regression suite:

```sh
cd ~/dev/mac-tooling/work-login
.venv/bin/python -m unittest discover -v
```

Tests use dummy credentials and intercepted browser requests. They do not
contact the real portal, submit a real login or launch Citrix. Clipboard tests use a private
pasteboard, leaving the system clipboard untouched, and camera tests use a stub command
instead of the real camera.

Implementation references: [Playwright browser contexts](https://playwright.dev/python/docs/api/class-browser#browser-new-context)
and [download completion](https://playwright.dev/python/docs/downloads),
[Apple's pasteboard change counter](https://sosumi.ai/documentation/appkit/nspasteboard/changecount),
and [terminal input](https://python-prompt-toolkit.readthedocs.io/en/stable/pages/asking_for_input.html).
