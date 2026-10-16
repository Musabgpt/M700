// =====================================================================
//  M700 Calculator  -  Android app written 100% in ARM64 Assembly
//
//  No Java, no Kotlin, no C. Android's built-in NativeActivity loads
//  libcalc.so and calls ANativeActivity_onCreate (below). Everything
//  else - drawing pixels, the font, touch input and the arithmetic -
//  is done here by hand.
// =====================================================================

        .text
        .p2align 2

#define NBTN        19              // number of buttons

// ---- state block (st) offsets ---------------------------------------
#define S_WINDOW    0               // ANativeWindow*
#define S_QUEUE     8               // AInputQueue*
#define S_BITS      16              // pixel pointer of the locked buffer
#define S_ACC       24              // double: accumulator
#define S_STRIDE    32              // pixels per buffer row
#define S_W         36              // screen width  (pixels)
#define S_H         40              // screen height (pixels)
#define S_PRESSED   44              // index of the button being touched, -1 none
#define S_OP        48              // pending operator key, 0 = none
#define S_NEW       52              // 1 = next digit starts a new number
#define S_ERR       56              // 1 = showing "Error"
#define S_LEN       60              // length of display text
#define S_CELLW     64              // layout: cell width
#define S_CELLH     68              // layout: cell height
#define S_GAP       72              // layout: gap
#define S_TOP       76              // layout: y of the button grid
#define S_INIT      80              // 1 after first start
#define S_DISP      96              // display text, 32 bytes (ASCII)
#define S_BUF       128             // ANativeWindow_Buffer (48 bytes)
#define S_EVT       176             // AInputEvent* scratch
#define S_SIZE      192

// ---- keys (each key number is also its glyph number in the font) ----
#define K_DOT       10
#define K_ADD       11
#define K_SUB       12
#define K_MUL       13
#define K_DIV       14
#define K_EQ        15
#define K_CLR       16
#define K_NEG       17
#define K_BACK      18
#define G_E         19
#define G_R         20
#define G_O         21

// ---- colours, RGBA_8888 in memory = 0xAABBGGRR ----------------------
#define C_BG        0xFF000000      // black
#define C_DIG       0xFF333333      // dark grey   (digits)
#define C_DIG_P     0xFF737373
#define C_FN        0xFFA5A5A5      // light grey  (C, +/-, back)
#define C_FN_P      0xFFD9D9D9
#define C_OP        0xFF0A9FFF      // orange      (operators)
#define C_OP_P      0xFF8DC7FC
#define C_WHITE     0xFFFFFFFF
#define C_BLACK     0xFF000000

// ---- ANativeActivityCallbacks offsets ---------------------------------
#define CB_FOCUS    48
#define CB_WIN_NEW  56
#define CB_WIN_RES  64
#define CB_WIN_DRAW 72
#define CB_WIN_DEL  80
#define CB_Q_NEW    88
#define CB_Q_DEL    96

.macro ADDR reg, sym
        adrp    \reg, \sym
        add     \reg, \reg, :lo12:\sym
.endm

.macro MOV32 reg, val
        movz    \reg, #((\val) & 0xFFFF)
        movk    \reg, #(((\val) >> 16) & 0xFFFF), lsl #16
.endm

// =====================================================================
//  Entry point - called by Android when the activity is created
//  x0 = ANativeActivity*
// =====================================================================
        .globl  ANativeActivity_onCreate
        .type   ANativeActivity_onCreate, %function
