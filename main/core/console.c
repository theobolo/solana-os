// UART0 command console. Besides the hardware commands from the reference
// firmware it can drive the UI (open, key, shot), which is how the OS is
// tested without touching the buttons: see tools/badge.py.

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <dirent.h>
#include <sys/stat.h>
#include <unistd.h>
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "esp_console.h"
#include "driver/uart.h"
#include "esp_timer.h"
#include "esp_heap_caps.h"
#include "esp_log.h"
#include "esp_system.h"
#include "esp_app_desc.h"
#include "esp_wifi.h"
#include "psa/crypto.h"
#include "bsp.h"
#include "console.h"
#include "os.h"
#include "os_wifi.h"
#include "os_cloud.h"
#include "os_cmd.h"
#include "os_http.h"
#include "os_mem.h"
#include "os_ws.h"

static const char *TAG = "console";

static int cmd_heap(int argc, char **argv);

static int cmd_info(int argc, char **argv)
{
    printf("Solana OS %s\nBoard: ESP32-C5 badge\n"
           "  SPI2 SCK=%d MOSI=%d MISO=%d | LCD CS=%d DC=%d RST=%d BL=%d | SD CS=%d\n"
           "  I2C SCL=%d SDA=%d TCA9534@0x%02X INT=%d | BOOT=%d | WS2812 x%d on %d\n"
           "  Battery ADC GPIO%d (x%d) | UART0 TX=%d RX=%d\n",
           esp_app_get_description()->version, BOARD_SPI_SCK, BOARD_SPI_MOSI, BOARD_SPI_MISO, BOARD_LCD_CS, BOARD_LCD_DC, BOARD_LCD_RST, BOARD_LCD_BL,
           BOARD_SD_CS, BOARD_I2C_SCL, BOARD_I2C_SDA, BOARD_TCA9534_ADDR, BOARD_TCA9534_INT, BOARD_BOOT_BTN,
           BOARD_RGB_COUNT, BOARD_RGB_GPIO, BOARD_BAT_ADC_GPIO, BOARD_BAT_DIVIDER, BOARD_UART_TX, BOARD_UART_RX);
    int mv = bsp_battery_mv();
    printf("Battery: %d mV (%d%%)\nButtons: 0x%02lX\nHeap: %u bytes free\n", mv, bsp_battery_percent(mv),
           (unsigned long)bsp_buttons_get(), (unsigned)heap_caps_get_free_size(OS_MEM_SRAM));
    if (os_mem_psram()) {
        printf("PSRAM: %u KB, %u KB free\n", (unsigned)(heap_caps_get_total_size(OS_MEM_PSRAM) / 1024),
               (unsigned)(heap_caps_get_free_size(OS_MEM_PSRAM) / 1024));
    } else {
        printf("PSRAM: none\n");
    }
    printf("LCD: colour inversion %s\n", bsp_display_inverted() ? "on" : "off");
    bsp_sd_print_card();
    return 0;
}

static int sd_speed_test(void)
{
    const char *path = BSP_SD_MOUNT "/speed.bin";
    const int chunk = 4096, total = 256 * 1024;
    uint8_t *buf = malloc(chunk);
    if (!buf) {
        return 1;
    }
    FILE *f = fopen(path, "wb");
    if (!f) {
        printf("open for write failed\n");
        free(buf);
        return 1;
    }
    int64_t t0 = esp_timer_get_time();
    for (int off = 0; off < total; off += chunk) {
        for (int i = 0; i < chunk; i++) {
            buf[i] = (uint8_t)((off + i) * 7);
        }
        fwrite(buf, 1, chunk, f);
    }
    fclose(f);
    int64_t t1 = esp_timer_get_time();
    f = fopen(path, "rb");
    int bad = f ? 0 : 1;
    for (int off = 0; f && off < total; off += chunk) {
        if (fread(buf, 1, chunk, f) != chunk) {
            bad++;
            break;
        }
        for (int i = 0; i < chunk; i++) {
            if (buf[i] != (uint8_t)((off + i) * 7)) {
                bad++;
                break;
            }
        }
    }
    if (f) {
        fclose(f);
    }
    int64_t t2 = esp_timer_get_time();
    unlink(path);
    free(buf);
    printf("SD test: wrote %d KB at %lld KB/s, read+verify at %lld KB/s -> %s\n", total / 1024,
           (int64_t)total * 1000 / (t1 - t0), (int64_t)total * 1000 / (t2 - t1), bad ? "FAIL" : "PASS");
    return bad ? 1 : 0;
}

