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
  semaphore sem_buf = new(2);
  event ev_rx_pushed, ev_tx_pushed;

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
  



  /*
  function void consume_rx_bytes(ref MD_Rx_Sample #(ALGN_DATA_WIDTH) rx_fifo[$], MD_pack2 #(ALGN_DATA_WIDTH) trans);
    int unsigned bytes_to_consume = rx_bytes_available();
    bit num_err = 0;
    MD_Rx_Sample #(ALGN_DATA_WIDTH) current_sample;
    int unsigned sample_bytes;
    while (bytes_to_consume > 0) begin
      if (rx_fifo.size() == 0) begin
        $fatal(1, "No hay suficientes datos en el buffer RX para consumir %0d bytes", bytes_to_consume);
      end     
      current_sample = rx_fifo[0];
      sample_bytes = (bytes_to_consume <= current_sample.size) ? bytes_to_consume : current_sample.size;
      $display("[MD_MON] Consumiendo %0d bytes del sample con %0d bytes restantes", sample_bytes, current_sample.size);
      if (bytes_to_consume == 0) begin
        rx_fifo.pop_front();
        continue;
      end

      num_err |= current_sample.err;
      trans.data_in.push_back(current_sample);
      bytes_to_consume -= sample_bytes;

      //Mantener la coherencia de la cola
      if (bytes_to_consume == 0) begin
        rx_fifo.pop_front();
      end else begin
        rx_fifo[0] = current_sample;
      end
    end
  endfunction */

  task send_transaction(ref MD_pack2 #(ALGN_DATA_WIDTH) trans);
    msMD_mailbox.put(trans.clone());
    mcMD_mailbox.put(trans.clone());
    $display("[MD_MON] Enviado paquete MD al scoreboard/checker: %0d bytes", trans.data_in.size());
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
          sem_buf.get(1);
          sample = new();
          sample.data_in = vif.md_rx_data;
          sample.offset  = vif.md_rx_offset;
          sample.size    = vif.md_rx_size;
          sample.err     = vif.md_rx_err;
          sample.t_sample= $time;
          
          data_in_buffer.push_back(sample);
          rx_bytes_count += sample.size;

          @(posedge vif.clk);
          -> ev_rx_pushed;
          sem_buf.put(1);
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
        
        sem_buf.get(1);
        sample = new();
        sample.data_out = vif.md_tx_data;
        sample.ctrl_offset = vif.md_tx_offset;
        sample.ctrl_size = vif.md_tx_size;
        sample.t_sample = $time;
        data_out_buffer.push_back(sample);
        tx_bytes_count += sample.ctrl_size;

        @(posedge vif.clk);
        -> ev_tx_pushed;
        sem_buf.put(1);
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
    forever begin
      @ev_rx_pushed;
      rx_sample = data_in_buffer.pop_front();
      @ev_tx_pushed;
      tx_sample = data_out_buffer.pop_front();

      if (rx_sample.size > tx_sample.ctrl_size) begin
        while(tx_bytes_count < rx_sample.size) begin
          sem_buf.get(1);
          @ev_tx_pushed;
          tx_bytes_count =+ tx_sample.ctrl_size;
          sem_buf.put(1);
        end
        tr = new();
        tr.data_in[0] = rx_sample;
        foreach (data_out_buffer[i]) begin
          tr.data_out[i] = data_out_buffer.pop_front();
        end
        @(posedge vif.clk);
        $display("[MD_MON] Enviado paquete MD al checker: TX(size=%0d,data=%h) RX(samples=%0d)", tr.data_out[0].ctrl_size, tr.data_out[0].data_out, tr.data_in.size());
         foreach (tr.data_in[i]) begin
          $display("  [RX%0d] data=%h off=%0d size=%0d", i, tr.data_in[i].data_in, tr.data_in[i].offset, tr.data_in[i].size);
          end

        send_transaction(tr);
        tx_bytes_count = 0;
      end

      else begin
        
        while (rx_bytes_count < tx_sample.ctrl_size) begin
          sem_buf.get(1);
          @ev_rx_pushed;
          rx_bytes_count =+ rx_sample.size;
          sem_buf.put(1);
        end
        tr = new();
        tr.data_out[0] = tx_sample;
        foreach (data_in_buffer[i]) begin
          tr.data_in[i] = data_in_buffer.pop_front();
        end
        @(posedge vif.clk);
         $display("[MD_MON] Enviado paquete MD al checker: TX(size=%0d,data=%h) RX(samples=%0d)", tr.data_out[0].ctrl_size, tr.data_out[0].data_out, tr.data_in.size());
         foreach (tr.data_in[i]) begin
          $display("  [RX%0d] data=%h off=%0d size=%0d", i, tr.data_in[i].data_in, tr.data_in[i].offset, tr.data_in[i].size);
          end
        send_transaction(tr);
        rx_bytes_count = 0;
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