ANativeActivity_onCreate:
        stp     x29, x30, [sp, #-32]!
        mov     x29, sp
        str     x19, [sp, #16]
        ldr     x19, [x0]                       // activity->callbacks
        ADDR    x9, on_focus_changed
        str     x9, [x19, #CB_FOCUS]
        ADDR    x9, on_window_created
        str     x9, [x19, #CB_WIN_NEW]
        ADDR    x9, on_window_redraw
        str     x9, [x19, #CB_WIN_RES]
        str     x9, [x19, #CB_WIN_DRAW]
        ADDR    x9, on_window_destroyed
        str     x9, [x19, #CB_WIN_DEL]
        ADDR    x9, on_queue_created
        str     x9, [x19, #CB_Q_NEW]
        ADDR    x9, on_queue_destroyed
        str     x9, [x19, #CB_Q_DEL]

        ADDR    x9, st
        ldr     w10, [x9, #S_INIT]
        cbnz    w10, 1f                         // keep state across re-creation
        mov     w10, #1
        str     w10, [x9, #S_INIT]
        bl      calc_clear
1:      ADDR    x9, st
        mov     w10, #-1
        str     w10, [x9, #S_PRESSED]
        ldr     x19, [sp, #16]
        ldp     x29, x30, [sp], #32
        ret
        .size   ANativeActivity_onCreate, . - ANativeActivity_onCreate

// =====================================================================
//  Activity callbacks
// =====================================================================

// (activity, window)
on_window_created:
        stp     x29, x30, [sp, #-16]!
        mov     x29, sp
        ADDR    x9, st
        str     x1, [x9, #S_WINDOW]
        mov     x0, x1
        mov     w1, #0
        mov     w2, #0
        mov     w3, #1                          // WINDOW_FORMAT_RGBA_8888
        bl      ANativeWindow_setBuffersGeometry
        bl      draw_frame
        ldp     x29, x30, [sp], #16
        ret

// (activity, window) - resized / redraw needed
on_window_redraw:
        stp     x29, x30, [sp, #-16]!
        mov     x29, sp
        bl      draw_frame
        ldp     x29, x30, [sp], #16
        ret

// (activity, hasFocus)
on_focus_changed:
        stp     x29, x30, [sp, #-16]!
        mov     x29, sp
        bl      draw_frame
        ldp     x29, x30, [sp], #16
        ret

// (activity, window)
on_window_destroyed:
        ADDR    x9, st
        str     xzr, [x9, #S_WINDOW]
        ret

// (activity, queue) - attach the input queue to the main thread looper
on_queue_created:
        stp     x29, x30, [sp, #-32]!
        mov     x29, sp
        str     x19, [sp, #16]
        mov     x19, x1
        ADDR    x9, st
        str     x1, [x9, #S_QUEUE]
        bl      ALooper_forThread               // x0 = looper of this thread
        mov     x1, x0
        mov     x0, x19
        mov     w2, #1
        ADDR    x3, input_cb
        mov     x4, #0
        bl      AInputQueue_attachLooper
        ldr     x19, [sp, #16]
        ldp     x29, x30, [sp], #32
        ret

// (activity, queue)
on_queue_destroyed:
        stp     x29, x30, [sp, #-16]!
        mov     x29, sp
        mov     x0, x1
        bl      AInputQueue_detachLooper
        ADDR    x9, st
        str     xzr, [x9, #S_QUEUE]
        ldp     x29, x30, [sp], #16
        ret

// =====================================================================
//  Input
// =====================================================================

// Looper callback: int input_cb(int fd, int events, void* data)
input_cb:
        stp     x29, x30, [sp, #-32]!
        mov     x29, sp
        str     x19, [sp, #16]
        ADDR    x19, st
1:      ldr     x0, [x19, #S_QUEUE]
        cbz     x0, 9f
        add     x1, x19, #S_EVT
        bl      AInputQueue_getEvent
        tbnz    w0, #31, 9f                     // < 0 : no more events
        ldr     x0, [x19, #S_QUEUE]
        ldr     x1, [x19, #S_EVT]
        bl      AInputQueue_preDispatchEvent
        cbnz    w0, 1b
        ldr     x0, [x19, #S_EVT]
        bl      handle_event
        mov     w2, w0
        ldr     x0, [x19, #S_QUEUE]
        ldr     x1, [x19, #S_EVT]
        bl      AInputQueue_finishEvent
        b       1b
9:      mov     w0, #1                          // keep receiving
        ldr     x19, [sp, #16]
        ldp     x29, x30, [sp], #32
        ret

// x0 = AInputEvent*  ->  w0 = handled (1) or not (0, e.g. Back key)
handle_event:
        stp     x29, x30, [sp, #-48]!
        mov     x29, sp
        stp     x19, x20, [sp, #16]
        stp     x21, x22, [sp, #32]
        mov     x19, x0
        bl      AInputEvent_getType
        cmp     w0, #2                          // AINPUT_EVENT_TYPE_MOTION
        b.ne    2f
        mov     x0, x19
        bl      AMotionEvent_getAction
        and     w20, w0, #0xff
        mov     x0, x19
        mov     x1, #0
        bl      AMotionEvent_getX
        fcvtzs  w21, s0
        mov     x0, x19
        mov     x1, #0
        bl      AMotionEvent_getY
        fcvtzs  w22, s0
        mov     w0, w20
        mov     w1, w21
        mov     w2, w22
        bl      on_touch
        mov     w0, #1
        b       3f
2:      mov     w0, #0
3:      ldp     x21, x22, [sp, #32]
        ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #48
        ret

// w0 = action (0 down, 1 up, 2 move, 3 cancel), w1 = x, w2 = y
on_touch:
        stp     x29, x30, [sp, #-48]!
        mov     x29, sp
        stp     x19, x20, [sp, #16]
        stp     x21, x22, [sp, #32]
        ADDR    x19, st
        mov     w20, w0
        mov     w21, w1
        mov     w22, w2

        cmp     w20, #0                         // DOWN: highlight the button
        b.ne    1f
        mov     w0, w21
        mov     w1, w22
        bl      hit_test
        str     w0, [x19, #S_PRESSED]
        b       8f

1:      cmp     w20, #1                         // UP: press it
        b.ne    3f
        ldr     w0, [x19, #S_PRESSED]
        tbnz    w0, #31, 9f
        mov     w0, w21
        mov     w1, w22
        bl      hit_test
        ldr     w1, [x19, #S_PRESSED]
        mov     w2, #-1
        str     w2, [x19, #S_PRESSED]
        cmp     w0, w1
        b.ne    8f                              // released somewhere else
        ADDR    x2, btn_tbl
        add     x2, x2, w1, uxtw #2
        ldrb    w0, [x2, #3]                    // key of that button
        bl      press_key
        b       8f

3:      cmp     w20, #2                         // MOVE: slid off the button?
        b.ne    4f
        ldr     w0, [x19, #S_PRESSED]
        tbnz    w0, #31, 9f
        mov     w0, w21
        mov     w1, w22
        bl      hit_test
        ldr     w1, [x19, #S_PRESSED]
        cmp     w0, w1
        b.eq    9f
        mov     w2, #-1
        str     w2, [x19, #S_PRESSED]
        b       8f

4:      cmp     w20, #3                         // CANCEL
        b.ne    9f
        mov     w2, #-1
        str     w2, [x19, #S_PRESSED]

8:      bl      draw_frame
9:      ldp     x21, x22, [sp, #32]
        ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #48
        ret

// w0 = x, w1 = y  ->  w0 = button index or -1
hit_test:
        stp     x29, x30, [sp, #-48]!
        mov     x29, sp
        stp     x19, x20, [sp, #16]
        stp     x21, x22, [sp, #32]
        mov     w19, w0
        mov     w20, w1
        bl      compute_metrics
        ADDR    x9, st
        ldr     w22, [x9, #S_GAP]
        mov     w21, #0
1:      mov     w0, w21
        bl      layout_button
        sub     w0, w0, w22                     // whole cell is touchable
        sub     w1, w1, w22
        add     w2, w2, w22, lsl #1
        add     w3, w3, w22, lsl #1
        cmp     w19, w0
        b.lt    2f
        add     w2, w0, w2
        cmp     w19, w2
        b.ge    2f
        cmp     w20, w1
        b.lt    2f
        add     w3, w1, w3
        cmp     w20, w3
        b.ge    2f
        mov     w0, w21
        b       9f
2:      add     w21, w21, #1
        cmp     w21, #NBTN
        b.lt    1b
        mov     w0, #-1
9:      ldp     x21, x22, [sp, #32]
        ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #48
        ret

// =====================================================================
//  Drawing
// =====================================================================

// Lock the window, render, post.
draw_frame:
        stp     x29, x30, [sp, #-32]!
        mov     x29, sp
        str     x19, [sp, #16]
        ADDR    x19, st
        ldr     x0, [x19, #S_WINDOW]
        cbz     x0, 9f
        add     x1, x19, #S_BUF
        mov     x2, #0
        bl      ANativeWindow_lock
        tbnz    w0, #31, 9f
        ldr     w9, [x19, #S_BUF + 12]          // format: only 32-bit pixels
        cmp     w9, #1
        b.eq    1f
        cmp     w9, #2
        b.ne    2f
1:      ldr     x0, [x19, #S_BUF + 16]          // bits
        ldr     w1, [x19, #S_BUF + 8]           // stride
        ldr     w2, [x19, #S_BUF + 0]           // width
        ldr     w3, [x19, #S_BUF + 4]           // height
        bl      render
2:      ldr     x0, [x19, #S_WINDOW]
        bl      ANativeWindow_unlockAndPost
9:      ldr     x19, [sp, #16]
        ldp     x29, x30, [sp], #32
        ret

// x0 = pixels, w1 = stride, w2 = width, w3 = height
render:
        stp     x29, x30, [sp, #-32]!
        mov     x29, sp
        stp     x19, x20, [sp, #16]
        ADDR    x19, st
        str     x0, [x19, #S_BITS]
        str     w1, [x19, #S_STRIDE]
        str     w2, [x19, #S_W]
        str     w3, [x19, #S_H]
        bl      compute_metrics
        mov     w0, #0                          // background
        mov     w1, #0
        ldr     w2, [x19, #S_W]
        ldr     w3, [x19, #S_H]
        MOV32   w4, C_BG
        bl      fill_rect
        mov     w20, #0                         // buttons
1:      mov     w0, w20
        bl      draw_button
        add     w20, w20, #1
        cmp     w20, #NBTN
        b.lt    1b
        bl      draw_display
        ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #32
        ret

// Layout from screen size: 4 columns x 5 rows at the bottom.
compute_metrics:
        ADDR    x9, st
        ldr     w10, [x9, #S_W]
        ldr     w11, [x9, #S_H]
        lsr     w12, w10, #2                    // cellW = W / 4
        mov     w13, #3
        mul     w13, w11, w13
        mov     w14, #25
        udiv    w13, w13, w14                   // max cellH = 3H / 25
        cmp     w12, w13
        csel    w13, w12, w13, lo               // cellH = min(cellW, max)
        mov     w14, #48
        udiv    w14, w10, w14                   // gap = W / 48
        str     w12, [x9, #S_CELLW]
        str     w13, [x9, #S_CELLH]
        str     w14, [x9, #S_GAP]
        mov     w15, #5
        mul     w15, w13, w15
        sub     w15, w11, w15
        sub     w15, w15, w14                   // top = H - 5*cellH - gap
        str     w15, [x9, #S_TOP]
        ret

// w0 = button index  ->  w0 = x, w1 = y, w2 = width, w3 = height
layout_button:
        ADDR    x9, st
        ADDR    x10, btn_tbl
        add     x10, x10, w0, uxtw #2
        ldrb    w11, [x10, #0]                  // column
        ldrb    w12, [x10, #1]                  // row
        ldrb    w13, [x10, #2]                  // column span
        ldr     w14, [x9, #S_CELLW]
        ldr     w15, [x9, #S_CELLH]
        ldr     w16, [x9, #S_GAP]
        ldr     w17, [x9, #S_TOP]
        madd    w0, w11, w14, w16               // x = col*cellW + gap
        madd    w1, w12, w15, w17
        add     w1, w1, w16                     // y = top + row*cellH + gap
        mul     w2, w13, w14
        sub     w2, w2, w16, lsl #1             // w = span*cellW - 2*gap
        sub     w3, w15, w16, lsl #1            // h = cellH - 2*gap
        ret

// w0 = button index
draw_button:
        stp     x29, x30, [sp, #-96]!
        mov     x29, sp
        stp     x19, x20, [sp, #16]
        stp     x21, x22, [sp, #32]
        stp     x23, x24, [sp, #48]
        stp     x25, x26, [sp, #64]
        stp     x27, x28, [sp, #80]
        ADDR    x19, st
        mov     w20, w0
        ADDR    x9, btn_tbl
        add     x9, x9, w20, uxtw #2
        ldrb    w21, [x9, #3]                   // key
        mov     w0, w20
        bl      layout_button
        mov     w22, w0                         // x
        mov     w23, w1                         // y
        mov     w24, w2                         // w
        mov     w25, w3                         // h

        ldr     w10, [x19, #S_PRESSED]
        cmp     w10, w20
        cset    w11, eq                         // w11 = is pressed
        cmp     w21, #K_DOT
        b.ls    1f
        cmp     w21, #K_EQ
        b.ls    2f
        MOV32   w26, C_FN                       // function key
        MOV32   w12, C_FN_P
        cmp     w11, #0
        csel    w26, w12, w26, ne
        MOV32   w27, C_BLACK
        b       4f
1:      MOV32   w26, C_DIG                      // digit key
        MOV32   w12, C_DIG_P
        cmp     w11, #0
        csel    w26, w12, w26, ne
        MOV32   w27, C_WHITE
        b       4f
2:      MOV32   w26, C_OP                       // operator key
        MOV32   w12, C_OP_P
        cmp     w11, #0
        csel    w26, w12, w26, ne
        MOV32   w27, C_WHITE
        ldr     w10, [x19, #S_OP]               // selected operator: inverted
        cmp     w10, w21
        b.ne    4f
        ldr     w10, [x19, #S_NEW]
        cbz     w10, 4f
        cbnz    w11, 4f
        MOV32   w26, C_WHITE
        MOV32   w27, C_OP

4:      mov     w0, w22                         // round button
        mov     w1, w23
        mov     w2, w24
        mov     w3, w25
        lsr     w4, w25, #1                     // radius = h / 2
        mov     w5, w26
        bl      fill_round

        lsr     w28, w25, #4                    // label scale = h / 16
        cmp     w28, #1
        csinc   w28, w28, wzr, ge               // at least 1
        mov     w9, #5
        mul     w9, w9, w28
        sub     w9, w24, w9
        asr     w9, w9, #1
        add     w1, w22, w9                     // centred x
        mov     w9, #7
        mul     w9, w9, w28
        sub     w9, w25, w9
        asr     w9, w9, #1
        add     w2, w23, w9                     // centred y
        mov     w0, w21
        mov     w3, w28
        mov     w4, w27
        bl      draw_glyph

        ldp     x27, x28, [sp, #80]
        ldp     x25, x26, [sp, #64]
        ldp     x23, x24, [sp, #48]
        ldp     x21, x22, [sp, #32]
        ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #96
        ret

// Display text, right aligned above the buttons, auto-sized.
draw_display:
        stp     x29, x30, [sp, #-48]!
        mov     x29, sp
        stp     x19, x20, [sp, #16]
        stp     x21, x22, [sp, #32]
        ADDR    x19, st
        ldr     w20, [x19, #S_LEN]
        ldr     w21, [x19, #S_W]
        ldr     w22, [x19, #S_GAP]
        mov     w9, #40
        udiv    w4, w21, w9                     // s = W / 40 ...
        sub     w10, w21, w22, lsl #2
        mov     w11, #6
        mul     w11, w11, w20
        udiv    w10, w10, w11                   // ... or what fits
        cmp     w10, w4
        csel    w4, w10, w4, lo
        cmp     w4, #1
        csinc   w4, w4, wzr, ge
        mov     w9, #6
        mul     w9, w9, w4
        mul     w9, w9, w20
        sub     w9, w9, w4                      // text width
        sub     w2, w21, w22, lsl #1
        sub     w2, w2, w9                      // x = W - 2*gap - width
        ldr     w3, [x19, #S_TOP]
        sub     w3, w3, w22
        mov     w9, #7
        msub    w3, w9, w4, w3                  // y = top - gap - 7*s
        add     x0, x19, #S_DISP
        mov     w1, w20
        MOV32   w5, C_WHITE
        bl      draw_text
        ldp     x21, x22, [sp, #32]
        ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #48
        ret

// x0 = text, w1 = length, w2 = x, w3 = y, w4 = scale, w5 = colour
draw_text:
        stp     x29, x30, [sp, #-64]!
        mov     x29, sp
        stp     x19, x20, [sp, #16]
        stp     x21, x22, [sp, #32]
        stp     x23, x24, [sp, #48]
        mov     x19, x0
        mov     w20, w1
        mov     w21, w2
        mov     w22, w3
        mov     w23, w4
        mov     w24, w5
1:      cbz     w20, 9f
        ldrb    w0, [x19], #1
        bl      char_glyph
        tbnz    w0, #31, 2f
        mov     w1, w21
        mov     w2, w22
        mov     w3, w23
        mov     w4, w24
        bl      draw_glyph
2:      mov     w9, #6
        madd    w21, w9, w23, w21               // next character
        sub     w20, w20, #1
        b       1b
9:      ldp     x23, x24, [sp, #48]
        ldp     x21, x22, [sp, #32]
        ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #64
        ret

// w0 = ASCII  ->  w0 = glyph number or -1
char_glyph:
        sub     w1, w0, #48
        cmp     w1, #9
        b.ls    1f
        cmp     w0, #46                         // '.'
        b.eq    2f
        cmp     w0, #45                         // '-'
        b.eq    3f
        cmp     w0, #69                         // 'E'
        b.eq    4f
        cmp     w0, #114                        // 'r'
        b.eq    5f
        cmp     w0, #111                        // 'o'
        b.eq    6f
        mov     w0, #-1
        ret
1:      mov     w0, w1
        ret
2:      mov     w0, #K_DOT
        ret
3:      mov     w0, #K_SUB
        ret
4:      mov     w0, #G_E
        ret
5:      mov     w0, #G_R
        ret
6:      mov     w0, #G_O
        ret

// w0 = glyph, w1 = x, w2 = y, w3 = scale, w4 = colour
draw_glyph:
        stp     x29, x30, [sp, #-80]!
        mov     x29, sp
        stp     x19, x20, [sp, #16]
        stp     x21, x22, [sp, #32]
        stp     x23, x24, [sp, #48]
        stp     x25, x26, [sp, #64]
        ADDR    x9, font
        add     x19, x9, w0, uxtw #3            // 8 bytes per glyph
        mov     w20, w1
        mov     w21, w2
        mov     w22, w3
        mov     w23, w4
        mov     w24, #0                         // row
1:      ldrb    w25, [x19, x24]
        mov     w26, #0                         // column
2:      mov     w9, #4
        sub     w9, w9, w26
        lsr     w10, w25, w9
        tbz     w10, #0, 3f
        madd    w0, w26, w22, w20
        madd    w1, w24, w22, w21
        mov     w2, w22
        mov     w3, w22
        mov     w4, w23
        bl      fill_rect
3:      add     w26, w26, #1
        cmp     w26, #5
        b.lt    2b
        add     w24, w24, #1
        cmp     w24, #7
        b.lt    1b
        ldp     x25, x26, [sp, #64]
        ldp     x23, x24, [sp, #48]
        ldp     x21, x22, [sp, #32]
        ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #80
        ret

// w0 = x, w1 = y, w2 = w, w3 = h, w4 = radius, w5 = colour
fill_round:
        stp     x29, x30, [sp, #-64]!
        mov     x29, sp
        stp     x19, x20, [sp, #16]
        stp     x21, x22, [sp, #32]
        stp     x23, x24, [sp, #48]
        mov     w19, w0
        mov     w20, w1
        mov     w21, w2
        mov     w22, w3
        mov     w23, w4
        mov     w24, w5
        str     x25, [sp, #-16]!
        mov     w25, #0                         // row j
1:      cmp     w25, w22
        b.ge    9f
        sub     w9, w22, #1
        sub     w9, w9, w25
        cmp     w25, w9
        csel    w9, w25, w9, lt                 // distance to nearest edge
        mov     w0, #0                          // inset
        cmp     w9, w23
        b.ge    2f
        sub     w10, w23, w9                    // inset = r - sqrt(r^2 - dy^2)
        lsl     w10, w10, #1
        sub     w10, w10, #1                    // 2*dy
        mul     w10, w10, w10
        lsl     w11, w23, #1
        mul     w11, w11, w11
        sub     w10, w11, w10                   // 4*(r^2 - dy^2)
        scvtf   d0, w10
        fsqrt   d0, d0
        fmov    d1, #0.5
        fmul    d0, d0, d1
        scvtf   d1, w23
        fsub    d0, d1, d0
        fcvtas  w0, d0
2:      sub     w2, w21, w0, lsl #1
        add     w0, w19, w0
        add     w1, w20, w25
        mov     w3, #1
        mov     w4, w24
        bl      fill_rect
        add     w25, w25, #1
        b       1b
9:      ldr     x25, [sp], #16
        ldp     x23, x24, [sp, #48]
        ldp     x21, x22, [sp, #32]
        ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #64
        ret

// w0 = x, w1 = y, w2 = w, w3 = h, w4 = colour   (clipped to the screen)
fill_rect:
        ADDR    x9, st
        ldr     w10, [x9, #S_W]
        ldr     w11, [x9, #S_H]
        cmp     w0, #0
        b.ge    1f
        add     w2, w2, w0
        mov     w0, #0
1:      cmp     w1, #0
        b.ge    2f
        add     w3, w3, w1
        mov     w1, #0
2:      add     w12, w0, w2
        cmp     w12, w10
        b.le    3f
        sub     w2, w10, w0
3:      add     w12, w1, w3
        cmp     w12, w11
        b.le    4f
        sub     w3, w11, w1
4:      cmp     w2, #0
        b.le    9f
        cmp     w3, #0
        b.le    9f
        ldr     x13, [x9, #S_BITS]
        ldr     w14, [x9, #S_STRIDE]
        madd    w15, w1, w14, w0                // y*stride + x
        add     x13, x13, w15, uxtw #2
5:      mov     x16, x13
        mov     w17, w2
6:      str     w4, [x16], #4
        subs    w17, w17, #1
        b.ne    6b
        add     x13, x13, w14, uxtw #2
        subs    w3, w3, #1
        b.ne    5b
9:      ret

// =====================================================================
//  Calculator logic
// =====================================================================

calc_clear:
        ADDR    x9, st
        mov     w10, #48                        // "0"
        strb    w10, [x9, #S_DISP]
        mov     w10, #1
        str     w10, [x9, #S_LEN]
        str     w10, [x9, #S_NEW]
        str     wzr, [x9, #S_OP]
        str     wzr, [x9, #S_ERR]
        str     xzr, [x9, #S_ACC]
        ret

// w0 = key
press_key:
        stp     x29, x30, [sp, #-32]!
        mov     x29, sp
        stp     x19, x20, [sp, #16]
        ADDR    x19, st
        mov     w20, w0
        cmp     w20, #9
        b.ls    .Lk_digit
        cmp     w20, #K_DOT
        b.eq    .Lk_dot
        cmp     w20, #K_DIV
        b.ls    .Lk_op
        cmp     w20, #K_EQ
        b.eq    .Lk_eq
        cmp     w20, #K_CLR
        b.eq    .Lk_clr
        cmp     w20, #K_NEG
        b.eq    .Lk_neg
        cmp     w20, #K_BACK
        b.eq    .Lk_back
        b       .Lk_done

// ---- 0..9 ----
.Lk_digit:
        ldr     w9, [x19, #S_ERR]
        cbz     w9, 1f
        bl      calc_clear
1:      ldr     w9, [x19, #S_NEW]
        cbz     w9, 2f
        mov     w9, #48                         // start a new number
        strb    w9, [x19, #S_DISP]
        mov     w9, #1
        str     w9, [x19, #S_LEN]
        str     wzr, [x19, #S_NEW]
2:      bl      count_digits
        cmp     w0, #12                         // max 12 digits
        b.hs    .Lk_done
        ldr     w9, [x19, #S_LEN]
        add     x10, x19, #S_DISP
        sub     w11, w9, #1
        ldrb    w12, [x10, x11]                 // last character
        cmp     w12, #48
        b.ne    3f
        cmp     w9, #1                          // "0"  -> replace
        b.eq    4f
        cmp     w9, #2
        b.ne    3f
        ldrb    w12, [x10]
        cmp     w12, #45                        // "-0" -> replace
        b.ne    3f
4:      add     w12, w20, #48
        strb    w12, [x10, x11]
        b       .Lk_done
3:      add     w12, w20, #48                   // append
        strb    w12, [x10, x9]
        add     w9, w9, #1
        str     w9, [x19, #S_LEN]
        b       .Lk_done

// ---- . ----
.Lk_dot:
        ldr     w9, [x19, #S_ERR]
        cbz     w9, 1f
        bl      calc_clear
1:      ldr     w9, [x19, #S_NEW]
        cbz     w9, 2f
        mov     w9, #48                         // "0."
        strb    w9, [x19, #S_DISP]
        mov     w9, #46
        strb    w9, [x19, #S_DISP + 1]
        mov     w9, #2
        str     w9, [x19, #S_LEN]
        str     wzr, [x19, #S_NEW]
        b       .Lk_done
2:      ldr     w9, [x19, #S_LEN]
        add     x10, x19, #S_DISP
        mov     w11, #0
3:      cmp     w11, w9                         // already has a point?
        b.ge    4f
        ldrb    w12, [x10, x11]
        cmp     w12, #46
        b.eq    .Lk_done
        add     w11, w11, #1
        b       3b
4:      cmp     w9, #30
        b.hs    .Lk_done
        mov     w12, #46
        strb    w12, [x10, x9]
        add     w9, w9, #1
        str     w9, [x19, #S_LEN]
        b       .Lk_done

// ---- + - x / ----
.Lk_op:
        ldr     w9, [x19, #S_ERR]
        cbnz    w9, .Lk_done
        ldr     w9, [x19, #S_NEW]
        ldr     w10, [x19, #S_OP]
        cbz     w9, 1f
        cbz     w10, 1f
        str     w20, [x19, #S_OP]               // just change the operator
        b       .Lk_done
1:      bl      parse_disp                      // d0 = number on screen
        ldr     w10, [x19, #S_OP]
        cbnz    w10, 2f
        str     d0, [x19, #S_ACC]
        b       3f
2:      fmov    d1, d0                          // chain: acc = acc op number
        ldr     d0, [x19, #S_ACC]
        mov     w0, w10
        bl      apply_op
        cbnz    w0, .Lk_error
        str     d0, [x19, #S_ACC]
        bl      format_disp
3:      str     w20, [x19, #S_OP]
        mov     w9, #1
        str     w9, [x19, #S_NEW]
        b       .Lk_done

// ---- = ----
.Lk_eq:
        ldr     w9, [x19, #S_ERR]
        cbnz    w9, .Lk_done
        bl      parse_disp
        ldr     w10, [x19, #S_OP]
        cbz     w10, 1f
        fmov    d1, d0
        ldr     d0, [x19, #S_ACC]
        mov     w0, w10
        bl      apply_op
        cbnz    w0, .Lk_error
1:      str     d0, [x19, #S_ACC]
        bl      format_disp
        str     wzr, [x19, #S_OP]
        mov     w9, #1
        str     w9, [x19, #S_NEW]
        b       .Lk_done

// ---- C ----
.Lk_clr:
        bl      calc_clear
        b       .Lk_done

// ---- +/- ----
.Lk_neg:
        ldr     w9, [x19, #S_ERR]
        cbnz    w9, .Lk_done
        ldr     w9, [x19, #S_NEW]
        ldr     w10, [x19, #S_OP]
        cbz     w9, 1f
        cbz     w10, 1f
        mov     w9, #45                         // right after an operator: "-0"
        strb    w9, [x19, #S_DISP]
        mov     w9, #48
        strb    w9, [x19, #S_DISP + 1]
        mov     w9, #2
        str     w9, [x19, #S_LEN]
        str     wzr, [x19, #S_NEW]
        b       .Lk_done
1:      ldr     w9, [x19, #S_LEN]
        add     x10, x19, #S_DISP
        ldrb    w11, [x10]
        cmp     w11, #45
        b.ne    3f
        mov     w12, #1                         // remove the leading '-'
2:      cmp     w12, w9
        b.ge    21f
        ldrb    w13, [x10, x12]
        sub     w14, w12, #1
        strb    w13, [x10, x14]
        add     w12, w12, #1
        b       2b
21:     sub     w9, w9, #1
        str     w9, [x19, #S_LEN]
        b       .Lk_done
3:      cmp     w9, #1                          // "0" stays "0"
        b.ne    4f
        cmp     w11, #48
        b.eq    .Lk_done
4:      cmp     w9, #30
        b.hs    .Lk_done
        mov     w12, w9                         // shift right, insert '-'
5:      cbz     w12, 6f
        sub     w14, w12, #1
        ldrb    w13, [x10, x14]
        strb    w13, [x10, x12]
        mov     w12, w14
        b       5b
6:      mov     w13, #45
        strb    w13, [x10]
        add     w9, w9, #1
        str     w9, [x19, #S_LEN]
        b       .Lk_done

// ---- backspace ----
.Lk_back:
        ldr     w9, [x19, #S_ERR]
        cbz     w9, 1f
        bl      calc_clear
        b       .Lk_done
1:      ldr     w9, [x19, #S_NEW]
        cbnz    w9, .Lk_done                    // results are not editable
        ldr     w9, [x19, #S_LEN]
        sub     w9, w9, #1
        cbz     w9, 2f
        cmp     w9, #1
        b.ne    3f
        ldrb    w10, [x19, #S_DISP]
        cmp     w10, #45                        // only "-" left
        b.ne    3f
2:      mov     w10, #48
        strb    w10, [x19, #S_DISP]
        mov     w9, #1
3:      str     w9, [x19, #S_LEN]
        b       .Lk_done

.Lk_error:
        add     x10, x19, #S_DISP               // "Error"
        mov     w9, #69
        strb    w9, [x10, #0]
        mov     w9, #114
        strb    w9, [x10, #1]
        strb    w9, [x10, #2]
        strb    w9, [x10, #4]
        mov     w9, #111
        strb    w9, [x10, #3]
        mov     w9, #5
        str     w9, [x19, #S_LEN]
        mov     w9, #1
        str     w9, [x19, #S_ERR]
        str     w9, [x19, #S_NEW]
        str     wzr, [x19, #S_OP]

.Lk_done:
        ldp     x19, x20, [sp, #16]
        ldp     x29, x30, [sp], #32
        ret

// -> w0 = number of digit characters on the display
count_digits:
        ADDR    x9, st
        ldr     w10, [x9, #S_LEN]
        add     x11, x9, #S_DISP
        mov     w0, #0
        mov     w12, #0
1:      cmp     w12, w10
        b.ge    9f
        ldrb    w13, [x11, x12]
        sub     w13, w13, #48
        cmp     w13, #9
        cinc    w0, w0, ls
        add     w12, w12, #1
        b       1b
9:      ret

// display text -> d0
parse_disp:
        ADDR    x9, st
        ldr     w10, [x9, #S_LEN]
        add     x11, x9, #S_DISP
        mov     x12, #0                         // digits as an integer
        mov     w13, #0                         // index
        mov     w14, #0                         // 1 after the point
        mov     w15, #0                         // digits after the point
        mov     x16, #10
1:      cmp     w13, w10
        b.ge    4f
        ldrb    w17, [x11, x13]
        add     w13, w13, #1
        cmp     w17, #46
        b.ne    2f
        mov     w14, #1
        b       1b
2:      sub     w17, w17, #48
        cmp     w17, #9
        b.hi    1b                              // skip '-'
        madd    x12, x12, x16, x17
        add     w15, w15, w14
        b       1b
4:      scvtf   d0, x12
        fmov    d1, #10.0
5:      cbz     w15, 6f
        fdiv    d0, d0, d1
        sub     w15, w15, #1
        b       5b
6:      ldrb    w17, [x11]
        cmp     w17, #45
        b.ne    7f
        fneg    d0, d0
7:      ret

// d0 = a, d1 = b, w0 = operator  ->  d0 = result, w0 = 0 ok / 1 error
apply_op:
        cmp     w0, #K_ADD
        b.ne    1f
        fadd    d0, d0, d1
        b       5f
1:      cmp     w0, #K_SUB
        b.ne    2f
        fsub    d0, d0, d1
        b       5f
2:      cmp     w0, #K_MUL
        b.ne    3f
        fmul    d0, d0, d1
        b       5f
3:      fcmp    d1, #0.0                        // division by zero
        b.eq    8f
        fdiv    d0, d0, d1
5:      fabs    d2, d0
        ADDR    x9, k_max
        ldr     d3, [x9]
        fcmp    d2, d3
        b.hs    8f                              // too big (or NaN)
        mov     w0, #0
        ret
8:      mov     w0, #1
        ret

// d0 -> display text: at most 15 significant digits and 6 decimals,
// trailing zeros removed
format_disp:
        ADDR    x9, st
        add     x10, x9, #S_DISP
        mov     w11, #0                         // length
        fabs    d2, d0
        movz    x14, #0x4240
        movk    x14, #0xF, lsl #16              // p = 1000000 (6 decimals)
        ADDR    x12, k_1e6
        ldr     d1, [x12]                       // same as a double
        ldr     d4, [x12, #8]                   // 1e9
        fmov    d5, #10.0
        mov     x7, #10
10:     fcmp    d2, d4                          // one decimal less for every
        b.lt    11f                             // integer digit above 9
        cmp     x14, #1
        b.ls    11f
        udiv    x14, x14, x7
        fdiv    d1, d1, d5
        fmul    d4, d4, d5
        b       10b
11:     fmul    d2, d2, d1
        fcvtas  x13, d2                         // n = round(|v| * p)
        cbz     x13, 1f                         // zero has no sign
        fcmp    d0, #0.0
        b.ge    1f
        mov     w5, #45
        strb    w5, [x10, x11]
        add     w11, w11, #1
1:      udiv    x15, x13, x14                   // integer part
        msub    x16, x15, x14, x13              // fraction part
        sub     sp, sp, #32
        mov     x17, #0
        mov     x7, #10
2:      udiv    x6, x15, x7                     // integer digits, reversed
        msub    x5, x6, x7, x15
        add     w5, w5, #48
        strb    w5, [sp, x17]
        add     x17, x17, #1
        mov     x15, x6
        cbnz    x15, 2b
3:      sub     x17, x17, #1                    // copy them in order
        ldrb    w5, [sp, x17]
        strb    w5, [x10, x11]
        add     w11, w11, #1
        cbnz    x17, 3b
        add     sp, sp, #32
        cbz     x16, 9f
        mov     w5, #46                         // '.'
        strb    w5, [x10, x11]
        add     w11, w11, #1
        udiv    x14, x14, x7                    // first decimal place
4:      udiv    x6, x16, x14
        msub    x16, x6, x14, x16
        add     w6, w6, #48
        strb    w6, [x10, x11]
        add     w11, w11, #1
        udiv    x14, x14, x7
        cbnz    x14, 4b
5:      sub     w12, w11, #1                    // drop trailing zeros
        ldrb    w6, [x10, x12]
        cmp     w6, #48
        b.ne    9f
        mov     w11, w12
        b       5b
9:      str     w11, [x9, #S_LEN]
        ret

// =====================================================================
//  Read-only data
// =====================================================================
        .section .rodata
        .p2align 3
k_max:  .double 1.0e12
k_1e6:  .double 1.0e6
k_1e9:  .double 1.0e9                           // must follow k_1e6

// buttons: column, row, column span, key
btn_tbl:
        .byte 0,0,1,K_CLR,   1,0,1,K_NEG,   2,0,1,K_BACK,  3,0,1,K_DIV
        .byte 0,1,1,7,       1,1,1,8,       2,1,1,9,       3,1,1,K_MUL
        .byte 0,2,1,4,       1,2,1,5,       2,2,1,6,       3,2,1,K_SUB
        .byte 0,3,1,1,       1,3,1,2,       2,3,1,3,       3,3,1,K_ADD
        .byte 0,4,2,0,       2,4,1,K_DOT,   3,4,1,K_EQ

// 5x7 pixel font, 8 bytes per glyph, bit 4 = left column
font:
        .byte 0b01110,0b10001,0b10001,0b10001,0b10001,0b10001,0b01110,0   // 0
        .byte 0b00100,0b01100,0b00100,0b00100,0b00100,0b00100,0b01110,0   // 1
        .byte 0b01110,0b10001,0b00001,0b00010,0b00100,0b01000,0b11111,0   // 2
        .byte 0b11111,0b00010,0b00100,0b00010,0b00001,0b10001,0b01110,0   // 3
        .byte 0b00010,0b00110,0b01010,0b10010,0b11111,0b00010,0b00010,0   // 4
        .byte 0b11111,0b10000,0b11110,0b00001,0b00001,0b10001,0b01110,0   // 5
        .byte 0b00110,0b01000,0b10000,0b11110,0b10001,0b10001,0b01110,0   // 6
        .byte 0b11111,0b00001,0b00010,0b00100,0b01000,0b01000,0b01000,0   // 7
        .byte 0b01110,0b10001,0b10001,0b01110,0b10001,0b10001,0b01110,0   // 8
        .byte 0b01110,0b10001,0b10001,0b01111,0b00001,0b00010,0b01100,0   // 9
        .byte 0b00000,0b00000,0b00000,0b00000,0b00000,0b01100,0b01100,0   // .
        .byte 0b00000,0b00100,0b00100,0b11111,0b00100,0b00100,0b00000,0   // +
        .byte 0b00000,0b00000,0b00000,0b11111,0b00000,0b00000,0b00000,0   // -
        .byte 0b00000,0b10001,0b01010,0b00100,0b01010,0b10001,0b00000,0   // x
        .byte 0b00000,0b00100,0b00000,0b11111,0b00000,0b00100,0b00000,0   // /
        .byte 0b00000,0b00000,0b11111,0b00000,0b11111,0b00000,0b00000,0   // =
        .byte 0b01110,0b10001,0b10000,0b10000,0b10000,0b10001,0b01110,0   // C
        .byte 0b00100,0b00100,0b11111,0b00100,0b00100,0b00000,0b11111,0   // +/-
        .byte 0b00000,0b00100,0b01000,0b11111,0b01000,0b00100,0b00000,0   // back
        .byte 0b11111,0b10000,0b10000,0b11110,0b10000,0b10000,0b11111,0   // E
        .byte 0b00000,0b00000,0b10110,0b11001,0b10000,0b10000,0b10000,0   // r
        .byte 0b00000,0b00000,0b01110,0b10001,0b10001,0b10001,0b01110,0   // o

// =====================================================================
//  Mutable state
// =====================================================================
        .bss
        .p2align 4
st:     .space  S_SIZE

        .section .note.GNU-stack,"",%progbits