static int cmd_sd(int argc, char **argv)
{
    const char *sub = argc > 1 ? argv[1] : "info";
    esp_err_t err = ESP_OK;
    if (!strcmp(sub, "info")) {
        bsp_sd_print_card();
        return 0;
    } else if (!strcmp(sub, "mount")) {
        err = bsp_sd_mount();
    } else if (!strcmp(sub, "unmount")) {
        err = bsp_sd_unmount();
    } else if (!strcmp(sub, "format")) {
        if (argc < 3 || strcmp(argv[2], "yes")) {
            printf("This erases the card. Run: sd format yes\n");
            return 1;
        }
        err = bsp_sd_format();
    } else if (!strcmp(sub, "test")) {
        int rc = sd_speed_test();
        bsp_sd_refresh_usage();
        return rc;
    } else {
        printf("usage: sd [info|mount|unmount|format yes|test]\n");
        return 1;
    }
    printf("%s\n", esp_err_to_name(err));
    return err == ESP_OK ? 0 : 1;
}

static int cmd_ls(int argc, char **argv)
{
    char path[128];
    snprintf(path, sizeof(path), "%s%s%s", BSP_SD_MOUNT, argc > 1 && argv[1][0] != '/' ? "/" : "", argc > 1 ? argv[1] : "");
    DIR *d = opendir(path);
    if (!d) {
        printf("cannot open %s\n", path);
        return 1;
    }
    struct dirent *de;
    while ((de = readdir(d))) {
        char full[400];
        struct stat st = {0};
        snprintf(full, sizeof(full), "%s/%s", path, de->d_name);
        stat(full, &st);
        printf("%s %10ld  %s\n", de->d_type == DT_DIR ? "d" : "-", (long)st.st_size, de->d_name);
    }
    closedir(d);
    return 0;
}

static int cmd_cat(int argc, char **argv)
{
    if (argc < 2) {
        printf("usage: cat <file>\n");
        return 1;
    }
    char path[160];
    snprintf(path, sizeof(path), "%s/%s", BSP_SD_MOUNT, argv[1][0] == '/' ? argv[1] + 1 : argv[1]);
    FILE *f = fopen(path, "r");
    if (!f) {
        printf("cannot open %s\n", path);
        return 1;
    }
    char line[128];
    while (fgets(line, sizeof(line), f)) {
        fputs(line, stdout);
    }
    fclose(f);
    printf("\n");
    return 0;
}

static int cmd_rgb(int argc, char **argv)
{
    if (argc != 5) {
        printf("usage: rgb <0-%d|all> <r> <g> <b>   (0-255)\n", BOARD_RGB_COUNT - 1);
        return 1;
    }
    int r = atoi(argv[2]), g = atoi(argv[3]), b = atoi(argv[4]);
    if (!strcmp(argv[1], "all")) {
        bsp_rgb_fill(r, g, b);
    } else {
        bsp_rgb_set(atoi(argv[1]), r, g, b);
    }
    bsp_rgb_show();
    return 0;
}

static int cmd_apps(int argc, char **argv)
{
    const os_app_t *cur = os_current();
    for (int i = 0; i < os_app_count; i++) {
        printf("%c %-8s %s\n", os_apps[i] == cur ? '*' : ' ', os_apps[i]->id, os_apps[i]->name);
    }
    return 0;
}

static int cmd_open(int argc, char **argv)
{
    if (argc != 2) {
        printf("usage: open <app id|home>\n");
        return 1;
    }
    os_launch_id(argv[1]);
    return 0;
}

static int cmd_key(int argc, char **argv)
{
    if (argc < 2) {
        printf("usage: key <up|down|left|right|select|back|home>... \n");
        return 1;
    }
    for (int i = 1; i < argc; i++) {
        os_key_t k = os_key_parse(argv[i]);
        if (k == OS_KEY_NONE) {
            printf("unknown key '%s'\n", argv[i]);
            return 1;
        }
        os_inject_key(k);
        vTaskDelay(pdMS_TO_TICKS(150));
    }
    return 0;
}

