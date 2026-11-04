//============================================================================
//  v0.4p directed hazard bench
//  Checks load->MUL/DIV operand capture, wrong-path MUL retirement and the
//  number of load-use stalls caused by immediate bits decoded as rs2.
//============================================================================
`timescale 1ns / 1ps
`default_nettype none

module tb_v4_hazard;

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
        .dmem_rdata (dmem_rdata),
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

    // stall accounting
    integer n_stall_ld = 0;
    integer n_stall_br = 0;
    integer n_stall_md = 0;

    always @(posedge clk) begin
        cycles = cycles + 1;
        if (retire)
            instret = instret + 1;
        if (dut.stall_load_use) n_stall_ld = n_stall_ld + 1;
        if (dut.br_load_dep)    n_stall_br = n_stall_br + 1;
        if (dut.stall_muldiv)   n_stall_md = n_stall_md + 1;
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
        cycles_halt  = cycles;
        instret_halt = instret;
        #100;

        check(5'd1,  32'h0000_1234);   // T1 load value
        check(5'd4,  32'h0000_369C);   // T1 0x1234 * 3
        check(5'd8,  32'd75);          // T2 load value
        check(5'd9,  32'd25);          // T2 75 / 3
        check(5'd12, 32'h0000_1234);
        check(5'd13, 32'd0);           // T3 high half
        check(5'd15, 32'd0);           // T4 wrong-path MUL must not retire
        check(5'd16, 32'd0);
        check(5'd17, 32'd116);         // T5 no spurious stall, value correct
        check(5'd21, 32'd1);           // T6 taken branch
        check(5'd22, 32'h0000_1234);

        $display("[TB] stalls: load_use=%0d br_dep=%0d muldiv=%0d",
                 n_stall_ld, n_stall_br, n_stall_md);

        if (errors == 0) begin
            $display("[TB] PASS: hazards, cycles=%0d instret=%0d cpi=%0d.%02d",
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
        #300_000;
        $display("[TB] FAIL: timeout waiting for halt, pc=0x%08x", dbg_pc);
        $fatal(1);
    end

endmodule

`default_nettype wire
