//============================================================================
//  MyXTRV32 UART transmitter  (8N1, LSB first, no flow control)
//  The baud rate divider is computed at elaboration time.
//============================================================================
`timescale 1ns / 1ps
`default_nettype none

module myxtrv32_uart_tx #(
    parameter integer CLK_HZ = 100_000_000,
    parameter integer BAUD   = 115200
) (
    input  wire       clk,
    input  wire       rst,       // synchronous, active high
    input  wire [7:0] data,
    input  wire       send,      // one cycle pulse, ignored while busy
    output reg        busy,
    output reg        tx         // idle high
);

    localparam integer DIV = (CLK_HZ + (BAUD / 2)) / BAUD;
    localparam [15:0]  DIV_MINUS_1 = DIV - 1;

    localparam       S_IDLE = 1'b0,
                     S_SEND = 1'b1;

    reg        st;
    reg [9:0]  sh;          // {stop, data[7:0], start}
    reg [3:0]  bit_cnt;
    reg [15:0] tick;

    always @(posedge clk) begin
        if (rst) begin
            st      <= S_IDLE;
            sh      <= 10'h3FF;
            bit_cnt <= 4'd0;
            tick    <= 16'd0;
            busy    <= 1'b0;
            tx      <= 1'b1;
        end else begin
            case (st)
                S_IDLE: begin
                    tx      <= 1'b1;
                    tick    <= 16'd0;
                    bit_cnt <= 4'd0;
                    busy    <= 1'b0;
                    if (send) begin
                        sh   <= {1'b1, data, 1'b0};
                        busy <= 1'b1;
                        st   <= S_SEND;
                    end
                end

                S_SEND: begin
                    tx <= sh[0];
                    if (tick == DIV_MINUS_1) begin
                        tick <= 16'd0;
                        if (bit_cnt == 4'd9) begin
                            st      <= S_IDLE;
                            busy    <= 1'b0;
                            tx      <= 1'b1;
                            bit_cnt <= 4'd0;
                        end else begin
                            sh      <= {1'b1, sh[9:1]};
                            bit_cnt <= bit_cnt + 4'd1;
                        end
                    end else begin
                        tick <= tick + 16'd1;
                    end
                end

                default: st <= S_IDLE;
            endcase
        end
    end

endmodule

`default_nettype wire