static int cmd_wifi(int argc, char **argv)
{
    const char *sub = argc > 1 ? argv[1] : "status";
    if (!strcmp(sub, "connect") && argc >= 3) {
        // Optional channel: join the SSID's AP there (like picking a band row in the app).
        return os_wifi_connect_ch(argv[2], argc > 3 ? argv[3] : "", argc > 4 ? atoi(argv[4]) : 0) == ESP_OK ? 0 : 1;
    } else if (!strcmp(sub, "forget")) {
        os_wifi_forget();
        return 0;
    } else if (!strcmp(sub, "on") || !strcmp(sub, "off")) {
        os_wifi_set_enabled(!strcmp(sub, "on"));
        return 0;
    } else if (strcmp(sub, "status")) {
        printf("usage: wifi [status|on|off|connect <ssid> [pass [channel]]|forget]\n");
        return 1;
    }
    static const char *names[] = {"idle", "connecting", "connected", "failed", "suspended"};
    os_wifi_info_t in;
    os_wifi_get_info(&in);
    printf("wifi: %s (%s)  ssid='%s' ip=%s rssi=%d ch=%d %s\n", names[in.state], in.enabled ? "on" : "off", in.ssid,
           in.ip, in.rssi, in.channel, in.fail_reason ? in.fail_reason : "");
    return 0;
}

static int cmd_server(int argc, char **argv)
{
    if (argc > 2) {
        printf("usage: server [url|clear]\n");
        return 1;
    }
    if (argc == 2) {
        const char *url = argv[1];
        if (!strcmp(url, "clear")) {
            url = "";
        } else if (strncmp(url, "http://", 7) && strncmp(url, "https://", 8)) {
            printf("the server must start with http:// or https://\n");
            return 1;
        }
        os_cloud_set_server(url);
    }
    os_cloud_info_t in;
    os_cloud_get_info(&in);
    printf("server: %s\n", in.server[0] ? in.server : "(not set)");
    return 0;
}

static int cmd_cloud(int argc, char **argv)
{
    if (argc > 1 && !strcmp(argv[1], "hangup")) {
        // Drops the kept-alive connection but keeps its session ticket, so the next
        // request resumes the TLS session: the path a connection the network reset takes.
        os_http_hangup();
        printf("cloud: connection closed; the next request resumes the TLS session\n");
        return 0;
    }
    static const char *names[] = {"offline", "connecting", "unclaimed", "claimed", "error", "linked elsewhere"};
    os_cloud_info_t in;
    os_cloud_get_info(&in);
    printf("cloud: %s%s  server=%s\n  id=%s owner=%s\n  claim=%s\n", names[in.state], in.busy ? " (busy)" : "",
           in.server[0] ? in.server : "(not set)", in.id[0] ? in.id : "-", in.owner[0] ? in.owner : "-",
           in.claim_url[0] ? in.claim_url : "-");
    printf("  last http=%d next hello in %d s%s%s\n", in.http_status, in.retry_s, in.error ? "  error: " : "",
           in.error ? in.error : "");
    if (in.message[0]) {
        printf("  server: %s\n", in.message);
    }
    uint32_t requests, connects;
    os_http_stats(&requests, &connects);
    printf("  http: %lu requests on %lu connections, %s\n", (unsigned long)requests, (unsigned long)connects,
           os_http_connected() ? "connection open" : "no connection");
    return cmd_heap(0, NULL);
}

static int cmd_shot(int argc, char **argv)
{
    os_screenshot();
    vTaskDelay(pdMS_TO_TICKS(100));
    return 0;
}

