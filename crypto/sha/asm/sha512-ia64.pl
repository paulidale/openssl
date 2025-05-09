#! /usr/bin/env perl
# Copyright 2004-2016 The OpenSSL Project Authors. All Rights Reserved.
#
# Licensed under the Apache License 2.0 (the "License").  You may not use
# this file except in compliance with the License.  You can obtain a copy
# in the file LICENSE in the source distribution or at
# https://www.openssl.org/source/license.html

#
# ====================================================================
# Written by Andy Polyakov, @dot-asm, initially for use in the OpenSSL
# project. The module is, however, dual licensed under OpenSSL and
# CRYPTOGAMS licenses depending on where you obtain it. For further
# details see https://github.com/dot-asm/cryptogams/.
# ====================================================================
#
# SHA256/512_Transform for Itanium.
#
# sha512_block runs in 1003 cycles on Itanium 2, which is almost 50%
# faster than gcc and >60%(!) faster than code generated by HP-UX
# compiler (yes, HP-UX is generating slower code, because unlike gcc,
# it failed to deploy "shift right pair," 'shrp' instruction, which
# substitutes for 64-bit rotate).
#
# 924 cycles long sha256_block outperforms gcc by over factor of 2(!)
# and HP-UX compiler - by >40% (yes, gcc won sha512_block, but lost
# this one big time). Note that "formally" 924 is about 100 cycles
# too much. I mean it's 64 32-bit rounds vs. 80 virtually identical
# 64-bit ones and 1003*64/80 gives 802. Extra cycles, 2 per round,
# are spent on extra work to provide for 32-bit rotations. 32-bit
# rotations are still handled by 'shrp' instruction and for this
# reason lower 32 bits are deposited to upper half of 64-bit register
# prior 'shrp' issue. And in order to minimize the amount of such
# operations, X[16] values are *maintained* with copies of lower
# halves in upper halves, which is why you'll spot such instructions
# as custom 'mux2', "parallel 32-bit add," 'padd4' and "parallel
# 32-bit unsigned right shift," 'pshr4.u' instructions here.
#
# Rules of engagement.
#
# There is only one integer shifter meaning that if I have two rotate,
# deposit or extract instructions in adjacent bundles, they shall
# split [at run-time if they have to]. But note that variable and
# parallel shifts are performed by multi-media ALU and *are* pairable
# with rotates [and alike]. On the backside MMALU is rather slow: it
# takes 2 extra cycles before the result of integer operation is
# available *to* MMALU and 2(*) extra cycles before the result of MM
# operation is available "back" *to* integer ALU, not to mention that
# MMALU itself has 2 cycles latency. However! I explicitly scheduled
# these MM instructions to avoid MM stalls, so that all these extra
# latencies get "hidden" in instruction-level parallelism.
#
# (*) 2 cycles on Itanium 1 and 1 cycle on Itanium 2. But I schedule
#     for 2 in order to provide for best *overall* performance,
#     because on Itanium 1 stall on MM result is accompanied by
#     pipeline flush, which takes 6 cycles:-(
#
# June 2012
#
# Improve performance by 15-20%. Note about "rules of engagement"
# above. Contemporary cores are equipped with additional shifter,
# so that they should perform even better than below, presumably
# by ~10%.
#
######################################################################
# Current performance in cycles per processed byte for Itanium 2
# pre-9000 series [little-endian] system:
#
# SHA1(*)	5.7
# SHA256	12.6
# SHA512	6.7
#
# (*) SHA1 result is presented purely for reference purposes.
#
# To generate code, pass the file name with either 256 or 512 in its
# name and compiler flags.

# $output is the last argument if it looks like a file (it has an extension)
$output = $#ARGV >= 0 && $ARGV[$#ARGV] =~ m|\.\w+$| ? pop : undef;

if ($output =~ /512.*\.[s|asm]/i) {
	$SZ=8;
	$BITS=8*$SZ;
	$LDW="ld8";
	$STW="st8";
	$ADD="add";
	$SHRU="shr.u";
	$TABLE="K512";
	$func="sha512_block_data_order";
	@Sigma0=(28,34,39);
	@Sigma1=(14,18,41);
	@sigma0=(1,  8, 7);
	@sigma1=(19,61, 6);
	$rounds=80;
} elsif ($output =~ /256.*\.[s|asm]/i) {
	$SZ=4;
	$BITS=8*$SZ;
	$LDW="ld4";
	$STW="st4";
	$ADD="padd4";
	$SHRU="pshr4.u";
	$TABLE="K256";
	$func="sha256_block_data_order";
	@Sigma0=( 2,13,22);
	@Sigma1=( 6,11,25);
	@sigma0=( 7,18, 3);
	@sigma1=(17,19,10);
	$rounds=64;
} else { die "nonsense $output"; }

