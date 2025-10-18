// ============================================================================
// GENERATOR:
// - Lee PACK3 del TEST, crea PACK1 por ítem, fija
//   el modo, llama randomize(), toma cobertura y envía el ítem a drivers/scoreboard/checker.
// - También realiza inyecciones deterministas de APB en APB_CFG y ERRORES.
// ============================================================================
class Generator #(parameter int ALGN_DATA_WIDTH = 32);


  // Mailboxes hacia drivers / scoreboard / checker y TEST->GENERATOR
mailbox gdMD_mailbox; //Generador -> drivers : MD
mailbox gsMD_mailbox; //Generador -> scoreboard : MD
mailbox gdAPB_mailbox; //Generador -> drivers : APB
mailbox gsAPB_mailbox; //Generador -> scoreboard : APB
mailbox tg_mailbox; //TEST -> GENERATOR


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


  // clone solo campos necesarios para drivers/scoreboard/checker
  function automatic MD_pack1 clone_md(MD_pack1 s);
    MD_pack1 d = new();
    d.md_data = s.md_data;
    d.md_size = s.md_size;
    d.md_offset = s.md_offset;
    d.trans_cycles = s.trans_cycles;
    d.mode = s.mode;
    d.txn_num  = s.txn_num;
    return d;
  endfunction

  function automatic APB_pack1 clone_apb(APB_pack1 s);
    APB_pack1 d = new();
    d.APBaddr = s.APBaddr;
    d.APBdata = s.APBdata;
    d.Esc_Lec_APB = s.Esc_Lec_APB;
    d.conf_cycles = s.conf_cycles;
    d.mode = s.mode;
    d.txn_num  = s.txn_num;
    return d;
  endfunction

  // Envía el ítem a drivers y réplicas a scoreboard/checker por sus mailboxes
  task automatic fanout_md(MD_pack1 it);
    gdMD_mailbox.put(clone_md(it));
    gsMD_mailbox.put(clone_md(it));
  endtask
  
  task automatic fanout_apb(APB_pack1 it);
    gdAPB_mailbox.put(clone_apb(it));
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
            begin //GEN_MD
              for (int i=0; i<cmd.len_n_md; i++) begin
                MD_pack1 it = new(); it.mode = cmd.mode;
                it.txn_num = i+1;  
                it.randomize(); it.post_randomize();
                //cg_md.sample(it.md_size, it.md_offset, it.md_use_valid);
                fanout_md(it);
              end 
            end
            begin //GEN_APB
              for (int j=0; j<cmd.len_n_apb; j++) begin
                APB_pack1 it = new(); it.mode = cmd.mode;
                it.txn_num = j+1;
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
            begin //GEN_MD
              for (int i=0; i<cmd.len_n_md; i++) begin
                MD_pack1 it = new(); it.mode = cmd.mode;
                it.txn_num = i+1;
                it.randomize(); it.post_randomize();
                //cg_md.sample(it.md_size, it.md_offset, 1'b1);
                fanout_md(it);
              end
            end
            begin //GEN_APB
              for (int j=0; j<cmd.len_n_apb; j++) begin
                APB_pack1 it = new(); it.mode = cmd.mode;
                it.txn_num = j+1;
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
            begin //GEN_MD_ERR
              for (int i=0; i<cmd.len_n_md;  i++) begin
                MD_pack1 it_md = new(); it_md.mode = cmd.mode;
                it_md.txn_num = i+1;
                it_md.randomize(); it_md.post_randomize();
                //cg_md.sample(it_md.md_size, it_md.md_offset, !it_md.md_err_illegal);
                fanout_md(it_md);
              end
            end
            begin //GEN_APB_ERR
              for (int j=0; j<cmd.len_n_apb; j++) begin
                APB_pack1 it_apb = new(); it_apb.mode = cmd.mode;
                it_apb.txn_num = j+1;
                it_apb.randomize(); it_apb.post_randomize();

                if (j == 550) begin
                  it_apb.APBaddr        = 16'h0000;
                  it_apb.Esc_Lec_APB    = 1'b1;
                  it_apb.APBdata        = 32'h0001_0000;
                  it_apb.apb_addr_valid = 1'b1;  // asegura coherencia con cobertura/scoreboard
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
            begin //GEN_MD
              for (int i=0; i<cmd.len_n_md; i++) begin
                MD_pack1 it_md = new(); it_md.mode = cmd.mode;
                it_md.txn_num = i+1;
                it_md.randomize();
                it_md.post_randomize();
               // cg_md.sample(it_md.md_size, it_md.md_offset, it_md.md_use_valid);
                fanout_md(it_md);
              end
            end
            // ===== APB =====
            begin //GEN_APB
              for (int j=0; j<cmd.len_n_apb; j++) begin
                APB_pack1 it_apb = new(); it_apb.mode = cmd.mode;
                it_apb.txn_num = j+1;
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
