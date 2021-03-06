//
// Copyright (C) 2014 Jeff Bush
// 
// This library is free software; you can redistribute it and/or
// modify it under the terms of the GNU Library General Public
// License as published by the Free Software Foundation; either
// version 2 of the License, or (at your option) any later version.
// 
// This library is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
// Library General Public License for more details.
// 
// You should have received a copy of the GNU Library General Public
// License along with this library; if not, write to the
// Free Software Foundation, Inc., 51 Franklin St, Fifth Floor,
// Boston, MA  02110-1301, USA.
//

`include "defines.v"

//
// Multicycle execution pipeline stage 1
//
// Floating Point Addition
// - Determine which operand is larger (absolute value)
// - Swap so the larger operand is first
// - Compute alignment shift amount
// Float to int conversion
// - Steer value down smaller-exponent lane
// Floating point multiplication
// - Add exponents/multiply significands
//

module multi_cycle_execute_stage1(
	input                                          clk,
	input                                          reset,

	// From writeback stage                        
	input logic                                    wb_rollback_en,
	input thread_idx_t                             wb_rollback_thread_idx,
	                                               
	// From operand fetch stage                    
	input vector_t                                 of_operand1,
	input vector_t                                 of_operand2,
	input [`VECTOR_LANES - 1:0]                    of_mask_value,
	input                                          of_instruction_valid,
	input decoded_instruction_t                    of_instruction,
	input thread_idx_t                             of_thread_idx,
	input subcycle_t                               of_subcycle,
	                                               
	// To mx2 stage                                
	output                                         mx1_instruction_valid,
	output decoded_instruction_t                   mx1_instruction,
	output [`VECTOR_LANES - 1:0]                   mx1_mask_value,
	output thread_idx_t                            mx1_thread_idx,
	output subcycle_t                              mx1_subcycle,
	output logic[`VECTOR_LANES - 1:0]              mx1_result_is_inf,
	output logic[`VECTOR_LANES - 1:0]              mx1_result_is_nan,
	                                               
	// Floating point addition/subtraction                    
	output scalar_t[`VECTOR_LANES - 1:0]           mx1_significand_le,	// Larger exponent
	output scalar_t[`VECTOR_LANES - 1:0]           mx1_significand_se,  // Smaller exponent
	output logic[`VECTOR_LANES - 1:0][5:0]         mx1_se_align_shift,
	output logic[`VECTOR_LANES - 1:0][7:0]         mx1_add_exponent,
	output logic[`VECTOR_LANES - 1:0]              mx1_logical_subtract,
	output logic[`VECTOR_LANES - 1:0]              mx1_add_result_sign,
	
	// Floating point multiplication
	output logic[`VECTOR_LANES - 1:0][31:0]        mx1_multiplicand,
	output logic[`VECTOR_LANES - 1:0][31:0]        mx1_multiplier,
	output logic[`VECTOR_LANES - 1:0][7:0]         mx1_mul_exponent,
	output logic[`VECTOR_LANES - 1:0]              mx1_mul_sign);

	logic is_fmul;
	logic is_imul;
	logic is_ftoi;
	logic is_itof;

	assign is_fmul = of_instruction.alu_op == OP_FMUL;
	assign is_imul = of_instruction.alu_op == OP_IMUL;
	assign is_ftoi = of_instruction.alu_op == OP_FTOI;
	assign is_itof = of_instruction.alu_op == OP_ITOF;
	
	genvar lane_idx;
	generate
		for (lane_idx = 0; lane_idx < `VECTOR_LANES; lane_idx++)
		begin : lane_logic
			ieee754_binary32_t fop1;
			ieee754_binary32_t fop2;
			logic[23:0] full_significand1;
			logic[23:0] full_significand2;
			logic op1_hidden_bit;
			logic op2_hidden_bit;
			logic op1_is_larger;
			logic[7:0] exp_difference;
			logic is_subtract;
			logic[7:0] mul_exponent;
			logic fop1_is_inf;
			logic fop1_is_nan;
			logic fop2_is_inf;
			logic fop2_is_nan;
			logic logical_subtract;
			logic result_is_nan;
			logic mul_exponent_underflow;
			logic mul_exponent_carry;
			logic[7:0] ftoi_shift;

			assign fop1 = of_operand1[lane_idx];
			assign fop2 = of_operand2[lane_idx];
			assign op1_hidden_bit = fop1.exponent != 0;	// Check for subnormal numbers
			assign op2_hidden_bit = fop2.exponent != 0;
			assign full_significand1 = { op1_hidden_bit, fop1.significand };
			assign full_significand2 = { op2_hidden_bit, fop2.significand };
			assign is_subtract = of_instruction.alu_op != OP_FADD;	// This also include compares
			assign fop1_is_inf = fop1.exponent == 8'hff && fop1.significand == 0;
			assign fop1_is_nan = fop1.exponent == 8'hff && fop1.significand != 0;
			assign fop2_is_inf = fop2.exponent == 8'hff && fop2.significand == 0;
			assign fop2_is_nan = fop2.exponent == 8'hff && fop2.significand != 0;
			assign ftoi_shift = 8'd150 - fop2.exponent;

			always_comb
			begin
				if (is_itof)
					logical_subtract = of_operand2[lane_idx][31]; // Check high bit to see if this is negative
				else if (is_ftoi)
					logical_subtract = fop2.sign; // If negative, inverter in stg 3 will convert to 2s complement
				else
					logical_subtract = fop1.sign ^ fop2.sign ^ is_subtract;
			end
			
			always_comb
			begin
				if (is_itof)
					result_is_nan = 0;
				else if (is_fmul)
					result_is_nan = fop1_is_nan || fop2_is_nan || (fop1_is_inf && of_operand2[lane_idx] == 0)
						|| (fop2_is_inf && of_operand1[lane_idx] == 0);
				else if (is_ftoi)
					result_is_nan = fop2_is_nan || fop2_is_inf || fop2.exponent >= 8'd159;
				else
					result_is_nan = fop1_is_nan || fop2_is_nan || (fop1_is_inf && fop2_is_inf && logical_subtract);
			end
			
			// The result exponent for multiplication is the sum of the exponents.  We convert these
			// from biased to unbiased representation by inverting the MSB, then add.
			// XXX handle underflow
			assign { mul_exponent_underflow, mul_exponent_carry, mul_exponent }
				=  { 2'd0, fop1.exponent } + { 2'd0, fop2.exponent } - 10'd127;

			// Subtle: In the case where values are equal, leave operand1 in the _le slot.  This properly 
			// handles the sign for +/- zero.
			assign op1_is_larger = fop1.exponent > fop2.exponent 
					|| (fop1.exponent == fop2.exponent && full_significand1 >= full_significand2);
			assign exp_difference = op1_is_larger ? fop1.exponent - fop2.exponent
				: fop2.exponent - fop1.exponent;
			
			always_ff @(posedge clk)
			begin
				mx1_result_is_nan[lane_idx] <= result_is_nan;
				mx1_result_is_inf[lane_idx] <= !result_is_nan && (fop1_is_inf || fop2_is_inf
					|| (is_fmul && mul_exponent_carry && !mul_exponent_underflow));
			
				// Floating point addition pipeline. 
				// - If this is a float<->int conversion, the value goes down the small exponent path.
				//   The large exponent is set to zero.
				// - For addition/subtraction, sort into significand_le (the larger value) and 
				//   sigificand_se (the smaller).
				if (op1_is_larger || is_ftoi || is_itof)
				begin
					if (is_ftoi || is_itof)
						mx1_significand_le[lane_idx] <= 0;
					else
						mx1_significand_le[lane_idx] <= full_significand1;

					if (is_itof)
					begin
						// Convert int to float
						mx1_significand_se[lane_idx] <= of_operand2[lane_idx];
						mx1_add_exponent[lane_idx] <= 8'd127 + 8'd23;
						mx1_add_result_sign[lane_idx] <= of_operand2[lane_idx][31];
					end
					else
					begin
						// Add/Subtract/Compare, first operand has larger value
						mx1_significand_se[lane_idx] <= full_significand2;
						mx1_add_exponent[lane_idx] <= fop1.exponent;
						mx1_add_result_sign[lane_idx] <= fop1.sign;	// Larger magnitude sign wins
					end
				end
				else
				begin
					// Add/Subtract/Comapare, second operand has larger value
					mx1_significand_le[lane_idx] <= full_significand2;
					mx1_significand_se[lane_idx] <= full_significand1;
					mx1_add_exponent[lane_idx] <= fop2.exponent;
					mx1_add_result_sign[lane_idx] <= fop2.sign ^ is_subtract;
				end

				mx1_logical_subtract[lane_idx] <= logical_subtract;
				if (is_itof)
					mx1_se_align_shift[lane_idx] <= 0;	
				else if (is_ftoi)
				begin
					// Shift to truncate fractional bits
					mx1_se_align_shift[lane_idx] <= ftoi_shift < 8'd31 ? ftoi_shift : 8'd32;	
				end
				else
				begin
					// Compute how much to shift significand to make exponents be equal.
					// Note that we shift up to 27 bits, even though the significand is only
					// 24 bits.  This allows shifting out the guard and round bits.
					mx1_se_align_shift[lane_idx] <= exp_difference < 8'd27 ? exp_difference : 8'd27;	
				end
				
				// Multiplication pipeline.
				if (is_imul)
				begin
					mx1_multiplicand[lane_idx] <= of_operand1[lane_idx];
					mx1_multiplier[lane_idx] <= of_operand2[lane_idx];
				end
				else
				begin
					mx1_multiplicand[lane_idx] <= full_significand1;
					mx1_multiplier[lane_idx] <= full_significand2;
				end

				mx1_mul_exponent[lane_idx] <= mul_exponent;
				mx1_mul_sign[lane_idx] <= fop1.sign ^ fop2.sign;
			end
		end
	endgenerate
	
	always_ff @(posedge clk, posedge reset)
	begin
		if (reset)
		begin
			/*AUTORESET*/
			// Beginning of autoreset for uninitialized flops
			mx1_instruction <= 1'h0;
			mx1_instruction_valid <= 1'h0;
			mx1_mask_value <= {(1+(`VECTOR_LANES-1)){1'b0}};
			mx1_subcycle <= 1'h0;
			mx1_thread_idx <= 1'h0;
			// End of automatics
		end
		else
		begin
			mx1_instruction_valid <= of_instruction_valid && (!wb_rollback_en || wb_rollback_thread_idx != of_thread_idx)
				&& of_instruction.pipeline_sel == PIPE_MCYCLE_ARITH;
			mx1_instruction <= of_instruction;
			mx1_mask_value <= of_mask_value;
			mx1_thread_idx <= of_thread_idx;
			mx1_subcycle <= of_subcycle;
		end
	end
endmodule

// Local Variables:
// verilog-typedef-regexp:"_t$"
// End:
