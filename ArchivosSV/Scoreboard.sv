
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


  // === Hilo consumidor de MD  ===
  task consume_md_monitor();
    MD_pack2 #(ALGN_DATA_WIDTH) MD_tr;
    forever begin
      msMD_mailbox.get(MD_tr);
      mon_rx_data_q = MD_tr.data_in;
      mon_rx_offset_q.push_back(MD_tr.offset_in);
      mon_rx_size_q.push_back(MD_tr.size_in);
      tx_data_q.push_back(MD_tr.data_out);
      tx_offset_q.push_back(MD_tr.offset_out);
      tx_size_q.push_back(MD_tr.size_out);
      err_q.push_back(MD_tr.err);
      t_in.push_back(MD_tr.t_data_in);
      t_out.push_back(MD_tr.t_data_out);
      time_trans_q.push_back(MD_tr.t_data_in - MD_tr.t_tx_sample);
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
  endtask

  // === Exportar CSV en columnas ===
  // Columnas: RX_data, RX_size, RX_offset, APB_prdata, APB_pslverr, TX_data, TX_size, TX_offset
  // + (opcional) APB_addr, APB_dir, APB_wdata, APB_waitstates
 /* task write_csv(string path);
    int fd = $fopen(path, "w");
    if (fd == 0) begin
      $display("[%0t] [SB] ERROR: No se pudo abrir CSV '%s'", $time, path);
      return;
    end

    // Cabecera
    $fdisplay(fd, "idx," "rx_data,rx_size,rx_offset," "apb_prdata,apb_pslverr,apb_addr,apb_dir,apb_wdata,apb_waitstates," "tx_data,tx_size,tx_offset"
    );

    int unsigned n_rx = rx_data_q.size();
    int unsigned n_apb = apb_prdata_q.size();
    int unsigned n_tx = tx_data_q.size();

    int unsigned n_rows;
    if (n_rx >= n_apb && n_rx >= n_tx)       n_rows = n_rx;
    else if (n_apb >= n_rx && n_apb >= n_tx) n_rows = n_apb;
    else                                     n_rows = n_tx;

    // Helper para strings vacíos en campos faltantes
    string s_rx_data, s_rx_size, s_rx_off;
    string s_apb_prd, s_apb_err, s_apb_addr, s_apb_dir, s_apb_wdat, s_apb_ws;
    string s_tx_data, s_tx_size, s_tx_off;

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
  endtask*/

endclass
