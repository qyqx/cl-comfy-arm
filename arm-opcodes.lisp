;;; -*- mode: Lisp; Package: ("ARM" "CL"); Syntax: ANSI-Common-Lisp; -*-
;;;
;;; arm-opcodes.lisp
;;;

(cl:defpackage "ARM"
  (:use "CL")
  (:export
   "R0" "R1" "R2" "R3" "R4" "R5" "R6" "R7"
   "R8" "R9" "R10" "R11" "R12" "R13" "R14" "R15"
   "FP" ; alias for R11
   "IP" ; alias for R12
   "SP" ; alias for R13
   "LR" ; alias for R14
   "PC" ; alias for R15
   "EQ" "NE" "CS" "HS" "CC" "LO" "MI" "PL"
   "VS" "VC" "HI" "LS" "GE" "LT" "GT" "LE"
   "AL"
   "S" "LSL" "LSR" "ASR" "ROR" "RRX" "#"
   "MVN" "MOV" "ORR" "CMN" "BIC" "CMP" "TEQ" "TST" "RSC"
   "SBC" "ADC" "ADD" "RSB" "SUB" "EOR" "AND"
    "LDMDA" "LDMFA" "LDMIA" "LDMFD"
    "LDMDB" "LDMEA" "LDMIB" "LDMED"
    "STMDA" "STMED" "STMIA" "STMEA"
    "STMDB" "STMFD" "STMIB" "STMFA"
))

(cl:in-package "ARM")

(define-condition arm-error (error) ())

(define-condition bad-argument-count (arm-error)
  ((opcode :reader opcode :initarg opcode)
   (arglist :reader arglist :initarg arglist)
   (expected-count :reader expected-count :initarg expected-count))
  (:report (lambda (condition stream)
	     (format stream "opcode ~A accepts only ~D arguments, given ~A."
		     (opcode condition)
		     (expected-count condition)
		     (arglist condition)))))

(define-condition bad-condition-code (arm-error)
  ((condition-code :reader condition-code :initarg condition-code))
  (:report (lambda (condition stream)
	     (format stream "~A is not a valid condition code."
		     (condition-code condition)))))

(define-condition bad-register (arm-error)
  ((register :reader register :initarg register))
  (:report (lambda (condition stream)
	     (format stream "~A is not a valid register."
		     (register condition)))))

(define-condition bad-opcode (arm-error)
  ((opcode :reader opcode :initarg opcode))
  (:report (lambda (condition stream)
	     (format stream "~A is not a valid opcode for this instruction type."
		     (opcode condition)))))

(define-condition bad-immediate-32 (arm-error)
  ((immediate :reader immediate :initarg immediate))
  (:report (lambda (condition stream)
	     (format stream "~A cannot be encoded as an immediate value."
		     (immediate condition)))))

(define-condition bad-shift-type (arm-error)
  ((shift-type :reader shift-type :initarg shift-type))
  (:report (lambda (condition stream)
	     (format stream "~A is not a valid shift type."
		     (shift-type condition)))))

(defclass instruction ()
  ((opcode :accessor opcode :initarg opcode)
   (condition :accessor condition :initarg condition
	      :initform 'AL
	      :documentation "Conditional execution: NIL or ARM:AL indicate always")
   (update :accessor update :initarg update :initform NIL
	   :documentation "Non-nil indicates the instruction updates the condition flag")))

(defclass data-processing (instruction)
  ((rn :accessor rn :initarg rn :documentation "First source operation")
   (rd :accessor rd :initarg rd :documentation "Destination register")))

(defclass immediate (data-processing)
  ((rotate_imm :accessor rotate_imm :initarg rotate_imm)
   (immed_8 :accessor immed_8 :initarg immed_8)))

(defclass immediate-shift (data-processing)
  ((rm :accessor rm :initarg rm :documentation "Shifter operand register")
   (shift_imm :accessor shift_imm :initarg shift_imm)
   (shift :accessor shift :initarg shift)))

(defclass register-shift (data-processing)
  ((rm :accessor rm :initarg rm :documentation "Shifter operand register")
   (rs :accessor rs :initarg rs :documentation "Shifter shift register")
   (shift :accessor shift :initarg shift)))

