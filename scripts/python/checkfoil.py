# -*- coding: utf-8 -*-
r"""
foilcheck (single file, UTF-8-fest)
- lädt config/config.json relativ zu ROOT (zwei Ordner über diesem Skript)
- schreibt Log nach ROOT\docs\logs\<einziger_unterordner>\foilcheck.txt
  (Fallback: C:\EndkontrolleTemp\foilcheck.txt)
- Admin-Elevation (optional per Config)
- .NET & LibreHardwareMonitorLib (NuGet-Fallback)
- HVCI-Check
- Core-Clock via: LHM -> %ProcessorPerformance -> ProcessorFrequency
- adaptive Zielschwelle (LHM/Fallback konfigurierbar)
- Live-CMD-Ausgabe + Logging; kein Sensor-Dump
"""

import os, sys, time, math, multiprocessing, zipfile, urllib.request, shutil, ctypes, json

# ============================================================
# UTF-8 KONSOLE & SYMBOL-FALLBACK
# ============================================================
def _enable_utf8_console_and_symbols():
    import sys, os
    # UTF-8 aktivieren (Windows Codepage)
    if os.name == "nt":
        try:
            ctypes.windll.kernel32.SetConsoleOutputCP(65001)
            ctypes.windll.kernel32.SetConsoleCP(65001)
        except Exception:
            pass

    # stdout/stderr auf UTF-8 re-konfigurieren
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
        sys.stderr.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass

    enc = (sys.stdout.encoding or "").lower()
    supports_utf8 = "utf" in enc

    globals()["_SYM_OK"]   = "✅" if supports_utf8 else "[OK]"
    globals()["_SYM_ERR"]  = "❌" if supports_utf8 else "[X]"
    globals()["_SYM_WARN"] = "⚠️" if supports_utf8 else "[!]"
    return supports_utf8


_SUPPORTS_UTF8 = _enable_utf8_console_and_symbols()

# ============================================================
# ROOT & CONFIG
# ============================================================
def _root_dir_from_here() -> str:
    here = os.path.dirname(os.path.abspath(__file__))
    return os.path.abspath(os.path.join(here, "..", ".."))

ROOT_DIR = _root_dir_from_here()

def _load_json(path: str):
    try:
        with open(path, "r", encoding="utf-8") as f:
            return json.load(f)
    except FileNotFoundError:
        print("[CONFIG] Keine config.json gefunden:", path)
        return {}
    except json.JSONDecodeError as e:
        print(f"[CONFIG] Fehler in config.json ({path}): {e}")
        return {}

def _as_float_percent(x, default: float) -> float:
    try:
        if x is None: return default
        v = float(x)
        if v > 2.0: return v / 100.0  # 101 -> 1.01
        if 0 < v < 2.0: return v      # 1.01 -> 1.01
    except Exception:
        pass
    return default

def _bool(v, default: bool) -> bool:
    if isinstance(v, bool): return v
    if isinstance(v, str):  return v.strip().lower() in ("1","true","yes","y","on")
    return default

def _int(v, default: int) -> int:
    try:    return int(v)
    except: return default

def _resolve_path(root: str, p: str) -> str:
    if not p: return ""
    p = p.replace("\\", "/")
    if os.path.isabs(p) or (len(p) > 1 and p[1] == ":"):
        return p
    return os.path.normpath(os.path.join(root, p))

