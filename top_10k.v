`timescale 1ns/1ps
module top (
    input  wire       sys_clk,         // 100MHz 晶振 (球号见 XDC 注释, 唯一待填项)
    input  wire       ext_pulse10k,    // IO0  N14  外部10kHz脉冲(可选)
    input  wire       sin_in,          // IO1  M14
    input  wire       cos_in,          // IO2  C4
    input  wire       sin_cos_select,  // IO3  B13  1=内部仿真
    output wire       uart_tx,         // DIN  B12 -> ESP32 GPIO27
    input  wire       cts              // CCLK A8  <- ESP32 GPIO17(RTS)
);
    parameter CLK_FREQ = 100_000_000;
    parameter BAUD     = 921_600;
    parameter signed [15:0] DATA_ADD = 16'sd1, DATA_SUB = 16'sd1;

    reg [3:0] rst_cnt=0; wire rst=~(&rst_cnt);
    always@(posedge sys_clk) if(rst) rst_cnt<=rst_cnt+1;

    // ---- CTS 边沿武装: 必须见到 RTS 低->高 跳变才允许发送 (消除配置完成瞬间双输出对撞) ----
    reg cts_d1=0, cts_d2=0, armed=0;
    always@(posedge sys_clk) if(rst){cts_d1<=0;cts_d2<=0;armed<=0;}
    else begin cts_d1<=cts; cts_d2<=cts_d1; if(cts_d1&&!cts_d2) armed<=1; end
    wire cts_ok = armed & cts_d1;

    // ---- 10kHz 脉冲: 外部优先, 1ms 无外部则切内部 ----
    wire ext_e; edge_det ed_ext(.clk(sys_clk),.rst(rst),.level(ext_pulse10k),.rise(ext_e),.fall());
    reg [23:0] tmo=0; reg use_ext=0;
    always@(posedge sys_clk) if(rst){tmo<=0;use_ext<=0;}
    else if(ext_e){tmo<=0;use_ext<=1;}
    else if(tmo<100_000) tmo<=tmo+1; else use_ext<=0;
    reg [15:0] icnt=0; reg ipulse=0;
    always@(posedge sys_clk) if(rst){icnt<=0;ipulse<=0;}
    else if(icnt==CLK_FREQ/10_000-1){icnt<=0;ipulse<=1;} else {icnt<=icnt+1;ipulse<=0;}
    wire pulse10k = use_ext ? ext_e : ipulse;

    // ---- 信号源 + 仿真正交方波 1kHz ----
    wire sim_s, sim_c; sim_gen #(.CLK_FREQ(CLK_FREQ)) sg(.clk(sys_clk),.rst(rst),.out_sin(sim_s),.out_cos(sim_c));
    wire raw_s = sin_cos_select ? sim_s : sin_in;
    wire raw_c = sin_cos_select ? sim_c : cos_in;

    // ---- 滤波10周期 -> 延迟99999 -> 双边沿 ----
    wire f_s,f_c,d_s,d_c;
    filter10 fl_s(.clk(sys_clk),.rst(rst),.raw(raw_s),.out(f_s));
    filter10 fl_c(.clk(sys_clk),.rst(rst),.raw(raw_c),.out(f_c));
    delay_line #(.DEPTH(100000),.DELAY(99999)) dl_s(.clk(sys_clk),.rst(rst),.din(f_s),.dout(d_s));
    delay_line #(.DEPTH(100000),.DELAY(99999)) dl_c(.clk(sys_clk),.rst(rst),.din(f_c),.dout(d_c));
    wire s_rise,s_fall,c_rise,c_fall;
    edge_det ed_s(.clk(sys_clk),.rst(rst),.level(d_s),.rise(s_rise),.fall(s_fall));
    edge_det ed_c(.clk(sys_clk),.rst(rst),.level(d_c),.rise(c_rise),.fall(c_fall));

    // ---- solid_flitter 16bit, 启动只加不减 ----
    reg seen=0; always@(posedge sys_clk) if(rst) seen<=0; else if(pulse10k) seen<=1;
    wire signed [15:0] dint_s, dint_c;
    solid_flitter sf_s(.clk(sys_clk),.rst(rst),.rise(s_rise),.fall(s_fall),.first(seen),.dout(dint_s));
    solid_flitter sf_c(.clk(sys_clk),.rst(rst),.rise(c_rise),.fall(c_fall),.first(seen),.dout(dint_c));

    // ---- resol_count 33bit + 10kHz 锁存 ----
    reg signed [32:0] sum_s=0, sum_c=0; reg [31:0] fb_s=0, fb_c=0;
    always@(posedge sys_clk) if(rst){sum_s<=0;sum_c<=0;}
    else if(pulse10k){fb_s<=sum_s[31:0];fb_c<=sum_c[31:0];sum_s<=0;sum_c<=0;}
    else begin
        if(s_rise||s_fall) sum_s<=sum_s+dint_s;
        if(c_rise||c_fall) sum_c<=sum_c+dint_c;
    end
    wire signed [31:0] diff = fb_s - fb_c;
    wire signed [31:0] x_in = diff[31] ? -diff : diff;

    // ---- 10kHz IIR 低通 (Q54, 10kHz 等效系数) ----
    wire signed [31:0] y_filt; wire f_valid;
    iir_df2t iir_inst(.clk(sys_clk),.rst(rst),.in_valid(pulse10k),.x_in(x_in),
                      .out_valid(f_valid),.y_out(y_filt));

    // ---- 序列号 + 帧FIFO + UART ----
    reg [15:0] seq=0; always@(posedge sys_clk) if(rst) seq<=0; else if(f_valid) seq<=seq+1;
    wire full, empty; wire [47:0] rd_data; wire rd_valid; reg rd_en=0;
    frame_fifo #(.DEPTH(2048)) ff(.clk(sys_clk),.rst(rst),
        .wr_en(f_valid), .wr_data({seq, y_filt[31:0]}),
        .rd_en(rd_en), .rd_valid(rd_valid), .rd_data(rd_data), .full(full), .empty(empty));
    uart_tx6 #(.CLK_FREQ(CLK_FREQ),.BAUD(BAUD)) ut(
        .clk(sys_clk),.rst(rst),.cts_ok(cts_ok),.empty(empty),
        .rd_en(rd_en),.rd_valid(rd_valid),.rd_data(rd_data),.tx(uart_tx));
endmodule

// ================= 子模块 =================
module filter10(input clk,rst,raw,output reg out);
    reg [9:0] sr=0;
    always@(posedge clk) if(rst){sr<=0;out<=0;}
    else begin sr<={sr[8:0],raw};
        if(sr==10'h3FF) out<=1; else if(sr==10'h000) out<=0; end
endmodule
module edge_det(input clk,rst,level,output reg rise,output reg fall);
    reg d=0;
    always@(posedge clk) if(rst){d<=0;rise<=0;fall<=0;}
    else begin d<=level; rise<=level&~d; fall<=~level&d; end
endmodule
module sim_gen #(parameter CLK_FREQ=100_000_000)(input clk,rst,output reg out_sin,output reg out_cos);
    localparam P=CLK_FREQ/1000; reg [16:0] c=0;
    always@(posedge clk) if(rst){c<=0;out_sin<=0;out_cos<=0;}
    else begin if(c==P-1)c<=0;else c<=c+1;
        out_sin<=(c<P/2); out_cos<=(c>=P/4 && c<P*3/4); end
endmodule
module delay_line #(parameter DEPTH=100000,DELAY=99999)(input clk,rst,din,output reg dout);
    (* ram_style="block" *) reg [0:0] mem [0:DEPTH-1];
    reg [16:0] wp=0, rp=DELAY;
    always@(posedge clk) if(rst){wp<=0;rp<=DELAY;dout<=0;}
    else begin mem[wp]<=din; dout<=mem[rp];
        wp<=(wp==DEPTH-1)?0:wp+1; rp<=(rp==DEPTH-1)?0:rp+1; end
endmodule
module solid_flitter(input clk,rst,rise,fall,first,output reg signed[15:0] dout);
    parameter signed[15:0] ADD=16'sd1,SUB=16'sd1;
    always@(posedge clk) if(rst) dout<=0;
    else if(rise) dout<=dout+ADD;
    else if(fall&&first) dout<=dout-SUB;
endmodule
module frame_fifo #(parameter DEPTH=2048)(
    input clk,rst, input wr_en, input [47:0] wr_data,
    input rd_en, output reg rd_valid, output reg [47:0] rd_data,
    output wire full, output wire empty);
    (* ram_style="block" *) reg [47:0] mem [0:DEPTH-1];
    reg [11:0] wp=0, rp=0; reg [12:0] cnt=0;
    assign empty=(cnt==0); assign full=(cnt==DEPTH);
    always@(posedge clk) begin
        if(rst){wp<=0;rp<=0;cnt<=0;rd_valid<=0;}
        else begin
            rd_valid<=0;
            if(wr_en&&!full) begin mem[wp]<=wr_data; wp<=wp+1; end
            if(rd_en&&!empty) begin rd_data<=mem[rp]; rp<=rp+1; rd_valid<=1; end
            cnt<=cnt+(wr_en&&!full?1:0)-(rd_en&&!empty?1:0);
        end
    end
endmodule
module uart_tx6 #(parameter CLK_FREQ=100_000_000,BAUD=921_600)(
    input clk,rst,cts_ok,empty, output reg rd_en, input rd_valid,
    input [47:0] rd_data, output reg tx);
    localparam CB=CLK_FREQ/BAUD;
    reg [1:0] st=0; reg [59:0] stream; reg [6:0] idx=0; reg [15:0] bc=0;
    integer i;
    always@(posedge clk) begin
        if(rst){st<=0;tx<=1;rd_en<=0;idx<=0;bc<=0;}
        else case(st)
            0: begin tx<=1; rd_en<=0;
                 if(!empty&&cts_ok) begin rd_en<=1; st<=1; end end
            1: begin rd_en<=0;
                 if(rd_valid) begin
                    for(i=0;i<6;i=i+1) begin
                        stream[i*10]<=1'b0;
                        stream[i*10+1]<=rd_data[i*8+0]; stream[i*10+2]<=rd_data[i*8+1];
                        stream[i*10+3]<=rd_data[i*8+2]; stream[i*10+4]<=rd_data[i*8+3];
                        stream[i*10+5]<=rd_data[i*8+4]; stream[i*10+6]<=rd_data[i*8+5];
                        stream[i*10+7]<=rd_data[i*8+6]; stream[i*10+8]<=rd_data[i*8+7];
                        stream[i*10+9]<=1'b1;
                    end
                    idx<=0; bc<=0; st<=2; end
                 else if(!cts_ok) st<=0; end
            2: begin tx<=stream[idx];
                 if(bc==CB-1) begin bc<=0; if(idx==59) st<=0; else idx<=idx+1; end
                 else bc<=bc+1; end
        endcase
    end
endmodule