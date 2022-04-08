
//--------------------------------------------------------------------------------------------------------
// Module  : sd_reader
// Type    : synthesizable, IP's top
// Standard: SystemVerilog 2005 (IEEE1800-2005)
// Function: A SD-host to initialize SDcard and read sector
// Compatibility: CardType : SDv1.1 , SDv2  or SDHCv2
//--------------------------------------------------------------------------------------------------------

module sd_reader # (
    parameter [2:0] CLK_DIV = 3'd1      // when clk =   0~ 25MHz , set CLK_DIV = 3'd0,
                                        // when clk =  25~ 50MHz , set CLK_DIV = 3'd1,
                                        // when clk =  50~100MHz , set CLK_DIV = 3'd2,
                                        // when clk = 100~200MHz , set CLK_DIV = 3'd3,
                                        // ......
) (
    // rstn active-low, 1:working, 0:reset
    input  wire         rstn,
    // clock
    input  wire         clk,
    // SDcard signals (connect to SDcard), this design do not use sddat1~sddat3.
    output wire         sdclk,
    inout               sdcmd,
    input  wire         sddat0,
    // show card status
    output wire [ 1:0]  card_type,
    output wire [ 3:0]  card_stat,
    // user read sector command interface (sync with clk)
    input  wire         rstart,
    input  wire [31:0]  rsector,
    output wire         rbusy,
    output wire         rdone,
    // sector data output interface (sync with clk)
    output reg          outen,
    output reg  [ 8:0]  outaddr,  // outaddr from 0 to 511, because the sector size is 512
    output reg  [ 7:0]  outbyte
);

localparam SIMULATE = 0;

initial {outen, outaddr, outbyte} = '0;

localparam [15:0] FASTCLKDIV = 16'd1 << CLK_DIV ;
localparam [15:0] SLOWCLKDIV = FASTCLKDIV * (SIMULATE ? 16'd2 : 16'd35);

reg        start  = 1'b0;
reg [15:0] precnt = '0;
reg [ 5:0] cmd    = '0;
reg [31:0] arg    = '0;
reg [15:0] clkdiv = SLOWCLKDIV;
reg [31:0] rsectoraddr='0;
wire       busy, done, timeout, syntaxe;
wire[31:0] resparg;

reg [15:0] rca = '0;
enum logic [2:0] {UNKNOWN, SDv1, SDv2, SDHCv2, SDv1Maybe} cardtype = UNKNOWN;
enum logic [3:0] {CMD0, CMD8, CMD55_41, ACMD41, CMD2, CMD3, CMD7, CMD16, CMD17, READING, READING2} card_state = CMD0;

assign     rbusy  = card_state!=CMD17;
reg        sdclkl = 1'b0;
enum logic [2:0] {RWAIT, RDURING, RTAIL, RDONE, RTIMEOUT} sddat_state = RWAIT;
reg [31:0] ridx   = 0;
assign     rdone  = card_state == READING2 && sddat_state==RDONE;

assign card_type = cardtype[1:0];
assign card_stat = card_state[3:0];


sdcmd_ctrl sdcmd_ctrl_i (
    .rstn        ( rstn         ),
    .clk         ( clk          ),
    .sdclk       ( sdclk        ),
    .sdcmd       ( sdcmd        ),
    .clkdiv      ( clkdiv       ),
    .start       ( start        ),
    .precnt      ( precnt       ),
    .cmd         ( cmd          ),
    .arg         ( arg          ),
    .busy        ( busy         ),
    .done        ( done         ),
    .timeout     ( timeout      ),
    .syntaxe     ( syntaxe      ),
    .resparg     ( resparg      )
);


