import sys
import os

def get_icon_path():
    r"""
    Returns the full path to 'BrinkTerm.ico'.
    Uses PyInstaller's _MEIPASS path if bundled, otherwise uses C:\Scripts path.
    """
    if hasattr(sys, '_MEIPASS'):
        return os.path.join(sys._MEIPASS, "BrinkTerm.ico")
    else:
        return r"C:\Scripts\BrinkTerm.ico"

if __name__ == "__main__":
    icon_path = get_icon_path()
    print(f"Icon path: {icon_path}")
