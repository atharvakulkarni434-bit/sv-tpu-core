//==============================================================================
// File: axi_lite_sva.sv   (Corrected version)
// Project: sv-tpu-core
//
// WHAT THIS FILE IS, IN ONE BREATH:
//   This is the "rulebook checker" for the AXI-Lite bus itself. It doesn't
//   know or care about matrix multiply, DIM_REG, or done. It only watches the
//   handshake wires (awvalid/awready/wvalid/...) and screams (fires an
//   assertion) the instant the bus master violates the AXI-Lite protocol.
//
//   It is bound onto axi_lite_slave.sv from the outside.
//
//   Two properties live here, strictly following the AMBA AXI Protocol Spec:
//       A1 — once awvalid rises, awvalid and awaddr must stay stable until 
//            awready takes it.
//       A2 — once wvalid rises, wvalid and wdata must stay stable until 
//            wready takes it.
//
//   (NOTE: Previous versions of this file incorrectly assumed awvalid and 
//   wvalid had to assert on the same cycle. AXI-Lite channels are independent; 
//   that check has been removed to prevent false failures).
//==============================================================================

`timescale 1ns/1ps

module axi_lite_sva #(
    parameter int ADDR_W = 4,
    parameter int AXI_W  = 32
)(
    input logic clk,
    input logic rst_n,

    // WRITE ADDRESS channel
    input logic [ADDR_W-1:0] awaddr,
    input logic              awvalid,
    input logic              awready,

    // WRITE DATA channel
    input logic [AXI_W-1:0]  wdata,
    input logic              wvalid,
    input logic              wready
);

    // ==========================================================================
    // A1 — axi_awvalid_stable
    //
    // ENGLISH: "Once you raise your hand (awvalid) and declare a destination 
    // (awaddr), keep them BOTH exactly the same until the teacher calls on 
    // you (awready). Don't put your hand down, and don't change your answer."
    //
    // WHY IT MATTERS: A master that drops awvalid early or silently mutates 
    // the address mid-transaction causes catastrophic, hard-to-debug data 
    // corruption.
    // ==========================================================================
    property axi_awvalid_stable;
        @(posedge clk) disable iff (!rst_n)
            awvalid && !awready |=> awvalid && $stable(awaddr);
    endproperty

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
    endproperty

    a_axi_wvalid_stable: assert property (axi_wvalid_stable)
        else
            $error("A2 PROTOCOL VIOLATION: wvalid dropped or wdata changed before wready. wdata=0x%0h", 
                   wdata);

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
