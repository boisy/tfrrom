* A simple program to transfer the contents of a contiguous block of memory
* over the CoCo's bit-banger port to a host.

* Set the beginning and end of desired memory to send
TFRBEG	equ		$C000
TFREND	equ		$DFFF

BBOUT       equ    $FF20
BBIN        equ    $FF22
OP_WRITE    equ    'W		Write one sector
OP_NAMEOBJ_MOUNT	equ	$01
OP_NAMEOBJ_CREATE	equ	$02

		org		$6000
Start
* Create the named object
		lda		#OP_NAMEOBJ_CREATE
		leax	ObjCr,pcr
		sta		,x
		ldy		#ObjCrL
 		lbsr	DWWrite
 		lbcs	Error

* Get the response from the create 		
 		leax	ObjNum,pcr
 		ldy		#$0001
 		lbsr	DWRead
 		lbcs	Error
		tst		ObjNum,pcr			0?
		bne		StartTfr
		
* If the create failed, mount the named object
		lda		#OP_NAMEOBJ_MOUNT
		leax	ObjCr,pcr
		sta		,x
		ldy		#ObjCrL
 		lbsr	DWWrite
 		lbcs	Error

* Get the response from the mount
 		leax	ObjNum,pcr
 		ldy		#$0001
 		lbsr	DWRead
 		bcs		Error
		tst		ObjNum,pcr			0?
		beq		Error

* Begin transferring
StartTfr
 		ldu		#TFRBEG
 		clr		LSN12+1,pcr
 		
WriteIt 		
		leax	WriteBlock,pcr
		ldy		#5
		lbsr	DWWrite
		inc		LSN12+1,pcr
		
* send 256 bytes	
		tfr		u,x
 		ldy		#256
		lbsr	DWWrite

* compute and send checksum
 		tfr     u,x
 		ldy		#256
 		lbsr	ComputeChecksum
        std     CSum,pcr
        leax	CSum,pcr
        ldy		#$0002
		lbsr	DWWrite
  		
* read response from server to OP_WRITE  		
		leax	Response,pcr
  		ldy		#$0001
  		lbsr	DWRead
  		bcs		Error
  		tst		Response,pcr
  		bne		Error
  		
* continue if not done
        leau    256,u
        cmpu	#TFREND
        bls		WriteIt
Error
 		rts

ComputeChecksum
		clra
		clrb
cl@
        addb    ,x+
        adca	#0
        leay    -1,y
        bne     cl@
        rts
        
WriteBlock
        fcb     OP_WRITE
ObjNum	fcb     $00
LSN0    fcb     $00
LSN12   fcb     $00,$00
CSum    fcb     $00,$00
        
ObjCr	fcb		$02
		fcb		NameLen
Name	fcc		"XROM"
NameLen	equ		*-Name
ObjCrL	equ		*-ObjCr

Response fcb	$00

NOINTMASK	equ	0
IntMasks	equ	$50
		
*******************************************************
*
* DWRead
*    Receive a response from the DriveWire server.
*    Times out if serial port goes idle for more than 1.4 (0.7) seconds.
*    Serial data format:  1-8-N-1
*    4/12/2009 by Darren Atkinson
*
* Entry:
*    X  = starting address where data is to be stored
*    Y  = number of bytes expected
*
* Exit:
*    CC = carry set on framing error, Z set if all bytes received
*    X  = starting address of data received
*    Y  = checksum
*    U is preserved.  All accumulators are clobbered
*

*******************************************************
* 57600 (115200) bps using 6809 code and timimg
*******************************************************

DWRead    clra                          ; clear Carry (no framing error)
          deca                          ; clear Z flag, A = timeout msb ($ff)
          tfr       cc,b
          pshs      u,x,dp,b,a          ; preserve registers, push timeout msb
          IFEQ      NOINTMASK
          orcc      #IntMasks           ; mask interrupts
          ENDC
          tfr       a,dp                ; set direct page to $FFxx
          setdp     $ff
          leau      ,x                  ; U = storage ptr
          ldx       #0                  ; initialize checksum
          lda       #$01                ; A = serial in mask
          bra       rx0030              ; go wait for start bit

* Read a byte
rxByte    leau      1,u                 ; bump storage ptr
          leay      ,-y                 ; decrement request count
          lda       <BBIN               ; read bit 0
          lsra                          ; move bit 0 into Carry
          ldd       #$ff20              ; A = timeout msb, B = shift counter
          sta       ,s                  ; reset timeout msb for next byte
          rorb                          ; rotate bit 0 into byte accumulator
