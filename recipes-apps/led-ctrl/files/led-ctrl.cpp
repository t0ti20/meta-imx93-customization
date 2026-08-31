// led-ctrl — RGB LED controller for i.MX93 FRDM
//
// Usage:
//   led-ctrl            daemon mode: fade through all colors
//   led-ctrl #RRGGBB    set a static color (daemon stays running, just stops fading)
//   led-ctrl --resume   resume fading (removes the static-color override)
//
// IPC: daemon polls /run/led-ctrl.color every loop.
//   If the file exists and contains a valid hex color → hold that color.
//   If the file is absent/empty → fade.
//
// PWM mapping (confirmed on FRDM-IMX93):
//   Green → pwmchip0 ch0  (TPM3_CH0, GPIO_IO04)
//   Blue  → pwmchip0 ch2  (TPM3_CH2, GPIO_IO12)
//   Red   → pwmchip4 ch2  (TPM4_CH2, GPIO_IO13)

#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <iostream>
#include <string>
#include <fcntl.h>
#include <unistd.h>
#include <csignal>

static const char* CONTROL_FILE = "/run/led-ctrl.color";
static const long  PERIOD_NS    = 1000000L;   // 1 ms → 1 kHz PWM

// ── PWM channel ──────────────────────────────────────────────────────────────

struct PwmCh {
    const char* chip;
    int         ch;
    int         duty_fd;   // keep the duty_cycle fd open for fast writes
};

static PwmCh CH_RED   = {"pwmchip4", 2, -1};
static PwmCh CH_GREEN = {"pwmchip0", 0, -1};
static PwmCh CH_BLUE  = {"pwmchip0", 2, -1};

static bool sysfs_write(const std::string& path, const std::string& val)
{
    std::ofstream f(path);
    if (!f) return false;
    f << val;
    return true;
}

static bool pwm_init(PwmCh& c)
{
    std::string base = std::string("/sys/class/pwm/") + c.chip;
    sysfs_write(base + "/export", std::to_string(c.ch));   // ignore if already exported

    std::string pwm = base + "/pwm" + std::to_string(c.ch);
    if (!sysfs_write(pwm + "/period",     std::to_string(PERIOD_NS))) return false;
    if (!sysfs_write(pwm + "/duty_cycle", "0"))                       return false;
    if (!sysfs_write(pwm + "/enable",     "1"))                       return false;

    // Open duty_cycle fd and keep it open — avoids open() overhead per frame
    c.duty_fd = open((pwm + "/duty_cycle").c_str(), O_WRONLY);
    return c.duty_fd >= 0;
}

static void pwm_set(const PwmCh& c, uint8_t brightness)
{
    long  duty = (long)brightness * PERIOD_NS / 255L;
    char  buf[16];
    int   len = snprintf(buf, sizeof(buf), "%ld", duty);
    (void)pwrite(c.duty_fd, buf, len, 0);
}

// ── Color helpers ─────────────────────────────────────────────────────────────

static bool parse_hex(const std::string& s, uint8_t& r, uint8_t& g, uint8_t& b)
{
    std::string hex = s;
    if (!hex.empty() && hex[0] == '#') hex = hex.substr(1);
    if (hex.size() != 6) return false;
    try {
        unsigned long v = std::stoul(hex, nullptr, 16);
        r = (v >> 16) & 0xFF;
        g = (v >>  8) & 0xFF;
        b =  v        & 0xFF;
        return true;
    } catch (...) { return false; }
}

static void hsv_to_rgb(float h, float s, float v, uint8_t& r, uint8_t& g, uint8_t& b)
{
    float c  = v * s;
    float x  = c * (1.0f - std::fabs(std::fmod(h / 60.0f, 2.0f) - 1.0f));
    float m  = v - c;
    float r1, g1, b1;
    if      (h <  60) { r1=c; g1=x; b1=0; }
    else if (h < 120) { r1=x; g1=c; b1=0; }
    else if (h < 180) { r1=0; g1=c; b1=x; }
    else if (h < 240) { r1=0; g1=x; b1=c; }
    else if (h < 300) { r1=x; g1=0; b1=c; }
    else              { r1=c; g1=0; b1=x; }
    r = static_cast<uint8_t>((r1 + m) * 255.0f);
    g = static_cast<uint8_t>((g1 + m) * 255.0f);
    b = static_cast<uint8_t>((b1 + m) * 255.0f);
}

static void set_rgb(uint8_t r, uint8_t g, uint8_t b)
{
    pwm_set(CH_RED,   r);
    pwm_set(CH_GREEN, g);
    pwm_set(CH_BLUE,  b);
}

// ── Control file ──────────────────────────────────────────────────────────────

static bool read_control(uint8_t& r, uint8_t& g, uint8_t& b)
{
    std::ifstream f(CONTROL_FILE);
    if (!f) return false;
    std::string line;
    if (!std::getline(f, line) || line.empty()) return false;
    return parse_hex(line, r, g, b);
}

// ── Signal handling ───────────────────────────────────────────────────────────

static volatile sig_atomic_t g_running = 1;
static void on_signal(int) { g_running = 0; }

// ── main ──────────────────────────────────────────────────────────────────────

int main(int argc, char* argv[])
{
    // ── Client modes ──────────────────────────────────────────────────────────
    if (argc >= 2) {
        std::string arg = argv[1];

        if (arg == "--resume" || arg == "-r") {
            if (remove(CONTROL_FILE) == 0)
                std::cout << "Fading resumed\n";
            else
                std::cout << "Already in fading mode\n";
            return 0;
        }

        uint8_t r, g, b;
        if (!parse_hex(arg, r, g, b)) {
            std::cerr << "Usage:\n"
                      << "  led-ctrl               start daemon (fade)\n"
                      << "  led-ctrl #RRGGBB       set static color\n"
                      << "  led-ctrl --resume      resume fading\n";
            return 1;
        }

        std::ofstream f(CONTROL_FILE);
        if (!f) {
            std::cerr << "Cannot write " << CONTROL_FILE << "\n";
            return 1;
        }
        f << arg << "\n";
        std::cout << "Color set to " << arg << "\n";
        return 0;
    }

    // ── Daemon mode ───────────────────────────────────────────────────────────
    signal(SIGINT,  on_signal);
    signal(SIGTERM, on_signal);

    if (!pwm_init(CH_RED)   ||
        !pwm_init(CH_GREEN) ||
        !pwm_init(CH_BLUE)) {
        std::cerr << "Failed to initialise PWM channels\n";
        return 1;
    }

    // Hue step: 0.3 degrees per 20 ms → full 360° cycle ≈ 24 s
    float hue  = 0.0f;
    const float HUE_STEP = 0.3f;

    while (g_running) {
        uint8_t r, g, b;

        if (read_control(r, g, b)) {
            // Static color mode — poll slowly
            set_rgb(r, g, b);
            usleep(100000);   // 100 ms
        } else {
            // Fading mode
            hsv_to_rgb(hue, 1.0f, 1.0f, r, g, b);
            set_rgb(r, g, b);
            hue = std::fmod(hue + HUE_STEP, 360.0f);
            usleep(20000);    // 20 ms → ~50 fps
        }
    }

    set_rgb(0, 0, 0);
    return 0;
}
