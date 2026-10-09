# Valora: ventana tipo chat para hablar con Antigravity CLI (agy).
# Permite adjuntar fotos, archivos y carpetas, enviar preguntas y ver las respuestas,
# y abrir la terminal de agy en la misma carpeta de trabajo y conversación.

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms

# Repositorio de GitHub desde el que Valora se actualiza sola (usuario/repositorio).
$RepoValora = 'rubencandeal-a11y/valora'
$RutaValora = $MyInvocation.MyCommand.Path   # ruta de este script, para reemplazarlo al actualizar

$ConfigDir  = Join-Path $env:LOCALAPPDATA 'Valora'
$ConfigFile = Join-Path $ConfigDir 'config.json'
New-Item -ItemType Directory -Force $ConfigDir | Out-Null

function Find-Agy {
    $propio = Join-Path $env:LOCALAPPDATA 'Valora\bin\agy.exe'
    if (Test-Path $propio) { return $propio }
    $cmd = Get-Command agy -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $raices = @(
        (Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet'),
        (Join-Path $env:ProgramFiles 'WinGet')
    )
    foreach ($r in $raices) {
        $link = Join-Path $r 'Links\agy.exe'
        if (Test-Path $link) { return $link }
        $paq = Join-Path $r 'Packages'
        if (Test-Path $paq) {
            $exe = Get-ChildItem $paq -Directory -Filter 'Google.AntigravityCLI*' -ErrorAction SilentlyContinue |
                ForEach-Object { Join-Path $_.FullName 'agy.exe' } | Where-Object { Test-Path $_ } | Select-Object -First 1
            if ($exe) { return $exe }
        }
    }
    return $null
}

# Comillas al estilo de la línea de comandos de Windows.
function Quote-Arg([string]$s) {
    $s = $s -replace '(\\*)"', '$1$1\"'
    $s = $s -replace '(\\+)$', '$1$1'
    return '"' + $s + '"'
}

function Load-Config {
    $cfg = @{ workspace = (Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'Tasaciones'); auto = $true; carpetas = @() }
    if (Test-Path $ConfigFile) {
        try {
            $j = Get-Content $ConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($j.workspace) { $cfg.workspace = $j.workspace }
            if ($null -ne $j.auto) { $cfg.auto = [bool]$j.auto }
            if ($j.carpetas) { $cfg.carpetas = @($j.carpetas) }
        } catch {}
    }
    return $cfg
}

function Save-Config {
    @{ workspace = $script:workspace; auto = [bool]$ui.ChkAuto.IsChecked; carpetas = @($script:carpetas) } |
        ConvertTo-Json | Set-Content $ConfigFile -Encoding UTF8
}

$script:Agy = Find-Agy
$cfg = Load-Config
$script:workspace = $cfg.workspace
New-Item -ItemType Directory -Force $script:workspace | Out-Null
$script:carpetas = New-Object System.Collections.ArrayList
foreach ($c in $cfg.carpetas) { if (Test-Path $c) { [void]$script:carpetas.Add($c) } }
$script:archivos = New-Object System.Collections.ArrayList

$script:proc = $null
$script:outTask = $null
$script:errTask = $null
$script:conv = $null          # conversación abierta (se guarda en %LOCALAPPDATA%\Valora\conversaciones)
$script:avisoLogin = $false
$script:resultado = $null
$ConvDir = Join-Path $ConfigDir 'conversaciones'
New-Item -ItemType Directory -Force $ConvDir | Out-Null
$script:respuesta = $null
$script:pensando = $true

[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Valora" Width="1180" Height="780" MinWidth="820" MinHeight="520"
        WindowStartupLocation="CenterScreen" Background="#212121" AllowDrop="True"
        FontFamily="Segoe UI" FontSize="14" Foreground="#ECECEC">
  <Window.Resources>
    <SolidColorBrush x:Key="Sidebar" Color="#171717"/>

    <Style x:Key="Plano" TargetType="Button">
      <Setter Property="Foreground" Value="#ECECEC"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Padding" Value="10,7"/>
      <Setter Property="HorizontalContentAlignment" Value="Left"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="b" Background="{TemplateBinding Background}" CornerRadius="8" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="{TemplateBinding HorizontalContentAlignment}" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Background" Value="#2A2A2A"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.4"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="Chip" TargetType="Button" BasedOn="{StaticResource Plano}">
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="b" Background="Transparent" BorderBrush="#3A3A3A" BorderThickness="1" CornerRadius="12" Padding="14,10">
              <ContentPresenter HorizontalAlignment="Left" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Background" Value="#2A2A2A"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="Redondo" TargetType="Button">
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Width" Value="36"/>
      <Setter Property="Height" Value="36"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="b" Background="{TemplateBinding Background}" CornerRadius="18">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Opacity" Value="0.85"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter TargetName="b" Property="Opacity" Value="0.3"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="Seccion" TargetType="TextBlock">
      <Setter Property="Foreground" Value="#8E8E8E"/>
      <Setter Property="FontSize" Value="11.5"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Margin" Value="12,18,12,6"/>
    </Style>
  </Window.Resources>

  <Grid>
    <Grid.ColumnDefinitions>
      <ColumnDefinition Width="270"/>
      <ColumnDefinition Width="*"/>
    </Grid.ColumnDefinitions>

    <!-- Barra lateral -->
    <Border Background="{StaticResource Sidebar}">
      <DockPanel Margin="10,14,10,12">
        <StackPanel DockPanel.Dock="Top">
          <StackPanel Orientation="Horizontal" Margin="10,0,0,14">
            <Border Width="30" Height="30" CornerRadius="8" Background="#ECECEC">
              <TextBlock Text="V" Foreground="#171717" FontWeight="Bold" FontSize="17" HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <TextBlock Text="Valora" FontSize="18" FontWeight="SemiBold" Margin="10,0,0,0" VerticalAlignment="Center"/>
          </StackPanel>
          <Button x:Name="BtnNueva" Style="{StaticResource Plano}">
            <StackPanel Orientation="Horizontal">
              <TextBlock FontFamily="Segoe MDL2 Assets" Text="&#xE70F;" VerticalAlignment="Center" Margin="0,0,10,0"/>
              <TextBlock Text="Nueva conversación"/>
            </StackPanel>
          </Button>

          <TextBlock Text="CARPETA DE TRABAJO" Style="{StaticResource Seccion}"/>
          <Border Background="#202020" CornerRadius="8" Padding="10,8" Margin="2,0">
            <StackPanel>
              <TextBlock x:Name="TxtWs" TextTrimming="CharacterEllipsis" Foreground="#CFCFCF" FontSize="13"/>
              <StackPanel Orientation="Horizontal" Margin="0,8,0,0">
                <Button x:Name="BtnWs" Style="{StaticResource Plano}" Padding="8,4" FontSize="12.5" Foreground="#B4B4B4" Content="Cambiar"/>
                <Button x:Name="BtnAbrirWs" Style="{StaticResource Plano}" Padding="8,4" FontSize="12.5" Foreground="#B4B4B4" Content="Abrir en Explorador"/>
              </StackPanel>
            </StackPanel>
          </Border>

          <TextBlock Text="CARPETAS CONECTADAS" Style="{StaticResource Seccion}"/>
          <ItemsControl x:Name="ListaCarpetas"/>
          <Button x:Name="BtnCarpeta" Style="{StaticResource Plano}" Foreground="#B4B4B4">
            <StackPanel Orientation="Horizontal">
              <TextBlock FontFamily="Segoe MDL2 Assets" Text="&#xE710;" VerticalAlignment="Center" Margin="0,0,10,0" FontSize="12"/>
              <TextBlock Text="Conectar carpeta"/>
            </StackPanel>
          </Button>
        </StackPanel>

        <StackPanel DockPanel.Dock="Bottom">
          <CheckBox x:Name="ChkAuto" Foreground="#B4B4B4" Margin="12,0,0,10" FontSize="13"
                    Content="Modo automático (no pide permisos)"
                    ToolTip="agy lee, crea archivos y ejecuta comandos sin preguntar"/>
          <Button x:Name="BtnTerminal" Style="{StaticResource Plano}">
            <StackPanel Orientation="Horizontal">
              <TextBlock FontFamily="Segoe MDL2 Assets" Text="&#xE756;" VerticalAlignment="Center" Margin="0,0,10,0"/>
              <TextBlock Text="Abrir terminal (agy)"/>
            </StackPanel>
          </Button>
          <Border Background="#202020" CornerRadius="8" Padding="12,8" Margin="2,8,2,0">
            <Grid>
              <StackPanel Margin="0,0,70,0">
                <TextBlock Text="Cuenta de Google" Foreground="#8E8E8E" FontSize="11.5"/>
                <TextBlock x:Name="TxtCuenta" Text="—" Foreground="#CFCFCF" FontSize="12.5" TextTrimming="CharacterEllipsis"/>
              </StackPanel>
              <Button x:Name="BtnLogout" Style="{StaticResource Plano}" Padding="8,4" FontSize="12" Foreground="#B4B4B4"
                      HorizontalAlignment="Right" VerticalAlignment="Center" Content="Cerrar sesión"/>
            </Grid>
          </Border>
          <TextBlock x:Name="TxtEstado" Foreground="#8E8E8E" FontSize="12" TextWrapping="Wrap" Margin="12,10,8,0"/>
        </StackPanel>
        <DockPanel Margin="0,4,0,8">
          <TextBlock DockPanel.Dock="Top" Text="CONVERSACIONES" Style="{StaticResource Seccion}"/>
          <ScrollViewer VerticalScrollBarVisibility="Auto">
            <StackPanel x:Name="ListaConv"/>
          </ScrollViewer>
        </DockPanel>
      </DockPanel>
    </Border>

    <!-- Zona principal -->
    <Grid Grid.Column="1">
      <Grid.RowDefinitions>
        <RowDefinition Height="*"/>
        <RowDefinition Height="Auto"/>
      </Grid.RowDefinitions>

      <Border x:Name="AvisoVersion" VerticalAlignment="Top" HorizontalAlignment="Center" Margin="0,14,0,0" Panel.ZIndex="5"
              Background="#2E7D5A" CornerRadius="18" Padding="16,6,6,6" Visibility="Collapsed">
        <StackPanel Orientation="Horizontal">
          <TextBlock Text="Hay una versión nueva de Valora." Foreground="White" VerticalAlignment="Center" Margin="0,0,12,0"/>
          <Button x:Name="BtnReiniciar" Style="{StaticResource Plano}" Background="#FFFFFF" Foreground="#174F38" Padding="12,5"
                  FontWeight="SemiBold" Content="Reiniciar ahora"/>
        </StackPanel>
      </Border>

      <ScrollViewer x:Name="Scroll" VerticalScrollBarVisibility="Auto">
        <StackPanel x:Name="Chat" MaxWidth="820" Margin="32,28,32,12"/>
      </ScrollViewer>

      <!-- Pantalla de inicio -->
      <StackPanel x:Name="Inicio" VerticalAlignment="Center" HorizontalAlignment="Center" MaxWidth="680">
        <TextBlock Text="¿En qué trabajamos?" FontSize="28" FontWeight="SemiBold" HorizontalAlignment="Center" Margin="0,0,0,8"/>
        <TextBlock Text="Arrastra fotos, documentos o carpetas a la ventana y pregunta." Foreground="#8E8E8E" HorizontalAlignment="Center" Margin="0,0,0,26"/>
        <UniformGrid x:Name="Sugerencias" Columns="2">
          <Button Style="{StaticResource Chip}" Margin="5" Tag="Mira las fotos adjuntas y haz un informe de tasación del inmueble: estado, superficie aproximada, calidades, desperfectos y una estimación de valor razonada.">
            <StackPanel><TextBlock Text="Tasar un inmueble" FontWeight="SemiBold"/><TextBlock Text="a partir de las fotos adjuntas" Foreground="#8E8E8E" FontSize="12.5"/></StackPanel>
          </Button>
          <Button Style="{StaticResource Chip}" Margin="5" Tag="Revisa la carpeta conectada y dime qué hay: tipos de archivo, de qué trata cada uno y qué falta.">
            <StackPanel><TextBlock Text="Revisar una carpeta" FontWeight="SemiBold"/><TextBlock Text="qué hay y qué falta" Foreground="#8E8E8E" FontSize="12.5"/></StackPanel>
          </Button>
          <Button Style="{StaticResource Chip}" Margin="5" Tag="Con lo que hemos visto, crea un informe en formato Word (.docx) en la carpeta de trabajo, con fotos y conclusiones.">
            <StackPanel><TextBlock Text="Crear un informe Word" FontWeight="SemiBold"/><TextBlock Text="en la carpeta de trabajo" Foreground="#8E8E8E" FontSize="12.5"/></StackPanel>
          </Button>
          <Button Style="{StaticResource Chip}" Margin="5" Tag="Compara las fotos adjuntas y dime las diferencias de estado entre ellas.">
            <StackPanel><TextBlock Text="Comparar fotos" FontWeight="SemiBold"/><TextBlock Text="diferencias de estado" Foreground="#8E8E8E" FontSize="12.5"/></StackPanel>
          </Button>
        </UniformGrid>
      </StackPanel>

      <!-- Caja de mensaje -->
      <Grid Grid.Row="1" MaxWidth="820" Margin="32,4,32,10">
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        <Border CornerRadius="22" Background="#2F2F2F" Padding="10,8,10,8">
          <Grid>
            <Grid.RowDefinitions>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="Auto"/>
            </Grid.RowDefinitions>
            <WrapPanel x:Name="Adjuntos" Margin="4,6,4,4"/>
            <Grid Grid.Row="1">
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="Auto"/>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="Auto"/>
              </Grid.ColumnDefinitions>
              <Button x:Name="BtnAdjuntar" Style="{StaticResource Redondo}" Background="Transparent" VerticalAlignment="Bottom" ToolTip="Adjuntar archivos">
                <TextBlock FontFamily="Segoe MDL2 Assets" Text="&#xE723;" FontSize="16" Foreground="#CFCFCF"/>
              </Button>
              <Grid Grid.Column="1" Margin="6,0">
                <TextBox x:Name="Prompt" Background="Transparent" BorderThickness="0" Foreground="#ECECEC" CaretBrush="#ECECEC"
                         FontSize="15" TextWrapping="Wrap" AcceptsReturn="False" MaxHeight="200" MinHeight="36"
                         VerticalScrollBarVisibility="Auto" VerticalContentAlignment="Center" Padding="2,8"/>
                <TextBlock x:Name="Placeholder" Text="Pregunta lo que quieras" Foreground="#8E8E8E" FontSize="15"
                           IsHitTestVisible="False" VerticalAlignment="Center" Margin="5,0"/>
              </Grid>
              <Button x:Name="BtnEnviar" Grid.Column="2" Style="{StaticResource Redondo}" Background="#ECECEC" VerticalAlignment="Bottom" ToolTip="Enviar (Enter)">
                <TextBlock x:Name="IcoEnviar" FontFamily="Segoe MDL2 Assets" Text="&#xE74A;" FontSize="16" Foreground="#171717" FontWeight="Bold"/>
              </Button>
            </Grid>
          </Grid>
        </Border>
        <TextBlock Grid.Row="1" Text="Enter envía · Shift+Enter nueva línea · Valora puede equivocarse: revisa lo importante."
                   Foreground="#6E6E6E" FontSize="11.5" HorizontalAlignment="Center" Margin="0,8,0,0"/>
      </Grid>
    </Grid>

    <!-- Inicio de sesión con Google -->
    <Grid x:Name="Login" Grid.ColumnSpan="2" Background="#E6121212" Visibility="Collapsed">
      <Border Width="500" Background="#262626" CornerRadius="18" Padding="34,30" VerticalAlignment="Center" HorizontalAlignment="Center"
              BorderBrush="#3A3A3A" BorderThickness="1">
        <StackPanel>
          <Border Width="52" Height="52" CornerRadius="14" Background="#2E7D5A" HorizontalAlignment="Left" Margin="0,0,0,18">
            <TextBlock Text="V" FontSize="28" FontWeight="Bold" Foreground="White" HorizontalAlignment="Center" VerticalAlignment="Center"/>
          </Border>
          <TextBlock Text="Conecta tu cuenta de Google" FontSize="22" FontWeight="SemiBold" Margin="0,0,0,8"/>
          <TextBlock x:Name="LoginTexto" TextWrapping="Wrap" Foreground="#B4B4B4" FontSize="14" LineHeight="21" Margin="0,0,0,22"
                     Text="Valora funciona con Google Antigravity. Para empezar, entra con tu cuenta de Google. Solo hace falta la primera vez."/>

          <Button x:Name="BtnLogin" Style="{StaticResource Plano}" Background="#ECECEC" Foreground="#171717" Padding="18,12"
                  HorizontalContentAlignment="Center" FontSize="15" FontWeight="SemiBold" Content="Iniciar sesión con Google"/>

          <StackPanel x:Name="LoginCodigo" Visibility="Collapsed">
            <TextBlock TextWrapping="Wrap" Foreground="#ECECEC" FontSize="14" LineHeight="21" Margin="0,0,0,12"
                       Text="Tienes 1 minuto:&#x0a;1. En el navegador, elige tu cuenta de Google y acepta.&#x0a;2. Si al final Google te enseña un código, cópialo y pégalo aquí:"/>
            <Border Background="#1A1A1A" CornerRadius="10" BorderBrush="#3A3A3A" BorderThickness="1" Padding="10,4">
              <TextBox x:Name="CodigoLogin" Background="Transparent" BorderThickness="0" Foreground="#ECECEC" CaretBrush="#ECECEC"
                       FontSize="14" Padding="0,8" FontFamily="Consolas"/>
            </Border>
            <Grid Margin="0,14,0,0">
              <Button x:Name="BtnReabrir" Style="{StaticResource Plano}" Foreground="#B4B4B4" Padding="8,8" Content="Abrir otra vez el navegador" HorizontalAlignment="Left"/>
              <Button x:Name="BtnCodigo" Style="{StaticResource Plano}" Background="#ECECEC" Foreground="#171717" Padding="18,9"
                      FontWeight="SemiBold" Content="Continuar" HorizontalAlignment="Right"/>
            </Grid>
          </StackPanel>

          <TextBlock x:Name="LoginEstado" TextWrapping="Wrap" Foreground="#8E8E8E" FontSize="13" Margin="0,16,0,0"/>
          <Button x:Name="BtnLoginLuego" Style="{StaticResource Plano}" Foreground="#8E8E8E" Padding="8,6" FontSize="12.5"
                  HorizontalAlignment="Left" Margin="-8,8,0,0" Content="Ahora no" Visibility="Collapsed"/>
        </StackPanel>
      </Border>
    </Grid>
  </Grid>
</Window>
'@

$win = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xaml))
$ui = @{}
foreach ($n in 'BtnNueva','TxtWs','BtnWs','BtnAbrirWs','ListaCarpetas','BtnCarpeta','ChkAuto','BtnTerminal','TxtEstado',
               'Scroll','Chat','Inicio','Sugerencias','Adjuntos','BtnAdjuntar','Prompt','Placeholder','BtnEnviar','IcoEnviar',
               'Login','LoginTexto','BtnLogin','LoginCodigo','CodigoLogin','BtnReabrir','BtnCodigo','LoginEstado','BtnLoginLuego',
               'TxtCuenta','BtnLogout','ListaConv','AvisoVersion','BtnReiniciar') {
    $ui[$n] = $win.FindName($n)
}
$icono = Join-Path $ConfigDir 'valora.ico'
if (Test-Path $icono) { try { $win.Icon = [System.Windows.Media.Imaging.BitmapFrame]::Create((New-Object Uri $icono)) } catch {} }

