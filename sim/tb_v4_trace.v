//============================================================================
//  v0.5 branch trace bench (for BTB / RAS feasibility analysis)
//
//  Runs the real top level (ROM + RAM + UART + counters) with a short CoreMark
//  image and dumps one line per executed branch/jump:
//
//      cycle  pc  type  taken  target  rd  rs1
//      type: 0 = conditional branch, 1 = JAL, 2 = JALR
//
//  cycle lets the analyser split the run into iterations and check that the
//  prediction statistics are stationary.  rd/rs1 let it model a return stack
//  (jalr with rd=x0 and rs1 in {x1,x5} is a return).
//============================================================================
`timescale 1ns / 1ps
`default_nettype none

module tb_v4_trace;

    parameter integer CYC_LIMIT   = 8_000_000;
    parameter         TRACE_FILE  = "out/branch_trace.txt";

    localparam integer CLK_HZ    = 100_000_000;
    localparam integer BAUD      = 115_200;

    reg clk = 1'b0;
    always #5 clk = ~clk;

    wire uart_tx;
    wire led_run;
    wire led_error;

    myxtrv32_top_v4 #(
        .CLK_HZ     (CLK_HZ),
        .BAUD       (BAUD),
        .POR_CYCLES (32)
    ) dut (
        .clk       (clk),
        .uart_tx   (uart_tx),
        .led_run   (led_run),
        .led_error (led_error)
    );

    integer fd;
    integer cycles = 0;
    integer nbranch = 0;
    integer nred = 0;
    integer nret = 0;
    integer nbt = 0;
    integer nbn = 0;
    integer nretbr = 0;
    integer nretld = 0;

    initial begin
        fd = $fopen(TRACE_FILE, "w");
        if (fd == 0) begin
            $display("[TB] FAIL: cannot open %s", TRACE_FILE);
            $fatal(1);
        end
        $display("[TB] tracing to %s, limit %0d cycles", TRACE_FILE, CYC_LIMIT);
    end

    // Sample on the falling edge: the decode/branch/resolve logic is pure
    // combinational and is fully settled there, so the recorded pc/taken/
    // target all describe the instruction sitting in IF/ID in this cycle.
    always @(negedge clk) begin
        if (!dut.u_core.rst && !dut.u_core.halt_r && dut.u_core.if_id_valid
            && !dut.u_core.stall
            && (dut.u_core.is_branch || dut.u_core.is_jal || dut.u_core.is_jalr)) begin
            $fwrite(fd, "%0d %08x %0d %0d %08x %0d %0d\n",
                    cycles,
                    dut.u_core.if_id_pc,
                    dut.u_core.is_branch ? 0 : (dut.u_core.is_jal ? 1 : 2),
                    dut.u_core.is_branch ? dut.u_core.br_cond : 1'b1,
                    dut.u_core.pc_target,
                    dut.u_core.rd,
                    dut.u_core.rs1);
            nbranch = nbranch + 1;
        end

        if (dut.u_core.redirect && !dut.u_core.stall && !dut.u_core.halt_r)
            nred = nred + 1;
        // same expressions the PERF_EXT counters use
        if (dut.u_core.is_branch && dut.u_core.if_id_valid && dut.u_core.br_cond
            && !dut.u_core.stall)
            nbt = nbt + 1;
        if (dut.u_core.is_branch && dut.u_core.if_id_valid && !dut.u_core.br_cond
            && !dut.u_core.stall)
            nbn = nbn + 1;
    end

    always @(posedge clk) begin
        cycles = cycles + 1;
        if (dut.u_core.retire) begin
            nret = nret + 1;
            if (dut.u_core.retire_cls == 3'd3) nretbr = nretbr + 1;
            if (dut.u_core.retire_cls == 3'd1) nretld = nretld + 1;
        end

        if (cycles >= CYC_LIMIT) begin
            $fclose(fd);
            $display("[TB] DONE: cyc=%0d rec=%0d red=%0d ret=%0d br_ret=%0d ld_ret=%0d taken=%0d not=%0d",
                     cycles, nbranch, nred, nret, nretbr, nretld, nbt, nbn);
            $finish;
        end
    end

endmodule

`default_nettype wire
