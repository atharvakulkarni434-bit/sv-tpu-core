`timescale 1ns/1ps

module mmu_scoreboard_smoke_tb;
    import mmu_scoreboard_pkg::*;

    mmu_scoreboard sb();

    initial begin
        flat_i8_t  act, wgt;
        flat_i32_t dut_out;
        int i;

        // ---- S1: 2x2 hand-check, same as ref_model.py's _selftest() ----
        act[0]=1; act[1]=2; act[2]=3; act[3]=4;
        wgt[0]=5; wgt[1]=6; wgt[2]=7; wgt[3]=8;
        dut_out[0]=19; dut_out[1]=22; dut_out[2]=43; dut_out[3]=50;
        sb.check_result("S1 2x2 hand-check matches ref_model", act, wgt, 2, dut_out);

        // ---- S2: identity weight -> result equals activations (4x4) ----
        act[0]=7;    act[1]=-8'sd3;  act[2]=42;    act[3]=-8'sd100;
        act[4]=1;    act[5]=2;       act[6]=3;     act[7]=4;
        act[8]=-8'sd5; act[9]=-8'sd6; act[10]=-8'sd7; act[11]=-8'sd8;
        act[12]=10;  act[13]=20;     act[14]=30;   act[15]=40;
        for (i=0;i<16;i++) wgt[i] = '0;
        wgt[0]=1; wgt[5]=1; wgt[10]=1; wgt[15]=1;
        for (i=0;i<16;i++) dut_out[i] = 32'($signed(act[i])); // $signed: same variable-index sign-loss issue as compute_expected_flat
        sb.check_result("S2 identity weight -> passthrough", act, wgt, 4, dut_out);

        // ---- S3: all-zero weight -> zero result ----
        for (i=0;i<16;i++) begin wgt[i]='0; dut_out[i]='0; end
        sb.check_result("S3 all-zero weight -> zero result", act, wgt, 4, dut_out);

        // ---- S4: worst-case magnitude, matches Proof 1's math ----
        for (i=0;i<16;i++) begin
            act[i] = -8'sd128; wgt[i] = 8'sd127; dut_out[i] = -32'sd65024;
        end
        sb.check_result("S4 worst-case magnitude (4x -128*127)", act, wgt, 4, dut_out);

        // ---- S5: deliberately WRONG dut_out, prove the checker catches it ----
        for (i=0;i<16;i++) dut_out[i] = 32'sd999;
        sb.check_result("S5 deliberate mismatch (should FAIL)", act, wgt, 4, dut_out);

        $display("\n==== mmu_scoreboard smoke test: %0d passed, %0d failed ====",
                 sb.pass_count, sb.fail_count);
        $display("(S5 is SUPPOSED to fail -- proves the checker actually detects mismatches)");
        $finish;
    end
endmodule