static int cmd_heap(int argc, char **argv)
{
    // The first line is the SRAM, as in 1.x (the heap whose limits matter
    // most: stacks, DMA, LVGL, Bluetooth); PSRAM follows when there is some.
    printf("heap: %u free, %u min, %u largest block\n", (unsigned)heap_caps_get_free_size(OS_MEM_SRAM),
           (unsigned)heap_caps_get_minimum_free_size(OS_MEM_SRAM),
           (unsigned)heap_caps_get_largest_free_block(OS_MEM_SRAM));
    if (os_mem_psram()) {
        // Of that, what malloc can still take: not the 32 KB DMA pool (os_mem.h).
        printf("sram: %u free for malloc, %u min\n", (unsigned)heap_caps_get_free_size(OS_MEM_SRAM_MALLOC),
               (unsigned)heap_caps_get_minimum_free_size(OS_MEM_SRAM_MALLOC));
        printf("psram: %u free, %u min, %u largest block, %u total\n", (unsigned)heap_caps_get_free_size(OS_MEM_PSRAM),
               (unsigned)heap_caps_get_minimum_free_size(OS_MEM_PSRAM),
               (unsigned)heap_caps_get_largest_free_block(OS_MEM_PSRAM),
               (unsigned)heap_caps_get_total_size(OS_MEM_PSRAM));
    }
    if (argc > 1 && !strcmp(argv[1], "stacks")) {
        // Bytes each task has never touched since boot (its worst case so far).
        static const char *const names[] = {"taskLVGL", "os", "mesh", "cloud", "lua", "console_repl", "lua_inst", "buttons"};
        for (int i = 0; i < sizeof(names) / sizeof(names[0]); i++) {
            TaskHandle_t t = xTaskGetHandle(names[i]);
            if (t) {
                printf("  %-12s %5u B of stack never used\n", names[i], (unsigned)uxTaskGetStackHighWaterMark(t));
            }
        }
    }
    return 0;
}


static int cmd_reboot(int argc, char **argv)
{
    esp_restart();
    return 0;
}

// The REPL waits in our command meanwhile, so the UART is ours: read its
// driver directly (the REPL installed it). stdin's VFS would add nothing, and
// in the console's CR mode it holds no byte back.
int console_stream_read(void *buf, size_t n, int timeout_ms)
{
    if (!n) {
        return 0;                           // asking whether this console streams: it does
    }
    int got = uart_read_bytes(CONFIG_ESP_CONSOLE_UART_NUM, buf, n, pdMS_TO_TICKS(timeout_ms));
    return got < 0 ? -1 : got;
}

// fdbench [seconds]: can this badge keep up with a Firedancer dashboard's websocket?
// It connects to gui.firedancer.io asking for zstd compression, reads everything and
// throws it away, and says each second what came. The connection needs a task with
// room for a TLS handshake, so it runs on its own; "cloud hangup" first frees the
// badge server's connection if the heap is short.
static volatile bool s_fdbench;
static int s_fdbench_mode;                  // FD_STORE, FD_DISCARD or FD_RAW
enum { FD_STORE, FD_DISCARD, FD_RAW };

#if CONFIG_FREERTOS_GENERATE_RUN_TIME_STATS
// Since the last call: the share of the CPU each task had (one core: they add up to
// 100%), as "busy X%: the four busiest". The first call only takes the counters.
static void fdbench_cpu(char *out, size_t n)
{
    static TaskStatus_t was[40], now[40];
    static UBaseType_t nwas;
    static configRUN_TIME_COUNTER_TYPE twas;
    configRUN_TIME_COUNTER_TYPE t;
    UBaseType_t k = uxTaskGetSystemState(now, 40, &t);
    out[0] = 0;
    if (nwas && t > twas) {
        const char *name[4] = { 0 };
        unsigned top[4] = { 0 };
        unsigned idle = 0;
        for (UBaseType_t i = 0; i < k; i++) {
            configRUN_TIME_COUNTER_TYPE d = now[i].ulRunTimeCounter;
            for (UBaseType_t j = 0; j < nwas; j++) {
                if (was[j].xHandle == now[i].xHandle) {
                    d -= was[j].ulRunTimeCounter;
                    break;
                }
            }
            unsigned pct = (unsigned)(d * 100 / (t - twas));
            if (!strncmp(now[i].pcTaskName, "IDLE", 4)) {
                idle += pct;
                continue;
            }
            for (int r = 0; r < 4; r++) {
                if (pct > top[r]) {
                    for (int q = 3; q > r; q--) {
                        top[q] = top[q - 1];
                        name[q] = name[q - 1];
                    }
                    top[r] = pct;
                    name[r] = now[i].pcTaskName;
                    break;
                }
            }
        }
        snprintf(out, n, "  cpu busy %u%%: %s %u%%, %s %u%%, %s %u%%, %s %u%%", 100 - (idle > 100 ? 100 : idle),
                 name[0] ? name[0] : "-", top[0], name[1] ? name[1] : "-", top[1], name[2] ? name[2] : "-", top[2],
                 name[3] ? name[3] : "-", top[3]);
    }
    memcpy(was, now, sizeof(TaskStatus_t) * k);
    nwas = k;
    twas = t;
}
#else
static void fdbench_cpu(char *out, size_t n)
{
    out[0] = 0;
}
#endif

