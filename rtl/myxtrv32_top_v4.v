//============================================================================
//  MyXTRV32 v0.1  --  top level for xc7z020 (100 MHz input clock)
//----------------------------------------------------------------------------
//  Board resources used (see IO_ZYNQ7020.xlsx)
//    clk        N18  100 MHz single ended input
//    uart_tx    L14  (extension header, CH340/RS232 side)
//    led_run    P18
//    led_error  N17
//
//  Power on reset is generated internally (~0.65 ms) so no reset pin is
//  required.  The CPU boots from word 0 of the internal ROM.
//============================================================================
`timescale 1ns / 1ps
`default_nettype none

module myxtrv32_top_v4 #(
    parameter integer CLK_HZ     = 100_000_000,
    parameter integer BAUD       = 115200,
    parameter integer POR_CYCLES = 65536        // ~0.65 ms at 100 MHz
) (
    input  wire clk,
    output wire uart_tx,
    output wire led_run,
    output wire led_error
);

    //------------------------------------------------------------------
    // Power-on reset
    //------------------------------------------------------------------
    reg [31:0] por_cnt = 32'd0;
    reg        rst     = 1'b1;

    always @(posedge clk) begin
        if (por_cnt < POR_CYCLES) begin
            por_cnt <= por_cnt + 32'd1;
            rst     <= 1'b1;
        end else begin
            rst     <= 1'b0;
        end
    end

    //------------------------------------------------------------------
    // CPU
    //------------------------------------------------------------------
    wire [13:0] imem_addr;
    wire [31:0] imem_rdata;

    wire        dmem_req;
    wire        dmem_we;
    wire [31:0] dmem_addr;
    wire [31:0] dmem_wdata;
    wire [3:0]  dmem_wstrb;
    wire [31:0] dmem_rdata;

    wire [31:0] dbg_pc;
    wire        dbg_halt;
    wire        retire;
    wire [2:0]  retire_cls;
    wire        ev_flush;
    wire        ev_br_taken;
    wire        ev_br_not;
    wire        ev_stall_ld;
    wire        ev_stall_br;
    wire        ev_stall_md;

    myxtrv32_core_v4p u_core (
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
        .ev_flush   (ev_flush),
        .ev_br_taken(ev_br_taken),
        .ev_br_not  (ev_br_not),
        .ev_stall_ld(ev_stall_ld),
        .ev_stall_br(ev_stall_br),
        .ev_stall_md(ev_stall_md)
    );

    //------------------------------------------------------------------
    // Instruction ROM (64 KiB, generated from the firmware image)
    // Port A feeds the fetch unit, port B lets the CPU load constants
    // (strings, tables) from the same 0x0000..0xFFFF window.
    //------------------------------------------------------------------
    wire [31:0] rom_ddata;

    wire [31:0] A = dmem_addr;

    myxtrv32_rom u_rom (
        .clk   (clk),
        .iaddr (imem_addr),
        .idata (imem_rdata),
        .daddr (A[15:2]),
        .ddata (rom_ddata)
    );

    //------------------------------------------------------------------
    // Address decode
    //   0x0000_0000..0xFFFF  ROM
    //   0x0001_0000..0xFFFF  RAM
    //   0x0002_00xx          UART TX
    //   0x0002_01xx          GPIO
    //   0x0002_02xx          MTIME
    //   0x0002_03xx          PERF counters
    //------------------------------------------------------------------
    wire sel_rom   = dmem_req && (A[31:16] == 16'h0000);
    wire sel_ram   = dmem_req && (A[31:16] == 16'h0001);
    wire sel_uart  = dmem_req && (A[31:8] == 24'h000200);
    wire sel_gpio  = dmem_req && (A[31:8] == 24'h000201);
    wire sel_mtime = dmem_req && (A[31:8] == 24'h000202);
    wire sel_perf  = dmem_req && (A[31:8] == 24'h000203);

    //------------------------------------------------------------------
    // Data RAM (64 KiB @ 0x0001_0000)
    //------------------------------------------------------------------
    wire [31:0] ram_rdata;

    myxtrv32_ram u_ram (
        .clk   (clk),
        .addr  (A[15:2]),
        .wdata (dmem_wdata),
        .wstrb (dmem_wstrb),
        .we    (sel_ram && dmem_we),
        .rdata (ram_rdata)
    );

    //------------------------------------------------------------------
    // UART TX @ 0x0002_0000
    //   +0 write : TX byte (trigger)
    //   +4 read  : bit0 = busy
    //------------------------------------------------------------------
    wire        uart_send = sel_uart && dmem_we && (A[3:2] == 2'b00);
    wire [7:0]  uart_data = dmem_wdata[7:0];
    wire        uart_busy;

    myxtrv32_uart_tx #(
        .CLK_HZ (CLK_HZ),
        .BAUD   (BAUD)
    ) u_uart (
        .clk  (clk),
        .rst  (rst),
        .data (uart_data),
        .send (uart_send),
        .busy (uart_busy),
        .tx   (uart_tx)
    );

    //------------------------------------------------------------------
    // GPIO @ 0x0002_0100
    //   +0 bit0 = led_run, bit1 = led_error
    //   +4 free running 32-bit counter (read only, ~43 s wrap)
    //------------------------------------------------------------------
    reg [1:0]  led_r;
    reg [31:0] free_cnt;

    always @(posedge clk) begin
        if (rst) begin
            led_r    <= 2'b00;
            free_cnt <= 32'd0;
        end else begin
            free_cnt <= free_cnt + 32'd1;
            if (sel_gpio && dmem_we && (A[3:2] == 2'b00))
                led_r <= dmem_wdata[1:0];
        end
    end

    //------------------------------------------------------------------
    // MTIME @ 0x0002_0200 : 64-bit free running counter at CLK_HZ
    //   +0 read : low  32 bits (also latches the high word)
    //   +4 read : high 32 bits (latched, safe against a carry between reads)
    //------------------------------------------------------------------
    reg [63:0] mtime;
    reg [31:0] mtime_hi_l;

    always @(posedge clk) begin
        if (rst) begin
            mtime    <= 64'd0;
            mtime_hi_l <= 32'd0;
        end else begin
            mtime <= mtime + 64'd1;
            if (sel_mtime && !dmem_we && (A[3:2] == 2'b00))
                mtime_hi_l <= mtime[63:32];
        end
    end

    wire [31:0] mtime_read = (A[3:2] == 2'b01) ? mtime_hi_l : mtime[31:0];

    //------------------------------------------------------------------
    // PERF counters @ 0x0002_0300 (read only, 32 bit each)
    //   +0x00 instret        +0x04 ALU      +0x08 LOAD
    //   +0x0C STORE          +0x10 BR/JUMP  +0x14 MUL
    //   +0x18 DIV
    //------------------------------------------------------------------
    reg [31:0] perf_inst;
    reg [31:0] perf_alu;
    reg [31:0] perf_load;
    reg [31:0] perf_store;
    reg [31:0] perf_br;
    reg [31:0] perf_mul;
    reg [31:0] perf_div;
`ifdef PERF_EXT
    reg [31:0] perf_btaken;
    reg [31:0] perf_bnot;
    reg [31:0] perf_st_ld;
    reg [31:0] perf_st_br;
    reg [31:0] perf_st_md;
    reg [31:0] perf_flush;

    always @(posedge clk) begin
        if (rst) begin
            perf_inst  <= 32'd0;
            perf_alu   <= 32'd0;
            perf_load  <= 32'd0;
            perf_store <= 32'd0;
            perf_br    <= 32'd0;
            perf_mul   <= 32'd0;
            perf_div   <= 32'd0;
            perf_btaken <= 32'd0;
            perf_bnot  <= 32'd0;
            perf_st_ld <= 32'd0;
            perf_st_br <= 32'd0;
            perf_st_md <= 32'd0;
            perf_flush <= 32'd0;
        end else begin
            if (retire) begin
                perf_inst <= perf_inst + 32'd1;
                case (retire_cls)
                    3'd0: perf_alu   <= perf_alu   + 32'd1;
                    3'd1: perf_load  <= perf_load  + 32'd1;
                    3'd2: perf_store <= perf_store + 32'd1;
                    3'd3: perf_br    <= perf_br    + 32'd1;
                    3'd4: perf_mul   <= perf_mul   + 32'd1;
                    3'd5: perf_div   <= perf_div   + 32'd1;
                    default: ;
                endcase
            end
            if (ev_br_taken) perf_btaken <= perf_btaken + 32'd1;
            if (ev_br_not)   perf_bnot   <= perf_bnot   + 32'd1;
            if (ev_stall_ld) perf_st_ld  <= perf_st_ld  + 32'd1;
            if (ev_stall_br) perf_st_br  <= perf_st_br  + 32'd1;
            if (ev_stall_md) perf_st_md  <= perf_st_md  + 32'd1;
            if (ev_flush)    perf_flush  <= perf_flush  + 32'd1;
        end
    end

`endif

    reg [31:0] perf_read;
    always @* begin
        case (A[5:2])
            4'd0:  perf_read = perf_inst;
            4'd1:  perf_read = perf_alu;
            4'd2:  perf_read = perf_load;
            4'd3:  perf_read = perf_store;
            4'd4:  perf_read = perf_br;
            4'd5:  perf_read = perf_mul;
            4'd6:  perf_read = perf_div;






            default: perf_read = 32'd0;
`ifdef PERF_EXT
                4'd7:  perf_read = perf_btaken;
                4'd8:  perf_read = perf_bnot;
                4'd9:  perf_read = perf_st_ld;
                4'd10: perf_read = perf_st_br;
                4'd11: perf_read = perf_st_md;
                4'd12: perf_read = perf_flush;
`endif
            endcase
    end

    //------------------------------------------------------------------
    // Read data mux.  The RAM has a one cycle read latency, so the MMIO
    // values and the decode selects are registered once to line up with
    // the ST_WB state of the core.
    //------------------------------------------------------------------
    reg        sel_rom_q;
    reg        sel_ram_q;
    reg        sel_uart_q;
    reg        sel_gpio_q;
    reg        sel_mtime_q;
    reg        sel_perf_q;
    reg [31:0] uart_rdata_q;
    reg [31:0] gpio_rdata_q;
    reg [31:0] mtime_rdata_q;
    reg [31:0] perf_rdata_q;

    wire [31:0] gpio_read = (A[3:2] == 2'b01) ? free_cnt : {30'd0, led_r};

    always @(posedge clk) begin
        sel_rom_q    <= sel_rom;
        sel_ram_q    <= sel_ram;
        sel_uart_q   <= sel_uart;
        sel_gpio_q   <= sel_gpio;
        sel_mtime_q  <= sel_mtime;
        sel_perf_q   <= sel_perf;
        uart_rdata_q <= {31'd0, uart_busy};
        gpio_rdata_q <= gpio_read;
        mtime_rdata_q <= mtime_read;
        perf_rdata_q  <= perf_read;
    end

    // ram_rdata / rom_ddata are registered inside their memories on the
    // same edge that latches sel_*_q, so a plain mux is already aligned
    // with ST_WB.
    assign dmem_rdata = sel_rom_q   ? rom_ddata     :
                        sel_ram_q   ? ram_rdata     :
                        sel_uart_q  ? uart_rdata_q  :
                        sel_gpio_q  ? gpio_rdata_q  :
                        sel_mtime_q ? mtime_rdata_q :
                        sel_perf_q  ? perf_rdata_q  : 32'd0;

    //------------------------------------------------------------------
    // LEDs
    //------------------------------------------------------------------
    assign led_run   = led_r[0];
    assign led_error = led_r[1] | dbg_halt;

endmodule

`default_nettype wire
