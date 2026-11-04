//============================================================================
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
    // IF/ID labels -- updated on the same edge as the ROM output register
    //------------------------------------------------------------------
    always @(posedge clk) begin
        if (rst) begin
            if_id_pc    <= 32'd0;
            if_id_valid <= 1'b0;
        end else if (!halt_r) begin
            if_id_pc    <= pc;
            if_id_valid <= 1'b1;
        end
    end

    //------------------------------------------------------------------
    // ID/EX (combinational; input is the ROM output register)
    //------------------------------------------------------------------
    wire [31:0] instr = imem_rdata;

    wire [6:0] opc = instr[6:0];
    wire [2:0] f3  = instr[14:12];
    wire [6:0] f7  = instr[31:25];
    wire [4:0] rs1 = instr[19:15];
    wire [4:0] rs2 = instr[24:20];
    wire [4:0] rd  = instr[11:7];

    wire [31:0] imm_i = {{20{instr[31]}}, instr[31:20]};
    wire [31:0] imm_u = {instr[31:12], 12'd0};

    reg [31:0] regs [0:31];

    // EX/MEM register (declared before the forwarding mux that reads it)
    reg [31:0] ex_mem_alu;
    reg [4:0]  ex_mem_rd;
    reg        ex_mem_we;
    reg        ex_mem_valid;

    // register file read + EX/MEM forwarding
    wire [31:0] rs1_raw = (rs1 == 5'd0) ? 32'd0 : regs[rs1];
    wire [31:0] rs2_raw = (rs2 == 5'd0) ? 32'd0 : regs[rs2];

    wire fwd_a = ex_mem_valid && ex_mem_we && (ex_mem_rd == rs1) && (rs1 != 5'd0);
    wire fwd_b = ex_mem_valid && ex_mem_we && (ex_mem_rd == rs2) && (rs2 != 5'd0);

    wire [31:0] a = fwd_a ? ex_mem_alu : rs1_raw;
    wire [31:0] b = fwd_b ? ex_mem_alu : rs2_raw;

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
                if (f7 != 7'b0000001) begin       // M extension: later step
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

    wire instr_writes_rd = (opc == 7'b0110111) || (opc == 7'b0010111) ||
                           (opc == 7'b0010011) || (opc == 7'b0110011);

    //------------------------------------------------------------------
    // EX/MEM register update
    //------------------------------------------------------------------
    always @(posedge clk) begin
        if (rst) begin
            ex_mem_valid <= 1'b0;
            ex_mem_we    <= 1'b0;
            ex_mem_rd    <= 5'd0;
            ex_mem_alu   <= 32'd0;
        end else if (!halt_r) begin
            ex_mem_valid <= if_id_valid;
            ex_mem_we    <= instr_writes_rd;
            ex_mem_rd    <= rd;
            ex_mem_alu   <= alu_out;
        end else begin
            ex_mem_valid <= 1'b0;
        end
    end

    //------------------------------------------------------------------
    // MEM/WB: write back + retirement
    //------------------------------------------------------------------
    always @(posedge clk) begin
        if (ex_mem_valid && ex_mem_we && (ex_mem_rd != 5'd0))
            regs[ex_mem_rd] <= ex_mem_alu;
    end

    assign retire     = ex_mem_valid;
    assign retire_cls = 3'd0;

    //------------------------------------------------------------------
    // PC / halt
    //------------------------------------------------------------------
    wire is_ebreak = (opc == 7'b1110011);

    always @(posedge clk) begin
        if (rst) begin
            pc     <= 32'd0;
            halt_r <= 1'b0;
        end else if (!halt_r) begin
            pc <= pc + 32'd4;
            if (is_ebreak && if_id_valid)
                halt_r <= 1'b1;
        end
    end

    //------------------------------------------------------------------
    // Data port is unused in the ALU skeleton
    //------------------------------------------------------------------
    assign dmem_req   = 1'b0;
    assign dmem_we    = 1'b0;
    assign dmem_addr  = 32'd0;
    assign dmem_wdata = 32'd0;
    assign dmem_wstrb = 4'd0;
    wire _unused = &{1'b0, dmem_rdata};

endmodule

`default_nettype wire
