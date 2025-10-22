`include "checker_pkg.sv"
import checker_pkg::*;

class Checker #(int W = ALGN_DATA_WIDTH);

  // Mailbox desde el monitor
  mailbox mcMD_mailbox;

  // Config del DUT que define cómo fragmenta/agrupa
  int unsigned CTRL_SIZE; // en bytes, p.ej 1,2,4
  // (si quisieras soportar ctrl_offset inicial, agrégalo; en el golden fijamos offset_out=0)

  // Métricas
  int unsigned n_checked, n_pass, n_fail;

  // ---- helper: clase RX -> struct simple
  /*
  function automatic MD_Rx_Sample rx_class_to_s(const ref MD_Rx_Sample#(W) c);
    MD_Rx_Sample s;
    s.data   = c.data_in;
    s.offset = c.offset;
    s.size   = c.size;
    return s;
  endfunction
  */ 
  // ---- Construye el "golden" para UN paquete (primera salida emitible)
  function automatic bit build_expected_one(
      const ref MD_pack2 #(W) pkt,
      output MD_Tx_Sample exp_one
  );
    byte byte_stream[$];
    MD_Rx_Sample rx_s;
    int need;
    int offset;
    

    // 1) Aplanar entradas válidas del paquete a BYTES (orden de llegada)
    foreach (pkt.data_in[i]) begin
    rx_s = new();
    rx_s.data   = pkt.data_in[i].data_in;
    rx_s.offset = pkt.data_in[i].offset;
    rx_s.size   = pkt.data_in[i].size;
    append_valid_window_bytes(rx_s, byte_stream);
  end

  // 2) Tamaño requerido = el que mostró el DUT (pkt.size_out)
  need = pkt.data_out[0].ctrl_size;

  // DEBUG: imprimir flujo de bytes disponible
  $write("[CHK] byte_stream(size=%0d) = [", byte_stream.size());
  for (int k=0; k<byte_stream.size(); k++) $write("%02x%s", byte_stream[k], (k+1==byte_stream.size())? "": " ");
  $write("]\n");

  // 3) Armar UNA salida si hay bytes suficientes
  return emit_one_word_from_bytes(byte_stream, need, exp_one);
  endfunction

  // ---- Comparación 1:1 contra lo observado en el paquete
  function automatic bit compare_one(
      input MD_Tx_Sample exp,
      input MD_Tx_Sample got_data
  );
    bit ok = 1;
    if (exp.data_out != got_data.data_out) ok = 0;
    if (exp.ctrl_size != got_data.ctrl_size) ok = 0;
    if (exp.ctrl_offset != got_data.ctrl_offset) ok = 0;

    if (!ok) begin
      $error("[CHK] MISMATCH " | "exp_data=%h got_data=%h | "| "exp_size=%0d got_size=%0d | " | "exp_size=%0d got_size=%0d | " | "exp_off=%0d got_off=%0d", exp.data_out, got_data.data_out, exp.ctrl_size, got_data.ctrl_size, exp.ctrl_offset, got_data.ctrl_offset);
    end
    return ok;
  endfunction

  // ---- Hilo principal del checker
  task run();
    MD_pack2 #(W) pkt;
    MD_Tx_Sample #(W) exp;
    bit have;
    MD_Tx_Sample #(W) got_d;
    logic [ALGN_SIZE_WIDTH-1:0] got_sz;
    logic [ALGN_OFFSET_WIDTH-1:0] got_off;

    forever begin
      mcMD_mailbox.get(pkt);
      $display("[CHK] pkt=%p", pkt);
      got_d = new();
      $display("[CHK] Procesando paquete MD recibido en checker: %0d", pkt.data_in.size());
      n_checked++;
      have = build_expected_one(pkt, exp);

      // Convención: si no hay suficientes bytes para formar una salida,
      // esperamos que el DUT NO haya emitido dato (o emita 0,0,0 según tu monitor).
      
      got_d = pkt.data_out[0];
      got_sz  = got_d.ctrl_size;
      CTRL_SIZE = got_sz;
      got_off = got_d.ctrl_offset;

      if (!have) begin
        md_tx_s null_exp = '{data_out:'0, ctrl_offset:'0, ctrl_size:'0};
        if (compare_one(null_exp, got_d)) begin
          n_pass++;
          $display("[CHK] #%0d OK (sin salida esperada -> nula)", n_checked);
        end else begin
          n_fail++;
          $display("[CHK] #%0d FAIL (DUT emitió pero golden no tenía suficiente bytes)", n_checked);
        end
        continue;
      end

      // Para salidas válidas, el golden fija offset_out=0 y size_out=CTRL_SIZE
      if (compare_one(exp, got_d)) begin
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