$conversorColor = New-Object System.Windows.Media.BrushConverter
function Brush([string]$hex) { return $conversorColor.ConvertFromString($hex) }
$imagenes = @('.jpg','.jpeg','.png','.bmp','.gif','.tif','.tiff')

# ---------- Utilidades de interfaz ----------
function Set-Estado([string]$texto, [string]$color = '#8E8E8E') {
    $ui.TxtEstado.Text = $texto
    $ui.TxtEstado.Foreground = Brush $color
}

function Update-Inicio {
    $ui.Inicio.Visibility = if ($ui.Chat.Children.Count -eq 0) { 'Visible' } else { 'Collapsed' }
}

function New-Icono([string]$glifo, [double]$tam = 14, [string]$color = '#CFCFCF') {
    $t = New-Object System.Windows.Controls.TextBlock
    $t.FontFamily = 'Segoe MDL2 Assets'; $t.Text = $glifo; $t.FontSize = $tam
    $t.Foreground = Brush $color; $t.VerticalAlignment = 'Center'; $t.HorizontalAlignment = 'Center'
    return $t
}

function New-TextoLectura([string]$texto, [string]$color) {
    $t = New-Object System.Windows.Controls.TextBox
    $t.Text = $texto; $t.IsReadOnly = $true; $t.BorderThickness = 0; $t.Background = 'Transparent'
    $t.Foreground = Brush $color; $t.TextWrapping = 'Wrap'; $t.FontSize = 15
    return $t
}

