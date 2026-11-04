//============================================================================
//  v0.4 three-stage testbench -- LOAD/STORE subset
//  Instantiates ROM + core + RAM with the same "selects registered once"
//  convention the real top level uses, so load data lands in MEM/WB.
//============================================================================
`timescale 1ns / 1ps
`default_nettype none

module tb_v4_mem;

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

    //---- data RAM at 0x0001_0000, selects registered like the real top ----
    wire [31:0] ram_rdata;
    wire sel_ram = (dmem_addr[31:16] == 16'h0001) && dmem_req;

    myxtrv32_ram u_ram (
        .clk   (clk),
        .addr  (dmem_addr[15:2]),
        .wdata (dmem_wdata),
        .wstrb (dmem_wstrb),
        .we    (sel_ram && dmem_we),
        .rdata (ram_rdata)
    );

    reg sel_ram_q;
    always @(posedge clk)
        sel_ram_q <= sel_ram;

    wire [31:0] dmem_rdata = sel_ram_q ? ram_rdata : 32'd0;

    myxtrv32_core_v4 dut (
        .clk        (clk),
        .rst        (rst),
        .imem_addr  (imem_addr),
        .imem_rdata (imem_rdata),
        .dmem_req   (dmem_req),
        .dmem_we    (dmem_we),
        .dmem_addr  (dmem_addr),
        .dmem_wdata (dmem_wdata),
        .dmem_wstrb (dmem_wstrb),
        .dmem_rdata (dmem_rdata),
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

        check(5'd0,  32'h0000_0000);
        check(5'd1,  32'hDEAD_BEEF);
        check(5'd2,  32'h0001_0000);
        check(5'd3,  32'hBD5B_7DDE);
        check(5'd4,  32'h0000_1234);
        check(5'd5,  32'hBD5B_9012);
        check(5'd6,  32'h0000_00AA);
        check(5'd7,  32'hFFFF_FFAA);
        check(5'd8,  32'h0000_BEEF);
        check(5'd9,  32'hFFFF_BEEF);
        check(5'd10, 32'hDEAD_BEEF);
        check(5'd11, 32'h0000_1234);
        check(5'd12, 32'h0000_00AA);
        check(5'd13, 32'h0000_BEEF);
        check(5'd14, 32'hFFFF_FFAB);

        if (errors == 0) begin
            $display("[TB] PASS: LOAD/STORE skeleton, cycles=%0d instret=%0d cpi=%0d.%02d",
                     cycles_halt, instret_halt,
                     cycles_halt / instret_halt,
                     (cycles_halt * 100 / instret_halt) % 100);
            $finish;
        end else begin
            $display("[TB] FAIL: %0d register mismatches", errors);
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
