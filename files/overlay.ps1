param([int]$Port, [string]$Token, [int]$HubPid, [string]$Root, [string]$Game = '', [int]$Button = 1, [int]$Card = 1)
# overlay.ps1 - cosas que se dibujan ENCIMA de Sven Co-op (solo cuando esta en primer plano; nunca roban el foco):
#   * Boton flotante: clic o F9 abre los Comandos del Hub. Se arrastra; clic derecho lo oculta.
#   * Tarjeta de /tp: al hacer /tp muestra la skin y el nombre de la persona. Lee la linea [HUBTP] que escribe el plugin en la consola del juego.
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
$OverlaySource = @'
using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Runtime.InteropServices;
using System.Windows.Forms;

public class HubOverlay : Form
{
    public Action OnOpen;
    public Action<int, int> OnMoved;
    public Action OnHide;
    Point downAt, downLoc;
    bool down, dragged, hotkeyOn;
    const int S = 48;

    [DllImport("user32.dll")] static extern bool RegisterHotKey(IntPtr h, int id, uint mod, uint vk);
    [DllImport("user32.dll")] static extern bool UnregisterHotKey(IntPtr h, int id);

    public HubOverlay(int x, int y)
    {
        FormBorderStyle = FormBorderStyle.None;
        StartPosition = FormStartPosition.Manual;
        Location = new Point(x, y);
        Size = new Size(S, S);
        ShowInTaskbar = false;
        TopMost = true;
        BackColor = Color.FromArgb(18, 20, 24);
        Opacity = 0.45;
        DoubleBuffered = true;
        Cursor = Cursors.Hand;
        GraphicsPath gp = new GraphicsPath();
        int r = 14;
        gp.AddArc(0, 0, r * 2, r * 2, 180, 90);
        gp.AddArc(S - r * 2 - 1, 0, r * 2, r * 2, 270, 90);
        gp.AddArc(S - r * 2 - 1, S - r * 2 - 1, r * 2, r * 2, 0, 90);
        gp.AddArc(0, S - r * 2 - 1, r * 2, r * 2, 90, 90);
        gp.CloseFigure();
        Region = new Region(gp);
    }

    protected override bool ShowWithoutActivation { get { return true; } }

    protected override CreateParams CreateParams
    {
        get { CreateParams cp = base.CreateParams; cp.ExStyle |= 0x08000000 | 0x00000080; return cp; } // NOACTIVATE | TOOLWINDOW
    }

    // F9 solo existe mientras el boton esta visible (o sea, mientras el juego esta al frente)
    public void SetHotkey(bool on)
    {
        if (on == hotkeyOn) return;
        if (on) hotkeyOn = RegisterHotKey(Handle, 1, 0x4000, 0x78);
        else { UnregisterHotKey(Handle, 1); hotkeyOn = false; }
    }

    protected override void WndProc(ref Message m)
    {
        if (m.Msg == 0x0312 && OnOpen != null) OnOpen();
        base.WndProc(ref m);
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        Graphics g = e.Graphics;
        g.SmoothingMode = SmoothingMode.AntiAlias;
        Color orange = Color.FromArgb(255, 255, 168, 38);
        using (Pen pen = new Pen(orange, 2.6f))
        {
            pen.LineJoin = LineJoin.Round; pen.StartCap = LineCap.Round; pen.EndCap = LineCap.Round;
            float k = S / 64f, c = S / 2f, sc = 0.62f;
            PointF[] hex = new PointF[6];
            float[,] pts = { { 32, 4 }, { 56, 18 }, { 56, 46 }, { 32, 60 }, { 8, 46 }, { 8, 18 } };
            for (int i = 0; i < 6; i++) hex[i] = new PointF(c + (pts[i, 0] - 32) * k * sc * 1.25f, c + (pts[i, 1] - 32) * k * sc * 1.25f);
            g.DrawPolygon(pen, hex);
            float rad = 7 * k * 0.9f;
            g.DrawEllipse(pen, c - rad, c - rad, rad * 2, rad * 2);
            g.DrawLine(pen, c, c - 17 * k * 0.8f, c, c - rad - 2);
            g.DrawLine(pen, c, c + rad + 2, c, c + 17 * k * 0.8f);
            g.DrawLine(pen, c - 17 * k * 0.8f, c, c - rad - 2, c);
            g.DrawLine(pen, c + rad + 2, c, c + 17 * k * 0.8f, c);
        }
    }

