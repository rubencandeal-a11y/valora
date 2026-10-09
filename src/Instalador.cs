// Asistente de instalación de Valora: instala Antigravity CLI (agy) con winget,
// copia la ventana Valora.ps1 y su icono (incrustados en este .exe) y crea los accesos directos.
using System;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Net;
using System.Reflection;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Windows.Forms;

[assembly: AssemblyTitle("Instalador de Valora")]
[assembly: AssemblyProduct("Valora")]
[assembly: AssemblyVersion("1.0.0.0")]

namespace ValoraInstalador
{
    public class Asistente : Form
    {
        private int paso = 0;
        private readonly Label titulo = new Label();
        private readonly Label subtitulo = new Label();
        private readonly Panel contenido = new Panel();
        private readonly Button btnAtras = new Button();
        private readonly Button btnSiguiente = new Button();
        private readonly Button btnCancelar = new Button();

        private readonly TextBox txtCarpeta = new TextBox();
        private readonly CheckBox chkEscritorio = new CheckBox();
        private readonly CheckBox chkEscritorioTerm = new CheckBox();
        private readonly CheckBox chkAbrir = new CheckBox();
        private readonly CheckBox chkLogin = new CheckBox();
        private readonly CheckBox chkNode = new CheckBox();
        private bool instalarNode = true;
        private string lnkVentana;
        private string lnkTerminal;
        private readonly ProgressBar barra = new ProgressBar();
        private readonly TextBox log = new TextBox();
        private readonly Label lblFin = new Label();

        public static bool Auto = false; // /auto: instala sin preguntar y abre todo al terminar
        private bool instalando = false;
        private bool instaladoOk = false;
        private string rutaVentana;
        private string rutaIcono;

        public Asistente()
        {
            Text = "Instalar Valora";
            ClientSize = new Size(620, 430);
            FormBorderStyle = FormBorderStyle.FixedDialog;
            MaximizeBox = false;
            StartPosition = FormStartPosition.CenterScreen;
            Font = new Font("Segoe UI", 9.5f);
            Icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath);

            Panel cabecera = new Panel();
            cabecera.Dock = DockStyle.Top;
            cabecera.Height = 70;
            cabecera.BackColor = Color.White;
            titulo.Font = new Font("Segoe UI", 13f, FontStyle.Bold);
            titulo.Location = new Point(20, 10);
            titulo.AutoSize = true;
            subtitulo.Location = new Point(22, 40);
            subtitulo.AutoSize = true;
            subtitulo.ForeColor = Color.DimGray;
            cabecera.Controls.Add(titulo);
            cabecera.Controls.Add(subtitulo);

            Label linea1 = new Label();
            linea1.Dock = DockStyle.Top;
            linea1.Height = 1;
            linea1.BackColor = Color.LightGray;

            Panel pie = new Panel();
            pie.Dock = DockStyle.Bottom;
            pie.Height = 52;
            btnAtras.Text = "< Atrás";
            btnAtras.Size = new Size(95, 30);
            btnAtras.Location = new Point(300, 11);
            btnSiguiente.Text = "Siguiente >";
            btnSiguiente.Size = new Size(95, 30);
            btnSiguiente.Location = new Point(400, 11);
            btnCancelar.Text = "Cancelar";
            btnCancelar.Size = new Size(95, 30);
            btnCancelar.Location = new Point(510, 11);
            pie.Controls.Add(btnAtras);
            pie.Controls.Add(btnSiguiente);
            pie.Controls.Add(btnCancelar);

            Label linea2 = new Label();
            linea2.Dock = DockStyle.Bottom;
            linea2.Height = 1;
            linea2.BackColor = Color.LightGray;

            contenido.Dock = DockStyle.Fill;
            contenido.Padding = new Padding(24, 16, 24, 8);

            Controls.Add(contenido);
            Controls.Add(linea2);
            Controls.Add(pie);
            Controls.Add(linea1);
            Controls.Add(cabecera);

