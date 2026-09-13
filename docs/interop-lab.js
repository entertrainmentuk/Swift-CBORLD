const root = document.documentElement;
const themeButton = document.querySelector('.theme-button');
const themeMeta = document.querySelector('meta[name="theme-color"]');
const savedTheme = localStorage.getItem('swift-cborld-theme');
if (savedTheme === 'light' || savedTheme === 'dark') root.dataset.theme = savedTheme;
else if (matchMedia('(prefers-color-scheme: light)').matches) root.dataset.theme = 'light';

function updateThemeControl() {
  const dark = root.dataset.theme === 'dark';
  themeButton.setAttribute('aria-label', dark ? 'Use light theme' : 'Use dark theme');
  themeMeta.content = dark ? '#071315' : '#f4f6f2';
}
themeButton.addEventListener('click', () => {
  root.dataset.theme = root.dataset.theme === 'dark' ? 'light' : 'dark';
  localStorage.setItem('swift-cborld-theme', root.dataset.theme);
  updateThemeControl();
});
updateThemeControl();

const names = { swift: 'Swift', javascript: 'JavaScript', python: 'Python', rust: 'Rust', 'go-fxamacker': 'Go oracle' };
const implementationDescriptions = {
  swift: 'Native implementation under test',
  javascript: 'Digital Bazaar reference processor',
  python: 'Independent Subfile processor',
  rust: 'Independent ldclabs processor',
  'go-fxamacker': 'Raw RFC 8949 CBOR oracle',
  'iridium-java': 'Independent Java architecture reference',
  'anweiss-cddl': 'Independent schema-validation oracle',
  'swift-semanticcompute': 'Future optional acceleration lane'
};

const additionalImplementationRows = [
  { id: 'iridium-java', name: 'Iridium Java', status: 'source-present' },
  { id: 'anweiss-cddl', name: 'anweiss CDDL', status: 'source-present · execution unavailable' },
  { id: 'swift-semanticcompute', name: 'Swift + SemanticCompute', status: 'public distribution unavailable' }
];
let evidence;
let selectedOperation = 'roundTrip';
let selectedFamilyFilter = 'all';

const escapeHTML = (value) => String(value ?? '').replace(/[&<>'"]/g, character => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', "'": '&#39;', '"': '&quot;' })[character]);
const formatDate = (value) => new Intl.DateTimeFormat(undefined, { dateStyle: 'medium', timeStyle: 'short' }).format(new Date(value));
const formatNumber = (value, digits = 0) => new Intl.NumberFormat(undefined, { maximumFractionDigits: digits }).format(value);
const formatDuration = (nanoseconds) => nanoseconds >= 1e6 ? `${formatNumber(nanoseconds / 1e6, 2)} ms` : nanoseconds >= 1e3 ? `${formatNumber(nanoseconds / 1e3, 2)} µs` : `${formatNumber(nanoseconds, 1)} ns`;

function renderSummary() {
  const summary = evidence.summary;
  document.querySelector('#header-status').textContent = `${evidence.status.interop} · ${summary.fixtureCount} fixtures`;
  document.querySelector('#evidence-time').textContent = formatDate(evidence.generatedFrom.performance);
  document.querySelector('#summary-cross').textContent = `${summary.crossDecodePassed}/${summary.crossDecodeTotal}`;
  document.querySelector('#summary-cross-status').textContent = evidence.status.interop;
  document.querySelector('#summary-bytes').textContent = `${summary.byteConsensusFixtures}/${summary.fixtureCount}`;
  document.querySelector('#summary-wins').textContent = `${summary.swiftPerformanceWins}/${summary.performanceFixtureCount}`;
  document.querySelector('#vector-count').textContent = `${summary.validCBORVectors}/${summary.selectedCBORVectors} RFC-valid`;
  document.querySelector('#footer-generated').textContent = `Performance snapshot · ${formatDate(evidence.generatedFrom.performance)}`;
}

function renderImplementations() {
  const grid = document.querySelector('#implementation-grid');
  const implementations = [...evidence.implementations, ...additionalImplementationRows];
  grid.innerHTML = implementations.map((implementation, index) => `
    <article class="implementation-card">
      <span class="impl-index">0${index + 1}</span>
      <h3>${escapeHTML(implementation.name)}</h3>
      <p>${escapeHTML(implementationDescriptions[implementation.id])}</p>
      <span class="impl-state ${implementation.status.includes('unavailable') ? 'unavailable' : implementation.status.includes('source-present') ? 'source' : 'verified'}">${escapeHTML(implementation.status)}</span>
    </article>`).join('');
}

function renderMatrixOptions() {
  const select = document.querySelector('#matrix-fixture');
  select.innerHTML = evidence.fixtures.map(fixture => `<option value="${escapeHTML(fixture.id)}">${escapeHTML(fixture.id)}</option>`).join('');
  select.disabled = false;
  select.addEventListener('change', renderMatrix);
  renderMatrix();
}

