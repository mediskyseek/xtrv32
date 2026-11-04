//============================================================================
//  v0.4 three-stage testbench -- MUL / DIV subset
//============================================================================
`timescale 1ns / 1ps
`default_nettype none

module tb_v4_muldiv;

    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg rst = 1'b1;

    wire [13:0] imem_addr;
    wire [31:0] imem_rdata;
    wire [31:0] dbg_pc;
    wire        dbg_halt;
    wire        retire;
    wire [2:0]  retire_cls;
    wire        dmem_req;
    wire        dmem_we;
    wire [31:0] dmem_addr;
    wire [31:0] dmem_wdata;
    wire [3:0]  dmem_wstrb;

    myxtrv32_rom u_rom (
        .clk   (clk),
        .iaddr (imem_addr),
        .idata (imem_rdata),
        .daddr (14'd0),
        .ddata ()
    );

    myxtrv32_core_v4p dut (
        .clk        (clk),
        .rst        (rst),
        .imem_addr  (imem_addr),
        .imem_rdata (imem_rdata),
        .dmem_req   (dmem_req),
        .dmem_we    (dmem_we),
        .dmem_addr  (dmem_addr),
        .dmem_wdata (dmem_wdata),
        .dmem_wstrb (dmem_wstrb),
        .dmem_rdata (32'd0),
        .dbg_pc     (dbg_pc),
        .dbg_halt   (dbg_halt),
        .retire     (retire),
        .retire_cls (retire_cls)
    );

    integer cycles  = 0;
    integer instret = 0;
    integer errors  = 0;
    integer cycles_halt  = 0;
    integer instret_halt = 0;

    always @(posedge clk) begin
        cycles = cycles + 1;
        if (retire)
            instret = instret + 1;
    end

    always @(posedge clk) begin
        if (dut.mul_start || dut.mul_busy || dut.div_busy || dut.ex_mem_valid)
            $display("[M] pc=%h ms=%b mb=%b db=%b dc=%0d stall=%b alu=%h exv=%b exrd=%0d exalu=%h we=%b",
                     dbg_pc, dut.mul_start, dut.mul_busy, dut.div_busy, dut.div_cnt,
                     dut.stall, dut.alu_out, dut.ex_mem_valid, dut.ex_mem_rd,
                     dut.ex_mem_alu, dut.ex_mem_we);
    end

    task automatic check(input [4:0] r, input [31:0] exp);
        begin
            if (dut.regs[r] !== exp) begin
                errors = errors + 1;
                $display("[TB] FAIL x%0d = 0x%08x expected 0x%08x", r, dut.regs[r], exp);
            end
        end
    endtask

    initial begin
        #20 rst = 1'b0;

        wait (dbg_halt === 1'b1);
        cycles_halt  = cycles;
        instret_halt = instret;
        #100;

        check(5'd3,  32'd42);
        check(5'd4,  32'd48);
        check(5'd7,  32'd14);
        check(5'd8,  32'd2);
        check(5'd9,  32'd16);
        check(5'd11, 32'hFFFF_FFFF);
        check(5'd12, 32'd0);
        check(5'd15, 32'hFFFF_FFFD);   // -3
        check(5'd16, 32'hFFFF_FFFF);   // -1
        check(5'd19, 32'd2);
        check(5'd20, 32'd1);
        check(5'd21, 32'hFFFF_FFFF);   // 6/0
        check(5'd22, 32'd6);           // 6%0
        check(5'd25, 32'd0);
        check(5'd26, 32'hFFFF_FFFE);
        check(5'd30, 32'd2);           // exactly once each

        if (errors == 0) begin
            $display("[TB] PASS: MUL/DIV, cycles=%0d instret=%0d cpi=%0d.%02d",
                     cycles_halt, instret_halt,
                     cycles_halt / instret_halt,
                     (cycles_halt * 100 / instret_halt) % 100);
            $finish;
        end else begin
            $display("[TB] FAIL: %0d mismatches", errors);
            $fatal(1);
        end
    end

    initial begin
        #300_000;
        $display("[TB] FAIL: timeout waiting for halt, pc=0x%08x", dbg_pc);
        $fatal(1);
    end

endmodule

`default_nettype wire
