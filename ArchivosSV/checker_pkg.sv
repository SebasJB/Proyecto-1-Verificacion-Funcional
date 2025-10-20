package checker_pkg;

  parameter int ALGN_DATA_WIDTH = 32;
  localparam int BYTES_W        = (ALGN_DATA_WIDTH/8);
  localparam int ALGN_OFFSET_WIDTH = (ALGN_DATA_WIDTH<=8) ? 1 : $clog2(BYTES_W);
  localparam int ALGN_SIZE_WIDTH   = $clog2(BYTES_W) + 1;

  typedef struct packed {
    logic [ALGN_DATA_WIDTH-1:0] data_out;
    logic [ALGN_OFFSET_WIDTH-1:0] ctrl_offset; // siempre 0 en golden
    logic [ALGN_SIZE_WIDTH-1:0]   ctrl_size;   // = CFG_CTRL_SIZE
  } md_tx_s;

  typedef struct packed {
    logic [ALGN_DATA_WIDTH-1:0] data;
    logic [ALGN_OFFSET_WIDTH-1:0] offset; // bytes
    logic [ALGN_SIZE_WIDTH-1:0]   size;   // bytes
  } md_rx_s;

  // ---------- Reglas de validez (las que diste) ----------
  function automatic bit is_align_valid(
      input logic [ALGN_OFFSET_WIDTH-1:0] offset_b,
      input logic [ALGN_SIZE_WIDTH-1:0]   size_b
  );
    if (size_b == 0 || size_b > BYTES_W[ALGN_SIZE_WIDTH-1:0]) return 1'b0;
    if (offset_b >= BYTES_W[ALGN_OFFSET_WIDTH-1:0])           return 1'b0;
    return (((BYTES_W + int'(offset_b)) % int'(size_b)) == 0);
  endfunction

  // ---------- Extraer ventana de bytes válido -> cola de bytes ----------
  function automatic void append_valid_window_bytes(
      input  md_rx_s in_s,
      inout  byte    byte_stream[$]   // se va llenando con bytes válidos
  );
    int unsigned o;
    int unsigned s;
    if (!is_align_valid(in_s.offset, in_s.size)) return; // descarta inválidas
    o = in_s.offset;
    s = in_s.size;
    for (int i = 0; i < s; i++) begin
      byte b = in_s.data[8*(o+i) +: 8]; // byte 0 en LSB
      byte_stream.push_back(b);
    end
  endfunction

  // ---------- Tomar N bytes (si hay) y construir un md_tx_s ----------
  function automatic bit emit_one_word_from_bytes(
      inout  byte byte_stream[$],                    // entrada/salida
      input  int  ctrl_size_bytes,                   // CFG_CTRL_SIZE (1..BYTES_W)
      output md_tx_s out_one
  );
    out_one = '{data_out:'0, ctrl_offset:'0, ctrl_size:logic'(ctrl_size_bytes)};
    if (ctrl_size_bytes <= 0 || ctrl_size_bytes > BYTES_W) return 1'b0;
    if (byte_stream.size() < ctrl_size_bytes)               return 1'b0;

    // Empaquetar los primeros ctrl_size_bytes en LSBs
    for (int i = 0; i < ctrl_size_bytes; i++) begin
      out_one.data_out[8*i +: 8] = byte_stream[i];
    end
    // Consumirlos del stream
    for (int i = 0; i < ctrl_size_bytes; i++) void'(byte_stream.pop_front());

    return 1'b1;
  endfunction

endpackage
