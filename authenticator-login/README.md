# Camera Authenticator login

In Chrome, focus the empty **Verification code** field on Cloudflare's
`https://dash.cloudflare.com/two-factor` page and press **Ctrl–Cmd–Shift–A**.
Open Google Authenticator on the unlocked iPhone and hold its screen up to the
Mac camera. Keep the full Cloudflare account label and code visible; searching
for Cloudflare on the phone can help when the label is too small.

The enlarged preview has an aiming box for the account label and code. The box
turns green with “Code detected — hold still” feedback when recognition succeeds.
It is a positioning aid; recognition still scans the whole camera frame. The
preview starts unmirrored. Use **Mirror preview** if the opposite orientation
feels easier; the choice is remembered for both Authenticator and RSA capture.
Only the preview is flipped, not the image used for text recognition.

The shortcut maps the exact HTTPS website to the account in `config.json`,
matches the full account label to the code beneath it, fills the browser field,
and clicks **Verify once**. It does not retry rejected codes. The success alert
means submission was triggered, not that the service accepted the login.

Press the shortcut again or **Escape** to cancel. Switching applications, tabs,
or fields, or editing the field during capture cancels the flow. Capture stops
after a timeout. An unknown website or ambiguous/missing account fails closed.

## One-time setup

- Hammerspoon must have Accessibility access and permission to automate Chrome.
- In Chrome, enable **View → Developer → Allow JavaScript from Apple Events**.
  This permits local automation to execute scripts in Chrome pages; this flow
  uses it to verify the destination field and submit without blind keystrokes.
- Allow camera access for the launch context when macOS requests it. Permission
  previously granted to a terminal may not cover the Hammerspoon launch path.

The active Hammerspoon configuration loads `hammerspoon/config/authenticator-login.lua`.
The existing **Ctrl–Cmd–L** RSA login is unchanged.

## Scope and privacy

Only Cloudflare is configured initially. Supporting another website also requires
adapting and testing the page checks in `page.js`; adding a hostname alone is not
enough. Multiple accounts for one service need a reliable page account identifier.

Recognition runs locally with Apple Vision. Account mode sends the six-digit
result through a private process pipe; it does not write to the clipboard, save
camera images, or log codes. Script input travels through stdin, not command-line
arguments. Configuration contains account labels, not TOTP seeds.

The reader requires consistent recognition for at least 0.6 seconds and pauses
in the final five seconds of the Mac's 30-second TOTP interval. This is a
best-effort rollover guard; it cannot establish the phone's exact remaining
validity. Keep both devices' clocks accurate.

## Verification

```sh
python3 camera-otp/test_account_matching.py
node --test authenticator-login/page.test.js
hs -c 'dofile(os.getenv("HOME") .. "/dev/mac-tooling/authenticator-login/controller.test.lua")'
```

These checks cover account/row selection and browser submission guards. Actual
phone-camera recognition, macOS permissions, and a successful Cloudflare login
must also be checked on the user's devices.
