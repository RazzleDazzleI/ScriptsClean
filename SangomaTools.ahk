#Requires AutoHotkey v2.0

; ---------------------------
; F7 = capture Sangoma window position/size (copy + show)
; ---------------------------
F7::CaptureSangomaRect()

; ---------------------------
; F8 = capture mouse position + color + Sangoma-relative offsets
; ---------------------------
F8::CaptureMouseAndOffsets()

CaptureSangomaRect() {
    if !WinExist("ahk_exe Sangoma Phone.exe") {
        MsgBox "Sangoma Phone window not found."
        return
    }

    WinGetPos &wx, &wy, &ww, &wh, "ahk_exe Sangoma Phone.exe"

    txt :=
    (
"; --- Sangoma window 'pin' settings (paste into your script) ---
SangX := " wx "
SangY := " wy "
SangW := " ww "
SangH := " wh "
"
    )

    A_Clipboard := txt
    MsgBox "Captured Sangoma window rectangle (also copied to clipboard):`n`n" txt
}

CaptureMouseAndOffsets() {
    CoordMode "Mouse", "Screen"
    CoordMode "Pixel", "Screen"

    MouseGetPos &mx, &my
    c := PixelGetColor(mx, my, "RGB") ; 0xRRGGBB
    colorHex := Format("0x{:06X}", c)

    if WinExist("ahk_exe Sangoma Phone.exe") {
        WinGetPos &wx, &wy, &ww, &wh, "ahk_exe Sangoma Phone.exe"
        dx := mx - wx
        dy := my - wy

        txt :=
        (
"Mouse Screen: " mx ", " my "
Color: " colorHex "

Sangoma Window top-left: " wx ", " wy "
Offsets from Sangoma (dx, dy): " dx ", " dy "
"
        )
    } else {
        txt :=
        (
"Mouse Screen: " mx ", " my "
Color: " colorHex "

Sangoma window not found (can't compute offsets).
"
        )
    }

    A_Clipboard := txt
    MsgBox "Captured (also copied to clipboard):`n`n" txt
}
