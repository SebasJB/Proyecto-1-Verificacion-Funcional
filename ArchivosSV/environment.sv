class Ambiente #(parameter int ALGN_DATA_WIDTH = 32);
  // Interfaces virtuales
  virtual MD_if #(ALGN_DATA_WIDTH) md_vif;
  virtual APB_if apb_vif;

  // --- Componentes del ambiente
  APB_Monitor APB_mon;
  APB_Driver APB_drv;
  MD_Monitor #(.ALGN_DATA_WIDTH(ALGN_DATA_WIDTH)) MD_mon;
  MD_Driver #(.ALGN_DATA_WIDTH(ALGN_DATA_WIDTH)) MD_drv;
  Generator #(.ALGN_DATA_WIDTH(ALGN_DATA_WIDTH)) Generador;
  Scoreboard #(.ALGN_DATA_WIDTH(ALGN_DATA_WIDTH)) Scoreboard_ins;
  Checker #(.ALGN_DATA_WIDTH(ALGN_DATA_WIDTH)) Checker_inst;
  
  //Mailboxes
  //Generador
  mailbox gdMD_mailbox; // Generador → drivers : MD
  mailbox gdAPB_mailbox; // Generador → drivers : APB
  mailbox gsMD_mailbox; // Generador → scoreboard : MD
  mailbox gsAPB_mailbox; // Generador → scoreboard : APB
  mailbox gcMD_mailbox; // Generador → checker : MD
  //mailbox gcAPB_mailbox; // Generador → checker : APB
  mailbox tg_mailbox;   // test → generator (modo)

  //Monitores
  mailbox msMD_mailbox;  // monitor → scoreboard : MD
  mailbox msAPB_mailbox; // monitor → scoreboard : APB
  mailbox mcMD_mailbox; // monitor → checker : MD
  //mailbox mcAPB_mailbox; // monitor → checker : APB
 

  function new();

    // Instanciación de los mailboxes
    gdMD_mailbox = new(); 
    gdAPB_mailbox = new();
    gsMD_mailbox = new(); 
    gsAPB_mailbox = new();
    //gcMD_mailbox = new(); 
    //gcAPB_mailbox = new();
    msMD_mailbox = new(); 
    msAPB_mailbox = new();
    mcMD_mailbox = new(); 
    //mcAPB_mailbox = new();

    tg_mailbox   = new();

    // Instanciación de los componentes del ambiente
    MD_drv = new();
    APB_drv = new();
    Generador = new();
    Scoreboard_ins = new(); 
    Checker_inst = new();
    MD_mon = new();
    APB_mon = new();

    // Conexión de las interfaces virtuales
    MD_drv.vif = md_vif;
    MD_mon.vif = md_vif;
    APB_drv.vif = apb_vif;
    APB_mon.vif = apb_vif;

    //Conexión drivers y generador
    MD_drv.gdMD_mailbox = gdMD_mailbox;
    Generador.gdMD_mailbox  = gdMD_mailbox;
    APB_drv.gdAPB_mailbox = gdAPB_mailbox;
    Generador.gdAPB_mailbox = gdAPB_mailbox;

    //Conexión generador y scoreboard/checker
    Generador.gsMD_mailbox  = gsMD_mailbox;
    Generador.gsAPB_mailbox = gsAPB_mailbox;
    //Generador.gcMD_mailbox  = gcMD_mailbox;
    //Generador.gcAPB_mailbox = gcAPB_mailbox;
    Generador.tg_mailbox    = tg_mailbox;

    //Cponexión monitores y scoreboard/checker
    MD_mon.msMD_mailbox= msMD_mailbox;  // monitor → scoreboard (MD)
    MD_mon.mcMD_mailbox = mcMD_mailbox;  // monitor → checker   (MD)
    APB_mon.msAPB_mailbox= msAPB_mailbox; // monitor → scoreboard (APB)
    //APB_mon.mcAPB_mailbox = mcAPB_mailbox; // monitor → checker   (APB)

    //    Scoreboard
    Scoreboard_ins.gsMD_mailbox  = gsMD_mailbox;
    Scoreboard_ins.gsAPB_mailbox = gsAPB_mailbox;
    Scoreboard_ins.msMD_mailbox  = msMD_mailbox;
    Scoreboard_ins.msAPB_mailbox  = msAPB_mailbox;
    //Scoreboard_ins.test_sb_mbx= ts_mailbox;

    //Checker
    //Checker_inst.gcMD_mailbox = gcMD_mailbox;
    //Checker_inst.gcAPB_mailbox = gcAPB_mailbox;
    Checker_inst.mcMD_mailbox = mcMD_mailbox;
    //Checker_inst.mcAPB_mailbox = mcAPB_mailbox;

  endfunction

  // run(): lanza todas las tareas .run() en paralelo (join_none)
  virtual task run();
    $display("[%0t] [ENV] Ambiente inicializado", $time);
    fork
      MD_drv.run();
      APB_drv.run();
      Generador.run();
      Scoreboard_ins.run();
      Checker_inst.run();
      MD_mon.run();
      APB_mon.run();
    join_none
  endtask

endclass
