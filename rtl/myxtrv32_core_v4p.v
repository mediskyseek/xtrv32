//============================================================================
//  MyXTRV32 v0.4p  --  four-stage pipeline (RV32IM)
//----------------------------------------------------------------------------
//  IF | ID/EX | MEM | WB
//
//  Motivation (measured): driving the BRAM address combinationally from
//  ID/EX produced a 12.98 ns path (ROM output -> decode -> RAM ENARDEN),
//  with 63% of it routing.  Here the *whole* memory interface (addr, en,
//  we, wstrb, wdata) is registered in EX/MEM, so the BRAM ports only ever
//  see a register output.
//
//  Pipeline registers
//    IF/ID   : the ROM's own synchronous output register (no extra instr
//              register) + if_id_pc / if_id_valid tags
//    EX/MEM  : alu_r, mem_addr, mem_wdata, mem_wstrb, mem_we, is_load,
//              is_store, rd, funct3, class, valid
//    MEM/WB  : alu_r, mem_addr, rd, we, is_load, funct3, valid
//
//  Hazards
//    ALU -> ALU      : EX/MEM  forward (1 mux level, unconditional)
//    LOAD -> use     : 1-cycle stall, then MEM/WB -> EX forward
//                      (RAM data is valid during WB, so a single stall is
//                       exactly what the synchronous read latency needs)
//    MUL             : 1-cycle stall in ID/EX, result captured in EX/MEM
//    DIV             : blocks ID/EX for 32 iterations, EX/MEM takes bubbles
//    BRANCH/JAL/JALR : resolved in ID/EX, flush IF/ID on the same edge
//============================================================================
`timescale 1ns / 1ps
`default_nettype none

