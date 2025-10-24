
// ----------------------------------------------------
// Scoreboard: consume msMD_mailbox y msAPB_mailbox,
// acumula en queues y exporta CSV.
// ----------------------------------------------------
class Scoreboard #(int ALGN_DATA_WIDTH = 32);

  localparam int ALGN_OFFSET_WIDTH = (ALGN_DATA_WIDTH<=8) ? 1 : $clog2(ALGN_DATA_WIDTH/8);
  localparam int ALGN_SIZE_WIDTH   = 3;
  // Mailboxes (exactos según tu requerimiento)
  mailbox msMD_mailbox;   // monitores → scoreboard (MD)
  mailbox msAPB_mailbox;  // monitores → scoreboard (APB)
  mailbox gsMD_mailbox;    // generator -> scoreboard (MD)
  mailbox gsAPB_mailbox;   // generator -> scoreboard (APB)


  // ====== Queues de generador (MD) ======
  bit [ALGN_DATA_WIDTH-1:0] rx_data_q[$]; // para análisis de datos en RX
  bit [ALGN_OFFSET_WIDTH-1:0] rx_offset_q[$];  // para análisis de offsets en RX
  bit [ALGN_SIZE_WIDTH-1:0] rx_size_q[$]; // para análisis de tamaños en RX
  int unsigned gaps_q[$]; // para análisis de gaps en RX

  // ====== Queues de Monitor (MD) ======
  MD_Rx_Sample #(ALGN_DATA_WIDTH) mon_rx_data_q[$]; // para análisis de datos en RX
  bit [ALGN_OFFSET_WIDTH-1:0] mon_rx_offset_q[$];  // para análisis de offsets en RX
  bit [ALGN_SIZE_WIDTH-1:0] mon_rx_size_q[$]; // para análisis de tamaños en RX
  int unsigned mon_gaps_q[$]; // para análisis de gaps en RX

  MD_Tx_Sample #(ALGN_DATA_WIDTH) tx_data_q[$]; // para análisis de datos en TX
  bit [ALGN_OFFSET_WIDTH-1:0] tx_offset_q[$];  // para análisis de offsets en TX
  bit [ALGN_SIZE_WIDTH-1:0] tx_size_q[$]; // para análisis de tamaños en TX
  bit [ALGN_DATA_WIDTH-1:0] err_q[$]; // para análisis de errores en RX
  time t_in[$]; // para análisis de gaps en TX
  time t_out[$]; // para análisis de gaps en TX
  time time_trans_q[$]; // para análisis de gaps totales
  int unsigned md_t_time_q[$]; // para análisis de tiempos de transacción en TX


  // ====== Queues de APB ======
  apb_trans_type apb_dir_q[$]; // para análisis de esc/lec APB (0=lec,1=esc)
  bit [15:0] apb_addr_q[$]; // para análisis de direcciones APB
  bit [31:0] apb_wdata_q[$];
  bit [31:0] apb_prdata_q[$];
  bit apb_pslverr_q[$];
  int unsigned apb_conf_cycles_q[$];
  int unsigned apb_waitstates_q[$];
  time apb_t_time_q[$];

  /*
  // === Hilo consumidor de MD  ===
  task consume_md_monitor();
    MD_pack2 #(ALGN_DATA_WIDTH) MD_tr;
    forever begin
      msMD_mailbox.get(MD_tr);
      foreach (MD_tr.data_in[i]) begin
        mon_rx_data_q.push_back(MD_tr.data_in[i]);
        mon_rx_offset_q.push_back(MD_tr.data_in[i].offset);
        mon_rx_size_q.push_back(MD_tr.data_in[i].size);
        err_q.push_back(MD_tr.data_in[i].err);
        t_in.push_back(MD_tr.data_in[i].t_sample);
      end
      foreach (MD_tr.data_out[i]) begin
        tx_data_q.push_back(MD_tr.data_out[i]);
        tx_offset_q.push_back(MD_tr.data_out[i].ctrl_offset);
        tx_size_q.push_back(MD_tr.data_out[i].ctrl_size);
        t_out.push_back(MD_tr.data_out[i].t_sample);
      end
    end
  endtask

   // === Hilo consumidor de APB ===
  task consume_apb_monitor();
    APB_pack2 apb_tr;
    forever begin
      msAPB_mailbox.get(apb_tr);
      apb_dir_q.push_back(apb_tr.dir);
      apb_prdata_q.push_back(apb_tr.rdata);     // prdata (válido en lecturas)
      apb_pslverr_q.push_back(apb_tr.slverr);    // pslverr
      apb_waitstates_q.push_back(apb_tr.wait_states);
      apb_t_time_q.push_back(apb_tr.apb_t_time);
    end
  endtask


  // === Hilo consumidor de APB ===
  task consume_apb_generator();
    APB_pack1 apb_tr;
    forever begin
      gsAPB_mailbox.get(apb_tr);
      apb_dir_q.push_back(apb_tr.Esc_Lec_APB ? APB_WRITE : APB_READ);
      apb_addr_q.push_back(apb_tr.APBaddr);
      apb_wdata_q.push_back(apb_tr.APBdata);
      apb_conf_cycles_q.push_back(apb_tr.conf_cycles);
    end
  endtask

  task consume_md_generator();
    MD_pack1 #(ALGN_DATA_WIDTH) MD_tr;
    forever begin
      gsMD_mailbox.get(MD_tr);
      rx_data_q.push_back(MD_tr.md_data);
      rx_offset_q.push_back(MD_tr.md_offset);
      rx_size_q.push_back(MD_tr.md_size);
      gaps_q.push_back(MD_tr.trans_cycles);
    end
  endtask

 
  // === Arranque del scoreboard ===
  task run();
    fork
      consume_md_monitor();
      consume_apb_monitor();
      consume_md_generator();
      consume_apb_generator();
    join_none
  endtask*/

  // === Exportar CSV en columnas ===
  // Columnas: RX_data, RX_size, RX_offset, APB_prdata, APB_pslverr, TX_data, TX_size, TX_offset
  // + (opcional) APB_addr, APB_dir, APB_wdata, APB_waitstates
  task write_csv(string path);
    int unsigned n_rx;
    int unsigned n_apb;
    int unsigned n_tx;
    int unsigned n_rows;
    string s_rx_data, s_rx_size, s_rx_off;
    string s_apb_prd, s_apb_err, s_apb_addr, s_apb_dir, s_apb_wdat, s_apb_ws;
    string s_tx_data, s_tx_size, s_tx_off;

    int fd = $fopen(path, "w");
    if (fd == 0) begin
      $display("[%0t] [SB] ERROR: No se pudo abrir CSV '%s'", $time, path);
      return;
    end

    // Cabecera
    $fdisplay(fd, "idx,","rx_data,rx_size,rx_offset,", "apb_prdata,apb_pslverr,apb_addr,apb_dir,apb_wdata,apb_waitstates," ,"tx_data,tx_size,tx_offset");

    n_rx = rx_data_q.size();
    n_apb = apb_prdata_q.size();
    n_tx = tx_data_q.size();

    
    if (n_rx >= n_apb && n_rx >= n_tx)       n_rows = n_rx;
    else if (n_apb >= n_rx && n_apb >= n_tx) n_rows = n_apb;
    else                                     n_rows = n_tx;

    // Helper para strings vacíos en campos faltantes
    

    for (int i = 0; i < n_rows; i++) begin
      // RX
      if (i < n_rx) begin
        s_rx_data = $sformatf("0x%0h", rx_data_q[i]);
        s_rx_size = $sformatf("%0d",   rx_size_q[i]);
        s_rx_off  = $sformatf("%0d",   rx_offset_q[i]);
      end else begin
        s_rx_data = ""; s_rx_size = ""; s_rx_off = "";
      end

      // APB
      if (i < n_apb) begin
        s_apb_prd  = $sformatf("0x%0h", apb_prdata_q[i]);
        s_apb_err  = $sformatf("%0d",   apb_pslverr_q[i]);
        s_apb_addr = $sformatf("0x%0h", apb_addr_q[i]);
        s_apb_dir  = (apb_dir_q[i]==APBWRITE) ? "W" : "R";
        s_apb_wdat = $sformatf("0x%0h", apb_wdata_q[i]);
        s_apb_ws   = $sformatf("%0d",   apb_waitstates_q[i]);
      end else begin
        s_apb_prd = ""; s_apb_err = ""; s_apb_addr = ""; s_apb_dir = ""; s_apb_wdat = ""; s_apb_ws = "";
      end

      // TX
      if (i < n_tx) begin
        s_tx_data = $sformatf("0x%0h", tx_data_q[i]);
        s_tx_size = $sformatf("%0d",   tx_size_q[i]);
        s_tx_off  = $sformatf("%0d",   tx_offset_q[i]);
      end else begin
        s_tx_data = ""; s_tx_size = ""; s_tx_off = "";
      end

      // Escribir fila CSV
      $fdisplay(fd, "%0d,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s",
        i,
        s_rx_data, s_rx_size, s_rx_off,
        s_apb_prd, s_apb_err, s_apb_addr, s_apb_dir, s_apb_wdat, s_apb_ws,
        s_tx_data, s_tx_size, s_tx_off
      );
    end

    $fclose(fd);
    $display("[%0t] [SB] CSV escrito en '%s' (filas=%0d)", $time, path, n_rows);

    // ===== CSV =====
  endtask

  function void csv_open(string path = "md_trace.csv");
  int csv_fd;
  bit csv_header_written = 0;
    csv_fd = $fopen(path, "w");
    if (csv_fd == 0) $fatal(1, "[SCB] No pude abrir CSV '%s'", path);
    // Header
    $fdisplay(csv_fd,
      "pkt_id,stream,idx,data_hex,offset,size,err,t_sample_ps");
    csv_header_written = 1;
    $display("[SCB] CSV abierto en '%s'", path);
  endfunction

  function void csv_close();
    if (csv_fd) begin
      $fclose(csv_fd);
      csv_fd = 0;
      $display("[SCB] CSV cerrado");
    end
  endfunction

  // Helpers para escribir filas (formato uniforme)
  function void csv_write_rx(int pkt_id, int idx, MD_Rx_Sample#(W) s);
    $fdisplay(csv_fd, "%0d,RX,%0d,%0h,%0d,%0d,%0d,%0t",
              pkt_id, idx, s.data_in,
              int'($unsigned(s.offset)),
              int'($unsigned(s.size)),
              int'(s.err), s.t_sample);
  endfunction

  function void csv_write_tx(int pkt_id, int idx, MD_Tx_Sample#(W) s);
    // err no existe en TX sample -> escribe 0
    $fdisplay(csv_fd, "%0d,TX,%0d,%0h,%0d,%0d,%0d,%0t",
              pkt_id, idx, s.data_out,
              int'($unsigned(s.ctrl_offset)),
              int'($unsigned(s.ctrl_size)),
              0, s.t_sample);
  endfunction

  function void csv_write_err(int pkt_id, int idx, MD_Rx_Sample#(W) s);
    $fdisplay(csv_fd, "%0d,ERR,%0d,%0h,%0d,%0d,%0d,%0t",
              pkt_id, idx, s.data_in,
              int'($unsigned(s.offset)),
              int'($unsigned(s.size)),
              int'(s.err), s.t_sample);
  endfunction

  // Escribe todo un paquete MD (tres colas)
  function void csv_write_packet(int pkt_id, MD_pack2#(W) p);
    if (!csv_header_written) csv_open(); // auto-open si olvidaste llamarlo
    // RX
    foreach (p.data_in[i])
      if (p.data_in[i] != null) csv_write_rx(pkt_id, i, p.data_in[i]);
    // TX
    foreach (p.data_out[j])
      if (p.data_out[j] != null) csv_write_tx(pkt_id, j, p.data_out[j]);
    // ERR
    foreach (p.data_err[k])
      if (p.data_err[k] != null) csv_write_err(pkt_id, k, p.data_err[k]);
  endfunction

  

  task run();
  // ===== Ejemplo de uso en tu flujo =====
  int unsigned pkt_counter = 0;
    MD_pack2#(W) pkt;
    csv_open("md_trace.csv"); // abrir una vez (o deja que sea auto)
    forever begin
      mcMD_mailbox.get(pkt);     // donde sea que recibas el paquete
      csv_write_packet(pkt_counter++, pkt);
      // ... resto del procesamiento/scoreboard ...
    end
  endtask
    class Scoreboard #(int W = 32);

  // ... (tu plumbing existente)

  

endclass

endclass
