//-----------------------------------------------------------------------------
// Module: tap_top
// Description: Top-level JTAG Test Access Port (TAP) controller for IEEE 1149.1.
//              This module implements the TAP finite state machine (FSM), instruction
//              register (IR) decoding, and data path selection for multiple scan chains:
//              - IDCODE scan chain
//              - Debug interface scan chain
//              - Global boundary scan (BS) chain
//              - Memory BIST (MBIST) scan chain
//
//              All scan chains operate on the falling edge of TCK.
//-----------------------------------------------------------------------------

module tap_top (

    //----------------------------------------------------------------------------
    // JTAG Terminal Signals (pad-level)
    //----------------------------------------------------------------------------
    input  logic tck_pad_i,    // JTAG Test Clock (TCK) input
    input  logic tms_pad_i,    // JTAG Test Mode Select (TMS) input
    input  logic tdi_pad_i,    // JTAG Test Data Input (TDI) pad input
    output logic tdo_pad_o,    // JTAG Test Data Output (TDO) pad output
    input  logic tdo_padoe_o,  // TDO output enable for tdo_pad_o pin; operates in the same layer
    input  logic trst_pad_i,   // JTAG Test Reset (TRST) input (active high)

    //----------------------------------------------------------------------------
    // TAP State Output Signals (DR scan control)
    //----------------------------------------------------------------------------
    // Shift DR phase indicators
    output logic shift_dr_o,
    output logic pause_dr_o,
    output logic update_dr_o,
    output logic capture_dr_o,

    //----------------------------------------------------------------------------
    // Scan Chain Selection Outputs (IR decode results)
    //----------------------------------------------------------------------------
    output logic extest_select_o,         // EXTEST instruction selected (boundary scan)
    output logic sample_preload_select_o, // SAMPLE/PRELOAD instruction selected
    output logic mbist_select_o,          // MBIST instruction selected
    output logic debug_select_o,          // DEBUG instruction selected

    //----------------------------------------------------------------------------
    // Internal Data Path Signals
    //----------------------------------------------------------------------------
    output logic tdo_o,  // Internal TDO: routed to TDI inputs of all submodules

    //----------------------------------------------------------------------------
    // Submodule TDI Inputs (scan chain data in)
    //----------------------------------------------------------------------------
    input  logic debug_tdi_i,   // TDI from debug module scan chain
    input  logic bs_chain_tdi_i, // TDI from boundary scan chain module
    input  logic mbist_tdi_i     // TDI from memory BIST scan chain
);

//-----------------------------------------------------------------------------
// Internal Registers
//-----------------------------------------------------------------------------
logic [3:0]  IR;       // 4-bit Instruction Register (IR)
logic [31:0] ID_CODE;  // 32-bit IDCODE register (read-only)


logic bypass_select_o ;
logic idcode_select_o ;
//-----------------------------------------------------------------------------
// Instruction Decoder (IEEE 1149.1 Compliant)
//-----------------------------------------------------------------------------
/*
 * IR Instruction Encoding (4-bit)
 *
 * 0000 = EXTEST
 *   - Connects the boundary scan chain between TDI and TDO.
 *   - Purpose: Drive test data off-chip via boundary outputs and receive test data
 *     in-chip via boundary inputs.
 *   - Defined as all zeroes by IEEE Std. 1149.1.
 *
 *   CaptureDR: Outputs from system logic (test vector) are captured.
 *   ShiftDR:   Captured test vector shifted out via TDO; new test vector shifted in via TDI.
 *   UpdateDR:  Data shifted in via TDI applied to Output/Control cells (pins driven 0, 1, or high-Z).
 *
 * 0001 = SAMPLE/PRELOAD
 *   - Allows IC to remain in functional mode while boundary-scan chain is connected
 *     between TDI and TDO.
 *   - Purpose: Sample functional data entering/leaving the IC; preload test data before
 *     EXTEST.
 *   - Usage: Production tests only.
 *
 *   CaptureDR: Inputs from system logic (test vector) are captured.
 *   ShiftDR:   Captured test vector shifted out via TDO; new test vector shifted in via TDI.
 *   UpdateDR:  No changes.
 *
 * 0010 = IDCODE
 *   - Selects the 32-bit read-only device identification register between TDI and TDO.
 *   - Contains manufacturer ID, device type, and version code.
 *   - Non-invasive: Does not interfere with IC operation.
 *   - Immediately available after power-up or TAP reset (TRST or Test-Logic-Reset state).
 *
 *   CaptureDR: ID value captured from ID register.
 *   ShiftDR:   Captured ID value shifted out via TDO.
 *   UpdateDR:  No changes.
 *
 * 1000 = DEBUG
 *   - Enables debugging functionality.
 *   - debug_tdi_i connected to TDO when DEBUG instruction is active.
 *   - tdo_o must connect to TDI of dbg_interface module.
 *   - See dbg_interface documentation at OpenCores for details.
 *
 * 1001 = MBIST
 *   - Enables internal memory built-in self-test (MBIST).
 *   - mbist_tdi_i connected to TDO when MBIST instruction is active.
 *   - See MBIST documentation for detailed operation.
 *
 * 1111 = BYPASS
 *   - Connects bypass register between TDI and TDO.
 *   - Purpose: Serial data transfer through IC without affecting operation.
 *   - Defined as all ones by IEEE Std. 1149.1.
 *   - Unimplemented instructions default to BYPASS.
 *
 *   CaptureDR: Logical 0 captured in bypass register.
 *   ShiftDR:   TDI input shifted out via TDO after 1-clock delay.
 *   UpdateDR:  No changes.
 *
 * IDCODE Register (31:0 RO ID)
 *   - 32-bit read-only identification register.
 *   - Bit 0 is LSB (shifted out first in ID scan chain).
 */

