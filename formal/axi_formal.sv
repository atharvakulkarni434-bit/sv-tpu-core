// =============================================================================
// File:        axi_formal.sv
// Commented:   August 13, 2026
// Description: Formal proof (JasperGold) for AXI-Lite protocol compliance,
//              Proof 2 of the sv-tpu-core formal suite. Binds onto
//              axi_lite_slave.sv and checks two classes of property: 2a
//              (AWVALID stability) is modeled as an ASSUME rather than an
//              ASSERT, since awvalid is a free primary input with no
//              synthesizable master RTL in this project to hold accountable
//              — the same role ap_accum_in_bounded played for Proof 1. 2b
//              (STATUS_REG is read-only — a STATUS write never leaks into
//              dim_q/ctrl_q, and still completes with BRESP=OKAY) and 2c
//              (no spurious BVALID) are real asserts about the slave
//              itself. Run via axi_compliance.tcl.
// =============================================================================

module axi_formal_checker (    
    input logic        clk,
    input logic        rst_n, // active low

    input logic [3:0]  awaddr,
    input logic        awvalid,
    input logic        awready,

    input logic [31:0] wdata,
    input logic [3:0]  wstrb,
    input logic        wvalid,
    input logic        wready,

    input logic [1:0]  bresp,
    input logic        bvalid,
    input logic        bready,

    input logic [3:0]  araddr,
    input logic        arvalid,
    input logic        arready,

    input logic [31:0] rdata,
    input logic [1:0]  rresp,
    input logic        rvalid,
    input logic        rready,

    input logic        start,
    input logic [2:0]  dim_n,
    input logic        done,
    input logic [2:0]  dim_q,   
    input logic        ctrl_q  
);

    localparam logic [3:0] ADDR_STATUS = 4'h8; 
    localparam logic [1:0] RESP_OKAY   = 2'b00;

    ap_awvalid_stable: assume property (
        @(posedge clk) disable iff (!rst_n)
        (awvalid && !awready) |=> awvalid
    );

    cp_awvalid_held: cover property (
        @(posedge clk) disable iff (!rst_n)
        awvalid && !awready ##1 awvalid
    );
        
    ap_status_write_no_leak: assert property (
        @(posedge clk)
        disable iff (!rst_n || $past(!rst_n, 1, 1'b1, @(posedge clk))) 
        (awvalid && wvalid && !bvalid && (awaddr == ADDR_STATUS)) 
        |=> (dim_q == $past(dim_q)) && (ctrl_q == $past(ctrl_q)) 
    );

    ap_status_write_gets_okay: assert property (
        @(posedge clk)
        disable iff (!rst_n || $past(!rst_n, 1, 1'b1, @(posedge clk)))
        (awvalid && wvalid && !bvalid && (awaddr == ADDR_STATUS)) 
        |=> (bvalid && bresp == RESP_OKAY) 
    );

    ap_status_read_reflects_done: assert property (
        @(posedge clk)
        disable iff (!rst_n || $past(!rst_n, 1, 1'b1, @(posedge clk)))
        (arvalid && !rvalid && (araddr == ADDR_STATUS)) 
        |=> (rdata == {31'b0, $past(done)}) 
    );

    cp_status_write_hits: cover property (
        @(posedge clk) disable iff (!rst_n)
        (awvalid && wvalid && !bvalid && (awaddr == ADDR_STATUS))
    );

    ap_no_spurious_bvalid: assert property (
        @(posedge clk)
        disable iff (!rst_n || $past(!rst_n, 1, 1'b1, @(posedge clk)))
        bvalid |-> ($past(bvalid) || $past(awvalid && wvalid && !bvalid)) 
    );

    cp_bvalid_reachable: cover property (
        @(posedge clk) disable iff (!rst_n)
        bvalid
    );

endmodule : axi_formal_checker

bind axi_lite_slave axi_formal_checker axi_formal_checker_i (.*);