function renderMatrix() {
  const fixture = evidence.fixtures.find(row => row.id === document.querySelector('#matrix-fixture').value) || evidence.fixtures[0];
  const adapters = fixture.activeAdapters;
  const lookup = new Map(fixture.crossDecode.map(row => [`${row.decoder}:${row.encoder}`, row]));
  document.querySelector('#decode-grid').innerHTML = `<thead><tr><th>Decoder</th>${adapters.map(id => `<th>${escapeHTML(names[id] || id)}</th>`).join('')}</tr></thead><tbody>${adapters.map(decoder => `<tr><th>${escapeHTML(names[decoder] || decoder)}</th>${adapters.map(encoder => { const row = lookup.get(`${decoder}:${encoder}`); return `<td><span class="${row?.passed ? 'grid-pass' : 'grid-fail'}">${row?.passed ? 'pass' : 'fail'}</span></td>`; }).join('')}</tr>`).join('')}</tbody>`;
  document.querySelector('#decode-score').textContent = `${fixture.crossDecodePassed}/${fixture.crossDecodeTotal} passed`;
  document.querySelector('#fixture-name').textContent = fixture.id;
  document.querySelector('#fixture-description').textContent = fixture.description;
  document.querySelector('#fixture-semantic').textContent = fixture.status;
  document.querySelector('#fixture-bytes').textContent = fixture.byteConsensus ? 'exact' : 'variation permitted';
  document.querySelector('#fixture-adapters').textContent = String(adapters.length);
  document.querySelector('#fixture-hex').textContent = fixture.encodings.swift?.bytesHex || 'unavailable';
  const verdict = document.querySelector('#matrix-verdict');
  verdict.className = `toolbar-verdict ${fixture.status}`;
  verdict.querySelector('b').textContent = fixture.status;
  verdict.querySelector('small').textContent = fixture.byteConsensus ? 'exact byte consensus' : 'semantic consensus';
}

function renderSpeedOptions() {
  const select = document.querySelector('#speed-fixture');
  select.innerHTML = evidence.performance.map(fixture => `<option value="${escapeHTML(fixture.id)}">${escapeHTML(fixture.id)}</option>`).join('');
  select.value = evidence.performance.at(-1).id;
  select.disabled = false;
  select.addEventListener('change', renderSpeed);
  document.querySelectorAll('[data-operation]').forEach(button => button.addEventListener('click', () => {
    selectedOperation = button.dataset.operation;
    document.querySelectorAll('[data-operation]').forEach(item => item.setAttribute('aria-selected', String(item === button)));
    renderSpeed();
  }));
  document.querySelector('#measurement-scope').textContent = evidence.measurementScope;
  renderSpeed();
}

function operationValue(result) {
  if (selectedOperation === 'encode') return result.encodeNanoseconds;
  if (selectedOperation === 'decode') return result.decodeNanoseconds;
  return result.roundTripNanoseconds;
}

function renderSpeed() {
  const fixture = evidence.performance.find(row => row.id === document.querySelector('#speed-fixture').value) || evidence.performance[0];
  const swift = fixture.implementations.swift;
  const rust = fixture.implementations.rust;
  const swiftValue = operationValue(swift);
  const rustValue = operationValue(rust);
  const slowest = Math.max(swiftValue, rustValue);
  document.querySelector('#speed-swift-value').textContent = formatDuration(swiftValue);
  document.querySelector('#speed-rust-value').textContent = formatDuration(rustValue);
  document.querySelector('#speed-swift-rate').textContent = selectedOperation === 'roundTrip' ? `${formatNumber(swift.roundTripsPerSecond, 1)} docs/s` : 'median / operation';
  document.querySelector('#speed-rust-rate').textContent = selectedOperation === 'roundTrip' ? `${formatNumber(rust.roundTripsPerSecond, 1)} docs/s` : 'median / operation';
  document.querySelector('#speed-swift-bar').style.setProperty('--bar', `${Math.max(12, swiftValue / slowest * 100)}%`);
  document.querySelector('#speed-rust-bar').style.setProperty('--bar', `${Math.max(12, rustValue / slowest * 100)}%`);
  document.querySelector('#speed-swift-bar span').textContent = swiftValue <= rustValue ? 'faster' : '';
  document.querySelector('#speed-rust-bar span').textContent = rustValue < swiftValue ? 'faster' : '';
  document.querySelector('#speed-winner').textContent = swiftValue <= rustValue ? 'Swift' : 'Rust';
  document.querySelector('#speed-exact').textContent = fixture.wireBytesEqual ? 'byte-identical' : 'semantic match';
  document.querySelector('#speed-iterations').textContent = formatNumber(fixture.iterationsPerSample);
  const environment = evidence.environment;
  document.querySelector('#speed-environment').textContent = environment.machine || environment.platform || 'recorded report';
}

function renderFamilies() {
  const rows = evidence.semanticComputeFamilies.filter(family => selectedFamilyFilter === 'all' || family.adapterStatus === selectedFamilyFilter);
  document.querySelector('#family-list').innerHTML = rows.map(family => `
    <article class="family-row">
      <div><h3>${escapeHTML(family.name)}</h3><code>${escapeHTML(family.ids.join(' · '))}</code></div>
      <p>${escapeHTML(family.whySC)}</p>
      <span class="family-state ${family.adapterStatus === 'bridge-present' ? 'bridge' : 'cpu'}">${family.adapterStatus === 'bridge-present' ? 'local bridge evidence' : 'CPU reference'}</span>
      <span class="family-state pending family-measurement">SC timing · ${escapeHTML(family.scMeasurementStatus)}</span>
    </article>`).join('') || '<div class="lab-loading">No families match this filter.</div>';
}

document.querySelectorAll('.family-filter').forEach(button => button.addEventListener('click', () => {
  selectedFamilyFilter = button.dataset.familyFilter;
  document.querySelectorAll('.family-filter').forEach(item => item.classList.toggle('active', item === button));
  renderFamilies();
}));

fetch('interop-data.json')
  .then(response => {
    if (!response.ok) throw new Error(`evidence request failed: ${response.status}`);
    return response.json();
  })
  .then(data => {
    evidence = data;
    renderSummary();
    renderImplementations();
    renderMatrixOptions();
    renderSpeedOptions();
    renderFamilies();
  })
  .catch(error => {
    document.querySelector('#header-status').textContent = 'evidence unavailable';
    document.querySelectorAll('.lab-loading').forEach(node => { node.textContent = 'Evidence could not be loaded. Inspect the retained reports in the repository.'; });
    console.error(error);
  });