    protected override void OnMouseDown(MouseEventArgs e)
    {
        if (e.Button == MouseButtons.Left) { down = true; dragged = false; downAt = Cursor.Position; downLoc = Location; }
    }

    protected override void OnMouseMove(MouseEventArgs e)
    {
        if (!down) return;
        Point p = Cursor.Position;
        int dx = p.X - downAt.X, dy = p.Y - downAt.Y;
        if (!dragged && Math.Abs(dx) + Math.Abs(dy) > 5) dragged = true;
        if (dragged) Location = new Point(downLoc.X + dx, downLoc.Y + dy);
    }

    protected override void OnMouseUp(MouseEventArgs e)
    {
        if (e.Button == MouseButtons.Left && down)
        {
            down = false;
            if (dragged) { if (OnMoved != null) OnMoved(Left, Top); }
            else if (OnOpen != null) OnOpen();
        }
        else if (e.Button == MouseButtons.Right)
        {
            ContextMenuStrip cm = new ContextMenuStrip();
            cm.Items.Add("Ocultar botón", null, delegate(object s2, EventArgs e2) { if (OnHide != null) OnHide(); });
            cm.Show(Cursor.Position);
        }
    }

    protected override void OnMouseEnter(EventArgs e) { Opacity = 0.95; base.OnMouseEnter(e); }
    protected override void OnMouseLeave(EventArgs e) { Opacity = 0.45; base.OnMouseLeave(e); }
}

// Tarjeta que aparece unos segundos arriba al centro: skin + nombre. Es "transparente al clic": no estorba al jugar.
public class HubTpCard : Form
{
    Image img;
    string name = "", model = "";
    Timer fade;
    DateTime shownAt;
    const int W = 210, H = 268, HOLD = 4200;

    public HubTpCard()
    {
        FormBorderStyle = FormBorderStyle.None;
        StartPosition = FormStartPosition.Manual;
        ShowInTaskbar = false;
        TopMost = true;
        Size = new Size(W, H);
        BackColor = Color.FromArgb(20, 23, 28);
        Opacity = 0;
        DoubleBuffered = true;
        GraphicsPath gp = new GraphicsPath();
        int r = 16;
        gp.AddArc(0, 0, r * 2, r * 2, 180, 90);
        gp.AddArc(W - r * 2 - 1, 0, r * 2, r * 2, 270, 90);
        gp.AddArc(W - r * 2 - 1, H - r * 2 - 1, r * 2, r * 2, 0, 90);
        gp.AddArc(0, H - r * 2 - 1, r * 2, r * 2, 90, 90);
        gp.CloseFigure();
        Region = new Region(gp);
        fade = new Timer();
        fade.Interval = 30;
        fade.Tick += OnFade;
    }

    protected override bool ShowWithoutActivation { get { return true; } }

    protected override CreateParams CreateParams
    {
        // NOACTIVATE | TOOLWINDOW | TRANSPARENT (los clics lo atraviesan)
        get { CreateParams cp = base.CreateParams; cp.ExStyle |= 0x08000000 | 0x00000080 | 0x00000020; return cp; }
    }

    public void ShowCard(Image i, string n, string m)
    {
        if (img != null) img.Dispose();
        img = i; name = n; model = m;
        Rectangle sb = Screen.PrimaryScreen.Bounds;
        Location = new Point(sb.Left + (sb.Width - W) / 2, sb.Top + (int)(sb.Height * 0.09));
        shownAt = DateTime.UtcNow;
        Invalidate();
        if (!Visible) Show();
        fade.Start();
    }