            txtCarpeta.Text = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments), "Tasaciones");
            chkEscritorio.Text = "Crear acceso directo \"Valora\" en el escritorio";
            chkEscritorio.Checked = true;
            chkEscritorioTerm.Text = "Crear acceso directo \"Valora (terminal)\" en el escritorio";
            chkEscritorioTerm.Checked = true;
            chkAbrir.Text = "Abrir Valora al terminar la instalación";
            chkAbrir.Checked = true;
            chkLogin.Text = "Abrir también la terminal de agy (opcional, para usuarios avanzados)";
            chkLogin.Checked = false;
            chkNode.Text = "Instalar también Node.js LTS (agy no lo necesita; útil para proyectos)";
            chkNode.Checked = true;
            AcceptButton = btnSiguiente;

            btnAtras.Click += delegate { if (paso > 0) { paso--; Mostrar(); } };
            btnSiguiente.Click += delegate { Avanzar(); };
            btnCancelar.Click += delegate { Close(); };
            FormClosing += delegate(object s, FormClosingEventArgs e)
            {
                if (instalando)
                {
                    MessageBox.Show(this, "Espera a que termine la instalación.", "Instalar Valora");
                    e.Cancel = true;
                }
            };

            Mostrar();
            if (Auto) Shown += delegate { paso = 1; Avanzar(); };
        }

        private Label Texto(string t, int y, int alto)
        {
            Label l = new Label();
            l.Text = t;
            l.Location = new Point(24, y);
            l.Size = new Size(570, alto);
            return l;
        }

        private void Mostrar()
        {
            contenido.Controls.Clear();
            btnAtras.Enabled = paso == 1;
            btnCancelar.Enabled = paso < 2;
            btnSiguiente.Enabled = true;

            if (paso == 0)
            {
                titulo.Text = "Bienvenido al instalador de Valora";
                subtitulo.Text = "Asistente con IA para trabajar con fotos, documentos y carpetas.";
                contenido.Controls.Add(Texto(
                    "Este asistente instala en el equipo:\r\n\r\n" +
                    "  •  Valora, una ventana tipo chat para adjuntar fotos y carpetas y ver las respuestas.\r\n" +
                    "  •  Antigravity CLI (comando agy), el asistente de Google que trabaja por debajo.\r\n" +
                    "  •  Un botón para abrir la terminal de agy cuando haga falta.\r\n\r\n" +
                    "Necesita conexión a Internet y una cuenta de Google.\r\n" +
                    "Windows pedirá permiso de administrador: acéptalo para que se instale todo.\r\n\r\n" +
                    "Pulsa Siguiente para continuar.", 20, 260));
                btnSiguiente.Text = "Siguiente >";
            }
            else if (paso == 1)
            {
                titulo.Text = "Carpeta de trabajo";
                subtitulo.Text = "Dónde guardará Valora los archivos adjuntos y los resultados.";
                contenido.Controls.Add(Texto("Carpeta:", 24, 22));
                txtCarpeta.Location = new Point(24, 50);
                txtCarpeta.Width = 460;
                Button examinar = new Button();
                examinar.Text = "Examinar...";
                examinar.Location = new Point(494, 48);
                examinar.Size = new Size(95, 28);
                examinar.Click += delegate
                {
                    FolderBrowserDialog dlg = new FolderBrowserDialog();
                    dlg.Description = "Elige la carpeta de trabajo";
                    dlg.SelectedPath = txtCarpeta.Text;
                    if (dlg.ShowDialog(this) == DialogResult.OK) txtCarpeta.Text = dlg.SelectedPath;
                };
                chkEscritorio.Location = new Point(24, 100);
                chkEscritorio.AutoSize = true;
                contenido.Controls.Add(txtCarpeta);
                contenido.Controls.Add(examinar);
                chkEscritorioTerm.Location = new Point(24, 128);
                chkEscritorioTerm.AutoSize = true;
                chkNode.Location = new Point(24, 156);
                chkNode.AutoSize = true;
                chkAbrir.Location = new Point(24, 184);
                chkAbrir.AutoSize = true;
                chkLogin.Location = new Point(24, 212);
                chkLogin.AutoSize = true;
                contenido.Controls.Add(chkEscritorio);
                contenido.Controls.Add(chkEscritorioTerm);
                contenido.Controls.Add(chkNode);
                contenido.Controls.Add(chkAbrir);
                contenido.Controls.Add(chkLogin);
                contenido.Controls.Add(Texto("La carpeta se puede cambiar más tarde desde la propia ventana de Valora.", 248, 40));
                btnSiguiente.Text = "Instalar";
            }
            else if (paso == 2)
            {
                titulo.Text = "Instalando";
                subtitulo.Text = "Espera mientras se instala Valora. Puede tardar unos minutos.";
                barra.Location = new Point(24, 20);
                barra.Size = new Size(570, 22);
                barra.Style = ProgressBarStyle.Marquee;
                log.Location = new Point(24, 54);
                log.Size = new Size(570, 220);
                log.Multiline = true;
                log.ReadOnly = true;
                log.ScrollBars = ScrollBars.Vertical;
                log.BackColor = Color.White;
                log.Font = new Font("Consolas", 9f);
                contenido.Controls.Add(barra);
                contenido.Controls.Add(log);
                btnSiguiente.Text = "Siguiente >";
                btnSiguiente.Enabled = false;
                btnAtras.Enabled = false;
                Instalar();
            }
            else
            {
                titulo.Text = instaladoOk ? "Instalación completada" : "La instalación no ha terminado";
                subtitulo.Text = instaladoOk ? "Valora está listo para usarse." : "Revisa el mensaje de abajo.";
                if (instaladoOk)
                {
                    lblFin.Text =
                        "La primera vez, Valora te pedirá conectar tu cuenta de Google:\r\n\r\n" +
                        "  1.  Pulsa \"Iniciar sesión con Google\" en la ventana de Valora.\r\n" +
                        "  2.  Elige tu cuenta en el navegador y acepta.\r\n" +
                        "  3.  Si Google te enseña un código, pégalo en Valora y pulsa Continuar.\r\n\r\n" +
                        "Accesos: \"Valora\" y \"Valora (terminal)\" en el escritorio y en el menú Inicio.";
                    lblFin.Location = new Point(24, 16);
                    lblFin.Size = new Size(570, 140);
                    contenido.Controls.Add(lblFin);
                }
                else
                {
                    log.Location = new Point(24, 20);
                    log.Size = new Size(570, 250);
                    contenido.Controls.Add(log);
                }
                btnSiguiente.Text = "Finalizar";
                btnAtras.Enabled = false;
                btnCancelar.Enabled = false;
            }
        }

        private void Avanzar()
        {
            if (paso == 1)
            {
                if (txtCarpeta.Text.Trim().Length == 0)
                {
                    MessageBox.Show(this, "Elige una carpeta de trabajo.", "Instalar Valora");
                    return;
                }
            }
            if (paso == 3)
            {
                Close();
                return;
            }
            paso++;
            Mostrar();
        }

        private void Log(string linea)
        {
            if (InvokeRequired) { BeginInvoke(new Action<string>(Log), linea); return; }
            log.AppendText(linea + "\r\n");
        }

        private void Instalar()
        {
            instalando = true;
            string carpeta = txtCarpeta.Text.Trim();
            bool escritorio = chkEscritorio.Checked;
            bool escritorioTerm = chkEscritorioTerm.Checked;
            bool abrir = chkAbrir.Checked;
            bool login = chkLogin.Checked;
            instalarNode = chkNode.Checked;
            Thread t = new Thread(delegate()
            {
                bool ok = false;
                try { ok = PasosInstalacion(carpeta, escritorio, escritorioTerm); }
                catch (Exception ex) { Log("[ERROR] " + ex.Message); }
                BeginInvoke(new Action(delegate
                {
                    instalando = false;
                    instaladoOk = ok;
                    barra.Style = ProgressBarStyle.Continuous;
                    barra.Value = ok ? 100 : 0;
                    btnSiguiente.Enabled = true;
                    btnSiguiente.Focus();
                    if (ok)
                    {
                        if (login) AbrirSinElevar(lnkTerminal);
                        if (abrir) AbrirSinElevar(lnkVentana);
                        Log(abrir ? "Instalación terminada. Valora se está abriendo." : "Instalación terminada. Pulsa Siguiente.");
                    }
                    if (ok && Auto) { Avanzar(); Avanzar(); }
                }));
            });
            t.IsBackground = true;
            t.Start();
        }

        private bool PasosInstalacion(string carpeta, bool escritorio, bool escritorioTerm)
        {
            // 1. agy
            Log("Buscando agy...");
            string agy = BuscarAgy();
            if (agy != null)
            {
                Log("[OK] agy ya está instalado: " + agy);
            }
            else
            {
                Log("Instalando Antigravity CLI con winget (descarga ~200 MB)...");
                int codigo = Ejecutar("winget", "install --id Google.AntigravityCLI -e --accept-source-agreements --accept-package-agreements --disable-interactivity");
                if (codigo == -9999) Log("[AVISO] Este equipo no tiene winget.");
                agy = BuscarAgy();
                if (agy == null)
                {
                    // Plan B: descarga directa del ejecutable portable de Google.
                    Log("Descargando agy directamente de Google...");
                    string bin = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), @"Valora\bin");
                    Directory.CreateDirectory(bin);
                    string exe = Path.Combine(bin, "agy.exe");
                    Descargar(UrlAgy, exe);
                    AnadirAlPath(bin);
                    agy = exe;
                }
                Log("[OK] agy instalado: " + agy);
            }

            // 1b. Node.js (opcional; agy no lo necesita, pero sí muchos proyectos)
            if (instalarNode)
            {
                if (BuscarEnPath("node.exe") != null || File.Exists(@"C:\Program Files\nodejs\node.exe"))
                {
                    Log("[OK] Node.js ya está instalado.");
                }
                else
                {
                    Log("Instalando Node.js LTS con winget...");
                    int codigo = Ejecutar("winget", "install --id OpenJS.NodeJS.LTS -e --accept-source-agreements --accept-package-agreements --disable-interactivity");
                    if (codigo != 0 && !File.Exists(@"C:\Program Files\nodejs\node.exe"))
                    {
                        Log("winget no pudo; descargando Node.js de nodejs.org...");
                        string msi = Path.Combine(Path.GetTempPath(), "node-lts-x64.msi");
                        Descargar(UrlNodeLts(), msi);
                        codigo = Ejecutar("msiexec", "/i \"" + msi + "\" /passive /norestart");
                    }
                    if (File.Exists(@"C:\Program Files\nodejs\node.exe")) Log("[OK] Node.js instalado.");
                    else Log("[AVISO] Node.js no se instaló (código " + codigo + "). agy funciona igual.");
                }
            }

            // 2. Ventana
            string destino = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Valora");
            Directory.CreateDirectory(destino);
            rutaVentana = Path.Combine(destino, "Valora.ps1");
            Extraer("Valora.ps1", rutaVentana);
            rutaIcono = Path.Combine(destino, "valora.ico");
            Extraer("valora.ico", rutaIcono);
            Log("[OK] Ventana copiada a " + destino);

            // 3. Carpeta de trabajo y configuración
            Directory.CreateDirectory(carpeta);
            string json = "{ \"workspace\": \"" + carpeta.Replace("\\", "\\\\").Replace("\"", "\\\"") + "\", \"auto\": true }";
            File.WriteAllText(Path.Combine(destino, "config.json"), json, new UTF8Encoding(false));
            Log("[OK] Carpeta de trabajo: " + carpeta);

            // 4. Accesos directos
            string escritorioDir = Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory);
            string menuDir = Environment.GetFolderPath(Environment.SpecialFolder.Programs);
            string argsTerminal = "-NoExit -NoProfile -Command \"& '" + agy.Replace("'", "''") + "'\"";
            // Accesos de versiones anteriores, cuando se llamaba Agy.
            foreach (string viejo in new string[] { Path.Combine(menuDir, "Agy.lnk"), Path.Combine(menuDir, "Agy (terminal).lnk"), Path.Combine(escritorioDir, "Agy.lnk"), Path.Combine(escritorioDir, "Agy (terminal).lnk") })
            {
                try { if (File.Exists(viejo)) File.Delete(viejo); } catch (IOException) { }
            }
            lnkVentana = Path.Combine(menuDir, "Valora.lnk");
            lnkTerminal = Path.Combine(menuDir, "Valora (terminal).lnk");
            CrearAcceso(lnkVentana, ArgumentosVentana(), carpeta, agy, "Valora: asistente de tasaciones con agy");
            CrearAcceso(lnkTerminal, argsTerminal, carpeta, agy, "agy en la terminal");
            Log("[OK] Accesos en el menú Inicio");
            if (escritorio)
            {
                CrearAcceso(Path.Combine(escritorioDir, "Valora.lnk"), ArgumentosVentana(), carpeta, agy, "Valora: asistente de tasaciones con agy");
                Log("[OK] Acceso directo \"Valora\" en el escritorio");
            }
            if (escritorioTerm)
            {
                CrearAcceso(Path.Combine(escritorioDir, "Valora (terminal).lnk"), argsTerminal, carpeta, agy, "agy en la terminal");
                Log("[OK] Acceso directo \"Valora (terminal)\" en el escritorio");
            }
            return true;
        }

        private static string RutaPowerShell()
        {
            return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), @"WindowsPowerShell\v1.0\powershell.exe");
        }

        private string ArgumentosVentana()
        {
            return "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"" + rutaVentana + "\"";
        }

        private void CrearAcceso(string ruta, string argumentos, string carpeta, string agy, string descripcion)
        {
            Type tipo = Type.GetTypeFromProgID("WScript.Shell");
            object shell = Activator.CreateInstance(tipo);
            object lnk = tipo.InvokeMember("CreateShortcut", BindingFlags.InvokeMethod, null, shell, new object[] { ruta });
            Type t = lnk.GetType();
            t.InvokeMember("TargetPath", BindingFlags.SetProperty, null, lnk, new object[] { RutaPowerShell() });
            t.InvokeMember("Arguments", BindingFlags.SetProperty, null, lnk, new object[] { argumentos });
            t.InvokeMember("WorkingDirectory", BindingFlags.SetProperty, null, lnk, new object[] { carpeta });
            t.InvokeMember("IconLocation", BindingFlags.SetProperty, null, lnk, new object[] { rutaIcono + ",0" });
            t.InvokeMember("Description", BindingFlags.SetProperty, null, lnk, new object[] { descripcion });
            t.InvokeMember("Save", BindingFlags.InvokeMethod, null, lnk, null);
        }

        // El instalador corre como administrador; abrir a través de explorer.exe
        // lanza el acceso directo como usuario normal (si no, no se podrían arrastrar
        // archivos desde el Explorador a la ventana).
        private static void AbrirSinElevar(string lnk)
        {
            if (lnk != null && File.Exists(lnk)) Process.Start("explorer.exe", "\"" + lnk + "\"");
        }

        private const string UrlAgy = "https://storage.googleapis.com/antigravity-public/antigravity-cli/1.3.1-4582356770750464/windows-x64/cli_windows_x64.exe";

        private void Descargar(string url, string destino)
        {
            ServicePointManager.SecurityProtocol = (SecurityProtocolType)3072; // TLS 1.2
            using (WebClient wc = new WebClient())
            {
                int ultimo = -1;
                wc.DownloadProgressChanged += delegate(object s, DownloadProgressChangedEventArgs e)
                {
                    if (e.ProgressPercentage / 10 != ultimo) { ultimo = e.ProgressPercentage / 10; Log("  " + e.ProgressPercentage + " %"); }
                };
                Exception error = null;
                ManualResetEvent fin = new ManualResetEvent(false);
                wc.DownloadFileCompleted += delegate(object s, System.ComponentModel.AsyncCompletedEventArgs e) { error = e.Error; fin.Set(); };
                wc.DownloadFileAsync(new Uri(url), destino);
                fin.WaitOne();
                if (error != null) throw new Exception("No se pudo descargar " + url + ": " + error.Message);
            }
        }

        // Busca la última versión LTS de Node en el índice oficial.
        private static string UrlNodeLts()
        {
            ServicePointManager.SecurityProtocol = (SecurityProtocolType)3072;
            string indice;
            using (WebClient wc = new WebClient()) indice = wc.DownloadString("https://nodejs.org/dist/index.json");
            Match m = Regex.Match(indice, "\"version\":\"(v[0-9.]+)\"[^}]*?\"lts\":\"[A-Za-z]");
            if (!m.Success) throw new Exception("No encuentro la versión LTS de Node.");
            string v = m.Groups[1].Value;
            return "https://nodejs.org/dist/" + v + "/node-" + v + "-x64.msi";
        }

        private static void AnadirAlPath(string dir)
        {
            string actual = Environment.GetEnvironmentVariable("PATH", EnvironmentVariableTarget.User) ?? "";
            if (actual.IndexOf(dir, StringComparison.OrdinalIgnoreCase) < 0)
                Environment.SetEnvironmentVariable("PATH", actual.TrimEnd(';') + ";" + dir, EnvironmentVariableTarget.User);
        }

        private static string BuscarEnPath(string nombre)
        {
            string path = (Environment.GetEnvironmentVariable("PATH", EnvironmentVariableTarget.Machine) ?? "") + ";" +
                          (Environment.GetEnvironmentVariable("PATH", EnvironmentVariableTarget.User) ?? "");
            foreach (string dir in path.Split(';'))
            {
                try
                {
                    string d = Environment.ExpandEnvironmentVariables(dir.Trim());
                    if (d.Length > 0 && File.Exists(Path.Combine(d, nombre))) return Path.Combine(d, nombre);
                }
                catch (ArgumentException) { }
            }
            return null;
        }

        private static string BuscarAgy()
        {
            string propio = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), @"Valora\bin\agy.exe");
            if (File.Exists(propio)) return propio;
            string enPath = BuscarEnPath("agy.exe");
            if (enPath != null) return enPath;
            string local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
            string pf = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles);
            foreach (string links in new string[] { Path.Combine(local, @"Microsoft\WinGet\Links"), Path.Combine(pf, @"WinGet\Links") })
            {
                if (File.Exists(Path.Combine(links, "agy.exe"))) return Path.Combine(links, "agy.exe");
            }
            foreach (string paq in new string[] { Path.Combine(local, @"Microsoft\WinGet\Packages"), Path.Combine(pf, @"WinGet\Packages") })
            {
                if (!Directory.Exists(paq)) continue;
                foreach (string d in Directory.GetDirectories(paq, "Google.AntigravityCLI*"))
                {
                    if (File.Exists(Path.Combine(d, "agy.exe"))) return Path.Combine(d, "agy.exe");
                }
            }
            return null;
        }

        // Ejecuta un programa y vuelca su salida al registro. Devuelve -9999 si no existe.
        private int Ejecutar(string programa, string argumentos)
        {
            ProcessStartInfo psi = new ProcessStartInfo(programa, argumentos);
            psi.UseShellExecute = false;
            psi.CreateNoWindow = true;
            psi.RedirectStandardOutput = true;
            psi.RedirectStandardError = true;
            psi.StandardOutputEncoding = Encoding.UTF8;
            psi.StandardErrorEncoding = Encoding.UTF8;
            Process p;
            try { p = Process.Start(psi); }
            catch (System.ComponentModel.Win32Exception) { return -9999; }
            p.OutputDataReceived += delegate(object s, DataReceivedEventArgs e) { Filtrar(e.Data); };
            p.ErrorDataReceived += delegate(object s, DataReceivedEventArgs e) { Filtrar(e.Data); };
            p.BeginOutputReadLine();
            p.BeginErrorReadLine();
            p.WaitForExit();
            return p.ExitCode;
        }

        // winget pinta barras de progreso con retornos de carro; se queda con el texto útil.
        private void Filtrar(string linea)
        {
            if (linea == null) return;
            string[] trozos = linea.Split('\r');
            string ultimo = trozos[trozos.Length - 1].Trim();
            if (ultimo.Length == 0) return;
            if (ultimo.IndexOf('█') >= 0 || ultimo.IndexOf('▒') >= 0) return;
            if (ultimo == "-" || ultimo == "\\" || ultimo == "|" || ultimo == "/") return;
            Log(ultimo);
        }

        [STAThread]
        public static void Main(string[] args)
        {
            foreach (string a in args) if (a.Equals("/auto", StringComparison.OrdinalIgnoreCase)) Auto = true;
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            Application.Run(new Asistente());
        }

        private static void Extraer(string recurso, string destino)
        {
            using (Stream s = Assembly.GetExecutingAssembly().GetManifestResourceStream(recurso))
            using (FileStream f = File.Create(destino))
            {
                s.CopyTo(f);
            }
        }
    }
}
