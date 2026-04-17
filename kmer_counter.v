// =============================================================================
// kmer_counter.v  —  K-mer DNA Sequencing Hardware Accelerator
// =============================================================================
//
// WHAT THIS MODULE DOES
// ---------------------
// Accepts a stream of DNA bases (one per clock), slides a window of width K,
// and counts how often every distinct k-mer appears in the sequence.
// Results are readable through a query port once done = 1.
//
// BASE ENCODING (2 bits per base)
// --------------------------------
//   A = 2'b00    C = 2'b01    G = 2'b10    T = 2'b11
//
// SHIFT REGISTER LAYOUT (KMER_W bits)
// -------------------------------------
//   [KMER_W-1 : KMER_W-BASE_W]  = oldest base  (most significant end)
//   [BASE_W-1 : 0             ]  = newest base  (least significant end)
//   Example for K=4, sequence ATCG:
//     shift_r = A(00) T(11) C(01) G(10) = 8'b00_11_01_10 = 8'h36
//
// PARAMETERS
// ----------
//   K         – k-mer length              (default 4)
//   BASE_W    – bits per base             (fixed 2, do not change)
//   KMER_W    – bits per k-mer            (= K × BASE_W, derived)
//   MEM_DEPTH – number of unique k-mers   (= 4^K = 2^KMER_W, derived)
//   COUNT_W   – width of each counter     (default 16 → max count 65535)
//
// INTERFACE
// ---------
//   1. Assert rst_n low for ≥ 1 cycle to clear all counters.
//   2. Drive one base per clock: valid_in=1, base_in=<2-bit base>.
//   3. On the very last base, also assert seq_done=1.
//   4. Wait for done=1.
//   5. Drive query_kmer to read any k-mer's count from query_count.
//
// THROUGHPUT
//   One base per clock after reset. No bubbles required between bases.
//
// SYNTHESISABILITY NOTES
//   – Targets Verilog-2001 + $clog2 (supported by Vivado, Quartus, DC).
//   – Memory is a synchronous register file (flip-flops); for K > 6
//     consider replacing mem_r with an inferred BRAM or SRAM macro.
//   – Reset iterates over all MEM_DEPTH entries; for K > 8 consider a
//     separate initialisation FSM to avoid huge reset fan-out.
//
// =============================================================================

