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

        bus_map = create_map(
            .name("bus_map"),
            .base_addr('h0),
            .n_bytes(4), 
            .endian(UVM_LITTLE_ENDIAN)
        );

    
        bus_map.add_reg(DIM_REG, 'h0, "RW");
        bus_map.add_reg(CTRL_REG, 'h4, "RW");
        bus_map.add_reg(STATUS_REG, 'h8, "RO");

        lock_model();
    endfunction
endclass

`endif // MMU_REG_MODEL_SV