static void fdbench_task(void *arg)
{
    int secs = (int)(intptr_t)arg;
    static const char *const MODE[] = { "store", "discard", "raw" };
    printf("fdbench: connecting to gui.firedancer.io (%s)...\n", MODE[s_fdbench_mode]);
    char *raw = s_fdbench_mode == FD_RAW ? heap_caps_malloc(16384, MALLOC_CAP_INTERNAL) : NULL;
    if (s_fdbench_mode == FD_RAW && !raw) {
        printf("fdbench: no memory for its buffer\n");
        s_fdbench = false;
        vTaskDelete(NULL);
    }
    os_ws_bench_discard(s_fdbench_mode == FD_DISCARD);
    int64_t t0 = esp_timer_get_time();
    esp_err_t err = os_ws_connect("wss://gui.firedancer.io/websocket", "compress-zstd");
    if (err != ESP_OK) {
        printf("fdbench: no connection (%s)%s\n", esp_err_to_name(err),
               err == ESP_ERR_NO_MEM ? ": try 'cloud hangup' first" : "");
        os_ws_bench_discard(false);
        free(raw);
        s_fdbench = false;
        vTaskDelete(NULL);
    }
    int64_t now = esp_timer_get_time();
    printf("fdbench: open in %d ms, reading for %d s\n", (int)((now - t0) / 1000), secs);
    char cpu[128];
    fdbench_cpu(cpu, sizeof(cpu));
    int64_t tick = now, end = now + (int64_t)secs * 1000000;
    size_t bytes = 0, biggest = 0;
    uint32_t total_kb = 0;
    int msgs = 0, zstd = 0, n = 0;
    for (;;) {
        char *m = NULL;
        size_t len = 0;
        int code = 0;
        int r;
        if (raw) {
            // The bytes only: no frames, no messages (msgs/s stays 0).
            r = os_ws_read_raw(raw, 16384, 200);
            if (r > 0) {
                bytes += r;
                r = OS_WS_TIMEOUT;
            } else if (r == 0) {
                r = OS_WS_TIMEOUT;
            } else {
                r = OS_WS_LOST;
            }
        } else {
            r = os_ws_recv(&m, &len, 4u << 20, 200, &code);
        }
        if (r == OS_WS_MSG) {
            msgs++;
            bytes += len;
            biggest = len > biggest ? len : biggest;
            zstd += m && len >= 4 && (uint8_t)m[0] == 0x28 && (uint8_t)m[1] == 0xB5 && (uint8_t)m[2] == 0x2F && (uint8_t)m[3] == 0xFD;
            free(m);
        } else if (r != OS_WS_TIMEOUT) {
            printf("fdbench: the connection ended (%d, close code %d)\n", r, code);
            break;
        }
        now = esp_timer_get_time();
        if (now - tick >= 1000000) {
            int rssi = 0;
            esp_wifi_sta_get_rssi(&rssi);
            fdbench_cpu(cpu, sizeof(cpu));
            printf("fdbench: %2d s  %4u KB/s  %4d msgs/s (%d zstd)  biggest %u KB  heap %u KB free, %u KB internal  rssi %d  tcp wnd %u%s\n",
                   ++n, (unsigned)(bytes / 1000), msgs, zstd, (unsigned)(biggest / 1000),
                   (unsigned)(esp_get_free_heap_size() / 1024),
                   (unsigned)(heap_caps_get_free_size(MALLOC_CAP_INTERNAL) / 1024),
                   rssi, (unsigned)CONFIG_LWIP_TCP_WND_DEFAULT, cpu);
            total_kb += bytes / 1000;
            bytes = 0;
            msgs = zstd = 0;
            tick = now;
        }
        if (now >= end) {
            break;
        }
    }
    os_ws_close(1000);
    os_ws_bench_discard(false);
    free(raw);
    printf("fdbench: done, %u KB in %d s (a desktop gets ~420 KB/s from this dashboard)\n", (unsigned)total_kb, n);
    s_fdbench = false;
    vTaskDelete(NULL);
}

