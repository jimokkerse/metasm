#    This file is part of Metasm, the Ruby assembly manipulation suite
#    Copyright (C) 2008 Yoann GUILLOT
#
#    Licence is LGPL, see LICENCE in the top-level directory


require 'metasm/exe_format/main'
require 'metasm/encode'
require 'metasm/decode'


module Metasm
# Nintendo DS executable file format
class NDS < ExeFormat
	class Header < SerialStruct
		str :title, 12
		str :code, 4
		str :maker, 2
		bytes :unitcode, :devicetype
		mem :reserved1, 10
		bytes :version, :reserved2
		words :arm9off, :arm9entry, :arm9addr, :arm9sz
		words :arm7off, :arm7entry, :arm7addr, :arm7sz
		words :fnameoff, :fnamesz, :fatoff, :fatsz
		words :arm9oloff, :arm9olsz, :arm7oloff, :arm7olsz
		words :romctrl1, :romtcrl2, :iconoff
		half :secureCRC
		half :romctrl3
		mem :reserved3, 16
		words :endoff, :headersz
		mem :reserved4, 56
	       	mem :ninlogo, 156
		half :logoCRC
		half :headerCRC

		attr_accessor :files, :fat

		def decode(x)
			super

			# decode the files section
			# it is just the tree structure of a file hierarchy
			# no indication whatsoever on where to find individual file content
			x.encoded.ptr = @fnameoff
			f = EncodedData.new << x.encoded.read(@fnamesz)
			idx = []
			# 1st word = size of index subsection
			idxsz = x.decode_word(f)
			f.ptr = 0
			# index seems to be an array of word, half, half (offset of name, index of name of first file, index of name of first subdir)
			(idxsz/8).times { idx << [x.decode_word(f), x.decode_half(f), x.decode_half(f)] }
			# follows a serie of filenames : 1-byte length, name
			# if length has high bit set, name is a directory, content = index[half following the name]
			dat = []
			idx.each { |off, idf, idd|
				f.ptr = off
				dat << []
				while (l = x.decode_byte(f)) > 0
					name = f.read(l&0x7f)
					if l & 0x80 > 0
						i = x.decode_half(f)
						dat.last << { name => i.to_s(16) }
					else
						dat.last << name
					end
				end
			}

			# build the tree from the serialized data
			# directory = array of [hash (subdirname => directory) or string (filename)]
			tree = dat.map { |dt| dt.map { |d| d.dup } }
			tree.each { |br|
				br.grep(Hash).each { |b|
					b.each { |k, v| b[k] = tree[v.to_i(16) & 0xfff] }
				}
			}
			tree = tree.first

			# flatten the tree to a list of fullpath
			iter = proc { |ar, cur|
				ret = []
				ar.each { |elem|
					case elem
					when Hash: ret.concat iter[elem.values.first, cur + elem.keys.first + '/']
					else ret << (cur + elem)
					end
				}
				ret
			}

			@files = tree #iter[tree, '/']

			x.encoded.ptr = @fatoff
			@fat = x.encoded.read(@fatsz)
		end
	end

	def encode_byte(val) val end
	def encode_half(val)        Expression[val].encode(:u16, @endianness) end
	def encode_word(val)        Expression[val].encode(:u32, @endianness) end
	def decode_byte(edata = @encoded) edata.read(1)[0] end
	def decode_half(edata = @encoded) edata.decode_imm(:u16, @endianness) end
	def decode_word(edata = @encoded) edata.decode_imm(:u32, @endianness) end


	attr_accessor :header, :arm9, :arm7

	def initialize(edn)
		@endianness = edn
		@encoded = EncodedData.new
	end

	# decodes the MZ header from the current offset in self.encoded
	def decode_header
		@header = Header.new
		@header.decode(self)
	end
	
	def decode
		decode_header
		@arm9 = @encoded[@header.arm9off, @header.arm9sz]
		@arm7 = @encoded[@header.arm7off, @header.arm7sz]
	end
end
end