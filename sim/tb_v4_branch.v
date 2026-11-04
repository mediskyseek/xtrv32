//============================================================================
//  v0.4 three-stage testbench -- branch / jump subset
//  x3 must reach 6; every taken/not-taken path and both jump forms are
//  exercised, and any wrong-path execution would leave 99 in x3.
//============================================================================
`timescale 1ns / 1ps
`default_nettype none

module tb_v4_branch;

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

        check(5'd3, 32'h0000_0006);

        if (dut.regs[6] == 32'd0 || (dut.regs[6] & 3) != 0) begin
            errors = errors + 1;
            $display("[TB] FAIL jal return address x6 = 0x%08x", dut.regs[6]);
        end
        if (dut.regs[8] == 32'd0 || (dut.regs[8] & 3) != 0) begin
            errors = errors + 1;
            $display("[TB] FAIL jalr return address x8 = 0x%08x", dut.regs[8]);
        end
        if (!(dut.regs[6] < dut.regs[8])) begin
            errors = errors + 1;
            $display("[TB] FAIL expected x6 < x8 (got 0x%08x / 0x%08x)",
                     dut.regs[6], dut.regs[8]);
        end

        if (errors == 0) begin
            $display("[TB] PASS: branch/jump, cycles=%0d instret=%0d cpi=%0d.%02d x6=0x%08x x8=0x%08x",
                     cycles_halt, instret_halt,
                     cycles_halt / instret_halt,
                     (cycles_halt * 100 / instret_halt) % 100,
                     dut.regs[6], dut.regs[8]);
            $finish;
        end else begin
            $display("[TB] FAIL: %0d mismatches", errors);
            $fatal(1);
        end
    end

    initial begin
        #200_000;
        $display("[TB] FAIL: timeout waiting for halt, pc=0x%08x", dbg_pc);
        $fatal(1);
    end

endmodule

`default_nettype wire
