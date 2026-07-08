
`timescale 1ns/1ps
 
package mmu_scoreboard_pkg;
 
    localparam int MAX_ELEMS = 16;  // 4x4 physical array upper bound
 
    // Packed array types (not unpacked) so they can legally be subroutine
    // ports — indexing (act_flat[i]) works exactly the same either way.
    typedef logic signed [0:MAX_ELEMS-1][7:0]  flat_i8_t;   // 16 x int8
    typedef logic signed [0:MAX_ELEMS-1][31:0] flat_i32_t;  // 16 x int32
 
    
    function automatic flat_i32_t compute_expected_flat(
        input flat_i8_t act_flat,
        input flat_i8_t wgt_flat,
        input int       n
    );
        int r, c, k;
        logic signed [31:0] sum;
        flat_i32_t exp_flat;
        begin
            for (r = 0; r < n; r++) begin
                for (c = 0; c < n; c++) begin
                    sum = 32'sd0;
                    for (k = 0; k < n; k++) begin
                        sum = sum + (32'($signed(act_flat[r*n+k])) * 32'($signed(wgt_flat[k*n+c])));
                    end
                    exp_flat[r*n+c] = sum;
                end
            end
            return exp_flat;
        end
    endfunction
 
endpackage : mmu_scoreboard_pkg
 
 
module mmu_scoreboard;
    import mmu_scoreboard_pkg::*;
 
    int pass_count = 0;
    int fail_count = 0;
 
    // -------------------------------------------------------------------
    // check_result — compares one DUT output matrix (flat, row-major)
    // against the golden model's result for the same inputs/N.
    // -------------------------------------------------------------------
    task automatic check_result(
        input string      name,
        input flat_i8_t   act_flat,
        input flat_i8_t   wgt_flat,
        input int         n,
        input flat_i32_t  dut_out_flat
    );
        flat_i32_t exp_flat;
        bit ok;
        int idx;
        begin
            exp_flat = compute_expected_flat(act_flat, wgt_flat, n);
            ok = 1;
            for (idx = 0; idx < n*n; idx++)
                if (dut_out_flat[idx] !== exp_flat[idx]) ok = 0;
 
            if (ok) begin
                pass_count++;
                $display("  PASS  %-42s (N=%0d matmul matches golden model)", name, n);
            end else begin
                fail_count++;
                $display("  FAIL  %-42s (N=%0d matmul MISMATCH)", name, n);
                for (idx = 0; idx < n*n; idx++)
                    if (dut_out_flat[idx] !== exp_flat[idx])
                        $display("        idx=%0d dut=%0d exp=%0d", idx, $signed(dut_out_flat[idx]), $signed(exp_flat[idx]));
            end
        end
    endtask
 
endmodule : mmu_scoreboard