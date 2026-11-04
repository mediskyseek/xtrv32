//============================================================================
//  UNUSED SKELETON -- history only.  The shipped core is
//  rtl/myxtrv32_core_v4p.v; no build or simulation script references this
//  file (it implements only LUI/AUIPC/OP-IMM/OP, no LOAD/STORE/BRANCH/M).
//----------------------------------------------------------------------------
//  MyXTRV32 v0.4  --  three-stage pipeline skeleton (ALU subset)
//----------------------------------------------------------------------------
//  Stage boundaries (see doc/v0.4_pipeline_cycles.md):
//
//      IF          ID/EX (combinational)         EX/MEM (register)
//    pc -> ROM     decode, regs, fwd mux, ALU    alu_r / rd / we / valid
//
//  The ROM's own synchronous output register *is* the IF/ID data register:
//  there is deliberately no extra 'if_id_instr' register, so a taken branch
//  costs one slot instead of two.
//
//  This skeleton supports LUI/AUIPC/OP-IMM/OP(no M) and treats everything
//  else as a NOP.  Load/store/branch/M/DIV are added in later steps.
//============================================================================
`timescale 1ns / 1ps
`default_nettype none

module myxtrv32_core_v4 (
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
    output wire [2:0]  retire_cls
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
    // IF/ID labels -- updated on the same edge as the ROM output register.
    // The actual assignment lives further down, after the branch resolution
    // logic that produces 'redirect'.
    //------------------------------------------------------------------
    wire if_id_flush;

    //------------------------------------------------------------------
    // ID/EX (combinational; input is the ROM output register)
    //
    // While the front end is stalled the pc is frozen, so the ROM output
    // changes to "pc" (the *next* instruction) rather than the instruction
    // currently in ID/EX.  instr_hold keeps the stalled instruction alive.
    //------------------------------------------------------------------
    reg  [31:0] instr_hold;
    reg         stall_d;

    wire [31:0] instr = stall_d ? instr_hold : imem_rdata;

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

    // EX/MEM register (declared before the forwarding mux that reads it)
    reg [31:0] ex_mem_alu;
    reg [4:0]  ex_mem_rd;
    reg        ex_mem_we;
    reg        ex_mem_valid;
    reg        ex_mem_load;
    reg [2:0]  ex_mem_f3;
    reg [2:0]  ex_mem_cls;

    // register file read + EX/MEM forwarding
    wire [31:0] rs1_raw = (rs1 == 5'd0) ? 32'd0 : regs[rs1];
    wire [31:0] rs2_raw = (rs2 == 5'd0) ? 32'd0 : regs[rs2];

    wire fwd_a = ex_mem_valid && ex_mem_we && (ex_mem_rd == rs1) && (rs1 != 5'd0);
    wire fwd_b = ex_mem_valid && ex_mem_we && (ex_mem_rd == rs2) && (rs2 != 5'd0);

    // forwarding source is the final writeback value: for a load that is
    // mem_rdata after byte/half extraction and sign extension, so the
    // load->use case needs no stall (the RAM output is valid this cycle).
    wire [31:0] wb_data;

    wire [31:0] a = fwd_a ? wb_data : rs1_raw;
    wire [31:0] b = fwd_b ? wb_data : rs2_raw;

    // explicit signed view: '$signed(a) >>> n' inside a ?: expression is not
    // reliably treated as an arithmetic shift by every simulator
    wire signed [31:0] a_s = a;
    wire signed [31:0] b_s = b;

    // Arithmetic right shift implemented without relying on '>>>' signedness
    // (Icarus Verilog evaluates >>> as a logical shift inside ?: expressions).
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
    // M extension: DSP multiply (1 extra cycle) and iterative divide
    //------------------------------------------------------------------
    // !stall_d: the held instruction is still visible on the cycle after a
    // stall, so the start pulse must only fire once per instruction.
    wire mul_start = (opc == 7'b0110011) && (f7 == 7'b0000001) && !f3[2] && !stall_d;
    wire div_start = (opc == 7'b0110011) && (f7 == 7'b0000001) &&  f3[2] && !stall_d;

    wire [63:0] mul_full_w = a * b;

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
    // divide by zero: quotient = -1, remainder = dividend (RISC-V spec)
    wire [31:0] div_res_w   = div_is_rem ? div_r_final
                                         : ((div_b == 32'd0) ? 32'hFFFFFFFF : div_q_final);

    // stall the front end while the multiplier/divider needs more cycles.
    // div_start must stall too: div_busy is only set on the following edge.
    wire stall = (mul_start && !mul_busy) || div_start || div_busy;

    //------------------------------------------------------------------
    // ALU
    //------------------------------------------------------------------
    reg [31:0] alu_out;

    always @* begin
        alu_out = 32'd0;
        case (opc)
            //------------------------------------------------ LUI
            7'b0110111: alu_out = imm_u;

            //------------------------------------------------ AUIPC
            7'b0010111: alu_out = if_id_pc + imm_u;

            //------------------------------------------------ JAL / JALR
            7'b1101111: alu_out = if_id_pc + 32'd4;   // link value
            7'b1100111: alu_out = if_id_pc + 32'd4;   // link value

            //------------------------------------------------ BRANCH
            7'b1100011: alu_out = 32'd0;              // no writeback

            //------------------------------------------------ LOAD / STORE
            7'b0000011: alu_out = a + imm_i;      // load address
            7'b0100011: alu_out = a + imm_s;      // store address

            //------------------------------------------------ OP-IMM
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

            //------------------------------------------------ OP
            7'b0110011: begin
                if (f7 == 7'b0000001) begin
                    // M extension: result already latched in mul_full_r / div_q
                    alu_out = f3[2] ? div_res_w : mul_res_w;
                end else begin
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

    wire is_load  = (opc == 7'b0000011);
    wire is_store = (opc == 7'b0100011);

    //------------------------------------------------------------------
    // Branch / jump resolution (ID/EX, static not-taken)
    //   taken -> pc redirects on this edge and IF/ID is flushed on the same
    //   edge, so the wrong-path instruction never reaches EX/MEM.
    //------------------------------------------------------------------
    wire is_branch = (opc == 7'b1100011);
    wire is_jal    = (opc == 7'b1101111);
    wire is_jalr   = (opc == 7'b1100111);

    reg br_cond;
    always @* begin
        case (f3)
            3'b000: br_cond = (a == b);
            3'b001: br_cond = (a != b);
            3'b100: br_cond = (a_s < b_s);
            3'b101: br_cond = (a_s >= b_s);
            3'b110: br_cond = (a < b);
            3'b111: br_cond = (a >= b);
            default: br_cond = 1'b0;
        endcase
    end

    wire br_taken = is_branch && if_id_valid && br_cond;
    wire jal_go   = (is_jal || is_jalr) && if_id_valid;
    wire redirect = br_taken || jal_go;

    wire [31:0] pc_target = is_jal  ? (if_id_pc + imm_j) :
                            is_jalr ? ((a + imm_i) & ~32'd1) :
                                      (if_id_pc + imm_b);

    wire instr_writes_rd = (opc == 7'b0110111) || (opc == 7'b0010111) ||
                           (opc == 7'b0010011) || (opc == 7'b0110011) ||
                           (opc == 7'b0000011) || (opc == 7'b1101111) ||
                           (opc == 7'b1100111);

    //------------------------------------------------------------------
    // MUL / DIV sequencing
    //   MUL: sample the DSP on the first cycle, result is ready on the next
    //   DIV: 32 restoring steps while the front end is stalled
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
                $display("[COREMUL] a=%h b=%h full=%h f3=%b fwda=%b fwdb=%b",
                         a, b, mul_full_w, f3, fwd_a, fwd_b);
                mul_full_r <= mul_full_w;
                mul_a_r    <= a;
                mul_b_r    <= b;
                mul_f3_r   <= f3;
                mul_busy   <= 1'b1;
            end else if (mul_busy) begin
                mul_busy   <= 1'b0;      // result consumed this cycle
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
                div_busy <= 1'b1;        // div-by-zero handled by the quotient
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
    // Instruction hold across stalls (needs 'stall', declared above)
    //------------------------------------------------------------------
    always @(posedge clk) begin
        if (rst) begin
            instr_hold <= 32'd0;
            stall_d    <= 1'b0;
        end else begin
            if (stall && !stall_d)       // only latch on the first stall cycle
                instr_hold <= imem_rdata;
            stall_d <= stall;
        end
    end

    reg [2:0] cls_w;
    always @* begin
        case (opc)
            7'b0000011: cls_w = 3'd1;                       // LOAD
            7'b0100011: cls_w = 3'd2;                       // STORE
            7'b1100011, 7'b1101111, 7'b1100111: cls_w = 3'd3; // BR / JAL / JALR
            7'b0110011: cls_w = (f7 == 7'b0000001)
                                ? (f3[2] ? 3'd5 : 3'd4)     // DIV / MUL
                                : 3'd0;
            default:    cls_w = 3'd0;
        endcase
    end

    //------------------------------------------------------------------
    // EX/MEM register update
    //------------------------------------------------------------------
    always @(posedge clk) begin
        if (rst) begin
            ex_mem_valid <= 1'b0;
            ex_mem_we    <= 1'b0;
            ex_mem_rd    <= 5'd0;
            ex_mem_alu   <= 32'd0;
            ex_mem_load  <= 1'b0;
            ex_mem_f3    <= 3'd0;
            ex_mem_cls   <= 3'd0;
        end else if (stall) begin
            ex_mem_valid <= 1'b0;            // bubble while MUL/DIV blocks
        end else if (!halt_r) begin
            ex_mem_valid <= if_id_valid;
            ex_mem_we    <= instr_writes_rd;
            ex_mem_rd    <= rd;
            ex_mem_alu   <= alu_out;
            ex_mem_load  <= is_load;
            ex_mem_f3    <= f3;
            ex_mem_cls   <= cls_w;
        end else begin
            ex_mem_valid <= 1'b0;
        end
    end

    //------------------------------------------------------------------
    // Load data extraction (uses the EX/MEM copy of the address and funct3)
    //------------------------------------------------------------------
    wire [31:0] ld_shift = dmem_rdata >> {ex_mem_alu[1:0], 3'b000};

    reg [31:0] ld_ext;
    always @* begin
        case (ex_mem_f3)
            3'b000: ld_ext = {{24{ld_shift[7]}},  ld_shift[7:0]};    // LB
            3'b001: ld_ext = {{16{ld_shift[15]}}, ld_shift[15:0]};   // LH
            3'b100: ld_ext = {24'd0, ld_shift[7:0]};                 // LBU
            3'b101: ld_ext = {16'd0, ld_shift[15:0]};                // LHU
            default: ld_ext = ld_shift;                              // LW
        endcase
    end

    assign wb_data = ex_mem_load ? ld_ext : ex_mem_alu;

    //------------------------------------------------------------------
    // MEM/WB: write back + retirement
    //------------------------------------------------------------------
    always @(posedge clk) begin
        if (ex_mem_valid && ex_mem_we && (ex_mem_rd != 5'd0))
            regs[ex_mem_rd] <= wb_data;
    end

    assign retire     = ex_mem_valid;
    assign retire_cls = ex_mem_cls;

    //------------------------------------------------------------------
    // PC / halt
    //------------------------------------------------------------------
    wire is_ebreak = (opc == 7'b1110011);

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
    // IF/ID label update (same edge as the ROM output register)
    //------------------------------------------------------------------
    assign if_id_flush = redirect;

    always @(posedge clk) begin
        if (rst) begin
            if_id_pc    <= 32'd0;
            if_id_valid <= 1'b0;
        end else if (!halt_r && !stall) begin
            if_id_pc    <= pc;
            if_id_valid <= !if_id_flush;
        end
    end

    //------------------------------------------------------------------
    // Data port -- driven combinationally from ID/EX, sampled on the edge
    //------------------------------------------------------------------
    reg [31:0] st_data;
    reg [3:0]  st_strb;

    always @* begin
        case (f3)
            3'b000: begin                                  // SB
                st_data = {4{b[7:0]}};
                st_strb = 4'b0001 << alu_out[1:0];
            end
            3'b001: begin                                  // SH
                st_data = {2{b[15:0]}};
                st_strb = alu_out[1] ? 4'b1100 : 4'b0011;
            end
            default: begin                                 // SW
                st_data = b;
                st_strb = 4'b1111;
            end
        endcase
    end

    assign dmem_req   = (is_load || is_store) && if_id_valid;
    assign dmem_we    = is_store && if_id_valid;
    assign dmem_addr  = alu_out;
    assign dmem_wdata = st_data;
    assign dmem_wstrb = st_strb;

endmodule

`default_nettype wire