//-----------------------------------------------------------------------------
// Scan Chain Architecture
//-----------------------------------------------------------------------------
/*
 * Four scan chains connected to the TAP controller:
 *
 * 1. ID Scan Chain
 *    - 32-bit chain for reading internal IDCODE.
 *    - Selected when IDCODE instruction (0010) is in IR.
 *    - LSB shifted out first.
 *
 * 2. Debug Interface Scan Chain
 *    - Interfaces to debug support (CPU, Wishbone, etc.).
 *    - Selected when DEBUG instruction (1000) is in IR.
 *    - See dbg_interface documentation for length and protocol details.
 *
 * 3. Global Boundary Scan (BS) Chain
 *    - Provides access to entire SoC periphery.
 *    - Used for interconnect/boundary scan testing.
 *    - Selected when EXTEST (0000) or SAMPLE/PRELOAD (0001) is in IR.
 *    - Automatically selected after reset.
 *
 * 4. Memory BIST (MBIST) Scan Chain
 *    - Provides access to memory built-in self-test chain.
 *    - Selected when MBIST instruction (1001) is in IR.
 *    - MBIST is not part of this project; TAP provides only connection ports.
 *
 * Clocking:
 *   All scan chains operate at the falling edge of TCK (negedge tck_pad_i).
 */

//-----------------------------------------------------------------------------
// Scan Chain Details (Reference)
//-----------------------------------------------------------------------------
/*
 * 4.3.1 ID Scan Chain
 *   - 32-bit chain for internal IDCODE readout.
 *   - LSB bit shifted out first.
 *
 * 4.3.2 Debug Scan Chain
 *   - Interfaces to debug support (CPU, Wishbone, etc.).
 *   - Refer to dbg_interface documentation for length and protocol.
 *
 * 4.3.3 Global BS (Boundary Scan) Chain
 *   - Accesses entire SoC periphery.
 *   - Used for boundary scan/interconnect testing.
 *   - Automatically selected after reset.
 *
 * 4.3.4 Memory BIST Scan Chain
 *   - Accesses memory BIST scan chain.
 *   - MBIST not included in this project; TAP provides only connection ports.
 */

//-----------------------------------------------------------------------------
// TAP State Enumeration
//-----------------------------------------------------------------------------
// TAP state enumeration (5 bits needed for 16 states)
typedef enum logic [4:0] {
    TEST_LOGIC_RESET    = 5'b10000,
    RUN_TEST_IDLE       = 5'b10001,
    SELECT_DR_SCAN      = 5'b10010,
    SELECT_IR_SCAN      = 5'b10011,
    CAPTURE_DR          = 5'b10100,
    CAPTURE_IR          = 5'b10101,
    SHIFT_DR            = 5'b10110,
    SHIFT_IR            = 5'b10111,
    EXIT1_DR            = 5'b11000,
    EXIT1_IR            = 5'b11001,
    PAUSE_DR            = 5'b11010,
    PAUSE_IR            = 5'b11011,
    EXIT2_DR            = 5'b11100,
    EXIT2_IR            = 5'b11101,
    UPDATE_DR           = 5'b11110,
    UPDATE_IR           = 5'b11111
} tap_state_t;

tap_state_t current_state, next_state ; 


assign shift_dr_o = (current_state == SHIFT_DR ); 

assign pause_dr_o = (current_state == PAUSE_DR ); 

assign update_dr_o = (current_state == UPDATE_DR ); 

assign capture_dr_o = (current_state == CAPTURE_DR ); 


//-----------------------------------------------------------------------------
// TAP FSM (Falling Edge of TCK, Active-Low Reset)
//-----------------------------------------------------------------------------
always_ff @(posedge tck_pad_i or negedge trst_pad_i) begin
    if (!trst_pad_i) begin
	
		current_state <=  0 ; 
        // trst_pad_i is active-low based reset
        // TODO: Implement Test-Logic-Reset state initialization
    end else begin
        // TODO: Implement TAP FSM state transitions based on TMS
		
		current_state <= next_state; 
    end
end