function Add-MensajeUsuario([string]$texto, $adjuntos) {
    $pila = New-Object System.Windows.Controls.StackPanel
    $pila.HorizontalAlignment = 'Right'; $pila.Margin = '80,10,0,10'
    if ($adjuntos.Count -gt 0) {
        $wrap = New-Object System.Windows.Controls.WrapPanel
        $wrap.HorizontalAlignment = 'Right'; $wrap.Margin = '0,0,0,6'
        foreach ($a in $adjuntos) { [void]$wrap.Children.Add((New-Miniatura $a 72 $false)) }
        [void]$pila.Children.Add($wrap)
    }
    $b = New-Object System.Windows.Controls.Border
    $b.Background = Brush '#303030'; $b.CornerRadius = 18; $b.Padding = '16,10'
    $b.HorizontalAlignment = 'Right'
    $b.Child = New-TextoLectura $texto '#ECECEC'
    [void]$pila.Children.Add($b)
    [void]$ui.Chat.Children.Add($pila)
    Update-Inicio
}

function Add-MensajeAgy {
    $g = New-Object System.Windows.Controls.Grid
    $g.Margin = '0,10,0,14'
    $c1 = New-Object System.Windows.Controls.ColumnDefinition; $c1.Width = 'Auto'
    $c2 = New-Object System.Windows.Controls.ColumnDefinition
    $g.ColumnDefinitions.Add($c1); $g.ColumnDefinitions.Add($c2)
    $av = New-Object System.Windows.Controls.Border
    $av.Width = 28; $av.Height = 28; $av.CornerRadius = 14; $av.BorderBrush = Brush '#3A3A3A'; $av.BorderThickness = 1
    $av.VerticalAlignment = 'Top'; $av.Margin = '0,2,14,0'
    $l = New-Object System.Windows.Controls.TextBlock
    $l.Text = 'V'; $l.FontWeight = 'Bold'; $l.HorizontalAlignment = 'Center'; $l.VerticalAlignment = 'Center'
    $av.Child = $l
    $t = New-TextoLectura 'Pensando…' '#8E8E8E'
    [System.Windows.Controls.Grid]::SetColumn($t, 1)
    [void]$g.Children.Add($av); [void]$g.Children.Add($t)
    [void]$ui.Chat.Children.Add($g)
    Update-Inicio
    $script:respuesta = $t
    $script:pensando = $true
}

function Add-MensajeAgyTexto([string]$texto) {
    Add-MensajeAgy
    $script:respuesta.Text = $texto
    $script:respuesta.Foreground = Brush '#ECECEC'
    $script:pensando = $false
    $script:respuesta = $null
}

# ---------- Historial de conversaciones ----------
function Save-Conv {
    if (-not $script:conv) { return }
    $script:conv.actualizada = (Get-Date).ToString('o')
    $ruta = Join-Path $ConvDir ($script:conv.id + '.json')
    $script:conv | ConvertTo-Json -Depth 6 | Set-Content $ruta -Encoding UTF8
}

function Get-Convs {
    $lista = @()
    foreach ($f in Get-ChildItem $ConvDir -Filter *.json -ErrorAction SilentlyContinue) {
        try {
            $c = Get-Content $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($c.id) { $lista += $c }
        } catch {}
    }
    return @($lista | Sort-Object { [datetime]$_.actualizada } -Descending)
}

function Update-ListaConv {
    $ui.ListaConv.Children.Clear()
    foreach ($c in Get-Convs) {
        $g = New-Object System.Windows.Controls.Grid
        $g.Margin = '2,0,2,1'
        $btn = New-Object System.Windows.Controls.Button
        $btn.Style = $win.FindResource('Plano'); $btn.Padding = '10,7'; $btn.Tag = $c.id
        if ($script:conv -and $script:conv.id -eq $c.id) { $btn.Background = Brush '#2A2A2A' }
        $sp = New-Object System.Windows.Controls.StackPanel
        $t = New-Object System.Windows.Controls.TextBlock
        $t.Text = $c.titulo; $t.TextTrimming = 'CharacterEllipsis'; $t.Margin = '0,0,22,0'; $t.FontSize = 13.5
        $f = New-Object System.Windows.Controls.TextBlock
        $f.Text = ([datetime]$c.actualizada).ToString('dd/MM/yyyy HH:mm'); $f.Foreground = Brush '#7A7A7A'; $f.FontSize = 11
        [void]$sp.Children.Add($t); [void]$sp.Children.Add($f)
        $btn.Content = $sp
        $btn.ToolTip = $c.titulo
        $btn.Add_Click({ Open-Conv $this.Tag })
        $x = New-Object System.Windows.Controls.Button
        $x.Style = $win.FindResource('Plano'); $x.Padding = '7'; $x.HorizontalAlignment = 'Right'; $x.VerticalAlignment = 'Center'
        $x.Tag = $c.id; $x.ToolTip = 'Borrar conversación'
        [System.Windows.Automation.AutomationProperties]::SetName($x, 'Borrar: ' + $c.titulo)
        $x.Content = New-Icono ([string][char]0xE74D) 12 '#8E8E8E'
        $x.Add_Click({ Remove-Conv $this.Tag })
        [void]$g.Children.Add($btn); [void]$g.Children.Add($x)
        [void]$ui.ListaConv.Children.Add($g)
    }
}

