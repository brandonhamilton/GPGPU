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

//
// Round robin arbiter.
// The incoming signal 'request' indicates units that would like to access some
// shared resource, with one bit per requestor.  The signal grant_oh (one hot) will 
// set one bit to indicate the unit that should receive access. grant_oh is not 
// registered. If update_lru is set, this will update its state on the next clock edge. 
// The unit that was granted will not receive access again until the other units that are 
// requesting access have a turn.
//

module arbiter
	#(parameter NUM_ENTRIES = 4)

	(input                           clk,
	input                            reset,
	input[NUM_ENTRIES - 1:0]         request,
	input                            update_lru,
	output logic[NUM_ENTRIES - 1:0]  grant_oh);

	logic[NUM_ENTRIES - 1:0] priority_oh_nxt;
	logic[NUM_ENTRIES - 1:0] priority_oh;

	always_comb
	begin
		for (int grant_idx = 0; grant_idx < NUM_ENTRIES; grant_idx++)
		begin
			grant_oh[grant_idx] = 0;
			for (int priority_idx = 0; priority_idx < NUM_ENTRIES; priority_idx++)
			begin
				logic is_granted = request[grant_idx] & priority_oh[priority_idx];
				for (logic[$clog2(NUM_ENTRIES) - 1:0] bit_idx = priority_idx; bit_idx != grant_idx;
					 bit_idx++)
				begin
					is_granted &= !request[bit_idx];
				end

				grant_oh[grant_idx] |= is_granted;
			end
		end
	end

	// rotate left
	assign priority_oh_nxt = { grant_oh[NUM_ENTRIES - 2:0], 
		grant_oh[NUM_ENTRIES - 1] };

	always_ff @(posedge clk, posedge reset)
	begin
		if (reset)
			priority_oh <= 1'b1;
		else if (request != 0 && update_lru)
			priority_oh <= priority_oh_nxt;
	end
endmodule

// Local Variables:
// verilog-typedef-regexp:"_t$"
// End:


