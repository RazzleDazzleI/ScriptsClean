#Requires AutoHotkey v2.0
#SingleInstance Force

; Use screen coordinates
CoordMode "Mouse", "Screen"
CoordMode "Pixel", "Screen"
SetTitleMatchMode 2

; =======================
; CONFIG - EDIT IF NEEDED
; =======================

; Toast popup green answer button (your earlier coords)
toastX := 1840
toastY := 454

; In-app *small* Answer button (your screenshot shows this)
mainAnswerX := 266
mainAnswerY := -970

; Color sample from Window Spy while hovering small Answer button
; (AutoHotkey v2 PixelGetColor returns 0xRRGGBB)
mainAnswerColor := 0x3AA652

; Auto-answer behavior
pollMs := 120          ; check interval
cooldownMs := 2500     ; prevent spam clicks
colorTolerance := 30   ; 0-255ish, higher = more forgiving

; Freshdesk new ticket URL
freshdeskUrl := "https://drm-help.freshdesk.com/a/tickets/new"

; =======================
; STATE (do not edit)
; =======================
global autoOn := false
global lastAuto := 0

; ---------------------------
; Ctrl + Tab  = answer via toast popup
; ---------------------------
^Tab:: {
    Click toastX, toastY
    DoAfterAnswer()
}

; ---------------------------
; Ctrl + ` = answer via in-app SMALL Answer button
; ---------------------------
^`:: {
    ; Activating helps if the app is behind something
    WinActivate "Sangoma Phone"
    Sleep 60
    Click mainAnswerX, mainAnswerY
    DoAfterAnswer()
}

; ---------------------------
; Ctrl + 1 = pause/play media
; ---------------------------
^1:: {
    Send "{Media_Play_Pause}"
    Sleep 100
}

; ---------------------------
; Ctrl + Shift + ` = toggle auto-answer ON/OFF
; ---------------------------
^+`:: {
    ToggleAutoAnswer()
}

; =======================
; FUNCTIONS
; =======================

DoAfterAnswer() {
    global freshdeskUrl
    ; Pause/Play toggle (usually pauses)
    Send "{Media_Play_Pause}"
    Sleep 100

    Sleep 250
    Run freshdeskUrl
}

ToggleAutoAnswer() {
    global autoOn, pollMs
    autoOn := !autoOn

    if autoOn {
        SetTimer AutoAnswerTick, pollMs
        TrayTip "Sangoma Auto-Answer", "ON (Ctrl+Shift+` to toggle)", 1
    } else {
        SetTimer AutoAnswerTick, 0
        TrayTip "Sangoma Auto-Answer", "OFF (Ctrl+Shift+` to toggle)", 1
    }
}

AutoAnswerTick() {
    global lastAuto, cooldownMs
    global mainAnswerX, mainAnswerY, mainAnswerColor, colorTolerance

    ; Only run if Sangoma is running
    if !WinExist("ahk_exe Sangoma Phone.exe")
        return

    now := A_TickCount
    if (now - lastAuto < cooldownMs)
        return

    ; Read pixel color at the small Answer button location
    c := PixelGetColor(mainAnswerX, mainAnswerY, "RGB") ; returns 0xRRGGBB

    if ColorNear(c, mainAnswerColor, colorTolerance) {
        ; Bring to front just in case, then click
        WinActivate "Sangoma Phone"
        Sleep 40
        Click mainAnswerX, mainAnswerY
        lastAuto := now
    }
}

ColorNear(c1, c2, tol) {
    r1 := (c1 >> 16) & 0xFF, g1 := (c1 >> 8) & 0xFF, b1 := c1 & 0xFF
    r2 := (c2 >> 16) & 0xFF, g2 := (c2 >> 8) & 0xFF, b2 := c2 & 0xFF

    return (Abs(r1 - r2) <= tol
         && Abs(g1 - g2) <= tol
         && Abs(b1 - b2) <= tol)
}
