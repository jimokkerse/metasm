#    This file is part of Metasm, the Ruby assembly manipulation suite
#    Copyright (C) 2007 Yoann GUILLOT
#
#    Licence is LGPL, see LICENCE in the top-level directory

# 
# this exemple illustrates the use of the PTrace32 class to implement a pytstop-like functionnality
# Works on linux/x86
#

require 'metasm'

class Rubstop < Metasm::PTrace32
	EFLAGS = {0 => 'c', 2 => 'p', 4 => 'a', 6 => 'z', 7 => 's', 9 => 'i', 10 => 'd', 11 => 'o'}
	# define accessors for registers
	%w[eax ebx ecx edx ebp esp edi esi eip orig_eax eflags dr0 dr1 dr2 dr3 dr6 dr7 cs ds es fs gs].each { |reg|
		define_method(reg) { peekusr(REGS_I386[reg.upcase]) & 0xffffffff }
		define_method(reg+'=') { |v|
			v = [v].pack('L').unpack('l').first if v >= 0x8000_0000
			pokeusr(REGS_I386[reg.upcase], v)
			@regs_cache[reg] = v
		}
	}

	def cont(signal=0)
		singlestep(true) if @wantbp
		super
		::Process.waitpid(@pid)
		return if child.exited?
		@oldregs.update @regs_cache
		readregs
		checkbp
	end

	def singlestep(justcheck=false)
		super()
		::Process.waitpid(@pid)
		return if child.exited?
		case @wantbp
		when ::Integer: bpx @wantbp ; @wantbp = nil
		when ::String: self.dr7 |= 1 << (2*@wantbp[2, 1].to_i) ; @wantbp = nil
		end
		return if justcheck
		@oldregs.update @regs_cache
		readregs
		checkbp
	end

	def stepover
		if curinstr.opcode and curinstr.opcode.name == 'call'
			eaddr = @regs_cache['eip'] + curinstr.bin_length
			bpx eaddr, true
			cont
		else
			singlestep
		end
	end

	def stepout
		# XXX @regs_cache..
		stepover until curinstr.opcode.name == 'ret'
	end

	def syscall
		singlestep(true) if @wantbp
		super
		::Process.waitpid(@pid)
		return if child.exited?
		@oldregs.update @regs_cache
		readregs
		checkbp
	end

	attr_accessor :pgm, :regs_cache, :breakpoints, :singleshot, :wantbp,
		:symbols, :symbols_len, :filemap, :has_pax, :oldregs
	def initialize(*a)
		super
		@pgm = Metasm::ExeFormat.new Metasm::Ia32.new
		@pgm.encoded = Metasm::EncodedData.new Metasm::LinuxRemoteString.new(@pid)
		@pgm.encoded.data.ptrace = self
		@regs_cache = {}
		@oldregs = {}
		readregs
		@oldregs.update @regs_cache
		@breakpoints = {}
		@singleshot = {}
		@wantbp = nil
		@symbols = {}
		@symbols_len = {}
		@filemap = {}
		@has_pax = false
	end

	def readregs
		%w[eax ebx ecx edx esi edi esp ebp eip eflags dr0 dr1 dr2 dr3 dr6 dr7 cs ds].each { |r| @regs_cache[r] = send(r) }
		@curinstr = nil if @regs_cache['eip'] != @oldregs['eip']
	end

	def curinstr
		@curinstr ||= mnemonic_di
	end

	def child
		$?
	end

	def checkbp
		::Process::waitpid(@pid, ::Process::WNOHANG) if not child
		return if not child
		if not child.stopped?
			if child.exited?:      log "process exited with status #{child.exitstatus}"
			elsif child.signaled?: log "process exited due to signal #{child.termsig} (#{Signal.list.index child.termsig})"
			else                log "process in unknown status #{child.inspect}"
			end
			return
		elsif child.stopsig != ::Signal.list['TRAP']
			log "process stopped due to signal #{child.stopsig} (#{Signal.list.index child.stopsig})"
		end
		@codeptr = nil
		ccaddr = @regs_cache['eip']-1
		if @breakpoints[ccaddr] and self[ccaddr] == 0xcc
			self[ccaddr] = @breakpoints.delete ccaddr
			self.eip = ccaddr
			@wantbp = @regs_cache['eip'] if not @singleshot.delete @regs['eip']
		elsif @regs_cache['dr6'] & 15 != 0
			dr = (0..3).find { |dr| @regs_cache['dr6'] & (1 << dr) != 0 }
			@wantbp = "dr#{dr}" if not @singleshot.delete @regs_cache['eip']
			self.dr6 = 0
			self.dr7 = @regs_cache['dr7'] & (0xffff_ffff ^ (3 << (2*dr)))
			readregs
		end
	end

	def bpx(addr, singleshot=false)
		@singleshot[addr] = singleshot
		return if @breakpoints[addr]
		if @has_pax
			set_hwbp 'x', addr
		else
			begin
				@breakpoints[addr] = self[addr]
				self[addr] = 0xcc
			rescue Errno::EIO
				log 'i/o error when setting breakpoint, switching to PaX mode'
				@has_pax = true
				@breakpoints.delete addr
				bpx(addr, singleshot)
			end
		end
	end

	def mnemonic_di(addr = eip)
		@pgm.encoded.ptr = addr
		di = @pgm.cpu.decode_instruction(@pgm, @pgm.encoded, addr)
		@curinstr = di if addr == @regs_cache['eip']
		di
	end

	def mnemonic(addr=eip)
		mnemonic_di(addr).instruction
	end

	def regs_dump
		[%w[eax ebx ecx edx orig_eax], %w[ebp esp edi esi eip]].map { |l|
			l.map { |reg| "#{reg}=#{'%08x' % @regs_cache[reg]}" }.join(' ')
		}.join("\n")
	end

	def findfilemap(s)
		@filemap.keys.find { |k| @filemap[k][0] <= s and @filemap[k][1] > s } || '???'
	end

	def findsymbol(k)
		file = findfilemap(k) + '!'
		if s = @symbols.keys.find { |s| s <= k and s + @symbols_len[s] > k }
			file + @symbols[s] + (s == k ? '' : (k-s).to_s(16))
		else
			file + ('%08x' % k)
		end
	end

	def set_hwbp(type, addr, len=1)
		dr = (0..3).find { |dr| @regs_cache['dr7'] & (1 << (2*dr)) == 0 and @wantbp != "dr#{dr}" }
		if not dr
			log 'no debug reg available :('
			return false
		end
		@regs_cache['dr7'] &= 0xffff_ffff ^ (0xf << (16+4*dr))
		case type
		when 'x': addr += 0x6000_0000 if @has_pax
		when 'r': @regs_cache['dr7'] |= (((len-1)<<2)|3) << (16+4*dr)
		when 'w': @regs_cache['dr7'] |= (((len-1)<<2)|1) << (16+4*dr)
		end
		send("dr#{dr}=", addr)
		self.dr6 = 0
		self.dr7 = @regs_cache['dr7'] | (1 << (2*dr))
		readregs
		true
	end

	def loadsyms(baseaddr, name)
		@loadedsyms ||= {}
		return if @loadedsyms[name] or self[baseaddr, 4] != "\x7fELF"
		@loadedsyms[name] = true

		e = Metasm::LoadedELF.load self[baseaddr, 0x100_0000]
		e.load_address = baseaddr
		begin
			e.decode
		rescue
			log "failed to load symbols from #{name}: #$!"
			($!.backtrace - caller).each { |l| log l.chomp }
			@filemap[baseaddr.to_s(16)] = [baseaddr, baseaddr+0x1000]
			return
		end

		name = e.tag['SONAME'] if e.tag['SONAME']
		#e = Metasm::ELF.decode_file name rescue return 	# read from disk

		last_s = e.segments.reverse.find { |s| s.type == 'LOAD' }
		vlen = last_s.vaddr + last_s.memsz
		vlen -= baseaddr if e.header.type == 'EXEC'
		@filemap[name] = [baseaddr, baseaddr + vlen]

		oldsyms = @symbols.length
		e.symbols.each { |s|
			next if not s.name or s.shndx == 'UNDEF'
			@symbols[baseaddr + s.value] = s.name
			@symbols_len[baseaddr + s.value] = s.size
		}
		if e.header.type == 'EXEC'
			@symbols[e.header.entry] = 'entrypoint'
			@symbols_len[e.header.entry] = 1
		end
		log "loaded #{@symbols.length-oldsyms} symbols from #{name} at #{'%08x' % baseaddr}"
	end

	def loadallsyms
		File.read("/proc/#{@pid}/maps").each { |l|
			name = l.split[5]
			loadsyms l.to_i(16), name if name and name[0] == ?/
		}
	end

	def scansyms
		addr = 0
		fd = @pgm.encoded.data.readfd
		while addr <= 0xffff_f000
			addr = 0xc000_0000 if @has_pax and addr == 0x6000_0000
			log "scansym: #{'%08x' % addr}" if addr & 0x0fff_ffff == 0
			fd.pos = addr
			loadsyms(addr, '%08x'%addr) if (fd.read(4) == "\x7fELF" rescue false)
			addr += 0x1000
		end
	end

	def [](addr, len=nil)
		@pgm.encoded.data[addr, len]
	end
	def []=(addr, len, str=nil)
		@pgm.encoded.data[addr, len] = str
	end

	attr_accessor :logger
	def log(s)
		@logger ||= $stdout
		@logger.puts s
	end
end

if $0 == __FILE__

	# map syscall number to syscall name
	pp = Metasm::Preprocessor.new
	pp.define('__i386__')
	pp.feed '#include <asm/unistd.h>'
	pp.readtok until pp.eos?

	syscall_map = {}
	pp.definition.each_value { |macro|
		next if macro.name.raw !~ /__NR_(.*)/
		syscall_map[macro.body.first.raw.to_i] = $1.downcase
	}

	# start debugging
	rs = Rubstop.new(ARGV.shift)

	begin
		while rs.child.stopped? and rs.child.stopsig == Signal.list['TRAP']
			if $VERBOSE
				puts "#{'%08x' % rs.eip} #{rs.mnemonic}"
				rs.singlestep
			else
				rs.syscall ; rs.syscall	# wait return of syscall
				puts syscall_map[rs.orig_eax]
			end
		end
		p rs.child
		puts rs.regs_dump
	rescue Interrupt
		rs.detach rescue nil
		puts 'interrupted!'
	rescue Errno::ESRCH
	end
end
