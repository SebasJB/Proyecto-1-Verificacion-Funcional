
// ====================================================
// Tipos básicos
// ====================================================
typedef enum logic { APB_READ=0, APB_WRITE=1 } apb_trans_type;
typedef enum logic [1:0] { CASO_GENERAL, ESTRES, ERRORES, APB_CFG } test_e; // Define los 4 modos en que se ejecutará la generación de estímulos:
typedef enum int {MD_PACKED_OK, MD_PACKED_PARTIAL} md_pack_status_e;
// ----------------------------------------------------

// ============================================================================
// MD_pack1: item del GENERATOR -> drivers/scoreboard/checker (tráfico MD)
// ============================================================================
class MD_pack1 #(parameter int ALGN_DATA_WIDTH = 32);

  // Tamaños para offset/size (idénticos al pack1 this)
  localparam int ALGN_OFFSET_WIDTH = 2;
  localparam int ALGN_SIZE_WIDTH   = 3;
  event md_cov_ev; //evento para covergroups

  test_e mode;      // tipo de prueba
  int    txn_num;   // número de transacción

  // ---- Señales MD hacia el DUT ----
  rand logic [ALGN_DATA_WIDTH-1:0]   md_data;
  rand logic [ALGN_OFFSET_WIDTH-1:0] md_offset;     // 0..3
  rand logic [ALGN_SIZE_WIDTH-1:0]   md_size;       // {0,1,2,4} codificado en 3b
  rand int unsigned                  trans_cycles;  // gap entre beats

  // ---- Variables auxiliares/decisión (mismo modelo que el pack1 this) ----
  // General / estrés
  rand int md_code;           // 10*size + offset
  rand bit md_use_valid;      // 70% válidos / 30% inválidos

  // Errores
  rand int md_err_code;       // 10*size + offset
  rand bit md_err_illegal;    // 60% inválidas vs 40% válidas

  // ---- Listas fijas de pares (code = 10*size + offset) ----
  static int unsigned valid_pairs  [$] = '{10,11,12,13,20,22,40};
  static int unsigned invalid_pairs[$] = '{00,01,02,03,21,23,30,31,32,33,41,42,43};

  // ========================= Constraints (MD) =========================
  // Selección 70/30 de legalidad en GENERAL/APB_CFG, y 100% legal en ESTRES
  constraint c_md_use_valid {
    if (mode==CASO_GENERAL || mode==APB_CFG) md_use_valid dist {1:=70, 0:=30};
    else if (mode==ESTRES)                   md_use_valid == 1;
  }

  // En estrés fuerza (size=4, off=0) → md_code=40; en otros modos elige por lista
  constraint c_md_code {
    if (mode==ESTRES) {
      md_code == 40;
    } else {
      if (md_use_valid) md_code inside { valid_pairs };
      else              md_code inside { invalid_pairs };
    }
  }

  // Mapear md_code -> (md_size, md_offset) cuando NO estamos en ERRORES
  constraint c_md_order {
    solve md_code before md_size, md_offset;
  }
  constraint c_md_map {
    if (mode!=ERRORES) {
      md_size   == (md_code/10);
      md_offset == (md_code%10);
    }
  }

  // Gaps MD por modo
  constraint c_md_gap_gen    { if (mode==CASO_GENERAL || mode==APB_CFG) trans_cycles inside {[0:5]}; }
  constraint c_md_gap_stress { if (mode==ESTRES)                          trans_cycles inside {[0:1]}; }
  constraint c_md_gap_err    { if (mode==ERRORES)                         trans_cycles inside {[0:5]}; }

  // ERRORES: mezcla 40/60 válidas/ inválidas para md_err_code
  constraint c_md_err_ratio  { if (mode==ERRORES) md_err_illegal dist {1:=60, 0:=40}; }
  constraint c_md_err_pick   {
    if (mode==ERRORES) {
      if (md_err_illegal) md_err_code inside { invalid_pairs };
      else                md_err_code inside { valid_pairs   };
    }
  }
  // Mapeo directo en ERRORES: md_err_code → md_size/md_offset
  constraint c_md_err_order {
    solve md_err_code before md_size, md_offset;
  }
  constraint c_md_err_map {
    if (mode==ERRORES) {
      md_size   == (md_err_code/10);
      md_offset == (md_err_code%10);
    }
  }

  // ========================= post_randomize (MD) =========================
  function void post_randomize();
    if (md_data==='0) md_data = $urandom();
    -> md_cov_ev;
  endfunction

  // ========================= util/print =========================
  function void print(string tag="");
    $display("[%0t] %s MD_pack1 mode=%0d | MD: data=%h size=%0d off=%0d gap=%0d",
      $time, tag, mode, md_data, md_size, md_offset, trans_cycles);
  endfunction

  covergroup cg_md @(md_cov_ev); option.per_instance=1;
    cp_sz : coverpoint md_size   { bins s0={0}; bins s1={1}; bins s2={2}; bins s4={4}; }
    cp_of : coverpoint md_offset { bins o[] = {[0:3]}; }
    x_sz_of: cross cp_sz, cp_of;
  endgroup
  function new(); cg_md = new(); endfunction

endclass

// ============================================================================
// APB_pack1: item del GENERATOR -> drivers/scoreboard/checker (tráfico APB)
// ============================================================================
class APB_pack1;

  // Contexto (modo de prueba)
  test_e mode;      // tipo de prueba
  int    txn_num;   // número de transacción

  // ---- APB (acceso a registros) ----
  rand logic [15:0] APBaddr;
  rand logic [31:0] APBdata;
  rand bit          Esc_Lec_APB;    // 1=WRITE, 0=READ
  rand int unsigned conf_cycles;    // gap entre configuraciones

  // ---- Auxiliares APB (campos embebidos en APBdata) ----
  rand int unsigned apb_size_aux;   // 0,1,2,4
  rand int unsigned apb_off_aux;    // 0..3

  // ---- Decisión APB ----
  rand bit apb_addr_valid;          // 50% válidas / 50% inválidas
  rand bit apb_use_valid2;          // 70/30 (usar pares válidos/ inválidos)
  rand int apb_code;                // 10*size + offset

  // ---- Listas fijas ----
  static int unsigned valid_pairs  [$] = '{10,11,12,13,20,22,40};
  static int unsigned invalid_pairs[$] = '{00,01,02,03,21,23,30,31,32,33,41,42,43};

  event apb_cov_ev; //evento para covergroup
  // ========================= Constraints (APB) =========================
  // Dirección válida 50% dentro del set, inválida 50% fuera
  constraint c_apb_addr {
    apb_addr_valid dist {1:=50, 0:=50};
    if (apb_addr_valid) APBaddr inside {16'h0000,16'h000C,16'h00F0,16'h00F4};
    else                !(APBaddr inside {16'h0000,16'h000C,16'h00F0,16'h00F4});
  }

  // 50/50 entre escritura/lectura
  constraint c_apb_wr { Esc_Lec_APB dist {1:=50, 0:=50}; }

  // 70/30 para (size,offset) embebidos en APBdata (apb_code)
  constraint c_apb_code {
    apb_use_valid2 dist {1:=70, 0:=30};
    if (apb_use_valid2) apb_code inside { valid_pairs };
    else                apb_code inside { invalid_pairs };
  }

  // Mapeo apb_code -> auxiliares
  constraint c_apb_map {
    solve apb_code before apb_size_aux, apb_off_aux;
    apb_size_aux == (apb_code/10);
    apb_off_aux  == (apb_code%10);
  }

  // Gaps APB por modo
  constraint c_apb_conf_gen    { if (mode==CASO_GENERAL || mode==APB_CFG || mode==ERRORES) conf_cycles inside {[1:5]}; }
  constraint c_apb_conf_stress { if (mode==ESTRES)                                         conf_cycles inside {[1:2]}; }

  // ========================= post_randomize (APB) =========================
  // Inserta SIZE (bits [2:0]) y OFFSET (bits [9:8]) en APBdata
  function logic [31:0] ins_apb(logic [31:0] base, int apb_size, int apb_off);
    logic [31:0] tmp;
    tmp = base & ~32'h00000307;            // limpia [9:8] y [2:0]
    tmp |= {29'b0, (apb_size[2:0])};       // SIZE -> [2:0]
    tmp |= {22'b0, (apb_off[1:0]), 8'b0};  // OFFSET -> [9:8]
    return tmp;
  endfunction

  function void post_randomize();
    APBdata = ins_apb($urandom(), apb_size_aux, apb_off_aux);
    if (Esc_Lec_APB && (APBaddr==16'h00F4 || APBaddr==16'h00F0)) begin
      APBdata[31:5] = '0;
      APBdata[4:0]  = $urandom_range(0,31);
    end
    -> apb_cov_ev;
  endfunction

  // ========================= util/print =========================
  function void print(string tag="");
    $display("[%0t] %s APB_pack1 mode=%0d | APB: %s addr=%h data=%h gap=%0d | aux size=%0d off=%0d vld=%0b",
      $time, tag, mode, (Esc_Lec_APB ? "WR" : "RD"), APBaddr, APBdata, conf_cycles,
      apb_size_aux, apb_off_aux, apb_addr_valid);
  endfunction

  covergroup cg_apb @(apb_cov_ev); option.per_instance=1;
    cp_dir: coverpoint APBaddr { bins CTRL={16'h0000}; bins STAT={16'h000C}; bins IRQE={16'h00F0}; bins IRQ={16'h00F4}; }
    cp_wr : coverpoint Esc_Lec_APB { bins RD={0}; bins WR={1}; }
    cp_as : coverpoint apb_size_aux {  bins s0={0}; bins s1={1}; bins s2={2}; bins s4={4}; }
    cp_ao : coverpoint apb_off_aux  { bins o[]={[0:3]}; }
    x_dir_wr: cross cp_dir, cp_wr;
  endgroup
  function new(); cg_apb = new(); endfunction

endclass

// ====================================================
// Transacción MD (lado TX del Aligner, parametrizable)
// Usa el mismo cálculo de anchos que tu interface MD_if
// ====================================================
/*
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
*/



// ====================================================
// APB_pack2: (capturada al completar la transferencia)
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
// ============================================================================
// PACK3: del TEST al GENERATOR
// - Objeto que el TEST envía al GENERATOR para indicar:
//   * tipo de prueba (mode)
//   * cuántas transacciones generar en MD y APB (len_n_md / len_n_apb)
class pack3;
  test_e mode;
  rand int    len_n_md;
  rand int    len_n_apb;

  constraint c_len {
    if (mode==CASO_GENERAL) { len_n_md inside {[700:900]}; len_n_apb inside {[400:600]}; }
    if (mode==ESTRES)       { len_n_md inside {[700:800]};  len_n_apb inside {[400:600]}; }
    if (mode==APB_CFG)      { len_n_md inside {[600:820]}; len_n_apb inside {[400:700]}; }
    if (mode==ERRORES)      { len_n_md == 600;              len_n_apb == 400; }
  }

  function new(test_e m = CASO_GENERAL);   // Constructor
    mode = m;
  endfunction
endclass

class MD_Rx_Sample #(int ALGN_DATA_WIDTH = 32);
  localparam int ALGN_OFFSET_WIDTH = (ALGN_DATA_WIDTH<=8) ? 1 : $clog2(ALGN_DATA_WIDTH/8);
  localparam int ALGN_SIZE_WIDTH = $clog2(ALGN_DATA_WIDTH/8) + 1;
  logic [ALGN_DATA_WIDTH-1:0] data_in;
  logic [ALGN_OFFSET_WIDTH-1:0] offset;
  logic [ALGN_SIZE_WIDTH-1:0] size;
  logic err;      // refleja md_rx_err
  time t_sample; // tiempo del muestreo válido

  function new();
    data_in = '0;
    offset = '0;
    size = '0;
    err = 0;
    t_sample = 0;
  endfunction
endclass

class MD_Tx_Sample #(int ALGN_DATA_WIDTH = 32);
  localparam int ALGN_OFFSET_WIDTH = (ALGN_DATA_WIDTH<=8) ? 1 : $clog2(ALGN_DATA_WIDTH/8);
  localparam int ALGN_SIZE_WIDTH = $clog2(ALGN_DATA_WIDTH/8) + 1;
  logic [ALGN_DATA_WIDTH-1:0] data_out;
  logic [ALGN_OFFSET_WIDTH-1:0] ctrl_offset;
  logic [ALGN_SIZE_WIDTH-1:0] ctrl_size;
  time t_sample; // tiempo del muestreo válido
  function new();
    data_out = '0;
    ctrl_offset = '0;
    ctrl_size = '0;
    t_sample = 0;
  endfunction
endclass

class MD_pack2 #(int ALGN_DATA_WIDTH = 32);
  localparam int ALGN_OFFSET_WIDTH = (ALGN_DATA_WIDTH<=8) ? 1 : $clog2(ALGN_DATA_WIDTH/8);
  localparam int ALGN_SIZE_WIDTH   = $clog2(ALGN_DATA_WIDTH/8) + 1;

  MD_Rx_Sample #(ALGN_DATA_WIDTH) data_in[$]; // refleja md_rx_data que alimentaron esta TX (pueden ser varias y/o fracciones)
  MD_Tx_Sample #(ALGN_DATA_WIDTH) data_out[$]; // refleja md_tx_data que generaron esta TX (pueden ser varias y/o fracciones)

  function MD_pack2 #(ALGN_DATA_WIDTH) clone();
    MD_pack2#(ALGN_DATA_WIDTH) c = new();
    c.data_in = this.data_in;
    c.data_out = this.data_out;
    return c;
  endfunction
endclass