always_comb begin 


	case(current_state )  

		TEST_LOGIC_RESET:
				if (tms_pad_i) next_state = TEST_LOGIC_RESET;
				else           next_state = RUN_TEST_IDLE;

			RUN_TEST_IDLE:
				if (tms_pad_i) next_state = SELECT_IR_SCAN;
				else           next_state = RUN_TEST_IDLE;

			SELECT_DR_SCAN:
				if (tms_pad_i) next_state = SELECT_IR_SCAN;
				else           next_state = CAPTURE_DR;

			SELECT_IR_SCAN:
				if (tms_pad_i) next_state = TEST_LOGIC_RESET;
				else           next_state = CAPTURE_IR;

			CAPTURE_DR:
				if (tms_pad_i) next_state = EXIT1_DR;
				else           next_state = SHIFT_DR;

			CAPTURE_IR:
				if (tms_pad_i) next_state = EXIT1_IR;
				else           next_state = SHIFT_IR;

			SHIFT_DR:
				if (tms_pad_i) next_state = EXIT1_DR;
				else           next_state = SHIFT_DR;

			SHIFT_IR:
				if (tms_pad_i) next_state = EXIT1_IR;
				else           next_state = SHIFT_IR;

			EXIT1_DR:
				if (tms_pad_i) next_state = PAUSE_DR;
				else           next_state = UPDATE_DR;

			EXIT1_IR:
				if (tms_pad_i) next_state = PAUSE_IR;
				else           next_state = UPDATE_IR;

			PAUSE_DR:
				if (tms_pad_i) next_state = EXIT2_DR;
				else           next_state = PAUSE_DR;

			PAUSE_IR:
				if (tms_pad_i) next_state = EXIT2_IR;
				else           next_state = PAUSE_IR;

			EXIT2_DR:
				if (tms_pad_i) next_state = UPDATE_DR;
				else           next_state = SHIFT_DR;

			EXIT2_IR:
				if (tms_pad_i) next_state = UPDATE_IR;
				else           next_state = SHIFT_IR;

			UPDATE_DR:
				if (tms_pad_i) next_state = SELECT_IR_SCAN;
				else           next_state = RUN_TEST_IDLE;

			UPDATE_IR:
				if (tms_pad_i) next_state = TEST_LOGIC_RESET;
				else           next_state = RUN_TEST_IDLE;

			default:
				next_state = TEST_LOGIC_RESET;
	endcase 

end 

logic [3:0] ir_reg ; 
logic [3 : 0] ir_shift; 

//-----------------------------------------------------------------------------
// Updating the instruction register (Falling Edge of TCK, Active-Low Reset)
//-----------------------------------------------------------------------------
always_ff @(negedge tck_pad_i or negedge trst_pad_i) begin
    if (!trst_pad_i) begin
	
		 ir_shift <= 1; // Reset condition for shift register 
		 ir_reg <= 1 ; // Reset condition 
    end else begin
		if(current_state == CAPTURE_IR ) begin 
			ir_shift <= 4'b0101; // IEEE 1149 Patter for this signal . 
		end else if(current_state == SHIFT_IR ) begin 
			ir_shift <= {tdi_pad_i, ir_shift [ 3 : 1 ] }; // Shift by 1 by 1 bit 
		end else if(current_state == UPDATE_IR ) begin 
			ir_reg <= ir_shift ; 
		end 
    end
end


always_comb begin 

	case (ir_reg)
        4'b0000: extest_select_o        = 1'b1;
        4'b0001: sample_preload_select_o = 1'b1;
        4'b0010: idcode_select_o         = 1'b1;
        4'b1000: debug_select_o          = 1'b1;
        4'b1001: mbist_select_o          = 1'b1;
        4'b1111: bypass_select_o         = 1'b1;
        default:  bypass_select_o         = 1'b1;
    endcase
end 


//-----------------------------------------------------------------------------
// TDO Mux (DR Signal Drive - Falling Edge of TCK, Scan Chains)
//


always_ff @(negedge tck_pad_i ) begin 


	if(bypass_select_o) begin 
		tdo_o <= 0 ; 
	end else if(idcode_select_o) begin 
		
		tdo_o <= ID_CODE[0] ; 
	end else if(debug_select_o ) begin 
		tdo_o <= debug_tdi_i ; 

	end else if(mbist_select_o ) begin 
		tdo_o <= mbist_tdi_i;
	end else if (extest_select_o || sample_preload_select_o ) begin 
		tdo_o <= bs_chain_tdi_i ; 
	end else begin 
		tdo_o <= 0 ; // Default is bypass 
	end 
	

end 


always_ff @(negedge tck_pad_i ) begin 


	if(current_state == CAPTURE_DR && idcode_select_o) begin 
		 // IDCODE composition (IEEE Std 1149.1):
        // [31:28] = version (4 bits)
        // [27:12] = part number (16 bits)
        // [11:1]  = manufacturer ID (11 bits)
        // [0]     = 1 (always set)
        ID_CODE <= 32'b0000_0000_0000_0000_0000_0000_0000_0001;
	end 
end 


//-----------------------------------------------------------------------------
// TDO Pad Output (Optionally Gated by Output Enable)
//-----------------------------------------------------------------------------
// If tdo_padoe_o is used as output enable:
assign tdo_pad_o = tdo_padoe_o ? tdo_o : 1'b0;




endmodule