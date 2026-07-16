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
// *** OPEN ITEM - CONFIRM BEFORE JUL 15 CHECKPOINT ***
// This assumes axi_agent.sv's sequence item is named axi_lite_seq_item
// with fields:
//     rand bit [31:0] addr;
//     rand bit [31:0] data;
//     rand axi_op_e   op;    // enum: AXI_READ, AXI_WRITE
//          bit [1:0]  resp;  // captured BRESP/RRESP after the txn completes
// If whoever builds axi_agent.sv lands on different names/types, only
// this file changes - mmu_reg_model.sv and every test written against
// reg_model.DIM_REG.write(...) etc. are unaffected. That isolation is
// the whole point of the adapter pattern.
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


        //virtual because needs to be overriden
        //returns generic sequence item because axi sequence extends from this class, can change bus protocol and method still works
        //a pass-by-reference, so see the actual wire value, but const, so can't change it.
        //uvm_reg_bus_op is the INTENT, created by the RAL. Or, more specifically...
        //the uvm_reg class has an in built write method which we use in every test. That write method automatically does this conversion of english intent into reg_bus_op.
        
        virtual function uvm_sequence_item reg2bus(const ref uvm_reg_bus_op rw);

            axi_lite_seq_item item = axi_lite_seq_item::type_id::create("item"); //construct the axi bus package.

            //most important three lines, this converts or "adapts" the uvm bus operation into axi bus package via the following translations.
            item.addr = rw.addr;
            item.data = rw.data;
            item.op   = (rw.kind == UVM_READ) ? AXI_READ : AXI_WRITE;

            return item;

        endfunction


        //ok, why does this exist?
        //reg2bus translates intent into actual package! Recall we do intent -> RAL(the mirror)
        //then, RAL-> adapter translates intent into package -> AXI driver -> drives into DUT to actually change registers.
        //then we must compare!

        //hence, this below function performs the comparison, are the 2 bus functions identical: the intent and the resultant package.
        //the uvm sequence item is, yet again, the generic type, not the specific axi type, hence the package.
        //the other one is the intent!

        virtual function void bus2reg(uvm_sequence_item bus_item, ref uvm_reg_bus_op rw);
            axi_lite_seq_item item;

            //the bus_item is the actual bus data, the rw is the intent!
            //cast the actual bus data item into the axi to CHECK if protocol matches!
            if (!$cast(item, bus_item)) begin
                `uvm_fatal("MMU_REG_ADAPTER",
                "bus2reg: bus_item is not an axi_lite_seq_item - check axi_agent.sv item type")
                return;
            end

            
            rw.kind   = (item.op == AXI_READ) ? UVM_READ : UVM_WRITE;
            rw.addr   = item.addr;
            rw.data   = item.data; //MOST IMPORTANT!!! bus2reg is the response, or the what actually happened
            //so if you wanted dimensions to be set to 2 as ur intent, this data value carries if that actually happened or not, i.e. what is dim reg value NOW in the DUT

            // AXI-Lite OKAY (2'b00) -> UVM_IS_OK, anything else -> UVM_NOT_OK.
            // Note: a write to STATUS_REG still completes with an OKAY bus
            // response per spec (B.2 axi_formal.sv Property 2b/2c cover the
            // protocol side) - the *value* being unchanged is what the RAL
            // model's own mismatch check catches, not the bus response here.

            //did the handshake actually happen, did the status succeed
            rw.status = (item.resp == 2'b00) ? UVM_IS_OK : UVM_NOT_OK;

            endfunction


endclass

`endif // MMU_REG_ADAPTER_SV