function New-ConvVacia {
    $script:conv = $null
    $ui.Chat.Children.Clear()
    Update-Inicio
    Update-ListaConv
}

function Open-Conv([string]$id) {
    if ($script:proc) { return }
    $ruta = Join-Path $ConvDir ($id + '.json')
    if (-not (Test-Path $ruta)) { Update-ListaConv; return }
    $c = Get-Content $ruta -Raw -Encoding UTF8 | ConvertFrom-Json
    $c.mensajes = @($c.mensajes)
    $script:conv = $c
    $ui.Chat.Children.Clear()
    foreach ($m in $c.mensajes) {
        if ($m.rol -eq 'usuario') { Add-MensajeUsuario $m.texto @($m.adjuntos | Where-Object { $_ }) }
        else { Add-MensajeAgyTexto $m.texto }
    }
    Update-Inicio
    Update-ListaConv
    $ui.Scroll.ScrollToEnd()
    Set-Estado 'Conversación abierta. Puedes seguir donde la dejaste.'
    $ui.Prompt.Focus() | Out-Null
}

function Remove-Conv([string]$id) {
    $ruta = Join-Path $ConvDir ($id + '.json')
    $titulo = ''
    try { $titulo = (Get-Content $ruta -Raw -Encoding UTF8 | ConvertFrom-Json).titulo } catch {}
    $r = [System.Windows.MessageBox]::Show("¿Borrar esta conversación?`n`n$titulo`n`nNo se puede deshacer.", 'Borrar conversación', 'YesNo', 'Warning')
    if ($r -ne 'Yes') { return }
    try {
        $c = Get-Content $ruta -Raw -Encoding UTF8 | ConvertFrom-Json
        # También se borra la copia que guarda agy de esa conversación.
        if ($c.agyId) {
            Get-ChildItem (Join-Path $env:USERPROFILE '.gemini\antigravity-cli\conversations') -Filter ($c.agyId + '*') -ErrorAction SilentlyContinue |
                Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
        }
    } catch {}
    Remove-Item $ruta -Force -ErrorAction SilentlyContinue
    if ($script:conv -and $script:conv.id -eq $id) { New-ConvVacia } else { Update-ListaConv }
    Set-Estado 'Conversación borrada.'
}

function Write-Respuesta([string]$texto, [string]$color = '#ECECEC') {
    if (-not $script:respuesta) { return }
    if ($script:pensando) {
        $script:respuesta.Text = ''
        $script:respuesta.Foreground = Brush $color
        $script:pensando = $false
    }
    $script:respuesta.AppendText($texto)
    $ui.Scroll.ScrollToEnd()
}

function New-Miniatura([string]$ruta, [int]$alto, [bool]$quitable) {
    $g = New-Object System.Windows.Controls.Grid
    $g.Margin = '0,0,8,8'
    $b = New-Object System.Windows.Controls.Border
    $b.CornerRadius = 10; $b.Background = Brush '#3A3A3A'; $b.ToolTip = $ruta
    $esImagen = $false
    if ($imagenes -contains [IO.Path]::GetExtension($ruta).ToLower()) {
        try {
            $bmp = New-Object System.Windows.Media.Imaging.BitmapImage
            $bmp.BeginInit(); $bmp.UriSource = New-Object Uri($ruta); $bmp.DecodePixelHeight = $alto * 2
            $bmp.CacheOption = 'OnLoad'; $bmp.EndInit()
            $brush = New-Object System.Windows.Media.ImageBrush $bmp
            $brush.Stretch = 'UniformToFill'
            $b.Background = $brush; $b.Width = $alto; $b.Height = $alto
            $esImagen = $true
        } catch {}
    }
    if (-not $esImagen) {
        $sp = New-Object System.Windows.Controls.StackPanel
        $sp.Orientation = 'Horizontal'; $sp.Margin = '12,8,14,8'
        $glifo = if (Test-Path $ruta -PathType Container) { [string][char]0xE8B7 } else { [string][char]0xE8A5 }
        [void]$sp.Children.Add((New-Icono $glifo 14))
        $n = New-Object System.Windows.Controls.TextBlock
        $n.Text = Split-Path $ruta -Leaf; $n.Margin = '8,0,0,0'; $n.MaxWidth = 200; $n.TextTrimming = 'CharacterEllipsis'
        $n.Foreground = Brush '#ECECEC'; $n.FontSize = 13; $n.VerticalAlignment = 'Center'
        [void]$sp.Children.Add($n)
        $b.Child = $sp
    }
    [void]$g.Children.Add($b)
    if ($quitable) {
        $x = New-Object System.Windows.Controls.Button
        $x.Style = $win.FindResource('Redondo'); $x.Width = 20; $x.Height = 20
        $x.Background = Brush '#ECECEC'; $x.HorizontalAlignment = 'Right'; $x.VerticalAlignment = 'Top'
        $x.Margin = '0,-6,-6,0'; $x.ToolTip = 'Quitar'
        $x.Content = New-Icono ([string][char]0xE711) 8 '#171717'
        $x.Tag = $ruta
        $x.Add_Click({ $script:archivos.Remove($this.Tag); Update-Adjuntos })
        [void]$g.Children.Add($x)
    }
    return $g
}

function Update-Adjuntos {
    $ui.Adjuntos.Children.Clear()
    foreach ($a in $script:archivos) { [void]$ui.Adjuntos.Children.Add((New-Miniatura $a 56 $true)) }
    $ui.Adjuntos.Visibility = if ($script:archivos.Count -gt 0) { 'Visible' } else { 'Collapsed' }
}

function Update-Carpetas {
    $ui.ListaCarpetas.Items.Clear()
    foreach ($c in $script:carpetas) {
        $g = New-Object System.Windows.Controls.Grid
        $g.Margin = '2,0,2,2'
        $btn = New-Object System.Windows.Controls.Button
        $btn.Style = $win.FindResource('Plano'); $btn.Padding = '10,6'; $btn.ToolTip = $c; $btn.Tag = $c
        $sp = New-Object System.Windows.Controls.StackPanel; $sp.Orientation = 'Horizontal'
        [void]$sp.Children.Add((New-Icono ([string][char]0xE8B7) 13 '#B4B4B4'))
        $t = New-Object System.Windows.Controls.TextBlock
        $t.Text = Split-Path $c -Leaf; $t.Margin = '10,0,24,0'; $t.TextTrimming = 'CharacterEllipsis'; $t.MaxWidth = 170
        [void]$sp.Children.Add($t)
        $btn.Content = $sp
        $btn.Add_Click({ Start-Process explorer.exe $this.Tag })
        $x = New-Object System.Windows.Controls.Button
        $x.Style = $win.FindResource('Plano'); $x.Padding = '6'; $x.HorizontalAlignment = 'Right'; $x.Tag = $c
        $x.ToolTip = 'Desconectar carpeta'
        $x.Content = New-Icono ([string][char]0xE711) 10 '#8E8E8E'
        $x.Add_Click({ $script:carpetas.Remove($this.Tag); Update-Carpetas; Save-Config })
        [void]$g.Children.Add($btn); [void]$g.Children.Add($x)
        [void]$ui.ListaCarpetas.Items.Add($g)
    }
}

function Add-Rutas($rutas) {
    foreach ($r in $rutas) {
        if (-not $r -or -not (Test-Path $r)) { continue }
        if (Test-Path $r -PathType Container) {
            if (-not $script:carpetas.Contains($r)) { [void]$script:carpetas.Add($r) }
        } elseif (-not $script:archivos.Contains($r)) {
            [void]$script:archivos.Add($r)
        }
    }
    Update-Adjuntos; Update-Carpetas; Save-Config
}

function Set-Ocupado([bool]$ocupado) {
    $ui.BtnNueva.IsEnabled = -not $ocupado
    if ($ocupado) {
        $ui.IcoEnviar.Text = [string][char]0xE71A
        $ui.BtnEnviar.ToolTip = 'Parar'
    } else {
        $ui.IcoEnviar.Text = [string][char]0xE74A
        $ui.BtnEnviar.ToolTip = 'Enviar (Enter)'
    }
}

# ---------- Inicio de sesión ----------
# agy guarda la sesión en el Administrador de credenciales de Windows. Si no hay sesión,
# "agy -p" imprime un enlace de Google y espera a que se pegue el código por la entrada estándar.
$script:chk = $null
$script:loginProc = $null
$script:codigoMalo = $false
$script:urlLogin = $null
$script:loginIntentado = $false
$script:loginInicio = $null
$script:loginCaducado = $false
$script:codigoEnviado = $false

