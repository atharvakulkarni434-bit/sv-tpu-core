//=============================================================================
// mmu_reg_model.sv
// UVM RAL Register Model for sv-tpu-core
//
// Source of truth: SpecDoc.docx, Part B (Register / RAL Spec)
//   DIM_REG    - offset 0x0, RW, 3-bit  (B.2 / B.3)
//   CTRL_REG   - offset 0x4, RW, 1-bit  (B.2 / B.3)
//   STATUS_REG - offset 0x8, RO, 1-bit  (B.2 / B.3)
//
// All three registers reset to 0 (B.4).
//
// Exercised directly by TC-032 (uvm_reg_hw_reset_seq) and TC-033
// (uvm_reg_access_seq) - see FULL_UVMVerification_PLAN.pdf Section 3.7.
// Both are the first tests run in Phase 3 integration and gate every
// other test in the regression, so field definitions here must be exact.
//=============================================================================

`ifndef MMU_REG_MODEL_SV
`define MMU_REG_MODEL_SV

//-----------------------------------------------------------------------------
// DIM_REG - offset 0x0, RW, 3-bit field "N", reset 0x0
//
// Holds the active matrix dimension for the next computation.
// IMPORTANT: legal range is 1-4 per spec B.4, but this field is left
// UNCONSTRAINED (0-7). TC-026 (Invalid Dimension, DIM_REG > 4) and the
// dim=0 case in TC-024 deliberately drive illegal values through this
// exact register to confirm the DUT rejects them safely. Constraining
// N here would silently break those negative tests.
//-----------------------------------------------------------------------------
class dim_reg extends uvm_reg;
    `uvm_object_utils(dim_reg)

    rand uvm_reg_field N;

    function new(string name = "dim_reg");
        super.new(name, 3, UVM_NO_COVERAGE);
    endfunction

    virtual function void build();
      N = uvm_reg_field::type_id::create("N");
      N.configure(
        .parent(this),
        .size(3),
        .lsb_pos(0),
        .access("RW"),
        .volatile(0),
        .reset(3'h0),
        .has_reset(1),
        .is_rand(1),
        .individually_accessible(0)
      );
    endfunction

endclass

//-----------------------------------------------------------------------------
// CTRL_REG - offset 0x4, RW, 1-bit field "start", reset 0x0
//
// Writing 1 triggers weight load then activation flow (B.3).
// Modeled as plain RW. Whether/when the RTL self-clears the bit inside
// the FSM is a hardware behavior checked by the scoreboard and SVA
// (B4 - no_spurious_done), not something this model enforces - the RAL
// model's job is register-file correctness, not FSM behavior.
//-----------------------------------------------------------------------------
class ctrl_reg extends uvm_reg;
    `uvm_object_utils(ctrl_reg)

    rand uvm_reg_field start;

    function new(string name = "ctrl_reg");
        super.new(name, 1, UVM_NO_COVERAGE);
    endfunction

    virtual function void build();
        start = uvm_reg_field::type_id::create("start");

        start.configure(
              .parent(this),
              .size(1),
              .lsb_pos(0),
              .access("RW"),
              .volatile(0),
              .reset(1'h0),
              .has_reset(1),
              .is_rand(0),
              .individually_accessible(0)
        );
    endfunction

endclass

//-----------------------------------------------------------------------------
// STATUS_REG - offset 0x8, RO, 1-bit field "done", reset 0x0
//
// Hardware sets this to 1 when results are valid (B.3, B.4). Declaring
// access "RO" here is what makes uvm_reg_access_seq (TC-033) skip write
// attempts to this register automatically - no custom scoreboard code
// needed for that part of read-only enforcement (see test plan 7.4).
// Marked volatile because the value changes outside of any bus write
// (hardware-driven), which also means the RAL mirror must not be trusted
// stale - always read, don't assume the mirrored value is current.
//-----------------------------------------------------------------------------
class status_reg extends uvm_reg;
    `uvm_object_utils(status_reg)

    rand uvm_reg_field done;

    function new(string name = "status_reg");
        super.new(name, 1, UVM_NO_COVERAGE);
    endfunction

    virtual function void build();
      done = uvm_reg_field::type_id::create("done");

      done.configure(
              .parent(this),
              .size(1),
              .lsb_pos(0),
              .access("RO"),
              .volatile(1),
              .reset(1'h0),
              .has_reset(1),
              .is_rand(0),
              .individually_accessible(0)
        );


    endfunction

endclass

//-----------------------------------------------------------------------------
// mmu_reg_block - top-level RAL block, address map per SpecDoc B.2
//-----------------------------------------------------------------------------
class mmu_reg_block extends uvm_reg_block;
    `uvm_object_utils(mmu_reg_block)

    rand dim_reg DIM_REG;
    rand ctrl_reg CTRL_REG;
    rand status_reg STATUS_REG;

    uvm_reg_map bus_map;

    function new(string name = "mmu_reg_block");
      super.new(name, UVM_NO_COVERAGE);
    endfunction

    virtual function void build();

        DIM_REG = dim_reg::type_id::create("DIM_REG");
        CTRL_REG = ctrl_reg::type_id::create("CTRL_REG");
        STATUS_REG = status_reg::type_id::create("STATUS_REG");

        DIM_REG.configure(this);
        CTRL_REG.configure(this);
        STATUS_REG.configure(this);

        DIM_REG.build();
        CTRL_REG.build();
        STATUS_REG.build();

        // --- address map: base address assigned at integration (B.2 note) ---
        // Base is left at 'h0 here; if mmu_top instantiation adds a nonzero
        // base offset at integration, update base_addr below to match -
        // this is the single place that needs to change.
        bus_map = create_map(
            .name("bus_map"),
            .base_addr('h0),
            .n_bytes(4), //NOTE: This is because this is AXI-LITE, the bus we are using defines the number of bytes in the map!
            .endian(UVM_LITTLE_ENDIAN)
        );

        //below we actually PLACE the registers in the block.
        bus_map.add_reg(DIM_REG, 'h0, "RW");
        bus_map.add_reg(CTRL_REG, 'h4, "RW");
        bus_map.add_reg(STATUS_REG, 'h8, "RO");

        //lock the model down!
        lock_model();
    endfunction
endclass

`endif // MMU_REG_MODEL_SV