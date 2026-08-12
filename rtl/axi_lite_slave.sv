//==============================================================================
// File: axi_lite_slave.sv   (heavily-commented reading version)
// Project: sv-tpu-core.
//
// WHAT THIS MODULE IS, IN ONE BREATH:
//   This file is the chip's control panel: it lets the outside world (a CPU) 
//   set the matrix size, press start, and check if it's done. Its inputs 
//   receive the CPU's commands over the AXI bus (awvalid, wdata, araddr, etc.) 
//   plus the done signal from the controller. Its outputs send responses back 
//   to the CPU (rdata, bvalid, etc.) and hand the rest of the chip the simple 
//   signals it actually uses (start, dim_n).

//   It's the "control panel" of the chip. The outside world (a CPU, or in our
//   case the UVM testbench pretending to be one) talks to it over a bus called
//   AXI-Lite to do three things:
//       - set the matrix size      (write DIM_REG)
//       - press "start"            (write CTRL_REG)
//       - check "are you done?"    (read  STATUS_REG)
//   It does NO math. It just receives those commands, stores them, and hands
//   the rest of the chip dead-simple signals (start, dim_n) while reporting
//   done back out. Think: the keypad + display on a microwave, not the part
//   that cooks.
//
//   The FSM that actually runs the computation (mmu_controller.sv) is a
//   SEPARATE module. This file never does control flow — it's just a register
//   file + the AXI-Lite handshake.
//==============================================================================