def load_config():
    cfg_path = os.path.join(ROOT_DIR, "config", "config.json")
    raw = _load_json(cfg_path)
    cfg = {
        "ROOT_DIR": ROOT_DIR,
        "Paths": {
            # FIX: "programme" statt "programma"
            "PythonPortable": raw.get("Paths", {}).get("PythonPortable", "scripts/programme/portable/python/python.exe"),
            "DotNetRoot":     raw.get("Paths", {}).get("DotNetRoot", "dotnet"),
            "DllDir":         raw.get("Paths", {}).get("DllDir", "dll/net6.0"),
        },
        "General": {
            "DocsFolder":        raw.get("General", {}).get("DocsFolder", "docs"),
            "UseAdminElevation": _bool(raw.get("General", {}).get("UseAdminElevation", True), True),
        },
        "PerformanceTest": {
            "TestMinutes":               _int(raw.get("PerformanceTest", {}).get("TestMinutes", raw.get("test_minutes", 2)), 2),
            "WarmupSeconds":             _int(raw.get("PerformanceTest", {}).get("WarmupSeconds", 5), 5),
            "MeasurementMaxValues":      _int(raw.get("PerformanceTest", {}).get("MeasurementMaxValues", 8), 8),
            "MeasurementTimeoutSeconds": _int(raw.get("PerformanceTest", {}).get("MeasurementTimeoutSeconds", 120), 120),
            "TargetFactorLHM":           _as_float_percent(raw.get("PerformanceTest", {}).get("TargetPercentLHM", 101), 1.01),
            "TargetFactorFallback":      _as_float_percent(raw.get("PerformanceTest", {}).get("TargetPercentFallback", 100), 1.00),
            "PrintLiveValues":           _bool(raw.get("PerformanceTest", {}).get("PrintLiveValues", True), True),
            "LogEachValue":              _bool(raw.get("PerformanceTest", {}).get("LogEachValue", True), True),
            "ShowHeaderInfo":            _bool(raw.get("PerformanceTest", {}).get("ShowHeaderInfo", True), True),
        },
        "Network":    raw.get("Network", {}),
        "api":        raw.get("api", {}),
        "validation": raw.get("validation", {}),
    }
    # Pfade relativ zu ROOT auflösen
    cfg["Paths"]["DotNetRoot"] = _resolve_path(ROOT_DIR, cfg["Paths"]["DotNetRoot"])
    cfg["Paths"]["DllDir"]     = _resolve_path(ROOT_DIR, cfg["Paths"]["DllDir"])
    return cfg

CONFIG = load_config()

# ============================================================
# EINSTELLUNGEN
# ============================================================
LOG_FILENAME = "foilcheck.txt"

USE_ADMIN_ELEVATION = CONFIG["General"]["UseAdminElevation"]
DOCS_FOLDER         = CONFIG["General"]["DocsFolder"]

DEFAULT_TEST_MINUTES   = int(CONFIG["PerformanceTest"]["TestMinutes"])
WARMUP_SECONDS         = int(CONFIG["PerformanceTest"]["WarmupSeconds"])
MEAS_MAX_VALUES        = int(CONFIG["PerformanceTest"]["MeasurementMaxValues"])
MEAS_TIMEOUT_SECONDS   = int(CONFIG["PerformanceTest"]["MeasurementTimeoutSeconds"])
TARGET_FACTOR_LHM      = float(CONFIG["PerformanceTest"]["TargetFactorLHM"])
TARGET_FACTOR_FALLBACK = float(CONFIG["PerformanceTest"]["TargetFactorFallback"])
PRINT_LIVE             = bool(CONFIG["PerformanceTest"]["PrintLiveValues"])
LOG_EACH               = bool(CONFIG["PerformanceTest"]["LogEachValue"])
SHOW_HEADER            = bool(CONFIG["PerformanceTest"]["ShowHeaderInfo"])

DOTNET_ROOT  = CONFIG["Paths"]["DotNetRoot"]
DLL_DIR_NET6 = CONFIG["Paths"]["DllDir"]
NUGET_URL    = "https://www.nuget.org/api/v2/package/LibreHardwareMonitorLib"
NUGET_SAVE   = os.path.join(ROOT_DIR, "dll", "LibreHardwareMonitorLib.nupkg")
NUGET_UNPACK = os.path.join(ROOT_DIR, "dll", "nuget_tmp")

# ============================================================
# LOG-PFAD (docs\logs\<einziger_unterordner>\foilcheck.txt)
# - Wenn mehrere Unterordner existieren, nehme den JÜNGSTEN.
# ============================================================
def resolve_log_path() -> str:
    logs_dir = os.path.join(ROOT_DIR, DOCS_FOLDER, "logs")
    if not os.path.isdir(logs_dir):
        os.makedirs(logs_dir, exist_ok=True)

    entries = [d for d in os.listdir(logs_dir) if os.path.isdir(os.path.join(logs_dir, d))]
    if len(entries) >= 1:
        # jüngsten Unterordner wählen
        fulls = [(d, os.path.join(logs_dir, d)) for d in entries]
        newest = max(fulls, key=lambda t: os.path.getmtime(t[1]))[1]
        os.makedirs(newest, exist_ok=True)
        return os.path.join(newest, LOG_FILENAME)

    # Fallback wenn GAR KEIN Unterordner existiert
    fallback_dir = r"C:\EndkontrolleTemp"
    os.makedirs(fallback_dir, exist_ok=True)
    print(f"[LOG] Hinweis: In '{logs_dir}' wurde kein Unterordner gefunden. "
          f"Nutze Fallback: {fallback_dir}\\{LOG_FILENAME}")
    return os.path.join(fallback_dir, LOG_FILENAME)

