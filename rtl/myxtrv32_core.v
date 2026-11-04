//============================================================================
//  MyXTRV32 v0.1  --  RV32I multi-cycle (FSM) soft core
//----------------------------------------------------------------------------
//  Features
//    * RV32I base integer ISA (no M/A/F/D, no CSR, no interrupts)
//    * Single issue, no pipeline: FETCH -> DECODE -> EXEC -> MEM -> WB
//    * 4 cycles per ALU/branch/jump instruction, 5 cycles for load/store
//    * Harvard style: separate instruction (ROM) and data (RAM/MMIO) ports
//    * Both memories are synchronous, 1 clock read latency
//
//  Memory map (byte addresses)
//    0x0000_0000 .. 0x0000_FFFF   ROM  64 KiB (fetch + constant loads)
//    0x0001_0000 .. 0x0001_FFFF   RAM  64 KiB
//    0x0002_0000 .. 0x0002_00FF   UART TX  (+0 data, +4 status)
//    0x0002_0100 .. 0x0002_01FF   GPIO     (+0 leds, +4 free running counter)
//    0x0002_0200 .. 0x0002_02FF   MTIME    (+0 low 32 bits, +4 high 32 bits)
//============================================================================
`timescale 1ns / 1ps
`default_nettype none

module myxtrv32_core (
    input  wire        clk,
    input  wire        rst,           // synchronous, active high

    // instruction port (ROM)
    output wire [13:0] imem_addr,     // word index, 16384 entries (64 KiB)
    input  wire [31:0] imem_rdata,

    // data port (RAM / MMIO)
    output wire        dmem_req,
    output wire        dmem_we,
    output wire [31:0] dmem_addr,
    output wire [31:0] dmem_wdata,
    output wire [3:0]  dmem_wstrb,
    input  wire [31:0] dmem_rdata,

    // debug / observation
    output wire [31:0] dbg_pc,
    output wire [2:0]  dbg_state,
    output wire        dbg_halt,

    // performance counters: one pulse per retired instruction
    output wire        retire,
    output wire [2:0]  retire_cls    // 0 ALU, 1 LOAD, 2 STORE, 3 BR/JMP, 4 MUL, 5 DIV
);

    //------------------------------------------------------------------
    // FSM states
    //------------------------------------------------------------------
    localparam [2:0] ST_FETCH  = 3'd0,
                     ST_DECODE = 3'd1,
                     ST_EXEC   = 3'd2,
                     ST_MEM    = 3'd3,
                     ST_WB     = 3'd4,
                     ST_HALT   = 3'd5,
                     ST_DIV    = 3'd6,
                     ST_MUL    = 3'd7;

    //------------------------------------------------------------------
    // Architectural state
    //------------------------------------------------------------------
    reg [2:0]  state;
    reg [31:0] pc;
    reg [31:0] pc_next;
    reg [31:0] ir;

    reg [31:0] regs [0:31];

    // EXEC -> MEM/WB pipeline-less registers
    reg [31:0] alu_r;
    reg [31:0] mem_addr_r;
    reg [31:0] mem_wdata_r;
    reg [3:0]  mem_wstrb_r;
    reg [1:0]  mem_off_r;
    reg [2:0]  mem_f3_r;
    reg        mem_is_load_r;
    reg        mem_is_store_r;
    reg        reg_we_r;
    reg [4:0]  rd_r;
    reg        halt_r;

    //------------------------------------------------------------------
    // Instruction fields
    //------------------------------------------------------------------
    wire [6:0] opc   = ir[6:0];
    wire [2:0] f3    = ir[14:12];
    wire [6:0] f7    = ir[31:25];
    wire [4:0] rs1_i = ir[19:15];
    wire [4:0] rs2_i = ir[24:20];
    wire [4:0] rd_i  = ir[11:7];

    wire [31:0] rs1_v = (rs1_i == 5'd0) ? 32'd0 : regs[rs1_i];
    wire [31:0] rs2_v = (rs2_i == 5'd0) ? 32'd0 : regs[rs2_i];

    //------------------------------------------------------------------
    // Immediate generation
    //------------------------------------------------------------------
    wire [31:0] imm_i = {{20{ir[31]}}, ir[31:20]};
    wire [31:0] imm_s = {{20{ir[31]}}, ir[31:25], ir[11:7]};
    wire [31:0] imm_b = {{20{ir[31]}}, ir[7], ir[30:25], ir[11:8], 1'b0};
    wire [31:0] imm_u = {ir[31:12], 12'd0};
    wire [31:0] imm_j = {{12{ir[31]}}, ir[19:12], ir[20], ir[30:21], 1'b0};

    //------------------------------------------------------------------
    // Main decode / ALU (combinational, valid during ST_EXEC)
    //------------------------------------------------------------------
    reg [31:0] alu_w;
    reg [31:0] pc_target_w;
    reg        br_taken_w;
    reg        d_load_w;
    reg        d_store_w;
    reg        d_branch_w;
    reg        d_jal_w;
    reg        d_jalr_w;
    reg        d_div_w;
    reg        d_mul_w;

    //------------------------------------------------------------------
    // M extension: one unsigned 32x32 multiplier (DSP48), high-word
    // corrections for the signed variants are done in ST_MUL so that the
    // DSP and the 64-bit adders do not share a single clock period.
    //------------------------------------------------------------------
    wire [63:0] mul_full_w = rs1_v * rs2_v;

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

    //------------------------------------------------------------------
    // Divide unit state (iterative, 32 steps)
    //------------------------------------------------------------------
    reg [31:0] div_a;         // dividend (shifting left)
    reg [31:0] div_b;         // divisor (absolute value)
    reg [32:0] div_r;         // partial remainder
    reg [31:0] div_q;         // quotient
    reg [5:0]  div_cnt;
    reg        div_is_rem;
    reg        div_neg_q;
    reg        div_neg_r;

    wire [32:0] div_r_shift = {div_r[31:0], div_a[31]};
    wire [32:0] div_r_sub   = div_r_shift - {1'b0, div_b};
    wire        div_ge      = (div_r_shift >= {1'b0, div_b});
    wire [31:0] div_q_final = div_neg_q ? (~div_q + 32'd1) : div_q;
    wire [31:0] div_r_final = div_neg_r ? (~div_r[31:0] + 32'd1) : div_r[31:0];

    always @* begin
        alu_w        = 32'd0;
        pc_target_w  = pc + 32'd4;
        br_taken_w   = 1'b0;
        d_load_w     = 1'b0;
        d_store_w    = 1'b0;
        d_branch_w   = 1'b0;
        d_jal_w      = 1'b0;
        d_jalr_w     = 1'b0;
        d_div_w      = 1'b0;
        d_mul_w      = 1'b0;

        case (opc)
            //-------------------------------------------------- LUI
            7'b0110111: alu_w = imm_u;

            //-------------------------------------------------- AUIPC
            7'b0010111: alu_w = pc + imm_u;

            //-------------------------------------------------- JAL
            7'b1101111: begin
                d_jal_w     = 1'b1;
                alu_w       = pc + 32'd4;      // link value
                pc_target_w = pc + imm_j;
            end

            //-------------------------------------------------- JALR
            7'b1100111: begin
                d_jalr_w    = 1'b1;
                alu_w       = pc + 32'd4;
                pc_target_w = (rs1_v + imm_i) & ~32'd1;
            end

            //-------------------------------------------------- BRANCH
            7'b1100011: begin
                d_branch_w = 1'b1;
                case (f3)
                    3'b000: br_taken_w = (rs1_v == rs2_v);
                    3'b001: br_taken_w = (rs1_v != rs2_v);
                    3'b100: br_taken_w = ($signed(rs1_v) <  $signed(rs2_v));
                    3'b101: br_taken_w = ($signed(rs1_v) >= $signed(rs2_v));
                    3'b110: br_taken_w = (rs1_v <  rs2_v);
                    3'b111: br_taken_w = (rs1_v >= rs2_v);
                    default: br_taken_w = 1'b0;
                endcase
                pc_target_w = br_taken_w ? (pc + imm_b) : (pc + 32'd4);
            end

            //-------------------------------------------------- LOAD
            7'b0000011: begin
                d_load_w = 1'b1;
                alu_w    = rs1_v + imm_i;
            end

            //-------------------------------------------------- STORE
            7'b0100011: begin
                d_store_w = 1'b1;
                alu_w     = rs1_v + imm_s;
            end

            //-------------------------------------------------- OP-IMM
            7'b0010011: begin
                case (f3)
                    3'b000: alu_w = rs1_v + imm_i;
                    3'b010: alu_w = {31'd0, ($signed(rs1_v) < $signed(imm_i))};
                    3'b011: alu_w = {31'd0, (rs1_v < imm_i)};
                    3'b100: alu_w = rs1_v ^ imm_i;
                    3'b110: alu_w = rs1_v | imm_i;
                    3'b111: alu_w = rs1_v & imm_i;
                    3'b001: alu_w = rs1_v << imm_i[4:0];
                    3'b101: alu_w = f7[5] ? ($signed(rs1_v) >>> imm_i[4:0])
                                          : (rs1_v >> imm_i[4:0]);
                    default: alu_w = 32'd0;
                endcase
            end

            //-------------------------------------------------- OP
            7'b0110011: begin
                if (f7 == 7'b0000001) begin
                    //----------------------------- M extension
                    case (f3)
                        3'b000, 3'b001, 3'b010, 3'b011: begin
                            d_mul_w = 1'b1;            // MUL/MULH/MULHSU/MULHU
                            alu_w   = 32'd0;
                        end
                        3'b100, 3'b101, 3'b110, 3'b111: begin
                            d_div_w = 1'b1;            // DIV/DIVU/REM/REMU
                            alu_w   = 32'd0;
                        end
                        default: alu_w = 32'd0;
                    endcase
                end else begin
                    case (f3)
                        3'b000: alu_w = f7[5] ? (rs1_v - rs2_v) : (rs1_v + rs2_v);
                        3'b010: alu_w = {31'd0, ($signed(rs1_v) < $signed(rs2_v))};
                        3'b011: alu_w = {31'd0, (rs1_v < rs2_v)};
                        3'b100: alu_w = rs1_v ^ rs2_v;
                        3'b110: alu_w = rs1_v | rs2_v;
                        3'b111: alu_w = rs1_v & rs2_v;
                        3'b001: alu_w = rs1_v << rs2_v[4:0];
                        3'b101: alu_w = f7[5] ? ($signed(rs1_v) >>> rs2_v[4:0])
                                              : (rs1_v >> rs2_v[4:0]);
                        default: alu_w = 32'd0;
                    endcase
                end
            end

            //-------------------------------------------------- FENCE / SYSTEM
            default: alu_w = 32'd0;
        endcase
    end

    wire reg_we_w = (opc == 7'b0110111) || (opc == 7'b0010111) ||
                    (opc == 7'b1101111) || (opc == 7'b1100111) ||
                    (opc == 7'b0000011) || (opc == 7'b0010011) ||
                    (opc == 7'b0110011);

    //------------------------------------------------------------------
    // Store data replication + byte strobes (based on EXEC address)
    //------------------------------------------------------------------
    reg [31:0] st_data_w;
    reg [3:0]  st_strb_w;

    always @* begin
        case (f3)
            3'b000: begin                               // SB
                st_data_w = {4{rs2_v[7:0]}};
                st_strb_w = 4'b0001 << alu_w[1:0];
            end
            3'b001: begin                               // SH
                st_data_w = {2{rs2_v[15:0]}};
                st_strb_w = alu_w[1] ? 4'b1100 : 4'b0011;
            end
            default: begin                              // SW
                st_data_w = rs2_v;
                st_strb_w = 4'b1111;
            end
        endcase
    end

    //------------------------------------------------------------------
    // Load data extraction / sign extension (used in ST_WB)
    //------------------------------------------------------------------
    wire [31:0] ld_shift = dmem_rdata >> {mem_off_r, 3'b000};

    reg [31:0] ld_ext;
    always @* begin
        case (mem_f3_r)
            3'b000: ld_ext = {{24{ld_shift[7]}},  ld_shift[7:0]};    // LB
            3'b001: ld_ext = {{16{ld_shift[15]}}, ld_shift[15:0]};   // LH
            3'b100: ld_ext = {24'd0, ld_shift[7:0]};                 // LBU
            3'b101: ld_ext = {16'd0, ld_shift[15:0]};                // LHU
            default: ld_ext = ld_shift;                              // LW
        endcase
    end

    wire [31:0] wb_data = mem_is_load_r ? ld_ext : alu_r;

    //------------------------------------------------------------------
    // Output ports
    //------------------------------------------------------------------
    assign imem_addr = pc[15:2];
    assign dmem_req  = (state == ST_MEM);
    assign dmem_we   = (state == ST_MEM) && mem_is_store_r;
    assign dmem_addr = mem_addr_r;
    assign dmem_wdata = mem_wdata_r;
    assign dmem_wstrb = mem_wstrb_r;

    assign dbg_pc    = pc;
    assign dbg_state = state;
    assign dbg_halt  = halt_r;

    //------------------------------------------------------------------
    // Retirement / instruction-class counters (drive top-level perf regs)
    //------------------------------------------------------------------
    reg [2:0] cls_w;
    always @* begin
        case (opc)
            7'b0000011: cls_w = 3'd1;                       // LOAD
            7'b0100011: cls_w = 3'd2;                       // STORE
            7'b1100011, 7'b1101111, 7'b1100111: cls_w = 3'd3; // BRANCH / JAL / JALR
            7'b0110011: cls_w = (f7 == 7'b0000001)
                                ? (f3[2] ? 3'd5 : 3'd4)     // DIV / MUL
                                : 3'd0;
            default:    cls_w = 3'd0;                       // ALU / LUI / AUIPC / OP-IMM
        endcase
    end

    assign retire     = (state == ST_WB);
    assign retire_cls = cls_w;

    //------------------------------------------------------------------
    // FSM
    //------------------------------------------------------------------
    always @(posedge clk) begin
        if (rst) begin
            state          <= ST_FETCH;
            pc             <= 32'd0;
            pc_next        <= 32'd0;
            ir             <= 32'd0;
            alu_r          <= 32'd0;
            mem_addr_r     <= 32'd0;
            mem_wdata_r    <= 32'd0;
            mem_wstrb_r    <= 4'd0;
            mem_off_r      <= 2'd0;
            mem_f3_r       <= 3'd0;
            mem_is_load_r  <= 1'b0;
            mem_is_store_r <= 1'b0;
            reg_we_r       <= 1'b0;
            rd_r           <= 5'd0;
            halt_r         <= 1'b0;
            div_a          <= 32'd0;
            div_b          <= 32'd0;
            div_r          <= 33'd0;
            div_q          <= 32'd0;
            div_cnt        <= 6'd0;
            div_is_rem     <= 1'b0;
            div_neg_q      <= 1'b0;
            div_neg_r      <= 1'b0;
            mul_full_r     <= 64'd0;
            mul_a_r        <= 32'd0;
            mul_b_r        <= 32'd0;
            mul_f3_r       <= 3'd0;
        end else if (halt_r) begin
            // Core halted (EBREAK/ECALL): freeze PC, registers and the
            // memory interface.  Keeping this outside the case statement
            // guarantees the one-hot state bit cannot be optimised away.
            halt_r <= 1'b1;
        end else begin
            case (state)
                //------------------------------------------------ FETCH
                ST_FETCH: begin
                    state <= ST_DECODE;
                end

                //------------------------------------------------ DECODE
                // imem_rdata is valid here (1 cycle ROM latency)
                ST_DECODE: begin
                    ir    <= imem_rdata;
                    state <= ST_EXEC;
                end

                //------------------------------------------------ EXEC
                ST_EXEC: begin
                    alu_r          <= alu_w;
                    mem_addr_r     <= alu_w;
                    mem_off_r      <= alu_w[1:0];
                    mem_f3_r       <= f3;
                    mem_is_load_r  <= d_load_w;
                    mem_is_store_r <= d_store_w;
                    mem_wdata_r    <= st_data_w;
                    mem_wstrb_r    <= st_strb_w;
                    rd_r           <= rd_i;
                    reg_we_r       <= reg_we_w;

                    if (d_branch_w || d_jal_w || d_jalr_w)
                        pc_next <= pc_target_w;
                    else
                        pc_next <= pc + 32'd4;

                    if (opc == 7'b1110011) begin        // ECALL / EBREAK
                        halt_r <= 1'b1;
                        state  <= ST_HALT;
                    end else if (d_div_w) begin
                        //-------------------------------- M extension divide
                        div_is_rem <= f3[1];
                        div_cnt    <= 6'd32;
                        div_q      <= 32'd0;
                        div_r      <= 33'd0;
                        if (!f3[0]) begin
                            // signed: use absolute values, remember the signs
                            div_a     <= rs1_v[31] ? (~rs1_v + 32'd1) : rs1_v;
                            div_b     <= rs2_v[31] ? (~rs2_v + 32'd1) : rs2_v;
                            div_neg_q <= rs1_v[31] ^ rs2_v[31];
                            div_neg_r <= rs1_v[31];
                        end else begin
                            div_a     <= rs1_v;
                            div_b     <= rs2_v;
                            div_neg_q <= 1'b0;
                            div_neg_r <= 1'b0;
                        end

                        if (rs2_v == 32'd0) begin
                            // division by zero: q = -1, r = dividend
                            alu_r <= f3[1] ? rs1_v : 32'hFFFFFFFF;
                            state <= ST_WB;
                        end else begin
                            state <= ST_DIV;
                        end
                    end else if (d_mul_w) begin
                        //-------------------------------- M extension multiply
                        // the DSP output is captured here; the signed
                        // high-word correction happens in ST_MUL
                        mul_full_r <= mul_full_w;
                        mul_a_r    <= rs1_v;
                        mul_b_r    <= rs2_v;
                        mul_f3_r   <= f3;
                        state      <= ST_MUL;
                    end else if (d_load_w || d_store_w) begin
                        state  <= ST_MEM;
                    end else begin
                        state  <= ST_WB;
                    end
                end

                //------------------------------------------------ MUL
                ST_MUL: begin
                    alu_r <= mul_res_w;
                    state <= ST_WB;
                end

                //------------------------------------------------ DIV
                // Restoring division, one quotient bit per cycle (32 steps).
                ST_DIV: begin
                    if (div_cnt == 6'd0) begin
                        alu_r <= div_is_rem ? div_r_final : div_q_final;
                        state <= ST_WB;
                    end else begin
                        div_r   <= div_ge ? div_r_sub : div_r_shift;
                        div_q   <= {div_q[30:0], div_ge};
                        div_a   <= {div_a[30:0], 1'b0};
                        div_cnt <= div_cnt - 6'd1;
                    end
                end

                //------------------------------------------------ MEM
                // dmem_req/we/addr/data are asserted combinationally while
                // state==ST_MEM; RAM returns data on the next clock edge.
                ST_MEM: begin
                    state <= ST_WB;
                end

                //------------------------------------------------ WB
                ST_WB: begin
                    if (reg_we_r && (rd_r != 5'd0))
                        regs[rd_r] <= wb_data;
                    pc    <= pc_next;
                    state <= ST_FETCH;
                end

                //------------------------------------------------ HALT
                ST_HALT: begin
                    state <= ST_HALT;
                end

                default: state <= ST_FETCH;
            endcase
        end
    end

endmodule

`default_nettype wire
