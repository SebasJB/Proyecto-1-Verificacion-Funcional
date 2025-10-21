interface MD_if #(parameter int ALGN_DATA_WIDTH = 32) (input logic clk);
    localparam int ALGN_OFFSET_WIDTH = (ALGN_DATA_WIDTH<=8) ? 1 : $clog2(ALGN_DATA_WIDTH/8);
    localparam int ALGN_SIZE_WIDTH   = $clog2(ALGN_DATA_WIDTH/8) + 1;

    logic                         md_rx_valid;
    logic [ALGN_DATA_WIDTH-1:0]   md_rx_data;
    logic [ALGN_OFFSET_WIDTH-1:0] md_rx_offset;
    logic [ALGN_SIZE_WIDTH-1:0]   md_rx_size;
    logic                         md_rx_ready; 
    logic                         md_rx_err; 
    logic                         md_tx_valid;
    logic [ALGN_DATA_WIDTH-1:0]   md_tx_data;
    logic [ALGN_OFFSET_WIDTH-1:0] md_tx_offset;
    logic [ALGN_SIZE_WIDTH-1:0]   md_tx_size;
    logic                         md_tx_ready;
    logic                         md_tx_err;
  endinterface

  interface APB_if (input logic clk);
    logic [15:0]                  paddr;
    logic                         psel;
    logic                         penable;
    logic                         pwrite;
    logic [31:0]                  pwdata;
    logic [31:0]                  prdata;   
    logic                         pready;   
    logic                         pslverr; 
    logic                         irq;  
  endinterface

  // ==============================================================
  // MD DRIVER  (lee pack1 desde gdMD_mailbox)
  //  - Aplica protocolo: {data,offset,size} + md_rx_valid estables
  //    hasta que md_rx_ready = 1; un ciclo después baja todo a 0.
  //  - Respeta "trans_cycles" antes de la siguiente transacción.
  // ==============================================================
  class MD_Driver #(parameter int ALGN_DATA_WIDTH = 32);
    virtual MD_if #(.ALGN_DATA_WIDTH(ALGN_DATA_WIDTH)) vif;
    mailbox gdMD_mailbox;

    static function string mode2str(test_e m);
    case (m)
      CASO_GENERAL: mode2str = "CASO_GENERAL";
      ESTRES:       mode2str = "ESTRES";
      ERRORES:      mode2str = "ERRORES";
      APB_CFG:      mode2str = "APB_CFG";
      default:      mode2str = $sformatf("UNK(%0d)", m);
    endcase
    endfunction

    // Pone la interfaz en reposo
    task automatic idle_lines();
      vif.md_rx_valid  = 1'b0;
      vif.md_rx_data   = '0;
      vif.md_rx_offset = '0;
      vif.md_rx_size   = '0;
      @(posedge vif.clk);
    endtask

    // Arranca el bucle de conducción
    task run();
      MD_pack1#(.ALGN_DATA_WIDTH(ALGN_DATA_WIDTH)) item;
      idle_lines();
      forever begin
        gdMD_mailbox.get(item);           // bloquea hasta tener un item

        // SETUP del beat
        vif.md_rx_data   = item.md_data;
        vif.md_rx_offset = item.md_offset;
        vif.md_rx_size   = item.md_size;
        vif.md_rx_valid  = 1'b1;
        $display("[%0t] MD_DRV SETUP  test=%s tran#=%0d  data=0x%0h off=%0d size=%0d",
        $time, mode2str(item.mode), item.txn_num, item.md_data, item.md_offset, item.md_size);

        wait (vif.md_rx_ready === 1'b1);    // Espera ready del DUT 
        $display("[%0t] MD_DRV  ready=1 err=%0b", $time, vif.md_rx_err);
        // Un ciclo después de ready=1, soltar líneas a 0
        @(posedge vif.clk);
        vif.md_rx_valid  = 1'b0;
        vif.md_rx_data   = '0;
        vif.md_rx_offset = '0;
        vif.md_rx_size   = '0;
        $display("[%0t] MD_DRV  gap=%0d", $time, item.trans_cycles);
        // tiempo de espera siguiente transacción
        repeat (item.trans_cycles) @(posedge vif.clk);
      end
    endtask
  endclass

  // ==============================================================
  // APB DRIVER  (lee pack1 desde gdAPB_mailbox)
  //  - Ciclo SETUP:   psel=1, paddr, pwrite (Según regla), pwdata
  //  - Ciclo ACCESS:  penable=1 hasta pready=1
  //  - Un ciclo después: bajar todo y esperar "conf_cycles"
  //  - Regla: pwrite=1 SOLO si (Esc_Lec_APB==1); en caso contrario 0.
  // ==============================================================
  class APB_Driver;
    virtual APB_if vif;
    mailbox gdAPB_mailbox;

    static function string mode2str(test_e m);
    case (m)
      CASO_GENERAL: mode2str = "CASO_GENERAL";
      ESTRES:       mode2str = "ESTRES";
      ERRORES:      mode2str = "ERRORES";
      APB_CFG:      mode2str = "APB_CFG";
      default:      mode2str = $sformatf("UNK(%0d)", m);
    endcase
    endfunction

    task automatic idle_bus();
      vif.psel    = 1'b0;
      vif.penable = 1'b0;
      vif.pwrite  = 1'b0;
      vif.paddr   = '0;
      vif.pwdata  = '0;
      @(posedge vif.clk);
    endtask

    // Secuencia básica APB 
    task run();
      APB_pack1 item;
      idle_bus();
      forever begin
        gdAPB_mailbox.get(item);

        // ---- SETUP: poner señales y PSEL=1 (PENABLE=0) ------------
        vif.paddr   = item.APBaddr;
        // pwrite solo se activa si ESCRITURA
        vif.pwrite  = (item.Esc_Lec_APB);
        // Solo tiene sentido pwdata cuando es escritura
        vif.pwdata  = ( item.Esc_Lec_APB )
               ? item.APBdata : '0;
        vif.psel    = 1'b1;
        vif.penable = 1'b0;
        $display("[%0t] APB_DRV SETUP  test=%s tran#=%0d  %s addr=0x%0h data=0x%0h",
        $time, mode2str(item.mode), item.txn_num, (item.Esc_Lec_APB ? "WRITE":"READ"), item.APBaddr, item.APBdata);
        @(posedge vif.clk);

        // ---- ACCESS: levantar PENABLE y esperar PREADY ----
        vif.penable = 1'b1;
        // Si PREADY se pone en 1 en este mismo ciclo (0 wait), este wait termina de inmediato.
        // Si no, esperará hasta el ciclo en que PREADY suba.
        wait (vif.pready === 1'b1);  
        // Si es lectura, tomar datos ahora (ciclo de PREADY)
        if (!item.Esc_Lec_APB) begin
          $display("[%0t] APB_DRV READ addr=0x%0h read_data=0x%0h err=%0b",
                   $time, item.APBaddr, vif.prdata, vif.pslverr);
        end else begin
          // LOG write complete
          $display("[%0t] APB_DRV WRITE  addr=0x%0h data=0x%0h err=%0b",
                   $time, item.APBaddr, item.APBdata, vif.pslverr);
        end
        // Flanco inmediatamente POSTERIOR al flanco que tuvo PREADY=1 -> bajar
        @(posedge vif.clk);
        vif.psel    = 1'b0;
        vif.penable = 1'b0;
        vif.pwrite  = 1'b0;
        vif.paddr   = '0;
        vif.pwdata  = '0;
        $display("[%0t] APB_DRV DONE IDLE  gap=%0d", $time, item.conf_cycles);
        // ---- transacciones entre configuraciones ----------------------------
        repeat (item.conf_cycles) @(posedge vif.clk);
      end
    endtask
  endclass