LOG_FILE = resolve_log_path()

# ============================================================
# HELPERS
# ============================================================
def ensure_dir(p):
    if not os.path.isdir(p):
        os.makedirs(p, exist_ok=True)

def ensure_log_dir():
    ensure_dir(os.path.dirname(LOG_FILE))

def print_flush(msg: str):
    if PRINT_LIVE:
        try:
            print(msg)
        except UnicodeEncodeError:
            safe = msg.encode("ascii", "replace").decode("ascii")
            print(safe)
        sys.stdout.flush()

def log_write(line: str):
    ensure_log_dir()
    with open(LOG_FILE, "a", encoding="utf-8") as f:
        f.write(line)

# ============================================================
# ADMIN-ELEVATION
# ============================================================
def ensure_admin():
    if not USE_ADMIN_ELEVATION:
        return
    try:
        is_admin = ctypes.windll.shell32.IsUserAnAdmin()
    except Exception:
        is_admin = False
    if not is_admin:
        params = " ".join([f'"{arg}"' if " " in arg else arg for arg in sys.argv])
        rc = ctypes.windll.shell32.ShellExecuteW(None, "runas", sys.executable, params, None, 1)
        if int(rc) <= 32:
            sys.exit("Administratorrechte erforderlich – UAC abgebrochen.")
        else:
            sys.exit(0)

# ============================================================
# .NET & LHM
# ============================================================
if os.path.isdir(DOTNET_ROOT):
    os.environ["DOTNET_ROOT"] = DOTNET_ROOT
    os.environ["PATH"] = DOTNET_ROOT + os.pathsep + os.environ.get("PATH", "")

DLL_CANDIDATES = [
    os.path.join(DLL_DIR_NET6, "LibreHardwareMonitorLib.dll"),
    os.path.join(ROOT_DIR, "dll", "LibreHardwareMonitorLib.dll"),
]

def ensure_lhm_dll():
    for p in DLL_CANDIDATES:
        if os.path.exists(p):
            return p
    ensure_dir(os.path.dirname(NUGET_SAVE))
    urllib.request.urlretrieve(NUGET_URL, NUGET_SAVE)
    if os.path.isdir(NUGET_UNPACK):
        shutil.rmtree(NUGET_UNPACK, ignore_errors=True)
    ensure_dir(NUGET_UNPACK)
    with zipfile.ZipFile(NUGET_SAVE, "r") as z:
        z.extractall(NUGET_UNPACK)
    candidate = None
    for root, _, files in os.walk(NUGET_UNPACK):
        if "lib/net6.0" in root.replace("\\", "/") and "LibreHardwareMonitorLib.dll" in files:
            candidate = os.path.join(root, "LibreHardwareMonitorLib.dll")
            break
    if not candidate:
        sys.exit("FEHLER: Keine lib/net6.0-Variante gefunden!")
    ensure_dir(DLL_DIR_NET6)
    target = os.path.join(DLL_DIR_NET6, "LibreHardwareMonitorLib.dll")
    shutil.copy2(candidate, target)
    shutil.rmtree(NUGET_UNPACK, ignore_errors=True)
    return target

def load_clr_and_namespace():
    try:
        import clr
    except ImportError:
        sys.exit("pythonnet fehlt. Bitte installieren: pip install pythonnet==3.0.5")
    dll_path = ensure_lhm_dll()
    clr.AddReference(dll_path)
    from LibreHardwareMonitor import Hardware
    return Hardware

def ensure_lhm_driver_ready(Hardware):
    try:
        comp = Hardware.Computer()
        comp.IsCpuEnabled = True
        comp.Open()
        comp.Close()
        return True
    except Exception:
        return False

def is_memory_integrity_enabled():
    try:
        import winreg
        path = r"SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity"
        with winreg.OpenKey(winreg.HKEY_LOCAL_MACHINE, path) as k:
            val, _ = winreg.QueryValueEx(k, "Enabled")
            return int(val) == 1
    except Exception:
        return False