$output and (open STDOUT,">$output" or die "can't open $output: $!");

if ($^O eq "hpux") {
    $ADDP="addp4";
    for (@ARGV) { $ADDP="add" if (/[\+DD|\-mlp]64/); }
} else { $ADDP="add"; }
for (@ARGV)  {	$big_endian=1 if (/\-DB_ENDIAN/);
		$big_endian=0 if (/\-DL_ENDIAN/);  }
if (!defined($big_endian))
             {	$big_endian=(unpack('L',pack('N',1))==1);  }

$code=<<___;
.ident  \"$output, version 2.0\"
.ident  \"IA-64 ISA artwork by Andy Polyakov <https://github.com/dot-asm>\"
.explicit
.text

pfssave=r2;
lcsave=r3;
prsave=r14;
K=r15;
A_=r16; B_=r17; C_=r18; D_=r19;
E_=r20; F_=r21; G_=r22; H_=r23;
T1=r24;	T2=r25;
s0=r26;	s1=r27;	t0=r28;	t1=r29;
Ktbl=r30;
ctx=r31;	// 1st arg
input=r56;	// 2nd arg
num=r57;	// 3rd arg
sgm0=r58;	sgm1=r59;	// small constants

// void $func (SHA_CTX *ctx, const void *in,size_t num[,int host])
.global	$func#
.proc	$func#
.align	32
.skip	16
$func:
	.prologue
	.save	ar.pfs,pfssave
{ .mmi;	alloc	pfssave=ar.pfs,3,25,0,24
	$ADDP	ctx=0,r32		// 1st arg
	.save	ar.lc,lcsave
	mov	lcsave=ar.lc	}
{ .mmi;	$ADDP	input=0,r33		// 2nd arg
	mov	num=r34			// 3rd arg
	.save	pr,prsave
	mov	prsave=pr	};;

	.body
{ .mib;	add	r8=0*$SZ,ctx
	add	r9=1*$SZ,ctx	}
{ .mib;	add	r10=2*$SZ,ctx
	add	r11=3*$SZ,ctx	};;

// load A-H
.Lpic_point:
{ .mmi;	$LDW	A_=[r8],4*$SZ
	$LDW	B_=[r9],4*$SZ
	mov	Ktbl=ip		}
{ .mmi;	$LDW	C_=[r10],4*$SZ
	$LDW	D_=[r11],4*$SZ
	mov	sgm0=$sigma0[2]	};;
{ .mmi;	$LDW	E_=[r8]
	$LDW	F_=[r9]
	add	Ktbl=($TABLE#-.Lpic_point),Ktbl		}
{ .mmi;	$LDW	G_=[r10]
	$LDW	H_=[r11]
	cmp.ne	p0,p16=0,r0	};;
___
$code.=<<___ if ($BITS==64);
{ .mii;	and	r8=7,input
	and	input=~7,input;;
	cmp.eq	p9,p0=1,r8	}
{ .mmi;	cmp.eq	p10,p0=2,r8
	cmp.eq	p11,p0=3,r8
	cmp.eq	p12,p0=4,r8	}
{ .mmi;	cmp.eq	p13,p0=5,r8
	cmp.eq	p14,p0=6,r8
	cmp.eq	p15,p0=7,r8	};;
___
$code.=<<___;
.L_outer:
.rotr	R[8],X[16]
A=R[0]; B=R[1]; C=R[2]; D=R[3]; E=R[4]; F=R[5]; G=R[6]; H=R[7]
{ .mmi;	ld1	X[15]=[input],$SZ		// eliminated in sha512
	mov	A=A_
	mov	ar.lc=14	}
{ .mmi;	mov	B=B_
	mov	C=C_
	mov	D=D_		}
{ .mmi;	mov	E=E_
	mov	F=F_
	mov	ar.ec=2		};;
{ .mmi;	mov	G=G_
	mov	H=H_
	mov	sgm1=$sigma1[2]	}
{ .mib;	mov	r8=0
	add	r9=1-$SZ,input
	brp.loop.imp	.L_first16,.L_first16_end-16	};;
___
$t0="A", $t1="E", $code.=<<___ if ($BITS==64);
// in sha512 case I load whole X[16] at once and take care of alignment...
{ .mmi;	add	r8=1*$SZ,input
	add	r9=2*$SZ,input
	add	r10=3*$SZ,input		};;
{ .mmb;	$LDW	X[15]=[input],4*$SZ
	$LDW	X[14]=[r8],4*$SZ
(p9)	br.cond.dpnt.many	.L1byte	};;
{ .mmb;	$LDW	X[13]=[r9],4*$SZ
	$LDW	X[12]=[r10],4*$SZ
(p10)	br.cond.dpnt.many	.L2byte	};;
{ .mmb;	$LDW	X[11]=[input],4*$SZ
	$LDW	X[10]=[r8],4*$SZ
(p11)	br.cond.dpnt.many	.L3byte	};;
{ .mmb;	$LDW	X[ 9]=[r9],4*$SZ
	$LDW	X[ 8]=[r10],4*$SZ
(p12)	br.cond.dpnt.many	.L4byte	};;
{ .mmb;	$LDW	X[ 7]=[input],4*$SZ
	$LDW	X[ 6]=[r8],4*$SZ
(p13)	br.cond.dpnt.many	.L5byte	};;
{ .mmb;	$LDW	X[ 5]=[r9],4*$SZ
	$LDW	X[ 4]=[r10],4*$SZ
(p14)	br.cond.dpnt.many	.L6byte	};;
{ .mmb;	$LDW	X[ 3]=[input],4*$SZ
	$LDW	X[ 2]=[r8],4*$SZ
(p15)	br.cond.dpnt.many	.L7byte	};;
{ .mmb;	$LDW	X[ 1]=[r9],4*$SZ
	$LDW	X[ 0]=[r10],4*$SZ	}
{ .mib;	mov	r8=0
	mux1	X[15]=X[15],\@rev		// eliminated on big-endian
	br.many	.L_first16		};;
.L1byte:
{ .mmi;	$LDW	X[13]=[r9],4*$SZ
	$LDW	X[12]=[r10],4*$SZ
	shrp	X[15]=X[15],X[14],56	};;
{ .mmi;	$LDW	X[11]=[input],4*$SZ
	$LDW	X[10]=[r8],4*$SZ
	shrp	X[14]=X[14],X[13],56	}
{ .mmi;	$LDW	X[ 9]=[r9],4*$SZ
	$LDW	X[ 8]=[r10],4*$SZ
	shrp	X[13]=X[13],X[12],56	};;
{ .mmi;	$LDW	X[ 7]=[input],4*$SZ
	$LDW	X[ 6]=[r8],4*$SZ
	shrp	X[12]=X[12],X[11],56	}
{ .mmi;	$LDW	X[ 5]=[r9],4*$SZ
	$LDW	X[ 4]=[r10],4*$SZ
	shrp	X[11]=X[11],X[10],56	};;
{ .mmi;	$LDW	X[ 3]=[input],4*$SZ
	$LDW	X[ 2]=[r8],4*$SZ
	shrp	X[10]=X[10],X[ 9],56	}
{ .mmi;	$LDW	X[ 1]=[r9],4*$SZ
	$LDW	X[ 0]=[r10],4*$SZ
	shrp	X[ 9]=X[ 9],X[ 8],56	};;
{ .mii;	$LDW	T1=[input]
	shrp	X[ 8]=X[ 8],X[ 7],56
	shrp	X[ 7]=X[ 7],X[ 6],56	}
{ .mii;	shrp	X[ 6]=X[ 6],X[ 5],56
	shrp	X[ 5]=X[ 5],X[ 4],56	};;
{ .mii;	shrp	X[ 4]=X[ 4],X[ 3],56
	shrp	X[ 3]=X[ 3],X[ 2],56	}
{ .mii;	shrp	X[ 2]=X[ 2],X[ 1],56
	shrp	X[ 1]=X[ 1],X[ 0],56	}
{ .mib;	shrp	X[ 0]=X[ 0],T1,56	}
{ .mib;	mov	r8=0
	mux1	X[15]=X[15],\@rev		// eliminated on big-endian
	br.many	.L_first16		};;
.L2byte:
{ .mmi;	$LDW	X[11]=[input],4*$SZ
	$LDW	X[10]=[r8],4*$SZ
	shrp	X[15]=X[15],X[14],48	}
{ .mmi;	$LDW	X[ 9]=[r9],4*$SZ
	$LDW	X[ 8]=[r10],4*$SZ
	shrp	X[14]=X[14],X[13],48	};;
{ .mmi;	$LDW	X[ 7]=[input],4*$SZ
	$LDW	X[ 6]=[r8],4*$SZ
	shrp	X[13]=X[13],X[12],48	}
{ .mmi;	$LDW	X[ 5]=[r9],4*$SZ
	$LDW	X[ 4]=[r10],4*$SZ
	shrp	X[12]=X[12],X[11],48	};;
{ .mmi;	$LDW	X[ 3]=[input],4*$SZ
	$LDW	X[ 2]=[r8],4*$SZ
	shrp	X[11]=X[11],X[10],48	}
{ .mmi;	$LDW	X[ 1]=[r9],4*$SZ
	$LDW	X[ 0]=[r10],4*$SZ
	shrp	X[10]=X[10],X[ 9],48	};;
{ .mii;	$LDW	T1=[input]
	shrp	X[ 9]=X[ 9],X[ 8],48
	shrp	X[ 8]=X[ 8],X[ 7],48	}
{ .mii;	shrp	X[ 7]=X[ 7],X[ 6],48
	shrp	X[ 6]=X[ 6],X[ 5],48	};;
{ .mii;	shrp	X[ 5]=X[ 5],X[ 4],48
	shrp	X[ 4]=X[ 4],X[ 3],48	}
{ .mii;	shrp	X[ 3]=X[ 3],X[ 2],48
	shrp	X[ 2]=X[ 2],X[ 1],48	}
{ .mii;	shrp	X[ 1]=X[ 1],X[ 0],48
	shrp	X[ 0]=X[ 0],T1,48	}
{ .mib;	mov	r8=0
	mux1	X[15]=X[15],\@rev		// eliminated on big-endian
	br.many	.L_first16		};;
.L3byte:
{ .mmi;	$LDW	X[ 9]=[r9],4*$SZ
	$LDW	X[ 8]=[r10],4*$SZ
	shrp	X[15]=X[15],X[14],40	};;
{ .mmi;	$LDW	X[ 7]=[input],4*$SZ
	$LDW	X[ 6]=[r8],4*$SZ
	shrp	X[14]=X[14],X[13],40	}
{ .mmi;	$LDW	X[ 5]=[r9],4*$SZ
	$LDW	X[ 4]=[r10],4*$SZ
	shrp	X[13]=X[13],X[12],40	};;
{ .mmi;	$LDW	X[ 3]=[input],4*$SZ
	$LDW	X[ 2]=[r8],4*$SZ
	shrp	X[12]=X[12],X[11],40	}
{ .mmi;	$LDW	X[ 1]=[r9],4*$SZ
	$LDW	X[ 0]=[r10],4*$SZ
	shrp	X[11]=X[11],X[10],40	};;
{ .mii;	$LDW	T1=[input]
	shrp	X[10]=X[10],X[ 9],40
	shrp	X[ 9]=X[ 9],X[ 8],40	}
{ .mii;	shrp	X[ 8]=X[ 8],X[ 7],40
	shrp	X[ 7]=X[ 7],X[ 6],40	};;
{ .mii;	shrp	X[ 6]=X[ 6],X[ 5],40
	shrp	X[ 5]=X[ 5],X[ 4],40	}
{ .mii;	shrp	X[ 4]=X[ 4],X[ 3],40
	shrp	X[ 3]=X[ 3],X[ 2],40	}
{ .mii;	shrp	X[ 2]=X[ 2],X[ 1],40
	shrp	X[ 1]=X[ 1],X[ 0],40	}
{ .mib;	shrp	X[ 0]=X[ 0],T1,40	}
{ .mib;	mov	r8=0
	mux1	X[15]=X[15],\@rev		// eliminated on big-endian
	br.many	.L_first16		};;
.L4byte:
{ .mmi;	$LDW	X[ 7]=[input],4*$SZ
	$LDW	X[ 6]=[r8],4*$SZ
	shrp	X[15]=X[15],X[14],32	}
{ .mmi;	$LDW	X[ 5]=[r9],4*$SZ
	$LDW	X[ 4]=[r10],4*$SZ
	shrp	X[14]=X[14],X[13],32	};;
{ .mmi;	$LDW	X[ 3]=[input],4*$SZ
	$LDW	X[ 2]=[r8],4*$SZ
	shrp	X[13]=X[13],X[12],32	}
{ .mmi;	$LDW	X[ 1]=[r9],4*$SZ
	$LDW	X[ 0]=[r10],4*$SZ
	shrp	X[12]=X[12],X[11],32	};;
{ .mii;	$LDW	T1=[input]
	shrp	X[11]=X[11],X[10],32
	shrp	X[10]=X[10],X[ 9],32	}
{ .mii;	shrp	X[ 9]=X[ 9],X[ 8],32
	shrp	X[ 8]=X[ 8],X[ 7],32	};;
{ .mii;	shrp	X[ 7]=X[ 7],X[ 6],32
	shrp	X[ 6]=X[ 6],X[ 5],32	}
{ .mii;	shrp	X[ 5]=X[ 5],X[ 4],32
	shrp	X[ 4]=X[ 4],X[ 3],32	}
{ .mii;	shrp	X[ 3]=X[ 3],X[ 2],32
	shrp	X[ 2]=X[ 2],X[ 1],32	}
{ .mii;	shrp	X[ 1]=X[ 1],X[ 0],32
	shrp	X[ 0]=X[ 0],T1,32	}
{ .mib;	mov	r8=0
	mux1	X[15]=X[15],\@rev		// eliminated on big-endian
	br.many	.L_first16		};;
.L5byte:
{ .mmi;	$LDW	X[ 5]=[r9],4*$SZ
	$LDW	X[ 4]=[r10],4*$SZ
	shrp	X[15]=X[15],X[14],24	};;
{ .mmi;	$LDW	X[ 3]=[input],4*$SZ
	$LDW	X[ 2]=[r8],4*$SZ
	shrp	X[14]=X[14],X[13],24	}
{ .mmi;	$LDW	X[ 1]=[r9],4*$SZ
	$LDW	X[ 0]=[r10],4*$SZ
	shrp	X[13]=X[13],X[12],24	};;
{ .mii;	$LDW	T1=[input]
	shrp	X[12]=X[12],X[11],24
	shrp	X[11]=X[11],X[10],24	}
{ .mii;	shrp	X[10]=X[10],X[ 9],24
	shrp	X[ 9]=X[ 9],X[ 8],24	};;
{ .mii;	shrp	X[ 8]=X[ 8],X[ 7],24
	shrp	X[ 7]=X[ 7],X[ 6],24	}
{ .mii;	shrp	X[ 6]=X[ 6],X[ 5],24
	shrp	X[ 5]=X[ 5],X[ 4],24	}
{ .mii;	shrp	X[ 4]=X[ 4],X[ 3],24
	shrp	X[ 3]=X[ 3],X[ 2],24	}
{ .mii;	shrp	X[ 2]=X[ 2],X[ 1],24
	shrp	X[ 1]=X[ 1],X[ 0],24	}
{ .mib;	shrp	X[ 0]=X[ 0],T1,24	}
{ .mib;	mov	r8=0
	mux1	X[15]=X[15],\@rev		// eliminated on big-endian
	br.many	.L_first16		};;
.L6byte:
{ .mmi;	$LDW	X[ 3]=[input],4*$SZ
	$LDW	X[ 2]=[r8],4*$SZ
	shrp	X[15]=X[15],X[14],16	}
{ .mmi;	$LDW	X[ 1]=[r9],4*$SZ
	$LDW	X[ 0]=[r10],4*$SZ
	shrp	X[14]=X[14],X[13],16	};;
{ .mii;	$LDW	T1=[input]
	shrp	X[13]=X[13],X[12],16
	shrp	X[12]=X[12],X[11],16	}
{ .mii;	shrp	X[11]=X[11],X[10],16
	shrp	X[10]=X[10],X[ 9],16	};;
{ .mii;	shrp	X[ 9]=X[ 9],X[ 8],16
	shrp	X[ 8]=X[ 8],X[ 7],16	}
{ .mii;	shrp	X[ 7]=X[ 7],X[ 6],16
	shrp	X[ 6]=X[ 6],X[ 5],16	}
{ .mii;	shrp	X[ 5]=X[ 5],X[ 4],16
	shrp	X[ 4]=X[ 4],X[ 3],16	}
{ .mii;	shrp	X[ 3]=X[ 3],X[ 2],16
	shrp	X[ 2]=X[ 2],X[ 1],16	}
{ .mii;	shrp	X[ 1]=X[ 1],X[ 0],16
	shrp	X[ 0]=X[ 0],T1,16	}
{ .mib;	mov	r8=0
	mux1	X[15]=X[15],\@rev		// eliminated on big-endian
	br.many	.L_first16		};;
.L7byte:
{ .mmi;	$LDW	X[ 1]=[r9],4*$SZ
	$LDW	X[ 0]=[r10],4*$SZ
	shrp	X[15]=X[15],X[14],8	};;
{ .mii;	$LDW	T1=[input]
	shrp	X[14]=X[14],X[13],8
	shrp	X[13]=X[13],X[12],8	}
{ .mii;	shrp	X[12]=X[12],X[11],8
	shrp	X[11]=X[11],X[10],8	};;
{ .mii;	shrp	X[10]=X[10],X[ 9],8
	shrp	X[ 9]=X[ 9],X[ 8],8	}
{ .mii;	shrp	X[ 8]=X[ 8],X[ 7],8
	shrp	X[ 7]=X[ 7],X[ 6],8	}
{ .mii;	shrp	X[ 6]=X[ 6],X[ 5],8
	shrp	X[ 5]=X[ 5],X[ 4],8	}
{ .mii;	shrp	X[ 4]=X[ 4],X[ 3],8
	shrp	X[ 3]=X[ 3],X[ 2],8	}
{ .mii;	shrp	X[ 2]=X[ 2],X[ 1],8
	shrp	X[ 1]=X[ 1],X[ 0],8	}
{ .mib;	shrp	X[ 0]=X[ 0],T1,8	}
{ .mib;	mov	r8=0
	mux1	X[15]=X[15],\@rev	};;	// eliminated on big-endian

.align	32
.L_first16:
{ .mmi;		$LDW	K=[Ktbl],$SZ
		add	A=A,r8			// H+=Sigma(0) from the past
		_rotr	r10=$t1,$Sigma1[0]  }	// ROTR(e,14)
{ .mmi;		and	T1=F,E
		andcm	r8=G,E
	(p16)	mux1	X[14]=X[14],\@rev   };;	// eliminated on big-endian
{ .mmi;		and	T2=A,B
		and	r9=A,C
		_rotr	r11=$t1,$Sigma1[1]  }	// ROTR(e,41)
{ .mmi;		xor	T1=T1,r8		// T1=((e & f) ^ (~e & g))
		and	r8=B,C		    };;
___
$t0="t0", $t1="t1", $code.=<<___ if ($BITS==32);
.align	32
.L_first16:
{ .mmi;		add	A=A,r8			// H+=Sigma(0) from the past
		add	r10=2-$SZ,input
		add	r11=3-$SZ,input	};;
{ .mmi;		ld1	r9=[r9]
		ld1	r10=[r10]
		dep.z	$t1=E,32,32	}
{ .mmi;		ld1	r11=[r11]
		$LDW	K=[Ktbl],$SZ
		zxt4	E=E		};;
{ .mii;		or	$t1=$t1,E
		dep	X[15]=X[15],r9,8,8
		mux2	$t0=A,0x44	};;	// copy lower half to upper
{ .mmi;		and	T1=F,E
		andcm	r8=G,E
		dep	r11=r10,r11,8,8	};;
{ .mmi;		and	T2=A,B
		and	r9=A,C
		dep	X[15]=X[15],r11,16,16	};;
{ .mmi;	(p16)	ld1	X[15-1]=[input],$SZ	// prefetch
		xor	T1=T1,r8		// T1=((e & f) ^ (~e & g))
		_rotr	r10=$t1,$Sigma1[0] }	// ROTR(e,14)
{ .mmi;		and	r8=B,C
		_rotr	r11=$t1,$Sigma1[1] };;	// ROTR(e,18)
___
$code.=<<___;
{ .mmi;		add	T1=T1,H			// T1=Ch(e,f,g)+h
		xor	r10=r10,r11
		_rotr	r11=$t1,$Sigma1[2]  }	// ROTR(e,41)
{ .mmi;		xor	T2=T2,r9
		add	K=K,X[15]	    };;
{ .mmi;		add	T1=T1,K			// T1+=K[i]+X[i]
		xor	T2=T2,r8		// T2=((a & b) ^ (a & c) ^ (b & c))
		_rotr	r8=$t0,$Sigma0[0]   }	// ROTR(a,28)
{ .mmi;		xor	r11=r11,r10		// Sigma1(e)
		_rotr	r9=$t0,$Sigma0[1]   };;	// ROTR(a,34)
{ .mmi;		add	T1=T1,r11		// T+=Sigma1(e)
		xor	r8=r8,r9
		_rotr	r9=$t0,$Sigma0[2]   };;	// ROTR(a,39)
{ .mmi;		xor	r8=r8,r9		// Sigma0(a)
		add	D=D,T1
		mux2	H=X[15],0x44	    }	// mov H=X[15] in sha512
{ .mib;	(p16)	add	r9=1-$SZ,input		// not used in sha512
		add	X[15]=T1,T2		// H=T1+Maj(a,b,c)
	br.ctop.sptk	.L_first16	    };;
.L_first16_end:

{ .mib;	mov	ar.lc=$rounds-17
	brp.loop.imp	.L_rest,.L_rest_end-16		}
{ .mib;	mov	ar.ec=1
	br.many	.L_rest			};;

.align	32
.L_rest:
{ .mmi;		$LDW	K=[Ktbl],$SZ
		add	A=A,r8			// H+=Sigma0(a) from the past
		_rotr	r8=X[15-1],$sigma0[0] }	// ROTR(s0,1)
{ .mmi; 	add	X[15]=X[15],X[15-9]	// X[i&0xF]+=X[(i+9)&0xF]
		$SHRU	s0=X[15-1],sgm0	    };;	// s0=X[(i+1)&0xF]>>7
{ .mib;		and	T1=F,E
		_rotr	r9=X[15-1],$sigma0[1] }	// ROTR(s0,8)
{ .mib;		andcm	r10=G,E
		$SHRU	s1=X[15-14],sgm1    };;	// s1=X[(i+14)&0xF]>>6
// Pair of mmi; splits on Itanium 1 and prevents pipeline flush
// upon $SHRU output usage
{ .mmi;		xor	T1=T1,r10		// T1=((e & f) ^ (~e & g))
		xor	r9=r8,r9
		_rotr	r10=X[15-14],$sigma1[0] }// ROTR(s1,19)
{ .mmi;		and	T2=A,B
		and	r8=A,C
		_rotr	r11=X[15-14],$sigma1[1] };;// ROTR(s1,61)
___
$t0="t0", $t1="t1", $code.=<<___ if ($BITS==32);
{ .mib;		xor	s0=s0,r9		// s0=sigma0(X[(i+1)&0xF])
		dep.z	$t1=E,32,32	    }
{ .mib;		xor	r10=r11,r10
		zxt4	E=E		    };;
{ .mii;		xor	s1=s1,r10		// s1=sigma1(X[(i+14)&0xF])
		shrp	r9=E,$t1,32+$Sigma1[0]	// ROTR(e,14)
		mux2	$t0=A,0x44	    };;	// copy lower half to upper
// Pair of mmi; splits on Itanium 1 and prevents pipeline flush
// upon mux2 output usage
{ .mmi;		xor	T2=T2,r8
		shrp	r8=E,$t1,32+$Sigma1[1]}	// ROTR(e,18)
{ .mmi;		and	r10=B,C
		add	T1=T1,H			// T1=Ch(e,f,g)+h
		or	$t1=$t1,E   	    };;
___
$t0="A", $t1="E", $code.=<<___ if ($BITS==64);
{ .mib;		xor	s0=s0,r9		// s0=sigma0(X[(i+1)&0xF])
		_rotr	r9=$t1,$Sigma1[0]   }	// ROTR(e,14)
{ .mib;		xor	r10=r11,r10
		xor	T2=T2,r8	    };;
{ .mib;		xor	s1=s1,r10		// s1=sigma1(X[(i+14)&0xF])
		_rotr	r8=$t1,$Sigma1[1]   }	// ROTR(e,18)
{ .mib;		and	r10=B,C
		add	T1=T1,H		    };;	// T1+=H
___
$code.=<<___;
{ .mib;		xor	r9=r9,r8
		_rotr	r8=$t1,$Sigma1[2]   }	// ROTR(e,41)
{ .mib;		xor	T2=T2,r10		// T2=((a & b) ^ (a & c) ^ (b & c))
		add	X[15]=X[15],s0	    };;	// X[i]+=sigma0(X[i+1])
{ .mmi;		xor	r9=r9,r8		// Sigma1(e)
		add	X[15]=X[15],s1		// X[i]+=sigma0(X[i+14])
		_rotr	r8=$t0,$Sigma0[0]   };;	// ROTR(a,28)
{ .mmi;		add	K=K,X[15]
		add	T1=T1,r9		// T1+=Sigma1(e)
		_rotr	r9=$t0,$Sigma0[1]   };;	// ROTR(a,34)
{ .mmi;		add	T1=T1,K			// T1+=K[i]+X[i]
		xor	r8=r8,r9
		_rotr	r9=$t0,$Sigma0[2]   };;	// ROTR(a,39)
{ .mib;		add	D=D,T1
		mux2	H=X[15],0x44	    }	// mov H=X[15] in sha512
{ .mib;		xor	r8=r8,r9		// Sigma0(a)
		add	X[15]=T1,T2		// H=T1+Maj(a,b,c)
	br.ctop.sptk	.L_rest		    };;
.L_rest_end:

{ .mmi;	add	A=A,r8			};;	// H+=Sigma0(a) from the past
{ .mmi;	add	A_=A_,A
	add	B_=B_,B
	add	C_=C_,C			}
{ .mmi;	add	D_=D_,D
	add	E_=E_,E
	cmp.ltu	p16,p0=1,num		};;
{ .mmi;	add	F_=F_,F
	add	G_=G_,G
	add	H_=H_,H			}
{ .mmb;	add	Ktbl=-$SZ*$rounds,Ktbl
(p16)	add	num=-1,num
(p16)	br.dptk.many	.L_outer	};;

{ .mib;	add	r8=0*$SZ,ctx
	add	r9=1*$SZ,ctx		}
{ .mib;	add	r10=2*$SZ,ctx
	add	r11=3*$SZ,ctx		};;
{ .mmi;	$STW	[r8]=A_,4*$SZ
	$STW	[r9]=B_,4*$SZ
	mov	ar.lc=lcsave		}
{ .mmi;	$STW	[r10]=C_,4*$SZ
	$STW	[r11]=D_,4*$SZ
	mov	pr=prsave,0x1ffff	};;
{ .mmb;	$STW	[r8]=E_
	$STW	[r9]=F_			}
{ .mmb;	$STW	[r10]=G_
	$STW	[r11]=H_
	br.ret.sptk.many	b0	};;
.endp	$func#
___

foreach(split($/,$code)) {
    s/\`([^\`]*)\`/eval $1/gem;
    s/_rotr(\s+)([^=]+)=([^,]+),([0-9]+)/shrp$1$2=$3,$3,$4/gm;
    if ($BITS==64) {
	s/mux2(\s+)([^=]+)=([^,]+),\S+/mov$1 $2=$3/gm;
	s/mux1(\s+)\S+/nop.i$1 0x0/gm	if ($big_endian);
	s/(shrp\s+X\[[^=]+)=([^,]+),([^,]+),([1-9]+)/$1=$3,$2,64-$4/gm
    						if (!$big_endian);
	s/ld1(\s+)X\[\S+/nop.m$1 0x0/gm;
    }

    print $_,"\n";
}

print<<___ if ($BITS==32);
.align	64
.type	K256#,\@object
K256:	data4	0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5
	data4	0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5
	data4	0xd807aa98,0x12835b01,0x243185be,0x550c7dc3
	data4	0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174
	data4	0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc
	data4	0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da
	data4	0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7
	data4	0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967
	data4	0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13
	data4	0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85
	data4	0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3
	data4	0xd192e819,0xd6990624,0xf40e3585,0x106aa070
	data4	0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5
	data4	0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3
	data4	0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208
	data4	0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2
.size	K256#,$SZ*$rounds
stringz	"SHA256 block transform for IA64, CRYPTOGAMS by <https://github.com/dot-asm>"
___
print<<___ if ($BITS==64);
.align	64
.type	K512#,\@object
K512:	data8	0x428a2f98d728ae22,0x7137449123ef65cd
	data8	0xb5c0fbcfec4d3b2f,0xe9b5dba58189dbbc
	data8	0x3956c25bf348b538,0x59f111f1b605d019
	data8	0x923f82a4af194f9b,0xab1c5ed5da6d8118
	data8	0xd807aa98a3030242,0x12835b0145706fbe
	data8	0x243185be4ee4b28c,0x550c7dc3d5ffb4e2
	data8	0x72be5d74f27b896f,0x80deb1fe3b1696b1
	data8	0x9bdc06a725c71235,0xc19bf174cf692694
	data8	0xe49b69c19ef14ad2,0xefbe4786384f25e3
	data8	0x0fc19dc68b8cd5b5,0x240ca1cc77ac9c65
	data8	0x2de92c6f592b0275,0x4a7484aa6ea6e483
	data8	0x5cb0a9dcbd41fbd4,0x76f988da831153b5
	data8	0x983e5152ee66dfab,0xa831c66d2db43210
	data8	0xb00327c898fb213f,0xbf597fc7beef0ee4
	data8	0xc6e00bf33da88fc2,0xd5a79147930aa725
	data8	0x06ca6351e003826f,0x142929670a0e6e70
	data8	0x27b70a8546d22ffc,0x2e1b21385c26c926
	data8	0x4d2c6dfc5ac42aed,0x53380d139d95b3df
	data8	0x650a73548baf63de,0x766a0abb3c77b2a8
	data8	0x81c2c92e47edaee6,0x92722c851482353b
	data8	0xa2bfe8a14cf10364,0xa81a664bbc423001
	data8	0xc24b8b70d0f89791,0xc76c51a30654be30
	data8	0xd192e819d6ef5218,0xd69906245565a910
	data8	0xf40e35855771202a,0x106aa07032bbd1b8
	data8	0x19a4c116b8d2d0c8,0x1e376c085141ab53
	data8	0x2748774cdf8eeb99,0x34b0bcb5e19b48a8
	data8	0x391c0cb3c5c95a63,0x4ed8aa4ae3418acb
	data8	0x5b9cca4f7763e373,0x682e6ff3d6b2b8a3
	data8	0x748f82ee5defb2fc,0x78a5636f43172f60
	data8	0x84c87814a1f0ab72,0x8cc702081a6439ec
	data8	0x90befffa23631e28,0xa4506cebde82bde9
	data8	0xbef9a3f7b2c67915,0xc67178f2e372532b
	data8	0xca273eceea26619c,0xd186b8c721c0c207
	data8	0xeada7dd6cde0eb1e,0xf57d4f7fee6ed178
	data8	0x06f067aa72176fba,0x0a637dc5a2c898a6
	data8	0x113f9804bef90dae,0x1b710b35131c471b
	data8	0x28db77f523047d84,0x32caab7b40c72493
	data8	0x3c9ebe0a15c9bebc,0x431d67c49c100d4c
	data8	0x4cc5d4becb3e42b6,0x597f299cfc657e2a
	data8	0x5fcb6fab3ad6faec,0x6c44198c4a475817
.size	K512#,$SZ*$rounds
stringz	"SHA512 block transform for IA64, CRYPTOGAMS by <https://github.com/dot-asm>"
___
