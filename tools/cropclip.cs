using System;
using System.Drawing;
using System.IO;
using System.Threading;
using System.Windows.Forms;

// Helper ultrarrápido para mpv_crop_script.lua
// Recorta la captura temporal en memoria y la copia al portapapeles directamente.
// Tiempo de ejecución aproximado: ~20-40 ms (frente a los varios segundos de lanzar una 2da instancia de MPV).
static class Program {
    [STAThread]
    static int Main(string[] args) {
        if (args.Length < 5) return 1;
        string path = args[0];
        int x, y, w, h;
        if (!int.TryParse(args[1], out x)) return 1;
        if (!int.TryParse(args[2], out y)) return 1;
        if (!int.TryParse(args[3], out w)) return 1;
        if (!int.TryParse(args[4], out h)) return 1;

        if (!File.Exists(path)) return 2;

        try {
            using (var orig = new Bitmap(path)) {
                int cx = Math.Max(0, Math.Min(x, orig.Width - 1));
                int cy = Math.Max(0, Math.Min(y, orig.Height - 1));
                int cw = Math.Max(1, Math.Min(w, orig.Width - cx));
                int ch = Math.Max(1, Math.Min(h, orig.Height - cy));

                var rect = new Rectangle(cx, cy, cw, ch);
                using (var cropped = orig.Clone(rect, orig.PixelFormat)) {
                    for (int i = 0; i < 5; i++) {
                        try {
                            Clipboard.SetImage(cropped);
                            break;
                        } catch {
                            Thread.Sleep(40);
                        }
                    }
                }
            }
            try { File.Delete(path); } catch { }
            return 0;
        } catch (Exception) {
            try { File.Delete(path); } catch { }
            return 3;
        }
    }
}
