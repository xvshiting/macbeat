document.querySelectorAll('[data-mode]').forEach((button) => {
  button.addEventListener('click', () => {
    document.querySelectorAll('[data-mode]').forEach((item) => {
      item.setAttribute('aria-pressed', String(item === button));
    });
    document.querySelectorAll('[data-output]').forEach((output) => {
      output.hidden = output.dataset.output !== button.dataset.mode;
    });
  });
});
