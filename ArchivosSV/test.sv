// TEST: empuja al generator las 4 pruebas (pack3) y pide reporte al scoreboard
class test #(parameter int ALGN_DATA_WIDTH = 32);

  // Ambiente e IFs virtuales 
  Ambiente #(.ALGN_DATA_WIDTH(ALGN_DATA_WIDTH)) env;
  virtual MD_if #(.ALGN_DATA_WIDTH(ALGN_DATA_WIDTH)) md_vif;
  virtual APB_if apb_vif;

  mailbox tg_mailbox; // TEST -> GENERATOR

  function new();
    env = new();
    tg_mailbox   = new();
    env.tg_mailbox = tg_mailbox;
    env.Generador.tg_mailbox = tg_mailbox;   
    env.md_vif = md_vif;
    env.apb_vif = apb_vif;    
  endfunction

  // run(): lanza el ambiente y envía las 4 pruebas por tg_mailbox.
  task run();
    pack3 cmd;
    $display("[%0t] [TEST] Inicializando ambiente…", $time);

    fork
      env.run(); // Arranca drivers, generator, monitores, scoreboard y checker
    join_none

    // 1) CASO_GENERAL
    cmd = new();
    cmd.mode = ESTRES ;  
    cmd.randomize();       // aleatoriza len_n_md / len_n_apb según modo
    $display("[%0t] [TEST] Enviando CASO_GENERAL  len_md=%0d len_apb=%0d",
             $time, cmd.len_n_md, cmd.len_n_apb);
    tg_mailbox.put(cmd);

    // 2) ESTRES
    cmd = new();
    cmd.mode = CASO_GENERAL;
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
    //env.scoreboard_inst.excel();
    # 100;
    $finish;
  endtask

endclass
