; Licensed to the .NET Foundation under one or more agreements.
; The .NET Foundation licenses this file to you under the MIT license.

; ***********************************************************************
; File: JitHelpers_Fast.asm
;
; Notes: routinues which we believe to be on the hot path for managed
;        code in most scenarios.
; ***********************************************************************


include AsmMacros.inc
include asmconstants.inc

; Min amount of stack space that a nested function should allocate.
MIN_SIZE equ 28h

EXTERN  g_ephemeral_low:QWORD
EXTERN  g_ephemeral_high:QWORD
EXTERN  g_lowest_address:QWORD
EXTERN  g_highest_address:QWORD
EXTERN  g_card_table:QWORD
EXTERN  g_region_shr:BYTE
EXTERN  g_region_use_bitwise_write_barrier:BYTE
EXTERN  g_region_to_generation_table:QWORD

ifdef FEATURE_MANUALLY_MANAGED_CARD_BUNDLES
EXTERN g_card_bundle_table:QWORD
endif

ifdef FEATURE_USE_SOFTWARE_WRITE_WATCH_FOR_GC_HEAP
EXTERN  g_write_watch_table:QWORD
EXTERN  g_sw_ww_enabled_for_gc_heap:BYTE
endif

ifdef WRITE_BARRIER_CHECK
; Those global variables are always defined, but should be 0 for Server GC
g_GCShadow                      TEXTEQU <?g_GCShadow@@3PEAEEA>
g_GCShadowEnd                   TEXTEQU <?g_GCShadowEnd@@3PEAEEA>
EXTERN  g_GCShadow:QWORD
EXTERN  g_GCShadowEnd:QWORD
endif

INVALIDGCVALUE          equ     0CCCCCCCDh

ifdef _DEBUG
extern JIT_WriteBarrier_Debug:proc
endif

ifndef FEATURE_SATORI_GC

Section segment para 'DATA'

        align   16

        public  JIT_WriteBarrier_Loc
JIT_WriteBarrier_Loc:
        dq 0

