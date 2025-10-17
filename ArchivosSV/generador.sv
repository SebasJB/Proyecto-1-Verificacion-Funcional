// ============================================================================
// Enum de tipos de prueba
// Define los 4 modos en que se ejecutará la generación de estímulos:
typedef enum logic [1:0] { CASO_GENERAL, ESTRES, ERRORES, APB_CFG } test_e;

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
    if (mode==CASO_GENERAL) { len_n_md inside {[500:1000]}; len_n_apb inside {[350:700]}; }
    if (mode==ESTRES)       { len_n_md inside {[500:900]};  len_n_apb inside {[300:600]}; }
    if (mode==APB_CFG)      { len_n_md inside {[500:1000]}; len_n_apb inside {[300:600]}; }
    if (mode==ERRORES)      { len_n_md == 600;              len_n_apb == 600; }
  }

  function new(test_e m = CASO_GENERAL);   // Constructor
    mode = m;
  endfunction
endclass

// ============================================================================
// MD_pack1: item del GENERATOR -> drivers/scoreboard/checker (tráfico MD)
// ============================================================================
class MD_pack1 #(parameter int ALGN_DATA_WIDTH = 32);

  // Tamaños para offset/size (idénticos al pack1 original)
  localparam int ALGN_OFFSET_WIDTH = 2;
  localparam int ALGN_SIZE_WIDTH   = 3;

  // Contexto (modo de prueba)
  test_e mode;

  // ---- Señales MD hacia el DUT ----
  rand logic [ALGN_DATA_WIDTH-1:0]   md_data;
  rand logic [ALGN_OFFSET_WIDTH-1:0] md_offset;     // 0..3
  rand logic [ALGN_SIZE_WIDTH-1:0]   md_size;       // {0,1,2,4} codificado en 3b
  rand int unsigned                  trans_cycles;  // gap entre beats

  // ---- Variables auxiliares/decisión (mismo modelo que el pack1 original) ----
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
  endfunction

  // ========================= util/print =========================
  function void print(string tag="");
    $display("[%0t] %s MD_pack1 mode=%0d | MD: data=%h size=%0d off=%0d gap=%0d",
      $time, tag, mode, md_data, md_size, md_offset, trans_cycles);
  endfunction

endclass

// ============================================================================
// APB_pack1: item del GENERATOR -> drivers/scoreboard/checker (tráfico APB)
// ============================================================================
class APB_pack1;

  // Contexto (modo de prueba)
  test_e mode;

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
  constraint c_apb_conf_gen    { if (mode==CASO_GENERAL || mode==APB_CFG || mode==ERRORES) conf_cycles inside {[1:10]}; }
  constraint c_apb_conf_stress { if (mode==ESTRES)                                         conf_cycles inside {[1:4]}; }

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
  endfunction

  // ========================= util/print =========================
  function void print(string tag="");
    $display("[%0t] %s APB_pack1 mode=%0d | APB: %s addr=%h data=%h gap=%0d | aux size=%0d off=%0d vld=%0b",
      $time, tag, mode, (Esc_Lec_APB ? "WR" : "RD"), APBaddr, APBdata, conf_cycles,
      apb_size_aux, apb_off_aux, apb_addr_valid);
  endfunction

endclass


// ============================================================================
// GENERATOR:
// - Lee PACK3 del TEST, crea PACK1 por ítem, fija
//   el modo, llama randomize(), toma cobertura y envía el ítem a drivers/scoreboard/checker.
// - También realiza inyecciones deterministas de APB en APB_CFG y ERRORES.
// ============================================================================
class generator #(parameter int ALGN_DATA_WIDTH = 32);

  typedef MD_pack1#(.ALGN_DATA_WIDTH(ALGN_DATA_WIDTH)) MD_pack1_t;
  typedef APB_pack1                                     APB_pack1_t;

  // Mailboxes hacia drivers / scoreboard / checker y TEST->GENERATOR
mailbox #(MD_pack1_t)  gdMD_mailbox, gsMD_mailbox; //gcMD_mailbox;
mailbox #(APB_pack1_t) gdAPB_mailbox, gsAPB_mailbox; //gcAPB_mailbox;
mailbox #(pack3)       tg_mailbox;


  // Covergroup para MD: cubre size, offset y validez (70/30 o 100% legal en estrés)
//  covergroup cgg_md with function sample(int size, int offset, bit is_valid);
//    option.per_instance = 1;
//    cp_sz : coverpoint size   { bins s[] = {0,1,2,4}; }
//    cp_of : coverpoint offset { bins o[] = {[0:3]}; }
//    cp_v  : coverpoint is_valid { bins ok={1}; bins bad={0}; }
//    cross cp_sz, cp_of;
//  endgroup
//  cgg_md cg_md; // handle del covergroup

  // Covergroup para APB: cubre dirección, tipo (RD/WR), validez de dirección
  // y los campos embebidos (size/offset) que viajan dentro de APBdata
