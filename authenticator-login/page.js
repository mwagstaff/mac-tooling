// Runs only in the configured Chrome tab. Never returns or logs the token.
function authenticatorPage(action, config, nonce, code) {
    const key = '__macToolingAuthenticator';
    const fail = error => ({ok: false, error});
    const visible = element => element && element.isConnected &&
        element.getClientRects().length > 0 && getComputedStyle(element).visibility !== 'hidden';
    const accountMatches = () => (document.body.innerText.toLowerCase()
        .match(/[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,}/g) || []).includes(config.email.toLowerCase());
    if (location.origin !== config.origin || location.pathname !== config.path) {
        return fail('The verification page changed.');
    }
    if (action === 'prepare') {
        if (window[key]) window[key].cleanup();
        const field = document.activeElement;
        if (!(field instanceof HTMLInputElement) || !visible(field) ||
            !['text', 'tel', 'number'].includes(field.type) || field.disabled || field.readOnly || field.value !== '') {
            return fail('Focus the empty verification-code field, then try again.');
        }
        const label = Array.from(field.labels || []).map(label => label.innerText).join(' ');
        if (!/verification code/i.test(label) && field.autocomplete !== 'one-time-code') {
            return fail('The focused field is not a verification-code field.');
        }
        const body = document.body.innerText.toLowerCase();
        if (!body.includes('verify with your authenticator app') || !accountMatches()) {
            return fail('The verification page does not identify the configured account.');
        }
        const buttons = Array.from(document.querySelectorAll('button, input[type="submit"]'))
            .filter(button => visible(button) && (button.innerText || button.value || '').trim().toLowerCase() === 'verify');
        if (buttons.length !== 1 || (field.form && buttons[0].form !== field.form)) {
            return fail('Could not identify a unique Verify button.');
        }
        const state = {field, button: buttons[0], href: location.href, nonce, invalid: false, started: Date.now()};
        const invalidate = () => { state.invalid = true; };
        const events = [[field, 'blur'], [field, 'input'], [window, 'blur'], [document, 'visibilitychange']];
        events.forEach(([target, event]) => target.addEventListener(event, invalidate));
        const expiry = setTimeout(() => state.cleanup(), 60000);
        state.cleanup = () => {
            events.forEach(([target, event]) => target.removeEventListener(event, invalidate));
            clearTimeout(expiry);
            if (window[key] === state) delete window[key];
        };
        window[key] = state;
        return {ok: true};
    }
    const state = window[key];
    if (!state || state.nonce !== nonce) return fail('Capture session is no longer valid.');
    const {field, button} = state;
    const valid = !state.invalid && Date.now() - state.started < 60000 &&
        location.href === state.href && document.hasFocus() && document.activeElement === field &&
        visible(field) && visible(button) && !field.disabled && !field.readOnly && field.value === '' &&
        accountMatches();
    if (action === 'check' && valid) return {ok: true};
    state.cleanup();
    if (!valid) return fail('The tab, account, or focused field changed. Capture cancelled.');
    if (action !== 'submit' || !/^[0-9]{6}$/.test(code)) return fail('Invalid capture result.');
    // The native setter plus input/change events also updates React-controlled fields.
    Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set.call(field, code);
    field.dispatchEvent(new Event('input', {bubbles: true}));
    field.dispatchEvent(new Event('change', {bubbles: true}));
    if (location.href !== state.href || document.activeElement !== field ||
        !visible(button) || button.disabled || field.value !== code || !field.checkValidity()) {
        return fail('Code filled, but the form was not ready to submit. Review it manually.');
    }
    button.click();
    return {ok: true};
}

if (typeof module !== 'undefined') module.exports = authenticatorPage;