# ============================================================
# CPU & SENSORS
# ============================================================
def get_cpu_info():
    try:
        import wmi
    except ImportError:
        sys.exit("wmi fehlt. Bitte installieren: pip install wmi")
    w = wmi.WMI()
    for cpu in w.Win32_Processor():
        return cpu.Name, float(cpu.MaxClockSpeed)  # MHz
    return None, None

def _full_update(hw):
    hw.Update()
    for sub in getattr(hw, "SubHardware", []):
        sub.Update()

def get_cpu_temperature(Hardware):
    comp = Hardware.Computer()
    comp.IsCpuEnabled = True
    comp.Open()
    try:
        temps = []
        for hw in comp.Hardware:
            _full_update(hw)
            if str(hw.HardwareType).lower().endswith("cpu"):
                for s in hw.Sensors:
                    if str(s.SensorType).lower() == "temperature" and s.Value is not None:
                        temps.append(float(s.Value))
        return max(temps) if temps else None
    finally:
        comp.Close()

def get_core_clock_lhm(Hardware):
    comp = Hardware.Computer()
    comp.IsCpuEnabled = True
    comp.Open()
    try:
        clocks = []
        for hw in comp.Hardware:
            _full_update(hw)
            if str(hw.HardwareType).lower().endswith("cpu"):
                for s in hw.Sensors:
                    if str(s.SensorType).lower() == "clock" and s.Value is not None:
                        clocks.append(float(s.Value))
        return max(clocks) if clocks else None
    finally:
        comp.Close()

def get_core_clock_wmi_perf():
    try:
        import wmi
    except ImportError:
        return None
    try:
        w = wmi.WMI(namespace=r"root\cimv2")
        vals = [float(row.ProcessorFrequency)
                for row in w.Win32_PerfFormattedData_Counters_ProcessorInformation()
                if "_Total" not in row.Name]
        return max(vals) if vals else None
    except Exception:
        return None

def get_core_clock_wmi_perf_ppp(base_clock_mhz):
    try:
        import wmi
    except ImportError:
        return None
    try:
        w = wmi.WMI(namespace=r"root\cimv2")
        vals = []
        for row in w.Win32_PerfFormattedData_Counters_ProcessorInformation():
            if "_Total" in row.Name:
                continue
            p = getattr(row, "PercentProcessorPerformance", None)
            if p is not None:
                vals.append((float(p)/100.0) * base_clock_mhz)
        return max(vals) if vals else None
    except Exception:
        return None

def get_core_clock(Hardware):
    clk = get_core_clock_lhm(Hardware)
    if clk and 0 < clk < 10000:
        return clk
    base = globals().get("_BASE_CLOCK_CACHE")
    if base:
        clk = get_core_clock_wmi_perf_ppp(base)
        if clk and 0 < clk < 10000:
            return clk
    clk = get_core_clock_wmi_perf()
    if clk and 0 < clk < 10000:
        return clk
    return None

# ============================================================
# STRESS TEST
# ============================================================
def heavy_loop(duration):
    end = time.time() + duration
    x = 0.0
    while time.time() < end:
        x = (x + math.sqrt(12345.6789)) % 1.0

def start_stress_test(duration):
    cores = multiprocessing.cpu_count()
    # "fuer" statt "für", um Mojibake-Risiko zu minimieren
    print_flush(f"[TEST] Starte Stresstest auf {cores} Kernen fuer {duration}s ...")
    procs = []
    for _ in range(cores):
        p = multiprocessing.Process(target=heavy_loop, args=(duration,))
        p.start()
        procs.append(p)
    return procs

def stop_stress_test(procs):
    for p in procs:
        if p.is_alive():
            p.terminate()
        p.join(timeout=1)

