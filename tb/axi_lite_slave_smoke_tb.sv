// =============================================================================
// axi_lite_slave_smoke_tb.sv — standalone smoke test for axi_lite_slave.sv
//
// Same spirit as pe_smoke_tb.sv: drive the inputs, watch the outputs, print
// PASS/FAIL per check. NO UVM, NO agent, NO adapter, NO controller — this TB
// pretends to be the outside world (a CPU) talking AXI-Lite directly, and
// fakes the `done` signal that mmu_controller.sv will drive later.
//
// Proves, standalone:
//   T1  reset leaves start=0, dim_n=0
//   T2  DIM_REG write -> readback, and dim_n decode
//   T3  CTRL_REG write -> start goes high, then software clears it
//   T4  STATUS_REG is read-only (write completes OKAY, done bit unaffected)
//   T5  STATUS_REG reads the live `done` value both ways (read-through)
//   T6  unmapped address returns SLVERR on both write and read
//   T7  DIM_REG stores raw illegal values (N=0, N=7) — controller rejects later
//   (handshakes never hanging is proven implicitly: every task returns, and a
//    watchdog fails loudly if one ever stalls)
//
// RUN (once Xcelium is set up):
//   xrun -sv rtl/axi_lite_slave.sv tb/axi_lite_slave_smoke_tb.sv
// =============================================================================