module kmer_counter #(
    parameter K         = 4,
    parameter BASE_W    = 2,
    parameter KMER_W    = K * BASE_W,
    parameter MEM_DEPTH = (1 << KMER_W),
    parameter COUNT_W   = 16
)(
    input  wire               clk,
    input  wire               rst_n,        // active-low asynchronous reset

    // ---- Input stream ------------------------------------------------
    input  wire               valid_in,     // base_in is valid this cycle
    input  wire [BASE_W-1:0]  base_in,      // 2-bit encoded DNA base
    input  wire               seq_done,     // assert WITH the last valid base

    // ---- Handshake ---------------------------------------------------
    output reg                ready,        // high while DUT accepts bases
    output reg                done,         // high when all counts are stable

    // ---- Query port (combinational read; valid only after done=1) ----
    input  wire [KMER_W-1:0]  query_kmer,
    output wire [COUNT_W-1:0] query_count
);

    // =========================================================================
    // FSM state encoding
    // =========================================================================
    localparam [1:0]
        S_IDLE = 2'd0,   // idle, waiting for the first base
        S_FILL = 2'd1,   // filling shift register (first K bases)
        S_RUN  = 2'd2,   // steady-state counting (one k-mer per clock)
        S_DONE = 2'd3;   // counting finished, results stable

    reg [1:0] state_r;

    // =========================================================================
    // Datapath registers
    // =========================================================================

    // Shift register — holds the K most recent bases.
    // Each new base shifts in at the LSB end; the oldest base falls off the MSB.
    reg [KMER_W-1:0] shift_r;

    // Fill counter — counts bases loaded so far (0 .. K).
    // 5 bits supports K up to 31.
    reg [4:0] fill_r;

    // =========================================================================
    // Count memory
    // =========================================================================
    // For K=4: 256 entries × 16 bits = 4 096 flip-flops.
    // Synthesis note: tools infer this as a register file.
    // The k-mer bit-pattern directly indexes the array — no hash required.
    reg [COUNT_W-1:0] mem_r [0:MEM_DEPTH-1];

    // =========================================================================
    // Combinational signals
    // =========================================================================

    // next_kmer_w: the k-mer that would be formed after shifting base_in in.
    // Used to count and update shift_r in a single cycle.
    wire [KMER_W-1:0] next_kmer_w = {shift_r[KMER_W-BASE_W-1:0], base_in};

    // =========================================================================
    // Query port — asynchronous read from count memory
    // =========================================================================
    assign query_count = mem_r[query_kmer];

    // =========================================================================
    // FSM + datapath
    // =========================================================================
    integer idx;   // loop variable for reset

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            // -----------------------------------------------------------------
            // Asynchronous reset: clear all state and every count to zero.
            // -----------------------------------------------------------------
            state_r <= S_IDLE;
            shift_r <= {KMER_W{1'b0}};
            fill_r  <= 5'd0;
            ready   <= 1'b0;
            done    <= 1'b0;
            for (idx = 0; idx < MEM_DEPTH; idx = idx + 1)
                mem_r[idx] <= {COUNT_W{1'b0}};

        end else begin
            case (state_r)

                // =============================================================
                // IDLE: assert ready, wait for the first base.
                // =============================================================
                S_IDLE: begin
                    done  <= 1'b0;
                    ready <= 1'b1;
                    if (valid_in) begin
                        // Load first base into the LSBs; upper bits are 0.
                        shift_r <= {{(KMER_W-BASE_W){1'b0}}, base_in};
                        fill_r  <= 5'd1;
                        // If this is also the last base, the sequence is
                        // shorter than 1 base — nothing to count.
                        state_r <= seq_done ? S_DONE : S_FILL;
                    end
                end

                // =============================================================
                // FILL: accumulate the first K bases; no k-mer counted yet
                //       until the K-th base arrives.
                // =============================================================
                S_FILL: begin
                    ready <= 1'b1;
                    if (valid_in) begin
                        shift_r <= next_kmer_w;
                        fill_r  <= fill_r + 5'd1;

                        if (fill_r == (K - 1)) begin
                            // ------------------------------------------------
                            // This is the K-th base.
                            // next_kmer_w now holds the very first complete
                            // k-mer — count it and transition to S_RUN.
                            // ------------------------------------------------
                            mem_r[next_kmer_w] <= mem_r[next_kmer_w] + 1;
                            state_r <= seq_done ? S_DONE : S_RUN;

                        end else if (seq_done) begin
                            // Sequence ended before we accumulated K bases.
                            // No k-mer can be formed.
                            state_r <= S_DONE;
                        end
                        // else: keep filling
                    end else if (seq_done) begin
                        // seq_done without valid_in — sequence ended abruptly.
                        state_r <= S_DONE;
                    end
                end

                // =============================================================
                // RUN: steady-state.
                // Every valid_in produces exactly one new k-mer to count.
                // =============================================================
                S_RUN: begin
                    ready <= 1'b1;
                    if (valid_in) begin
                        // Shift in the new base and count the resulting k-mer.
                        // Note: because mem_r is a register file and Verilog
                        // non-blocking assignments update at end-of-time-step,
                        // back-to-back writes to the same address are handled
                        // correctly — each cycle reads the value committed by
                        // the previous cycle.
                        shift_r               <= next_kmer_w;
                        mem_r[next_kmer_w]    <= mem_r[next_kmer_w] + 1;
                        if (seq_done)
                            state_r <= S_DONE;
                    end else if (seq_done) begin
                        // No final base; just close out.
                        state_r <= S_DONE;
                    end
                end

                // =============================================================
                // DONE: de-assert ready, assert done.  Results are stable.
                // =============================================================
                S_DONE: begin
                    done  <= 1'b1;
                    ready <= 1'b0;
                end

                default: state_r <= S_IDLE;

            endcase
        end
    end

endmodule