; There is an even more optimized version of these helpers possible which takes
; advantage of knowledge of which way the ephemeral heap is growing to only do 1/2
; that check (this is more significant in the JIT_WriteBarrier case).
;
; Additionally we can look into providing helpers which will take the src/dest from
; specific registers (like x86) which _could_ (??) make for easier register allocation
; for the JIT64, however it might lead to having to have some nasty code that treats
; these guys really special like... :(.
;
; Version that does the move, checks whether or not it's in the GC and whether or not
; it needs to have it's card updated
;
; void JIT_CheckedWriteBarrier(Object** dst, Object* src)
LEAF_ENTRY JIT_CheckedWriteBarrier, _TEXT

        ; When WRITE_BARRIER_CHECK is defined _NotInHeap will write the reference
        ; but if it isn't then it will just return.
        ;
        ; See if this is in GCHeap
        cmp     rcx, [g_lowest_address]
        jb      NotInHeap
        cmp     rcx, [g_highest_address]
        jnb     NotInHeap

        jmp     QWORD PTR [JIT_WriteBarrier_Loc]

    NotInHeap:
        ; See comment above about possible AV
        mov     [rcx], rdx
        ret
LEAF_END_MARKED JIT_CheckedWriteBarrier, _TEXT



else

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

Section segment para 'DATA'

        align   16

        public  JIT_WriteBarrier_Loc
JIT_WriteBarrier_Loc:
        dq 0

LEAF_ENTRY  JIT_WriteBarrier_Callable, _TEXT
        ; JIT_WriteBarrier(Object** dst, Object* src)
        jmp     JIT_WriteBarrier
LEAF_END JIT_WriteBarrier_Callable, _TEXT


; void JIT_CheckedWriteBarrier(Object** dst, Object* src)
LEAF_ENTRY JIT_CheckedWriteBarrier, _TEXT

        ; See if this is in GCHeap
        cmp     rcx, [g_highest_address]
        jnb     NotInHeap

        mov     rax, rcx
        shr     rax, 30                 ; round to page size ( >> PAGE_BITS )
        add     rax, [g_card_table]
        cmp     byte ptr [rax], 0
        jnz     JIT_WriteBarrier

    NotInHeap:
        ; See comment above about possible AV
        mov     [rcx], rdx
        ret
LEAF_END_MARKED JIT_CheckedWriteBarrier, _TEXT


; Mark start of the code region that we patch at runtime
LEAF_ENTRY JIT_PatchedCodeStart, _TEXT
        ret
LEAF_END JIT_PatchedCodeStart, _TEXT

;
;   rcx - dest address 
;   rdx - object
;
LEAF_ENTRY JIT_WriteBarrier, _TEXT
    ; check for escaping assignment
    ; 1) check if we own the source region
        mov     r8, rdx
        and     r8, 0FFFFFFFFFFE00000h  ; source region
        jz      JustAssign              ; assigning null   
        mov     rax,  gs:[30h]          ; thread tag, TEB on NT
        cmp     qword ptr [r8], rax     
        jne     AssignAndMarkCards      ; not local to this thread

    ; 2) check if the src and dst are from the same region
        mov     rax, rdx
        xor     rax, rcx
        shr     rax, 21
        jnz     RecordEscape            ; cross region assignment. definitely escaping

    ; 3) check if the target is exposed
        mov     rax, rcx
        and     rax, 01FFFFFh
        shr     rax, 3
        bt      qword ptr [r8], rax
        jb      RecordEscape            ; target is exposed. record an escape.

    JustAssign:
        mov     [rcx], rdx              ; threadlocal assignment of unescaped object
        ret

    RecordEscape:
        ; save rcx, rdx, r8 and have enough stack for the callee
        push rcx
        push rdx
        push r8
        sub  rsp, 20h

        ; void SatoriRegion::EscapeFn(SatoriObject** dst, SatoriObject* src, SatoriRegion* region)
        call    qword ptr [r8 + 8]

        add     rsp, 20h
        pop     r8
        pop     rdx
        pop     rcx

    AssignAndMarkCards:
        mov     [rcx], rdx

    ; TODO: VS for throughput tuning a nonconcurrent and concurrent paths could be separated 
    ;       need to suspend EE when swapping barriers, but GCs in that mode should be relatively rare

    ; check if src is in gen2
        cmp     dword ptr [r8 + 16], 2
        jne     SrcEphemeral
        cmp     byte ptr [g_sw_ww_enabled_for_gc_heap], 0h
        jne     SrcEphemeral
        REPRET

    SrcEphemeral:
    ; fetch card location for rcx
        mov     r8,  rcx
        mov     r9 , [g_card_table]     ; fetch the page map
        mov     rax, rcx
        shr     rax, 30
     CheckPageMap:                               
        movzx   ecx, byte ptr [r9 + rax]
        cmp     cl, 1
        je      PageFound
        add     cl, -2
        mov     edx, 1
        shl     rdx, cl
        sub     rax, rdx
        jmp     CheckPageMap
     PageFound:
        shl     rax, 30   ; page
        sub     r8, rax   ; offset in page
        mov     rdx,r8
        shr     r8, 9     ; card offset
        shr     rdx, 21   ; group offset

    ; check if concurrent marking is in progress
        cmp     byte ptr [g_sw_ww_enabled_for_gc_heap], 0h
        jne     DirtyCard

    ; SETTING CARD FOR RCX
     SetCard:
        cmp     byte ptr [rax + r8], 0
        jne     CardSet
        mov     byte ptr [rax + r8], 1
     SetGroup:
        cmp     byte ptr [rax + rdx * 2 + 80h], 0
        jne     CardSet
        mov     byte ptr [rax + rdx * 2 + 80h], 1
     SetPage:
        cmp     byte ptr [rax], 0
        jne     CardSet
        mov     byte ptr [rax], 1

     CardSet:
    ; check if concurrent marking is still not in progress
        cmp     byte ptr [g_sw_ww_enabled_for_gc_heap], 0h
        jne     DirtyCard
        REPRET

    ; DIRTYING CARD FOR RCX
     DirtyCard:
        mov     byte ptr [rax + r8], 3
     DirtyGroup:
        mov     byte ptr [rax + rdx * 2 + 80h], 3
     DirtyPage:
        mov     byte ptr [rax], 3

    Exit:
        ret
