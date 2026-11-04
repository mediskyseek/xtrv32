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
    wire [31:0] imm_s = {{20{instr[31]}}, instr[31:25], instr[11:7]};
    wire [31:0] imm_u = {instr[31:12], 12'd0};

    reg [31:0] regs [0:31];

    // EX/MEM register (declared before the forwarding mux that reads it)
    reg [31:0] ex_mem_alu;
    reg [4:0]  ex_mem_rd;
    reg        ex_mem_we;
    reg        ex_mem_valid;
    reg        ex_mem_load;
    reg [2:0]  ex_mem_f3;

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

    wire is_load  = (opc == 7'b0000011);
    wire is_store = (opc == 7'b0100011);

    wire instr_writes_rd = (opc == 7'b0110111) || (opc == 7'b0010111) ||
                           (opc == 7'b0010011) || (opc == 7'b0110011) ||
                           (opc == 7'b0000011);

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
        end else if (!halt_r) begin
            ex_mem_valid <= if_id_valid;
            ex_mem_we    <= instr_writes_rd;
            ex_mem_rd    <= rd;
            ex_mem_alu   <= alu_out;
            ex_mem_load  <= is_load;
            ex_mem_f3    <= f3;
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
