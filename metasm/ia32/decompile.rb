#    This file is part of Metasm, the Ruby assembly manipulation suite
#    Copyright (C) 2009 Yoann GUILLOT
#
#    Licence is LGPL, see LICENCE in the top-level directory


require 'metasm/ia32/main'

module Metasm
class Ia32
	# temporarily setup dasm.address_binding so that backtracking
	# stack-related offsets resolve in :frameptr (relative to func start)
	def decompile_makestackvars(dasm, funcstart, blocks)
		oldfuncbd = dasm.address_binding[funcstart]
		dasm.address_binding[funcstart] = { :esp => :frameptr }	# this would suffice, the rest here is just optimisation

		patched_binding = [funcstart]	# list of addresses to cleanup later
		ebp_frame = true

		# pretrace esp and ebp for each function block (cleared later)
		blocks.each { |block|
			blockstart = block.address
			if not dasm.address_binding[blockstart]
				patched_binding << blockstart
				dasm.address_binding[blockstart] = {}
				foo = dasm.backtrace(:esp, blockstart, :snapshot_addr => funcstart)
				if foo.length == 1 and ee = foo.first and ee.kind_of? Expression and (ee == Expression[:frameptr] or
						(ee.lexpr == :frameptr and ee.op == :+ and ee.rexpr.kind_of? ::Integer))
					dasm.address_binding[blockstart][:esp] = ee
				end
				next if not ebp_frame
				foo = dasm.backtrace(:ebp, blockstart, :snapshot_addr => funcstart)
				if foo.length == 1 and ee = foo.first and ee.kind_of? Expression and (ee == Expression[:frameptr] or
						(ee.lexpr == :frameptr and ee.op == :+ and ee.rexpr.kind_of? ::Integer))
					dasm.address_binding[blockstart][:ebp] = ee
				else
					ebp_frame = false	# func does not use ebp as frame ptr, no need to bt for later blocks
				end
			end

			yield block
		}

	ensure
		patched_binding.each { |a| dasm.address_binding.delete a }
		dasm.address_binding[funcstart] = oldfuncbd if oldfuncbd
	end

	# list variable dependency for each block, remove useless writes
	# returns { blockaddr => [list of vars that are needed by a following block] }
	def decompile_func_finddeps(dcmp, blocks, func)
		deps_r = {} ; deps_w = {} ; deps_to = {}
		deps_subfunc = {} 	# things read/written by subfuncs

		# find read/writes by each block
		blocks.each { |b, to|
			deps_r[b] = [] ; deps_w[b] = [] ; deps_to[b] = to
			deps_subfunc[b] = []

			blk = dcmp.dasm.decoded[b].block
			blk.list.each { |di|
				a = di.backtrace_binding.values
				w = []
				di.backtrace_binding.keys.each { |k|
					case k
					when ::Symbol; w |= [k]
					else a |= Expression[k].externals	# if dword [eax] <- 42, eax is read
					end
				}
				a << :eax if di.opcode.name == 'ret'		# standard ABI
				
				deps_r[b] |= a.map { |ee| Expression[ee].externals.grep(::Symbol) }.flatten - [:unknown] - deps_w[b]
				deps_w[b] |= w.map { |ee| Expression[ee].externals.grep(::Symbol) }.flatten - [:unknown]
			}
			stackoff = nil
			blk.each_to_normal { |t|
				t = dcmp.backtrace_target(t, blk.list.last.address)
				next if not t = dcmp.c_parser.toplevel.symbol[t]
				t.type = C::Function.new(C::BaseType.new(:int)) if not t.type.kind_of? C::Function	# XXX this may seem a bit extreme, and yes, it is.
				stackoff ||= Expression[dcmp.dasm.backtrace(:esp, blk.list.last.address, :snapshot_addr => blocks.first[0]).first, :-, :esp].reduce

				# things that are needed by the subfunction
				if t.has_attribute('fastcall')
					a = t.type.args.to_a
					dep = [:ecx, :edx]
					dep.shift if not a[0] or a[0].has_attribute('unused')
					dep.pop   if not a[1] or a[1].has_attribute('unused')
					deps_subfunc[b] |= dep
				end
			}
			if stackoff	# last block instr == subfunction call
				deps_r[b] |= deps_subfunc[b] - deps_w[b]
				deps_w[b] |= [:eax, :ecx, :edx]			# standard ABI
			end
		}



		# find regs read and never written (must have been set by caller and are part of the func ABI)
		uninitialized = lambda { |b, r, done|
			from = deps_to.keys.find_all { |f| deps_to[f].include? b } - done
			from.empty? or from.find { |f|
				!deps_w[f].include?(r) and uninitialized[f, r, done + [b]]
			}
		}

		regargs = []
		deps_r.each { |b, deps|
			# XXX filter using ABI otherwise we get false positive for "push esi  <func body>  pop esi  ret"
			deps &= [:eax, :ecx, :edx]
			# XXX false positive if the func returns void (eg func: ret)
			deps -= [:eax] if dcmp.dasm.decoded[b].block.list.last.opcode.name == 'ret'
			deps -= regargs
			regargs |= deps.find_all { |r| uninitialized[b, r, [b]] }
		}
		if regargs.include? :ecx or regargs.include? :edx
			# TODO handle things like normal() { dl = 42; fastcall(0, 42); }  =>  normal decompiled as fastcall (dl reads edx)
			# TODO check why decompile_types doesn't update ecx/edx types
			func.add_attribute 'fastcall'
			func.type.args << C::Variable.new('ecx', C::BaseType.new(:int))
			func.type.args.last.add_attribute 'unused' if not regargs.include? :ecx
			func.type.args << C::Variable.new('edx', C::BaseType.new(:int))
			func.type.args.last.add_attribute 'unused' if not regargs.include? :edx
			regargs -= [:ecx, :edx]
		end
		if not regargs.empty?
			func.add_attribute "regargs:#{regargs.inspect}"
		end

		# remove writes from a block if no following block read the value
		dw = {}
		deps_w.each { |b, deps|
			dw[b] = deps.reject { |dep|
				ret = true
				done = []
				todo = deps_to[b].dup
				while a = todo.pop
					next if done.include? a
					done << a
					if not deps_r[a] or deps_r[a].include? dep
						ret = false
						break
					elsif not deps_w[a].include? dep
						todo.concat deps_to[a]
					end
				end
				ret
			}
		}

		dw
	end

	def decompile_blocks(dcmp, myblocks, deps, func, nextaddr = nil)
		scope = func.initializer
		func.type.args.each { |a| scope.symbol[a.name] = a }
		stmts = scope.statements
		blocks_toclean = myblocks.dup
		func_entry = myblocks.first[0]
		until myblocks.empty?
			b, to = myblocks.shift
			if l = dcmp.dasm.prog_binding.index(b)
				stmts << C::Label.new(l)
			end

			# list of assignments [[dest reg, expr assigned]]
			ops = []
			# reg binding (reg => value, values.externals = regs at block start)
			binding = {}
			# Expr => CExpr
			ce  = lambda { |*e| dcmp.decompile_cexpr(Expression[Expression[*e].reduce], scope) }
			# Expr => Expr.bind(binding) => CExpr
			ceb = lambda { |*e| ce[Expression[*e].bind(binding)] }

			# dumps a CExprs that implements an assignment to a reg (uses ops[], patches op => [reg, nil])
			commit = lambda {
				deps[b].map { |k|
					[k, ops.rindex(ops.reverse.find { |r, v| r == k })]
				}.sort_by { |k, i| i.to_i }.each { |k, i|
					next if not i or not binding[k]
					e = k
					final = []
					ops[0..i].reverse_each { |r, v|
						final << r if not v
						e = Expression[e].bind(r => v).reduce if not final.include? r
					}
					ops[i][1] = nil
					binding.delete k
					stmts << ce[k, :'=', e] if k != e
				}
			}

			# go !
			dcmp.dasm.decoded[b].block.list.each_with_index { |di, didx|
				a = di.instruction.args
				if di.opcode.props[:setip] and not di.opcode.props[:stopexec]
					# conditional jump
					commit[]
					n = dcmp.backtrace_target(get_xrefs_x(dcmp.dasm, di).first, di.address)
					if di.opcode.name =~ /^loop(.+)?/
						cx = C::CExpression[:'--', ceb[:ecx]]
						cc = $1 ? C::CExpression[cx, :'&&', ceb[decode_cc_to_expr($1)]] : cx
					else
						cc = ceb[decode_cc_to_expr(di.opcode.name[1..-1])]
					end
					# XXX switch/indirect/multiple jmp
					stmts << C::If.new(C::CExpression[cc], C::Goto.new(n))
					to.delete dcmp.dasm.normalize(n)
					next
				end

				if di.opcode.name == 'mov'
					# mov cr0 etc
					a1, a2 = di.instruction.args
					case a1
					when Ia32::CtrlReg, Ia32::DbgReg, Ia32::SegReg
						sz = a1.kind_of?(Ia32::SegReg) ? 16 : 32
						if not dcmp.c_parser.toplevel.symbol["intrinsic_set_#{a1}"]
							dcmp.c_parser.parse("void intrinsic_set_#{a1}(__int#{sz});")
						end
						f = dcmp.c_parser.toplevel.symbol["intrinsic_set_#{a1}"]
						a2 = a2.symbolic
						a2 = [a2, :&, 0xffff] if sz == 16
						stmts << C::CExpression.new(f, :funcall, [ceb[a2]], f.type.type)
						next
					end
					case a2
					when Ia32::CtrlReg, Ia32::DbgReg, Ia32::SegReg
						if not dcmp.c_parser.toplevel.symbol["intrinsic_get_#{a2}"]
							sz = a2.kind_of?(Ia32::SegReg) ? 16 : 32
							dcmp.c_parser.parse("__int#{sz} intrinsic_get_#{a2}(void);")
						end
						f = dcmp.c_parser.toplevel.symbol["intrinsic_get_#{a2}"]
						t = f.type.type
						binding.delete a1.symbolic
						stmts << C::CExpression.new(ce[a1.symbolic], :'=', C::CExpression.new(f, :funcall, [], t), t)
						next
					end
				end

				case di.opcode.name
				when 'ret'
					commit[]
					stmts << C::Return.new(C::CExpression[ceb[:eax]])
				when 'call'	# :saveip
					n = dcmp.backtrace_target(get_xrefs_x(dcmp.dasm, di).first, di.address)
					args = []
					if t = dcmp.c_parser.toplevel.symbol[n] and t.type.args
						# XXX see remarks in #finddeps
						stackoff = Expression[dcmp.dasm.backtrace(:esp, di.address, :snapshot_addr => func_entry), :-, :esp].bind(:esp => :frameptr).reduce rescue nil
						args_todo = t.type.args.dup
						args = []
						if t.has_attribute('fastcall')	# XXX DRY
							if a = args_todo.shift
								mask = (1 << (8*dcmp.c_parser.sizeof(a))) - 1
								args << ceb[:ecx, :&, mask]
								binding.delete :ecx
							end

							if a = args_todo.shift
								mask = (1 << (8*dcmp.c_parser.sizeof(a))) - 1	# char => dl
								args << ceb[:edx, :&, mask]
								binding.delete :edx
							end
						end
						args_todo.each {
							if stackoff.kind_of? Integer
								var = Indirection[[:frameptr, :+, stackoff], @size/8]
								stackoff += @size/8
							else
								var = 0
							end
							args << ceb[var]
							binding.delete var
						}
					end
					commit[]
					#next if not di.block.to_subfuncret

					if n.kind_of? ::String
						if not f = dcmp.c_parser.toplevel.symbol[n]
							# internal functions are predeclared, so this one is extern
							f = dcmp.c_parser.toplevel.symbol[n] = C::Variable.new
							f.name = n
							f.type = C::Function.new(C::BaseType.new(:int))
							dcmp.c_parser.toplevel.statements << C::Declaration.new(f)
						end
						commit[]
					else
						# indirect funcall
						fptr = ceb[n]
						binding.delete n
						commit[]
						proto = C::Function.new(C::BaseType.new(:int))
						f = C::CExpression[[fptr], proto]
					end
					binding.delete :eax
					e = C::CExpression[f, :funcall, args]
					e = C::CExpression[ce[:eax], :'=', e, f.type.type] if deps[b].include? :eax
					stmts << e
				when 'jmp'
					#if di.comment.to_a.include? 'switch'
					#	n = di.instruction.args.first.symbolic
					#	fptr = ceb[n]
					#	binding.delete n
					#	commit[]
					#	sw = C::Switch.new(fptr, C::Block.new(scope))
					#	di.block.to_normal.to_a.each { |addr|
					#		addr = dcmp.dasm.normalize addr
					#		to.delete addr
					#		next if not l = dcmp.dasm.prog_binding.index(addr)
					#		sw.body.statements << C::Goto.new(l)
 					#	}
					#	stmts << sw
					a = di.instruction.args.first
					if a.kind_of? Expression
					elsif not a.respond_to? :symbolic
						stmts << C::Asm.new(di.instruction.to_s, nil, [], [], nil, nil)
					else
						n = di.instruction.args.first.symbolic
						fptr = ceb[n]
						binding.delete n
						commit[]
						proto = C::Function.new(C::BaseType.new(:void))
						ret = C::Return.new(C::CExpression[[[fptr], C::Pointer.new(proto)], :funcall, []])
						class << ret ; attr_accessor :from_instr end
						ret.from_instr = di
						stmts << ret
						to = []
					end
				# XXX bouh
				# TODO mark instructions for which bt_binding is accurate
				when 'push', 'pop', 'mov', 'add', 'sub', 'or', 'xor', 'and', 'not', 'mul', 'div', 'idiv', 'imul', 'shr', 'shl', 'sar', 'test', 'cmp', 'inc', 'dec', 'lea', 'movzx', 'movsx', 'neg', 'cdq', 'leave', 'nop'
					bd = get_fwdemu_binding(di)
					bd.each { |k, v|
						if k.kind_of? ::Symbol #and (not deps[b].include? k or di.block.list[didx+1..-1].find { |ddi| ddi.backtrace_binding[k] })
							ops << [k, v]
						else
							stmts << ceb[k, :'=', v]
							binding.delete k
						end
					}
					update = {}
					bd.each { |k, v|
						next if not k.kind_of? ::Symbol
						update[k] = Expression[Expression[v].bind(binding).reduce]
					}
					binding.update update
				when 'lgdt'
					if not dcmp.c_parser.toplevel.struct['segment_descriptor']
						dcmp.c_parser.parse('struct segment_descriptor { __int16 limit; __int16 base0_16; __int8 base16_24; __int8 flags1; __int8 flags2_limit_16_20; __int8 base24_32; };')
						dcmp.c_parser.parse('struct segment_table { __int16 size; struct segment_descriptor *table; } __attribute__((pack(2)));')
					end
					if not dcmp.c_parser.toplevel.symbol['intrinsic_lgdt']
						dcmp.c_parser.parse('void intrinsic_lgdt(struct segment_table *);')
					end
					# need a way to transform arg => :frameptr+12
					arg = di.backtrace_binding.keys.grep(Indirection).first.pointer
					stmts << C::CExpression.new(dcmp.c_parser.toplevel.symbol['intrinsic_lgdt'], :funcall, [ceb[arg]], C::BaseType.new(:void))
				when 'lidt'
					if not dcmp.c_parser.toplevel.struct['interrupt_descriptor']
						dcmp.c_parser.parse('struct interrupt_descriptor { __int16 offset0_16; __int16 segment; __int16 flags; __int16 offset16_32; };')
						dcmp.c_parser.parse('struct interrupt_table { __int16 size; struct interrupt_descriptor *table; } __attribute__((pack(2)));')
					end
					if not dcmp.c_parser.toplevel.symbol['intrinsic_lidt']
						dcmp.c_parser.parse('void intrinsic_lidt(struct interrupt_table *);')
					end
					arg = di.backtrace_binding.keys.grep(Indirection).first.pointer
					stmts << C::CExpression.new(dcmp.c_parser.toplevel.symbol['intrinsic_lidt'], :funcall, [ceb[arg]], C::BaseType.new(:void))
				when 'ltr', 'lldt'
					if not dcmp.c_parser.toplevel.symbol["intrinsic_#{di.opcode.name}"]
						dcmp.c_parser.parse("void intrinsic_#{di.opcode.name}(int);")
					end
					arg = di.backtrace_binding.keys.first
					stmts << C::CExpression.new(dcmp.c_parser.toplevel.symbol["intrinsic_#{di.opcode.name}"], :funcall, [ceb[arg]], C::BaseType.new(:void))
				when 'out'
					sz = di.instruction.args.find { |a_| a_.kind_of? Ia32::Reg and a_.val == 0 }.sz
					if not dcmp.c_parser.toplevel.symbol["intrinsic_out#{sz}"]
						dcmp.c_parser.parse("void intrinsic_out#{sz}(unsigned short port, __int#{sz} value);")
					end
					port = di.instruction.args.grep(Expression).first || :edx
					stmts << C::CExpression.new(dcmp.c_parser.toplevel.symbol["intrinsic_out#{sz}"], :funcall, [ceb[port], ceb[:eax]], C::BaseType.new(:void))
				when 'in'
					sz = di.instruction.args.find { |a_| a_.kind_of? Ia32::Reg and a_.val == 0 }.sz
					if not dcmp.c_parser.toplevel.symbol["intrinsic_in#{sz}"]
						dcmp.c_parser.parse("__int#{sz} intrinsic_in#{sz}(unsigned short port);")
					end
					port = di.instruction.args.grep(Expression).first || :edx
					f = dcmp.c_parser.toplevel.symbol["intrinsic_in#{sz}"]
					binding.delete :eax
					stmts << C::CExpression.new(ce[:eax], :'=', C::CExpression.new(f, :funcall, [ceb[port]], f.type.type), f.type.type)
				when 'sti', 'cli'
					stmts << C::Asm.new(di.instruction.to_s, nil, [], [], nil, nil)
				else
					commit[]
					stmts << C::Asm.new(di.instruction.to_s, nil, nil, nil, nil, nil)
				end
			}
			commit[]

			case to.length
			when 0
				if not myblocks.empty? and not %w[ret jmp].include? dcmp.dasm.decoded[b].block.list.last.instruction.opname
					puts "  block #{Expression[b]} has no to and don't end in ret"
				end
			when 1
				if (myblocks.empty? ? nextaddr != to[0] : myblocks.first.first != to[0])
					stmts << C::Goto.new(dcmp.dasm.auto_label_at(to[0], 'unknown_goto'))
				end
			else
				puts "  block #{Expression[b]} with multiple to"
			end
		end

		# cleanup di.bt_binding (we set :frameptr etc in those, this may confuse the dasm)
		blocks_toclean.each { |b_, to_|
			dcmp.dasm.decoded[b_].block.list.each { |di|
				di.backtrace_binding = nil
			}
	       	}
	end
	
	def decompile_check_abi(dcmp, entry, func)
		a = func.type.args
		if func.has_attribute('fastcall') and (not a[0] or a[0].has_attribute('unused')) and (not a[1] or a[1].has_attribute('unused'))
			a.shift ; a.shift
			func.attributes.delete 'fastcall'
			func.attributes << 'stdcall' if not a.empty?
		elsif func.has_attribute('fastcall') and a.length == 2 and a.last.has_attribute('unused')
			a.pop
		end

		if not f = dcmp.dasm.function[entry] or not f.return_address
			func.add_attribute 'noreturn'
		else
			adj = f.return_address.map { |ra| dcmp.dasm.backtrace(:esp, ra, :include_start => true, :stopaddr => entry) }.flatten.uniq
			if adj.length == 1 and so = Expression[adj.first, :-, :esp].reduce and so.kind_of? ::Integer
				so /= dcmp.dasm.cpu.size/8
				so -= 1
				case so
				when 0
				when a.find_all { |fa| fa.stackoff }.length
					func.add_attribute 'stdcall' if not func.has_attribute('fastcall')
				else
					func.add_attribute "stackoff:#{so}"
				end
			else
				func.add_attribute "breakstack:#{adj.inspect}"
			end
		end
	end
end
end