function New-AgyPsi([string]$argumentos, [bool]$conEntrada) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $script:Agy
    $psi.Arguments = $argumentos
    $psi.WorkingDirectory = $script:workspace
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
    return $psi
}

# Correo de la cuenta activa (agy lo guarda en ~\.gemini\google_accounts.json).
function Update-Cuenta([bool]$conectado) {
    $correo = $null
    if ($conectado) {
        try {
            $j = Get-Content (Join-Path $env:USERPROFILE '.gemini\google_accounts.json') -Raw -Encoding UTF8 | ConvertFrom-Json
            $correo = $j.active
        } catch {}
        if (-not $correo) { $correo = 'Conectada' }
    }
    $ui.TxtCuenta.Text = if ($correo) { $correo } else { 'Sin conectar' }
    $ui.TxtCuenta.ToolTip = $ui.TxtCuenta.Text
    $ui.BtnLogout.Visibility = if ($conectado) { 'Visible' } else { 'Collapsed' }
}

# Cerrar sesión: borra la credencial que agy guarda en el Administrador de credenciales de Windows.
function Close-Sesion {
    $r = [System.Windows.MessageBox]::Show(
        "¿Cerrar la sesión de Google en este equipo?`n`nPara volver a usar Valora habrá que iniciar sesión otra vez.",
        'Cerrar sesión', 'YesNo', 'Question')
    if ($r -ne 'Yes') { return }
    if ($script:proc -and -not $script:proc.HasExited) { try { $script:proc.Kill() } catch {} }
    & cmdkey.exe /delete:gemini:antigravity | Out-Null
    New-ConvVacia
    Update-Cuenta $false
    $script:loginIntentado = $false
    Show-Login 'Sesión cerrada.'
    $ui.LoginEstado.Foreground = Brush '#8E8E8E'
}

function Show-Login([string]$mensaje = '') {
    $ui.Login.Visibility = 'Visible'
    $ui.BtnLogin.Visibility = 'Visible'
    $ui.BtnLogin.IsEnabled = $true
    $ui.LoginCodigo.Visibility = 'Collapsed'
    $ui.LoginEstado.Text = $mensaje
    $ui.LoginEstado.Foreground = Brush $(if ($mensaje) { '#F28B82' } else { '#8E8E8E' })
    Update-Cuenta $false
    Set-Estado 'Falta iniciar sesión con Google.' '#F28B82'
}

function Hide-Login {
    $ui.Login.Visibility = 'Collapsed'
    $ui.Prompt.Focus() | Out-Null
}

$timerChk = New-Object System.Windows.Threading.DispatcherTimer
$timerChk.Interval = [TimeSpan]::FromMilliseconds(200)
$timerChk.Add_Tick({
    if (-not $script:chk) { $timerChk.Stop(); return }
    if (-not $script:chk.proc.HasExited) { return }
    if (-not ($script:chk.out.IsCompleted -and $script:chk.err.IsCompleted)) { return }
    $timerChk.Stop()
    $texto = $script:chk.out.Result + $script:chk.err.Result
    $ok = ($script:chk.proc.ExitCode -eq 0) -and ($texto -notmatch 'sign in|Authentication required')
    $script:chk = $null
    if ($ok) {
        Update-Cuenta $true
        if ($ui.Login.Visibility -eq 'Visible') { Set-Estado 'Sesión iniciada. ¡Listo para trabajar!' '#81C995' } else { Set-Estado 'Listo.' }
        Hide-Login
    } elseif ($script:codigoMalo) {
        Show-Login 'Google no ha aceptado el código (o ya se había usado). Pulsa el botón y vuelve a intentarlo.'
    } elseif ($script:loginCaducado) {
        Show-Login 'Se ha agotado el minuto que da Google. Pulsa el botón y vuelve a intentarlo: se abrirá otra vez el navegador.'
    } elseif ($script:loginIntentado) {
        Show-Login 'No se ha completado el inicio de sesión. Pulsa el botón y prueba otra vez.'
    } else {
        # Sin sesión: no se puede usar Valora, así que se lanza el login directamente.
        Show-Login
        Start-Login
    }
})

# Comprueba en segundo plano si agy tiene sesión ("agy models" falla sin sesión).
function Start-Comprobacion {
    if ($script:chk -or -not $script:Agy) { return }
    try {
        $p = [System.Diagnostics.Process]::Start((New-AgyPsi 'models' $false))
        $p.StandardInput.Close()
        $script:chk = @{ proc = $p; out = $p.StandardOutput.ReadToEndAsync(); err = $p.StandardError.ReadToEndAsync() }
        $timerChk.Start()
    } catch {
        Set-Estado ('No se pudo comprobar la sesión: ' + $_.Exception.Message) '#F28B82'
    }
}

# agy solo acepta el código pegado si su entrada es una consola de verdad, así que el
# inicio de sesión se ejecuta dentro de una pseudoconsola invisible (ConPTY).
$PtyCodigo = @'
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using Microsoft.Win32.SafeHandles;

// Ejecuta un programa dentro de una pseudoconsola (ConPTY) para que crea que tiene una
// terminal: agy solo acepta el código de inicio de sesión pegado si la entrada es una consola.
public class ValoraPty
{
    [StructLayout(LayoutKind.Sequential)] struct COORD { public short X, Y; }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct STARTUPINFO
    {
        public int cb; public string lpReserved, lpDesktop, lpTitle;
        public int dwX, dwY, dwXSize, dwYSize, dwXCountChars, dwYCountChars, dwFillAttribute, dwFlags;
        public short wShowWindow, cbReserved2; public IntPtr lpReserved2, hStdInput, hStdOutput, hStdError;
    }
    [StructLayout(LayoutKind.Sequential)] struct STARTUPINFOEX { public STARTUPINFO StartupInfo; public IntPtr lpAttributeList; }
    [StructLayout(LayoutKind.Sequential)] struct PROCESS_INFORMATION { public IntPtr hProcess, hThread; public int dwProcessId, dwThreadId; }

