# 
# Copyright (C) 2011-2014 Jeff Bush
# 
# This library is free software; you can redistribute it and/or
# modify it under the terms of the GNU Library General Public
# License as published by the Free Software Foundation; either
# version 2 of the License, or (at your option) any later version.
# 
# This library is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
# Library General Public License for more details.
# 
# You should have received a copy of the GNU Library General Public
# License along with this library; if not, write to the
# Free Software Foundation, Inc., 51 Franklin St, Fifth Floor,
# Boston, MA  02110-1301, USA.
# 


import random

class TestGroup:
	def __init__(self):
		pass

#
# Return a list of registers, where there are no duplicates in the list.
# e.g. ['r1', 'r7', 'r4']
# Note, this will not use r0
#
def allocateUniqueRegisters(type, numRegisters):
	regs = []
	while len(regs) < numRegisters:
		reg = type + str(random.randint(1, 27))	
		if reg not in regs:
			regs.append(reg)
			
	return regs

#
# Allocate a list of values, where there are no duplicates in the list
#
def allocateUniqueScalarValues(numValues):
	values = []
	while len(values) < numValues:
		value = random.randint(1, 0xffffffff)
		if value not in values:
			values.append(value)
			
	return values

def allocateRandomVectorValue():
	return [ random.randint(1, 0xffffffff) for x in range(16) ]

# Where valuea and valueb are vectors.
def vectorXor(original, valuea, valueb, mask):
	result = []

	for laneo, lanea, laneb in zip(original, valuea, valueb):
		if (mask & 0x8000) != 0:
			result += [ lanea ^ laneb ]
		else:
			result += [ laneo ]

		mask <<= 1

	return result


def makeVectorFromMemory(data, startOffset, stride):
	return [ data[startOffset + x * stride] 
		| (data[startOffset + x * stride + 1] << 8) 
		| (data[startOffset + x * stride + 2] << 16) 
		| (data[startOffset + x * stride + 3] << 24) for x in range(16) ]

def emulateSingleStore(baseOffset, memoryArray, address, value):
	memoryArray[address - baseOffset] = value & 0xff
	memoryArray[address - baseOffset + 1] = (value >> 8) & 0xff
	memoryArray[address - baseOffset + 2] = (value >> 16) & 0xff
	memoryArray[address - baseOffset + 3] = (value >> 24) & 0xff

def emulateVectorStore(baseOffset, memoryArray, address, value, stride, mask):
	if mask == None:
		useMask = 0xffff
	else:
		useMask = mask
	
	for lane, laneValue in enumerate(value):
		if (useMask << lane) & 0x8000:
			emulateSingleStore(baseOffset, memoryArray, address + lane * stride, laneValue)

def emulateScatterStore(baseOffset, memoryArray, addressVector, value, offset, mask):
	if mask == None:
		useMask = 0xffff
	else:
		useMask = mask
	
	for lane, (addr, laneValue) in enumerate(zip(addressVector, value)):
		if (useMask << lane) & 0x8000:
			emulateSingleStore(baseOffset, memoryArray, addr +offset, laneValue)

def makeAssemblyArray(data):
	str = ''
	for x in data:
		if str != '':
			str += ', '
			
		str += '0x%x' % x

	return '.byte ' + str
	
def shuffleIndices():
	rawPointers = [ x for x in range(16) ]
	random.shuffle(rawPointers)
	return rawPointers
	