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
  rand test_e mode;
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
// PACK1: item del GENERATOR hacia drivers/scoreboard/checker
// - Este es el "paquete" que viaja por mailboxes hacia drivers, scoreboard
//   y checker. Contiene las señales MD/APB y todas las constraints por modo.
class pack1 #(parameter int ALGN_DATA_WIDTH = 32);

  localparam int ALGN_OFFSET_WIDTH = 2;  // - OFFSET ocupa 2 bits (rangos 0..3)
  localparam int ALGN_SIZE_WIDTH   = 3;  // - SIZE se codifica en 3 bits (usamos los códigos {0,1,2,4})

  test_e mode;                            // Contexto de ejecución (prueba actual). Lo setea el GENERATOR antes de randomize().

  // ---- MD (entrada al DUT) ----
  rand logic [ALGN_DATA_WIDTH-1:0]   md_data;      // dato de entrada al DUT
  rand logic [ALGN_OFFSET_WIDTH-1:0] md_offset;    // offset de byte: 0..3
  rand logic [ALGN_SIZE_WIDTH-1:0]   md_size;      // tamaño en bytes: {0,1,2,4}
  rand int unsigned                  trans_cycles; // tiempo entre transacciones MD

  // ---- APB (acceso a registros) ----
  rand logic [15:0]                  APBaddr;      // dirección de registro
  rand logic [31:0]                  APBdata;      // datos de acceso APB
  rand bit                           Esc_Lec_APB;  // 1=WRITE, 0=READ
  rand int unsigned                  conf_cycles;  // tiempo entre cfg APB

  // ---- Auxiliares APB ----
  // - apb_size_aux/apb_off_aux contienen size/offset que se embeben en APBdata.
  rand int unsigned                  apb_size_aux; // {0,1,2,4}
  rand int unsigned                  apb_off_aux;  // 0..3

  // --- MD (general/estrés) ---
  rand int md_code;                                // - md_code: representa (10*size + offset) para mapear fácil size/offset          
  rand bit md_use_valid;                           // - md_use_valid: decide si elegir un par válido (70%) o inválido (30%)

  // --- MD (errores) ---
  rand int md_err_code;            // - En ERRORES usamos md_err_code con una mezcla 40/60 (válido/inválido)       
  rand bit md_err_illegal;         // (válido/inválido)

  // --- APB ---
  rand bit           apb_addr_valid;                // - apb_addr_valid: 50% direcciones válidas   
  rand bit           apb_use_valid2;                // - apb_use_valid2: 70/30 para elegir size y offset válidos o inválidos    
  rand int           apb_code;                      // - apb_code: igual idea que md_code pero para APBdata embebido    

  // ---- Listas fijas ----
  // - Conjuntos explícitos de pares válidos/ inválidos: code = 10*size + offset
  static int unsigned valid_pairs  [$] = '{10,11,12,13,20,22,40};
  static int unsigned invalid_pairs[$] = '{00,01,02,03,21,23,30,31,32,33,41,42,43};

  // ========================= Constraints =========================
  // Selección 70/30 de legalidad en GENERAL/APB_CFG, y 100% legal en ESTRES
  constraint c_md_use_valid {
    if (mode==CASO_GENERAL || mode==APB_CFG) md_use_valid dist {1:=70, 0:=30};
    else if (mode==ESTRES)                   md_use_valid == 1;
  }

  // En ESTRES se fuerza (size=4, off=0) → md_code=40; en otros modos se elige
  // de las listas según md_use_valid
  constraint c_md_code {
    if (mode==ESTRES) {
      md_code == 40;
    } else {
      if (md_use_valid) md_code inside { valid_pairs };
      else              md_code inside { invalid_pairs };
    }
  }

  // Mapear md_code a (md_size, md_offset) cuando NO estamos en ERRORES
  constraint c_md_map {
    if (mode!=ERRORES) {
      solve md_code before md_size, md_offset;
      md_size   == (md_code/10);
      md_offset == (md_code%10);
    }
  }

  // Gaps MD por modo:
  constraint c_md_gap_gen    { if (mode==CASO_GENERAL || mode==APB_CFG) trans_cycles inside {[0:5]}; }
  constraint c_md_gap_stress { if (mode==ESTRES)                          trans_cycles inside {[0:1]}; }
  constraint c_md_gap_err    { if (mode==ERRORES)                         trans_cycles inside {[0:5]}; }

  // Mezcla 40/60 (válidas/ inválidas) para md_err_code en modo ERRORES
  constraint c_md_err_ratio  { if (mode==ERRORES) md_err_illegal dist {1:=60, 0:=40}; }
  constraint c_md_err_pick   {
    if (mode==ERRORES) {
      if (md_err_illegal) md_err_code inside { invalid_pairs };
      else                md_err_code inside { valid_pairs   };
    }
  }
  // Mapeo directo en ERRORES: md_err_code → md_size/md_offset
  constraint c_md_err_map    {
    if (mode==ERRORES) {
      solve md_err_code before md_size, md_offset;
      md_size   == (md_err_code/10);
      md_offset == (md_err_code%10);
    }
  }

  // APB: 50% direcciones válidas y 50% inválidas (fuera)
  constraint c_apb_addr {
    apb_addr_valid dist {1:=50, 0:=50};
    if (apb_addr_valid) APBaddr inside {16'h0000,16'h000C,16'h00F0,16'h00F4};
    else                !(APBaddr inside {16'h0000,16'h000C,16'h00F0,16'h00F4});
  }

  // 50/50 entre escritura/lectura
  constraint c_apb_wr     { Esc_Lec_APB dist {1:=50, 0:=50}; }

  // 70/30 para (size,offset) embebidos en APBdata (apb_code)
  constraint c_apb_code   {
    apb_use_valid2 dist {1:=70, 0:=30};
    if (apb_use_valid2) apb_code inside { valid_pairs };
    else                apb_code inside { invalid_pairs };
  }

  // Mapeo de apb_code
  constraint c_apb_map    {
    solve apb_code before apb_size_aux, apb_off_aux;
    apb_size_aux == (apb_code/10);
    apb_off_aux  == (apb_code%10);
  }

  // Gaps APB por modo
  constraint c_apb_conf_gen    { if (mode==CASO_GENERAL || mode==APB_CFG || mode==ERRORES) conf_cycles inside {[1:10]}; }
  constraint c_apb_conf_stress { if (mode==ESTRES)                                         conf_cycles inside {[1:4]}; }

  // ========================= post_randomize =========================
  // - ins_apb(): función para insertar SIZE (bits [2:0]) y OFFSET (bits [9:8])
  //   dentro de APBdata a partir de apb_size_aux/apb_off_aux.
  function logic [31:0] ins_apb(logic [31:0] base, int apb_size, int apb_off);
    logic [31:0] tmp;
    tmp = base & ~32'h00000307;            // limpia [9:8] y [2:0]
    tmp |= {29'b0, (apb_size[2:0])};       // SIZE -> [2:0]
    tmp |= {22'b0, (apb_off[1:0]), 8'b0};  // OFFSET -> [9:8]
    return tmp;
  endfunction

  // - post_randomize()
  //   * Rellena md_data si vino '0 
  //   * Construye APBdata con SIZE/OFFSET embebidos.
  //   * Para IRQ/IRQE (0x00F4/0x00F0), limita la escritura a [4:0].
  function void post_randomize();
    if (md_data==='0) md_data = $urandom();
    APBdata = ins_apb($urandom(), apb_size_aux, apb_off_aux);
    if (Esc_Lec_APB && (APBaddr==16'h00F4 || APBaddr==16'h00F0)) begin
      APBdata[31:5] = '0;
      APBdata[4:0]  = $urandom_range(0,31);
    end
  endfunction

  // print del paquete
  function void print(string tag="");
    $display("[%0t] %s pack1 mode=%0d | MD: data=%h size=%0d off=%0d gap=%0d | APB: %s addr=%h data=%h gap=%0d",
      $time, tag, mode, md_data, md_size, md_offset, trans_cycles,
      (Esc_Lec_APB ? "WR" : "RD"), APBaddr, APBdata, conf_cycles);
  endfunction
endclass

// ============================================================================
// GENERATOR:
// - Lee PACK3 del TEST, crea PACK1 por ítem, fija
//   el modo, llama randomize(), toma cobertura y envía el ítem a drivers/scoreboard/checker.
// - También realiza inyecciones deterministas de APB en APB_CFG y ERRORES.
// ============================================================================
class generator #(parameter int ALGN_DATA_WIDTH = 32);

  typedef pack1#(.ALGN_DATA_WIDTH(ALGN_DATA_WIDTH)) pack1_t;

  // Mailboxes hacia drivers / scoreboard / checker y TEST->GENERATOR
  mailbox #(pack1_t) gdMD_mailbox, gdAPB_mailbox;
  mailbox #(pack1_t) gsMD_mailbox, gsAPB_mailbox;
  mailbox #(pack1_t) gcMD_mailbox, gcAPB_mailbox;
  mailbox #(pack3)   tg_mailbox;

  // Covergroup para MD: cubre size, offset y validez (70/30 o 100% legal en estrés)
  covergroup cg_md with function sample(int size, int offset, bit is_valid);
    option.per_instance = 1;
    cp_sz : coverpoint size   { bins s[] = {0,1,2,4}; }
    cp_of : coverpoint offset { bins o[] = {[0:3]}; }
    cp_v  : coverpoint is_valid { bins ok={1}; bins bad={0}; }
    cross cp_sz, cp_of;
  endgroup
  cg_md cg_md; // handle del covergroup

  // Covergroup para APB: cubre dirección, tipo (RD/WR), validez de dirección
  // y los campos embebidos (size/offset) que viajan dentro de APBdata
  covergroup cg_apb with function sample(logic [15:0] addr, bit wr, bit addr_valid, int apb_size, int apb_off);
    option.per_instance = 1;
    cp_dir : coverpoint addr { bins CTRL={16'h0000}; bins STAT={16'h000C};
                               bins IRQE={16'h00F0}; bins IRQ={16'h00F4}; bins OTH=default; }
    cp_wr  : coverpoint wr   { bins RD={0}; bins WR={1}; }
    cp_vld : coverpoint addr_valid { bins V={1}; bins IV={0}; }
    cp_as  : coverpoint apb_size { bins s[] = {[0:7]}; }
    cp_ao  : coverpoint apb_off  { bins o[] = {[0:3]}; }
    cross cp_dir, cp_wr;
  endgroup
  cg_apb cg_apb; // handle del covergroup

  // Constructor: conecta mailboxes y construye covergroups
  function new(
    mailbox #(pack1_t) m_md,
    mailbox #(pack1_t) m_apb,
    mailbox #(pack1_t) m_scbd_md,
    mailbox #(pack1_t) m_chck_md,
    mailbox #(pack1_t) m_scbd_apb,
    mailbox #(pack1_t) m_chck_apb,
    mailbox #(pack3)   m_tg = null
  );
    gdMD_mailbox  = m_md;    gdAPB_mailbox = m_apb;
    gsMD_mailbox  = m_scbd_md; gcMD_mailbox  = m_chck_md;
    gsAPB_mailbox = m_scbd_apb; gcAPB_mailbox = m_chck_apb;
    tg_mailbox    = m_tg;

    cg_md  = new();
    cg_apb = new();
  endfunction

  // clone solo campos necesarios para drivers/scoreboard/checker
  function automatic pack1_t clone(pack1_t s);
    pack1_t d = new();
    d.md_data = s.md_data; d.md_size = s.md_size; d.md_offset = s.md_offset; d.trans_cycles = s.trans_cycles;
    d.APBaddr = s.APBaddr; d.APBdata = s.APBdata; d.Esc_Lec_APB = s.Esc_Lec_APB; d.conf_cycles = s.conf_cycles;
    return d;
  endfunction

  // Envía el ítem a drivers y réplicas a scoreboard/checker por sus mailboxes
  task automatic fanout_to_all(pack1_t it, bit to_md, bit to_apb);
    if (to_md) begin
      gdMD_mailbox.put(it);
      gsMD_mailbox.put(clone(it));
      gcMD_mailbox.put(clone(it));
    end
    if (to_apb) begin
      gdAPB_mailbox.put(it);
      gsAPB_mailbox.put(clone(it));
      gcAPB_mailbox.put(clone(it));
    end
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
            begin : GEN_MD
              for (int i=0; i<cmd.len_n_md; i++) begin
                pack1_t it = new(); it.mode = cmd.mode;
                it.randomize(); 
                it.post_randomize();
                cg_md.sample(it.md_size, it.md_offset, it.md_use_valid);
                fanout_to_all(it, 1, 0);
              end
            end
            begin : GEN_APB
              for (int j=0; j<cmd.len_n_apb; j++) begin
                pack1_t it = new(); it.mode = cmd.mode;
                it.randomize();
                it.post_randomize();
                cg_apb.sample(it.APBaddr, it.Esc_Lec_APB, it.apb_addr_valid,
                              it.apb_size_aux & 3'h7, it.apb_off_aux & 2'h3);
                fanout_to_all(it, 0, 1);
              end
            end
          join
        end

        // 2) ESTRES: MD fuerza md_code=40 (size=4, off=0) y gaps cortos; APB con gaps cortos
        ESTRES: begin
          fork
            begin : GEN_MD
              for (int i=0; i<cmd.len_n_md; i++) begin
                pack1_t it = new(); it.mode = cmd.mode;
                it.randomize();
                it.post_randomize();
                cg_md.sample(it.md_size, it.md_offset, 1'b1); 
                fanout_to_all(it, 1, 0);
              end
            end
            begin : GEN_APB
              for (int j=0; j<cmd.len_n_apb; j++) begin
                pack1_t it = new(); it.mode = cmd.mode;
                it.randomize();
                it.post_randomize();
                cg_apb.sample(it.APBaddr, it.Esc_Lec_APB, it.apb_addr_valid,
                              it.apb_size_aux & 3'h7, it.apb_off_aux & 2'h3);
                fanout_to_all(it, 0, 1);
              end
            end
          join
        end

        // 3) ERRORES: 600 transacciones MD/APB, 40/60 válidas/ inválidas
        ERRORES: begin
          fork
            begin : GEN_MD_ERR
              for (int i=0; i<600; i++) begin
                pack1_t it_md = new(); it_md.mode = cmd.mode;
                it_md.randomize();
                it_md.post_randomize();
                cg_md.sample(it_md.md_size, it_md.md_offset, !it_md.md_err_illegal);
                fanout_to_all(it_md, 1, 0);
              end
            end

            begin : GEN_APB_ERR
              for (int i=0; i<600; i++) begin
                pack1_t it_apb = new(); it_apb.mode = cmd.mode;
                it_apb.randomize();
                it_apb.post_randomize();
                // en i==550 escribir CTRL.CLR[16]=1
                if (i == 550) begin
                  it_apb.APBaddr     = 16'h0000;      // CTRL
                  it_apb.Esc_Lec_APB = 1'b1;          // WRITE
                  it_apb.APBdata     = 32'h0001_0000; // CLR[16]=1
                  cg_apb.sample(it_apb.APBaddr, it_apb.Esc_Lec_APB, 1'b1, 0, 0);
                end
                else begin
                  // Política: fuera de i==550, evitar escribir '1' en CLR[16]
                  if (it_apb.Esc_Lec_APB && it_apb.APBaddr==16'h0000) it_apb.APBdata[16]=1'b0;
                  cg_apb.sample(it_apb.APBaddr, it_apb.Esc_Lec_APB, it_apb.apb_addr_valid,
                                it_apb.apb_size_aux & 3'h7, it_apb.apb_off_aux & 2'h3);
                end

                fanout_to_all(it_apb, 0, 1);
              end
            end
          join
        end

        // 4) APB_CFG: MD 70/30 y APB con accesos deterministas a IRQE/IRQ en ciertos ciclos
        APB_CFG: begin
          fork
            begin : GEN_MD
              for (int i=0; i<cmd.len_n_md; i++) begin
                pack1_t it = new(); it.mode = cmd.mode;
                it.randomize();
                it.post_randomize();
                cg_md.sample(it.md_size, it.md_offset, it.md_use_valid);
                fanout_to_all(it, 1, 0);
              end
            end

            begin : GEN_APB
              for (int j=0; j<cmd.len_n_apb; j++) begin
                pack1_t it = new(); it.mode = cmd.mode;
                it.randomize();
                it.post_randomize();
                bit vld = it.apb_addr_valid; // por defecto, validez de dirección según constraints

                // Inyecciones deterministas sobre IRQE/IRQ
                case (j)
                  50  : begin it.APBaddr=16'h00F0; it.Esc_Lec_APB=1; vld=1; it.APBdata[4:0]=5'h1F; end // IRQE set
                  60  : begin it.APBaddr=16'h00F0; it.Esc_Lec_APB=1; vld=1; it.APBdata[4:0]=5'h00; end // IRQE clr
                  100 : begin it.APBaddr=16'h00F4; it.Esc_Lec_APB=1; vld=1; it.APBdata[4:0]=5'h1F; end // IRQ  set
                  default: begin end
                endcase

                cg_apb.sample(it.APBaddr, it.Esc_Lec_APB, vld,
                              it.apb_size_aux & 3'h7, it.apb_off_aux & 2'h3);
                fanout_to_all(it, 0, 1);
              end
            end
          join
        end

        // si llega un modo desconocido, se reinyecta CASO_GENERAL
        default: begin
          $display("[%0t] GENERATOR: modo desconocido, ejecutando CASO_GENERAL", $time);
          pack3 tmp = new(CASO_GENERAL);
          tmp.randomize();
          tg_mailbox.put(tmp);
        end
      endcase
    end
  endtask

endclass