(defclass load/store-multiple (instruction)
  ((rn :accessor rn :initarg rn :documentation "Storage pointer")
   (update-rn :accessor update-rn :initarg update-rn :documentation 
	      "non-NIL if Rn is updated after the load/store.")
   (regs :accessor regs :initarg regs :documentation "List of registers")))
  
(defun encode-condition (cond)
  (case cond
    (EQ #b0000)
    (NE #b0001)
    ((CS HS) #b0010)
    ((CC LO) #b0011)
    (MI #b0100)
    (PL #b0101)
    (VS #b0110)
    (VC #b0111)
    (HI #b1000)
    (LS #b1001)
    (GE #b1010)
    (LT #b1011)
    (GT #b1100)
    (LE #b1101)
    ((AL nil) #b1110)
    (t (error 'bad-condition-code 'condition-code cond))))

(defun encode-register (reg)
  (let ((r (position reg
		     '(r0 r1 r2 r3 r4 r5 r6 r7 r8 
		       r9 r10 r11 r12 r13 r14 r15))))
    (cond 
      (r r)
      ((eq reg 'FP) 11)
      ((eq reg 'IP) 12)
      ((eq reg 'SP) 13)
      ((eq reg 'LR) 14)
      ((eq reg 'PC) 15)
      (t (error 'bad-register 'register reg)))))

;;; 32-bit immediates.
;;; if IMMEDIAT is the eight-bit value
;;; 0000 0000 0000 0000 0000 0000 IMME DIAT  rotate_imm = 0
;;; (mandatory if VAL in range 0 to 255)
;;;
;;; values of rotate_imm from 1 to 3 split immed_8
;;;
;;; AT00 0000 0000 0000 0000 0000 00IM MEDI  rotate_imm = 1
;;; DIAT 0000 0000 0000 0000 0000 0000 IMME               2
;;; MEDI AT00 0000 0000 0000 0000 0000 00IM               3
;;;
;;; values of rotate_imm from 4 to 15 are equivalent to 
;;; left shifts by (- 32 (* 2 rotate_imm))
;;;
;;; IMME DIAT 0000 0000 0000 0000 0000 0000               4
;;; 00IM MEDI AT00 0000 0000 0000 0000 0000               5
;;; 0000 IMME DIAT 0000 0000 0000 0000 0000               6
;;; 0000 00IM MEDI AT00 0000 0000 0000 0000               7
;;; 0000 0000 IMME DIAT 0000 0000 0000 0000               8
;;; 0000 0000 00IM MEDI AT00 0000 0000 0000               9
;;; 0000 0000 0000 IMME DIAT 0000 0000 0000              10
;;; 0000 0000 0000 00IM MEDI AT00 0000 0000              11
;;; 0000 0000 0000 0000 IMME DIAT 0000 0000              12
;;; 0000 0000 0000 0000 00IM MEDI AT00 0000              13
;;; 0000 0000 0000 0000 0000 IMME DIAT 0000              14
;;; 0000 0000 0000 0000 0000 00IM MEDI AT00              15

(defun encode-32-bit-immediate (val)
  "Returns two values: an 8-bit IMMED_8 and 4 bit ROTATE_IMM, 
such that VAL is equal to IMMED_8 rotated right by (* 2 ROTATE_IMM) bits
or NIL if VAL cannot be so encoded."
  (cond
    ((not (integerp val)) nil)
    ((<= 0 val #xFF) (values val 0))
    (t
     (loop for shift from 2 to 30 by 2
	with immed-high = 0 and immed-low = 0 and immed = 0
	do (if (< shift 8) 
	       (setf immed-high (ldb (byte shift (- 32 shift))
				     val)
		     immed-low (ldb (byte (- 8 shift) 0) val))
	       (setf immed (ldb (byte 8 (- 32 shift)) val)))
	when (or (and (< shift 8)
		      (= val (dpb immed-high (byte shift (- 32 shift))
				  (dpb immed-low (byte (- 8 shift) 0) 0))))
		 (and (>= shift 8)
		      (= val (dpb immed (byte 8 (- 32 shift)) 0))))
	return (values
		(if (< shift 8) (dpb immed-high (byte shift (- 8 shift)) 
				     (dpb immed-low (byte (- 8 shift) 0) 0))
		    immed)
		(/ shift 2))
	finally (return nil)))))
      
(defun encode-data-processing-opcodes (opcode)
  "bits 24..21 of a data-processing instruction."
  (case opcode
    (and #b0000)
    (eor #b0001)
    (sub #b0010)
    (rsb #b0011)
    (add #b0100)
    (adc #b0101)
    (sbc #b0110)
    (rsc #b0111)
    (tst #b1000)
    (teq #b1001)
    (cmp #b1010)
    (cmn #b1011)
    (orr #b1100)
    (mov #b1101)
    (bic #b1110)
    (mvn #b1111)
    (t (error 'bad-opcode 'opcode opcode))))

(defun encode-update (s)
  (if s 1 0))

(defmethod encode ((insn data-processing))
  (let ((cond (encode-condition (condition insn)))
	(rn (encode-register (rn insn)))
	(rd (encode-register (rd insn)))
	(opcode (encode-data-processing-opcodes (opcode insn)))
	(s (encode-update (update insn)))
	(word 0))
    (setf (ldb (byte 4 28) word) cond
	  (ldb (byte 4 21) word) opcode
	  (ldb (byte 1 20) word) s
	  (ldb (byte 4 16) word) rn
	  (ldb (byte 4 12) word) rd)
    word))

(defmethod encode ((insn immediate))
  (let ((word (call-next-method)))
    (setf (ldb (byte 3 25) word) #b001
	  (ldb (byte 4 8) word) (rotate_imm insn)
	  (ldb (byte 8 0) word) (immed_8 insn))
    word))

;; shift = 0, shift_imm = 0: register
;; shift = 0, shift_imm != 0: LSL #shift_imm

(defmethod encode ((insn immediate-shift))
  (let ((word (call-next-method))
	(rm (encode-register (rm insn))))
    (setf (ldb (byte 3 25) word) #b000
	  (ldb (byte 5 7) word) (shift_imm insn)
	  (ldb (byte 2 5) word) (shift insn)
	  (ldb (byte 1 4) word) 0
	  (ldb (byte 4 0) word) rm)
    word))

;; shift = #b00: LSL
;; shift = #b01: LSR
;; shift = #b10: ASR
;; shift = #b11: ROR
;; ROR #0 -> RRX

(defun encode-shift (shift-sym)
  "Returns the integer encoding for a shift-symbol; 
NIL equivalent to LSL #0, RRX equivalent to ROR #0"
  (case shift-sym
    ((LSL nil) #b00)
    (LSR #b01)
    (ASR #b10)
    ((ROR RRX) #b11)
    (t (error 'bad-shift-type 'shift-type shift-sym))))

(defmethod encode ((insn register-shift))
  (let ((word (call-next-method))
	(rs (encode-register (rs insn)))
	(rm (encode-register (rm insn))))
    (setf (ldb (byte 3 25) word) #b000
	  (ldb (byte 4 8) word) rs
	  (ldb (byte 1 7) word) 0
	  (ldb (byte 2 5) word) (shift insn)
	  (ldb (byte 1 4) word) 1
	  (ldb (byte 4 0) word) rm)
    word))

;;; S-expression instruction syntax
;;;
;;; Data-processing instructions
;;; ----------------------------
;;;
;;; opcodes with no flags, or S = 0, cond = always
;;;
;;; (opcode <Rd> <Rn> <shifter_operand>)
;;; 
;;; when only two arguments after the opcode
;;; 
;;;   for MOV, MVN (opcode <Rd> <shifter_operand>) Rn is always encoded as R0
;;;   for CMP, CMN, TST, TEQ S=1 always, and it is 
;;;                (opcode <Rn> <shifter_operand>), Rd is always encoded as R0
;;; 
;;; opcodes with S=1, cond = always
;;;
;;; ((opcode :s) <Rd> <Rn> <shifter_operand>)
;;;
;;; opcodes with S=0, cond other than always
;;;
;;; ((opcode <cond>) <Rd> <Rn> <shifter_operand>)
;;;
;;; opcodes with S=1, cond other always
;;; 
;;; ((opcode arm:s <cond>) <Rd> <Rn> <shifter_operand>)
;;; ((opcode <cond> arm:s) <Rd> <Rn> <shifter_operand>)
;;;
;;; Load/store multiple register instructions
;;; -----------------------------------------
;;;
;;; (opcode <Rn> &rest <register-list>)
;;;
;;; (opcode (<Rn> arm:!) &rest <register-list>)  sets the W bit, updating Rn
;;;
;;; opcode can be symbol (LDMIA, STMDB, etc.) or
;;; (opcode <cond>) (opcode arm:s) (opcode <cond> arm:s) or 
;;;                                (opcode arm:s <cond>) 
;;; where arm:^ can be used as a synonym for arm:s
;;; (The S-bit in LDM with R15/PC in the register list is used to indicate 
;;;  loading of CPSR from the SPSR; in priviledged mode 
;;;  for LDM without R15/PC or STM, the S-bit set indicates the 
;;;  load/store affects user-mode registers)
;;;

(defun split-sexp-opcode (opcode-list)
  "Splits s-expression form of opcodes.

   Returns three values: the bare opcode symbol, 
                         the symbol representing the condition,
                         and T/NIL the S (update) bit is set/not-set

    opcode                 -> AND
    (opcode <cond>)        -> AND<cond>
    (opcode ARM:S)         -> ANDS
    (opcode <cond> ARM:S)  -> AND<cond>S
    (opcode ARM:S <cond>)  -> AND<cond>S" 
  (cond 
    ((symbolp opcode-list) (values opcode-list 'AL nil)) ; bare opcode: S=0, cond=always
    ((not (consp opcode-list)) (error 'bad-opcode 'opcode opcode-list))
    ((null (cddr opcode-list)) ; one decorating symbol
     (let ((decorator (second opcode-list)))
       (cond 
	 ((eq decorator 's) (values (car opcode-list) 'al t))
	 ((encode-condition decorator) (values (car opcode-list) 
					       decorator nil))
	 (t (error 'bad-condition 'condition decorator)))))
    ((null (cdddr opcode-list)) 
     ;; two decorators, one must be S, the other
     ;; the condition
     (let ((s (find 's (cdr opcode-list)))
	   (condition (remove 's (cdr opcode-list))))
       (cond ((and s 
		   (null (cdr condition))
		   (encode-condition (car condition)))
	      (values (car opcode-list) (car condition) s))
	     (s ; s, but bogus condition
	      (error 'bad-condition 'condition (car condition)))
	     ((cdr condition) ; no s, but two symbols
	      (error 'bad-condition 'condition condition)))))
    (t (error 'bad-opcode 'opcode opcode-list))))

;;; <shifter_operand>
;;;
;;; immediate: (ARM:\# immediate-value)
;;; register: <Rm>
;;; <Rm>, LSL #<shift_imm>: (<Rm> arm:lsl (arm:\# immediate-value))
;;; <Rm>, LSL <Rs>: (<Rm> arm:lsl <Rs>)
;;; <Rm>, LSR #<shift_imm>: (<Rm> arm:lsr (arm:\# immediate-value))
;;; <Rm>, LSR <Rs>: (<Rm> arm:lsr <Rs>)
;;; <Rm>, ASR #<shift_imm>: (<Rm> arm:asr (arm:\# immediate-value))
;;; <Rm>, ASR <Rs>: (<Rm> arm:asr <Rs>)
;;; <Rm>, ROR #<shift_imm>: (<Rm> arm:ror (arm:\# immediate-value))
;;; <Rm>, ROR <Rs>: (<Rm> arm:ror <Rs>)
;;; <Rm>, RRX: (<Rm> arm:rrx)
;;; 

(defun split-sexp-shifter (shifter-op)
  "Returns three values
    Rm 
    Shift-type encoding bits
    Shift-value integer or symbol for Rs.

TODO: shift-value integers should be checked for magnitude"
  (cond
    ((symbolp shifter-op) ; Rm alone, equivalent to LSL #0
     (values shifter-op (encode-shift 'LSL) 0))
    ((and (consp shifter-op) 
	  (null (cddr shifter-op))
	  (eq (second shifter-op) 'RRX)) ; RRX = ROR #0
     (values (first shifter-op) (encode-shift 'ROR) 0))
    ((and (consp shifter-op)
	  (symbolp (third shifter-op)))
     (if (eq (second shifter-op)
	     'RRX)
	 (error 'bad-shift-type 'shift-type shifter-op)
	 (values (first shifter-op) (encode-shift (second shifter-op))
		 (third shifter-op))))
    ((and (consp shifter-op)
	  (consp (third shifter-op))
	  (eq (car (third shifter-op)) '\#))
     (values (first shifter-op) (encode-shift (second shifter-op))
	     (second (third shifter-op))))
    (t (error 'bad-shift-type 'shift-type shifter-op))))

;; load/store-multiple bits

(defun load/store-bits (opcode)
  "Returns three values: (T/NIL respectively)
L (load/store)
P (address included in storage/not-included)
U (transfer made upwards/downwards)"

  (case opcode 
    ((LDMDA LDMFA) (values t nil nil))
    ((LDMIA LDMFD) (values t nil t))
    ((LDMDB LDMEA) (values t t nil))
    ((LDMIB LDMED) (values t t t))
    ((STMDA STMED) (values nil nil nil))
    ((STMIA STMEA) (values nil nil t))
    ((STMDB STMFD) (values nil t nil))
    ((STMIB STMFA) (values nil t t))
    (t (error 'bad-opcode 'opcode opcode))))
    
(defun opcode-to-instruction (symbolic-opcode)
  (let ((opcode (first symbolic-opcode)))
    (multiple-value-bind (op condition update)
	(split-sexp-opcode opcode)
      (cond 
	((encode-data-processing-opcodes op)	
	 
	 ;; basic checks for argument count
	 (cond ((member op '(MOV MVN CMP CMN TST TEQ))
		(unless (null (cdddr symbolic-opcode))
		  (error 'bad-argument-count
			 'opcode op 
			 'arglist (rest symbolic-opcode)
			 'expected-count 2)))
	       (t (unless (null (cddddr symbolic-opcode))
		  (error 'bad-argument-count
			 'opcode op 
			 'arglist (rest symbolic-opcode)
			 'expected-count 3))))
	 (let ((shifter-op
		(cond ((member op '(MOV MVN CMP CMN TST TEQ))
		       (third symbolic-opcode))
		      (t (fourth symbolic-opcode))))
	       (rd 
		(cond ((member op '(CMP CMN TST TEQ))
		       'arm:r0) ; encoded as zero
		      (t (second symbolic-opcode))))
	       (rn
		(cond ((member op '(MOV MVN)) 'arm:r0) ; encoded as zero
		      ((member op '(CMP CMN TST TEQ))
		       (second symbolic-opcode))
		      (t (third symbolic-opcode))))
	       (s (cond ((member op '(CMP CMN TST TEQ)) ; imply S=1
			 t)
			(t update))))
	   (cond 
	     ((symbolp shifter-op)
	      (make-instance 'immediate-shift
			     'opcode op
			     'condition condition
			     'update s
			     'rd rd
			     'rn rn
			     'rm shifter-op
			     'shift 0
			     'shift_imm 0))
	     ((and (consp shifter-op)
		   (eq (car shifter-op) 'arm:\#))
	      (multiple-value-bind (immed-8 rotate-imm)
		  (encode-32-bit-immediate (cadr shifter-op))
		(if immed-8
		    (make-instance 'immediate
				   'condition condition
				   'update s
				   'opcode op
				   'rd rd
				   'rn rn
				   'rotate_imm rotate-imm 
				   'immed_8 immed-8)
		    (error 'bad-immediate-32 'immediate 
			   (cadr shifter-op)))))
	     ((and (consp shifter-op)
		   (member (second shifter-op) 
			   '(LSL LSR ASR ROR RRX)))
	      (multiple-value-bind (rm shift-code shift-reg-or-imm)
		  (split-sexp-shifter shifter-op)
		(if (symbolp shift-reg-or-imm)
		    (make-instance 'register-shift
				   'opcode op
				   'update s
				   'condition condition
				   'rd rd
				   'rn rn
				   'rm rm
				   'shift shift-code
				   'rs shift-reg-or-imm)
		    (make-instance 'immediate-shift
				   'opcode op
				   'update s
				   'condition condition
				   'rd rd
				   'rn rn
				   'rm rm
				   'shift shift-code
				   'shift_imm shift-reg-or-imm))))
	  (t (error "Not yet implemented.")))))))))
    