LEAF_END_MARKED JIT_WriteBarrier, _TEXT

; Mark start of the code region that we patch at runtime
LEAF_ENTRY JIT_PatchedCodeLast, _TEXT
        ret
LEAF_END JIT_PatchedCodeLast, _TEXT

; JIT_ByRefWriteBarrier has weird symantics, see usage in StubLinkerX86.cpp
;
; Entry:
;   RDI - address of ref-field (assigned to)
;   RSI - address of the data  (source)
;   Note: RyuJIT assumes that all volatile registers can be trashed by 
;   the CORINFO_HELP_ASSIGN_BYREF helper (i.e. JIT_ByRefWriteBarrier)
;   except RDI and RSI. This helper uses and defines RDI and RSI, so
;   they remain as live GC refs or byrefs, and are not killed.
; Exit:
;   RDI, RSI are incremented by SIZEOF(LPVOID)
LEAF_ENTRY JIT_ByRefWriteBarrier, _TEXT
        mov     rcx, rdi
        mov     rdx, [rsi]
        add     rdi, 8h
        add     rsi, 8h

        ; See if assignment is into heap
        cmp     rcx, [g_highest_address]
        jnb     NotInHeap               ; not in heap

        mov     rax, rcx
        shr     rax, 30                 ; round to page size ( >> PAGE_BITS )
        add     rax, [g_card_table]
        cmp     byte ptr [rax], 0
        je      NotInHeap               ; not in heap

        jmp     JIT_WriteBarrier

    align 16
    NotInHeap:
        mov     [rcx], rdx
        ret
LEAF_END_MARKED JIT_ByRefWriteBarrier, _TEXT


;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

endif

; The following helper will access ("probe") a word on each page of the stack
; starting with the page right beneath rsp down to the one pointed to by r11.
; The procedure is needed to make sure that the "guard" page is pushed down below the allocated stack frame.
; The call to the helper will be emitted by JIT in the function/funclet prolog when large (larger than 0x3000 bytes) stack frame is required.
;
; NOTE: this helper will NOT modify a value of rsp and can be defined as a leaf function.

PROBE_PAGE_SIZE equ 1000h

LEAF_ENTRY JIT_StackProbe, _TEXT
        ; On entry:
        ;   r11 - points to the lowest address on the stack frame being allocated (i.e. [InitialSp - FrameSize])
        ;   rsp - points to some byte on the last probed page
        ; On exit:
        ;   rax - is not preserved
        ;   r11 - is preserved
        ;
        ; NOTE: this helper will probe at least one page below the one pointed by rsp.

        mov     rax, rsp               ; rax points to some byte on the last probed page
        and     rax, -PROBE_PAGE_SIZE  ; rax points to the **lowest address** on the last probed page
                                       ; This is done to make the following loop end condition simpler.

ProbeLoop:
        sub     rax, PROBE_PAGE_SIZE   ; rax points to the lowest address of the **next page** to probe
        test    dword ptr [rax], eax   ; rax points to the lowest address on the **last probed** page
        cmp     rax, r11
        jg      ProbeLoop              ; If (rax > r11), then we need to probe at least one more page.

        ret

LEAF_END_MARKED JIT_StackProbe, _TEXT

LEAF_ENTRY JIT_ValidateIndirectCall, _TEXT
        ret
LEAF_END JIT_ValidateIndirectCall, _TEXT

LEAF_ENTRY JIT_DispatchIndirectCall, _TEXT
ifdef _DEBUG
        mov r10, 0CDCDCDCDCDCDCDCDh ; The real helper clobbers these registers, so clobber them too in the fake helper
        mov r11, 0CDCDCDCDCDCDCDCDh
endif
        rexw jmp rax
LEAF_END JIT_DispatchIndirectCall, _TEXT


        end
