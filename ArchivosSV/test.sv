// TEST: empuja al generator las 4 pruebas (pack3) y pide reporte al scoreboard
class test #(parameter int ALGN_DATA_WIDTH = 32);

  // Ambiente e IFs virtuales 
  ambiente #(.ALGN_DATA_WIDTH(ALGN_DATA_WIDTH))                    ambiente_inst;
  virtual MD_if  #(.ALGN_DATA_WIDTH(ALGN_DATA_WIDTH))              md_vif;
  virtual APB_if                                                    apb_vif;

  mailbox #(pack3) tg_mailbox;     // TEST -> GENERATOR
  //mailbox #(pack4) ts_mailbox;   // TEST -> SCOREBOARD

  // new(): recibe las interfaces, arma el ambiente y CABLEA los mailboxes
  function new(
    virtual MD_if #(.ALGN_DATA_WIDTH(ALGN_DATA_WIDTH)) md_if,
    virtual APB_if                                     apb_if
  );
    this.md_vif = md_if;
    this.apb_vif = apb_if;

    // Instancia ambiente
    ambiente_inst = new(md_vif, apb_vif);

    // Crea mailboxes del TEST
    tg_mailbox   = new();
    //ts_mailbox = new();

    // conecta los mailboxes
    ambiente_inst.tg_mailbox     = tg_mailbox;
    ambiente_inst.gen_inst.tg_mailbox = tg_mailbox;      
    //ambiente_inst.ts_mailbox   = ts_mailbox;
    //ambiente_inst.scoreboard_inst.test_sb_mbx = ts_mailbox; 
  endfunction

  // run(): lanza el ambiente y envía las 4 pruebas por tg_mailbox.
  task run();
    $display("[%0t] [TEST] Inicializando ambiente…", $time);

    fork
      ambiente_inst.run(); // Arranca drivers, generator, monitores, scoreboard y checker
    join_none

    pack3 cmd;
    // 1) CASO_GENERAL
    cmd = new();
    cmd.mode = CASO_GENERAL;  
    cmd.randomize();       // aleatoriza len_n_md / len_n_apb según modo
    $display("[%0t] [TEST] Enviando CASO_GENERAL  len_md=%0d len_apb=%0d",
             $time, cmd.len_n_md, cmd.len_n_apb);
    tg_mailbox.put(cmd);

    // 2) ESTRES
    cmd = new();
    cmd.mode = ESTRES;
    cmd.randomize();
    $display("[%0t] [TEST] Enviando ESTRES        len_md=%0d len_apb=%0d",
             $time, cmd.len_n_md, cmd.len_n_apb);
    tg_mailbox.put(cmd);

    // 3) ERRORES
    cmd = new();
    cmd.mode = ERRORES;
    cmd.randomize();
    $display("[%0t] [TEST] Enviando ERRORES       len_md=%0d len_apb=%0d",
             $time, cmd.len_n_md, cmd.len_n_apb);
    tg_mailbox.put(cmd);

    // 4) APB_CFG
    cmd = new();
    cmd.mode = APB_CFG;
    cmd.randomize();
    $display("[%0t] [TEST] Enviando APB_CFG       len_md=%0d len_apb=%0d",
             $time, cmd.len_n_md, cmd.len_n_apb);
    tg_mailbox.put(cmd);

    // A los 10000 ciclos, pedir REPORTE COMPLETO al scoreboard
    # 100000;
    $display("[%0t] [TEST] Solicitando REPORTE COMPLETO al Scoreboard", $time);
    //ambiente_inst.scoreboard_inst.excel();
    # 100;
    $finish;
  endtask

endclass
