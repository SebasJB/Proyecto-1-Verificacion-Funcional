class ambiente #(parameter int ALGN_DATA_WIDTH = 32);
  // --- Tipos e interfaces
  typedef MD_pack1#(.ALGN_DATA_WIDTH(ALGN_DATA_WIDTH)) MD_pack1_t;
  typedef APB_pack1                                     APB_pack1_t;
  typedef MD_pack2#(.ALGN_DATA_WIDTH(ALGN_DATA_WIDTH)) MD_pack2_t;
  typedef APB_pack2                                   APB_pack2_t;
  virtual MD_if  #(.ALGN_DATA_WIDTH(ALGN_DATA_WIDTH)) md_vif;
  virtual APB_if                                   apb_vif;

  // --- Componentes del ambiente
  generator  #(.ALGN_DATA_WIDTH(ALGN_DATA_WIDTH)) gen_inst;
  md_driver  #(.ALGN_DATA_WIDTH(ALGN_DATA_WIDTH)) md_drv_inst;
  apb_driver apb_drv_inst;
  Scoreboard #(.ALGN_DATA_WIDTH(ALGN_DATA_WIDTH)) scoreboard_inst;
  //checker    #(.ALGN_DATA_WIDTH(ALGN_DATA_WIDTH)) checker_inst;
  MD_Monitor #(.ALGN_DATA_WIDTH(ALGN_DATA_WIDTH)) md_mon_inst;
  APB_Monitor                                   apb_mon_inst;

  // --- Mailboxes generator / drivers / sb / chk)
  // gen → drivers
  mailbox #(MD_pack1_t)  gdMD_mailbox;
  mailbox #(APB_pack1_t) gdAPB_mailbox;
  // gen → scoreboard
  mailbox #(MD_pack1_t)  gsMD_mailbox;
  mailbox #(APB_pack1_t) gsAPB_mailbox;
  // gen → checker
 // mailbox #(MD_pack1_t)  gcMD_mailbox;
  //mailbox #(APB_pack1_t) gcAPB_mailbox;

  // --- Mailboxes pack2 (monitores → sb / chk)
  mailbox #(MD_pack2_t)   msMD_mailbox;  
  mailbox #(APB_pack2_t) msAPB_mailbox; // monitor → sb
  //mailbox #(pack2)   mcMD_mailbox,  mcAPB_mailbox; // monitor → chk
  // --- Mailboxes del test
  mailbox #(pack3)   tg_mailbox;   // test → generator (modo)
  //mailbox #(pack4)   ts_mailbox; // test → scoreboard (reporte)

  function new(virtual MD_if  #(.ALGN_DATA_WIDTH(ALGN_DATA_WIDTH)) md_if,
               virtual APB_if                                 apb_if);
    // Interfaces
    md_vif = md_if;
    apb_vif = apb_if;
    // Instanciación de los mailboxes
    gdMD_mailbox = new(); gdAPB_mailbox = new();
    gsMD_mailbox = new(); gsAPB_mailbox = new();
    //gcMD_mailbox = new(); gcAPB_mailbox = new();

    msMD_mailbox = new(); msAPB_mailbox = new();
    //mcMD_mailbox = new(); mcAPB_mailbox = new();

    tg_mailbox   = new();
    //ts_mailbox = new();

    // Instanciación de los componentes del ambiente
    md_drv_inst  = new(md_vif,  gdMD_mailbox);
    apb_drv_inst = new(apb_vif, gdAPB_mailbox);
    //aquí faltan mailboxes de checker
    gen_inst = new(
      gdMD_mailbox,   // m_md
      gdAPB_mailbox,  // m_apb
      gsMD_mailbox,   // m_scbd_md
      gsAPB_mailbox,  // m_scbd_apb
      tg_mailbox      // m_tg (opcional, pero ya lo tienes)
    );
    scoreboard_inst = new(); 
    //checker_inst    = new();
    md_mon_inst     = new();
    apb_mon_inst    = new();

    // Conexión de las interfaces y mailboxes en el ambiente
    //    Drivers
    md_drv_inst.vif          = md_vif;
    md_drv_inst.gdMD_mailbox = gdMD_mailbox;
    apb_drv_inst.vif           = apb_vif;
    apb_drv_inst.gdAPB_mailbox = gdAPB_mailbox;

    //    Generator 
    gen_inst.gdMD_mailbox  = gdMD_mailbox;
    gen_inst.gdAPB_mailbox = gdAPB_mailbox;
    gen_inst.gsMD_mailbox  = gsMD_mailbox;
    gen_inst.gsAPB_mailbox = gsAPB_mailbox;
    //gen_inst.gcMD_mailbox  = gcMD_mailbox;
    //gen_inst.gcAPB_mailbox = gcAPB_mailbox;
    gen_inst.tg_mailbox    = tg_mailbox;

    //    Monitores
    md_mon_inst.vif    = md_vif;
    md_mon_inst.msMD_mailbox= msMD_mailbox;  // monitor → scoreboard (MD)
    //md_mon_inst.mcMD_mailbox = mcMD_mailbox;  // monitor → checker   (MD)

    apb_mon_inst.vif    = apb_vif;
    apb_mon_inst.msAPB_mailbox= msAPB_mailbox; // monitor → scoreboard (APB)
    //apb_mon_inst.mcAPB_mailbox = mcAPB_mailbox; // monitor → checker   (APB)

    //    Scoreboard
    scoreboard_inst.gsMD_mailbox  = gsMD_mailbox;
    scoreboard_inst.gsAPB_mailbox = gsAPB_mailbox;
    scoreboard_inst.msMD_mailbox  = msMD_mailbox;
    scoreboard_inst.msAPB_mailbox  = msAPB_mailbox;
    //scoreboard_inst.test_sb_mbx= ts_mailbox;

    //    Checker
    //checker_inst.gcMD_mailbox = gcMD_mailbox;
    //checker_inst.gcAPB_mailbox = gcAPB_mailbox;
    //checker_inst.mcMD_mailbox = mcMD_mailbox;
    //checker_inst.mcAPB_mailbox = mcAPB_mailbox;

  endfunction

  // run(): lanza todas las tareas .run() en paralelo (join_none)
  virtual task run();
    $display("[%0t] [ENV] Ambiente inicializado", $time);
    fork
      md_drv_inst.run();
      apb_drv_inst.run();
      gen_inst.run();
      scoreboard_inst.run();
      //checker_inst.run();
      md_mon_inst.run();
      apb_mon_inst.run();
    join_none
  endtask

endclass