module myxtrv32_core_v4p (
    input  wire        clk,
    input  wire        rst,

    output wire [13:0] imem_addr,
    input  wire [31:0] imem_rdata,

    output wire        dmem_req,
    output wire        dmem_we,
    output wire [31:0] dmem_addr,
    output wire [31:0] dmem_wdata,
    output wire [3:0]  dmem_wstrb,
    input  wire [31:0] dmem_rdata,

    output wire [31:0] dbg_pc,
    output wire        dbg_halt,
    output wire        retire,
    output wire [2:0]  retire_cls,

    // performance events (one pulse per occurrence)
    output wire        ev_flush,       // pc redirected (branch taken / jump)
    output wire        ev_br_taken,    // conditional branch, taken
    output wire        ev_br_not,      // conditional branch, not taken
    output wire        ev_stall_ld,    // load->use stall cycle
    output wire        ev_stall_br,    // branch-depends-on-load stall cycle
    output wire        ev_stall_md     // mul/div stall cycle
);

    //------------------------------------------------------------------
    // IF
    //------------------------------------------------------------------
    reg [31:0] pc;
    reg [31:0] if_id_pc;
    reg        if_id_valid;
    reg        halt_r;

    assign imem_addr = pc[15:2];
    assign dbg_pc    = pc;
    assign dbg_halt  = halt_r;

    //------------------------------------------------------------------
    // Instruction hold across stalls (pc freezes, so the ROM output becomes
    // "pc" = the next instruction; the stalled one must be kept)
    //------------------------------------------------------------------
    reg  [31:0] instr_hold;
    reg         stall_d;
    wire [31:0] instr = stall_d ? instr_hold : imem_rdata;

    //------------------------------------------------------------------
    // Decode fields
    //------------------------------------------------------------------
    wire [6:0] opc = instr[6:0];
    wire [2:0] f3  = instr[14:12];
    wire [6:0] f7  = instr[31:25];
    wire [4:0] rs1 = instr[19:15];
    wire [4:0] rs2 = instr[24:20];
    wire [4:0] rd  = instr[11:7];

    wire [31:0] imm_i = {{20{instr[31]}}, instr[31:20]};
    wire [31:0] imm_s = {{20{instr[31]}}, instr[31:25], instr[11:7]};
    wire [31:0] imm_b = {{20{instr[31]}}, instr[7], instr[30:25], instr[11:8], 1'b0};
    wire [31:0] imm_u = {instr[31:12], 12'd0};
    wire [31:0] imm_j = {{12{instr[31]}}, instr[19:12], instr[20], instr[30:21], 1'b0};

    reg [31:0] regs [0:31];

    //------------------------------------------------------------------
    // EX/MEM and MEM/WB registers (declared before the forwarding logic)
    //------------------------------------------------------------------
    reg [31:0] ex_mem_alu;
    reg [31:0] ex_mem_addr;
    reg [31:0] ex_mem_wdata;
    reg [3:0]  ex_mem_wstrb;
    reg [4:0]  ex_mem_rd;
    reg        ex_mem_we;
    reg        ex_mem_load;
    reg        ex_mem_store;
    reg [2:0]  ex_mem_f3;
    reg [2:0]  ex_mem_cls;
    reg        ex_mem_valid;

    reg [31:0] mem_wb_alu;
    reg [31:0] mem_wb_addr;
    reg [4:0]  mem_wb_rd;
    reg        mem_wb_we;
    reg        mem_wb_load;
    reg [2:0]  mem_wb_f3;
    reg [2:0]  mem_wb_cls;
    reg        mem_wb_valid;

    //------------------------------------------------------------------
    // WB data + writeback
    //------------------------------------------------------------------
    wire [31:0] wb_ld_shift = dmem_rdata >> {mem_wb_addr[1:0], 3'b000};

    reg [31:0] wb_ld_ext;
    always @* begin
        case (mem_wb_f3)
            3'b000: wb_ld_ext = {{24{wb_ld_shift[7]}},  wb_ld_shift[7:0]};   // LB
            3'b001: wb_ld_ext = {{16{wb_ld_shift[15]}}, wb_ld_shift[15:0]};  // LH
            3'b100: wb_ld_ext = {24'd0, wb_ld_shift[7:0]};                   // LBU
            3'b101: wb_ld_ext = {16'd0, wb_ld_shift[15:0]};                  // LHU
            default: wb_ld_ext = wb_ld_shift;                                // LW
        endcase
    end

    wire [31:0] wb_data = mem_wb_load ? wb_ld_ext : mem_wb_alu;

    always @(posedge clk) begin
        if (mem_wb_valid && mem_wb_we && (mem_wb_rd != 5'd0))
            regs[mem_wb_rd] <= wb_data;
    end

    assign retire     = mem_wb_valid;
    assign retire_cls = mem_wb_cls;

    //------------------------------------------------------------------
    // Forwarding: EX/MEM (ALU) has priority, MEM/WB supplies load data
    //------------------------------------------------------------------
    wire [31:0] rs1_raw = (rs1 == 5'd0) ? 32'd0 : regs[rs1];
    wire [31:0] rs2_raw = (rs2 == 5'd0) ? 32'd0 : regs[rs2];

    wire fwd_ex_a  = ex_mem_valid && ex_mem_we  && (ex_mem_rd  == rs1) && (rs1 != 5'd0);
    wire fwd_ex_b  = ex_mem_valid && ex_mem_we  && (ex_mem_rd  == rs2) && (rs2 != 5'd0);
    wire fwd_wb_a  = mem_wb_valid && mem_wb_we  && (mem_wb_rd  == rs1) && (rs1 != 5'd0);
    wire fwd_wb_b  = mem_wb_valid && mem_wb_we  && (mem_wb_rd  == rs2) && (rs2 != 5'd0);

    wire [31:0] a = fwd_ex_a ? ex_mem_alu : (fwd_wb_a ? wb_data : rs1_raw);
    wire [31:0] b = fwd_ex_b ? ex_mem_alu : (fwd_wb_b ? wb_data : rs2_raw);

    // Branch / JALR operands skip only the *load* MEM/WB forward (that made
    // 'RAM output -> wb_data -> compare -> pc' the critical path).  An ALU
    // result sitting in MEM/WB is still forwarded normally - it is a plain
    // register (wb_data == mem_wb_alu) and keeps the path short.
    wire fwd_wb_br_a = fwd_wb_a && !mem_wb_load;
    wire fwd_wb_br_b = fwd_wb_b && !mem_wb_load;
    wire [31:0] a_br = fwd_ex_a ? ex_mem_alu : (fwd_wb_br_a ? wb_data : rs1_raw);
    wire [31:0] b_br = fwd_ex_b ? ex_mem_alu : (fwd_wb_br_b ? wb_data : rs2_raw);

    wire signed [31:0] a_s = a;
    wire signed [31:0] b_s = b;

    wire [4:0]  sh_i = imm_i[4:0];
    wire [4:0]  sh_r = b[4:0];
    wire [31:0] sra_i = (a >> sh_i) | ({32{a[31]}} << (6'd32 - {1'b0, sh_i}));
    wire [31:0] sra_r = (a >> sh_r) | ({32{a[31]}} << (6'd32 - {1'b0, sh_r}));

    integer ri;
    initial begin
        for (ri = 0; ri < 32; ri = ri + 1)
            regs[ri] = 32'd0;
    end

    //------------------------------------------------------------------
    // M extension state
    //------------------------------------------------------------------
    wire mul_start = (opc == 7'b0110011) && (f7 == 7'b0000001) && !f3[2] && !stall_d;
    wire div_start = (opc == 7'b0110011) && (f7 == 7'b0000001) &&  f3[2] && !stall_d;

    // Register the multiplicand inputs so the DSP can use its internal
    // AREG/BREG registers; the path "ROM -> forward mux -> DSP" was the
    // remaining -1.15 ns violation.
    reg [31:0] mul_op_a;
    reg [31:0] mul_op_b;
    wire [63:0] mul_full_w = mul_op_a * mul_op_b;

    reg        mul_busy;
    reg [63:0] mul_full_r;
    reg [31:0] mul_a_r;
    reg [31:0] mul_b_r;
    reg [2:0]  mul_f3_r;

    wire [31:0] mul_res_w =
        (mul_f3_r == 3'b000) ? mul_full_r[31:0] :
        (mul_f3_r == 3'b001) ? (mul_full_r[63:32]
                                - (mul_a_r[31] ? mul_b_r : 32'd0)
                                - (mul_b_r[31] ? mul_a_r : 32'd0)) :
        (mul_f3_r == 3'b010) ? (mul_full_r[63:32]
                                - (mul_a_r[31] ? mul_b_r : 32'd0)) :
                               mul_full_r[63:32];

    reg        div_busy;
    reg [31:0] div_a;
    reg [31:0] div_b;
    reg [32:0] div_r;
    reg [31:0] div_q;
    reg [5:0]  div_cnt;
    reg        div_is_rem;
    reg        div_neg_q;
    reg        div_neg_r;

    wire [32:0] div_r_shift = {div_r[31:0], div_a[31]};
    wire [32:0] div_r_sub   = div_r_shift - {1'b0, div_b};
    wire        div_ge      = (div_r_shift >= {1'b0, div_b});
    wire [31:0] div_q_final = div_neg_q ? (~div_q + 32'd1) : div_q;
    wire [31:0] div_r_final = div_neg_r ? (~div_r[31:0] + 32'd1) : div_r[31:0];
    wire [31:0] div_res_w   = div_is_rem ? div_r_final
                                         : ((div_b == 32'd0) ? 32'hFFFFFFFF : div_q_final);

    //------------------------------------------------------------------
    // ALU
    //------------------------------------------------------------------
    reg [31:0] alu_out;

    always @* begin
        alu_out = 32'd0;
        case (opc)
            7'b0110111: alu_out = imm_u;                     // LUI
            7'b0010111: alu_out = if_id_pc + imm_u;          // AUIPC

            7'b1101111: alu_out = if_id_pc + 32'd4;          // JAL link
            7'b1100111: alu_out = if_id_pc + 32'd4;          // JALR link
            7'b1100011: alu_out = 32'd0;                     // branch

            7'b0000011: alu_out = a + imm_i;                 // load address
            7'b0100011: alu_out = a + imm_s;                 // store address

            7'b0010011: begin
                case (f3)
                    3'b000: alu_out = a + imm_i;
                    3'b010: alu_out = {31'd0, ($signed(a) < $signed(imm_i))};
                    3'b011: alu_out = {31'd0, (a < imm_i)};
                    3'b100: alu_out = a ^ imm_i;
                    3'b110: alu_out = a | imm_i;
                    3'b111: alu_out = a & imm_i;
                    3'b001: alu_out = a << imm_i[4:0];
                    3'b101: alu_out = f7[5] ? sra_i : (a >> imm_i[4:0]);
                    default: alu_out = 32'd0;
                endcase
            end

            7'b0110011: begin
                if (f7 == 7'b0000001)
                    alu_out = f3[2] ? div_res_w : mul_res_w;
                else begin
                    case (f3)
                        3'b000: alu_out = f7[5] ? (a - b) : (a + b);
                        3'b010: alu_out = {31'd0, ($signed(a) < $signed(b))};
                        3'b011: alu_out = {31'd0, (a < b)};
                        3'b100: alu_out = a ^ b;
                        3'b110: alu_out = a | b;
                        3'b111: alu_out = a & b;
                        3'b001: alu_out = a << b[4:0];
                        3'b101: alu_out = f7[5] ? sra_r : (a >> b[4:0]);
                        default: alu_out = 32'd0;
                    endcase
                end
            end

            default: alu_out = 32'd0;
        endcase
    end

    //------------------------------------------------------------------
    // Store data / strobes
    //------------------------------------------------------------------
    wire is_load  = (opc == 7'b0000011);
    wire is_store = (opc == 7'b0100011);

    reg [31:0] st_data;
    reg [3:0]  st_strb;

    // addr[1:0] = (rs1[1:0] + imm[1:0]) mod 4 -- a 2-bit adder instead of
    // waiting for the full 32-bit carry chain.  This was the endpoint of the
    // critical path (ex_mem_wstrb).
    wire [1:0] st_addr_lo = a[1:0] + imm_s[1:0];

    always @* begin
        case (f3)
            3'b000: begin
                st_data = {4{b[7:0]}};
                st_strb = 4'b0001 << st_addr_lo;
            end
            3'b001: begin
                st_data = {2{b[15:0]}};
                st_strb = st_addr_lo[1] ? 4'b1100 : 4'b0011;
            end
            default: begin
                st_data = b;
                st_strb = 4'b1111;
            end
        endcase
    end

    //------------------------------------------------------------------
    // Branch / jump resolution (EX stage, static not-taken)
    //------------------------------------------------------------------
    wire is_branch = (opc == 7'b1100011);
    wire is_jal    = (opc == 7'b1101111);
    wire is_jalr   = (opc == 7'b1100111);

    reg br_cond;
    always @* begin
        case (f3)
            3'b000: br_cond = (a_br == b_br);
            3'b001: br_cond = (a_br != b_br);
            3'b100: br_cond = ($signed(a_br) < $signed(b_br));
            3'b101: br_cond = ($signed(a_br) >= $signed(b_br));
            3'b110: br_cond = (a_br < b_br);
            3'b111: br_cond = (a_br >= b_br);
            default: br_cond = 1'b0;
        endcase
    end

    wire br_taken = is_branch && if_id_valid && br_cond;
    wire jal_go   = (is_jal || is_jalr) && if_id_valid;
    wire redirect = br_taken || jal_go;

    wire [31:0] pc_target = is_jal  ? (if_id_pc + imm_j) :
                            is_jalr ? ((a_br + imm_i) & ~32'd1) :
                                      (if_id_pc + imm_b);

    wire instr_writes_rd = (opc == 7'b0110111) || (opc == 7'b0010111) ||
                           (opc == 7'b0010011) || (opc == 7'b0110011) ||
                           (opc == 7'b0000011) || (opc == 7'b1101111) ||
                           (opc == 7'b1100111);

    reg [2:0] cls_w;
    always @* begin
        case (opc)
            7'b0000011: cls_w = 3'd1;
            7'b0100011: cls_w = 3'd2;
            7'b1100011, 7'b1101111, 7'b1100111: cls_w = 3'd3;
            7'b0110011: cls_w = (f7 == 7'b0000001) ? (f3[2] ? 3'd5 : 3'd4) : 3'd0;
            default:    cls_w = 3'd0;
        endcase
    end

    //------------------------------------------------------------------
    // Stall: MUL/DIV block ID/EX; a load->use pair costs exactly one cycle
    // because the RAM output is valid during MEM/WB.
    //------------------------------------------------------------------
    wire stall_muldiv = (mul_start && !mul_busy) || mul_busy || div_start || div_busy;

    wire stall_load_use = ex_mem_valid && ex_mem_load && if_id_valid &&
                          ((ex_mem_rd == rs1) || (ex_mem_rd == rs2)) &&
                          (ex_mem_rd != 5'd0);

    // Branch/JALR whose operand is still in the MEM/WB load slot: stall one
    // cycle instead of forwarding through the RAM output.
    wire br_load_dep = (is_branch || is_jalr) && mem_wb_valid && mem_wb_load &&
                       (mem_wb_rd != 5'd0) &&
                       ((mem_wb_rd == rs1) || (mem_wb_rd == rs2));

    wire stall = stall_muldiv || stall_load_use || br_load_dep;

    //------------------------------------------------------------------
    // Performance event outputs
    //------------------------------------------------------------------
    // Registered so the counters' clock-enable pins do not sit on the same
    // combinational path as the branch compare / pc update.
    reg ev_flush_r, ev_br_taken_r, ev_br_not_r;
    reg ev_stall_ld_r, ev_stall_br_r, ev_stall_md_r;

    always @(posedge clk) begin
        if (rst) begin
            ev_flush_r    <= 1'b0;
            ev_br_taken_r <= 1'b0;
            ev_br_not_r   <= 1'b0;
            ev_stall_ld_r <= 1'b0;
            ev_stall_br_r <= 1'b0;
            ev_stall_md_r <= 1'b0;
        end else begin
            ev_flush_r    <= redirect && !halt_r && !stall;
            ev_br_taken_r <= is_branch && if_id_valid && br_cond && !stall;
            ev_br_not_r   <= is_branch && if_id_valid && !br_cond && !stall;
            ev_stall_ld_r <= stall_load_use;
            ev_stall_br_r <= br_load_dep;
            ev_stall_md_r <= stall_muldiv;
        end
    end

    assign ev_flush     = ev_flush_r;
    assign ev_br_taken  = ev_br_taken_r;
    assign ev_br_not    = ev_br_not_r;
    assign ev_stall_ld  = ev_stall_ld_r;
    assign ev_stall_br  = ev_stall_br_r;
    assign ev_stall_md  = ev_stall_md_r;

    //------------------------------------------------------------------
    // MUL / DIV sequencing
    //------------------------------------------------------------------
    always @(posedge clk) begin
        if (rst) begin
            mul_busy   <= 1'b0;
            mul_full_r <= 64'd0;
            mul_a_r    <= 32'd0;
            mul_b_r    <= 32'd0;
            mul_f3_r   <= 3'd0;
            div_busy   <= 1'b0;
            div_a      <= 32'd0;
            div_b      <= 32'd0;
            div_r      <= 33'd0;
            div_q      <= 32'd0;
            div_cnt    <= 6'd0;
            div_is_rem <= 1'b0;
            div_neg_q  <= 1'b0;
            div_neg_r  <= 1'b0;
        end else if (!halt_r) begin
            //-------------------------------------------------- multiply
            if (mul_start && !mul_busy) begin
                mul_op_a   <= a;
                mul_op_b   <= b;
                mul_a_r    <= a;
                mul_b_r    <= b;
                mul_f3_r   <= f3;
                mul_busy   <= 1'b1;
            end else if (mul_busy) begin
                mul_full_r <= mul_full_w;    // DSP output, one cycle later
                mul_busy   <= 1'b0;
            end

            //-------------------------------------------------- divide
            if (div_start && !div_busy) begin
                div_is_rem <= f3[1];
                div_cnt    <= 6'd32;
                div_q      <= 32'd0;
                div_r      <= 33'd0;
                if (!f3[0]) begin
                    div_a     <= a[31] ? (~a + 32'd1) : a;
                    div_b     <= b[31] ? (~b + 32'd1) : b;
                    div_neg_q <= a[31] ^ b[31];
                    div_neg_r <= a[31];
                end else begin
                    div_a     <= a;
                    div_b     <= b;
                    div_neg_q <= 1'b0;
                    div_neg_r <= 1'b0;
                end
                div_busy <= 1'b1;
            end else if (div_busy) begin
                if (div_cnt != 6'd0) begin
                    div_r   <= div_ge ? div_r_sub : div_r_shift;
                    div_q   <= {div_q[30:0], div_ge};
                    div_a   <= {div_a[30:0], 1'b0};
                    div_cnt <= div_cnt - 6'd1;
                end else begin
                    div_busy <= 1'b0;
                end
            end
        end
    end

    //------------------------------------------------------------------
    // PC / IF/ID
    //------------------------------------------------------------------
    wire is_ebreak = (opc == 7'b1110011);

    always @(posedge clk) begin
        if (rst) begin
            if_id_pc    <= 32'd0;
            if_id_valid <= 1'b0;
        end else if (!stall) begin
            if_id_pc    <= pc;
            if_id_valid <= !redirect;      // flush the wrong-path instruction
        end
    end

    always @(posedge clk) begin
        if (rst) begin
            instr_hold <= 32'd0;
            stall_d    <= 1'b0;
        end else begin
            if (stall && !stall_d)         // latch only on the first stall cycle
                instr_hold <= imem_rdata;
            stall_d <= stall;
        end
    end

    always @(posedge clk) begin
        if (rst) begin
            pc     <= 32'd0;
            halt_r <= 1'b0;
        end else if (!halt_r && !stall) begin
            if (redirect)
                pc <= pc_target;
            else
                pc <= pc + 32'd4;
            if (is_ebreak && if_id_valid)
                halt_r <= 1'b1;
        end
    end

    //------------------------------------------------------------------
    // EX/MEM register
    //------------------------------------------------------------------
    always @(posedge clk) begin
        if (rst) begin
            ex_mem_valid <= 1'b0;
            ex_mem_we    <= 1'b0;
            ex_mem_rd    <= 5'd0;
            ex_mem_alu   <= 32'd0;
            ex_mem_addr  <= 32'd0;
            ex_mem_wdata <= 32'd0;
            ex_mem_wstrb <= 4'd0;
            ex_mem_load  <= 1'b0;
            ex_mem_store <= 1'b0;
            ex_mem_f3    <= 3'd0;
            ex_mem_cls   <= 3'd0;
        end else if (stall) begin
            ex_mem_valid <= 1'b0;
            ex_mem_store <= 1'b0;
        end else if (!halt_r) begin
            ex_mem_valid <= if_id_valid;
            ex_mem_we    <= instr_writes_rd;
            ex_mem_rd    <= rd;
            ex_mem_alu   <= alu_out;
            ex_mem_addr  <= alu_out;
            ex_mem_wdata <= st_data;
            ex_mem_wstrb <= st_strb;
            ex_mem_load  <= is_load;
            ex_mem_store <= is_store;
            ex_mem_f3    <= f3;
            ex_mem_cls   <= cls_w;
        end else begin
            ex_mem_valid <= 1'b0;
            ex_mem_store <= 1'b0;
        end
    end

    //------------------------------------------------------------------
    // MEM/WB register
    //------------------------------------------------------------------
    always @(posedge clk) begin
        if (rst) begin
            mem_wb_valid <= 1'b0;
            mem_wb_we    <= 1'b0;
            mem_wb_rd    <= 5'd0;
            mem_wb_alu   <= 32'd0;
            mem_wb_addr  <= 32'd0;
            mem_wb_load  <= 1'b0;
            mem_wb_f3    <= 3'd0;
            mem_wb_cls   <= 3'd0;
        end else begin
            // always drain, so the instructions already in flight retire
            // even after halt has been asserted
            mem_wb_valid <= ex_mem_valid;
            mem_wb_we    <= ex_mem_we;
            mem_wb_rd    <= ex_mem_rd;
            mem_wb_alu   <= ex_mem_alu;
            mem_wb_addr  <= ex_mem_addr;
            mem_wb_load  <= ex_mem_load;
            mem_wb_f3    <= ex_mem_f3;
            mem_wb_cls   <= ex_mem_cls;
        end
    end

    //------------------------------------------------------------------
    // Memory interface: fully registered, driven by EX/MEM only
    //------------------------------------------------------------------
    assign dmem_req   = ex_mem_valid && (ex_mem_load || ex_mem_store);
    assign dmem_we    = ex_mem_valid && ex_mem_store;
    assign dmem_addr  = ex_mem_addr;
    assign dmem_wdata = ex_mem_wdata;
    assign dmem_wstrb = ex_mem_wstrb;

endmodule

`default_nettype wire
