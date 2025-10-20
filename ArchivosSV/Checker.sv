`include "checker_pkg.sv"
import checker_pkg::*;

// Se asume que ya están declaradas/visibles tus clases:
/// class MD_Rx_Sample#(int ALGN_DATA_WIDTH = 32); endclass
/// class MD_Tx_Sample#(int ALGN_DATA_WIDTH = 32); endclass
/// class MD_pack2#(int ALGN_DATA_WIDTH = 32); endclass

class Checker #(int W = ALGN_DATA_WIDTH);

  // Mailbox desde el monitor
  mailbox mcMD_mailbox;

  // Config del DUT que define cómo fragmenta/agrupa
  int unsigned CTRL_SIZE; // en bytes, p.ej 1,2,4
  // (si quisieras soportar ctrl_offset inicial, agrégalo; en el golden fijamos offset_out=0)

  // Métricas
  int unsigned n_checked, n_pass, n_fail;

  // ---- helper: clase RX -> struct simple
  function automatic md_rx_s rx_class_to_s(const ref MD_Rx_Sample#(W) c);
    md_rx_s s;
    s.data   = c.data_in;
    s.offset = c.offset;
    s.size   = c.size;
    return s;
  endfunction

  // ---- Construye el "golden" para UN paquete (primera salida emitible)
  function automatic bit build_expected_one(
      const ref MD_pack2 #(W) pkt,
      output md_tx_s exp_one
  );
    byte       byte_stream[$];
    md_rx_s    rx_s;

    // 1) Aplanar todas las entradas válidas -> bytes (en orden de llegada)
    foreach (pkt.data_in[i]) begin
      rx_s = rx_class_to_s(pkt.data_in[i]);
      append_valid_window_bytes(rx_s, byte_stream);
    end

    // 2) Emitir SOLO la primera salida posible de tamaño CTRL_SIZE
    return emit_one_word_from_bytes(byte_stream, CTRL_SIZE, exp_one);
  endfunction

  // ---- Comparación 1:1 contra lo observado en el paquete
  function automatic bit compare_one(
      input md_tx_s exp,
      input logic [W-1:0]                  got_data,
      input logic [ALGN_SIZE_WIDTH-1:0]    got_size,
      input logic [ALGN_OFFSET_WIDTH-1:0]  got_offset
  );
    bit ok = 1;
    if (exp.data_out    !== got_data)   ok = 0;
    if (exp.ctrl_size   !== got_size)   ok = 0;
    if (exp.ctrl_offset !== got_offset) ok = 0;

    if (!ok) begin
      $error("[CHK] MISMATCH " | "exp_data=%h got_data=%h | "| "exp_size=%0d got_size=%0d | " | "exp_size=%0d got_size=%0d | " | "exp_off=%0d got_off=%0d", exp.data_out, got_data, exp.ctrl_size, got_size, exp.ctrl_offset, got_offset);
    end
    return ok;
  endfunction

  // ---- Hilo principal del checker
  task run();
    MD_pack2#(W) pkt;
    md_tx_s exp;
    bit have;
    logic [W-1:0] got_d = pkt.data_out;
    logic [ALGN_SIZE_WIDTH-1:0] got_sz = pkt.size_out;
    logic [ALGN_OFFSET_WIDTH-1:0] got_off = pkt.offset_out;

    forever begin
      mcMD_mailbox.get(pkt); // bloqueante
      n_checked++;
      have = build_expected_one(pkt, exp);

      // Convención: si no hay suficientes bytes para formar una salida,
      // esperamos que el DUT NO haya emitido dato (o emita 0,0,0 según tu monitor).
      got_d   = pkt.data_out;
      got_sz  = pkt.size_out;
      got_off = pkt.offset_out;

      if (!have) begin
        md_tx_s null_exp = '{data_out:'0, ctrl_offset:'0, ctrl_size:'0};
        if (compare_one(null_exp, got_d, got_sz, got_off)) begin
          n_pass++;
          $display("[CHK] #%0d OK (sin salida esperada -> nula)", n_checked);
        end else begin
          n_fail++;
          $display("[CHK] #%0d FAIL (DUT emitió pero golden no tenía suficiente bytes)", n_checked);
        end
        continue;
      end

      // Para salidas válidas, el golden fija offset_out=0 y size_out=CTRL_SIZE
      if (compare_one(exp, got_d, got_sz, got_off)) begin
        n_pass++;
        $display("[CHK] #%0d OK (size=%0d)", n_checked, CTRL_SIZE);
      end else begin
        n_fail++;
        $display("[CHK] #%0d FAIL (size=%0d)", n_checked, CTRL_SIZE);
      end
    end
  endtask

  function void report();
    $display("[CHK] Resumen: checked=%0d pass=%0d fail=%0d", n_checked, n_pass, n_fail);
  endfunction

endclass