    [DllImport("kernel32.dll", SetLastError = true)] static extern int CreatePseudoConsole(COORD size, SafeFileHandle hInput, SafeFileHandle hOutput, uint flags, out IntPtr phPC);
    [DllImport("kernel32.dll")] static extern void ClosePseudoConsole(IntPtr hPC);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool CreatePipe(out SafeFileHandle r, out SafeFileHandle w, IntPtr sa, int size);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool InitializeProcThreadAttributeList(IntPtr list, int count, int flags, ref IntPtr size);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool UpdateProcThreadAttribute(IntPtr list, uint flags, IntPtr attr, IntPtr val, IntPtr size, IntPtr prev, IntPtr retSize);
    [DllImport("kernel32.dll")] static extern void DeleteProcThreadAttributeList(IntPtr list);
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern bool CreateProcess(string app, string cmd, IntPtr pa, IntPtr ta, bool inherit, uint flags, IntPtr env, string dir, ref STARTUPINFOEX si, out PROCESS_INFORMATION pi);
    [DllImport("kernel32.dll")] static extern uint WaitForSingleObject(IntPtr h, uint ms);
    [DllImport("kernel32.dll")] static extern bool GetExitCodeProcess(IntPtr h, out uint code);
    [DllImport("kernel32.dll")] static extern bool TerminateProcess(IntPtr h, uint code);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);

    IntPtr hPC = IntPtr.Zero, hProcess = IntPtr.Zero;
    FileStream entrada;
    readonly StringBuilder salida = new StringBuilder();
    readonly object cerrojo = new object();

    public static ValoraPty Start(string lineaComando, string carpeta)
    {
        ValoraPty p = new ValoraPty();
        SafeFileHandle inRead, inWrite, outRead, outWrite;
        if (!CreatePipe(out inRead, out inWrite, IntPtr.Zero, 0) || !CreatePipe(out outRead, out outWrite, IntPtr.Zero, 0))
            throw new InvalidOperationException("CreatePipe falló: " + Marshal.GetLastWin32Error());
        COORD tam; tam.X = 4000; tam.Y = 60;
        int hr = CreatePseudoConsole(tam, inRead, outWrite, 0, out p.hPC);
        if (hr != 0) throw new InvalidOperationException("CreatePseudoConsole falló: 0x" + hr.ToString("X"));

        IntPtr tamLista = IntPtr.Zero;
        InitializeProcThreadAttributeList(IntPtr.Zero, 1, 0, ref tamLista);
        IntPtr lista = Marshal.AllocHGlobal(tamLista);
        if (!InitializeProcThreadAttributeList(lista, 1, 0, ref tamLista))
            throw new InvalidOperationException("InitializeProcThreadAttributeList falló");
        if (!UpdateProcThreadAttribute(lista, 0, (IntPtr)0x00020016, p.hPC, (IntPtr)IntPtr.Size, IntPtr.Zero, IntPtr.Zero))
            throw new InvalidOperationException("UpdateProcThreadAttribute falló");

        STARTUPINFOEX si = new STARTUPINFOEX();
        si.StartupInfo.cb = Marshal.SizeOf(typeof(STARTUPINFOEX));
        si.StartupInfo.dwFlags = 0x100; // STARTF_USESTDHANDLES con handles nulos: no heredar los del padre
        si.lpAttributeList = lista;
        PROCESS_INFORMATION pi;
        if (!CreateProcess(null, lineaComando, IntPtr.Zero, IntPtr.Zero, false, 0x00080000, IntPtr.Zero, carpeta, ref si, out pi))
            throw new InvalidOperationException("CreateProcess falló: " + Marshal.GetLastWin32Error());
        CloseHandle(pi.hThread);
        p.hProcess = pi.hProcess;
        DeleteProcThreadAttributeList(lista);
        Marshal.FreeHGlobal(lista);
        inRead.Dispose();
        outWrite.Dispose();

        p.entrada = new FileStream(inWrite, FileAccess.Write);
        FileStream lectura = new FileStream(outRead, FileAccess.Read);
        Thread t = new Thread(delegate ()
        {
            byte[] buf = new byte[8192];
            Decoder dec = Encoding.UTF8.GetDecoder();
            char[] chars = new char[8192];
            try
            {
                int n;
                while ((n = lectura.Read(buf, 0, buf.Length)) > 0)
                {
                    int c = dec.GetChars(buf, 0, n, chars, 0);
                    lock (p.cerrojo) p.salida.Append(chars, 0, c);
                }
            }
            catch (IOException) { }
            catch (ObjectDisposedException) { }
        });
        t.IsBackground = true;
        t.Start();
        return p;
    }

    public string Salida { get { lock (cerrojo) return salida.ToString(); } }

    public void Escribir(string texto)
    {
        byte[] b = Encoding.UTF8.GetBytes(texto);
        entrada.Write(b, 0, b.Length);
        entrada.Flush();
    }

    public bool Terminado { get { return hProcess == IntPtr.Zero || WaitForSingleObject(hProcess, 0) == 0; } }

    public int Codigo
    {
        get { uint c; GetExitCodeProcess(hProcess, out c); return (int)c; }
    }

    public void Matar() { if (!Terminado) TerminateProcess(hProcess, 1); }

    // Cierra la pseudoconsola en otro hilo: ClosePseudoConsole puede bloquear hasta vaciar la salida.
    public void Cerrar()
    {
        IntPtr pc = hPC; hPC = IntPtr.Zero;
        if (pc != IntPtr.Zero) { Thread t = new Thread(delegate () { ClosePseudoConsole(pc); }); t.IsBackground = true; t.Start(); }
        try { if (entrada != null) entrada.Dispose(); } catch (IOException) { }
    }
}
'@

function Limpiar-Terminal([string]$s) {
    return ($s -replace '\x1b\[[0-9;?]*[A-Za-z]', '' -replace '\x1b\][^\x07]*\x07', '' -replace '\x1b[=>]', '')
}

$timerLogin = New-Object System.Windows.Threading.DispatcherTimer
$timerLogin.Interval = [TimeSpan]::FromMilliseconds(200)
$timerLogin.Add_Tick({
    if (-not $script:loginProc) { $timerLogin.Stop(); return }
    $texto = Limpiar-Terminal $script:loginProc.Salida
    if (-not $script:urlLogin -and $texto -match '(https://accounts\.google\.com/\S+?)(?=Waiting|\s|$)') {
        $script:urlLogin = $Matches[1]
        $script:loginInicio = Get-Date
        Start-Process $script:urlLogin
        $ui.BtnLogin.Visibility = 'Collapsed'
        $ui.LoginCodigo.Visibility = 'Visible'
        $ui.CodigoLogin.Focus() | Out-Null
    }
    if ($texto -match 'timed out') { $script:loginCaducado = $true }
    if ($texto -match 'invalid_grant|token exchange failed') { $script:codigoMalo = $true }
    $terminado = $script:loginProc.Terminado
    if ($script:loginInicio -and -not $script:codigoEnviado -and -not $terminado) {
        $quedan = 60 - [int]((Get-Date) - $script:loginInicio).TotalSeconds
        if ($quedan -gt 0) {
            $ui.LoginEstado.Foreground = Brush $(if ($quedan -le 15) { '#E8A33D' } else { '#8E8E8E' })
            $ui.LoginEstado.Text = "Esperando a que termines en el navegador… (quedan $quedan s)"
        }
    }
    if ($terminado) {
        $timerLogin.Stop()
        $script:loginProc.Cerrar()
        $script:loginProc = $null
        $ui.LoginEstado.Foreground = Brush '#8E8E8E'
        $ui.LoginEstado.Text = 'Comprobando…'
        Start-Comprobacion
    }
})

function Start-Login {
    if ($script:loginProc) { return }
    if (-not $script:Agy) { $script:Agy = Find-Agy }
    if (-not $script:Agy) { Show-Login 'No encuentro agy. Ejecuta InstalarValora.exe.'; return }
    $script:urlLogin = $null
    $script:loginIntentado = $true
    $script:loginInicio = $null
    $script:loginCaducado = $false
    $script:codigoMalo = $false
    $script:codigoEnviado = $false
    $ui.BtnLogin.IsEnabled = $false
    $ui.LoginEstado.Foreground = Brush '#8E8E8E'
    $ui.LoginEstado.Text = 'Abriendo el navegador…'
    try {
        if (-not ('ValoraPty' -as [type])) { Add-Type -TypeDefinition $PtyCodigo -Language CSharp }
        $linea = '"' + $script:Agy + '" -p "Responde solo: ok" --output-format text'
        $script:loginProc = [ValoraPty]::Start($linea, $script:workspace)
    } catch {
        Show-Login ('No se pudo arrancar el inicio de sesión: ' + $_.Exception.Message); return
    }
    $timerLogin.Start()
}

function Send-CodigoLogin {
    $codigo = $ui.CodigoLogin.Text.Trim()
    if (-not $codigo) { return }
    if (-not $script:loginProc -or $script:loginProc.Terminado) {
        Show-Login 'El enlace ha caducado. Pulsa el botón y prueba otra vez.'
        return
    }
    try { $script:loginProc.Escribir($codigo + "`r") } catch {}
    $script:codigoEnviado = $true
    $ui.CodigoLogin.Clear()
    $ui.LoginEstado.Foreground = Brush '#8E8E8E'
    $ui.LoginEstado.Text = 'Comprobando el código…'
}

$ui.BtnLogin.Add_Click({ Start-Login })
$ui.BtnLogout.Add_Click({ Close-Sesion })
$ui.BtnReabrir.Add_Click({ if ($script:urlLogin) { Start-Process $script:urlLogin } })
$ui.BtnCodigo.Add_Click({ Send-CodigoLogin })
$ui.CodigoLogin.Add_KeyDown({ if ($_.Key -eq 'Return') { Send-CodigoLogin; $_.Handled = $true } })
$ui.BtnLoginLuego.Add_Click({
    if ($script:loginProc) { try { $script:loginProc.Matar(); $script:loginProc.Cerrar() } catch {} ; $script:loginProc = $null }
    $ui.Login.Visibility = 'Collapsed'
})

# ---------- Ejecución de agy ----------
function Limpiar-Ansi([string]$s) { return ($s -replace '\x1b\[[0-9;?]*[A-Za-z]', '') }

# Cada línea de --output-format stream-json es un evento JSON.
$NombresPaso = @{
    'view_file' = 'Leyendo un archivo'; 'list_dir' = 'Mirando una carpeta'; 'find_by_name' = 'Buscando archivos'
    'grep_search' = 'Buscando en los archivos'; 'write_to_file' = 'Creando un archivo'; 'replace_file_content' = 'Editando un archivo'
    'multi_replace_file_content' = 'Editando un archivo'; 'run_command' = 'Ejecutando un comando'; 'search_web' = 'Buscando en internet'
    'read_url_content' = 'Leyendo una página web'; 'generate_image' = 'Generando una imagen'
}
function Read-Evento([string]$linea) {
    $ev = $null
    try { $ev = $linea | ConvertFrom-Json } catch {}
    if (-not $ev -or -not $ev.event) {
        if ($linea.Trim()) { Write-Respuesta ((Limpiar-Ansi $linea) + "`n") }
        return
    }
    switch ($ev.event) {
        'init' {
            if ($script:conv -and -not $script:conv.agyId -and $ev.conversation_id) {
                $script:conv | Add-Member -NotePropertyName agyId -NotePropertyValue $ev.conversation_id -Force
                Save-Conv
            }
        }
        'step_update' {
            $su = $ev.step_update
            if ($su.step_type -eq 'agent_response') {
                if ($su.text_delta) { Write-Respuesta $su.text_delta }
            } elseif ($su.state -eq 'ACTIVE' -and $su.step_type -ne 'user_input') {
                $nombre = $NombresPaso[[string]$su.step_type]
                if (-not $nombre) { $nombre = 'Trabajando' }
                Set-Estado "$nombre…" '#E8A33D'
            }
        }
        'result' { $script:resultado = $ev.result }
    }
}

