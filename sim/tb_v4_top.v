//============================================================================
//  MyXTRV32 v0.1 behavioural testbench
//    * 100 MHz clock, BAUD raised to 1 Mbaud so the run is short
//    * decodes uart_tx and prints every byte
//    * counts LED transitions, stops after the "DONE" line
//============================================================================
`timescale 1ns / 1ps
`default_nettype none

module tb_v4_top;

    // Number of '\n' terminated lines the firmware is expected to print
    // before the bench declares success.  Override per firmware:
    //   iverilog -P tb_v4_top.LINES=1 ...
    parameter integer LINES = 2;

    localparam integer CLK_HZ    = 100_000_000;
    localparam integer BAUD      = 1_000_000;
    localparam integer BIT_TICKS = (CLK_HZ + BAUD / 2) / BAUD;

    reg clk = 1'b0;
    always #5 clk = ~clk;               // 100 MHz

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

    //------------------------------------------------------------------
    // UART receiver model
    //------------------------------------------------------------------
    reg       tx_d   = 1'b1;
    reg       rx_act = 1'b0;
    integer   rx_cnt = 0;
    integer   rx_bit = 0;
    reg [7:0] rx_byte = 8'h00;

    integer   n_bytes   = 0;
    integer   n_lines   = 0;
    integer   led_toggles = 0;
    reg [8*256-1:0] text = 0;

    always @(posedge clk) begin
        tx_d <= uart_tx;

        if (!rx_act) begin
            if (tx_d && !uart_tx) begin
                rx_act <= 1'b1;
                rx_cnt <= BIT_TICKS + (BIT_TICKS / 2);
                rx_bit <= 0;
            end
        end else if (rx_cnt == 0) begin
            if (rx_bit < 8) begin
                rx_byte[rx_bit] <= uart_tx;
                rx_bit <= rx_bit + 1;
                rx_cnt <= BIT_TICKS - 1;
            end else begin
                rx_act <= 1'b0;
                n_bytes = n_bytes + 1;
                $write("%c", rx_byte);
                if (rx_byte == 8'h0A) begin
                    n_lines = n_lines + 1;
                    if (n_lines >= LINES) begin
                        $display("\n[TB] PASS: firmware printed %0d line(s) after %0d bytes", n_lines, n_bytes);
                        $display("[TB] LED toggles = %0d", led_toggles);
                        $finish;
                    end
                end
            end
        end else begin
            rx_cnt <= rx_cnt - 1;
        end
    end

    always @(posedge led_run) led_toggles = led_toggles + 1;

    //------------------------------------------------------------------
    // Watchdog
    //------------------------------------------------------------------
    initial begin
        $display("[TB] starting MyXTRV32 simulation (expect %0d line(s))", LINES);
        #20_000_000;                       // 20 ms
        $display("\n[TB] FAIL: timeout, %0d bytes / %0d line(s) received", n_bytes, n_lines);
        $fatal(1);
    end

endmodule

`default_nettype wire