    public bool Active { get { return Visible; } }

    void OnFade(object s, EventArgs e)
    {
        double ms = (DateTime.UtcNow - shownAt).TotalMilliseconds, o;
        if (ms < 180) o = ms / 180.0 * 0.96;
        else if (ms < HOLD) o = 0.96;
        else if (ms < HOLD + 450) o = 0.96 * (1 - (ms - HOLD) / 450.0);
        else { fade.Stop(); Hide(); return; }
        Opacity = o;
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        Graphics g = e.Graphics;
        g.SmoothingMode = SmoothingMode.AntiAlias;
        g.TextRenderingHint = System.Drawing.Text.TextRenderingHint.ClearTypeGridFit;
        Color orange = Color.FromArgb(255, 255, 168, 38);
        using (Pen pen = new Pen(orange, 2.5f)) g.DrawRectangle(pen, 1, 1, W - 3, H - 3);
        Rectangle box = new Rectangle((W - 164) / 2, 16, 164, 200);
        using (SolidBrush b = new SolidBrush(Color.FromArgb(255, 10, 11, 13))) g.FillRectangle(b, box);
        if (img != null) g.DrawImage(img, box);
        else
        {
            using (Font f = new Font("Bahnschrift", 44f, FontStyle.Bold))
            using (SolidBrush b = new SolidBrush(Color.FromArgb(255, 60, 66, 76)))
            {
                string ini = name.Length > 0 ? name.Substring(0, 1).ToUpper() : "?";
                SizeF sz = g.MeasureString(ini, f);
                g.DrawString(ini, f, b, box.Left + (box.Width - sz.Width) / 2, box.Top + (box.Height - sz.Height) / 2);
            }
        }
        StringFormat sf = new StringFormat();
        sf.Alignment = StringAlignment.Center; sf.Trimming = StringTrimming.EllipsisCharacter; sf.FormatFlags = StringFormatFlags.NoWrap;
        using (Font f = new Font("Bahnschrift", 13f, FontStyle.Bold))
        using (SolidBrush b = new SolidBrush(Color.FromArgb(255, 232, 234, 238)))
            g.DrawString(name, f, b, new RectangleF(8, 222, W - 16, 22), sf);
        using (Font f = new Font("Segoe UI", 8.5f))
        using (SolidBrush b = new SolidBrush(orange))
            g.DrawString("skin: " + model, f, b, new RectangleF(8, 244, W - 16, 18), sf);
    }
}

public static class OvWin
{
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern int GetWindowThreadProcessId(IntPtr h, out int pid);
    public static string ForegroundProcessId()
    {
        int pid; GetWindowThreadProcessId(GetForegroundWindow(), out pid); return pid.ToString();
    }
}
'@

# se compila una sola vez a cache\ y despues solo se carga (arranque mas rapido)
$sha = [BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($OverlaySource))).Replace('-', '').Substring(0, 10)
$cacheDir = Join-Path $Root 'cache'
$dll = Join-Path $cacheDir "HubOverlay-$sha.dll"
$refs = @('System.Windows.Forms', 'System.Drawing')
try {
    if (-not (Test-Path $dll)) {
        New-Item -ItemType Directory -Force $cacheDir | Out-Null
        Get-ChildItem $cacheDir -Filter 'HubOverlay-*.dll' -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
        Add-Type -TypeDefinition $OverlaySource -OutputAssembly $dll -OutputType Library -ReferencedAssemblies $refs
    }
    Add-Type -Path $dll -ReferencedAssemblies $refs
}
catch { Add-Type -TypeDefinition $OverlaySource -ReferencedAssemblies $refs }

$base = "http://127.0.0.1:$Port"
$headers = @{ 'X-Hub' = $Token }
$posFile = Join-Path $Root 'overlay.json'
$screen = [Windows.Forms.Screen]::PrimaryScreen.Bounds
$x = $screen.Width - 80; $y = [int]($screen.Height * 0.4)
if (Test-Path $posFile) { try { $p = Get-Content $posFile -Raw | ConvertFrom-Json; $x = [int]$p.x; $y = [int]$p.y } catch {} }
$x = [math]::Min([math]::Max($x, 0), $screen.Width - 52); $y = [math]::Min([math]::Max($y, 0), $screen.Height - 52)