// fdbench aes: what the dashboard's cipher (TLS 1.2, ECDHE-ECDSA-AES128-GCM-SHA256 from
// Cloudflare) costs to decrypt here, through PSA as TLS calls it (the AES peripheral),
// on a 16 KB record in PSRAM (where TLS buffers go, os_mem_tls_caps) and in internal RAM.
static void fdbench_aes(void)
{
    static const uint8_t key[16] = { 1, 2, 3 }, iv[12] = { 4, 5, 6 };
    const size_t len = 16384;
    psa_key_attributes_t a = PSA_KEY_ATTRIBUTES_INIT;
    psa_key_id_t k = 0;
    psa_set_key_type(&a, PSA_KEY_TYPE_AES);
    psa_set_key_bits(&a, 128);
    psa_set_key_usage_flags(&a, PSA_KEY_USAGE_ENCRYPT | PSA_KEY_USAGE_DECRYPT);
    psa_set_key_algorithm(&a, PSA_ALG_GCM);
    if (psa_crypto_init() != PSA_SUCCESS || psa_import_key(&a, key, sizeof(key), &k) != PSA_SUCCESS) {
        printf("fdbench aes: no key\n");
        return;
    }
    for (int where = 0; where < 2; where++) {
        unsigned caps = where ? MALLOC_CAP_INTERNAL : os_mem_tls_caps();
        uint8_t *plain = heap_caps_malloc(len, caps), *sealed = heap_caps_malloc(len + 16, caps);
        size_t got = 0;
        if (!plain || !sealed) {
            printf("fdbench aes: no memory\n");
        } else {
            memset(plain, 0x5A, len);
            psa_status_t st = psa_aead_encrypt(k, PSA_ALG_GCM, iv, sizeof(iv), NULL, 0, plain, len, sealed, len + 16, &got);
            int n = 0;
            int64_t t0 = esp_timer_get_time(), t;
            do {
                st |= psa_aead_decrypt(k, PSA_ALG_GCM, iv, sizeof(iv), NULL, 0, sealed, len + 16, plain, len, &got);
                n++;
                t = esp_timer_get_time() - t0;
            } while (t < 1000000);
            unsigned kbps = (unsigned)((int64_t)n * len * 1000 / t);    // bytes/ms = KB/s
            printf("fdbench aes: AES-128-GCM decrypt, 16 KB records in %s: %u KB/s%s; 450 KB/s of TLS takes %u%% of the CPU\n",
                   where ? "internal RAM" : "PSRAM", kbps, st != PSA_SUCCESS ? " (failed!)" : "",
                   (unsigned)(450u * 100 / (kbps ? kbps : 1)));
        }
        free(plain);
        free(sealed);
    }
    psa_destroy_key(k);
}

// top [seconds]: each second, how busy the CPU was and its four busiest tasks, from a
// task of its own so the console stays free (key, shot) meanwhile. Needs a build with
// FreeRTOS run-time stats (sdkconfig.stats).
static void top_task(void *arg)
{
    char cpu[128];
    fdbench_cpu(cpu, sizeof(cpu));
    for (int i = 0, n = (int)(intptr_t)arg; i < n; i++) {
        vTaskDelay(pdMS_TO_TICKS(1000));
        fdbench_cpu(cpu, sizeof(cpu));
        printf("top: %2d s%s\n", i + 1, cpu[0] ? cpu : "  (no run-time stats in this build)");
    }
    vTaskDelete(NULL);
}

static int cmd_top(int argc, char **argv)
{
    int secs = argc > 1 ? atoi(argv[1]) : 10;
    secs = secs < 1 ? 1 : secs > 600 ? 600 : secs;
    if (xTaskCreate(top_task, "top", 3 * 1024, (void *)(intptr_t)secs, 2, NULL) != pdPASS) {
        printf("top: no memory for its task\n");
        return 1;
    }
    return 0;
}

