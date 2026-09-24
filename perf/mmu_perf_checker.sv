//==============================================================================
// File: mmu_perf_checker.sv
// Description: performance checker — bound onto mmu_top, checks timing only,
// not correctness. Watches latency (right cycle count?) and throughput
// (how fast back-to-back computations run).
// Latency — how long one computation takes, from flow_en starting to done firing: free_cyc - start_cyc.
// Throughput — how far apart two consecutive computations start: free_cyc - last_flow_cyc.
// Control overhead — how long between start and flow_en actually beginning: free_cyc - start_edge_cyc.
//==============================================================================

`ifndef MMU_PERF_CHECKER_SV
`define MMU_PERF_CHECKER_SV

`timescale 1ns/1ps

module mmu_perf_checker #(
    parameter int N = 4          
)(
    input logic       clk,
    input logic       rst_n,
    input logic       start,     
    input logic       done,      
    input logic [2:0] dim_n,     
    input logic       flow_en   
);

    bit use_spec_2n;
    initial use_spec_2n = $test$plusargs("LAT_SPEC_2N");   

    
    function automatic int unsigned exp_latency(input int unsigned n);
        return use_spec_2n ? (2 * n) : (n + 5);
    endfunction

    
    localparam int unsigned LATENCY_WATCHDOG = 4*N + 4;

    bit          in_flight;        
    int unsigned free_cyc;        
    int unsigned start_cyc;        
    int unsigned n_latched;        
    int unsigned exp_cyc;          
    logic        flow_q;           
    logic        start_q;          

    bit          have_prev_flow;   
    int unsigned last_flow_cyc;    
    int unsigned init_interval;   
    int unsigned observed_latency; 

    bit          have_start;         
    int unsigned start_edge_cyc;    

    int unsigned n_ops_completed;    
    int unsigned n_latency_fail = 0; 

    wire flow_rise = flow_en & ~flow_q & (dim_n >= 3'd1) & (dim_n <= N[2:0]);  

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            in_flight        <= 1'b0;
            free_cyc         <= '0;
            start_cyc        <= '0;
            n_latched        <= '0;
            exp_cyc          <= '0;
            flow_q           <= 1'b0;
            start_q          <= 1'b0;
            have_prev_flow   <= 1'b0;
            last_flow_cyc    <= '0;
            init_interval    <= '0;
            observed_latency <= '0;
            have_start       <= 1'b0;
            start_edge_cyc   <= '0;
            n_ops_completed  <= '0;
        end
        else begin
            free_cyc <= free_cyc + 1;  
            flow_q   <= flow_en;        
            start_q  <= start;          

            
            if (start & ~start_q) begin
                start_edge_cyc <= free_cyc;   
                have_start     <= 1'b1;      
            end

           
            if (flow_rise && !in_flight) begin
                in_flight <= 1'b1;               
                start_cyc <= free_cyc;           
                n_latched <= dim_n;              
                exp_cyc   <= exp_latency(dim_n); 

                
                if (have_start)
                    $display("[PERF] control overhead: start->flow_en = %0d cyc (AXI + WEIGHT_LOAD + PE_CLEAR; not part of the latency contract)",
                             free_cyc - start_edge_cyc);

                
                if (have_prev_flow) begin
                    init_interval <= free_cyc - last_flow_cyc;
                    $display("[PERF] throughput: II=%0d cyc, idle_gap=%0d cyc (prev op latency=%0d)",
                             free_cyc - last_flow_cyc,
                             (free_cyc - last_flow_cyc) - observed_latency,
                             observed_latency);
                end
                last_flow_cyc  <= free_cyc;   
                have_prev_flow <= 1'b1;        
            end

            
            if (in_flight && done) begin
                observed_latency <= free_cyc - start_cyc;   
                n_ops_completed  <= n_ops_completed + 1;  
                in_flight        <= 1'b0;                   
                $display("[PERF] latency: N=%0d observed=%0d expected=%0d cyc %s",
                         n_latched, free_cyc - start_cyc, exp_cyc,
                         ((free_cyc - start_cyc) == exp_cyc) ? "PASS" : "FAIL");  
            end
        end
    end

    a_latency_exact: assert property (
        @(posedge clk) disable iff (!rst_n)  
        (in_flight && done) |-> ((free_cyc - start_cyc) == exp_cyc)   
    ) else begin
        n_latency_fail++;                      
        $error("[PERF] LATENCY VIOLATION: N=%0d observed=%0d expected=%0d cycles (flow_en->done)",
               $sampled(n_latched),             
               $sampled(free_cyc) - $sampled(start_cyc),  
               $sampled(exp_cyc));              
    end

    
    a_no_missing_done: assert property (
        @(posedge clk) disable iff (!rst_n)
        (in_flight && ((free_cyc - start_cyc) == (exp_cyc + 1))) |-> done   
    ) else begin
        n_latency_fail++;
        $error("[PERF] LATENCY VIOLATION: N=%0d done still not asserted %0d cycles after flow start (expected %0d)",
               $sampled(n_latched),
               $sampled(free_cyc) - $sampled(start_cyc),
               $sampled(exp_cyc));
    end

    a_watchdog: assert property (
        @(posedge clk) disable iff (!rst_n)
        (in_flight && ((free_cyc - start_cyc) == LATENCY_WATCHDOG)) |-> done   
    ) else
        $error("[PERF] WATCHDOG: N=%0d no done within %0d cycles of flow start - DUT appears hung",
               $sampled(n_latched), LATENCY_WATCHDOG);

    
    final begin
        $display("==== mmu_perf_checker summary: %0d ops completed, %0d latency failure(s) [%s contract] ====",
                 n_ops_completed,                              
                 n_latency_fail,                                
                 use_spec_2n ? "2N (plan)" : "dim+5 (as-built)"); 
    end

endmodule : mmu_perf_checker

`endif // MMU_PERF_CHECKER_SV
