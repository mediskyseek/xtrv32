//============================================================================
//  MyXTRV32 64 KiB data RAM  (single port, byte write enables, sync read)
//============================================================================
`timescale 1ns / 1ps
`default_nettype none

module myxtrv32_ram #(
    parameter integer WORDS = 16384         // 32-bit words (16384 = 64 KiB)
) (
    input  wire        clk,
    input  wire [13:0] addr,                // word index
    input  wire [31:0] wdata,
    input  wire [3:0]  wstrb,
    input  wire        we,
    output reg  [31:0] rdata
);

    reg [31:0] mem [0:WORDS-1];

    integer i;
    initial begin
        for (i = 0; i < WORDS; i = i + 1)
            mem[i] = 32'd0;
    end

    always @(posedge clk) begin
        if (we) begin
            if (wstrb[0]) mem[addr][ 7: 0] <= wdata[ 7: 0];
            if (wstrb[1]) mem[addr][15: 8] <= wdata[15: 8];
            if (wstrb[2]) mem[addr][23:16] <= wdata[23:16];
            if (wstrb[3]) mem[addr][31:24] <= wdata[31:24];
        end
        rdata <= mem[addr];
    end

endmodule

`default_nettype wire