function Call-Hub($path, $body) {
    try { Invoke-RestMethod "$base/api/$path" -Headers $headers -Method Post -Body ($body | ConvertTo-Json -Compress) -TimeoutSec 3 | Out-Null } catch {}
}

$form = New-Object HubOverlay($x, $y)
$form.OnOpen = [Action]{ Call-Hub 'openhub' @{ tab = 'cmds' } }
$form.OnMoved = [Action[int, int]]{ param($a, $b) [IO.File]::WriteAllText($posFile, (@{ x = $a; y = $b } | ConvertTo-Json -Compress)) }
$form.OnHide = [Action]{ Call-Hub 'overlay' @{ enabled = $false }; $form.Close() }
$form.Add_FormClosed({ [Windows.Forms.Application]::Exit() })
$null = $form.Handle   # el manejador debe existir para registrar F9 aunque el boton este oculto

$tpCard = New-Object HubTpCard
$script:LogPos = -1

# Lee solo lo nuevo del console log y devuelve la ultima linea [HUBTP]|nombre|skin
function Read-NewCard {
    if (-not $Game) { return $null }
    $path = Join-Path $Game ("console-{0}.log" -f (Get-Date -Format 'yyyy-MM-dd'))
    if (-not (Test-Path $path)) { return $null }
    $len = (Get-Item $path).Length
    if ($script:LogPos -lt 0 -or $len -lt $script:LogPos) { $script:LogPos = $len; return $null }   # primera vez: se empieza desde "ahora"
    if ($len -eq $script:LogPos) { return $null }
    $fs = [IO.File]::Open($path, 'Open', 'Read', 'ReadWrite')
    try {
        [void]$fs.Seek($script:LogPos, 'Begin')
        $buf = New-Object byte[] ([int][math]::Min($len - $script:LogPos, 65536))
        $n = $fs.Read($buf, 0, $buf.Length)
        $script:LogPos = $len
        $text = [Text.Encoding]::UTF8.GetString($buf, 0, $n)
    }
    finally { $fs.Close() }
    $found = $null
    foreach ($m in [regex]::Matches($text, '\[HUBTP\]\|(?<n>[^\r\n]*)\|(?<m>[^|\r\n]+)')) { $found = @{ name = $m.Groups['n'].Value.Trim(); model = $m.Groups['m'].Value.Trim() } }
    return $found
}

function Show-Card($info) {
    $img = $null
    try {
        $bytes = (Invoke-WebRequest "$base/api/modelimg?t=$Token&n=$([uri]::EscapeDataString($info.model))" -UseBasicParsing -TimeoutSec 3).Content
        $img = [Drawing.Image]::FromStream((New-Object IO.MemoryStream(, $bytes)))
    }
    catch {}
    $tpCard.ShowCard($img, $info.name, $info.model)
}

$timer = New-Object Windows.Forms.Timer
$timer.Interval = 300
$timer.Add_Tick({
        try { [void][Diagnostics.Process]::GetProcessById($HubPid) } catch { $form.Close(); return }
        $name = ''
        try { $name = [Diagnostics.Process]::GetProcessById([int][OvWin]::ForegroundProcessId()).ProcessName } catch {}
        $inGame = ($name -eq 'svencoop')
        if ($Button) {
            if ($inGame -and -not $form.Visible) { $form.Show() }
            elseif (-not $inGame -and $form.Visible -and -not $form.Capture) { $form.Hide() }
            $form.SetHotkey($form.Visible)
        }
        if ($Card) {
            $c = Read-NewCard
            if ($c -and $inGame) { Show-Card $c }
        }
    })
$timer.Start()
[Windows.Forms.Application]::Run((New-Object Windows.Forms.ApplicationContext))
