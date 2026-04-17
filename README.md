# 🧬 K-mer Counting in DNA Sequencing
### Design and Implementation using Verilog RTL
 
![Verilog](https://img.shields.io/badge/Language-Verilog--2001-blue?style=flat-square)
![Simulation](https://img.shields.io/badge/Simulator-Cadence%20SimVision-green?style=flat-square)
![Tests](https://img.shields.io/badge/Tests-22%2F22%20Passed-brightgreen?style=flat-square)
![Clock](https://img.shields.io/badge/Clock-100%20MHz-orange?style=flat-square)
![Domain](https://img.shields.io/badge/Domain-Bioinformatics%20%7C%20VLSI-purple?style=flat-square)
 
> A synthesizable Verilog RTL hardware accelerator that counts K-mer frequencies from a streaming DNA input at **one base per clock cycle**. Built as part of the Electronics and Communication Engineering curriculum at PES University.
 
---
 
## 📋 Table of Contents
 
- [What is This Project?](#-what-is-this-project)
- [Background — DNA and K-mers](#-background--dna-and-k-mers)
- [How K-mer Counting Works](#-how-k-mer-counting-works)
- [Hardware Architecture](#-hardware-architecture)
- [File Structure](#-file-structure)
- [Base Encoding](#-base-encoding)
- [FSM States](#-fsm-states)
- [Port Description](#-port-description)
- [Simulation Results](#-simulation-results)
- [How to Run](#-how-to-run)
- [Test Cases](#-test-cases)
- [Waveform Guide](#-waveform-guide)
- [Future Scope](#-future-scope)
---
 
## 🔬 What is This Project?
 
This project implements a **hardware accelerator for K-mer counting** — a fundamental operation in bioinformatics and genome assembly — using synthesizable Verilog RTL.
 
A DNA sequencing machine (like Illumina) cannot read a full genome at once. It produces millions of short random fragments called **reads**. To reconstruct the original genome, we:
 
1. Extract every substring of length K (called a **K-mer**) from every read
2. Count how often each K-mer appears across all reads
3. Use those counts to detect sequencing errors and assemble the genome
This project implements **step 1 and 2 entirely in hardware**, running at 100 MHz with full-throughput streaming input.
 
---
 
## 🧬 Background — DNA and K-mers
 
### DNA Basics
 
DNA is a string over a 4-character alphabet — **A, T, G, C** (the four nucleotide bases):
 
```
...A T C G G C T A T G C A T C G A T C G...
   ← 3.2 billion bases in the human genome →
```
 
Since there are only 4 symbols, each base needs just **2 bits** to encode:
 
| Base | Full Name | Pairs With | Hardware Encoding |
|------|-----------|------------|-------------------|
| A | Adenine  | T | `2'b00` |
| C | Cytosine | G | `2'b01` |
| G | Guanine  | C | `2'b10` |
| T | Thymine  | A | `2'b11` |
 
### What is a Read?
 
A sequencing machine cannot read the full genome. It produces millions of **short random fragments** (~100–300 bases), called reads, from random overlapping positions:
 
```
True genome:   A T C G T A C G A T C G
                                         (unknown, what we want to find)
Read 1:        A T C G T A
Read 2:          T C G T A C
Read 3:            C G T A C G
Read 4:              G T A C G A
```
 
### What is a K-mer?
 
A K-mer is every **contiguous substring of length K** extracted from a read by sliding a window one base at a time:
 
```
Read:    A T C G T A     (length L = 6)
K = 3
 
Window slides:
  [ATC]          → k-mer 1
   [TCG]         → k-mer 2
    [CGT]        → k-mer 3
     [GTA]       → k-mer 4
 
Total k-mers = L − K + 1 = 6 − 3 + 1 = 4
```
 
> **Key distinction:** Read length is fixed by the machine (~150 bases). K is a parameter **you choose** (typically 21–51 in real tools, K=4 in this implementation).
 
---
 
## ⚙️ How K-mer Counting Works
 
### Error Detection
 
The sequencer makes errors (~1% per base). One wrong base corrupts exactly **K consecutive k-mers**.
 
```
4 runs of the same region (Coverage Depth = 4):
 
Run 1:  A T C G T A   ✅ correct
Run 2:  A T C G T A   ✅ correct
Run 3:  A T C G T A   ✅ correct
Run 4:  A T C A T A   ❌ error: G→A at position 3
```
 
After counting all k-mers (K=3):
 
| K-mer | Count | Verdict |
|-------|-------|---------|
| ATC   | 4     | ✅ Real — all 4 runs agree |
| TCG   | 3     | ✅ Real — 3/4 runs agree |
| CGT   | 3     | ✅ Real |
| GTA   | 3     | ✅ Real |
| TCA   | 1     | ❌ Error — only run 4 produced this |
| CAT   | 1     | ❌ Error |
| ATA   | 1     | ❌ Error |
 
**Rule:**
```
count ≥ threshold  →  REAL k-mer  →  KEEP
count <  threshold →  ERROR k-mer →  DISCARD
```
 
Real k-mers appear in every read that covers that position → high count.
Error k-mers appear in only one bad read → count of 1.
 
### Overlap-Based Assembly (De Bruijn Graph)
 
Trusted k-mers are chained together by overlap of K−1 characters:
 
```
Two k-mers connect if:
  last (K−1) chars of k-mer A  =  first (K−1) chars of k-mer B
 
ATC → TCG  (TC = TC) ✅
TCG → CGT  (CG = CG) ✅
CGT → GTA  (GT = GT) ✅
 
Chain: ATC → TCG → CGT → GTA
Read:  A T C G T A   ← original genome recovered ✅
```
 
---
 
## 🏗️ Hardware Architecture
 
### Block Diagram
 
```
 Inputs                     kmer_counter.v                     Outputs
 ──────    ┌─────────────────────────────────────────┐    ──────────
  clk  ───▶│                                         │
  rst_n ──▶│  ┌──────────┐    ┌───────────────────┐  │───▶  ready
 valid_in─▶│  │   FSM    │───▶│  Shift Register   │  │───▶  done
  base_in─▶│  │ 4 states │    │   [K × 2 bits]    │  │
  seq_done▶│  └──────────┘    └─────────┬─────────┘  │
           │        │                   │             │
           │        │         ┌─────────▼──────────┐  │
           │        └────────▶│   Count Memory     │  │
           │                  │  [MEM_DEPTH × 16b] │  │
 query_kmer▶│                  └────────────────────┘  │───▶ query_count
           └─────────────────────────────────────────┘
```
 
### Shift Register Operation
 
The shift register holds the K most recent bases. Each clock cycle, a new base enters the LSB and the oldest base falls off the MSB. The full register value at any moment is the binary encoding of the current K-mer window — which directly serves as the count memory address.
 
```
Sequence: A T C G  (K=4, BASE_W=2, KMER_W=8)
 
After A:  [ 00 | 00 | 00 | 00 ]  (filling)
After T:  [ 00 | 00 | 00 | 11 ]  (filling)
After C:  [ 00 | 00 | 11 | 01 ]  (filling)
After G:  [ 00 | 11 | 01 | 10 ]  ← first complete k-mer: ATCG = 8'h36
After A:  [ 11 | 01 | 10 | 00 ]  ← TCGA = 8'hD8  (count!)
After T:  [ 01 | 10 | 00 | 11 ]  ← CGAT = 8'h63  (count!)
```
 
### Read-Modify-Write (One Cycle)
 
Every clock in S_RUN, the hardware performs:
```
1. Read   →  old_count = mem_r[current_kmer]
2. Add    →  new_count = old_count + 1
3. Write  →  mem_r[current_kmer] = new_count
```
 
All three operations complete in **one clock cycle** using Verilog non-blocking assignment semantics.
 
---
 
## 📁 File Structure
 
```
kmer-dna-sequencing/
│
├── rtl/
│   └── kmer_counter.v       # Synthesizable RTL module (DUT)
│
├── tb/
│   └── kmer_tb.v            # Self-checking testbench (3 test cases)
│
├── sim/
│   └── kmer_wave.vcd        # VCD waveform (generated after simulation)
│
└── README.md
```
 
---
 
## 🔢 Base Encoding
 
```verilog
A = 2'b00    C = 2'b01    G = 2'b10    T = 2'b11
```
 
K-mer address is formed by concatenating K base encodings, oldest base in MSBs:
 
```
ATCG (K=4):  A(00) T(11) C(01) G(10)  =  00_11_01_10  =  8'h36
TCGA (K=4):  T(11) C(01) G(10) A(00)  =  11_01_10_00  =  8'hD8
CGAT (K=4):  C(01) G(10) A(00) T(11)  =  01_10_00_11  =  8'h63
GATC (K=4):  G(10) A(00) T(11) C(01)  =  10_00_11_01  =  8'h8D
```
 
No hash function needed — the binary value of the K-mer **is** the memory address.
 
---
 
## 🔄 FSM States
 
```
          rst_n=0
             │
             ▼
         ┌────────┐
         │ S_IDLE │  ready=1, waiting for first valid_in
         └────────┘
              │  first valid_in received
              ▼
         ┌────────┐
         │ S_FILL │  accumulate first K bases
         └────────┘  no counting yet (window not full)
              │  K-th base received
              ▼
         ┌────────┐
         │ S_RUN  │  count one k-mer per clock
         └────────┘  full throughput: 1 base/cycle
              │  seq_done asserted
              ▼
         ┌────────┐
         │ S_DONE │  done=1, ready=0
         └────────┘  all counts stable, query port readable
```
 
| State | ready | done | Action |
|-------|-------|------|--------|
| S_IDLE | 1 | 0 | Wait for first base |
| S_FILL | 1 | 0 | Load first K bases into shift register |
| S_RUN  | 1 | 0 | Count one k-mer per clock cycle |
| S_DONE | 0 | 1 | Counting complete — results available |
 
---
 
## 📌 Port Description
 
```verilog
module kmer_counter #(
    parameter K         = 4,       // k-mer length
    parameter BASE_W    = 2,       // bits per base (always 2 for DNA)
    parameter KMER_W    = K*BASE_W,// shift register width
    parameter MEM_DEPTH = 1<<KMER_W,// number of unique k-mers (4^K)
    parameter COUNT_W   = 16       // counter width (max count = 65535)
)
```
 
| Port | Direction | Width | Description |
|------|-----------|-------|-------------|
| `clk` | input | 1 | System clock (100 MHz) |
| `rst_n` | input | 1 | Active-low asynchronous reset |
| `valid_in` | input | 1 | High when `base_in` contains a valid base |
| `base_in` | input | 2 | 2-bit encoded DNA base (A/C/G/T) |
| `seq_done` | input | 1 | Assert HIGH with the last valid base |
| `ready` | output | 1 | HIGH when DUT can accept a base |
| `done` | output | 1 | HIGH when all counting is complete |
| `query_kmer` | input | 8 | K-mer address to read count for |
| `query_count` | output | 16 | Count of the queried k-mer |
 
### Interface Timing
 
```
         ┌──┐  ┌──┐  ┌──┐  ┌──┐  ┌──┐
clk:  ───┘  └──┘  └──┘  └──┘  └──┘  └──
 
          │  A  │  T  │  C  │  G  │
base_in:  │ 00  │ 11  │ 01  │ 10  │
valid_in: └─────────────────────────┘ (HIGH for each valid base)
seq_done:                       ┌──┐   (HIGH only on last base)
                                └──┘
done:                                ┌──── (goes HIGH after S_DONE)
```
 
---
 
## ✅ Simulation Results
 
### Test 1 — Normal Operation
 
```
Sequence: A T C G A T C G  (8 bases, K=4)
 
[PASS]  kmer=8'h36 (ATCG)  expected=2  got=2   ← appears at pos 0 and 4
[PASS]  kmer=8'hd8 (TCGA)  expected=1  got=1
[PASS]  kmer=8'h63 (CGAT)  expected=1  got=1
[PASS]  kmer=8'h8d (GATC)  expected=1  got=1
[PASS]  kmer=8'h00 (AAAA)  expected=0  got=0
[PASS]  kmer=8'hff (TTTT)  expected=0  got=0
[PASS]  kmer=8'h55 (CCCC)  expected=0  got=0
[PASS]  kmer=8'haa (GGGG)  expected=0  got=0
TEST 1: PASS=8  FAIL=0
```
 
### Test 2 — Sequencer Error Demonstration
 
```
Stream: ATCGATCG + ATCAATCG  (16 bases — error at position 11: G→A)
 
Real k-mers (count ≥ 2 → KEEP):
[PASS]  kmer=8'h36 (ATCG)  expected=3  got=3
[PASS]  kmer=8'hd8 (TCGA)  expected=2  got=2
[PASS]  kmer=8'h63 (CGAT)  expected=2  got=2
[PASS]  kmer=8'h8d (GATC)  expected=2  got=2
 
Error k-mers (count = 1 → DISCARD):
[PASS]  kmer=8'h34 (ATCA)  expected=1  got=1  ← contains wrong base
[PASS]  kmer=8'hd0 (TCAA)  expected=1  got=1  ← contains wrong base
[PASS]  kmer=8'h43 (CAAT)  expected=1  got=1  ← contains wrong base
[PASS]  kmer=8'h0d (AATC)  expected=1  got=1  ← contains wrong base
TEST 2: PASS=8  FAIL=0
```
 
### Test 3 — Edge Case (Sequence Shorter Than K)
 
```
Only 2 bases streamed (K=4 needs minimum 4)
FSM: IDLE → FILL → DONE  (no k-mer counted)
 
[PASS]  kmer=8'h36  expected=0  got=0
[PASS]  kmer=8'hd8  expected=0  got=0
[PASS]  kmer=8'h00  expected=0  got=0
[PASS]  kmer=8'hff  expected=0  got=0
[PASS]  kmer=8'h55  expected=0  got=0
[PASS]  kmer=8'haa  expected=0  got=0
TEST 3: PASS=6  FAIL=0
```
 
```
╔══════════════════════════════════════════════════════════╗
║  TOTAL PASS = 22    TOTAL FAIL = 0                      ║
║  *** ALL TESTS PASSED — DESIGN FULLY VERIFIED ***       ║
╚══════════════════════════════════════════════════════════╝
```
 
---
 
## ▶️ How to Run
 
### Option 1 — Icarus Verilog (Free, Linux/Mac/Windows)
 
```bash
# Install Icarus Verilog
sudo apt install iverilog      # Ubuntu/Debian
brew install icarus-verilog    # macOS
 
# Compile
iverilog -g2005 -o kmer_sim rtl/kmer_counter.v tb/kmer_tb.v
 
# Run simulation
vvp kmer_sim
 
# View waveform (requires GTKWave)
gtkwave kmer_wave.vcd
```
 
### Option 2 — Cadence SimVision
 
```bash
# Compile and elaborate
ncvlog  rtl/kmer_counter.v tb/kmer_tb.v
ncelab  kmer_tb
ncsim   kmer_tb
```
 
### Option 3 — Vivado xsim
 
```bash
xvlog rtl/kmer_counter.v tb/kmer_tb.v
xelab kmer_tb -s kmer_top
xsim  kmer_top -R
```
 
### Option 4 — ModelSim / Questa
 
```tcl
vlog rtl/kmer_counter.v tb/kmer_tb.v
vsim -c kmer_tb -do "run -all; quit"
```
 
---
 
## 🧪 Test Cases
 
| Test | Input | Purpose |
|------|-------|---------|
| Test 1 — Normal | `ATCGATCG` 8 bases | Verifies correct k-mer counting with a repeat |
| Test 2 — Error Demo | `ATCGATCGATCAATCG` 16 bases (error at pos 11) | Shows real k-mers get count ≥ 2, error k-mers get count = 1 |
| Test 3 — Edge Case | `AT` only 2 bases | FSM exits cleanly before any k-mer forms, all counts stay 0 |
 
---
 
## 📊 Waveform Guide
 
Add these signals in GTKWave / SimVision in this order for the clearest view:
 
```
1.  clk                ← clock reference
2.  rst_n              ← see reset release
3.  valid_in           ← data stream active
4.  base_in[1:0]       ← set display to Hex
5.  seq_done           ← last-base pulse
6.  dut.state_r[1:0]   ← set display to Decimal (0=IDLE 1=FILL 2=RUN 3=DONE)
7.  dut.shift_r[7:0]   ← set display to Hex (watch it fill: 00→03→0D→36→D8...)
8.  ready              ← drops when DONE
9.  done               ← goes HIGH at end
10. query_kmer[7:0]    ← address being queried
11. query_count[15:0]  ← set display to Decimal (see counts 1, 2, 3...)
```
 
**Key moments to zoom into:**
 
| Time | Event |
|------|-------|
| ~75 ns  | S_IDLE → S_FILL (first base arrives) |
| ~105 ns | S_FILL → S_RUN (K-th base loaded, first k-mer counted) |
| ~120 ns | ATCG counted second time (count becomes 2) |
| ~145 ns | S_RUN → S_DONE (seq_done received) |
| ~150 ns | done = 1 asserts |
 
---
 
## 🚀 Future Scope
 
| Enhancement | Description |
|-------------|-------------|
| **BRAM for large K** | Replace flip-flop memory with Block RAM for K > 8 to support genome-scale datasets (K=21 needs 4GB+ of counters) |
| **Pipeline stages** | Add register stages between shift register and memory to push clock frequency beyond 200 MHz on Xilinx UltraScale+ |
| **Programmable threshold** | Make threshold a runtime-configurable register, auto-set based on estimated coverage depth |
| **De Bruijn graph builder** | Extend this counter into a full De Bruijn graph constructor — the next step toward a complete hardware genome assembler |
| **FPGA deployment** | Synthesize and deploy on Xilinx Artix-7 or Zynq with AXI streaming interface for real sequencer data ingestion |
 
---
 
## 📚 Concepts Referenced
 
- **K-mer Counting** — frequency analysis of substrings in biological sequences
- **De Bruijn Graph** — graph structure used in genome assembly (nodes = (K−1)-mers, edges = K-mers)
- **Eulerian Path** — path through De Bruijn graph that visits every edge once = reconstructed genome
- **Coverage Depth** — how many reads cover a given genomic position; determines threshold value
- **FSM-based RTL** — finite state machine controlling a shift-register datapath
- **Read-Modify-Write** — atomic counter update in one clock cycle using non-blocking assignments
---
 
## 👨‍💻 Author
 
**Rahul**
Electronics and Communication Engineering
PES University, Bengaluru
 
---
 
## 📄 License
 
This project is open source and available under the [MIT License](LICENSE).
 
---
 
<div align="center">
**K-mer counting is the foundation of all modern genome assemblers.**
**This project maps that algorithm directly onto efficient, elegant hardware.**
 
🧬 &nbsp; Built with Verilog &nbsp; | &nbsp; Verified with Cadence SimVision &nbsp; | &nbsp; 22/22 Tests Passed
 
</div>
