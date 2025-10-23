// ====================================================
// APB Monitor (para APB_if)
// - Detecta SETUP:  psel=1 && penable=0
// - Cuenta wait states durante ACCESS: penable=1 hasta pready=1
// - Completa en el ciclo (penable && pready)
// - Publica clones a msAPB_mailbox (scoreboard) y mcAPB_mailbox (checker)
// ====================================================
class APB_Monitor;
  // Interfaz virtual
  virtual APB_if vif; 

  // Mailboxes con los nombres requeridos
  mailbox msAPB_mailbox; // Monitor → scoreboard: APB transactions
  mailbox mcAPB_mailbox; // Monitor → checker: APB transactions
 
  time t_start, t_end;

  task run();
    APB_pack2 tr;
    forever begin
      // Espera fase SETUP
      @(posedge vif.clk iff (vif.psel || vif.penable));
      tr = new();
      t_start = $time;
      tr.dir = (vif.pwrite) ? APB_WRITE : APB_READ;
      tr.addr = vif.paddr;
      tr.wdata = vif.pwdata;
      tr.wait_states = 0;

      // Fase ACCESS: contar wait states hasta completar
      while (!(vif.penable && vif.pready)) begin
        @(posedge vif.clk);
        if (vif.penable && !vif.pready) tr.wait_states++;
      end;
      t_end  = $time;
      tr.apb_t_time = t_end - t_start;
      tr.slverr = vif.pslverr;
      if (tr.dir == APB_READ) tr.rdata = vif.prdata;

      // Publicar a ambos consumidores
      msAPB_mailbox.put(tr.clone());
      //mcAPB_mailbox.put(tr.clone());
    end
  endtask
endclass


// ====================================================
// MD Monitor (para MD_if, lado TX del Aligner)
// - Muestrea *solo* en handshake válido: md_tx_valid && md_tx_ready
// - Captura data/offset/size y md_tx_err
// - Publica clones a msMD_mailbox (scoreboard) y mcMD_mailbox (checker)
// ====================================================
// ----------------------------------------------------
// Monitor de la salida TX del Aligner (MD_if)
// - md_tx_ready SIEMPRE = 1 (acepta todo).
// - Reporta cambios de md_tx_data (MD_EVT_CHANGE) con t_start/t_hold.
// - Reporta handshakes (MD_EVT_HANDSHAKE) cuando (md_tx_valid && md_tx_ready).
// - Publica a msMD_mailbox (scoreboard) y mcMD_mailbox (checker).
// ----------------------------------------------------

