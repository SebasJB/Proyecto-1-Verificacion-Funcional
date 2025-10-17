// ====================================================
// Tipos básicos
// ====================================================
typedef enum logic { APB_READ=0, APB_WRITE=1 } apb_trans_type;

// ====================================================
// Transacción APB (capturada al completar la transferencia)
// ====================================================
class APB_pack2;
  apb_trans_type dir;
  bit [15:0] addr;
  bit [31:0] wdata;
  bit [31:0] rdata;
  bit slverr;
  int unsigned wait_states; // ciclos con penable=1 hasta pready=0
  time apb_t_time; // tiempo total de la transacción (t_end - t_start)

  function new();
    dir = APB_READ;
    addr = '0;
    wdata = '0;
    rdata = '0;
    slverr = 0;
    wait_states = 0;
    apb_t_time = 0;
  endfunction

  function APB_pack2 clone();
    APB_pack2 c = new();
    c.dir = this.dir;
    c.addr = this.addr;
    c.wdata = this.wdata;
    c.rdata = this.rdata;
    c.slverr = this.slverr;
    c.wait_states = this.wait_states;
    c.apb_t_time = this.apb_t_time;
    return c;
  endfunction

  function string sprint();
    return $sformatf("APB %s @0x%0h w=0x%0h r=0x%0h slverr=%0b ws=%0d",(dir==APB_WRITE)?"WRITE":"READ",addr, wdata, rdata, slverr, wait_states);
  endfunction
endclass

// ====================================================
// Transacción MD (lado TX del Aligner, parametrizable)
// Usa el mismo cálculo de anchos que tu interface MD_if
// ====================================================
class MD_pack2 #(int ALGN_DATA_WIDTH = 32);
  localparam int ALGN_OFFSET_WIDTH = (ALGN_DATA_WIDTH<=8) ? 1 : $clog2(ALGN_DATA_WIDTH/8);
  localparam int ALGN_SIZE_WIDTH   = 3;

  bit [ALGN_DATA_WIDTH-1:0]   data;
  bit [ALGN_OFFSET_WIDTH-1:0] offset;
  bit [ALGN_SIZE_WIDTH-1:0]   size;
  bit err;      // refleja md_rx_err
  time t_sample; // tiempo del handshake válido
  int unsigned md_t_time; // tiempo total de la transacción (t_end - t_start)

  function new();
    data = '0;
    offset = '0;
    size = '0;
    err = 0;
    t_sample = 0;
  endfunction

  function MD_pack2#(ALGN_DATA_WIDTH) clone();
    MD_pack2#(ALGN_DATA_WIDTH) c = new();
    c.data = this.data;
    c.offset = this.offset;
    c.size = this.size;
    c.err = this.err;
    c.t_sample = this.t_sample;
    return c;
  endfunction

  function string sprint();
    return $sformatf("MD_TX data=0x%0h off=%0d size=%0d err=%0b", data, offset, size, err);
  endfunction
endclass





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
   mailbox #(APB_pack2_t) msAPB_mailbox; // → scoreboard
  mailbox mcAPB_mailbox; // → checker
 
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
      mcAPB_mailbox.put(tr.clone());
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
  mailbox msMD_mailbox; // → scoreboard
  mailbox mcMD_mailbox; // → checker

  // Estado para detectar cambios y medir tiempos

  localparam int ALGN_OFFSET_WIDTH = (ALGN_DATA_WIDTH<=8) ? 1 : $clog2(ALGN_DATA_WIDTH/8);
  localparam int ALGN_SIZE_WIDTH   = $clog2(ALGN_DATA_WIDTH/8);

  bit [ALGN_DATA_WIDTH-1:0]   last_data; // Último dato observado
  bit [ALGN_OFFSET_WIDTH-1:0] last_offset; // Último offset observado
  bit [ALGN_SIZE_WIDTH-1:0]   last_size; // Último tamaño observado
  bit last_err; // Último error observado
  time t_data_start; // inicio del "dato activo" actual

  function new();
    last_data = '0; // fuerza primer "cambio" al inicio
    last_offset = '0;
    last_size = '0;
    last_err = '0;
    t_data_start = 0;
  endfunction

  task run();
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
        mcMD_mailbox.put(change_tr.clone());

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
        mcMD_mailbox.put(handshake_tr.clone());
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
endclass