$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(120)
$timer.Add_Tick({
    if (-not $script:proc) { $timer.Stop(); return }
    while ($script:outTask -and $script:outTask.IsCompleted) {
        $linea = $script:outTask.Result
        if ($null -eq $linea) { $script:outTask = $null; break }
        Read-Evento $linea
        $script:outTask = $script:proc.StandardOutput.ReadLineAsync()
    }
    while ($script:errTask -and $script:errTask.IsCompleted) {
        $linea = $script:errTask.Result
        if ($null -eq $linea) { $script:errTask = $null; break }
        $linea = Limpiar-Ansi $linea
        if ($linea -match 'Authentication required|sign in|log in') {
            $script:avisoLogin = $true
            try { $script:proc.Kill() } catch {}
        }
        if (-not $script:avisoLogin) { Write-Respuesta ($linea + "`n") '#F28B82' }
        $script:errTask = $script:proc.StandardError.ReadLineAsync()
    }
    if (-not $script:outTask -and -not $script:errTask -and $script:proc.HasExited) {
        $codigo = $script:proc.ExitCode
        $script:proc = $null
        $timer.Stop()
        Set-Ocupado $false
        if ($script:avisoLogin) {
            Write-Respuesta 'Falta conectar tu cuenta de Google. Inicia sesión y vuelve a enviar la pregunta.' '#F28B82'
            Show-Login
        } elseif ($codigo -eq 0) {
            Set-Estado 'Listo.'
        } else {
            Set-Estado "agy terminó con error (código $codigo)." '#F28B82'
        }
        if ($script:pensando) { Write-Respuesta '(sin respuesta)' '#8E8E8E' }
        if ($script:respuesta) {
            $script:respuesta.Text = $script:respuesta.Text.TrimEnd()
            if ($script:conv -and -not $script:avisoLogin) {
                $script:conv.mensajes = @($script:conv.mensajes) + @([pscustomobject]@{ rol = 'agy'; texto = $script:respuesta.Text; adjuntos = @() })
                Save-Conv
                Update-ListaConv
            }
        }
        $ui.Prompt.Focus() | Out-Null
    }
})

function Enviar {
    if ($script:proc) { return }
    if (-not $script:Agy) { $script:Agy = Find-Agy }
    if (-not $script:Agy) {
        [System.Windows.MessageBox]::Show('No encuentro agy. Ejecuta el instalador (InstalarValora.exe).', 'Valora') | Out-Null
        return
    }
    $texto = $ui.Prompt.Text.Trim()
    if (-not $texto) { return }
    $ws = $script:workspace
    New-Item -ItemType Directory -Force $ws | Out-Null

    # Los archivos sueltos se copian a <carpeta de trabajo>\entrada para que agy los vea.
    $entrada = Join-Path $ws 'entrada'
    $adjuntos = @()
    foreach ($f in @($script:archivos)) {
        if (-not (Test-Path $f)) { continue }
        $full = (Resolve-Path $f).Path
        if ($full.StartsWith($ws, [StringComparison]::OrdinalIgnoreCase)) {
            $adjuntos += $full
        } else {
            New-Item -ItemType Directory -Force $entrada | Out-Null
            $destino = Join-Path $entrada (Split-Path $full -Leaf)
            Copy-Item $full $destino -Force
            $adjuntos += $destino
        }
    }
    $carpetas = @($script:carpetas)

    $mensaje = $texto
    if ($adjuntos.Count -gt 0) {
        $mensaje += "`n`nArchivos adjuntos (ábrelos y míralos):`n" + (($adjuntos | ForEach-Object { "- $_" }) -join "`n")
    }
    if ($carpetas.Count -gt 0) {
        $mensaje += "`n`nCarpetas que puedes revisar:`n" + (($carpetas | ForEach-Object { "- $_" }) -join "`n")
    }

    if (-not $script:conv) {
        $titulo = ($texto -replace '\s+', ' ')
        if ($titulo.Length -gt 60) { $titulo = $titulo.Substring(0, 60) + '…' }
        $script:conv = [pscustomobject]@{
            id = [Guid]::NewGuid().ToString(); titulo = $titulo; agyId = $null
            creada = (Get-Date).ToString('o'); actualizada = (Get-Date).ToString('o'); mensajes = @()
        }
    }
    $script:conv.mensajes = @($script:conv.mensajes) + @([pscustomobject]@{ rol = 'usuario'; texto = $texto; adjuntos = @($adjuntos) })
    Save-Conv
    Update-ListaConv

    $argumentos = @('-p', (Quote-Arg $mensaje), '--output-format', 'stream-json')
    if ($script:conv.agyId) { $argumentos += @('--conversation', $script:conv.agyId) }
    if ($ui.ChkAuto.IsChecked) { $argumentos += '--dangerously-skip-permissions' }
    foreach ($c in $carpetas) { $argumentos += @('--add-dir', (Quote-Arg $c)) }

    Add-MensajeUsuario $texto $adjuntos
    Add-MensajeAgy
    $ui.Scroll.ScrollToEnd()

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $script:Agy
    $psi.Arguments = $argumentos -join ' '
    $psi.WorkingDirectory = $ws
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8

    try {
        $script:proc = [System.Diagnostics.Process]::Start($psi)
    } catch {
        Write-Respuesta ("No se pudo arrancar agy: " + $_.Exception.Message) '#F28B82'
        return
    }
    $script:proc.StandardInput.Close()
    $script:outTask = $script:proc.StandardOutput.ReadLineAsync()
    $script:errTask = $script:proc.StandardError.ReadLineAsync()
    $script:avisoLogin = $false
    $script:resultado = $null

    $ui.Prompt.Clear()
    $script:archivos.Clear(); Update-Adjuntos
    Set-Ocupado $true
    Set-Estado 'Valora está trabajando…' '#E8A33D'
    $timer.Start()
}

function Parar {
    if ($script:proc -and -not $script:proc.HasExited) {
        try { $script:proc.Kill() } catch {}
        Set-Estado 'Parado.'
    }
}

# ---------- Eventos ----------
$ui.BtnEnviar.Add_Click({ if ($script:proc) { Parar } else { Enviar } })

$ui.Prompt.Add_PreviewKeyDown({
    if ($_.Key -eq 'Return') {
        if ([System.Windows.Input.Keyboard]::Modifiers -band [System.Windows.Input.ModifierKeys]::Shift) {
            $p = $ui.Prompt; $i = $p.CaretIndex
            $p.Text = $p.Text.Insert($i, "`r`n"); $p.CaretIndex = $i + 2
        } else {
            Enviar
        }
        $_.Handled = $true
    }
})
$ui.Prompt.Add_TextChanged({
    $ui.Placeholder.Visibility = if ($ui.Prompt.Text.Length -eq 0) { 'Visible' } else { 'Collapsed' }
})

foreach ($chip in $ui.Sugerencias.Children) {
    $chip.Add_Click({ $ui.Prompt.Text = $this.Tag; $ui.Prompt.CaretIndex = $ui.Prompt.Text.Length; $ui.Prompt.Focus() | Out-Null })
}

$ui.BtnNueva.Add_Click({
    New-ConvVacia
    Set-Estado 'Conversación nueva. La anterior queda guardada en la lista.'
    $ui.Prompt.Focus() | Out-Null
})

$ui.BtnAdjuntar.Add_Click({
    $dlg = New-Object Microsoft.Win32.OpenFileDialog
    $dlg.Multiselect = $true
    $dlg.Title = 'Elige archivos (fotos, PDF, Excel…)'
    if ($dlg.ShowDialog($win)) { Add-Rutas $dlg.FileNames }
})

$ui.BtnCarpeta.Add_Click({
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = 'Elige una carpeta para que agy la revise'
    if ($dlg.ShowDialog() -eq 'OK') { Add-Rutas @($dlg.SelectedPath) }
})

$ui.BtnWs.Add_Click({
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = 'Carpeta donde agy trabaja y guarda los resultados'
    $dlg.SelectedPath = $script:workspace
    if ($dlg.ShowDialog() -eq 'OK') {
        $script:workspace = $dlg.SelectedPath
        $ui.TxtWs.Text = $script:workspace; $ui.TxtWs.ToolTip = $script:workspace
        New-ConvVacia
        Save-Config
        Set-Estado 'Carpeta cambiada. La conversación empieza de nuevo.'
    }
})

