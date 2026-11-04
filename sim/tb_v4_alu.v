//============================================================================
//  v0.4 three-stage skeleton testbench (ALU subset)
//  Checks the architectural registers after EBREAK and counts retirements.
//============================================================================
`timescale 1ns / 1ps
`default_nettype none

module tb_v4_alu;

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
        .retire_cls (retire_cls),
        .ev_flush   (),
        .ev_br_taken(),
        .ev_br_not  (),
        .ev_stall_ld(),
        .ev_stall_br(),
        .ev_stall_md()
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
        check(5'd1,  32'h0000_0005);
        check(5'd2,  32'h0000_0008);
        check(5'd3,  32'h0000_000D);
        check(5'd4,  32'h0000_0005);
        check(5'd5,  32'hFFFF_FFFF);
        check(5'd6,  32'h0000_0000);
        check(5'd7,  32'h0000_000D);
        check(5'd8,  32'h0000_0005);
        check(5'd9,  32'h0000_000D);
        check(5'd10, 32'h0000_0014);
        check(5'd11, 32'h0000_000A);
        check(5'd12, 32'hFFFF_FFFF);
        check(5'd13, 32'h0000_0001);
        check(5'd14, 32'h0000_0000);
        check(5'd15, 32'h1234_5000);
        check(5'd16, 32'h0000_0007);
        check(5'd17, 32'h0000_0000);

        if (errors == 0) begin
            $display("[TB] PASS: ALU skeleton, cycles=%0d instret=%0d cpi=%0d.%02d",
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
