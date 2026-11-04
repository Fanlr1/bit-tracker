// =====================================================================
// 从 C:\fpga_work\sys\ip\soc\soc.v 逐字提取（未改动一行）
// 目的：用【真实的 SoC 桥 RTL】接上 bitblt_axi_slave 做联合仿真，
//       避免 docs/56 记录的「测试台与 DUT 共享错误假设」。
// 提取模块：
//   BmbToAxi4SharedBridge_1_469dfaa85da54d55815c0d2324d480a8
//   StreamFifo_5_469dfaa85da54d55815c0d2324d480a8
// =====================================================================

// ---- soc.v L11729-12286 ----
module BmbToAxi4SharedBridge_1_469dfaa85da54d55815c0d2324d480a8 (
  input  wire          io_input_cmd_valid,
  output wire          io_input_cmd_ready,
  input  wire          io_input_cmd_payload_last,
  input  wire [0:0]    io_input_cmd_payload_fragment_source,
  input  wire [0:0]    io_input_cmd_payload_fragment_opcode,
  input  wire [31:0]   io_input_cmd_payload_fragment_address,
  input  wire [5:0]    io_input_cmd_payload_fragment_length,
  input  wire [31:0]   io_input_cmd_payload_fragment_data,
  input  wire [3:0]    io_input_cmd_payload_fragment_mask,
  input  wire [0:0]    io_input_cmd_payload_fragment_context,
  output reg           io_input_rsp_valid,
  input  wire          io_input_rsp_ready,
  output reg           io_input_rsp_payload_last,
  output reg  [0:0]    io_input_rsp_payload_fragment_source,
  output reg  [0:0]    io_input_rsp_payload_fragment_opcode,
  output wire [31:0]   io_input_rsp_payload_fragment_data,
  output reg  [0:0]    io_input_rsp_payload_fragment_context,
  output wire          io_output_arw_valid,
  input  wire          io_output_arw_ready,
  output wire [31:0]   io_output_arw_payload_addr,
  output wire [7:0]    io_output_arw_payload_len,
  output wire [2:0]    io_output_arw_payload_size,
  output wire [3:0]    io_output_arw_payload_cache,
  output wire [2:0]    io_output_arw_payload_prot,
  output wire          io_output_arw_payload_write,
  output wire          io_output_w_valid,
  input  wire          io_output_w_ready,
  output wire [31:0]   io_output_w_payload_data,
  output wire [3:0]    io_output_w_payload_strb,
  output wire          io_output_w_payload_last,
  input  wire          io_output_b_valid,
  output wire          io_output_b_ready,
  input  wire [1:0]    io_output_b_payload_resp,
  input  wire          io_output_r_valid,
  output wire          io_output_r_ready,
  input  wire [31:0]   io_output_r_payload_data,
  input  wire [1:0]    io_output_r_payload_resp,
  input  wire          io_output_r_payload_last,
  input  wire          io_systemClk,
  input  wire          systemCd_logic_outputReset
);

  wire                writeCmdInfo_fifo_io_pop_ready;
  wire                readCmdInfo_fifo_io_pop_ready;
  wire                writeCmdInfo_fifo_io_push_ready;
  wire                writeCmdInfo_fifo_io_pop_valid;
  wire       [0:0]    writeCmdInfo_fifo_io_pop_payload_source;
  wire       [0:0]    writeCmdInfo_fifo_io_pop_payload_context;
  wire       [3:0]    writeCmdInfo_fifo_io_occupancy;
  wire       [3:0]    writeCmdInfo_fifo_io_availability;
  wire                readCmdInfo_fifo_io_push_ready;
  wire                readCmdInfo_fifo_io_pop_valid;
  wire       [0:0]    readCmdInfo_fifo_io_pop_payload_source;
  wire       [0:0]    readCmdInfo_fifo_io_pop_payload_context;
  wire       [3:0]    readCmdInfo_fifo_io_occupancy;
  wire       [3:0]    readCmdInfo_fifo_io_availability;
  wire       [3:0]    _zz_io_output_arw_payload_len;
  reg                 pendingWrite;
  reg        [2:0]    pendingCounter;
  wire                io_input_cmd_fire;
  wire                when_Utils_l706;
  wire                io_input_rsp_fire;
  wire                when_Utils_l709;
  reg                 states_0_counter_incrementIt;
  reg                 states_0_counter_decrementIt;
  wire       [2:0]    states_0_counter_valueNext;
  reg        [2:0]    states_0_counter_value;
  wire                states_0_counter_mayOverflow;
  wire                states_0_counter_willOverflowIfInc;
  wire                states_0_counter_willOverflow;
  reg        [2:0]    states_0_counter_finalIncrement;
  wire                when_Utils_l735;
  wire                when_Utils_l737;
  wire                when_BmbToAxi4Bridge_l45;
  reg                 states_0_write;
  wire                when_BmbToAxi4Bridge_l47;
  wire                when_Utils_l706_1;
  wire                when_Utils_l709_1;
  reg                 states_1_counter_incrementIt;
  reg                 states_1_counter_decrementIt;
  wire       [2:0]    states_1_counter_valueNext;
  reg        [2:0]    states_1_counter_value;
  wire                states_1_counter_mayOverflow;
  wire                states_1_counter_willOverflowIfInc;
  wire                states_1_counter_willOverflow;
  reg        [2:0]    states_1_counter_finalIncrement;
  wire                when_Utils_l735_1;
  wire                when_Utils_l737_1;
  wire                when_BmbToAxi4Bridge_l45_1;
  reg                 states_1_write;
  wire                when_BmbToAxi4Bridge_l47_1;
  wire                hazard;
  wire                _zz_io_input_cmd_ready;
  wire                _zz_cmdFork_valid;
  reg                 _zz_io_input_cmd_ready_1;
  wire                _zz_cmdFork_payload_last;
  wire       [0:0]    _zz_cmdFork_payload_fragment_source;
  wire       [0:0]    _zz_cmdFork_payload_fragment_opcode;
  wire       [31:0]   _zz_cmdFork_payload_fragment_address;
  wire       [5:0]    _zz_cmdFork_payload_fragment_length;
  wire       [31:0]   _zz_cmdFork_payload_fragment_data;
  wire       [3:0]    _zz_cmdFork_payload_fragment_mask;
  wire       [0:0]    _zz_cmdFork_payload_fragment_context;
  wire                cmdFork_valid;
  reg                 cmdFork_ready;
  wire                cmdFork_payload_last;
  wire       [0:0]    cmdFork_payload_fragment_source;
  wire       [0:0]    cmdFork_payload_fragment_opcode;
  wire       [31:0]   cmdFork_payload_fragment_address;
  wire       [5:0]    cmdFork_payload_fragment_length;
  wire       [31:0]   cmdFork_payload_fragment_data;
  wire       [3:0]    cmdFork_payload_fragment_mask;
  wire       [0:0]    cmdFork_payload_fragment_context;
  wire                dataFork_valid;
  reg                 dataFork_ready;
  wire                dataFork_payload_last;
  wire       [0:0]    dataFork_payload_fragment_source;
  wire       [0:0]    dataFork_payload_fragment_opcode;
  wire       [31:0]   dataFork_payload_fragment_address;
  wire       [5:0]    dataFork_payload_fragment_length;
  wire       [31:0]   dataFork_payload_fragment_data;
  wire       [3:0]    dataFork_payload_fragment_mask;
  wire       [0:0]    dataFork_payload_fragment_context;
  reg                 _zz_cmdFork_valid_1;
  reg                 _zz_dataFork_valid;
  wire                when_Stream_l1063;
  wire                when_Stream_l1063_1;
  wire                cmdFork_fire;
  wire                dataFork_fire;
  reg                 io_input_cmd_payload_first;
  wire                when_Stream_l445;
  reg                 cmdStage_valid;
  wire                cmdStage_ready;
  wire                cmdStage_payload_last;
  wire       [0:0]    cmdStage_payload_fragment_source;
  wire       [0:0]    cmdStage_payload_fragment_opcode;
  wire       [31:0]   cmdStage_payload_fragment_address;
  wire       [5:0]    cmdStage_payload_fragment_length;
  wire       [31:0]   cmdStage_payload_fragment_data;
  wire       [3:0]    cmdStage_payload_fragment_mask;
  wire       [0:0]    cmdStage_payload_fragment_context;
  wire                when_Stream_l445_1;
  reg                 dataStage_valid;
  wire                dataStage_ready;
  wire                dataStage_payload_last;
  wire       [0:0]    dataStage_payload_fragment_source;
  wire       [0:0]    dataStage_payload_fragment_opcode;
  wire       [31:0]   dataStage_payload_fragment_address;
  wire       [5:0]    dataStage_payload_fragment_length;
  wire       [31:0]   dataStage_payload_fragment_data;
  wire       [3:0]    dataStage_payload_fragment_mask;
  wire       [0:0]    dataStage_payload_fragment_context;
  wire                writeCmdInfo_valid;
  wire                writeCmdInfo_ready;
  wire       [0:0]    writeCmdInfo_payload_source;
  wire       [0:0]    writeCmdInfo_payload_context;
  wire                readCmdInfo_valid;
  wire                readCmdInfo_ready;
  wire       [0:0]    readCmdInfo_payload_source;
  wire       [0:0]    readCmdInfo_payload_context;
  wire                cmdStage_fire;
  wire                writeRspInfo_valid;
  wire                writeRspInfo_ready;
  wire       [0:0]    writeRspInfo_payload_source;
  wire       [0:0]    writeRspInfo_payload_context;
  reg                 writeCmdInfo_fifo_io_pop_rValid;
  wire                writeRspInfo_fire;
  reg        [0:0]    writeCmdInfo_fifo_io_pop_rData_source;
  reg        [0:0]    writeCmdInfo_fifo_io_pop_rData_context;
  wire                readRspInfo_valid;
  wire                readRspInfo_ready;
  wire       [0:0]    readRspInfo_payload_source;
  wire       [0:0]    readRspInfo_payload_context;
  reg                 readCmdInfo_fifo_io_pop_rValid;
  wire                readRspInfo_fire;
  reg        [0:0]    readCmdInfo_fifo_io_pop_rData_source;
  reg        [0:0]    readCmdInfo_fifo_io_pop_rData_context;
  wire                _zz_io_output_arw_valid;
  reg                 rspSelLock;
  wire                when_BmbToAxi4Bridge_l87;
  wire                io_output_r_fire;
  wire                io_output_b_fire;
  wire                when_BmbToAxi4Bridge_l87_1;
  wire                when_BmbToAxi4Bridge_l88;
  reg                 rspSelReadLast;
  wire                rspSelRead;
  wire                when_BmbToAxi4Bridge_l108;

  assign _zz_io_output_arw_payload_len = io_input_cmd_payload_fragment_length[5 : 2];
  StreamFifo_5_469dfaa85da54d55815c0d2324d480a8 writeCmdInfo_fifo (
    .io_push_valid              (writeCmdInfo_valid                      ), //i
    .io_push_ready              (writeCmdInfo_fifo_io_push_ready         ), //o
    .io_push_payload_source     (writeCmdInfo_payload_source             ), //i
    .io_push_payload_context    (writeCmdInfo_payload_context            ), //i
    .io_pop_valid               (writeCmdInfo_fifo_io_pop_valid          ), //o
    .io_pop_ready               (writeCmdInfo_fifo_io_pop_ready          ), //i
    .io_pop_payload_source      (writeCmdInfo_fifo_io_pop_payload_source ), //o
    .io_pop_payload_context     (writeCmdInfo_fifo_io_pop_payload_context), //o
    .io_flush                   (1'b0                                    ), //i
    .io_occupancy               (writeCmdInfo_fifo_io_occupancy[3:0]     ), //o
    .io_availability            (writeCmdInfo_fifo_io_availability[3:0]  ), //o
    .io_systemClk               (io_systemClk                            ), //i
    .systemCd_logic_outputReset (systemCd_logic_outputReset              )  //i
  );
  StreamFifo_5_469dfaa85da54d55815c0d2324d480a8 readCmdInfo_fifo (
    .io_push_valid              (readCmdInfo_valid                      ), //i
    .io_push_ready              (readCmdInfo_fifo_io_push_ready         ), //o
    .io_push_payload_source     (readCmdInfo_payload_source             ), //i
    .io_push_payload_context    (readCmdInfo_payload_context            ), //i
    .io_pop_valid               (readCmdInfo_fifo_io_pop_valid          ), //o
    .io_pop_ready               (readCmdInfo_fifo_io_pop_ready          ), //i
    .io_pop_payload_source      (readCmdInfo_fifo_io_pop_payload_source ), //o
    .io_pop_payload_context     (readCmdInfo_fifo_io_pop_payload_context), //o
    .io_flush                   (1'b0                                   ), //i
    .io_occupancy               (readCmdInfo_fifo_io_occupancy[3:0]     ), //o
    .io_availability            (readCmdInfo_fifo_io_availability[3:0]  ), //o
    .io_systemClk               (io_systemClk                           ), //i
    .systemCd_logic_outputReset (systemCd_logic_outputReset             )  //i
  );
  always @(*) begin
    pendingWrite = 1'bx;
    if(when_BmbToAxi4Bridge_l47) begin
      pendingWrite = states_0_write;
    end
    if(when_BmbToAxi4Bridge_l47_1) begin
      pendingWrite = states_1_write;
    end
  end

  always @(*) begin
    pendingCounter = 3'bxxx;
    if(when_BmbToAxi4Bridge_l47) begin
      pendingCounter = states_0_counter_value;
    end
    if(when_BmbToAxi4Bridge_l47_1) begin
      pendingCounter = states_1_counter_value;
    end
  end

  assign io_input_cmd_fire = (io_input_cmd_valid && io_input_cmd_ready);
  assign when_Utils_l706 = (((io_input_cmd_payload_fragment_source == 1'b0) && io_input_cmd_fire) && io_input_cmd_payload_last);
  assign io_input_rsp_fire = (io_input_rsp_valid && io_input_rsp_ready);
  assign when_Utils_l709 = (((io_input_rsp_payload_fragment_source == 1'b0) && io_input_rsp_fire) && io_input_rsp_payload_last);
  always @(*) begin
    states_0_counter_incrementIt = 1'b0;
    if(when_Utils_l706) begin
      states_0_counter_incrementIt = 1'b1;
    end
  end

  always @(*) begin
    states_0_counter_decrementIt = 1'b0;
    if(when_Utils_l709) begin
      states_0_counter_decrementIt = 1'b1;
    end
  end

  assign states_0_counter_mayOverflow = (states_0_counter_value == 3'b111);
  assign states_0_counter_willOverflowIfInc = (states_0_counter_mayOverflow && (! states_0_counter_decrementIt));
  assign states_0_counter_willOverflow = (states_0_counter_willOverflowIfInc && states_0_counter_incrementIt);
  assign when_Utils_l735 = (states_0_counter_incrementIt && (! states_0_counter_decrementIt));
  always @(*) begin
    if(when_Utils_l735) begin
      states_0_counter_finalIncrement = 3'b001;
    end else begin
      if(when_Utils_l737) begin
        states_0_counter_finalIncrement = 3'b111;
      end else begin
        states_0_counter_finalIncrement = 3'b000;
      end
    end
  end

  assign when_Utils_l737 = ((! states_0_counter_incrementIt) && states_0_counter_decrementIt);
  assign states_0_counter_valueNext = (states_0_counter_value + states_0_counter_finalIncrement);
  assign when_BmbToAxi4Bridge_l45 = ((io_input_cmd_payload_fragment_source == 1'b0) && io_input_cmd_fire);
  assign when_BmbToAxi4Bridge_l47 = (io_input_cmd_payload_fragment_source == 1'b0);
  assign when_Utils_l706_1 = (((io_input_cmd_payload_fragment_source == 1'b1) && io_input_cmd_fire) && io_input_cmd_payload_last);
  assign when_Utils_l709_1 = (((io_input_rsp_payload_fragment_source == 1'b1) && io_input_rsp_fire) && io_input_rsp_payload_last);
  always @(*) begin
    states_1_counter_incrementIt = 1'b0;
    if(when_Utils_l706_1) begin
      states_1_counter_incrementIt = 1'b1;
    end
  end

  always @(*) begin
    states_1_counter_decrementIt = 1'b0;
    if(when_Utils_l709_1) begin
      states_1_counter_decrementIt = 1'b1;
    end
  end

  assign states_1_counter_mayOverflow = (states_1_counter_value == 3'b111);
  assign states_1_counter_willOverflowIfInc = (states_1_counter_mayOverflow && (! states_1_counter_decrementIt));
  assign states_1_counter_willOverflow = (states_1_counter_willOverflowIfInc && states_1_counter_incrementIt);
  assign when_Utils_l735_1 = (states_1_counter_incrementIt && (! states_1_counter_decrementIt));
  always @(*) begin
    if(when_Utils_l735_1) begin
      states_1_counter_finalIncrement = 3'b001;
    end else begin
      if(when_Utils_l737_1) begin
        states_1_counter_finalIncrement = 3'b111;
      end else begin
        states_1_counter_finalIncrement = 3'b000;
      end
    end
  end

  assign when_Utils_l737_1 = ((! states_1_counter_incrementIt) && states_1_counter_decrementIt);
  assign states_1_counter_valueNext = (states_1_counter_value + states_1_counter_finalIncrement);
  assign when_BmbToAxi4Bridge_l45_1 = ((io_input_cmd_payload_fragment_source == 1'b1) && io_input_cmd_fire);
  assign when_BmbToAxi4Bridge_l47_1 = (io_input_cmd_payload_fragment_source == 1'b1);
  assign hazard = ((((io_input_cmd_payload_fragment_opcode == 1'b1) != pendingWrite) && (pendingCounter != 3'b000)) || (pendingCounter == 3'b111));
  assign _zz_io_input_cmd_ready = (! hazard);
  assign _zz_cmdFork_valid = (io_input_cmd_valid && _zz_io_input_cmd_ready);
  assign io_input_cmd_ready = (_zz_io_input_cmd_ready_1 && _zz_io_input_cmd_ready);
  assign _zz_cmdFork_payload_last = io_input_cmd_payload_last;
  assign _zz_cmdFork_payload_fragment_source = io_input_cmd_payload_fragment_source;
  assign _zz_cmdFork_payload_fragment_opcode = io_input_cmd_payload_fragment_opcode;
  assign _zz_cmdFork_payload_fragment_address = io_input_cmd_payload_fragment_address;
  assign _zz_cmdFork_payload_fragment_length = io_input_cmd_payload_fragment_length;
  assign _zz_cmdFork_payload_fragment_data = io_input_cmd_payload_fragment_data;
  assign _zz_cmdFork_payload_fragment_mask = io_input_cmd_payload_fragment_mask;
  assign _zz_cmdFork_payload_fragment_context = io_input_cmd_payload_fragment_context;
  always @(*) begin
    _zz_io_input_cmd_ready_1 = 1'b1;
    if(when_Stream_l1063) begin
      _zz_io_input_cmd_ready_1 = 1'b0;
    end
    if(when_Stream_l1063_1) begin
      _zz_io_input_cmd_ready_1 = 1'b0;
    end
  end

  assign when_Stream_l1063 = ((! cmdFork_ready) && _zz_cmdFork_valid_1);
  assign when_Stream_l1063_1 = ((! dataFork_ready) && _zz_dataFork_valid);
  assign cmdFork_valid = (_zz_cmdFork_valid && _zz_cmdFork_valid_1);
  assign cmdFork_payload_last = _zz_cmdFork_payload_last;
  assign cmdFork_payload_fragment_source = _zz_cmdFork_payload_fragment_source;
  assign cmdFork_payload_fragment_opcode = _zz_cmdFork_payload_fragment_opcode;
  assign cmdFork_payload_fragment_address = _zz_cmdFork_payload_fragment_address;
  assign cmdFork_payload_fragment_length = _zz_cmdFork_payload_fragment_length;
  assign cmdFork_payload_fragment_data = _zz_cmdFork_payload_fragment_data;
  assign cmdFork_payload_fragment_mask = _zz_cmdFork_payload_fragment_mask;
  assign cmdFork_payload_fragment_context = _zz_cmdFork_payload_fragment_context;
  assign cmdFork_fire = (cmdFork_valid && cmdFork_ready);
  assign dataFork_valid = (_zz_cmdFork_valid && _zz_dataFork_valid);
  assign dataFork_payload_last = _zz_cmdFork_payload_last;
  assign dataFork_payload_fragment_source = _zz_cmdFork_payload_fragment_source;
  assign dataFork_payload_fragment_opcode = _zz_cmdFork_payload_fragment_opcode;
  assign dataFork_payload_fragment_address = _zz_cmdFork_payload_fragment_address;
  assign dataFork_payload_fragment_length = _zz_cmdFork_payload_fragment_length;
  assign dataFork_payload_fragment_data = _zz_cmdFork_payload_fragment_data;
  assign dataFork_payload_fragment_mask = _zz_cmdFork_payload_fragment_mask;
  assign dataFork_payload_fragment_context = _zz_cmdFork_payload_fragment_context;
  assign dataFork_fire = (dataFork_valid && dataFork_ready);
  assign when_Stream_l445 = (! io_input_cmd_payload_first);
  always @(*) begin
    cmdStage_valid = cmdFork_valid;
    if(when_Stream_l445) begin
      cmdStage_valid = 1'b0;
    end
  end

  always @(*) begin
    cmdFork_ready = cmdStage_ready;
    if(when_Stream_l445) begin
      cmdFork_ready = 1'b1;
    end
  end

  assign cmdStage_payload_last = cmdFork_payload_last;
  assign cmdStage_payload_fragment_source = cmdFork_payload_fragment_source;
  assign cmdStage_payload_fragment_opcode = cmdFork_payload_fragment_opcode;
  assign cmdStage_payload_fragment_address = cmdFork_payload_fragment_address;
  assign cmdStage_payload_fragment_length = cmdFork_payload_fragment_length;
  assign cmdStage_payload_fragment_data = cmdFork_payload_fragment_data;
  assign cmdStage_payload_fragment_mask = cmdFork_payload_fragment_mask;
  assign cmdStage_payload_fragment_context = cmdFork_payload_fragment_context;
  assign when_Stream_l445_1 = (! (dataFork_payload_fragment_opcode == 1'b1));
  always @(*) begin
    dataStage_valid = dataFork_valid;
    if(when_Stream_l445_1) begin
      dataStage_valid = 1'b0;
    end
  end

  always @(*) begin
    dataFork_ready = dataStage_ready;
    if(when_Stream_l445_1) begin
      dataFork_ready = 1'b1;
    end
  end

  assign dataStage_payload_last = dataFork_payload_last;
  assign dataStage_payload_fragment_source = dataFork_payload_fragment_source;
  assign dataStage_payload_fragment_opcode = dataFork_payload_fragment_opcode;
  assign dataStage_payload_fragment_address = dataFork_payload_fragment_address;
  assign dataStage_payload_fragment_length = dataFork_payload_fragment_length;
  assign dataStage_payload_fragment_data = dataFork_payload_fragment_data;
  assign dataStage_payload_fragment_mask = dataFork_payload_fragment_mask;
  assign dataStage_payload_fragment_context = dataFork_payload_fragment_context;
  assign cmdStage_fire = (cmdStage_valid && cmdStage_ready);
  assign writeCmdInfo_valid = (cmdStage_fire && (cmdStage_payload_fragment_opcode == 1'b1));
  assign writeCmdInfo_payload_source = cmdStage_payload_fragment_source;
  assign writeCmdInfo_payload_context = cmdStage_payload_fragment_context;
  assign readCmdInfo_valid = (cmdStage_fire && (cmdStage_payload_fragment_opcode == 1'b0));
  assign readCmdInfo_payload_source = cmdStage_payload_fragment_source;
  assign readCmdInfo_payload_context = cmdStage_payload_fragment_context;
  assign writeCmdInfo_ready = writeCmdInfo_fifo_io_push_ready;
  assign writeRspInfo_fire = (writeRspInfo_valid && writeRspInfo_ready);
  assign writeCmdInfo_fifo_io_pop_ready = (! writeCmdInfo_fifo_io_pop_rValid);
  assign writeRspInfo_valid = writeCmdInfo_fifo_io_pop_rValid;
  assign writeRspInfo_payload_source = writeCmdInfo_fifo_io_pop_rData_source;
  assign writeRspInfo_payload_context = writeCmdInfo_fifo_io_pop_rData_context;
  assign readCmdInfo_ready = readCmdInfo_fifo_io_push_ready;
  assign readRspInfo_fire = (readRspInfo_valid && readRspInfo_ready);
  assign readCmdInfo_fifo_io_pop_ready = (! readCmdInfo_fifo_io_pop_rValid);
  assign readRspInfo_valid = readCmdInfo_fifo_io_pop_rValid;
  assign readRspInfo_payload_source = readCmdInfo_fifo_io_pop_rData_source;
  assign readRspInfo_payload_context = readCmdInfo_fifo_io_pop_rData_context;
  assign _zz_io_output_arw_valid = (! ((! writeCmdInfo_ready) || (! readCmdInfo_ready)));
  assign cmdStage_ready = (io_output_arw_ready && _zz_io_output_arw_valid);
  assign io_output_arw_valid = (cmdStage_valid && _zz_io_output_arw_valid);
  assign io_output_arw_payload_write = (io_input_cmd_payload_fragment_opcode == 1'b1);
  assign io_output_arw_payload_addr = io_input_cmd_payload_fragment_address;
  assign io_output_arw_payload_len = {4'd0, _zz_io_output_arw_payload_len};
  assign io_output_arw_payload_size = 3'b010;
  assign io_output_arw_payload_prot = 3'b010;
  assign io_output_arw_payload_cache = 4'b1111;
  assign io_output_w_valid = dataStage_valid;
  assign dataStage_ready = io_output_w_ready;
  assign io_output_w_payload_data = dataStage_payload_fragment_data;
  assign io_output_w_payload_strb = dataStage_payload_fragment_mask;
  assign io_output_w_payload_last = dataStage_payload_last;
  assign when_BmbToAxi4Bridge_l87 = (io_output_r_valid || io_output_b_valid);
  assign io_output_r_fire = (io_output_r_valid && io_output_r_ready);
  assign io_output_b_fire = (io_output_b_valid && io_output_b_ready);
  assign when_BmbToAxi4Bridge_l87_1 = ((io_output_r_fire && io_output_r_payload_last) || io_output_b_fire);
  assign when_BmbToAxi4Bridge_l88 = (! rspSelLock);
  assign rspSelRead = (rspSelLock ? rspSelReadLast : io_output_r_valid);
  assign io_output_b_ready = ((io_input_rsp_ready && (! rspSelRead)) && writeRspInfo_valid);
  assign io_output_r_ready = ((io_input_rsp_ready && rspSelRead) && readRspInfo_valid);
  assign writeRspInfo_ready = ((io_input_rsp_fire && io_input_rsp_payload_last) && (! rspSelRead));
  assign readRspInfo_ready = ((io_input_rsp_fire && io_input_rsp_payload_last) && rspSelRead);
  assign io_input_rsp_payload_fragment_data = io_output_r_payload_data;
  always @(*) begin
    if(rspSelRead) begin
      io_input_rsp_valid = (io_output_r_valid && readRspInfo_valid);
    end else begin
      io_input_rsp_valid = (io_output_b_valid && writeRspInfo_valid);
    end
  end

  always @(*) begin
    if(rspSelRead) begin
      io_input_rsp_payload_last = io_output_r_payload_last;
    end else begin
      io_input_rsp_payload_last = 1'b1;
    end
  end

  always @(*) begin
    if(rspSelRead) begin
      io_input_rsp_payload_fragment_source = readRspInfo_payload_source;
    end else begin
      io_input_rsp_payload_fragment_source = writeRspInfo_payload_source;
    end
  end

  always @(*) begin
    if(rspSelRead) begin
      io_input_rsp_payload_fragment_context = readRspInfo_payload_context;
    end else begin
      io_input_rsp_payload_fragment_context = writeRspInfo_payload_context;
    end
  end

  assign when_BmbToAxi4Bridge_l108 = (rspSelRead ? (io_output_r_payload_resp == 2'b00) : (io_output_b_payload_resp == 2'b00));
  always @(*) begin
    if(when_BmbToAxi4Bridge_l108) begin
      io_input_rsp_payload_fragment_opcode = 1'b0;
    end else begin
      io_input_rsp_payload_fragment_opcode = 1'b1;
    end
  end

  always @(posedge io_systemClk) begin
    if(systemCd_logic_outputReset) begin
      states_0_counter_value <= 3'b000;
      states_1_counter_value <= 3'b000;
      _zz_cmdFork_valid_1 <= 1'b1;
      _zz_dataFork_valid <= 1'b1;
      io_input_cmd_payload_first <= 1'b1;
      writeCmdInfo_fifo_io_pop_rValid <= 1'b0;
      readCmdInfo_fifo_io_pop_rValid <= 1'b0;
      rspSelLock <= 1'b0;
    end else begin
      states_0_counter_value <= states_0_counter_valueNext;
      states_1_counter_value <= states_1_counter_valueNext;
      if(cmdFork_fire) begin
        _zz_cmdFork_valid_1 <= 1'b0;
      end
      if(dataFork_fire) begin
        _zz_dataFork_valid <= 1'b0;
      end
      if(_zz_io_input_cmd_ready_1) begin
        _zz_cmdFork_valid_1 <= 1'b1;
        _zz_dataFork_valid <= 1'b1;
      end
      if(io_input_cmd_fire) begin
        io_input_cmd_payload_first <= io_input_cmd_payload_last;
      end
      if(writeCmdInfo_fifo_io_pop_valid) begin
        writeCmdInfo_fifo_io_pop_rValid <= 1'b1;
      end
      if(writeRspInfo_fire) begin
        writeCmdInfo_fifo_io_pop_rValid <= 1'b0;
      end
      if(readCmdInfo_fifo_io_pop_valid) begin
        readCmdInfo_fifo_io_pop_rValid <= 1'b1;
      end
      if(readRspInfo_fire) begin
        readCmdInfo_fifo_io_pop_rValid <= 1'b0;
      end
      if(when_BmbToAxi4Bridge_l87) begin
        rspSelLock <= 1'b1;
      end
      if(when_BmbToAxi4Bridge_l87_1) begin
        rspSelLock <= 1'b0;
      end
    end
  end

  always @(posedge io_systemClk) begin
    if(when_BmbToAxi4Bridge_l45) begin
      states_0_write <= (io_input_cmd_payload_fragment_opcode == 1'b1);
    end
    if(when_BmbToAxi4Bridge_l45_1) begin
      states_1_write <= (io_input_cmd_payload_fragment_opcode == 1'b1);
    end
    if(writeCmdInfo_fifo_io_pop_ready) begin
      writeCmdInfo_fifo_io_pop_rData_source <= writeCmdInfo_fifo_io_pop_payload_source;
      writeCmdInfo_fifo_io_pop_rData_context <= writeCmdInfo_fifo_io_pop_payload_context;
    end
    if(readCmdInfo_fifo_io_pop_ready) begin
      readCmdInfo_fifo_io_pop_rData_source <= readCmdInfo_fifo_io_pop_payload_source;
      readCmdInfo_fifo_io_pop_rData_context <= readCmdInfo_fifo_io_pop_payload_context;
    end
    if(when_BmbToAxi4Bridge_l88) begin
      rspSelReadLast <= io_output_r_valid;
    end
  end


endmodule

// ---- soc.v L21572-21737 ----
module StreamFifo_5_469dfaa85da54d55815c0d2324d480a8 (
  input  wire          io_push_valid,
  output wire          io_push_ready,
  input  wire [0:0]    io_push_payload_source,
  input  wire [0:0]    io_push_payload_context,
  output wire          io_pop_valid,
  input  wire          io_pop_ready,
  output wire [0:0]    io_pop_payload_source,
  output wire [0:0]    io_pop_payload_context,
  input  wire          io_flush,
  output wire [3:0]    io_occupancy,
  output wire [3:0]    io_availability,
  input  wire          io_systemClk,
  input  wire          systemCd_logic_outputReset
);

  reg        [1:0]    logic_ram_spinal_port1;
  wire       [1:0]    _zz_logic_ram_port;
  reg                 _zz_1;
  wire                logic_ptr_doPush;
  wire                logic_ptr_doPop;
  wire                logic_ptr_full;
  wire                logic_ptr_empty;
  reg        [3:0]    logic_ptr_push;
  reg        [3:0]    logic_ptr_pop;
  wire       [3:0]    logic_ptr_occupancy;
  wire       [3:0]    logic_ptr_popOnIo;
  wire                when_Stream_l1248;
  reg                 logic_ptr_wentUp;
  wire                io_push_fire;
  wire                logic_push_onRam_write_valid;
  wire       [2:0]    logic_push_onRam_write_payload_address;
  wire       [0:0]    logic_push_onRam_write_payload_data_source;
  wire       [0:0]    logic_push_onRam_write_payload_data_context;
  wire                logic_pop_addressGen_valid;
  reg                 logic_pop_addressGen_ready;
  wire       [2:0]    logic_pop_addressGen_payload;
  wire                logic_pop_addressGen_fire;
  wire                logic_pop_sync_readArbitation_valid;
  wire                logic_pop_sync_readArbitation_ready;
  wire       [2:0]    logic_pop_sync_readArbitation_payload;
  reg                 logic_pop_addressGen_rValid;
  reg        [2:0]    logic_pop_addressGen_rData;
  wire                when_Stream_l375;
  wire                logic_pop_sync_readPort_cmd_valid;
  wire       [2:0]    logic_pop_sync_readPort_cmd_payload;
  wire       [0:0]    logic_pop_sync_readPort_rsp_source;
  wire       [0:0]    logic_pop_sync_readPort_rsp_context;
  wire       [1:0]    _zz_logic_pop_sync_readPort_rsp_source;
  wire                logic_pop_sync_readArbitation_translated_valid;
  wire                logic_pop_sync_readArbitation_translated_ready;
  wire       [0:0]    logic_pop_sync_readArbitation_translated_payload_source;
  wire       [0:0]    logic_pop_sync_readArbitation_translated_payload_context;
  wire                logic_pop_sync_readArbitation_fire;
  reg        [3:0]    logic_pop_sync_popReg;
  reg [1:0] logic_ram [0:7];

  assign _zz_logic_ram_port = {logic_push_onRam_write_payload_data_context,logic_push_onRam_write_payload_data_source};
  always @(posedge io_systemClk) begin
    if(_zz_1) begin
      logic_ram[logic_push_onRam_write_payload_address] <= _zz_logic_ram_port;
    end
  end

  always @(posedge io_systemClk) begin
    if(logic_pop_sync_readPort_cmd_valid) begin
      logic_ram_spinal_port1 <= logic_ram[logic_pop_sync_readPort_cmd_payload];
    end
  end

  always @(*) begin
    _zz_1 = 1'b0;
    if(logic_push_onRam_write_valid) begin
      _zz_1 = 1'b1;
    end
  end

  assign when_Stream_l1248 = (logic_ptr_doPush != logic_ptr_doPop);
  assign logic_ptr_full = (((logic_ptr_push ^ logic_ptr_popOnIo) ^ 4'b1000) == 4'b0000);
  assign logic_ptr_empty = (logic_ptr_push == logic_ptr_pop);
  assign logic_ptr_occupancy = (logic_ptr_push - logic_ptr_popOnIo);
  assign io_push_ready = (! logic_ptr_full);
  assign io_push_fire = (io_push_valid && io_push_ready);
  assign logic_ptr_doPush = io_push_fire;
  assign logic_push_onRam_write_valid = io_push_fire;
  assign logic_push_onRam_write_payload_address = logic_ptr_push[2:0];
  assign logic_push_onRam_write_payload_data_source = io_push_payload_source;
  assign logic_push_onRam_write_payload_data_context = io_push_payload_context;
  assign logic_pop_addressGen_valid = (! logic_ptr_empty);
  assign logic_pop_addressGen_payload = logic_ptr_pop[2:0];
  assign logic_pop_addressGen_fire = (logic_pop_addressGen_valid && logic_pop_addressGen_ready);
  assign logic_ptr_doPop = logic_pop_addressGen_fire;
  always @(*) begin
    logic_pop_addressGen_ready = logic_pop_sync_readArbitation_ready;
    if(when_Stream_l375) begin
      logic_pop_addressGen_ready = 1'b1;
    end
  end

  assign when_Stream_l375 = (! logic_pop_sync_readArbitation_valid);
  assign logic_pop_sync_readArbitation_valid = logic_pop_addressGen_rValid;
  assign logic_pop_sync_readArbitation_payload = logic_pop_addressGen_rData;
  assign _zz_logic_pop_sync_readPort_rsp_source = logic_ram_spinal_port1;
  assign logic_pop_sync_readPort_rsp_source = _zz_logic_pop_sync_readPort_rsp_source[0 : 0];
  assign logic_pop_sync_readPort_rsp_context = _zz_logic_pop_sync_readPort_rsp_source[1 : 1];
  assign logic_pop_sync_readPort_cmd_valid = logic_pop_addressGen_fire;
  assign logic_pop_sync_readPort_cmd_payload = logic_pop_addressGen_payload;
  assign logic_pop_sync_readArbitation_translated_valid = logic_pop_sync_readArbitation_valid;
  assign logic_pop_sync_readArbitation_ready = logic_pop_sync_readArbitation_translated_ready;
  assign logic_pop_sync_readArbitation_translated_payload_source = logic_pop_sync_readPort_rsp_source;
  assign logic_pop_sync_readArbitation_translated_payload_context = logic_pop_sync_readPort_rsp_context;
  assign io_pop_valid = logic_pop_sync_readArbitation_translated_valid;
  assign logic_pop_sync_readArbitation_translated_ready = io_pop_ready;
  assign io_pop_payload_source = logic_pop_sync_readArbitation_translated_payload_source;
  assign io_pop_payload_context = logic_pop_sync_readArbitation_translated_payload_context;
  assign logic_pop_sync_readArbitation_fire = (logic_pop_sync_readArbitation_valid && logic_pop_sync_readArbitation_ready);
  assign logic_ptr_popOnIo = logic_pop_sync_popReg;
  assign io_occupancy = logic_ptr_occupancy;
  assign io_availability = (4'b1000 - logic_ptr_occupancy);
  always @(posedge io_systemClk) begin
    if(systemCd_logic_outputReset) begin
      logic_ptr_push <= 4'b0000;
      logic_ptr_pop <= 4'b0000;
      logic_ptr_wentUp <= 1'b0;
      logic_pop_addressGen_rValid <= 1'b0;
      logic_pop_sync_popReg <= 4'b0000;
    end else begin
      if(when_Stream_l1248) begin
        logic_ptr_wentUp <= logic_ptr_doPush;
      end
      if(io_flush) begin
        logic_ptr_wentUp <= 1'b0;
      end
      if(logic_ptr_doPush) begin
        logic_ptr_push <= (logic_ptr_push + 4'b0001);
      end
      if(logic_ptr_doPop) begin
        logic_ptr_pop <= (logic_ptr_pop + 4'b0001);
      end
      if(io_flush) begin
        logic_ptr_push <= 4'b0000;
        logic_ptr_pop <= 4'b0000;
      end
      if(logic_pop_addressGen_ready) begin
        logic_pop_addressGen_rValid <= logic_pop_addressGen_valid;
      end
      if(io_flush) begin
        logic_pop_addressGen_rValid <= 1'b0;
      end
      if(logic_pop_sync_readArbitation_fire) begin
        logic_pop_sync_popReg <= logic_ptr_pop;
      end
      if(io_flush) begin
        logic_pop_sync_popReg <= 4'b0000;
      end
    end
  end

  always @(posedge io_systemClk) begin
    if(logic_pop_addressGen_ready) begin
      logic_pop_addressGen_rData <= logic_pop_addressGen_payload;
    end
  end


endmodule
