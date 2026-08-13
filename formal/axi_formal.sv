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
// Note, just as sva file, all signals are inputs, as we are not outputting anything here, only verifying
    
    input logic        clk,
    input logic        rst_n, // active low

    // write-address channel signals, same as all axi-lite related files
    input logic [3:0]  awaddr,
    input logic        awvalid,
    input logic        awready,

    // write-data channel
    input logic [31:0] wdata,
    input logic [3:0]  wstrb,
    input logic        wvalid,
    input logic        wready,

    // write-response channel
    input logic [1:0]  bresp,
    input logic        bvalid,
    input logic        bready,

    // read-address channel
    input logic [3:0]  araddr,
    input logic        arvalid,
    input logic        arready,

    // read-data channel
    input logic [31:0] rdata,
    input logic [1:0]  rresp,
    input logic        rvalid,
    input logic        rready,

    // TPU funciton signals: i.e. internal signals decoded
    input logic        start,
    input logic [2:0]  dim_n,
    input logic        done,
    input logic [2:0]  dim_q,   // internal, bound by name
    input logic        ctrl_q   // internal, bound by name
);

    localparam logic [3:0] ADDR_STATUS = 4'h8; // the address of the status register
    localparam logic [1:0] RESP_OKAY   = 2'b00; //the valid response encoding used throughout the project

    // ---------------------------------------------------------------
    // 2a — AWVALID stability (ASSUME — see header note).
    // ---------------------------------------------------------------

    // Functionally, the same as A1, except this assume only dictates that the address valid remain steady, not the VALUE of the address itself
    // In other words, since the property is weaker, it allows the machine to explore a larger state-space of unconstrained address values.
    
    ap_awvalid_stable: assume property (
        @(posedge clk) disable iff (!rst_n)
        (awvalid && !awready) |=> awvalid
    );

    // covering the property, checking the scenario above is actually reachable in this formal model
    cp_awvalid_held: cover property (
        @(posedge clk) disable iff (!rst_n)
        awvalid && !awready ##1 awvalid
    );

    // ---------------------------------------------------------------
    // 2b — STATUS_REG read-only enforcement.
    // Note: the extra "|| $past(!rst_n,...)" guard on disable_iff matches
    // BUGS.md Bug 2/4's lesson — skip the first post-reset cycle so $past
    // never reasons about a pre-reset value, even though this RTL happens
    // to reset all relevant registers to defined 0s (cheap insurance).
    // ---------------------------------------------------------------

    // The core claim: a write to STATUS_REG never leaks into the only
    // registers this module can actually write (dim_q, ctrl_q).
    //so, we intend to write to the status register...
    //and check to see if NOTHING changed.
        
    ap_status_write_no_leak: assert property (
        @(posedge clk)
        disable iff (!rst_n || $past(!rst_n, 1, 1'b1, @(posedge clk))) // we disable on a reset this cycle, or on a reset LAST cycle
        (awvalid && wvalid && !bvalid && (awaddr == ADDR_STATUS)) // a write is being accepted, no response issued yet, and the write is TO the status register
        |=> (dim_q == $past(dim_q)) && (ctrl_q == $past(ctrl_q)) // neither dimension nor the ctrl value should change due to this
    );

    // Handshake still completes normally (B.2: "the handshake still
    // completes, we just don't store" — write is accepted, not rejected).
    ap_status_write_gets_okay: assert property (
        @(posedge clk)
        disable iff (!rst_n || $past(!rst_n, 1, 1'b1, @(posedge clk)))
        (awvalid && wvalid && !bvalid && (awaddr == ADDR_STATUS)) // same thing, a write accepted, no response yet, TO the status register
        |=> (bvalid && bresp == RESP_OKAY) // we don't want to throw an error, we simply accept the write and discard it with no changes to anything
    );

    // Read-side decode correctness: a STATUS read always reflects the live
    // `done` value sampled at accept time. This checks the mux/decode
    // logic, not done's stability, so the free-input concern above doesn't
    // apply here — done can be anything, the property just checks it was
    // wired through correctly.
    ap_status_read_reflects_done: assert property (
        @(posedge clk)
        disable iff (!rst_n || $past(!rst_n, 1, 1'b1, @(posedge clk)))
        (arvalid && !rvalid && (araddr == ADDR_STATUS)) // a status read is being accepted...
        |=> (rdata == {31'b0, $past(done)}) // then rdata should equal the value of done from the previous cycle, sign extended to 32 bits
    );

    // below covers that the STATUS write accepted scenario actually occured
    cp_status_write_hits: cover property (
        @(posedge clk) disable iff (!rst_n)
        (awvalid && wvalid && !bvalid && (awaddr == ADDR_STATUS))
    );

    // ---------------------------------------------------------------
    // 2c — No spurious write response (no phantom BVALID).
    // This RTL accepts the address and data phase together in one cycle
    // (awvalid && wvalid && !bvalid), not as two separately-timed phases —
    // so "both phases completed" collapses to that single accept condition
    // for this specific implementation.
    // ---------------------------------------------------------------
    ap_no_spurious_bvalid: assert property (
        @(posedge clk)
        disable iff (!rst_n || $past(!rst_n, 1, 1'b1, @(posedge clk)))
        bvalid |-> ($past(bvalid) || $past(awvalid && wvalid && !bvalid)) // if bvalid is high NOW, then on the same cycle...
        // bvalid was either already high on last cycle, or last cycle had a legitimate write-accept condition: BOTH awvalid AND wvalid, address and data sent on the same cycle
    );

    // Q: does bvalid actually go high, ever? Hence, we cover the property.
    cp_bvalid_reachable: cover property (
        @(posedge clk) disable iff (!rst_n)
        bvalid
    );

endmodule : axi_formal_checker

bind axi_lite_slave axi_formal_checker axi_formal_checker_i (.*);
