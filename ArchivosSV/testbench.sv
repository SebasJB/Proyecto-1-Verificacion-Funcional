`timescale 1ns/1ps
`include "design.v"
`include "trans_items"
`include "generador.sv"
`include "drivers.sv"
`include "Monitores.sv"
`include "Scoreboard.sv"
`include "environment.sv"
`include "test.sv"
//==============================================================
// Top-level testbench
//==============================================================
module tb_top;

  // --- Parámetros del DUT / TB
  localparam int ALGN_DATA_WIDTH = 32;
  localparam int FIFO_DEPTH = 8;

  // --- Reloj y reset
  logic clk;
  logic reset_n;

  initial clk = 1'b0;
  always  #5 clk = ~clk;     // 100 MHz

  initial begin
    reset_n = 1'b0;
    repeat (5) @(posedge clk);
    reset_n = 1'b1;
  end

  // --- Interfaces virtuales hacia el ambiente
  MD_if #(.ALGN_DATA_WIDTH(ALGN_DATA_WIDTH)) md_if (clk);
  APB_if apb_if (clk);


  // --- DUT
  cfs_aligner #(
    .ALGN_DATA_WIDTH(ALGN_DATA_WIDTH),
    .FIFO_DEPTH     (FIFO_DEPTH)
  ) dut (
    .clk        (clk),
    .reset_n    (reset_n),

    // ------ APB ------
    .paddr      (apb_if.paddr),
    .pwrite     (apb_if.pwrite),
    .psel       (apb_if.psel),
    .penable    (apb_if.penable),
    .pwdata     (apb_if.pwdata),
    .pready     (apb_if.pready),
    .prdata     (apb_if.prdata),
    .pslverr    (apb_if.pslverr),

    // ------ MD RX (entrada al DUT) ------
    .md_rx_valid(md_if.md_rx_valid),
    .md_rx_data (md_if.md_rx_data),
    .md_rx_offset(md_if.md_rx_offset),
    .md_rx_size (md_if.md_rx_size),
    .md_rx_ready(md_if.md_rx_ready),
    .md_rx_err  (md_if.md_rx_err),

    // ------ MD TX (salida del DUT) ------
    .md_tx_valid(md_if.md_tx_valid),
    .md_tx_data (md_if.md_tx_data),
    .md_tx_offset(md_if.md_tx_offset),
    .md_tx_size (md_if.md_tx_size),
    .md_tx_ready(md_if.md_tx_ready),
    .md_tx_err  (md_if.md_tx_err),

    // ------ IRQ ------
    .irq        (apb_if.irq)
  );

  // --- TEST
  test #(.ALGN_DATA_WIDTH(ALGN_DATA_WIDTH)) t0;

  // --- Secuencia de arranque
  initial begin
    // Valores seguros antes del arranque del ambiente (los drivers igual hacen idle)
    apb_if.psel     = 1'b0;
    apb_if.penable  = 1'b0;
    apb_if.pwrite   = 1'b0;
    apb_if.paddr    = '0;
    apb_if.pwdata   = '0;

    md_if.md_rx_valid  = 1'b0;
    md_if.md_rx_data   = '0;
    md_if.md_rx_offset = '0;
    md_if.md_rx_size   = '0;

    // Instanciar y lanzar el test una vez liberado el reset
    t0 = new(md_if, apb_if);
    @(posedge reset_n);
    fork
      t0.run();
    join_none
  end

  // --- Watchdog de seguridad por si algo quedara colgado
  initial begin
    // 200us de tiempo simulado a 10ns de periodo
    #200_000;
    $display("[%0t] [TB] Watchdog timeout. Finalizando.", $time);
    $finish;
  end

endmodule
