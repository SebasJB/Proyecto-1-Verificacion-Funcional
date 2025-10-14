// ====================================================
// Tipos básicos
// ====================================================
typedef enum logic { APB_READ=0, APB_WRITE=1 } apb_trans_type;

// ====================================================
// Transacción APB (capturada al completar la transferencia)
// ====================================================
class APB_pack2;
  apb_trans_type   dir;
  logic [15:0]     addr;
  logic [31:0]     wdata;
  logic [31:0]     rdata;
  bit              slverr;
  int unsigned     wait_states; // ciclos con penable=1 y pready=0
  time             apb_t_time;     // tiempo total de la transacción (t_end - t_start)

  function new();
    dir         = APB_READ;
    addr        = '0;
    wdata       = '0;
    rdata       = '0;
    slverr      = 0;
    wait_states = 0;
    t_start     = 0;
    t_end       = 0;
  endfunction

  function APB_pack2 clone();
    APB_Trans c = new();
    c.dir         = this.dir;
    c.addr        = this.addr;
    c.wdata       = this.wdata;
    c.rdata       = this.rdata;
    c.slverr      = this.slverr;
    c.wait_states = this.wait_states;
    c.t_start     = this.t_start;
    c.t_end       = this.t_end;
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
  localparam int ALGN_SIZE_WIDTH   = $clog2(ALGN_DATA_WIDTH/8);

  logic [ALGN_DATA_WIDTH-1:0]   data;
  logic [ALGN_OFFSET_WIDTH-1:0] offset;
  logic [ALGN_SIZE_WIDTH-1:0]   size;
  bit                           err;      // refleja md_tx_err
  time                          t_sample; // tiempo del handshake válido
  int unsigned                  md_t_time; // tiempo total de la transacción (t_end - t_start)

  function new();
    data     = '0;
    offset   = '0;
    size     = '0;
    err      = 0;
    t_sample = 0;
  endfunction

  function MD_pack2#(ALGN_DATA_WIDTH) clone();
    MD_Trans#(ALGN_DATA_WIDTH) c = new();
    c.data     = this.data;
    c.offset   = this.offset;
    c.size     = this.size;
    c.err      = this.err;
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
  mailbox msAPB_mailbox; // → scoreboard
  mailbox mcAPB_mailbox; // → checker

  time t_start, t_end;

  task run();
    APB_pack2 tr;
    forever begin
      // Espera fase SETUP
      @(posedge vif.clk iff (vif.psel || vif.penable));
      tr = new();
      t_start   = $time;
      tr.dir       = (vif.pwrite) ? APB_WRITE : APB_READ;
      tr.addr      = vif.paddr;
      tr.wdata     = vif.pwdata;
      tr.wait_states = 0;

      // Fase ACCESS: contar wait states hasta completar
      while (!(vif.penable && vif.pready)) begin
        @(posedge vif.clk);
        if (vif.penable && !vif.pready) tr.wait_states++;
      end;
      t_end  = $time;
      tr.t_time = t_end - t_start;
      tr.slverr = vif.pslverr;
      if (tr.dir == APB_READ) tr.rdata = vif.prdata;

      // Publicar a ambos consumidores
      msAPB_mailbox.put(tr.clone());
      mcAPB_mailbox.put(tr.clone());
    end
  endtask

// ====================================================
// MD Monitor (para MD_if, lado TX del Aligner)
// - Muestrea *solo* en handshake válido: md_tx_valid && md_tx_ready
// - Captura data/offset/size y md_tx_err
// - Publica clones a msMD_mailbox (scoreboard) y mcMD_mailbox (checker)
// ====================================================
class MD_Monitor #(int ALGN_DATA_WIDTH = 32);

  // Interfaz virtual (parametrizada igual que tu MD_if)
  virtual MD_if #(ALGN_DATA_WIDTH) vif;
  typedef pack2#(.ALGN_DATA_WIDTH(ALGN_DATA_WIDTH)) pack2_t;

  // Mailboxes con los nombres requeridos
  mailbox  #(pack2_t) msMD_mailbox; // → scoreboard
  mailbox  #(pack2_t) mcMD_mailbox; // → checker

  bit [ALGN_DATA_WIDTH-1:0] prev_data;

  function new(virtual MD_if #(ALGN_DATA_WIDTH) vif,
               mailbox msMD_mailbox,
               mailbox mcMD_mailbox);
    this.vif          = vif;
    this.msMD_mailbox = msMD_mailbox;
    this.mcMD_mailbox = mcMD_mailbox;
  endfunction

  task run();
    MD_pack2#(pack2_t) tr;
    forever begin
      @(posedge vif.clk);
      vif.md_tx_ready = 1'b1; // ready siempre activo
      if (vif.md_tx_valid) begin
        fork
          begin: Captura_de_datos
           tr = new();
           tr.data     <= vif.md_tx_data;
           tr.offset   <= vif.md_tx_offset;
           tr.size     <= vif.md_tx_size;
           tr.err      <= vif.md_tx_err;
           tr.t_sample <= $time;
           tr.md_t_time <= 0;
          end
          begin: Cuenta_de_tiempo
            @(posedge vif.clk);
            while (vif.md_tx_data == prev_data) begin
              @(posedge vif.clk); tr.md_t_time++;
            end
          end

        join_any
        prev_data = vif.md_tx_data;
        // Publicar a ambos consumidores
        msMD_mailbox.put(tr.clone());
        mcMD_mailbox.put(tr.clone());
      end
    end
  endtask

endclass


endclass