rx0010    lda       <BBIN               ; read bit (d1, d3, d5)
          lsra
          rorb
          bita      1,s                 ; 5 cycle delay
          bcs       rx0020              ; exit loop after reading bit 5
          lda       <BBIN               ; read bit (d2, d4)
          lsra
          rorb
          leau      ,u
          bra       rx0010

rx0020    lda       <BBIN               ; read bit 6
          lsra
          rorb
          leay      ,y                  ; test request count
          beq       rx0050              ; branch if final byte of request
          lda       <BBIN               ; read bit 7
          lsra
          rorb                          ; byte is now complete
          stb       -1,u                ; store received byte to memory
          abx                           ; update checksum
          lda       <BBIN               ; read stop bit
          anda      #$01                ; mask out other bits
          beq       rxExit              ; exit if framing error

* Wait for a start bit or timeout
rx0030    bita      <BBIN               ; check for start bit
          beq       rxByte              ; branch if start bit detected
          bita      <BBIN               ; again
          beq       rxByte
          ldb       #$ff                ; init timeout lsb
rx0040    bita      <BBIN
          beq       rxByte
          subb      #1                  ; decrement timeout lsb
          bita      <BBIN
          beq       rxByte
          bcc       rx0040              ; loop until timeout lsb rolls under
          bita      <BBIN
          beq       rxByte
          addb      ,s                  ; B = timeout msb - 1
          bita      <BBIN
          beq       rxByte
          stb       ,s                  ; store decremented timeout msb
          bita      <BBIN
          beq       rxByte
          bcs       rx0030              ; loop if timeout hasn't expired
          bra       rxExit              ; exit due to timeout

rx0050    lda       <BBIN               ; read bit 7 of final byte
          lsra
          rorb                          ; byte is now complete
          stb       -1,u                ; store received byte to memory
          abx                           ; calculate final checksum
          lda       <BBIN               ; read stop bit
          anda      #$01                ; mask out other bits
          ora       #$02                ; return SUCCESS if no framing error

* Clean up, set status and return
rxExit    leas      1,s                 ; remove timeout msb from stack
          inca                          ; A = status to be returned in C and Z
          ora       ,s                  ; place status information into the..
          sta       ,s                  ; ..C and Z bits of the preserved CC
          leay      ,x                  ; return checksum in Y
          puls      cc,dp,x,u,pc        ; restore registers and return
          setdp     $00

*******************************************************
*
* DWWrite
*    Send a packet to the DriveWire server.
*    Serial data format:  1-8-N-1
*    4/12/2009 by Darren Atkinson
*
* Entry:
*    X  = starting address of data to send
*    Y  = number of bytes to send
*
* Exit:
*    X  = address of last byte sent + 1
*    Y  = 0
*    All others preserved
*
*******************************************************
* 57600 (115200) bps using 6809 code and timimg
*******************************************************

DWWrite   pshs      dp,d,cc             ; preserve registers
          IFEQ      NOINTMASK
          orcc      #IntMasks           ; mask interrupts
          ENDC
          ldd       #$04ff              ; A = loop counter, B = $ff
          tfr       b,dp                ; set direct page to $FFxx
          setdp     $ff
          ldb       <$ff23              ; read PIA 1-B control register
          andb      #$f7                ; clear sound enable bit
          stb       <$ff23              ; disable sound output
          fcb       $8c                 ; skip next instruction

txByte    stb       <BBOUT              ; send stop bit
          ldb       ,x+                 ; get a byte to transmit
          nop
          lslb                          ; left rotate the byte two positions..
          rolb                          ; ..placing a zero (start bit) in bit 1
tx0020    stb       <BBOUT              ; send bit (start bit, d1, d3, d5)
          rorb                          ; move next bit into position
          exg       a,a
          nop
          stb       <BBOUT              ; send bit (d0, d2, d4, d6)
          rorb                          ; move next bit into position
          leau      ,u
          deca                          ; decrement loop counter
          bne       tx0020              ; loop until 7th data bit has been sent

          stb       <BBOUT              ; send bit 7
          ldd       #$0402              ; A = loop counter, B = MARK value
          leay      ,-y                 ; decrement byte counter
          bne       txByte              ; loop if more to send

          stb       <BBOUT              ; leave bit banger output at MARK
          puls      cc,d,dp,pc          ; restore registers and return

		end		Start
		