$ui.BtnAbrirWs.Add_Click({ Start-Process explorer.exe $script:workspace })
$ui.ChkAuto.Add_Click({ Save-Config })

$ui.BtnTerminal.Add_Click({
    if (-not $script:Agy) { $script:Agy = Find-Agy }
    if (-not $script:Agy) {
        [System.Windows.MessageBox]::Show('No encuentro agy. Ejecuta el instalador (InstalarValora.exe).', 'Valora') | Out-Null
        return
    }
    $extra = ''
    if ($script:conv -and $script:conv.agyId) { $extra += ' --conversation ' + $script:conv.agyId }
    foreach ($c in $script:carpetas) { $extra += " --add-dir '" + ($c -replace "'", "''") + "'" }
    $comando = "& '" + ($script:Agy -replace "'", "''") + "'" + $extra
    Start-Process powershell.exe -WorkingDirectory $script:workspace -ArgumentList @('-NoExit', '-NoProfile', '-Command', $comando)
})

# ---------- Actualización automática ----------
# Valora mira en GitHub el último commit del repositorio. Si cambió, descarga Valora.ps1 de ese
# commit exacto (sin cachés), comprueba que se puede leer, se reemplaza y se reinicia.
# Además, una vez al día, actualiza agy con "agy update".
$VersionFile = Join-Path $ConfigDir 'version.json'
$script:upd = $null
$script:pendienteReinicio = $false

function Get-VersionLocal {
    $vacio = [pscustomobject]@{ sha = ''; agyUpdate = '' }
    if (-not (Test-Path $VersionFile)) { return $vacio }
    try {
        $v = Get-Content $VersionFile -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json
        if ($v) { return $v } else { return $vacio }
    } catch { return $vacio }
}
function Save-VersionLocal($v) { $v | ConvertTo-Json | Set-Content $VersionFile -Encoding UTF8 }

function New-Cliente {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072
    $wc = New-Object System.Net.WebClient
    $wc.Encoding = [System.Text.Encoding]::UTF8
    $wc.Headers['User-Agent'] = 'Valora'
    return $wc
}

# Registro de la actualización, para poder diagnosticar un PC sin estar delante.
function Write-LogUpd([string]$m) {
    try {
        $f = Join-Path $ConfigDir 'actualizacion.log'
        if ((Test-Path $f) -and (Get-Item $f).Length -gt 200KB) { Remove-Item $f -Force }
        Add-Content $f ('{0:yyyy-MM-dd HH:mm:ss} {1}' -f (Get-Date), $m) -Encoding UTF8
    } catch {}
}

function Start-BuscarActualizacion {
    if ($RepoValora -eq '__REPO__' -or $script:upd) { return }
    try {
        $wc = New-Cliente
        $wc.Headers['Accept'] = 'application/vnd.github.sha'
        $script:upd = @{ paso = 'sha'; tarea = $wc.DownloadStringTaskAsync("https://api.github.com/repos/$RepoValora/commits/main") }
        $timerUpd.Start()
    } catch { $script:upd = $null; Write-LogUpd ('no se pudo consultar GitHub: ' + $_.Exception.Message) }
}

function Restart-Valora {
    Save-Config
    Start-Process powershell.exe -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', $RutaValora)
    $win.Close()
}

$timerUpd = New-Object System.Windows.Threading.DispatcherTimer
$timerUpd.Interval = [TimeSpan]::FromMilliseconds(300)
$timerUpd.Add_Tick({
    if (-not $script:upd) { $timerUpd.Stop(); return }
    if (-not $script:upd.tarea.IsCompleted) { return }
    $u = $script:upd
    if ($u.tarea.IsFaulted -or $u.tarea.IsCanceled) {
        $script:upd = $null; $timerUpd.Stop()
        $err = if ($u.tarea.Exception) { $u.tarea.Exception.GetBaseException().Message } else { 'cancelada' }
        Write-LogUpd ("fallo en el paso '$($u.paso)': $err")
        return
    }
    if ($u.paso -eq 'sha') {
        $sha = $u.tarea.Result.Trim()
        $local = Get-VersionLocal
        if ($sha -notmatch '^[0-9a-f]{40}$' -or $sha -eq $local.sha) { $script:upd = $null; $timerUpd.Stop(); return }
        Write-LogUpd "versión nueva $sha (local: '$($local.sha)'), descargando"

        $wc = New-Cliente
        $script:upd = @{ paso = 'codigo'; sha = $sha; tarea = $wc.DownloadStringTaskAsync("https://raw.githubusercontent.com/$RepoValora/$sha/Valora.ps1") }
        return
    }
    if ($u.paso -eq 'codigo') {
        $script:upd = $null; $timerUpd.Stop()
        $codigo = $u.tarea.Result
        $errores = $null
        [void][System.Management.Automation.Language.Parser]::ParseInput($codigo, [ref]$null, [ref]$errores)
        if ($errores.Count -gt 0 -or $codigo -notmatch 'RepoValora') { Write-LogUpd 'descarga no válida, no se aplica'; return }
        try {
            [IO.File]::WriteAllText($RutaValora, $codigo, (New-Object System.Text.UTF8Encoding($true)))
            try { (New-Cliente).DownloadFile("https://raw.githubusercontent.com/$RepoValora/$($u.sha)/src/valora.ico", (Join-Path $ConfigDir 'valora.ico')) } catch {}
            $v = Get-VersionLocal
            $v | Add-Member -NotePropertyName sha -NotePropertyValue $u.sha -Force
            Save-VersionLocal $v
        } catch { Write-LogUpd ('no se pudo escribir la versión nueva: ' + $_.Exception.Message); return }
        Write-LogUpd "aplicada la versión $($u.sha)"
        # Si no se está usando, reinicia ya; si hay trabajo en marcha, avisa y espera.
        if (-not $script:proc -and $ui.Chat.Children.Count -eq 0 -and -not $ui.Prompt.Text -and $script:archivos.Count -eq 0) {
            Restart-Valora
        } else {
            $script:pendienteReinicio = $true
            $ui.AvisoVersion.Visibility = 'Visible'
        }
    }
})

function Start-ActualizarAgy {
    $v = Get-VersionLocal
    $hoy = (Get-Date).ToString('yyyy-MM-dd')
    if ($v.agyUpdate -eq $hoy -or -not $script:Agy) { return }
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo $script:Agy, 'update'
        $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
        [void][System.Diagnostics.Process]::Start($psi)
        $v | Add-Member -NotePropertyName agyUpdate -NotePropertyValue $hoy -Force
        Save-VersionLocal $v
    } catch {}
}

$ui.BtnReiniciar.Add_Click({ if (-not $script:proc) { Restart-Valora } })
$timerRevisar = New-Object System.Windows.Threading.DispatcherTimer
$timerRevisar.Interval = [TimeSpan]::FromMinutes(30)
$timerRevisar.Add_Tick({ Start-BuscarActualizacion })

# Arrastrar y soltar en cualquier parte de la ventana (también sobre la caja de texto).
$win.Add_PreviewDragOver({
    if ($_.Data.GetDataPresent([System.Windows.DataFormats]::FileDrop)) {
        $_.Effects = [System.Windows.DragDropEffects]::Copy
        $_.Handled = $true
    }
})
$win.Add_PreviewDrop({
    if ($_.Data.GetDataPresent([System.Windows.DataFormats]::FileDrop)) {
        Add-Rutas ($_.Data.GetData([System.Windows.DataFormats]::FileDrop))
        $_.Handled = $true
    }
})

$win.Add_Closing({
    Save-Config
    if ($script:proc -and -not $script:proc.HasExited) { try { $script:proc.Kill() } catch {} }
    if ($script:loginProc) { try { $script:loginProc.Matar(); $script:loginProc.Cerrar() } catch {} }
})

# ---------- Arranque ----------
$ui.TxtWs.Text = $script:workspace; $ui.TxtWs.ToolTip = $script:workspace
$ui.ChkAuto.IsChecked = $cfg.auto
Update-Adjuntos; Update-Carpetas; Update-Inicio; Update-ListaConv
$ui.TxtCuenta.Text = 'Comprobando…'; $ui.BtnLogout.Visibility = 'Collapsed'
if ($script:Agy) {
    Set-Estado 'Comprobando la sesión de Google…'
    Start-Comprobacion
} else {
    Set-Estado 'agy no está instalado. Ejecuta InstalarValora.exe.' '#F28B82'
}
$win.Add_ContentRendered({
    $ui.Prompt.Focus() | Out-Null
    Start-BuscarActualizacion
    Start-ActualizarAgy
    $timerRevisar.Start()
})
[void]$win.ShowDialog()
