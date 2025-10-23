
class Checker #(int ALGN_DATA_WIDTH = 32);

  localparam int BYTES_W        = (ALGN_DATA_WIDTH/8);
  localparam int ALGN_OFFSET_WIDTH = (ALGN_DATA_WIDTH<=8) ? 1 : $clog2(BYTES_W);
  localparam int ALGN_SIZE_WIDTH   = $clog2(BYTES_W) + 1;
  // Mailbox desde el monitor
  mailbox mcMD_mailbox;

  // Config del DUT que define cómo fragmenta/agrupa
  int unsigned CTRL_SIZE; // en bytes, p.ej 1,2,4
  // (si quisieras soportar ctrl_offset inicial, agrégalo; en el golden fijamos offset_out=0)

  // Métricas
  int unsigned n_checked, n_pass, n_fail;
  

  // ---- helper: clase RX -> struct simple
  /*
  function automatic MD_Rx_Sample rx_class_to_s(const ref MD_Rx_Sample#() c);
    MD_Rx_Sample s;
    s.data   = c.data_in;
    s.offset = c.offset;
    s.size   = c.size;
    return s;
  endfunction
  */ 
  // ==========================================================
// concat_one_from_pkt32 : usa un "byte_stream" de 32 bits
// para formar UNA salida esperada desde MD_pack2.
// Devuelve 1 si pudo formarla (hubo >= need bytes), 0 si no.
// ==========================================================
function automatic bit concat_one_from_pkt32 (
  input data_in_q[$],
  ref MD_Tx_Sample #(ALGN_DATA_WIDTH) exp_one,    // salida esperada (clase)
  output int unsigned bytes_avail // bytes metidos en byte_stream
);

    localparam int BYTES_W = (ALGN_DATA_WIDTH/8);
    bit [ALGN_DATA_WIDTH-1:0] byte_stream = '0;
    bit [ALGN_DATA_WIDTH-1:0] expected = '0;
    int unsigned need;
    int unsigned off_out;


    // ---------- 1) Aplanar entradas a byte_stream (LSB-first) ----------
    // Recorre cada muestra de entrada y copia sus 'size' bytes
    // empezando en 'offset' al stream en orden de llegada.
    foreach (data_in_q[i]) begin
      int o = data_in_q[i].offset;
      int s = $unsigned(data_in_q[i].size);


      // Recorta si ya llenamos 4 bytes
      for (int b = 0; (b < s) && (bytes_avail < BYTES_W); b++ ) begin
        byte_stream[8*bytes_avail +: 8] = pkt.data_in[i].data_in[8*(o+b) +: 8];
        bytes_avail++;
      end
      if (bytes_avail == BYTES_W) break; // stream de 32b lleno
    end

    // ---------- 2) Necesidad de salida según el DUT ----------
    need = $unsigned(pkt.data_out[0].ctrl_size);    // en bytes
    off_out  = $unsigned(pkt.data_out[0].ctrl_offset);  // en bytes

    // Debug: mostrar lo que llegó
    $display("[CHK] pkt: TX{size=%0d off=%0d data=%h} RX.samples=%0d  stream_bytes=%0d",
           pkt.size_out, pkt.offset_out, pkt.data_out.data_out, pkt.data_in.size(), bytes_avail);
    $display("[CHK] byte_stream=0x%08h  (bytes: %02x %02x %02x %02x)",
           byte_stream,
           byte_stream[7:0], byte_stream[15:8],
           byte_stream[23:16], byte_stream[31:24]);

    // Validaciones mínimas
    if (need <= 0 || need > BYTES_W || ((BYTES_W + int'(off_out)) % int'(need)) == 0) begin
      $error("[CHK] combinación inválida: need=%0d off=%0d (BYTES_W=%0d)", need, off_out, BYTES_W);
      return '0;
    end
    if (bytes_avail < need) begin
      $error("[CHK] insuficientes bytes en stream: need=%0d have=%0d", need, bytes_avail);
      return '0;
    end

    // ---------- 3) Construir palabra esperada colocando bytes en offset ----------
    for (int j = 0; j < need; j++) begin
      expected[8*(off_out + j) +: 8] = byte_stream[8*j +: 8];
    end

    // ---------- 4) Llenar la clase de salida ----------
    exp_one = new();
    exp_one.data_out = expected;
    exp_one.ctrl_size = pkt.data_out[0].ctrl_size;
    exp_one.ctrl_offset = pkt.data_out[0].ctrl_offset;
  

    $display("[CHK] EXPECTED: data=%h size=%0d off=%0d", exp_one.data_out, exp_one.ctrl_size, exp_one.ctrl_offset);
    return byte_stream;
endfunction


  // ---------- Tomar N bytes (si hay) y construir un md_tx_s ----------
  function automatic void emit_one_word_from_bytes(
      input bit byte_stream[$],  
      input int unsigned ctrl_size_bytes,                  // entrada/salida
      output MD_Tx_Sample #(ALGN_DATA_WIDTH) out_one
  );

    if (ctrl_size_bytes <= 0 || ctrl_size_bytes > BYTES_W) return;
    if (byte_stream.size() < ctrl_size_bytes)               return;

    // Empaquetar los primeros ctrl_size_bytes en LSBs
    for (int i = 0; i < ctrl_size_bytes; i++) begin
      out_one.data_out[8*i +: 8] = byte_stream[8*i +: 8];
      byte_stream[8*i +: 8] = 8'b0; // Consumirlos del stream
    end
  endfunction

  
   function automatic bit is_align_valid(
      input logic [ALGN_OFFSET_WIDTH-1:0] offset_b,
      input logic [ALGN_SIZE_WIDTH-1:0]   size_b
  );
    if (size_b == 0 || size_b > BYTES_W[ALGN_SIZE_WIDTH-1:0]) return 1'b0;
    if (offset_b >= BYTES_W[ALGN_OFFSET_WIDTH-1:0])           return 1'b0;
    return (((BYTES_W + int'(offset_b)) % int'(size_b)) == 0);
  endfunction
  /*
  // ---------- Extraer ventana de bytes válido -> cola de bytes ----------
  function automatic void append_valid_window_bytes(
      input MD_Rx_Sample in_s,
      ref bit byte_stream[$]   // se va llenando con bytes válidos
  );
    logic [ALGN_OFFSET_WIDTH-1:0] o;
    logic [ALGN_SIZE_WIDTH-1:0] s;
    if (!is_align_valid(in_s.offset, in_s.size)) begin
      $display("[CHK] La entrada es inválida, size: %0d, offset: %0d", in_s.size, in_s.offset)
      return; // descarta inválidas
    end
    o = in_s.offset;
    s = in_s.size;
    for (int i = 0; i < s; i++) begin
      bit b = in_s.data_in[i]; // byte 0 en LSB
      byte_stream.push_back(b);
      in_s.data_in.delete;
    end
  endfunction
  */

  // ---- Construye el "golden" para UN paquete (primera salida emitible)
  function automatic bit build_expected_one(
      ref MD_pack2 #(ALGN_DATA_WIDTH) pkt,
      output MD_Tx_Sample exp_one
  );
    MD_Rx_Sample #(ALGN_DATA_WIDTH) data_in_q[$];
    bit [ALGN_DATA_WIDTH-1:0] byte_stream;
    MD_Tx_Sample #(ALGN_DATA_WIDTH) tx_s;
    int unsigned tx_bytes_count;
    int unsigned avail;
    bit valid;
    tx_bytes_count = 0;
     
    
    if (pkt.data_in[0].size < pkt.data_out[0].size) begin
      tx_s = new();
      byte_stream = '0;
      foreach (pkt.data_in[i]) begin
        rx_s = new();
        data_in_q[i] = pkt.data_in[i].data_in;
        rx_s.offset = pkt.data_in[i].offset;
        rx_s.size   = pkt.data_in[i].size;
        valid = is_align_valid(rx_s.offset, rx_s.size);
        if (valid) begin
          byte_stream = concat_one_from_pkt32(pkt, tx_s, avail);
        end
      end
      tx_bytes_count = $unsigned(tx_s.ctrl_size);
      emit_one_word_from_bytes(byte_stream, tx_bytes_count, exp_one);
    end
    else begin
      rx_s = new(); 
      foreach (pkt.data_out[i]) begin
      tx_s = new();
      tx_s.data_out = pkt.data_out[i].data_out;
      tx_s.ctrl_offset = pkt.data_out[i].ctrl_offset;
      tx_s.ctrl_size = pkt.data_in[i].ctrl_size;
      valid = is_align_valid(tx_s.offset, tx_s.size);
      if (valid) begin
        tx_bytes_count = $unsigned(tx_s.ctrl_size);
        emit_one_word_from_bytes(byte_stream, tx_bytes_count, exp_one);
      end
    end
    
  end

  // DEBUG: imprimir flujo de bytes disponible
  $write("[CHK] byte_stream(size=%0d) = [", byte_stream.size());
  for (int k=0; k<byte_stream.size(); k++) $write("%02x%s", byte_stream[k], (k+1==byte_stream.size())? "": " ");
  $write("]\n");

  // 3) Armar UNA salida si hay bytes suficientes
  return 1'b1
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
    MD_pack2 #(ALGN_DATA_WIDTH) pkt;
    MD_Tx_Sample #(ALGN_DATA_WIDTH) exp;
    bit have;
    MD_Tx_Sample #(ALGN_DATA_WIDTH) got_d;
    MD_Tx_Sample #(ALGN_DATA_WIDTH) out_q;
    logic [ALGN_SIZE_WIDTH-1:0] got_sz;
    logic [ALGN_OFFSET_WIDTH-1:0] got_off;

    forever begin
      mcMD_mailbox.get(pkt);
      $display("[CHK] pkt=%p", pkt);
      out_q = pkt.data_out;
      got_d = new();

      $display("[CHK] Procesando paquete MD recibido en checker: %0d", pkt.data_in.size());
      n_checked++;
      have = build_expected_one(pkt, exp);

      // Convención: si no hay suficientes bytes para formar una salida,
      // esperamos que el DUT NO haya emitido dato (o emita 0,0,0 según tu monitor).
      
      got_d = out_q[0];
      got_sz  = got_d.ctrl_size;
      got_off = got_d.ctrl_offset;

      if (!have) begin
        MD_Tx_Sample #(ALGN_DATA_WIDTH) null_exp = '{data_out:'0, ctrl_offset:'0, ctrl_size:'0};
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