static int cmd_fdbench(int argc, char **argv)
{
    if (s_fdbench) {
        printf("fdbench is running\n");
        return 1;
    }
    if (os_wifi_state() != OS_WIFI_CONNECTED) {
        printf("fdbench: join Wi-Fi first\n");
        return 1;
    }
    if (argc > 1 && !strcmp(argv[1], "aes")) {
        fdbench_aes();
        return 0;
    }
    int secs = argc > 1 ? atoi(argv[1]) : 20;
    secs = secs < 5 ? 5 : secs > 120 ? 120 : secs;
    const char *mode = argc > 2 ? argv[2] : "store";
    s_fdbench_mode = !strcmp(mode, "discard") ? FD_DISCARD : !strcmp(mode, "raw") ? FD_RAW : FD_STORE;
    s_fdbench = true;
    if (xTaskCreate(fdbench_task, "fdbench", 12 * 1024, (void *)(intptr_t)secs, 4, NULL) != pdPASS) {
        s_fdbench = false;
        printf("fdbench: no memory for its task\n");
        return 1;
    }
    return 0;
}

static void start_now(void)
{
    esp_console_repl_t *repl;
    esp_console_repl_config_t repl_cfg = ESP_CONSOLE_REPL_CONFIG_DEFAULT();
    repl_cfg.prompt = "sol>";
    // lua list, sums and recv parse manifests and hash files on this task:
    // with the default 4 KB, lua list left ~600 bytes of it unused.
    repl_cfg.task_stack_size = 5 * 1024;
    esp_console_dev_uart_config_t uart_cfg = ESP_CONSOLE_DEV_UART_CONFIG_DEFAULT();
    ESP_ERROR_CHECK(esp_console_new_repl_uart(&uart_cfg, &repl_cfg, &repl));

    const esp_console_cmd_t cmds[] = {
        { .command = "info", .help = "Board pinout, battery, buttons, SD card", .func = cmd_info },
        { .command = "sd", .help = "sd [info|mount|unmount|format yes|test]", .func = cmd_sd },
        { .command = "ls", .help = "ls [dir] - list files on the SD card", .func = cmd_ls },
        { .command = "cat", .help = "cat <file> - print a text file from the SD card", .func = cmd_cat },
        { .command = "rgb", .help = "rgb <index|all> <r> <g> <b>", .func = cmd_rgb },
        { .command = "apps", .help = "List installed apps", .func = cmd_apps },
        { .command = "open", .help = "open <app id|home> - launch an app", .func = cmd_open },
        { .command = "key", .help = "key <up|down|left|right|select|back|home>... - press keys", .func = cmd_key },
        { .command = "wifi", .help = "wifi [status|on|off|connect <ssid> [pass [channel]]|forget]", .func = cmd_wifi },
        { .command = "server", .help = "server [url|clear] - show or set the badge server", .func = cmd_server },
        { .command = "cloud", .help = "cloud [hangup] - badge server link: state, badge ID, owner, claim URL; hangup closes the connection", .func = cmd_cloud },
        { .command = "shot", .help = "Dump a screenshot (decode with tools/badge.py)", .func = cmd_shot },
        { .command = "heap", .help = "heap [stacks] - heap usage, and the tasks' stack margins", .func = cmd_heap },
        { .command = "fdbench", .help = "fdbench [seconds] [store|discard|raw] | fdbench aes - read a Firedancer dashboard's websocket and say how fast it comes (discard: keep no message, raw: bytes only), or time its cipher", .func = cmd_fdbench },
        { .command = "top", .help = "top [seconds] - each second, how busy the CPU was and its busiest tasks (needs run-time stats)", .func = cmd_top },
        { .command = "reboot", .help = "Restart the badge", .func = cmd_reboot },
    };
    for (int i = 0; i < sizeof(cmds) / sizeof(cmds[0]); i++) {
        ESP_ERROR_CHECK(esp_console_cmd_register(&cmds[i]));
    }
    // Commands from portable code (os_cmd.h): same signature as esp_console's.
    for (int i = 0; i < os_cmd_count(); i++) {
        const os_cmd_t *c = os_cmd_get(i);
        const esp_console_cmd_t ec = { .command = c->name, .help = c->help, .func = c->fn };
        ESP_ERROR_CHECK(esp_console_cmd_register(&ec));
    }
    esp_console_register_help_command();
    ESP_ERROR_CHECK(esp_console_start_repl(repl));
    ESP_LOGI(TAG, "console ready, type 'help'");
}

// The REPL task, the UART driver and the command table hold ~8 KB of heap
// that a badge on battery has no one to talk to with: they start when USB
// power is present (the status bar's rule), at boot or once plugged in.
void console_start(void)
{
    os_on_usb_power(start_now);
}
