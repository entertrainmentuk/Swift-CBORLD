const root = document.documentElement;
const themeButton = document.querySelector('.theme-button');
const themeMeta = document.querySelector('meta[name="theme-color"]');

const savedTheme = localStorage.getItem('swift-cborld-theme');
if (savedTheme === 'light' || savedTheme === 'dark') {
  root.dataset.theme = savedTheme;
} else if (window.matchMedia('(prefers-color-scheme: light)').matches) {
  root.dataset.theme = 'light';
}

function updateThemeControl() {
  const isDark = root.dataset.theme === 'dark';
  themeButton.setAttribute('aria-label', isDark ? 'Use light theme' : 'Use dark theme');
  themeMeta.setAttribute('content', isDark ? '#08080a' : '#f8f6f6');
}

themeButton.addEventListener('click', () => {
  root.dataset.theme = root.dataset.theme === 'dark' ? 'light' : 'dark';
  localStorage.setItem('swift-cborld-theme', root.dataset.theme);
  updateThemeControl();
});
updateThemeControl();

const benchmarkData = {
  small: { swift: 444941.3, rust: 263494.2, swiftLabel: '444,941', rustLabel: '263,494', speedup: '1.69× faster' },
  unicode: { swift: 761448.0, rust: 415880.4, swiftLabel: '761,448', rustLabel: '415,880', speedup: '1.83× faster' },
  688: { swift: 973.6, rust: 494.7, swiftLabel: '973.6', rustLabel: '494.7', speedup: '1.97× faster' },
  2720: { swift: 250.9, rust: 122.7, swiftLabel: '250.9', rustLabel: '122.7', speedup: '2.05× faster' },
  10800: { swift: 65.4, rust: 30.5, swiftLabel: '65.4', rustLabel: '30.5', speedup: '2.14× faster' },
  42200: { swift: 16.7, rust: 6.8, swiftLabel: '16.7', rustLabel: '6.8', speedup: '2.45× faster' },
  166400: { swift: 4.2, rust: 1.9, swiftLabel: '4.2', rustLabel: '1.9', speedup: '2.17× faster' }
};

const fixtureSelect = document.querySelector('#fixture-select');
const swiftRate = document.querySelector('#swift-rate');
const rustRate = document.querySelector('#rust-rate');
const swiftBar = document.querySelector('#swift-bar');
const rustBar = document.querySelector('#rust-bar');
const speedup = document.querySelector('#speedup');

function updateBenchmark() {
  const row = benchmarkData[fixtureSelect.value];
  const max = Math.max(row.swift, row.rust);
  swiftRate.textContent = row.swiftLabel;
  rustRate.textContent = row.rustLabel;
  speedup.textContent = row.speedup;
  swiftBar.style.setProperty('--bar', `${Math.max(12, (row.swift / max) * 100)}%`);
  rustBar.style.setProperty('--bar', `${Math.max(12, (row.rust / max) * 100)}%`);
}
fixtureSelect.addEventListener('change', updateBenchmark);

const tabButtons = [...document.querySelectorAll('[data-code]')];
const codeBlocks = {
  package: document.querySelector('#package-code'),
  usage: document.querySelector('#usage-code')
};

tabButtons.forEach((button) => {
  button.addEventListener('click', () => {
    tabButtons.forEach((tab) => tab.setAttribute('aria-selected', String(tab === button)));
    Object.entries(codeBlocks).forEach(([key, block]) => {
      block.hidden = key !== button.dataset.code;
    });
  });
});

const copyButton = document.querySelector('.copy-button');
copyButton.addEventListener('click', async () => {
  const selected = tabButtons.find((tab) => tab.getAttribute('aria-selected') === 'true');
  const text = codeBlocks[selected.dataset.code].innerText;
  try {
    await navigator.clipboard.writeText(text);
    copyButton.textContent = 'Copied';
    window.setTimeout(() => { copyButton.textContent = 'Copy'; }, 1400);
  } catch {
    copyButton.textContent = 'Select code';
  }
});
