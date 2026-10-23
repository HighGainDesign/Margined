// App-owned isolated-world bridge. Document scripts stay disabled.
const main = document.getElementById('document');
if (!main) return null;
if (operation === 'highlight') {
    for (const old of main.querySelectorAll('.margined-speaking')) old.classList.remove('margined-speaking');
    if (!elementID) return true;
    const target = Array.from(main.querySelectorAll('[data-margined-speech]')).find(node => node.dataset.marginedSpeech === elementID);
    if (!target) return false;
    target.classList.add('margined-speaking');
    if (follow) target.scrollIntoView({block:'nearest',behavior:matchMedia('(prefers-reduced-motion: reduce)').matches ? 'instant' : 'smooth'});
    return true;
}
if (operation !== 'locate') return null;
if (mode === 'visible') {
    const nodes = Array.from(main.querySelectorAll('[data-margined-speech]'));
    const target = nodes.find(node => node.getBoundingClientRect().bottom > 0) ?? nodes.at(-1);
    return target ? {elementID:target.dataset.marginedSpeech,offset:0} : null;
}
const selection = getSelection();
if (!selection?.rangeCount) return null;
const range = selection.getRangeAt(0);
let start = range.startContainer.nodeType === Node.ELEMENT_NODE ? range.startContainer : range.startContainer.parentElement;
let target = start?.closest?.('[data-margined-speech]');
if (!target && start && main.contains(start)) {
    const child = start.childNodes[range.startOffset];
    if (child?.nodeType === Node.ELEMENT_NODE) target = child.matches('[data-margined-speech]') ? child : child.querySelector('[data-margined-speech]');
    if (!target) target = Array.from(main.querySelectorAll('[data-margined-speech]')).find(node => range.intersectsNode(node));
}
if (!target || !main.contains(target)) return null;
let offset = 0;
if (target.contains(range.startContainer)) {
    const prefix = document.createRange(); prefix.selectNodeContents(target);
    const formula = start?.closest?.('.margined-math');
    if (formula && target.contains(formula)) prefix.setEndBefore(formula);
    else prefix.setEnd(range.startContainer,range.startOffset);
    // Generated MathML contains visual tokens plus a TeX annotation. Selection
    // offsets use the original single TeX source, matching native speech maps.
    const length = node => {
        if (node.nodeType === Node.TEXT_NODE) return node.data.length;
        if (node.nodeType === Node.ELEMENT_NODE && node.hasAttribute('data-margined-math-source')) return node.getAttribute('data-margined-math-source').length;
        return Array.from(node.childNodes).reduce((n, child) => n + length(child), 0);
    };
    offset = length(prefix.cloneContents());
}
return {elementID:target.dataset.marginedSpeech,offset};