//  covergroup cgg_apb with function sample(logic [15:0] addr, bit wr, bit addr_valid, int apb_size, int apb_off);
//    option.per_instance = 1;
//    cp_dir : coverpoint addr { bins CTRL={16'h0000}; bins STAT={16'h000C};
//                               bins IRQE={16'h00F0}; bins IRQ={16'h00F4}; bins OTH=default; }
//    cp_wr  : coverpoint wr   { bins RD={0}; bins WR={1}; }
//    cp_vld : coverpoint addr_valid { bins V={1}; bins IV={0}; }
//    cp_as  : coverpoint apb_size { bins s[] = {[0:7]}; }
//    cp_ao  : coverpoint apb_off  { bins o[] = {[0:3]}; }
//    cross cp_dir, cp_wr;
//  endgroup
//  cgg_apb cg_apb; // handle del covergroup

  // Constructor: conecta mailboxes y construye covergroups
  function new(
    mailbox #(MD_pack1_t)  m_md,
    mailbox #(APB_pack1_t) m_apb,
    mailbox #(MD_pack1_t)  m_scbd_md,
    mailbox #(APB_pack1_t) m_scbd_apb,
    mailbox #(pack3)       m_tg = null
  );
    gdMD_mailbox  = m_md;     gdAPB_mailbox = m_apb;
    gsMD_mailbox  = m_scbd_md; 
    gsAPB_mailbox = m_scbd_apb; 
    tg_mailbox    = m_tg;
   // cg_md  = new();
   // cg_apb = new();
  endfunction

  // clone solo campos necesarios para drivers/scoreboard/checker
  function automatic MD_pack1_t clone_md(MD_pack1_t s);
    MD_pack1_t d = new();
    d.md_data = s.md_data; d.md_size = s.md_size; d.md_offset = s.md_offset; d.trans_cycles = s.trans_cycles;
    d.mode    = s.mode;
    return d;
  endfunction
  
  function automatic APB_pack1_t clone_apb(APB_pack1_t s);
    APB_pack1_t d = new();
    d.APBaddr = s.APBaddr; d.APBdata = s.APBdata; d.Esc_Lec_APB = s.Esc_Lec_APB; d.conf_cycles = s.conf_cycles;
    d.mode = s.mode;
    return d;
  endfunction

  // Envía el ítem a drivers y réplicas a scoreboard/checker por sus mailboxes
  task automatic fanout_md(MD_pack1_t it);
    gdMD_mailbox.put(it);
    gsMD_mailbox.put(clone_md(it));
  endtask
  
  task automatic fanout_apb(APB_pack1_t it);
    gdAPB_mailbox.put(it);
    gsAPB_mailbox.put(clone_apb(it));
  endtask

  // Bucle principal: espera PACK3, genera secuencias por modo, cobertura y fanout
  task run();
    pack3 cmd;
    forever begin
      tg_mailbox.get(cmd);

      case (cmd.mode)

        // 1) CASO_GENERAL: MD y APB en paralelo, 70/30 en legalidad
        CASO_GENERAL: begin
          fork
            begin //: GEN_MD
              for (int i=0; i<cmd.len_n_md; i++) begin
                MD_pack1_t it = new(); it.mode = cmd.mode;
                it.randomize(); it.post_randomize();
                //cg_md.sample(it.md_size, it.md_offset, it.md_use_valid);
                fanout_md(it);
              end
            end
            begin //: GEN_APB
              for (int j=0; j<cmd.len_n_apb; j++) begin
                APB_pack1_t it = new(); it.mode = cmd.mode;
                it.randomize(); it.post_randomize();
                //cg_apb.sample(it.APBaddr, it.Esc_Lec_APB, it.apb_addr_valid,
                 //             it.apb_size_aux & 3'h7, it.apb_off_aux & 2'h3);
                fanout_apb(it);
              end
            end
          join
        end

        // 2) ESTRES: MD fuerza md_code=40 (size=4, off=0) y gaps cortos; APB con gaps cortos
        ESTRES: begin
          fork
            begin //: GEN_MD
              for (int i=0; i<cmd.len_n_md; i++) begin
                MD_pack1_t it = new(); it.mode = cmd.mode;
                it.randomize(); it.post_randomize();
                //cg_md.sample(it.md_size, it.md_offset, 1'b1);
                fanout_md(it);
              end
            end
            begin //: GEN_APB
              for (int j=0; j<cmd.len_n_apb; j++) begin
                APB_pack1_t it = new(); it.mode = cmd.mode;
                it.randomize(); it.post_randomize();
                //cg_apb.sample(it.APBaddr, it.Esc_Lec_APB, it.apb_addr_valid,
                 //             it.apb_size_aux & 3'h7, it.apb_off_aux & 2'h3);
                fanout_apb(it);
              end
            end
          join
        end

        // 3) ERRORES: 600 transacciones MD/APB, 40/60 válidas/ inválidas
        ERRORES: begin
          fork
            begin //: GEN_MD_ERR
              for (int i=0; i<cmd.len_n_md;  i++) begin
                MD_pack1_t it_md = new(); it_md.mode = cmd.mode;
                it_md.randomize(); it_md.post_randomize();
                //cg_md.sample(it_md.md_size, it_md.md_offset, !it_md.md_err_illegal);
                fanout_md(it_md);
              end
            end
            begin //: GEN_APB_ERR
              for (int i=0; i<cmd.len_n_apb; i++) begin
                APB_pack1_t it_apb = new(); it_apb.mode = cmd.mode;
                it_apb.randomize(); it_apb.post_randomize();
          
                if (i == 550) begin
                  it_apb.APBaddr        = 16'h0000;
                  it_apb.Esc_Lec_APB    = 1'b1;
                  it_apb.APBdata        = 32'h0001_0000;
                  it_apb.apb_addr_valid = 1'b1;  // ✅ asegura coherencia con cobertura/scoreboard
                  //cg_apb.sample(it_apb.APBaddr, it_apb.Esc_Lec_APB, 1'b1, 0, 0);
                end else begin
                  if (it_apb.Esc_Lec_APB && it_apb.APBaddr==16'h0000) it_apb.APBdata[16]=1'b0;
                  //cg_apb.sample(it_apb.APBaddr, it_apb.Esc_Lec_APB, it_apb.apb_addr_valid,
                  //              it_apb.apb_size_aux & 3'h7, it_apb.apb_off_aux & 2'h3);
                end
                fanout_apb(it_apb);
              end
            end
          join
        end

        // 4) APB_CFG: MD 70/30 y APB con accesos deterministas a IRQE/IRQ en ciertos ciclos
        APB_CFG: begin
          fork
            // ===== MD =====
            begin //: GEN_MD
              for (int i=0; i<cmd.len_n_md; i++) begin
                MD_pack1_t it_md = new(); it_md.mode = cmd.mode;
                it_md.randomize();
                it_md.post_randomize();
               // cg_md.sample(it_md.md_size, it_md.md_offset, it_md.md_use_valid);
                fanout_md(it_md);
              end
            end
            // ===== APB =====
            // ===== APB =====
            begin //: GEN_APB
              for (int j=0; j<cmd.len_n_apb; j++) begin
                APB_pack1_t it_apb = new(); it_apb.mode = cmd.mode;
                it_apb.randomize();
                it_apb.post_randomize();
            
                //bit vld = it_apb.apb_addr_valid; // valor por defecto
            
                // Inyecciones deterministas sobre IRQE/IRQ (forzar dirección válida)
                case (j)
                  50: begin
                    it_apb.APBaddr        = 16'h00F0;  // IRQE
                    it_apb.Esc_Lec_APB    = 1'b1;      // WRITE
                    it_apb.apb_addr_valid = 1'b1;      // coherencia total 
                  //  vld                   = 1'b1;
                    it_apb.APBdata[4:0]   = 5'h1F;     // SET
                  end
                  60: begin
                    it_apb.APBaddr        = 16'h00F0;  // IRQE
                    it_apb.Esc_Lec_APB    = 1'b1;
                    it_apb.apb_addr_valid = 1'b1;
                  //  vld                   = 1'b1;
                    it_apb.APBdata[4:0]   = 5'h00;     // CLR
                  end
                  100: begin
                    it_apb.APBaddr        = 16'h00F4;  // IRQ
                    it_apb.Esc_Lec_APB    = 1'b1;
                    it_apb.apb_addr_valid = 1'b1;
                   // vld                   = 1'b1;
                    it_apb.APBdata[4:0]   = 5'h1F;     // SET IRQ flags
                  end 
                  default: ; // sin cambios
                endcase
            
               // cg_apb.sample(it_apb.APBaddr, it_apb.Esc_Lec_APB, vld,
               //               it_apb.apb_size_aux & 3'h7, it_apb.apb_off_aux & 2'h3);
                fanout_apb(it_apb);
              end
            end

          join
        end

        // si llega un modo desconocido, se procede a CASO_GENERAL
        default: begin
          pack3 t = new();
          $display("[%0t] GENERATOR: modo desconocido, ejecutando CASO_GENERAL", $time);
          t.randomize();
          tg_mailbox.put(t);
        end
      endcase
    end
  endtask

endclass
