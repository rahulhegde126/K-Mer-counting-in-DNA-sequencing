// =============================================================================
// kmer_tb.v  —  Self-checking testbench for kmer_counter
// =============================================================================
//
// TEST SEQUENCE:  A T C G A T C G   (8 bases, K = 4)
//
// SLIDING WINDOW (k = 4):
//
//   Position   Bases         k-mer   Address (binary)   Address (hex)
//   --------   -----------   -----   ----------------   -------------
//      0        A T C G      ATCG    00_11_01_10          8'h36
//      1        T C G A      TCGA    11_01_10_00          8'hD8
//      2        C G A T      CGAT    01_10_00_11          8'h63
//      3        G A T C      GATC    10_00_11_01          8'h8D
//      4        A T C G      ATCG    00_11_01_10          8'h36  ← repeat
//
// EXPECTED COUNTS AFTER PROCESSING:
//   ATCG (8'h36) → 2
//   TCGA (8'hD8) → 1
//   CGAT (8'h63) → 1
//   GATC (8'h8D) → 1
//   Everything else → 0  (spot-checked for AAAA, TTTT, CCCC, GGGG)
//
// HOW TO SIMULATE
//   Icarus Verilog:
//     iverilog -o kmer_sim kmer_counter.v kmer_tb.v && vvp kmer_sim
//   ModelSim / Questa:
//     vlog kmer_counter.v kmer_tb.v && vsim -c kmer_tb -do "run -all; quit"
//   Vivado xsim:
//     xvlog kmer_counter.v kmer_tb.v && xelab kmer_tb -s top && xsim top -R
//
// =============================================================================