task automatic set_cmd(input _start, input[15:0] _precnt='0, input[5:0] _cmd='0, input[31:0] _arg='0 );
    start  <= _start;
    precnt <= _precnt;
    cmd    <= _cmd;
    arg    <= _arg;
endtask


always @ (posedge clk or negedge rstn)
    if(~rstn) begin
        set_cmd(0);
        clkdiv   <= SLOWCLKDIV;
        rsectoraddr <= '0;
        rca      <= '0;
        cardtype <= UNKNOWN;
        card_state <= CMD0;
    end else begin
        set_cmd(0);
        if(card_state == READING2) begin
            if(sddat_state==RTIMEOUT) begin
                set_cmd(1, 32, 17, rsectoraddr);
                card_state <= READING;
            end else if(sddat_state==RDONE)
                card_state <= CMD17;
        end else if(~busy) begin
            case(card_state)
                CMD0    :   set_cmd(1, (SIMULATE?128:64000) ,  0,  'h00000000);
                CMD8    :   set_cmd(1,                   24 ,  8,  'h000001aa);
                CMD55_41:   set_cmd(1,                   24 , 55,  'h00000000);
                ACMD41  :   set_cmd(1,                   24 , 41,  'hc0100000);
                CMD2    :   set_cmd(1,                   24 ,  2,  'h00000000);
                CMD3    :   set_cmd(1,                   24 ,  3,  'h00000000);
                CMD7    :   set_cmd(1,                   24 ,  7, {rca,16'h0});
                CMD16   :   set_cmd(1, (SIMULATE?128:64000) , 16,  'h00000200);
                CMD17   :   if(rstart) begin
                                set_cmd(1, 32, 17, (cardtype==SDHCv2) ? rsector : (rsector<<9) );
                                rsectoraddr <= (cardtype==SDHCv2) ? rsector : (rsector<<9);
                                card_state <= READING;
                            end
            endcase
        end else if(done) begin
            case(card_state)
                CMD0    :   card_state <= CMD8;
                CMD8    :   if(timeout) begin
                                cardtype <= SDv1Maybe;
                                card_state  <= CMD55_41;
                            end else if(~syntaxe && resparg[7:0]==8'haa)
                                card_state  <= CMD55_41;
                CMD55_41:   if(~timeout && ~syntaxe)
                                card_state <= ACMD41;
                ACMD41  :   if(~timeout && ~syntaxe && resparg[31]) begin
                                cardtype <= (cardtype==SDv1Maybe) ? SDv1 : (resparg[30] ? SDHCv2 : SDv2);
                                card_state  <= CMD2;
                            end else
                                card_state  <= CMD55_41;
                CMD2    :   if(~timeout && ~syntaxe)
                                card_state <= CMD3;
                CMD3    :   if(~timeout && ~syntaxe) begin
                                rca <= resparg[31:16];
                                card_state <= CMD7;
                            end
                CMD7    :   if(~timeout && ~syntaxe) begin
                                clkdiv  <= FASTCLKDIV;
                                card_state <= CMD16;
                            end
                CMD16   :   if(~timeout && ~syntaxe)
                                card_state <= CMD17;
                READING :   if(~timeout && ~syntaxe)
                                card_state <= READING2;
                            else
                                set_cmd(1, 128, 17, rsectoraddr);
            endcase
        end
    end


always @ (posedge clk or negedge rstn)
    if(~rstn) begin
        outen  <= 1'b0;
        outaddr<= '0;
        outbyte<='0;
        sdclkl <= 1'b0;
        sddat_state <= RWAIT;
        ridx   <= 0;
    end else begin
        outen  <= 1'b0;
        outaddr<= '0;
        sdclkl <= sdclk;
        if(card_state!=READING && card_state!=READING2) begin
            sddat_state <= RWAIT;
            ridx   <= 0;
        end else if(~sdclkl & sdclk)
            case(sddat_state)
                RWAIT   :
                    if(~sddat0) begin
                        sddat_state <= RDURING;
                        ridx   <= 0;
                    end else begin
                        if(ridx > 1000000)      // according to SD datasheet, 1ms is enough to wait for DAT result, here, we set timeout to 1000000 clock cycles = 80ms (when SDCLK=12.5MHz)
                            sddat_state <= RTIMEOUT;
                        ridx   <= ridx + 1;
                    end
                RDURING :
                    begin
                        outbyte[3'd7 - ridx[2:0]] <= sddat0;
                        if(ridx[2:0] == 3'd7) begin
                            outen  <= 1'b1;
                            outaddr<= ridx[11:3];
                        end
                        if(ridx >= 512*8-1) begin
                            sddat_state <= RTAIL;
                            ridx   <= 0;
                        end else
                            ridx   <= ridx + 1;
                    end
                RTAIL   :
                    begin
                        if(ridx >= 8*8-1)
                            sddat_state <= RDONE;
                        ridx   <= ridx + 1;
                    end
            endcase
    end

endmodule

