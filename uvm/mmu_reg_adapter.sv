//=============================================================================
// mmu_reg_adapter.sv
// RAL <-> AXI-Lite bus adapter for sv-tpu-core
//
// Sits between mmu_reg_block (mmu_reg_model.sv) and axi_agent.sv. When a
// test calls e.g. reg_model.DIM_REG.write(status, 4), the RAL framework
// packages that into a uvm_reg_bus_op and calls reg2bus() below to turn
// it into a real bus-level sequence item that axi_agent's driver can
// actually drive on the AXI-Lite interface. bus2reg() does the reverse
// after the transaction completes, so the RAL mirror gets updated with
// what really happened on the bus.
//
// *** RESOLVED (was an open item) ***
// Confirmed against the actual axi_agent.sv: the sequence item is
// axi_txn, not axi_lite_seq_item, with fields:
//     rand axi_txn::rw_e rw;    // enum {WRITE, READ}, not a separate axi_op_e
//     rand logic [3:0]    addr; // 4 bits (only 3 registers exist), not 32
//     rand logic [31:0]   data;
//     logic [1:0]         resp; // 2-bit AXI resp, not a general status code
// Updated reg2bus()/bus2reg() below to match. mmu_reg_model.sv and every
// test written against reg_model.DIM_REG.write(...) etc. are unaffected -
// that isolation is the whole point of the adapter pattern.
//=============================================================================

`ifndef MMU_REG_ADAPTER_SV
`define MMU_REG_ADAPTER_SV

class mmu_reg_adapter extends uvm_reg_adapter;
        `uvm_object_utils(mmu_reg_adapter)

        function new(string name = "mmu_reg_adapter");
            super.new(name);

            // AXI-Lite here is control-only, full-word register accesses (B.2) -
            // no partial/byte-enabled writes are part of this spec.
            this.supports_byte_enable = 0;

            // The AXI-Lite slave always returns a B/R response, so the adapter
            // can report real pass/fail status back to the RAL model instead of
            // blindly assuming success. It does this via bus2reg function!
            this.provides_responses = 1;

        endfunction


        // virtual because needs to be overridden.
        // returns generic sequence item because axi_txn extends from this class -
        // the RAL layer only knows the base type, letting the bus protocol
        // change without touching mmu_reg_model.sv.
        // uvm_reg_bus_op is the INTENT, created by the RAL model's own write()/
        // read() methods before this adapter ever sees it.
        virtual function uvm_sequence_item reg2bus(const ref uvm_reg_bus_op rw);

            axi_txn item = axi_txn::type_id::create("item");

            // Translate RAL intent -> axi_txn fields.
            item.addr = rw.addr[3:0];   // only 3 registers exist (0x0/0x4/0x8); addr is 4 bits wide
            item.data = rw.data;
            item.rw   = (rw.kind == UVM_READ) ? axi_txn::READ : axi_txn::WRITE;

            return item;

        endfunction


        // bus2reg — the comparison half: did the bus transaction that actually
        // happened (bus_item) match/complete the intent (rw)? Cast the generic
        // uvm_sequence_item back to axi_txn to read the real bus fields.
        virtual function void bus2reg(uvm_sequence_item bus_item, ref uvm_reg_bus_op rw);
            axi_txn item;
            `uvm_info("MMU_REG_ADAPTER", "TRACE: bus2reg called", UVM_LOW)


            if (!$cast(item, bus_item)) begin
                `uvm_fatal("MMU_REG_ADAPTER",
                "bus2reg: bus_item is not an axi_txn - check axi_agent.sv item type")
                return;
            end

            rw.kind = (item.rw == axi_txn::READ) ? UVM_READ : UVM_WRITE;
            rw.addr = {28'h0, item.addr};  // widen 4-bit bus addr back to RAL's addr width
            rw.data = item.data;           // MOST IMPORTANT — what the DUT actually reported

            // AXI-Lite OKAY (2'b00) -> UVM_IS_OK, anything else -> UVM_NOT_OK.
            // A write to STATUS_REG still completes with an OKAY bus response
            // per spec (axi_formal.sv Property 2b/2c cover the protocol side) -
            // the *value* being unchanged is what the RAL model's own mismatch
            // check catches, not the bus response here.
            rw.status = (item.resp == 2'b00) ? UVM_IS_OK : UVM_NOT_OK;

        endfunction

endclass

`endif // MMU_REG_ADAPTER_SV