`timescale 1ns / 1ps

module kmer_tb;

    // =========================================================================
    // Testbench parameters — must match kmer_counter parameters
    // =========================================================================
    localparam K         = 4;
    localparam BASE_W    = 2;
    localparam KMER_W    = K * BASE_W;         // 8 bits
    localparam MEM_DEPTH = (1 << KMER_W);      // 256 entries
    localparam COUNT_W   = 16;
    localparam CLK_HALF  = 5;                  // 10 ns period → 100 MHz

    // =========================================================================
    // Base encoding constants
    // =========================================================================
    localparam [BASE_W-1:0]
        BASE_A = 2'b00,
        BASE_C = 2'b01,
        BASE_G = 2'b10,
        BASE_T = 2'b11;

    // =========================================================================
    // K-mer address constants
    // Encoding: oldest base in MSBs, newest base in LSBs.
    //
    //   ATCG → A(00) T(11) C(01) G(10) → 00_11_01_10 → 8'h36
    //   TCGA → T(11) C(01) G(10) A(00) → 11_01_10_00 → 8'hD8
    //   CGAT → C(01) G(10) A(00) T(11) → 01_10_00_11 → 8'h63
    //   GATC → G(10) A(00) T(11) C(01) → 10_00_11_01 → 8'h8D
    //   AAAA →                          → 00_00_00_00 → 8'h00
    //   TTTT →                          → 11_11_11_11 → 8'hFF
    //   CCCC →                          → 01_01_01_01 → 8'h55
    //   GGGG →                          → 10_10_10_10 → 8'hAA
    // =========================================================================
    localparam [KMER_W-1:0]
        KMER_ATCG = 8'h36,
        KMER_TCGA = 8'hD8,
        KMER_CGAT = 8'h63,
        KMER_GATC = 8'h8D,
        KMER_AAAA = 8'h00,
        KMER_TTTT = 8'hFF,
        KMER_CCCC = 8'h55,
        KMER_GGGG = 8'hAA;

    // =========================================================================
    // DUT signals
    // =========================================================================
    reg               clk;
    reg               rst_n;
    reg               valid_in;
    reg  [BASE_W-1:0] base_in;
    reg               seq_done;
    wire              ready;
    wire              done;
    reg  [KMER_W-1:0] query_kmer;
    wire [COUNT_W-1:0] query_count;

    // =========================================================================
    // DUT instantiation
    // =========================================================================
    kmer_counter #(
        .K        (K),
        .BASE_W   (BASE_W),
        .KMER_W   (KMER_W),
        .MEM_DEPTH(MEM_DEPTH),
        .COUNT_W  (COUNT_W)
    ) dut (
        .clk        (clk),
        .rst_n      (rst_n),
        .valid_in   (valid_in),
        .base_in    (base_in),
        .seq_done   (seq_done),
        .ready      (ready),
        .done       (done),
        .query_kmer (query_kmer),
        .query_count(query_count)
    );

    // =========================================================================
    // Clock generation — 10 ns period
    // =========================================================================
    initial clk = 1'b0;
    always #CLK_HALF clk = ~clk;

    // =========================================================================
    // Pass / fail counters
    // =========================================================================
    integer pass_cnt;
    integer fail_cnt;

    // =========================================================================
    // check_kmer task
    //   Drives query_kmer, waits for combinational settle, compares with
    //   expected and updates pass/fail counters.
    // =========================================================================
    task check_kmer;
        input [KMER_W-1:0]  kmer_addr;
        input [COUNT_W-1:0] expected;
        reg   [COUNT_W-1:0] got;
        begin
            query_kmer = kmer_addr;
            #1;                            // let combinational read settle
            got = query_count;
            if (got === expected) begin
                $display("    [PASS]  query=8'h%02h  expected=%0d  got=%0d",
                         kmer_addr, expected, got);
                pass_cnt = pass_cnt + 1;
            end else begin
                $display("    [FAIL]  query=8'h%02h  expected=%0d  got=%0d  <<< ERROR",
                         kmer_addr, expected, got);
                fail_cnt = fail_cnt + 1;
            end
        end
    endtask

    // =========================================================================
    // Test sequence storage
    // =========================================================================
    reg [BASE_W-1:0] seq [0:7];   // ATCGATCG
    integer i;

    // =========================================================================
    // Main stimulus
    // =========================================================================
    initial begin
        // -- Initialise signals --
        pass_cnt = 0;
        fail_cnt = 0;
        rst_n    = 1'b0;
        valid_in = 1'b0;
        seq_done = 1'b0;
        base_in  = {BASE_W{1'b0}};
        query_kmer = {KMER_W{1'b0}};

        // -- Build test sequence: A T C G A T C G --
        seq[0] = BASE_A; seq[1] = BASE_T;
        seq[2] = BASE_C; seq[3] = BASE_G;
        seq[4] = BASE_A; seq[5] = BASE_T;
        seq[6] = BASE_C; seq[7] = BASE_G;

        // -- Apply reset for 4 clock cycles --
        repeat(4) @(posedge clk);
        #1 rst_n = 1'b1;             // release reset one tick after posedge
        @(posedge clk); #1;          // wait one clean cycle

        $display("");
        $display("===========================================================");
        $display("  K-mer Counter Testbench  (K=%0d, COUNT_W=%0d)", K, COUNT_W);
        $display("  Test sequence : A-T-C-G-A-T-C-G  (8 bases)");
        $display("===========================================================");
        $display("");
        $display("  Streaming bases...");

        // ====================================================================
        // PHASE 1: Stream all 8 bases at full rate (one per clock).
        //
        // Timing convention:
        //   We drive valid_in and base_in one tick (#1) AFTER each posedge.
        //   This ensures setup time is met before the NEXT posedge, which is
        //   when the DUT samples the inputs.
        // ====================================================================
        for (i = 0; i < 8; i = i + 1) begin
            @(posedge clk); #1;
            valid_in = 1'b1;
            base_in  = seq[i];
            seq_done = (i == 7) ? 1'b1 : 1'b0;
            $display("    cycle %0d: base=%s  seq_done=%0b",
                     i, (seq[i]==BASE_A)?"A":(seq[i]==BASE_T)?"T":
                        (seq[i]==BASE_C)?"C":"G",
                     (i == 7));
        end

        // De-assert after the last base
        @(posedge clk); #1;
        valid_in = 1'b0;
        seq_done = 1'b0;

        // ====================================================================
        // PHASE 2: Wait for done to assert.
        //   done is registered; it asserts one cycle after the FSM enters
        //   S_DONE, which happens in the same cycle as the last count write.
        // ====================================================================
        $display("");
        $display("  Waiting for done...");
        @(posedge done);             // sensitivity to rising edge of done
        @(posedge clk); #1;         // one extra margin cycle

        // ====================================================================
        // PHASE 3: Query counts and check.
        // ====================================================================
        $display("");
        $display("  --- Expected k-mer counts ---");
        check_kmer(KMER_ATCG, 16'd2);   // ATCG appears at positions 0 and 4
        check_kmer(KMER_TCGA, 16'd1);   // TCGA at position 1
        check_kmer(KMER_CGAT, 16'd1);   // CGAT at position 2
        check_kmer(KMER_GATC, 16'd1);   // GATC at position 3

        $display("");
        $display("  --- Zero-count spot checks (should all be 0) ---");
        check_kmer(KMER_AAAA, 16'd0);   // AAAA never appears
        check_kmer(KMER_TTTT, 16'd0);   // TTTT never appears
        check_kmer(KMER_CCCC, 16'd0);   // CCCC never appears
        check_kmer(KMER_GGGG, 16'd0);   // GGGG never appears

        // ====================================================================
        // PHASE 4: Final summary
        // ====================================================================
        $display("");
        $display("===========================================================");
        $display("  RESULTS:  PASS = %0d   FAIL = %0d", pass_cnt, fail_cnt);
        if (fail_cnt == 0)
            $display("  *** ALL TESTS PASSED ***");
        else
            $display("  *** %0d TEST(S) FAILED — see [FAIL] lines above ***",
                     fail_cnt);
        $display("===========================================================");
        $display("");

        $finish;
    end

    // =========================================================================
    // Watchdog timer — kills simulation if it hangs
    // =========================================================================
    initial begin
        #100_000;
        $display("ERROR: Simulation TIMEOUT. Check for FSM deadlock.");
        $finish;
    end

    // =========================================================================
    // VCD waveform dump — view in GTKWave or ModelSim
    // =========================================================================
    initial begin
        $dumpfile("kmer_wave.vcd");
        $dumpvars(0, kmer_tb);
    end

    // =========================================================================
    // Optional: print state transitions for debugging
    // =========================================================================
    reg [1:0] prev_state;
    always @(posedge clk) begin
        prev_state <= dut.state_r;
        if (dut.state_r !== prev_state) begin
            case (dut.state_r)
                2'd0: $display("  [FSM]  @ %0t ns → S_IDLE", $time);
                2'd1: $display("  [FSM]  @ %0t ns → S_FILL", $time);
                2'd2: $display("  [FSM]  @ %0t ns → S_RUN",  $time);
                2'd3: $display("  [FSM]  @ %0t ns → S_DONE", $time);
            endcase
        end
    end

endmodule
