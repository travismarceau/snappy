(() => {
  const steps = [...document.querySelectorAll('.story-step')];
  const desktop = document.getElementById('desktop-demo');
  if (!steps.length || !desktop) return;
  document.body.classList.add('story-enhanced');

  let scheduled = false;
  const update = () => {
    scheduled = false;
    const threshold = window.innerHeight * (window.innerWidth <= 760 ? 0.68 : 0.55);
    let current = 0;

    steps.forEach((step, index) => {
      const bounds = step.getBoundingClientRect();
      if (bounds.top + bounds.height / 2 <= threshold) current = index;
    });

    desktop.dataset.state = String(current);
    steps.forEach((step, index) => {
      step.classList.toggle('is-active', index === current);
    });
  };

  const requestUpdate = () => {
    if (scheduled) return;
    scheduled = true;
    requestAnimationFrame(update);
  };

  window.addEventListener('scroll', requestUpdate, { passive: true });
  window.addEventListener('resize', requestUpdate);
  update();
})();
