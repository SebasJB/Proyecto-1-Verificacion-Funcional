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
  //mailbox mcMD_mailbox; // Monitor → checker: MD transactions

  // Estado para detectar cambios y medir tiempos

  localparam int ALGN_OFFSET_WIDTH = (ALGN_DATA_WIDTH<=8) ? 1 : $clog2(ALGN_DATA_WIDTH/8);
  localparam int ALGN_SIZE_WIDTH   = $clog2(ALGN_DATA_WIDTH/8) + 1;


  MD_Rx_Sample #(ALGN_DATA_WIDTH) data_in_buffer[$]; // buffer de datos recibidos
  MD_Rx_Sample #(ALGN_DATA_WIDTH) data_out_buffer[$]; // buffer de datos enviados


  //Variables de ultimos valores observados rx
  bit [ALGN_DATA_WIDTH-1:0]   last_data_rx; // Último dato observado
  bit [ALGN_OFFSET_WIDTH-1:0] last_offset_rx; // Último offset observado
  bit [ALGN_SIZE_WIDTH-1:0]   last_size_rx; // Último tamaño observado
  bit last_err_rx; // Último error observado
  time t_data_start_rx; // inicio del "dato activo" actual

  //Variables de ultimos valores observados tx
  bit [ALGN_DATA_WIDTH-1:0]   last_data_tx; // Último dato observado
  bit [ALGN_OFFSET_WIDTH-1:0] last_offset_tx; // Último offset observado
  bit [ALGN_SIZE_WIDTH-1:0]   last_size_tx; // Último tamaño observado
  bit last_err_tx; // Último error observado
  time t_data_start_tx; // inicio del "dato activo" actual

  function void push_rx_buffer();
    MD_Rx_Sample #(ALGN_DATA_WIDTH) sample;
    sample.data = vif.md_rx_data;
    sample.offset = vif.md_rx_offset;
    sample.size = vif.md_rx_size;
    sample.err = vif.md_rx_err;
    sample.t_sample = t_data_start;
    sample.bytes_left = sample.size;
    data_in_buffer.push_back(sample);
  endfunction

  function void push_tx_buffer();
    MD_Tx_Sample #(ALGN_DATA_WIDTH) sample;
    sample.data = vif.md_tx_data;
    sample.offset = vif.md_tx_offset;
    sample.size = vif.md_tx_size;
    sample.t_sample = t_data_start;
    data_out_buffer.push_back(sample);
  endfunction

  function int unsigned rx_bytes_available();
    int unsigned total = 0;
    foreach (data_in_buffer[i]) begin
      total += data_in_buffer[i].bytes_left;
    end
    return total;
  endfunction

  function void consume_rx_bytes(ref MD_Rx_Sample #(ALGN_DATA_WIDTH) rx_fifo[$], ref MD_pack2 #(ALGN_DATA_WIDTH) trans, int unsigned num_bytes);
    int unsigned bytes_to_consume = num_bytes;
    bit num_err = 0;
    MD_Rx_Sample #(ALGN_DATA_WIDTH) current_sample;
    int unsigned sample_bytes;
    while (bytes_to_consume > 0) begin
      if (rx_fifo.size() == 0) begin
        $fatal(1, "No hay suficientes datos en el buffer RX para consumir %0d bytes", num_bytes);
      end     
      current_sample = rx_fifo[0];
      sample_bytes = (bytes_to_consume <= current_sample.bytes_left) ? bytes_to_consume : current_sample.bytes_left;
      if (current_sample.bytes_left == 0) begin
        rx_fifo.pop_front();
        continue;
      end

      num_err |= current_sample.err;
      trans.data_in.push_back(current_sample);
      bytes_to_consume -= sample_bytes;
      current_sample.bytes_left -= sample_bytes;

      //Mantener la coherencia de la cola
      if (current_sample.bytes_left == 0) begin
        rx_fifo.pop_front();
      end else begin
        rx_fifo[0] = current_sample;
      end
    end
    trans.err = num_err;
  endfunction

  function void send_transaction(ref MD_pack2 #(ALGN_DATA_WIDTH) trans);
    msMD_mailbox.put(trans.clone());
    //mcMD_mailbox.put(trans.clone());
  endfunction

  task sample_rx_data();
     @(posedge vif.clk);
    // Inicializa referencia del primer dato observado
    last_data_rx = vif.md_rx_data;
    last_offset_rx = vif.md_rx_offset;
    last_size_rx = vif.md_rx_size;
    last_err_rx = vif.md_rx_err;
    t_data_start_rx = $time;

    forever begin
      @(posedge vif.clk);
      // === 2) Detección de CAMBIO DE DATO (aunque no haya handshake) ===


      if ((vif.md_rx_data != last_data_rx) & vif.md_rx_ready) begin
        // Cierra el "dato activo" anterior
        MD_pack2#(ALGN_DATA_WIDTH) change_tr = new();
        change_tr.data = vif.md_rx_data;
        change_tr.offset = vif.md_rx_offset;
        change_tr.size = vif.md_rx_size;
        change_tr.err = vif.md_rx_err;
        change_tr.t_sample = t_data_start_rx;
        change_tr.md_t_time = ($time - t_data_start_rx);

        // Publica duración del dato anterior
        msMD_mailbox.put(change_tr.clone());
        //mcMD_mailbox.put(change_tr.clone());

        // Inicia nuevo "dato activo"
        last_data_rx = vif.md_rx_data;
        last_offset_rx = vif.md_rx_offset;
        last_size_rx = vif.md_rx_size;
        last_err_rx = vif.md_rx_err;
        t_data_start_rx = $time;
      end

      else if (vif.md_rx_ready) begin
        MD_pack2#(ALGN_DATA_WIDTH) handshake_tr = new();
        handshake_tr.data = vif.md_rx_data;
        handshake_tr.offset = vif.md_rx_offset;
        handshake_tr.size = vif.md_rx_size;
        handshake_tr.err = vif.md_rx_err;
        handshake_tr.t_sample = t_data_start_rx;
        handshake_tr.md_t_time = ($time - t_data_start_rx); // duración desde el último cambio
        msMD_mailbox.put(handshake_tr.clone());
        //mcMD_mailbox.put(handshake_tr.clone());
        // Reinicia medición del dato actual
        last_data_rx = vif.md_rx_data;
        last_offset_rx = vif.md_rx_offset;
        last_size_rx = vif.md_rx_size;
        last_err_rx = vif.md_rx_err;
        t_data_start_rx = $time;

      end
      // === 3) No hay cambio ni handshake ===
    

      else begin
        // Se mantiene actualizados offset/size/err (por si varían sin cambio de data)
        last_offset_rx = vif.md_rx_offset;
        last_size_rx = vif.md_rx_size;
        last_err_rx = vif.md_rx_err;
      end
    end
  endtask

  task sample_tx_data();
    vif.md_tx_ready = 1'b1; // Siempre listo para enviar
     @(posedge vif.clk);
    // Inicializa referencia del primer dato observado
    last_data = vif.md_tx_data;
    last_offset = vif.md_tx_offset;
    last_size = vif.md_tx_size;
    last_err = vif.md_tx_err;
    t_data_start = $time;

    forever begin
      @(posedge vif.clk);
      // === 2) Detección de CAMBIO DE DATO (aunque no haya handshake) ===
      if ((vif.md_tx_data != last_data) & vif.md_tx_valid) begin
        // Cierra el "dato activo" anterior
        MD_pack2#(ALGN_DATA_WIDTH) change_tr = new();
        change_tr.data = vif.md_tx_data;
        change_tr.offset = vif.md_tx_offset;
        change_tr.size = vif.md_tx_size;
        change_tr.err = vif.md_tx_err;
        change_tr.t_sample = t_data_start;
        change_tr.md_t_time = ($time - t_data_start);

        // Publica duración del dato anterior
        msMD_mailbox.put(change_tr.clone());
        //mcMD_mailbox.put(change_tr.clone());

        // Inicia nuevo "dato activo"
        last_data = vif.md_tx_data;
        last_offset = vif.md_tx_offset;
        last_size = vif.md_tx_size;
        last_err = vif.md_tx_err;
        t_data_start = $time;
      end
      else if (vif.md_tx_valid) begin
        MD_pack2#(ALGN_DATA_WIDTH) handshake_tr = new();
        handshake_tr.data = vif.md_tx_data;
        handshake_tr.offset = vif.md_tx_offset;
        handshake_tr.size = vif.md_tx_size;
        handshake_tr.err = vif.md_tx_err;
        handshake_tr.t_sample = t_data_start;
        handshake_tr.md_t_time = ($time - t_data_start); // duración desde el último cambio
        msMD_mailbox.put(handshake_tr.clone());
        //mcMD_mailbox.put(handshake_tr.clone());

        // Reinicia medición del dato actual
        last_data = vif.md_tx_data;
        last_offset = vif.md_tx_offset;
        last_size = vif.md_tx_size;
        last_err = vif.md_tx_err;
        t_data_start = $time;
      end
      // === 3) No hay cambio ni handshake ===
      else begin
        // Se mantiene actualizados offset/size/err (por si varían sin cambio de data)
        last_offset = vif.md_tx_offset;
        last_size = vif.md_tx_size;
        last_err = vif.md_tx_err;
      end
    end
  endtask

  task aligner();
    MD_Tx_Sample #(ALGN_DATA_WIDTH) tx_sample;
    MD_pack2 #(ALGN_DATA_WIDTH) tr;
    forever begin
      wait (data_out_buffer.size() > 0);
      tx_sample = data_out_buffer.pop_front();
      while (rx_bytes_available() < tx_sample.size) begin
        @(posedge vif.clk);
        tr = new();
        tr.data_out = tx_sample;
        tr.t_data_out = tx_sample.t_sample;
        consume_rx_bytes(data_in_buffer, tr, tx_sample.size);
        send_transaction(tr);
      end
    end
  endtask

  task run_monitor();
    fork
      sample_rx_data();
      sample_tx_data();
      aligner();
    join_none
  endtask


  /*task run();
    // Política de aceptar siempre
    vif.md_tx_ready = 1'b1;

    // Sin señal de reset en la interface, arrancamos tras un ciclo
    @(posedge vif.clk);
    // Inicializa referencia del primer dato observado
    last_data = vif.md_tx_data;
    last_offset = vif.md_tx_offset;
    last_size = vif.md_tx_size;
    last_err = vif.md_tx_err;
    t_data_start = $time;

    forever begin
      @(posedge vif.clk);
      // === 2) Detección de CAMBIO DE DATO (aunque no haya handshake) ===


      if ((vif.md_tx_data != last_data) & vif.md_tx_valid) begin
        // Cierra el "dato activo" anterior
        MD_pack2#(ALGN_DATA_WIDTH) change_tr = new();
        change_tr.data = vif.md_tx_data;
        change_tr.offset = vif.md_tx_offset;
        change_tr.size = vif.md_tx_size;
        change_tr.err = vif.md_tx_err;
        change_tr.t_sample = t_data_start;
        change_tr.md_t_time = ($time - t_data_start);

        // Publica duración del dato anterior
        msMD_mailbox.put(change_tr.clone());
        //mcMD_mailbox.put(change_tr.clone());

        // Inicia nuevo "dato activo"
        last_data = vif.md_tx_data;
        last_offset = vif.md_tx_offset;
        last_size = vif.md_tx_size;
        last_err = vif.md_tx_err;
        t_data_start = $time;
      end
      // === 1) Reporte de HANDSHAKE (valid && ready) ===
      else if (vif.md_tx_valid) begin
        MD_pack2#(ALGN_DATA_WIDTH) handshake_tr = new();
        handshake_tr.data = vif.md_tx_data;
        handshake_tr.offset = vif.md_tx_offset;
        handshake_tr.size = vif.md_tx_size;
        handshake_tr.err = vif.md_tx_err;
        handshake_tr.t_sample = t_data_start;
        handshake_tr.md_t_time = ($time - t_data_start); // duración desde el último cambio
        msMD_mailbox.put(handshake_tr.clone());
        //mcMD_mailbox.put(handshake_tr.clone());
        // Reinicia medición del dato actual
        last_data = vif.md_tx_data;
        last_offset = vif.md_tx_offset;
        last_size = vif.md_tx_size;
        last_err = vif.md_tx_err;
        t_data_start = $time;

      end
      // === 3) No hay cambio ni handshake ===
    

      else begin
        // Se mantiene actualizados offset/size/err (por si varían sin cambio de data)
        last_offset = vif.md_tx_offset;
        last_size = vif.md_tx_size;
        last_err = vif.md_tx_err;
      end
    end
  endtask*/
endclass
