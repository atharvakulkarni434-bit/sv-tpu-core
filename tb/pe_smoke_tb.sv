`timescale 1ns/1ps  // set time units for this file: 1ns steps, 1ps precision

module pe_smoke_tb;                                            // start of the testbench module (no ports — it's the top of the simulation)

    logic               clk;                                   // clock wire we will generate ourselves
    logic               rst_n;                                 // reset wire we will drive ourselves
    logic signed [7:0]  activation_in;                          // signal we drive INTO the pe
    logic signed [7:0]  weight_in;                              // signal we drive INTO the pe
    logic               load_weight;                            // signal we drive INTO the pe
    logic               pe_clear;                               // signal we drive INTO the pe
    logic signed [7:0]  activation_out;                         // signal we READ coming OUT of the pe
    logic signed [31:0] accum_out;                               // signal we READ coming OUT of the pe

    int pass_count = 0;                                         // counter: how many checks passed so far
    int fail_count = 0;                                         // counter: how many checks failed so far

    pe dut (.*);                                                // create ("instantiate") one pe, auto-connect same-named wires ("dut" = device under test)

    initial clk = 0;                                            // at time 0, start the clock at 0
    always #5 clk = ~clk;                                       // every 5 time units, flip the clock (0->1->0...) = one full clock every 10 units = 100MHz

    task automatic check(string name, logic signed [31:0] got,   // reusable helper: compares an actual value ("got")
                         logic signed [31:0] exp);                // against the expected value ("exp")
        if (got === exp) begin                                  // if actual matches expected exactly
            pass_count++;                                       // add one to the pass counter
            $display("  PASS  %-42s got=%0d", name, got);       // print a PASS line with the value we got
        end else begin                                          // otherwise (they don't match)
            fail_count++;                                       // add one to the fail counter
            $display("  FAIL  %-42s got=%0d exp=%0d", name, got, exp); // print a FAIL line showing both values
        end
    endtask                                                     // end of the check helper

    task automatic mac_cycle(logic signed [7:0] act);            // reusable helper: feed one activation value for one clock cycle
        activation_in = act;                                    // put this value onto the activation_in wire right now
        @(posedge clk); #1;                                     // wait for the next clock edge, then wait 1 extra tick for values to settle
    endtask                                                     // end of the mac_cycle helper

    initial begin                                               // main test sequence — runs once, top to bottom, like a script

        $dumpfile("pe_smoke.vcd");                              // name the waveform file to record (viewable in gtkwave/SimVision)
        $dumpvars(0, pe_smoke_tb);                              // record every signal in this testbench (and everything inside it) to that file

        // ---- reset the PE first ----
        activation_in = '0; weight_in = '0;                     // start both data inputs at zero
        load_weight = 0; pe_clear = 0;                          // start both control flags off
        rst_n = 0;                                              // assert reset (active-low, so 0 = reset is ON)
        repeat (3) @(posedge clk); #1;                          // hold reset for 3 clock edges to be safe, then settle

        // ---- T1: check reset actually zeroed things ----
        check("T1a reset: accum_out == 0",       accum_out,      0);  // accumulator should read 0 right after reset
        check("T1b reset: activation_out == 0",  activation_out, 0);  // activation_out should also read 0 right after reset

        rst_n = 1;                                              // release reset (1 = normal operation begins)
        @(posedge clk); #1;                                     // let one clock cycle pass so the PE settles into normal mode

        // ---- T2: load a weight and prove it "sticks" ----
        weight_in   = 8'sd3;                                    // put the number 3 on the weight_in wire (signed decimal 3)
        load_weight = 1;                                        // tell the PE "capture that weight now"
        @(posedge clk); #1;                                     // let the clock edge happen — the PE grabs the 3 into weight_q
        load_weight = 0;                                        // turn the load signal back off (weight should now be locked in)
        weight_in   = 8'sd99;                                   // change the wire to 99 — but since load_weight is off, this should be IGNORED
        @(posedge clk); #1;                                     // let one more cycle pass — weight_q should still be 3, not 99

        // ---- T3: pe_clear should zero the accumulator in exactly one cycle ----
        mac_cycle(8'sd2);                                       // feed activation = 2 for one cycle (2 * weight(3) = 6 gets added)
        check("T3a pre-clear: acc == 2*3",       accum_out,      6);  // confirm the accumulator now holds 6
        activation_in = '0;                                     // set activation back to 0 so it doesn't interfere with the clear
        pe_clear = 1;                                           // turn on the clear signal
        @(posedge clk); #1;                                     // let one clock edge happen — accumulator should zero on this edge
        pe_clear = 0;                                           // turn the clear signal back off
        check("T3b one-cycle pe_clear: acc == 0", accum_out,     0);  // confirm the accumulator is now 0

        // ---- T4: run a short sequence of real MAC operations ----
        mac_cycle(8'sd5);                                       // feed activation = 5 (5 * weight(3) = 15 added, total becomes 15)
        check("T4a acc after 5*3",               accum_out,     15); // confirm total is 15
        mac_cycle(-8'sd2);                                      // feed activation = -2 (-2 * 3 = -6 added, total becomes 15-6=9)
        check("T4b acc after += (-2)*3",         accum_out,      9); // confirm total is 9
        check("T4c weight held (not 99)",        accum_out,      9); // if weight had wrongly become 99, this math would be way off — extra proof weight_q held
        activation_in = '0;                                     // feed activation = 0 (should add nothing)
        @(posedge clk); #1;                                     // let that cycle pass
        check("T4d act=0 leaves acc unchanged",  accum_out,      9); // confirm total is still 9 (0 * weight = 0 added)

        // ---- T5: confirm activation_out really lags activation_in by exactly 1 cycle ----
        activation_in = 8'sd42;                                 // put 42 on the input wire
        @(posedge clk); #1;                                     // let one clock edge happen — pipeline register captures 42 now
        check("T5a act_out == 42 one cycle later",              // one cycle after we set 42...
              {{24{activation_out[7]}}, activation_out}, 42);    // ...activation_out should now show 42 (sign-extended to compare cleanly)
        activation_in = 8'sd7;                                  // now put 7 on the input wire
        @(posedge clk); #1;                                     // let another clock edge happen
        check("T5b act_out follows with 1-cycle lag",           // one cycle after we set 7...
              {{24{activation_out[7]}}, activation_out}, 7);     // ...activation_out should now show 7
        activation_in = '0;                                     // reset the input wire back to 0
        @(posedge clk); #1;                                     // let one more cycle pass to clean up before the next test

        // ---- T6: signed math corner case (both extremes multiplied together) ----
        pe_clear = 1; @(posedge clk); #1; pe_clear = 0;         // clear the accumulator back to 0 first
        weight_in = 8'sd127; load_weight = 1;                   // load the maximum positive weight (127)
        @(posedge clk); #1; load_weight = 0;                    // let it load, then stop loading
        mac_cycle(-8'sd128);                                    // feed the minimum possible activation (-128)
        check("T6  signed corner (-128)*127",    accum_out, -16256); // confirm -128 * 127 = -16256 computed correctly (no overflow/sign bug)

        // ---- T7: worst-case magnitude accumulation (matches Proof 1's math) ----
        pe_clear = 1; activation_in = '0;                       // clear the accumulator, reset activation to 0
        @(posedge clk); #1; pe_clear = 0;                       // let the clear happen, then turn it off
        repeat (4) mac_cycle(8'sd127);                          // feed activation = 127, four separate cycles in a row (max legal N)
        check("T7  4x(127*127) == 64516",        accum_out,  64516); // confirm 4 * (127*127) = 64,516, matching the spec's worst-case number

        // ---- T8: prove no leftover value leaks into the next computation ----
        activation_in = '0;                                     // reset activation to 0 first
        pe_clear = 1; @(posedge clk); #1; pe_clear = 0;         // clear the accumulator (wipes the 64,516 from T7)
        weight_in = 8'sd2; load_weight = 1;                     // load a new weight (2) for this "new run"
        @(posedge clk); #1; load_weight = 0;                    // let it load, then stop loading
        mac_cycle(8'sd10);                                      // feed activation = 10 (10 * 2 = 20 added)
        check("T8  no leakage after clear",      accum_out,     20); // confirm total is exactly 20, not 64,516+20 (proves the clear fully worked)

        // ---- final summary ----
        $display("\n==== pe.sv smoke test: %0d passed, %0d failed ====",  // print how many total checks passed/failed
                 pass_count, fail_count);
        if (fail_count == 0) $display("SMOKE TEST: ALL PASS");           // if nothing failed, print a clear success message
        else                 $display("SMOKE TEST: FAILURES PRESENT");   // otherwise print a clear failure warning
        $finish;                                                          // end the simulation

    end                                                          // end of the main test sequence

endmodule                                                        // end of the testbench module