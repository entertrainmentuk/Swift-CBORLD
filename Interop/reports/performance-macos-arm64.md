# Swift versus Rust CBOR-LD benchmark

Generated: `2026-09-13T05:48:03Z`

## Measurement boundary

This is in-process codec throughput after one JSON protocol parse. Each adapter performs its own warmup, consumes every result through a barrier, and returns only aggregate timing. Process startup, executable loading, and JSON protocol I/O are outside the timed region.

Samples: **5**; base operations per sample: **10000**; base warmup operations: **1000**. Scaling fixtures divide both counts by their documented size factor.

## Results

| Fixture | Iterations | Bytes | Swift encode | Rust encode | Swift decode | Rust decode | Swift round trip | Rust round trip | Swift speedup |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| v1-empty-uncompressed | 10000 | 6 | 172.1 ns | 254.5 ns | 136.7 ns | 232.3 ns | 308.8 ns | 486.7 ns | 1.58x |
| v1-empty-default-table | 10000 | 6 | 2344.0 ns | 2968.3 ns | 2481.3 ns | 4687.3 ns | 4825.3 ns | 7655.6 ns | 1.59x |
| v1-inline-context-compressed | 10000 | 110 | 16683.4 ns | 22008.6 ns | 15698.6 ns | 23289.1 ns | 32382.1 ns | 45297.7 ns | 1.40x |
| v1-custom-type-table | 10000 | 44 | 8861.4 ns | 10816.0 ns | 8324.8 ns | 12531.7 ns | 17186.3 ns | 23347.7 ns | 1.36x |
| v1-json-shapes | 10000 | 67 | 689.6 ns | 2180.9 ns | 1557.9 ns | 1614.3 ns | 2247.5 ns | 3795.1 ns | 1.69x |
| v1-unicode-and-boundaries | 10000 | 53 | 426.0 ns | 1287.5 ns | 887.3 ns | 1117.1 ns | 1313.3 ns | 2404.5 ns | 1.83x |
| performance-records-688 | 7 | 45566 | 343113.1 ns | 1116113.1 ns | 683970.3 ns | 905208.3 ns | 1027083.4 ns | 2021321.4 ns | 1.97x |
| performance-records-2720 | 1 | 183742 | 1381583.0 ns | 4728042.0 ns | 2603708.0 ns | 3424542.0 ns | 3985291.0 ns | 8152584.0 ns | 2.05x |
| performance-records-10800 | 1 | 733982 | 5646125.0 ns | 19431542.0 ns | 9642750.0 ns | 13325667.0 ns | 15288875.0 ns | 32757209.0 ns | 2.14x |
| performance-records-42200 | 1 | 2900582 | 22145041.0 ns | 87287750.0 ns | 37603833.0 ns | 58880000.0 ns | 59748874.0 ns | 146167750.0 ns | 2.45x |
| performance-records-166400 | 1 | 11738512 | 90873417.0 ns | 303519667.0 ns | 146147291.0 ns | 210483625.0 ns | 237020708.0 ns | 514003292.0 ns | 2.17x |

## Size and memory observations

| Fixture | Source JSON | Encoded/source | Swift round trips/s | Rust round trips/s | Swift peak RSS | Rust peak RSS |
|---|---:|---:|---:|---:|---:|---:|
| v1-empty-uncompressed | 2 | 3.000 | 3238385.0 | 2054619.2 | 7094272 | 1933312 |
| v1-empty-default-table | 2 | 3.000 | 207242.4 | 130623.7 | 7438336 | 2310144 |
| v1-inline-context-compressed | 155 | 0.710 | 30881.3 | 22076.2 | 7831552 | 2539520 |
| v1-custom-type-table | 61 | 0.721 | 58186.0 | 42830.8 | 7733248 | 2506752 |
| v1-json-shapes | 93 | 0.720 | 444941.3 | 263494.2 | 7323648 | 2129920 |
| v1-unicode-and-boundaries | 69 | 0.768 | 761448.0 | 415880.4 | 7274496 | 2097152 |
| performance-records-688 | 65467 | 0.696 | 973.6 | 494.7 | 9551872 | 4325376 |
| performance-records-2720 | 262624 | 0.700 | 250.9 | 122.7 | 13828096 | 10584064 |
| performance-records-10800 | 1051477 | 0.698 | 65.4 | 30.5 | 34357248 | 35880960 |
| performance-records-42200 | 4201944 | 0.690 | 16.7 | 6.8 | 115195904 | 148242432 |
| performance-records-166400 | 16862544 | 0.696 | 4.2 | 1.9 | 430292992 | 564264960 |

Peak RSS is a process high-water mark for one warmed adapter sample, including its already-parsed protocol request and returned result; it is not bytes allocated per operation. Exact allocation counts remain explicitly unavailable unless an allocator counter is injected; the Swift batch API exposes that hook.

## Result

Corpus round-trip speedup: **2.22x**. Fixtures won: **11/11**. Byte-identical fixtures: **11/11**.

Gate: **passed**.

This evidence supports only the measured fixtures, machine, toolchains, and in-process round-trip contract. It does not claim lower cold CLI startup latency or that Swift wins each operation independently.
