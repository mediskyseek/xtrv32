//============================================================================
//  v0.5 MUL fast-path bench (back-to-back / dependent / mixed MULH)
//============================================================================
`timescale 1ns / 1ps
`default_nettype none

module tb_v4_mulchain;

    reg clk = 1'b0;
    always #5 clk = ~clk;
    reg rst = 1'b1;

    wire [13:0] imem_addr;
    wire [31:0] imem_rdata;
    wire [31:0] dbg_pc;
    wire        dbg_halt;
    wire        retire;
    wire [2:0]  retire_cls;
    wire        dmem_req, dmem_we;
    wire [31:0] dmem_addr, dmem_wdata;
    wire [3:0]  dmem_wstrb;

    myxtrv32_rom u_rom (.clk(clk), .iaddr(imem_addr), .idata(imem_rdata),
                        .daddr(14'd0), .ddata());

    myxtrv32_core_v4p dut (
        .clk(clk), .rst(rst),
        .imem_addr(imem_addr), .imem_rdata(imem_rdata),
        .dmem_req(dmem_req), .dmem_we(dmem_we), .dmem_addr(dmem_addr),
        .dmem_wdata(dmem_wdata), .dmem_wstrb(dmem_wstrb),
        .dmem_rdata(32'd0),
        .dbg_pc(dbg_pc), .dbg_halt(dbg_halt), .retire(retire),
        .retire_cls(retire_cls),
        .ev_flush(), .ev_br_taken(), .ev_br_not(),
        .ev_stall_ld(), .ev_stall_br(), .ev_stall_md());

    integer cycles  = 0;
    integer instret = 0;
    integer errors  = 0;

    always @(posedge clk) begin
        cycles = cycles + 1;
        if (retire)
            instret = instret + 1;
    end

    task automatic check(input [4:0] r, input [31:0] exp);
        begin
            if (dut.regs[r] !== exp) begin
                errors = errors + 1;
                $display("[TB] FAIL x%0d = 0x%08x expected 0x%08x",
                         r, dut.regs[r], exp);
            end
        end
    endtask

    initial begin
        #20 rst = 1'b0;
        wait (dbg_halt === 1'b1);
        #100;

        check(5'd10, 32'h0626_0060);
        check(5'd11, 32'h0000_369C);
        check(5'd12, 32'h0001_0368);
        check(5'd13, 32'h1272_0120);
        check(5'd14, 32'h3756_0360);
        check(5'd15, 32'h0001_0368);
        check(5'd16, 32'h0000_0000);   // 0x1234*0x5678 = 0x0626_0060
        check(5'd17, 32'h0000_0000);
        check(5'd20, 32'h0000_0000);
        check(5'd21, 32'hFFFF_FFFF);   // -1 (signed) * 0x1234 (unsigned) >> 32
        check(5'd23, 32'h0627_0060);

        if (errors == 0) begin
            $display("[TB] PASS: MUL chain, cycles=%0d instret=%0d",
                     cycles, instret);
            $finish;
        end else begin
            $display("[TB] FAIL: %0d register mismatches", errors);
            $fatal(1);
        end
    end

    initial begin
        #100_000;
        $display("[TB] FAIL: timeout, pc=0x%08x", dbg_pc);
        $fatal(1);
    end

endmodule

`default_nettype wire