# ============================================================
# MAIN
# ============================================================
def main(test_minutes=None):
    if USE_ADMIN_ELEVATION:
        ensure_admin()

    if test_minutes is None:
        test_minutes = DEFAULT_TEST_MINUTES

    if os.path.exists(LOG_FILE):
        try: os.remove(LOG_FILE)
        except: pass

    Hardware = load_clr_and_namespace()
    driver_ok = ensure_lhm_driver_ready(Hardware)
    hvci_on = is_memory_integrity_enabled()

    cpu_name, base_clock = get_cpu_info()
    globals()["_BASE_CLOCK_CACHE"] = base_clock

    if SHOW_HEADER:
        print_flush("====================================================")
        print_flush(f"Logdatei: {LOG_FILE}")
        print_flush(f"CPU: {cpu_name}")
        print_flush(f"Basistakt: {base_clock:.0f} MHz")
        print_flush(f"Modus: {'LHM' if (driver_ok and not hvci_on) else 'Fallback'}")
        print_flush("====================================================")

    init_temp = get_cpu_temperature(Hardware) if (driver_ok and not hvci_on) else None
    print_flush(f"CPU-Temp vor Test: {('N/A' if init_temp is None else f'{init_temp:.1f} °C')}")

    with open(LOG_FILE, "a", encoding="utf-8") as log:
        log.write("====================================================\n")
        log.write(time.strftime("%Y-%m-%d %H:%M:%S") + " - STARTE CLOCK-TEST (Core #1)\n")
        log.write(f"CPU: {cpu_name}, Basistakt: {base_clock:.0f} MHz\n")
        log.write(f"CPU-Temp vor Test: {('N/A' if init_temp is None else f'{init_temp:.1f} °C')}\n")

        test_seconds = max(30, int(test_minutes * 60))
        procs = start_stress_test(test_seconds)

        print_flush(f"\n--- Warm-up ({WARMUP_SECONDS}s) ---")
        log.write(f"\n--- Warm-up ({WARMUP_SECONDS}s) ---\n")
        for _ in range(WARMUP_SECONDS):
            clk = get_core_clock(Hardware)
            line = f"{time.strftime('%H:%M:%S')} - Warm-up: {('N/A' if clk is None else f'{clk:.1f} MHz')}"
            print_flush(line)
            if LOG_EACH: log.write(line + "\n")
            time.sleep(1)

        print_flush(f"\n--- Messung (max. {MEAS_MAX_VALUES} Werte, Timeout {MEAS_TIMEOUT_SECONDS}s) ---")
        log.write(f"\n--- Messung (max. {MEAS_MAX_VALUES} Werte, Timeout {MEAS_TIMEOUT_SECONDS}s) ---\n")
        vals = []
        deadline = time.time() + MEAS_TIMEOUT_SECONDS
        while len(vals) < MEAS_MAX_VALUES and time.time() < deadline:
            clk = get_core_clock(Hardware)
            if clk and 0 < clk < 10000:
                vals.append(clk)
                line = f"{time.strftime('%H:%M:%S')} - Core Clock: {clk:.1f} MHz"
            else:
                line = f"{time.strftime('%H:%M:%S')} - Core Clock: N/A"
            print_flush(line)
            if LOG_EACH: log.write(line + "\n")
            time.sleep(1)

        stop_stress_test(procs)

        if not vals:
            print_flush(f"\n{_SYM_ERR} Keine Messwerte – bitte Sensor-/Fallback prüfen.")
            log.write("\nKeine Messwerte.\n")
        else:
            avg = sum(vals) / len(vals)
            using_lhm_full = (driver_ok and not hvci_on)
            target_factor = TARGET_FACTOR_LHM if using_lhm_full else TARGET_FACTOR_FALLBACK
            threshold = target_factor * base_clock
            pct = (avg / base_clock) * 100.0

            res_line = (
                f"Durchschnitt: {avg:.1f} MHz (Soll: {threshold:.1f} MHz) "
                f"[Modus: {'LHM' if using_lhm_full else 'Fallback'}]"
            )
            print_flush(res_line)
            log.write(res_line + "\n")

            if avg < threshold:
                print_flush(f"{_SYM_ERR} {pct:.1f}% – unter Zielwert ({int(target_factor*100)}%).")
                log.write("FEHLER: Leistung unter Zielwert.\n")
            else:
                print_flush(f"{_SYM_OK} {pct:.1f}% – Test bestanden ({'LHM' if using_lhm_full else 'Fallback'}-Modus).")
                log.write("OK: CPU erbringt geforderte Leistung.\n")

        end_line = time.strftime("%Y-%m-%d %H:%M:%S") + " - TEST ENDE"
        print_flush("\n" + end_line)
        print_flush("====================================================")
        log.write(end_line + "\n")
        log.write("====================================================\n")

if __name__ == "__main__":
    mins = DEFAULT_TEST_MINUTES
    if len(sys.argv) >= 2:
        try: mins = int(sys.argv[1])
        except: pass
    main(test_minutes=mins)