class MD_Monitor #(int ALGN_DATA_WIDTH = 32);

  // Interfaz virtual (tu MD_if)
  virtual MD_if #(ALGN_DATA_WIDTH) vif;

  // Mailboxes con los nombres exactos solicitados
  mailbox msMD_mailbox; // Monitor → scoreboard: MD transactions
  mailbox mcMD_mailbox; // Monitor → checker: MD transactions

  // Mutex para proteger acceso a las colas
  semaphore sem_buf = new(1);
  event ev_rx_pushed, ev_tx_pushed;

  localparam int BYTES_W = (ALGN_DATA_WIDTH/8);
  localparam int ALGN_OFFSET_WIDTH = (ALGN_DATA_WIDTH<=8) ? 1 : $clog2(ALGN_DATA_WIDTH/8);
  localparam int ALGN_SIZE_WIDTH   = $clog2(ALGN_DATA_WIDTH/8) + 1;


  MD_Rx_Sample #(ALGN_DATA_WIDTH) data_in_buffer[$]; // buffer de datos recibidos
  MD_Tx_Sample #(ALGN_DATA_WIDTH) data_out_buffer[$]; // buffer de datos enviados


  //Variables de ultimos valores observados rx
  bit [ALGN_DATA_WIDTH-1:0]   last_data_rx; // Último dato observado
  bit [ALGN_OFFSET_WIDTH-1:0] last_offset_rx; // Último offset observado
  bit [ALGN_SIZE_WIDTH-1:0]   last_size_rx; // Último tamaño observado
  bit last_err_rx; // Último error observado

  //Variables de ultimos valores observados tx
  bit [ALGN_DATA_WIDTH-1:0]   last_data_tx; // Último dato observado
  bit [ALGN_OFFSET_WIDTH-1:0] last_offset_tx; // Último offset observado
  bit [ALGN_SIZE_WIDTH-1:0]   last_size_tx; // Último tamaño observado
  bit last_err_tx; // Último error observado

  bit change_rx;
  bit change_tx;
  int unsigned rx_bytes_count;
  int unsigned tx_bytes_count;
  

  task send_transaction(ref MD_pack2 #(ALGN_DATA_WIDTH) trans);
    msMD_mailbox.put(trans.clone());
    mcMD_mailbox.put(trans.clone());
    $display("[MD_MON] Enviado paquete MD al scoreboard/checker: %0d bytes de entrada, %0d bytes de salida", trans.data_in.size(), trans.data_out.size());
  endtask

  task sample_rx_data();
    MD_Rx_Sample #(ALGN_DATA_WIDTH) sample;
    last_data_rx  = '0;
    last_offset_rx= '0;
    last_size_rx  = '0;
    last_err_rx   = '0;
    forever begin
      
      @(posedge vif.clk);
      change_rx = vif.md_rx_valid &&
           (vif.md_rx_data   !== last_data_rx   ||
            vif.md_rx_offset !== last_offset_rx ||
            vif.md_rx_size   !== last_size_rx   ||
            vif.md_rx_err    !== last_err_rx);

      if (change_rx) begin
          // CAPTURA una sola muestra COMPLETA
          
          sample = new();
          sample.data_in = vif.md_rx_data;
          sample.offset  = vif.md_rx_offset;
          sample.size    = vif.md_rx_size;
          sample.err     = vif.md_rx_err;
          sample.t_sample= $time;
          data_in_buffer.push_back(sample);
          -> ev_rx_pushed;
          // actualiza "last" después de capturar
          last_data_rx   = vif.md_rx_data;
          last_offset_rx = vif.md_rx_offset;
          last_size_rx   = vif.md_rx_size;
          last_err_rx    = vif.md_rx_err;
      end
    end
  endtask

  task sample_tx_data();
    MD_Tx_Sample #(ALGN_DATA_WIDTH) sample;
    last_data_tx  = '0;
    last_offset_tx= '0;
    last_size_tx  = '0;
    forever begin
      vif.md_tx_ready = 1'b1;
      @(posedge vif.clk);
      change_tx = vif.md_tx_valid &&
      (vif.md_tx_data   !== last_data_tx  ||
      vif.md_tx_offset !== last_offset_tx ||
      vif.md_tx_size   !== last_size_tx   ||
      vif.md_tx_err    !== last_err_tx);
      if (change_tx) begin
        sample = new();
        sample.data_out = vif.md_tx_data;
        sample.ctrl_offset = vif.md_tx_offset;
        sample.ctrl_size = vif.md_tx_size;
        sample.t_sample = $time;
        data_out_buffer.push_back(sample);
        -> ev_tx_pushed;
        // actualiza "last" después de capturar
        last_data_tx   = vif.md_tx_data;
        last_offset_tx = vif.md_tx_offset;
        last_size_tx   = vif.md_tx_size;
      end
    end
  endtask


  task aligner();
    MD_Tx_Sample #(ALGN_DATA_WIDTH) tx_sample;
    MD_Rx_Sample #(ALGN_DATA_WIDTH) rx_sample;
    MD_pack2 #(ALGN_DATA_WIDTH) tr;
    int unsigned bytes;
    int unsigned i;
    forever begin
      tr = new();
      if (data_in_buffer.size() == 0 ) @ev_rx_pushed;
      rx_sample = data_in_buffer.pop_front();
      if (data_out_buffer.size() == 0 ) @ev_tx_pushed;
      tx_sample = data_out_buffer.pop_front();

      if (rx_sample.size > tx_sample.ctrl_size) begin
        if (rx_sample.err) begin
            tr.data_err[0] = rx_sample;
          end
        else begin
            tr.data_in[0] = rx_sample;
          end 
        i = 0;
        tx_bytes_count = 0;
        bytes = $unsigned(rx_sample.size);
        while(( tx_bytes_count < bytes) || ( i < BYTES_W)) begin
          tr.data_out[i] = tx_sample;
          i++;
          tx_bytes_count += $unsigned(tx_sample.ctrl_size);
          @ev_tx_pushed;
          tx_sample = data_out_buffer.pop_front();          
        end
        @(posedge vif.clk);
        $display("[MD_MON] Enviado paquete MD al checker: RX(size=%0d,data=%h) TX(samples=%0d) Bytes count: %0d", tr.data_in[0].size, tr.data_in[0].data_in, tr.data_out.size(), tx_bytes_count);
        foreach (tr.data_out[i]) begin
          $display("  [TX%0d] data=%h off=%0d size=%0d", i, tr.data_out[i].data_out, tr.data_out[i].ctrl_offset, tr.data_out[i].ctrl_size);
        end
        foreach (tr.data_in[i]) begin
          $display("  [RX%0d] data=%h off=%0d size=%0d", i, tr.data_in[i].data_in, tr.data_in[i].offset, tr.data_in[i].size);
          end
        send_transaction(tr);
        tx_bytes_count = 0;
        i = 0;
      end


      else begin
        tr.data_out[0] = tx_sample;
        i = 0;
        rx_bytes_count = 0;
        bytes = $unsigned(tx_sample.ctrl_size);
        while ((i < bytes)||(rx_bytes_count < BYTES_W)) begin
          if (!rx_sample.err) begin
            rx_bytes_count += $unsigned(rx_sample.size);
            tr.data_in[i] = rx_sample;
            i++;
            @ev_rx_pushed;
            rx_sample = data_in_buffer.pop_front(); 
          end
          else begin
            tr.data_err[i] = rx_sample;
            @ev_rx_pushed;
            rx_sample = data_in_buffer.pop_front(); 
          end
            
        end
        @(posedge vif.clk);
         $display("[MD_MON] Enviado paquete MD al checker: TX(size=%0d,data=%h) RX(samples=%0d) Bytes count: %0d", tr.data_out[0].ctrl_size, tr.data_out[0].data_out, tr.data_in.size(), rx_bytes_count);
         foreach (tr.data_in[i]) begin
          $display("  [RX%0d] data=%h off=%0d size=%0d", i, tr.data_in[i].data_in, tr.data_in[i].offset, tr.data_in[i].size);
          end
          foreach (tr.data_out[i]) begin
          $display("  [TX%0d] data=%h off=%0d size=%0d", i, tr.data_out[i].data_out, tr.data_out[i].ctrl_offset, tr.data_out[i].ctrl_size);
        end
        send_transaction(tr);
        rx_bytes_count = 0;
        i = 0;
      end
    end
  endtask


  task run();
    fork
      sample_rx_data();
      sample_tx_data();
      aligner();
    join_none
  endtask 
endclass 
/*
// ----------------------------------------------------
// MD Monitor (para MD_if)
// - Captura en RX y TX cada vez que cambia VALID o el contenido (data/offset/size/err).
// - Para el CHECKER/Scoreboard arma transacciones donde cada TX consume exactamente
//   ctrl_size bytes de las entradas RX, respetando offset y orden de bytes.
// - Soporta N→1 y 1→N (p. ej. size=4 vs size=1).
// ----------------------------------------------------
class MD_Monitor #(int ALGN_DATA_WIDTH = 32);

  // ===== Interfaz y canalización =====
  virtual MD_if #(ALGN_DATA_WIDTH) vif;

  // Mailboxes requeridos
  mailbox msMD_mailbox; // Monitor → scoreboard
  mailbox mcMD_mailbox; // Monitor → checker

  // Sincronización
  semaphore sem_buf = new(1);
  event ev_rx_pushed, ev_tx_pushed;

  // Parámetros derivados
  localparam int BYTES_W = (ALGN_DATA_WIDTH/8);
  localparam int ALGN_OFFSET_WIDTH = (ALGN_DATA_WIDTH<=8) ? 1 : $clog2(ALGN_DATA_WIDTH/8);
  localparam int ALGN_SIZE_WIDTH   = $clog2(ALGN_DATA_WIDTH/8) + 1;

  // Buffers (muestras “crudas” que captura el sampler)
  MD_Rx_Sample #(ALGN_DATA_WIDTH) data_in_buffer[$];
  MD_Tx_Sample #(ALGN_DATA_WIDTH) data_out_buffer[$];

  // FIFO interno del ALigner (para “cortar” RX si hace falta)
  MD_Rx_Sample #(ALGN_DATA_WIDTH) rx_fifo[$];
  int unsigned rx_cursor = 0; // bytes ya consumidos del sample rx_fifo[0]

  // Últimos valores observados (para detectar cambios)
  // RX
  bit [ALGN_DATA_WIDTH-1:0]   last_data_rx;
  bit [ALGN_OFFSET_WIDTH-1:0] last_offset_rx;
  bit [ALGN_SIZE_WIDTH-1:0]   last_size_rx;
  bit                         last_err_rx;
  bit                         last_valid_rx;

  // TX
  bit [ALGN_DATA_WIDTH-1:0]   last_data_tx;
  bit [ALGN_OFFSET_WIDTH-1:0] last_offset_tx;
  bit [ALGN_SIZE_WIDTH-1:0]   last_size_tx;
  bit                         last_err_tx;
  bit                         last_valid_tx;

  // Contadores informativos
  int unsigned rx_bytes_count;
  int unsigned tx_bytes_count;

  // ====== Helpers ======

  // Devuelve un byte del bus "data" en el lane "lane_idx" (0..BYTES_W-1)
  function automatic logic [7:0] get_lane_byte(bit [ALGN_DATA_WIDTH-1:0] data, int lane_idx);
    return data >> (8*lane_idx);
  endfunction

  // Crea un fragmento RX con 'count' bytes desde el sample 'src', empezando en 'start_byte'
  // Respeta los lanes originales (offset + start_byte + j).
  function automatic MD_Rx_Sample #(ALGN_DATA_WIDTH)
    make_rx_fragment(MD_Rx_Sample #(ALGN_DATA_WIDTH) src,
                     int unsigned start_byte,
                     int unsigned count);
    MD_Rx_Sample #(ALGN_DATA_WIDTH) frag;
    bit [ALGN_DATA_WIDTH-1:0] empaquetado;
    empaquetado = '0;
    frag = new();

    for (int j = 0; j < count; j++) begin
      int lane = src.offset + start_byte + j;
      logic [7:0] b = get_lane_byte(src.data_in, lane);
      empaquetado[(8*lane)+:8] = b;
    end

    frag.data_in = empaquetado;
    frag.offset  = src.offset + start_byte;
    frag.size    = count[ALGN_SIZE_WIDTH-1:0];
    frag.err     = src.err;
    frag.t_sample= src.t_sample; // si tu struct lo trae
    return frag;
  endfunction

  // Envía transacción a scoreboard y checker
  task automatic send_transaction(MD_pack2 #(ALGN_DATA_WIDTH) tr);
    // Si tu clase tiene clone(), cámbialo por put(tr.clone())
    msMD_mailbox.put(tr.clone());
    mcMD_mailbox.put(tr.clone());
  endtask

  // ====== API de arranque ======
  task run();
    fork
      sample_rx_data();
      sample_tx_data();
      aligner();
    join_none
  endtask

  // ====== Sampler RX ======
  task sample_rx_data();
    MD_Rx_Sample #(ALGN_DATA_WIDTH) s;
    bit valid_toggled;
    bit content_change;
    // Inicializa “last”
    last_data_rx   = '0;
    last_offset_rx = '0;
    last_size_rx   = '0;
    last_err_rx    = '0;
    last_valid_rx  = 1'b0;

    forever begin
      @(posedge vif.clk);

      valid_toggled  = (vif.md_rx_valid !== last_valid_rx);
      content_change = vif.md_rx_valid && (
                              (vif.md_rx_data   !== last_data_rx  ) ||
                              (vif.md_rx_offset !== last_offset_rx) ||
                              (vif.md_rx_size   !== last_size_rx  ) ||
                              (vif.md_rx_err    !== last_err_rx   )
                            );

      if (valid_toggled || content_change) begin
        if (vif.md_rx_valid) begin
          // Capturamos SOLO cuando valid=1
          s = new();
          s.data_in  = vif.md_rx_data;
          s.offset   = vif.md_rx_offset;
          s.size     = vif.md_rx_size;
          s.err      = vif.md_rx_err;
          s.t_sample = $time;

          sem_buf.get();
            data_in_buffer.push_back(s);
          sem_buf.put();
          -> ev_rx_pushed;

          rx_bytes_count += s.size; // (corrige tu "=+" por "+=")
        end

        // Actualiza “last” SIEMPRE para detectar toggles y cambios
        last_data_rx   = vif.md_rx_data;
        last_offset_rx = vif.md_rx_offset;
        last_size_rx   = vif.md_rx_size;
        last_err_rx    = vif.md_rx_err;
        last_valid_rx  = vif.md_rx_valid;
      end
    end
  endtask

  // ====== Sampler TX ======
  task sample_tx_data();
    MD_Tx_Sample #(ALGN_DATA_WIDTH) s;
    bit valid_toggled;
    bit content_change;
    last_data_tx   = '0;
    last_offset_tx = '0;
    last_size_tx   = '0;
    last_err_tx    = '0;
    last_valid_tx  = 1'b0;

    forever begin
      @(posedge vif.clk);

      valid_toggled  = (vif.md_tx_valid !== last_valid_tx);
      content_change = vif.md_tx_valid && (
                              (vif.md_tx_data   !== last_data_tx  ) ||
                              (vif.md_tx_offset !== last_offset_tx) ||
                              (vif.md_tx_size   !== last_size_tx  ) ||
                              (vif.md_tx_err    !== last_err_tx   )
                            );

      if (valid_toggled || content_change) begin
        if (vif.md_tx_valid) begin
          s = new();
          s.data_out    = vif.md_tx_data;
          s.ctrl_offset = vif.md_tx_offset;
          s.ctrl_size   = vif.md_tx_size;
          s.t_sample    = $time;

          sem_buf.get();
            data_out_buffer.push_back(s);
          sem_buf.put();
          -> ev_tx_pushed;

          tx_bytes_count += s.ctrl_size;
        end

        last_data_tx   = vif.md_tx_data;
        last_offset_tx = vif.md_tx_offset;
        last_size_tx   = vif.md_tx_size;
        last_valid_tx  = vif.md_tx_valid;
      end
    end
  endtask

  // ====== Aligner (TX-centrico, consume bytes RX según ctrl_size) ======
  task aligner();
    MD_pack2 #(ALGN_DATA_WIDTH) tr;
    MD_Rx_Sample #(ALGN_DATA_WIDTH) frag;
    MD_Tx_Sample #(ALGN_DATA_WIDTH) tx;
    MD_Rx_Sample #(ALGN_DATA_WIDTH) head;
    int unsigned need, avail, take;

    forever begin
      // 1) Espera TX disponible
      if (data_out_buffer.size() == 0) @ev_tx_pushed;

      sem_buf.get();
        tx = data_out_buffer.pop_front();
      sem_buf.put();

      // 2) Para cada TX, consumir EXACTAMENTE ctrl_size bytes del flujo RX
      need = int'(tx.ctrl_size);
      if (need == 0 || need > BYTES_W) begin
        $error("[MD_MON] ctrl_size inválido (%0d). BYTES_W=%0d", need, BYTES_W);
        continue;
      end

      tr = new();
      // nota: algunos MD_pack2 tienen data_out[] (dinámico). Si el tuyo es un solo campo, ajusta:
      //tr.data_out = new();
      tr.data_out[0] = tx;

      // Asegura disponibilidad de RX suficientes, trayendo del sampler a rx_fifo
      // y esperando nuevos si hace falta
      while (need > 0) begin
        // rellenar rx_fifo desde data_in_buffer cuando esté vacío
        if (rx_fifo.size() == 0) begin
          if (data_in_buffer.size() == 0) begin
            @ev_rx_pushed;
          end
          sem_buf.get();
            while (data_in_buffer.size() != 0)
              rx_fifo.push_back(data_in_buffer.pop_front());
          sem_buf.put();
        end

        head  = rx_fifo[0];
        avail = int'(head.size) - rx_cursor;
        if (avail <= 0) begin
          // debería significar que consumimos todo: avanzar
          rx_fifo.pop_front();
          rx_cursor = 0;
          continue;
        end

        take = (need <= avail) ? need : avail;

        // Fragmenta si hace falta y anexa a la transacción
        frag = make_rx_fragment(head, rx_cursor, take);
        // Si tu MD_pack2 usa una cola dinámica:
        //if (tr.data_in.size() == 0) tr.data_in = new();
        tr.data_in.push_back(frag);

        // Actualiza cursores
        rx_cursor += take;
        need      -= take;

        if (rx_cursor == int'(head.size)) begin
          rx_fifo.pop_front();
          rx_cursor = 0;
        end
      end // while need

      // 3) (Opcional) Puedes copiar meta a nivel de transacción si tu MD_pack2 lo tiene
      // tr.offset_out = tx.ctrl_offset;
      // tr.size_out   = tx.ctrl_size;
      // tr.err        = tx.err;

      // 4) Publica
      send_transaction(tr);

      // 5) Mensajería de debug (opcional)
      $display("[MD_MON] TX(size=%0d, off=%0d) -> %0d fragmentos RX",tx.ctrl_size, tx.ctrl_offset, tr.data_in.size());
    end // forever
  endtask

endclass */

