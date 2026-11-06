// App-owned controls in an isolated content world. Nothing here is saved into
// Markdown or included in native speech/review/print snapshots.
if (tokenAttribute && document.documentElement.getAttribute(tokenAttribute) !== token) return false;
const previous = window.marginedResponseState;
if (previous && previous.documentID !== documentID) window.marginedPendingAnswerFocus = null;
window.marginedResponseState = {enabled, token, documentID, answerKeys, focusIntent, focusReturn};
for (const paragraph of document.querySelectorAll('p[data-margined-answer]')) {
    const id = paragraph.getAttribute('data-margined-answer');
    let button = paragraph.querySelector('button[data-margined-answer-action]');
    if (!button) {
        button = document.createElement('button');
        button.type = 'button';
        button.setAttribute('data-margined-answer-action', id);
        button.setAttribute('data-margined-response-ui', '');
        button.className = 'margined-answer-button';
        paragraph.appendChild(button);
    }
    const pending = window.marginedPendingAnswerFocus;
    if (!enabled && document.activeElement === button && !pending) {
        window.marginedPendingAnswerFocus = {id, key:answerKeys[id], documentID, focusIntent, focusReturn, node:button};
    }
    button.textContent = editTitle;
    button.setAttribute('aria-label', answerLabels[id] || editTitle);
    button.disabled = !enabled;
}
for (const group of document.querySelectorAll('ul[data-margined-choice]')) {
    const id = group.getAttribute('data-margined-choice');
    let warning = document.querySelector(`[data-margined-response-warning="${id}"]`);
    if (group.getAttribute('aria-invalid') === 'true') {
        if (!warning) {
            warning = document.createElement('div');
            warning.className = 'margined-response-warning';
            warning.setAttribute('data-margined-response-warning', id);
            warning.setAttribute('data-margined-response-ui', '');
            warning.setAttribute('role', 'status');
            let identifier = `margined-response-warning-${token}-${id}`, suffix = 0;
            while (document.getElementById(identifier)) identifier += '-' + (++suffix);
            warning.id = identifier;
            group.before(warning);
        }
        warning.textContent = conflictText;
        group.setAttribute('aria-describedby', warning.id);
    } else if (warning) {
        if (group.getAttribute('aria-describedby') === warning.id) group.removeAttribute('aria-describedby');
        warning.remove();
    }
}
if (!window.marginedResponseListener) {
    window.marginedResponseListener = true;
    document.addEventListener('click', event => {
        const state = window.marginedResponseState;
        const button = event.target instanceof Element ? event.target.closest('button[data-margined-answer-action]') : null;
        if (!event.isTrusted || !state?.enabled || !button?.isConnected || button.disabled) return;
        const id = button.getAttribute('data-margined-answer-action');
        window.marginedPendingAnswerFocus = {id, key:state.answerKeys[id], documentID:state.documentID,
            focusIntent:state.focusIntent, focusReturn:state.focusReturn, node:button};
        for (const control of document.querySelectorAll('input[data-margined-task],button[data-margined-answer-action]')) control.disabled = true;
        window.webkit.messageHandlers.taskToggle.postMessage({kind:'answer',id:Number(id),token:state.token});
    });
    const moved = event => {
        const pending = window.marginedPendingAnswerFocus;
        if (pending && event.target !== pending.node && event.target !== document.body) window.marginedPendingAnswerFocus = null;
    };
    document.addEventListener('focusin', moved);
    document.addEventListener('pointerdown', moved);
}
const pending = window.marginedPendingAnswerFocus;
if (enabled && pending && focusReturn > pending.focusReturn) {
    const button = document.querySelector(`button[data-margined-answer-action="${pending.id}"]`);
    if (restoreFocus && pending.documentID === documentID && pending.focusIntent === focusIntent &&
        pending.key === answerKeys[pending.id] && button &&
        (document.activeElement === document.body || document.activeElement === pending.node)) button.focus({preventScroll:true});
    window.marginedPendingAnswerFocus = null;
}
return true;
