// =============================================================================
// File:        axi_lite_sva.sv
// Commented:   August 13, 2026
// Description: Protocol checker (SVA) for the AXI-Lite bus interface. Binds
//              onto axi_lite_slave.sv from the outside and has no knowledge
//              of matrix multiply, DIM_REG, or done — it only watches the
//              handshake wires and fires assertions the instant the bus
//              master violates the AXI-Lite protocol: awvalid/awaddr must
//              hold stable until awready, wvalid/wdata must hold stable
//              until wready, arvalid/araddr must hold stable until arready,
//              and rvalid/rdata must hold stable until rready, per the AMBA
//              AXI Protocol Spec.
// =============================================================================

`timescale 1ns/1ps

module axi_lite_sva #(
    parameter int ADDR_W = 4, // address width is 4 bits, consistent with register model and slave
    parameter int AXI_W  = 32 // axi-lite data width is 32 bits
)(
    input logic clk,
    input logic rst_n, // active low

    // the below signals are the same as in the axi_lite_slave.sv
    // Here, we have the write protocol signals
    // ***NOTE: all of the signals are coming in as inputs, even the ready signals, which (from the slave's perspective), are outputs.
    
    // WRITE ADDRESS channel
    input logic [ADDR_W-1:0] awaddr, 
    input logic              awvalid,
    input logic              awready,

    // WRITE DATA channel
    input logic [AXI_W-1:0]  wdata,
    input logic              wvalid,
    input logic              wready,

    // the below signals cover the read protocol, same note as above applies:
    // all signals are inputs here, even arready/rvalid which are slave outputs.

    // READ ADDRESS channel
    input logic [ADDR_W-1:0] araddr,
    input logic              arvalid,
    input logic              arready,

    // READ DATA channel
    input logic [AXI_W-1:0]  rdata,
    input logic              rvalid,
    input logic              rready
);

    // ==========================================================================
    // A1 — axi_awvalid_stable
    //
    // ENGLISH: "Once you raise your hand (awvalid) and declare a destination 
    // (awaddr), keep them BOTH exactly the same until the reciever calls on 
    // you (awready). Don't put your hand down, and don't change your answer."
    //
    // WHY IT MATTERS: A master that drops awvalid early or silently mutates 
    // the address mid-transaction causes catastrophic, hard-to-debug data 
    // corruption.
    // ==========================================================================
    property axi_awvalid_stable;
        @(posedge clk) disable iff (!rst_n) // evaluated on posedge clock, not evaluated when reset is low (active)
        awvalid && !awready |=> awvalid && $stable(awaddr); 
        // if address is valid, and reciever has not yet recieved data...
        // Then on the next cycle, the address should remain valid, and the value of the address should be the same as the last cycle.
    endproperty

    // asserting the property, with proper error statement
    a_axi_awvalid_stable: assert property (axi_awvalid_stable)
        else
            $error("A1 PROTOCOL VIOLATION: awvalid dropped or awaddr changed before awready. awaddr=0x%0h", 
                   awaddr);

    // ==========================================================================
    // A2 — axi_wvalid_stable
    //
    // ENGLISH: "Once you offer the data (wvalid) and the payload (wdata), 
    // keep them BOTH exactly the same until the slave accepts it (wready)."
    //
    // WHY IT MATTERS: The write data channel follows the exact same stability
    // rules as the address channel. The AMBA spec explicitly forbids a master
    // from altering the data payload while waiting for wready.
    // ==========================================================================
    property axi_wvalid_stable;
        @(posedge clk) disable iff (!rst_n)
            wvalid && !wready |=> wvalid && $stable(wdata);
        // An equivalent condition as the above, except for the data.
        // If the data is valid, but has not yet been recieved...
        // On the next cycle, the data should still be valid, and the data's value should be the same as last cycle.
    endproperty

    // asserting the property, and clarative error statement.
    a_axi_wvalid_stable: assert property (axi_wvalid_stable)
        else
            $error("A2 PROTOCOL VIOLATION: wvalid dropped or wdata changed before wready. wdata=0x%0h", 
                   wdata);

    // ==========================================================================
    // A3 — axi_arvalid_stable
    //
    // ENGLISH: "Once you raise your hand (arvalid) and declare a destination
    // (araddr), keep them BOTH exactly the same until the reciever calls on
    // you (arready). Don't put your hand down, and don't change your answer."
    //
    // WHY IT MATTERS: Same failure mode as A1, but for reads — a master that
    // drops arvalid early or silently mutates araddr mid-transaction can
    // cause the slave to service the wrong address, silently corrupting
    // whatever data gets read back.
    // ==========================================================================
    property axi_arvalid_stable;
        @(posedge clk) disable iff (!rst_n) // evaluated on posedge clock, not evaluated when reset is low (active)
        arvalid && !arready |=> arvalid && $stable(araddr);
        // if address is valid, and reciever has not yet recieved the request...
        // Then on the next cycle, the address should remain valid, and the value of the address should be the same as the last cycle.
    endproperty

    // asserting the property, with proper error statement
    a_axi_arvalid_stable: assert property (axi_arvalid_stable)
        else
            $error("A3 PROTOCOL VIOLATION: arvalid dropped or araddr changed before arready. araddr=0x%0h", 
                   araddr);

    // ==========================================================================
    // A4 — axi_rvalid_stable
    //
    // ENGLISH: "Once you offer the data (rvalid) and the payload (rdata),
    // keep them BOTH exactly the same until the master accepts it (rready)."
    //
    // WHY IT MATTERS: The read data channel follows the exact same stability
    // rules as the write data channel. The AMBA spec explicitly forbids a
    // slave from altering the read payload while waiting for rready.
    // ==========================================================================
    property axi_rvalid_stable;
        @(posedge clk) disable iff (!rst_n)
            rvalid && !rready |=> rvalid && $stable(rdata);
        // An equivalent condition as A2, except this is slave-driven, not master-driven.
        // If the read data is valid, but has not yet been recieved...
        // On the next cycle, the data should still be valid, and the data's value should be the same as last cycle.
    endproperty

    // asserting the property, and clarative error statement.
    a_axi_rvalid_stable: assert property (axi_rvalid_stable)
        else
            $error("A4 PROTOCOL VIOLATION: rvalid dropped or rdata changed before rready. rdata=0x%0h", 
                   rdata);

endmodule : axi_lite_sva


// ==============================================================================
// NOTE ON BINDING — deliberately NOT done in this file.
//
// tb_top.sv owns the bind statements. 
// 
// WARNING: When you uncomment the bind statement in tb_top.sv, you MUST ensure 
// the parameters are explicitly passed. If you leave the parameter overrides 
// out, this checker will silently fall back to ADDR_W=4, AXI_W=32 and will 
// shatter your simulation with port-width mismatch errors the moment the DUT 
// changes size.
//
// The line in tb_top.sv MUST look exactly like this:
//
//     bind axi_lite_slave axi_lite_sva #(.ADDR_W(ADDR_W), .AXI_W(AXI_W))
//         axi_sva_i (.*);
//
// Do NOT use: bind axi_lite_slave axi_lite_sva axi_sva_i (.*);
// ==============================================================================