// timescale: "1 time unit = 1 nanosecond, simulate down to 1 picosecond."
// This is what makes a testbench's `#5` mean 5 ns. Every file agrees on this.
`timescale 1ns/1ps

// ---- module + parameters --------------------------------------------------
// A "parameter" is an adjustable constant with a default. We could override
// these when we instantiate the module, but if we don't, these values apply.
// They're chosen to match mmu_if.sv EXACTLY — that's what lets this module
// plug into the interface. (Change them here without changing mmu_if and the
// pieces stop fitting.)
module axi_lite_slave #(
    parameter int ADDR_W = 4,    // addresses are 4 bits (enough for 0x0..0x8)
    parameter int AXI_W  = 32,   // data bus is 32 bits wide
    parameter int DIM_W  = 3     // DIM_REG is a 3-bit field (holds N)
)(
    // ---- the clock + reset --------------------------------------------------
    input  logic              clk,      // heartbeat: registers update on its tick
    input  logic              rst_n,    // reset. "_n" = active-LOW: resets when 0

    // ======================================================================
    // AXI-Lite is split into separate "lanes" (channels). Each transfer uses
    // a two-signal HANDSHAKE: one side raises "valid" (my info is ready), the
    // other raises "ready" (ok, I took it). A transfer happens the cycle both
    // are high. That handshake is the heart of the whole protocol.
    // ======================================================================

    // ---- WRITE ADDRESS channel: "which register am I writing?" -------------
    input  logic [ADDR_W-1:0] awaddr,    // the target address
    input  logic              awvalid,   // master: "address is valid"
    output logic              awready,   // us:     "got the address"

    // ---- WRITE DATA channel: "here's the value" ----------------------------
    input  logic [AXI_W-1:0]  wdata,     // the value being written
    input  logic [3:0]        wstrb,     // byte-enables (we ignore these; see note 6)
    input  logic              wvalid,    // master: "data is valid"
    output logic              wready,    // us:     "got the data"

    // ---- WRITE RESPONSE channel: the "receipt" after a write ---------------
    output logic [1:0]        bresp,     // 00 = OKAY, 10 = SLVERR (error) (whether the write succeeded)
    output logic              bvalid,    // us:     "receipt is ready"
    input  logic              bready,    // master: "I took the receipt"

    // ---- READ ADDRESS channel: "which register do I want to read?" ---------
    input  logic [ADDR_W-1:0] araddr,
    input  logic              arvalid,   // master: "read address is valid"
    output logic              arready,   // us:     "got it"

    // ---- READ DATA channel: the value we hand back -------------------------
    output logic [AXI_W-1:0]  rdata,     // the value being read out
    output logic [1:0]        rresp,     // 00 = OKAY, 10 = SLVERR
    output logic              rvalid,    // us:     "read data is ready"
    input  logic              rready,    // master: "I took the data"

    // ======================================================================
    // The SIMPLE side — the whole reason this module exists. These are plain
    // wires to the rest of the chip, with none of the AXI complexity. The
    // controller/array use THESE, not the bus.
    // ======================================================================
    output logic              start,     // = CTRL_REG bit 0. Tells controller "go".
    output logic [DIM_W-1:0]  dim_n,     // = DIM_REG value. The active matrix size N.

    input  logic              done       // comes FROM the controller; we report it
                                          // back out as STATUS_REG. (read-through)
);

    // ---- named constants (localparam = a constant you CAN'T override) ------
    // Using names instead of raw numbers makes the code readable and prevents
    // typo bugs (writing 4'h5 when you meant CTRL_REG's 4'h4 would be nasty).
    localparam logic [ADDR_W-1:0] ADDR_DIM    = 4'h0;  // DIM_REG   lives here
    localparam logic [ADDR_W-1:0] ADDR_CTRL   = 4'h4;  // CTRL_REG  lives here
    localparam logic [ADDR_W-1:0] ADDR_STATUS = 4'h8;  // STATUS_REG lives here

    localparam logic [1:0] RESP_OKAY   = 2'b00;  // AXI "all good"
    localparam logic [1:0] RESP_SLVERR = 2'b10;  // AXI "bad address" error

    // ---- the actual storage boxes ------------------------------------------
    // These two registers ARE the memory of DIM_REG and CTRL_REG. The "_q"
    // suffix is a convention meaning "this is a stored/registered value"
    // (same convention pe.sv uses with weight_q).
    //
    // NOTE there is deliberately NO storage box for STATUS_REG. We read the
    // live `done` input straight through at read time. Because there's nothing
    // stored, a write can't corrupt it — that's how STATUS stays truly
    // read-only "for free" (this is what Formal Proof 2 will prove).
    logic [DIM_W-1:0] dim_q;    // holds DIM_REG
    logic             ctrl_q;   // holds CTRL_REG bit 0

    // "assign" = a permanent wire, always true. The instant dim_q changes,
    // the outside world sees it on dim_n. Same for start = ctrl_q.
    assign dim_n = dim_q;
    assign start = ctrl_q;

    // ========================================================================
    // WRITE PATH
    // always_ff = "this block describes flip-flops (storage)."
    // It wakes up on a rising clock edge, OR the instant reset drops low.
    // The whole job: accept a write handshake -> decode the address -> store
    // the value -> send the receipt.
    // ========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            // ---- RESET: slam everything to a known-safe state. On real
            // hardware values are garbage until reset, so this guarantees a
            // clean starting point. ("<=" means "update on the clock edge",
            // which is how real flip-flops behave. "'0" = all zeros.)
            awready <= 1'b0;
            wready  <= 1'b0;
            bvalid  <= 1'b0;
            bresp   <= RESP_OKAY;
            dim_q   <= '0;
            ctrl_q  <= 1'b0;
        end else begin
            // ---- Every cycle, ASSUME we're not accepting a write. We'll only
            // raise these if a write actually shows up this cycle. Defaulting
            // them low gives clean one-cycle "yes I took it" pulses.
            awready <= 1'b0;
            wready  <= 1'b0;

            // ---- ACCEPT CONDITION:
            // Master has BOTH an address (awvalid) AND data (wvalid) ready,
            // AND we're not still busy delivering a previous receipt (!bvalid).
            // The !bvalid guard stops two writes from colliding.
            if (awvalid && wvalid && !bvalid) begin

                // say "got your address and data" for this one cycle
                awready <= 1'b1;
                wready  <= 1'b1;

                // ---- DECODE: look at the address, update the right box.
                // This "case" is like a switch statement on the address.
                case (awaddr)
                    // DIM_REG: keep the bottom 3 bits (it's a 3-bit register).
                    // We store WHATEVER was written, even illegal sizes like
                    // 0 or 7 — rejecting those is the CONTROLLER's job (note 2).
                    ADDR_DIM:    dim_q  <= wdata[DIM_W-1:0];

                    // CTRL_REG: keep just bit 0 (the start bit).
                    ADDR_CTRL:   ctrl_q <= wdata[0];

                    // STATUS_REG: it's READ-ONLY, so a write does NOTHING here.
                    // The handshake still completes, we just don't store.
                    ADDR_STATUS: /* ignore write, done bit unaffected */ ;

                    // any other address: unmapped, store nothing.
                    default:     /* ignore */ ;
                endcase

                // ---- SEND THE RECEIPT.
                bvalid <= 1'b1;
                // A write to one of our 3 real registers is OKAY (STATUS
                // included — the handshake succeeded even though the write did
                // nothing). A write to a garbage address gets SLVERR.
                // ( "? :" reads as: condition ? value-if-true : value-if-false )
                bresp  <= (awaddr == ADDR_DIM  ||
                           awaddr == ADDR_CTRL ||
                           awaddr == ADDR_STATUS) ? RESP_OKAY : RESP_SLVERR;

            end else if (bvalid && bready) begin
                // ---- Receipt was out (bvalid) and master took it (bready):
                // handshake done, lower the flag, ready for the next write.
                bvalid <= 1'b0;
            end
        end
    end

    // ========================================================================
    // READ PATH
    // Exact same shape as the write path — once you get one, you get both.
    // Job: accept a read handshake -> pick the right value by address ->
    // hand it back with a receipt.
    // ========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            // ---- RESET: clean, known state.
            arready <= 1'b0;
            rvalid  <= 1'b0;
            rresp   <= RESP_OKAY;
            rdata   <= '0;
        end else begin
            // default: not accepting a read this cycle (one-cycle pulse).
            arready <= 1'b0;

            // ACCEPT: master wants to read (arvalid) and we're not already
            // holding read data out (!rvalid).
            if (arvalid && !rvalid) begin
                arready <= 1'b1;   // "got your read address"
                rvalid  <= 1'b1;   // "and here's the data"

                // pick WHICH value to return based on the address.
                // Each value is only a few bits but rdata is 32 bits wide, so
                // we glue zeros in front to fill it out. "{29'b0, dim_q}" means
                // "29 zeros followed by the 3-bit dim_q" = a full 32-bit word.
                case (araddr)
                    ADDR_DIM: begin
                        rdata <= {{(AXI_W-DIM_W){1'b0}}, dim_q};
                        rresp <= RESP_OKAY;
                    end
                    ADDR_CTRL: begin
                        rdata <= {{(AXI_W-1){1'b0}}, ctrl_q};
                        rresp <= RESP_OKAY;
                    end
                    ADDR_STATUS: begin
                        // READ-THROUGH: return the LIVE done signal, not a
                        // stored copy. Whatever the controller is asserting
                        // right now is what a STATUS read reports. Always
                        // current, never stale.
                        rdata <= {{(AXI_W-1){1'b0}}, done};
                        rresp <= RESP_OKAY;
                    end
                    default: begin
                        // unmapped address: hand back 0 and an error.
                        rdata <= '0;
                        rresp <= RESP_SLVERR;
                    end
                endcase

            end else if (rvalid && rready) begin
                // data was out (rvalid) and master took it (rready): done,
                // lower the flag, ready for the next read.
                rvalid <= 1'b0;
            end
        end
    end

endmodule