`timescale 1ns/1ps

module axi_lite_slave_smoke_tb;

    // ---- DUT parameters (defaults from axi_lite_slave.sv / mmu_if.sv) ----
    localparam int ADDR_W = 4;
    localparam int AXI_W  = 32;
    localparam int DIM_W  = 3;

    // ---- register offsets (must match the slave) ----
    localparam logic [ADDR_W-1:0] ADDR_DIM    = 4'h0;
    localparam logic [ADDR_W-1:0] ADDR_CTRL   = 4'h4;
    localparam logic [ADDR_W-1:0] ADDR_STATUS = 4'h8;
    localparam logic [ADDR_W-1:0] ADDR_BAD    = 4'hC;  // deliberately unmapped

    localparam logic [1:0] RESP_OKAY   = 2'b00;
    localparam logic [1:0] RESP_SLVERR = 2'b10;

    // ---- signals: names match the DUT ports so `.*` connects them ----
    logic              clk;
    logic              rst_n;
    // write address
    logic [ADDR_W-1:0] awaddr;
    logic              awvalid;
    logic              awready;
    // write data
    logic [AXI_W-1:0]  wdata;
    logic [3:0]        wstrb;
    logic              wvalid;
    logic              wready;
    // write response
    logic [1:0]        bresp;
    logic              bvalid;
    logic              bready;
    // read address
    logic [ADDR_W-1:0] araddr;
    logic              arvalid;
    logic              arready;
    // read data
    logic [AXI_W-1:0]  rdata;
    logic [1:0]        rresp;
    logic              rvalid;
    logic              rready;
    // decoded outputs + status input
    logic              start;
    logic [DIM_W-1:0]  dim_n;
    logic              done;

    // ---- captured responses from the last transaction ----
    logic [1:0]        last_bresp;
    logic [1:0]        last_rresp;

    int pass_count = 0;
    int fail_count = 0;

    // ---- DUT ----
    axi_lite_slave #(.ADDR_W(ADDR_W), .AXI_W(AXI_W), .DIM_W(DIM_W)) dut (.*);

    // ---- clock: 100 MHz ----
    initial clk = 1'b0;
    always #5 clk = ~clk;

    // ---- watchdog: if any handshake ever hangs, fail loudly ----
    initial begin
        #100us;
        $display("  FAIL  WATCHDOG: a handshake hung — simulation never finished");
        $fatal(1, "watchdog timeout");
    end

    // -------------------------------------------------------------------------
    // check — compare a value against expectation, tally pass/fail
    // -------------------------------------------------------------------------
    task automatic check(string name, logic [AXI_W-1:0] got, logic [AXI_W-1:0] exp);
        if (got === exp) begin
            pass_count++;
            $display("  PASS  %-46s got=%0d", name, got);
        end else begin
            fail_count++;
            $display("  FAIL  %-46s got=%0d exp=%0d", name, got, exp);
        end
    endtask

    // -------------------------------------------------------------------------
    // axi_write — one AXI-Lite write. Presents AW+W together (the slave accepts
    // them together), waits for the accept, then completes the B response.
    // Captures BRESP into last_bresp.
    // -------------------------------------------------------------------------
    task automatic axi_write(logic [ADDR_W-1:0] addr, logic [AXI_W-1:0] data);
        awaddr  = addr;
        wdata   = data;
        wstrb   = 4'hF;
        awvalid = 1'b1;
        wvalid  = 1'b1;
        bready  = 1'b1;
        // wait until the slave accepts address+data
        forever begin @(posedge clk); #1; if (awready && wready) break; end
        awvalid = 1'b0;
        wvalid  = 1'b0;
        // bvalid is asserted on the same edge as the accept — capture it
        forever begin if (bvalid) break; @(posedge clk); #1; end
        last_bresp = bresp;
        // one more edge with bready still high lets the slave clear bvalid
        @(posedge clk); #1;
        bready = 1'b0;
    endtask

    // -------------------------------------------------------------------------
    // axi_read — one AXI-Lite read. Returns the read data; captures RRESP.
    // -------------------------------------------------------------------------
    task automatic axi_read(logic [ADDR_W-1:0] addr, output logic [AXI_W-1:0] data);
        araddr  = addr;
        arvalid = 1'b1;
        rready  = 1'b1;
        forever begin @(posedge clk); #1; if (arready) break; end
        arvalid = 1'b0;
        // rvalid asserted on the same edge as arready — data is ready
        forever begin if (rvalid) break; @(posedge clk); #1; end
        data       = rdata;
        last_rresp = rresp;
        // one more edge with rready still high lets the slave clear rvalid
        @(posedge clk); #1;
        rready = 1'b0;
    endtask

    // -------------------------------------------------------------------------
    // main sequence
    // -------------------------------------------------------------------------
    logic [AXI_W-1:0] rd;   // scratch for readbacks

    initial begin
        $dumpfile("axi_lite_slave_smoke.vcd");
        $dumpvars(0, axi_lite_slave_smoke_tb);

        // ---- idle all master-driven inputs, then reset ----
        awaddr='0; awvalid=0; wdata='0; wstrb='0; wvalid=0; bready=0;
        araddr='0; arvalid=0; rready=0; done=0;
        rst_n = 1'b0;
        repeat (3) @(posedge clk); #1;

        // ---- T1: reset state ----
        check("T1a reset: start == 0", {31'b0, start}, 0);
        check("T1b reset: dim_n == 0", {29'b0, dim_n}, 0);

        rst_n = 1'b1;
        @(posedge clk); #1;

        // ---- T2: DIM_REG write -> readback + decode ----
        axi_write(ADDR_DIM, 32'd4);
        check("T2a DIM_REG write resp OKAY", {30'b0, last_bresp}, RESP_OKAY);
        check("T2b dim_n decodes to 4",      {29'b0, dim_n},      4);
        axi_read(ADDR_DIM, rd);
        check("T2c DIM_REG reads back 4",    rd, 4);

        // ---- T3: CTRL_REG start bit ----
        axi_write(ADDR_CTRL, 32'd1);
        check("T3a start goes high on write 1", {31'b0, start}, 1);
        axi_read(ADDR_CTRL, rd);
        check("T3b CTRL_REG reads back 1",      rd, 1);
        axi_write(ADDR_CTRL, 32'd0);              // software clears
        check("T3c start clears on write 0",    {31'b0, start}, 0);

        // ---- T4: STATUS_REG is read-only ----
        done = 1'b1;                              // pretend controller finished
        @(posedge clk); #1;
        axi_read(ADDR_STATUS, rd);
        check("T4a STATUS reads done=1",         rd, 1);
        axi_write(ADDR_STATUS, 32'd0);            // attempt to force done to 0
        check("T4b STATUS write completes OKAY",{30'b0, last_bresp}, RESP_OKAY);
        axi_read(ADDR_STATUS, rd);
        check("T4c STATUS write did NOT change done", rd, 1);  // still 1

        // ---- T5: STATUS_REG read-through, both directions ----
        done = 1'b0;
        @(posedge clk); #1;
        axi_read(ADDR_STATUS, rd);
        check("T5a STATUS follows done=0",       rd, 0);
        done = 1'b1;
        @(posedge clk); #1;
        axi_read(ADDR_STATUS, rd);
        check("T5b STATUS follows done=1",       rd, 1);
        done = 1'b0;

        // ---- T6: unmapped address -> SLVERR ----
        axi_write(ADDR_BAD, 32'hDEAD_BEEF);
        check("T6a unmapped write -> SLVERR", {30'b0, last_bresp}, RESP_SLVERR);
        axi_read(ADDR_BAD, rd);
        check("T6b unmapped read  -> SLVERR", {30'b0, last_rresp}, RESP_SLVERR);

        // ---- T7: DIM_REG stores raw illegal values (controller rejects later) ----
        axi_write(ADDR_DIM, 32'd7);               // N=7 is illegal but must store
        axi_read(ADDR_DIM, rd);
        check("T7a DIM_REG stores raw N=7",  rd, 7);
        axi_write(ADDR_DIM, 32'd0);               // N=0 is illegal but must store
        axi_read(ADDR_DIM, rd);
        check("T7b DIM_REG stores raw N=0",  rd, 0);

        // ---- summary ----
        $display("\n==== axi_lite_slave smoke test: %0d passed, %0d failed ====",
                 pass_count, fail_count);
        if (fail_count == 0) $display("SMOKE TEST: ALL PASS");
        else                 $display("SMOKE TEST: FAILURES PRESENT");
        $finish;
    end

endmodule