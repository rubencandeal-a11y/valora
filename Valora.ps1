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
    $cfg = @{ workspace = (Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'Tasaciones'); auto = $true; carpetas = @(); fcEntorno = 'PRE'; fcClaves = @{}; ytUrl = ''; ytUsuario = ''; ytToken = $null; modo = 'valora'; estilo = '' }
    if (Test-Path $ConfigFile) {
        try {
            $j = Get-Content $ConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($j.workspace) { $cfg.workspace = $j.workspace }
            if ($null -ne $j.auto) { $cfg.auto = [bool]$j.auto }
            if ($j.carpetas) { $cfg.carpetas = @($j.carpetas) }
            if ($j.fcEntorno) { $cfg.fcEntorno = $j.fcEntorno }
            foreach ($k in 'ytUrl', 'ytUsuario', 'ytToken', 'modo', 'estilo', 'permisosAgy') { if ($j.$k) { $cfg[$k] = $j.$k } }
            if ($j.fcClaves) { foreach ($pr in $j.fcClaves.PSObject.Properties) { $cfg.fcClaves[$pr.Name] = $pr.Value } }
        } catch {}
    }
    return $cfg
}

function Save-Config {
    @{ workspace = $script:workspace; auto = [bool]$ui.ChkAuto.IsChecked; carpetas = @($script:carpetas); fcEntorno = $script:fcEntorno; fcClaves = $script:fcClaves
       ytUrl = $script:ytUrl; ytUsuario = $script:ytUsuario; ytToken = $script:ytToken; modo = $script:modo; estilo = $script:estilo; permisosAgy = $script:permisosAgy
       ytServidorLocal = [bool]$script:ytServidorLocal; ytClaveLocal = $script:ytClaveLocal } |
        ConvertTo-Json | Set-Content $ConfigFile -Encoding UTF8
    [void](Set-PermisosAgy)
}

# agy pide permiso para cada comando y cada carpeta salvo que su settings.json diga lo
# contrario. Valora le obliga siempre a trabajar sin preguntar (dangerously skip
# permissions): aprueba todos los comandos y confía en la carpeta de trabajo y en las
# conectadas. Se respeta el resto de la configuración (modelo, etc.).
function Set-PermisosAgy {
    try {
        $ruta = Join-Path $env:USERPROFILE '.gemini\antigravity-cli\settings.json'
        $s = $null
        if (Test-Path $ruta) { $s = Get-Content $ruta -Raw -Encoding UTF8 | ConvertFrom-Json }
        if (-not $s) { $s = [pscustomobject]@{} }
        $s | Add-Member -NotePropertyName dangerously_skip_permissions -NotePropertyValue $true -Force
        # El modelo más rápido de los que da agy (medido: Low resuelve antes que Medium y High,
        # con menos comandos). Con agy cada comando que lanza cuesta 4-5 s.
        $s | Add-Member -NotePropertyName model -NotePropertyValue 'Gemini 3.8 Flash (Low)' -Force
        $permisos = if ($s.permissions) { $s.permissions } else { [pscustomobject]@{} }
        $permitidos = @($permisos.allow | Where-Object { $_ })
        if ($permitidos -notcontains 'command(*)') { $permitidos += 'command(*)' }
        $permisos | Add-Member -NotePropertyName allow -NotePropertyValue $permitidos -Force
        $s | Add-Member -NotePropertyName permissions -NotePropertyValue $permisos -Force
        $confiadas = @($s.trustedWorkspaces | Where-Object { $_ })
        foreach ($c in @($script:workspace) + @($script:carpetas)) {
            if ($c -and -not ($confiadas | Where-Object { $_ -ieq $c })) { $confiadas += $c }
        }
        $s | Add-Member -NotePropertyName trustedWorkspaces -NotePropertyValue $confiadas -Force
        $json = $s | ConvertTo-Json -Depth 10
        if ((Test-Path $ruta) -and (Get-Content $ruta -Raw -Encoding UTF8) -eq $json) { return $true }
        New-Item -ItemType Directory -Force (Split-Path $ruta) | Out-Null
        [IO.File]::WriteAllText($ruta, $json, (New-Object Text.UTF8Encoding $false))
        return $true
    } catch { return $false }
}

$script:Agy = Find-Agy
$cfg = Load-Config
$script:workspace = $cfg.workspace
New-Item -ItemType Directory -Force $script:workspace | Out-Null
$script:carpetas = New-Object System.Collections.ArrayList
foreach ($c in $cfg.carpetas) { if (Test-Path $c) { [void]$script:carpetas.Add($c) } }
$script:archivos = New-Object System.Collections.ArrayList
$script:fcEntorno = $cfg.fcEntorno
$script:fcClaves = $cfg.fcClaves      # entorno -> clave cifrada con DPAPI (solo la descifra este usuario de Windows)
$script:fichaPendiente = $null        # ficha que abrirá la próxima conversación
$script:ytUrl = $cfg.ytUrl            # web de resubida de YouTube (vacía: la de este PC)
$script:ytServidorLocal = [bool]$cfg.ytServidorLocal   # este PC monta y sube él mismo (PC del jefe)
$script:ytClaveLocal = $cfg.ytClaveLocal               # contraseña de Valora en su propia web (cifrada)
$script:ytUsuario = $cfg.ytUsuario
$script:ytToken = $cfg.ytToken        # token de esa web, cifrado con DPAPI como las claves de Foticos Collection
$script:modo = 'valora'               # 'valora' o 'youtube'; se aplica al arrancar
$script:estilo = [string]$cfg.estilo  # cómo quiere el usuario que responda; va delante de cada pregunta
$script:permisosAgy = [bool]$cfg.permisosAgy   # el usuario ha aceptado que agy trabaje con todos los permisos

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
$script:convTrabajo = $null       # conversación a la que pertenece la respuesta en curso
$script:sesion = $null            # agy abierto y esperando preguntas (ver Start-SesionAgy)
$script:sesiones = New-Object System.Collections.ArrayList   # las dos últimas abiertas, la más reciente al final
$script:colaPreguntas = New-Object System.Collections.ArrayList   # lo escrito mientras Valora respondía
$script:finTurno = $false         # agy ha mandado el «result» de la pregunta en curso
$script:pasos = New-Object System.Collections.ArrayList   # lo que agy va haciendo en la pregunta en curso
$script:inicioTurno = Get-Date
$script:filaTrabajo = $null       # su burbuja en pantalla, para volver a ponerla al abrir esa conversación

[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Valora" Width="1180" Height="780" MinWidth="820" MinHeight="520"
        WindowStartupLocation="CenterScreen" Background="#1A1D22" AllowDrop="True"
        FontFamily="Segoe UI Variable Text, Segoe UI" FontSize="14" Foreground="#ECE8E1">
  <Window.Resources>
    <SolidColorBrush x:Key="Sidebar" Color="#14161A"/>

    <Style x:Key="Plano" TargetType="Button">
      <Setter Property="Foreground" Value="#ECE8E1"/>
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
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Background" Value="#2A2E36"/></Trigger>
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
            <Border x:Name="b" Background="Transparent" BorderBrush="#363C47" BorderThickness="1" CornerRadius="12" Padding="14,10">
              <ContentPresenter HorizontalAlignment="Left" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Background" Value="#2A2E36"/></Trigger>
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

    <!-- Barras de desplazamiento finas y oscuras, como en la web de Gemini -->
    <Style x:Key="PulgarScroll" TargetType="Thumb">
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Thumb">
            <Border x:Name="b" Background="#464C57" CornerRadius="3"/>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Background" Value="#6A707B"/></Trigger>
              <Trigger Property="IsDragging" Value="True"><Setter TargetName="b" Property="Background" Value="#767C87"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="HuecoScroll" TargetType="RepeatButton">
      <Setter Property="Focusable" Value="False"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="RepeatButton"><Border Background="Transparent"/></ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="ScrollBar">
      <Setter Property="Width" Value="8"/>
      <Setter Property="MinWidth" Value="8"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ScrollBar">
            <Track x:Name="PART_Track" IsDirectionReversed="True" Margin="1,2">
              <Track.DecreaseRepeatButton><RepeatButton Style="{StaticResource HuecoScroll}" Command="ScrollBar.PageUpCommand"/></Track.DecreaseRepeatButton>
              <Track.IncreaseRepeatButton><RepeatButton Style="{StaticResource HuecoScroll}" Command="ScrollBar.PageDownCommand"/></Track.IncreaseRepeatButton>
              <Track.Thumb><Thumb Style="{StaticResource PulgarScroll}" MinHeight="24"/></Track.Thumb>
            </Track>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
      <Style.Triggers>
        <Trigger Property="Orientation" Value="Horizontal">
          <Setter Property="Width" Value="Auto"/>
          <Setter Property="MinWidth" Value="0"/>
          <Setter Property="Height" Value="8"/>
          <Setter Property="MinHeight" Value="8"/>
          <Setter Property="Template">
            <Setter.Value>
              <ControlTemplate TargetType="ScrollBar">
                <Track x:Name="PART_Track" IsDirectionReversed="False" Margin="2,1">
                  <Track.DecreaseRepeatButton><RepeatButton Style="{StaticResource HuecoScroll}" Command="ScrollBar.PageLeftCommand"/></Track.DecreaseRepeatButton>
                  <Track.IncreaseRepeatButton><RepeatButton Style="{StaticResource HuecoScroll}" Command="ScrollBar.PageRightCommand"/></Track.IncreaseRepeatButton>
                  <Track.Thumb><Thumb Style="{StaticResource PulgarScroll}" MinWidth="24"/></Track.Thumb>
                </Track>
              </ControlTemplate>
            </Setter.Value>
          </Setter>
        </Trigger>
      </Style.Triggers>
    </Style>

    <Style x:Key="Seccion" TargetType="TextBlock">
      <Setter Property="Foreground" Value="#767C87"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Margin" Value="10,20,10,6"/>
    </Style>

    <Style x:Key="FilaYT" TargetType="ListViewItem">
      <Setter Property="Foreground" Value="#ECE8E1"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ListViewItem">
            <Border x:Name="b" Background="Transparent" Padding="0,5" BorderBrush="#2A2E36" BorderThickness="0,0,0,1">
              <GridViewRowPresenter VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Background" Value="#252930"/></Trigger>
              <Trigger Property="IsSelected" Value="True"><Setter TargetName="b" Property="Background" Value="#4A1E1E"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
      <Style.Triggers>
        <DataTrigger Binding="{Binding Seleccionable}" Value="False">
          <Setter Property="Foreground" Value="#767C87"/>
        </DataTrigger>
      </Style.Triggers>
    </Style>

    <Style x:Key="CabeceraYT" TargetType="GridViewColumnHeader">
      <Setter Property="Foreground" Value="#8C929C"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="GridViewColumnHeader">
            <Border Background="#181B20" BorderBrush="#2A2E36" BorderThickness="0,0,0,1" Padding="6,7">
              <ContentPresenter HorizontalAlignment="Left"/>
            </Border>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>

  <Grid>
    <Grid.ColumnDefinitions>
      <ColumnDefinition Width="270"/>
      <ColumnDefinition Width="*"/>
    </Grid.ColumnDefinitions>

    <!-- Barra lateral -->
    <Border x:Name="Lateral" Background="{StaticResource Sidebar}">
      <DockPanel Margin="10,14,10,12">
        <StackPanel DockPanel.Dock="Top">
          <StackPanel Orientation="Horizontal" Margin="10,2,0,16">
            <Border x:Name="LogoFondo" Width="30" Height="30" CornerRadius="8" Background="#C8A15A">
              <TextBlock x:Name="LogoLetra" Text="V" Foreground="#14161A" FontWeight="Bold" FontSize="17" HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <TextBlock x:Name="LogoTexto" Text="Valora" FontSize="18" FontWeight="SemiBold" Margin="10,0,0,0" VerticalAlignment="Center"/>
            <Button x:Name="BtnEstilo" Style="{StaticResource Plano}" Padding="6,4" Margin="6,0,0,0" VerticalAlignment="Center"
                    ToolTip="Cómo quieres que te responda Valora">
              <TextBlock x:Name="IcoEstilo" FontFamily="Segoe MDL2 Assets" Text="&#xE771;" FontSize="13" Foreground="#8C929C"/>
            </Button>
            <Button x:Name="BtnReiniciarTitulo" Margin="10,0,0,0" VerticalAlignment="Center" Cursor="Hand" Visibility="Collapsed"
                    ToolTip="Hay una versión nueva de Valora. Se aplica sola en cuanto no estés usando la ventana; pulsa para aplicarla ya.">
              <Button.Template>
                <ControlTemplate TargetType="Button">
                  <Border x:Name="Fondo" Background="#2E7D5A" CornerRadius="10" Padding="8,3">
                    <StackPanel Orientation="Horizontal">
                      <TextBlock FontFamily="Segoe MDL2 Assets" Text="&#xE72C;" FontSize="10" Foreground="White" VerticalAlignment="Center" Margin="0,0,5,0"/>
                      <TextBlock Text="Novedades" FontSize="11.5" FontWeight="SemiBold" Foreground="White" VerticalAlignment="Center"/>
                    </StackPanel>
                  </Border>
                  <ControlTemplate.Triggers>
                    <Trigger Property="IsMouseOver" Value="True">
                      <Setter TargetName="Fondo" Property="Background" Value="#38976D"/>
                    </Trigger>
                  </ControlTemplate.Triggers>
                </ControlTemplate>
              </Button.Template>
            </Button>
          </StackPanel>
          <Border Background="#20232A" CornerRadius="10" Padding="3" Margin="0,0,0,10">
            <UniformGrid Columns="2">
              <Button x:Name="BtnModoValora" Style="{StaticResource Plano}" Padding="8,6" HorizontalContentAlignment="Center" Background="#363C47">
                <StackPanel Orientation="Horizontal">
                  <TextBlock FontFamily="Segoe MDL2 Assets" Text="&#xE8BD;" FontSize="12" VerticalAlignment="Center" Margin="0,0,7,0"/>
                  <TextBlock Text="Valora"/>
                </StackPanel>
              </Button>
              <Button x:Name="BtnModoYT" Style="{StaticResource Plano}" Padding="8,6" HorizontalContentAlignment="Center"
                      ToolTip="Elegir vídeos del canal y volver a subirlos">
                <StackPanel Orientation="Horizontal">
                  <TextBlock FontFamily="Segoe MDL2 Assets" Text="&#xE714;" FontSize="12" VerticalAlignment="Center" Margin="0,0,7,0"/>
                  <TextBlock Text="YouTube"/>
                </StackPanel>
              </Button>
            </UniformGrid>
          </Border>
          <StackPanel x:Name="LateralArriba">
          <Button x:Name="BtnNueva" Style="{StaticResource Plano}" Background="#252930" Padding="10,9">
            <StackPanel Orientation="Horizontal">
              <TextBlock FontFamily="Segoe MDL2 Assets" Text="&#xE710;" Foreground="#C8A15A" VerticalAlignment="Center" Margin="0,0,10,0"/>
              <TextBlock Text="Nueva conversación"/>
            </StackPanel>
          </Button>

          <Button x:Name="BtnFichas" Style="{StaticResource Plano}" Margin="0,4,0,0" HorizontalContentAlignment="Stretch"
                  ToolTip="Fichas de Foticos Collection pendientes de tasar">
            <DockPanel>
              <Border x:Name="InsigniaEntorno" DockPanel.Dock="Right" CornerRadius="6" Padding="6,1" Background="#8A5A12" VerticalAlignment="Center">
                <TextBlock x:Name="TxtInsigniaEntorno" Text="PRE" FontSize="10.5" FontWeight="Bold" Foreground="White"/>
              </Border>
              <TextBlock FontFamily="Segoe MDL2 Assets" Text="&#xE8A1;" VerticalAlignment="Center" Margin="0,0,10,0"/>
              <TextBlock Text="Fichas por tasar" VerticalAlignment="Center"/>
            </DockPanel>
          </Button>

          <!-- Carpeta de trabajo, con los botones de cambiarla y de conectar otra siempre a la vista -->
          <Grid x:Name="FilaWs" Margin="0,1,0,0" Background="Transparent">
            <Button x:Name="BtnAbrirWs" Style="{StaticResource Plano}" HorizontalContentAlignment="Stretch">
              <DockPanel>
                <TextBlock FontFamily="Segoe MDL2 Assets" Text="&#xE8B7;" VerticalAlignment="Center" Margin="0,0,10,0"/>
                <TextBlock x:Name="TxtWs" TextTrimming="CharacterEllipsis" VerticalAlignment="Center" Margin="0,0,60,0"/>
              </DockPanel>
            </Button>
            <StackPanel x:Name="IconosWs" Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Center" Margin="0,0,4,0">
              <Button x:Name="BtnWs" Style="{StaticResource Plano}" Padding="6" ToolTip="Cambiar carpeta de trabajo">
                <TextBlock FontFamily="Segoe MDL2 Assets" Text="&#xE70F;" FontSize="12" Foreground="#969CA6"/>
              </Button>
              <Button x:Name="BtnCarpeta" Style="{StaticResource Plano}" Padding="6" ToolTip="Conectar otra carpeta">
                <TextBlock FontFamily="Segoe MDL2 Assets" Text="&#xE710;" FontSize="12" Foreground="#969CA6"/>
              </Button>
            </StackPanel>
          </Grid>
          <ItemsControl x:Name="ListaCarpetas"/>
          </StackPanel>
        </StackPanel>

        <StackPanel DockPanel.Dock="Bottom">
          <StackPanel x:Name="LateralAbajo">
          <Border Height="1" Background="#22262D" Margin="0,0,0,8"/>
          <DockPanel Margin="10,0,0,0">
            <Button x:Name="BtnTerminal" DockPanel.Dock="Right" Style="{StaticResource Plano}" Padding="8,6" ToolTip="Abrir terminal (agy)">
              <TextBlock FontFamily="Segoe MDL2 Assets" Text="&#xE756;" FontSize="13" Foreground="#ACB1B9"/>
            </Button>
            <CheckBox x:Name="ChkAuto" Foreground="#ACB1B9" FontSize="13" VerticalAlignment="Center"
                      Content="Modo automático" IsChecked="True" IsEnabled="False" ToolTipService.ShowOnDisabled="True"
                      ToolTip="Siempre activo: agy lee, crea archivos y ejecuta comandos sin pedir permiso"/>
          </DockPanel>
          <DockPanel Margin="6,6,0,0">
            <Button x:Name="BtnLogout" DockPanel.Dock="Right" Style="{StaticResource Plano}" Padding="8,6" ToolTip="Cerrar sesión de Google">
              <TextBlock FontFamily="Segoe MDL2 Assets" Text="&#xE7E8;" FontSize="13" Foreground="#ACB1B9"/>
            </Button>
            <Border Width="26" Height="26" CornerRadius="13" Background="#2C313A" VerticalAlignment="Center">
              <TextBlock FontFamily="Segoe MDL2 Assets" Text="&#xE77B;" FontSize="12" Foreground="#ACB1B9" HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <TextBlock x:Name="TxtCuenta" Text="—" Foreground="#CDCAC3" FontSize="12.5" TextTrimming="CharacterEllipsis"
                       VerticalAlignment="Center" Margin="10,0,0,0"/>
          </DockPanel>
          </StackPanel>
          <TextBlock x:Name="TxtEstado" Foreground="#8C929C" FontSize="12" TextWrapping="Wrap" Margin="10,10,8,0"/>
          <TextBlock x:Name="TxtVersion" Foreground="#5A606B" FontSize="11" Margin="10,4,8,0"/>
        </StackPanel>
        <DockPanel x:Name="LateralMedio" Margin="0,10,0,10">
          <Grid DockPanel.Dock="Top">
            <TextBlock Text="Conversaciones" Style="{StaticResource Seccion}"/>
            <TextBlock x:Name="TxtNumConv" Foreground="#5A606B" FontSize="11.5" HorizontalAlignment="Right" VerticalAlignment="Bottom" Margin="0,0,10,6"/>
          </Grid>
          <Border x:Name="CajaBuscarConv" DockPanel.Dock="Top" Background="#181B20" BorderBrush="#2A2E36" BorderThickness="1" CornerRadius="8" Margin="0,0,0,8" Padding="9,0" Visibility="Collapsed">
            <Grid>
              <TextBlock FontFamily="Segoe MDL2 Assets" Text="&#xE721;" FontSize="11" Foreground="#767C87" VerticalAlignment="Center"/>
              <TextBox x:Name="BuscarConv" Background="Transparent" BorderThickness="0" Foreground="#ECE8E1" CaretBrush="#ECE8E1"
                       FontSize="12.5" Padding="0,6" Margin="18,0,0,0" VerticalContentAlignment="Center"/>
              <TextBlock x:Name="BuscarConvPista" Text="Buscar conversación" Foreground="#6A707B" FontSize="12.5" Margin="20,0,0,0"
                         VerticalAlignment="Center" IsHitTestVisible="False"/>
            </Grid>
          </Border>
          <ScrollViewer x:Name="ScrollConv" VerticalScrollBarVisibility="Auto" Padding="0,0,2,0">
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
        <TextBlock Text="Hola 👋 ¿qué tasamos hoy?" FontSize="28" FontWeight="SemiBold" HorizontalAlignment="Center" Margin="0,0,0,8"/>
        <TextBlock Text="Arrastra fotos, documentos o carpetas a la ventana, o abre una ficha de «Fichas por tasar»." Foreground="#8C929C" HorizontalAlignment="Center" Margin="0,0,0,26"/>
        <UniformGrid x:Name="Sugerencias" Columns="2">
          <Button Style="{StaticResource Chip}" Margin="5" Tag="Mira las fotos adjuntas y haz un informe de tasación del inmueble: estado, superficie aproximada, calidades, desperfectos y una estimación de valor razonada.">
            <StackPanel><TextBlock Text="Tasar un inmueble" FontWeight="SemiBold"/><TextBlock Text="a partir de las fotos adjuntas" Foreground="#8C929C" FontSize="12.5"/></StackPanel>
          </Button>
          <Button Style="{StaticResource Chip}" Margin="5" Tag="Revisa la carpeta conectada y dime qué hay: tipos de archivo, de qué trata cada uno y qué falta.">
            <StackPanel><TextBlock Text="Revisar una carpeta" FontWeight="SemiBold"/><TextBlock Text="qué hay y qué falta" Foreground="#8C929C" FontSize="12.5"/></StackPanel>
          </Button>
          <Button Style="{StaticResource Chip}" Margin="5" Tag="Con lo que hemos visto, crea un informe en formato Word (.docx) en la carpeta de trabajo, con fotos y conclusiones.">
            <StackPanel><TextBlock Text="Crear un informe Word" FontWeight="SemiBold"/><TextBlock Text="en la carpeta de trabajo" Foreground="#8C929C" FontSize="12.5"/></StackPanel>
          </Button>
          <Button Style="{StaticResource Chip}" Margin="5" Tag="Compara las fotos adjuntas y dime las diferencias de estado entre ellas.">
            <StackPanel><TextBlock Text="Comparar fotos" FontWeight="SemiBold"/><TextBlock Text="diferencias de estado" Foreground="#8C929C" FontSize="12.5"/></StackPanel>
          </Button>
        </UniformGrid>
      </StackPanel>

      <!-- Caja de mensaje -->
      <Grid Grid.Row="1" MaxWidth="820" Margin="32,4,32,10">
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        <Border x:Name="BarraFicha" CornerRadius="14" Background="#1E2A24" BorderBrush="#2E7D5A" BorderThickness="1"
                Padding="12,8" Margin="0,0,0,8" Visibility="Collapsed">
          <Grid>
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="*"/>
              <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
              <Border x:Name="BarraEntorno" CornerRadius="6" Padding="6,1" Background="#8A5A12" VerticalAlignment="Center" Margin="0,0,10,0">
                <TextBlock x:Name="TxtBarraEntorno" Text="PRE" FontSize="10.5" FontWeight="Bold" Foreground="White"/>
              </Border>
              <TextBlock x:Name="TxtBarraFicha" Foreground="#ECE8E1" VerticalAlignment="Center" TextTrimming="CharacterEllipsis" MaxWidth="420"/>
              <TextBlock x:Name="TxtBarraEstado" Foreground="#8C929C" FontSize="12.5" VerticalAlignment="Center" Margin="12,0,0,0"/>
            </StackPanel>
            <StackPanel Grid.Column="1" Orientation="Horizontal">
              <Button x:Name="BtnAbrirFicha" Style="{StaticResource Plano}" Foreground="#ACB1B9" Padding="10,5" FontSize="12.5" Content="Abrir en Foticos Collection"/>
              <Button x:Name="BtnRevisarEnviar" Style="{StaticResource Plano}" Background="#2E7D5A" Foreground="White" Padding="14,6"
                      FontWeight="SemiBold" Margin="6,0,0,0" Content="Revisar y enviar tasación" IsEnabled="False"/>
            </StackPanel>
          </Grid>
        </Border>
        <Border Grid.Row="1" CornerRadius="22" Background="#2C313A" Padding="10,8,10,8">
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
                <TextBlock FontFamily="Segoe MDL2 Assets" Text="&#xE723;" FontSize="16" Foreground="#CDCAC3"/>
              </Button>
              <Grid Grid.Column="1" Margin="6,0">
                <TextBox x:Name="Prompt" Background="Transparent" BorderThickness="0" Foreground="#ECE8E1" CaretBrush="#ECE8E1"
                         FontSize="15" TextWrapping="Wrap" AcceptsReturn="False" MaxHeight="200" MinHeight="36"
                         VerticalScrollBarVisibility="Auto" VerticalContentAlignment="Center" Padding="2,8"/>
                <TextBlock x:Name="Placeholder" Text="Pregunta lo que quieras" Foreground="#8C929C" FontSize="15"
                           IsHitTestVisible="False" VerticalAlignment="Center" Margin="5,0"/>
              </Grid>
              <Button x:Name="BtnEnviar" Grid.Column="2" Style="{StaticResource Redondo}" Background="#C8A15A" VerticalAlignment="Bottom" ToolTip="Enviar (Enter)">
                <TextBlock x:Name="IcoEnviar" FontFamily="Segoe MDL2 Assets" Text="&#xE74A;" FontSize="16" Foreground="#14161A" FontWeight="Bold"/>
              </Button>
            </Grid>
          </Grid>
        </Border>
        <TextBlock Grid.Row="2" Text="Enter envía · Shift+Enter nueva línea · Valora puede equivocarse: revisa lo importante."
                   Foreground="#6A707B" FontSize="11.5" HorizontalAlignment="Center" Margin="0,8,0,0"/>
      </Grid>
    </Grid>

    <!-- YouTube: elegir vídeos del canal y volver a subirlos (habla con la web de Documents\youtube) -->
    <Grid x:Name="PanelYT" Grid.Column="1" Background="#1F1B1B" Visibility="Collapsed" Panel.ZIndex="4">
      <DockPanel Margin="24,18,24,14">
        <Grid DockPanel.Dock="Top" Margin="0,0,0,10">
          <StackPanel>
            <TextBlock Text="Resubir vídeos de YouTube" FontSize="20" FontWeight="SemiBold"/>
            <TextBlock x:Name="TxtYTResumen" Foreground="#8C929C" FontSize="12.5" Margin="0,2,0,0"/>
            <StackPanel Orientation="Horizontal" Margin="0,8,0,0">
              <Border x:Name="ChipYTServidor" CornerRadius="10" Padding="10,4" Background="#363C47" VerticalAlignment="Center" Margin="0,0,6,0">
                <TextBlock x:Name="TxtYTServidorChip" Text="Servidor…" FontSize="12.5" Foreground="White"/>
              </Border>
              <Border x:Name="ChipYTCanal" CornerRadius="10" Padding="10,4" Background="#4A2323" VerticalAlignment="Center">
                <TextBlock x:Name="TxtYTCanal" Text="Sin conectar" FontSize="12.5" Foreground="White"/>
              </Border>
            </StackPanel>
          </StackPanel>
          <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Top">
            <Button x:Name="BtnYTAbrirCanal" Style="{StaticResource Plano}" Foreground="#ACB1B9" Content="Abrir canal ↗" Visibility="Collapsed"
                    ToolTip="Los últimos vídeos del canal en YouTube Studio (también los privados)"/>
            <Button x:Name="BtnYTVerResubida" Style="{StaticResource Plano}" Foreground="#ECE8E1" Content="Ver resubida" Visibility="Collapsed"
                    ToolTip="En qué va cada vídeo de la última resubida, con su compilación y su enlace"/>
            <Button x:Name="BtnYTConectar" Style="{StaticResource Plano}" Foreground="#ACB1B9" Margin="6,0,0,0" Content="Conectar YouTube"
                    ToolTip="Entrar con la cuenta de Google dueña del canal al que se suben los vídeos"/>
            <Button x:Name="BtnYTActualizar" Style="{StaticResource Plano}" Foreground="#ACB1B9" Content="Actualizar listado"
                    ToolTip="Vuelve a leer la lista de vídeos del canal"/>
            <Button x:Name="BtnYTServidor" Style="{StaticResource Plano}" Foreground="#ACB1B9" Content="Servidor"
                    ToolTip="Dirección de la web, usuario y contraseña"/>
          </StackPanel>
        </Grid>

        <Border x:Name="ChipYTTrabajo" DockPanel.Dock="Top" CornerRadius="10" Padding="12,6" Margin="0,0,0,10" Background="#1E2A24"
                HorizontalAlignment="Left" Visibility="Collapsed">
          <TextBlock x:Name="TxtYTTrabajo" FontSize="13" TextWrapping="Wrap"/>
        </Border>

        <Border x:Name="YTServidor" DockPanel.Dock="Top" Background="#1C1F25" CornerRadius="12" Padding="14,12" Margin="0,0,0,12" Visibility="Collapsed">
          <StackPanel>
            <TextBlock Text="Conexión con la web de resubida" FontWeight="SemiBold" Margin="0,0,0,8"/>
            <TextBlock Text="Dirección de la web (te la da Rubén; en su propio PC se puede dejar vacía):" Foreground="#ACB1B9" FontSize="12.5" Margin="0,0,0,4"/>
            <Border Background="#121418" CornerRadius="8" BorderBrush="#363C47" BorderThickness="1" Padding="8,2" Margin="0,0,0,8">
              <TextBox x:Name="YTUrl" Background="Transparent" BorderThickness="0" Foreground="#ECE8E1" CaretBrush="#ECE8E1" Padding="0,6"/>
            </Border>
            <Grid>
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="Auto"/>
              </Grid.ColumnDefinitions>
              <StackPanel Margin="0,0,8,0">
                <TextBlock Text="Usuario" Foreground="#ACB1B9" FontSize="12.5" Margin="0,0,0,4"/>
                <Border Background="#121418" CornerRadius="8" BorderBrush="#363C47" BorderThickness="1" Padding="8,2">
                  <TextBox x:Name="YTUsuario" Background="Transparent" BorderThickness="0" Foreground="#ECE8E1" CaretBrush="#ECE8E1" Padding="0,6"/>
                </Border>
              </StackPanel>
              <StackPanel Grid.Column="1" Margin="0,0,8,0">
                <TextBlock Text="Contraseña" Foreground="#ACB1B9" FontSize="12.5" Margin="0,0,0,4"/>
                <Border Background="#121418" CornerRadius="8" BorderBrush="#363C47" BorderThickness="1" Padding="8,2">
                  <PasswordBox x:Name="YTClave" Background="Transparent" BorderThickness="0" Foreground="#ECE8E1" CaretBrush="#ECE8E1" Padding="0,6"/>
                </Border>
              </StackPanel>
              <Button x:Name="BtnYTEntrar" Grid.Column="2" Style="{StaticResource Plano}" Background="#ECE8E1" Foreground="#14161A"
                      Padding="16,7" FontWeight="SemiBold" VerticalAlignment="Bottom" Content="Entrar"/>
            </Grid>
            <TextBlock x:Name="TxtYTServidorEstado" Foreground="#8C929C" FontSize="12.5" Margin="0,8,0,0" TextWrapping="Wrap"
                       Text="Valora guarda la sesión cifrada para tu usuario de Windows: solo hay que entrar una vez."/>
          </StackPanel>
        </Border>

        <Border x:Name="YTCred" DockPanel.Dock="Top" Background="#1C1F25" CornerRadius="12" Padding="14,12" Margin="0,0,0,12" Visibility="Collapsed">
          <StackPanel>
            <Grid Margin="0,0,0,6">
              <TextBlock Text="Conectar YouTube" FontWeight="SemiBold" FontSize="15"/>
              <Button x:Name="BtnYTCredCerrar" Style="{StaticResource Plano}" Padding="6" HorizontalAlignment="Right">
                <TextBlock FontFamily="Segoe MDL2 Assets" Text="&#xE711;" FontSize="11"/>
              </Button>
            </Grid>
            <TextBlock x:Name="TxtYTCredEstado" TextWrapping="Wrap" FontSize="13" Margin="0,0,0,10"/>

            <StackPanel Orientation="Horizontal" Margin="0,0,0,8">
              <Button x:Name="BtnYTPaso4" Style="{StaticResource Plano}" Background="#2A2E36" Padding="12,6" FontSize="13"
                      Tag="https://console.cloud.google.com/apis/credentials" Content="1. Coger Client ID y secret en Google Cloud ↗"
                      ToolTip="Con este panel abierto, copia el ID y el secreto con el botón de copiar de Google: Valora los rellena y los guarda sola"/>
              <Button x:Name="BtnYTPaso2" Style="{StaticResource Plano}" Foreground="#8C929C" Padding="8,6" FontSize="12" Margin="6,0,0,0"
                      Tag="https://console.cloud.google.com/apis/library/youtube.googleapis.com" Content="¿API sin activar?"
                      ToolTip="Activa YouTube Data API v3 en el proyecto (solo la primera vez)"/>
            </StackPanel>
            <Grid Margin="0,0,0,4">
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="3*"/>
                <ColumnDefinition Width="2*"/>
                <ColumnDefinition Width="Auto"/>
              </Grid.ColumnDefinitions>
              <StackPanel Margin="0,0,8,0">
                <TextBlock Text="Client ID" Foreground="#ACB1B9" FontSize="12.5" Margin="0,0,0,4"/>
                <Border Background="#121418" CornerRadius="8" BorderBrush="#363C47" BorderThickness="1" Padding="8,2">
                  <TextBox x:Name="YTClientId" Background="Transparent" BorderThickness="0" Foreground="#ECE8E1" CaretBrush="#ECE8E1" Padding="0,6"
                           ToolTip="Acaba en .apps.googleusercontent.com. También se puede pegar aquí el JSON entero que descarga Google."/>
                </Border>
              </StackPanel>
              <StackPanel Grid.Column="1" Margin="0,0,8,0">
                <TextBlock Text="Client secret" Foreground="#ACB1B9" FontSize="12.5" Margin="0,0,0,4"/>
                <Border Background="#121418" CornerRadius="8" BorderBrush="#363C47" BorderThickness="1" Padding="8,2">
                  <PasswordBox x:Name="YTClientSecret" Background="Transparent" BorderThickness="0" Foreground="#ECE8E1" CaretBrush="#ECE8E1" Padding="0,6"/>
                </Border>
              </StackPanel>
              <Button x:Name="BtnYTGuardarCred" Grid.Column="2" Style="{StaticResource Plano}" Background="#ECE8E1" Foreground="#14161A"
                      Padding="14,7" FontWeight="SemiBold" VerticalAlignment="Bottom" Content="Guardar en el servidor"/>
            </Grid>

            <Button x:Name="BtnYTLoginGoogle" Style="{StaticResource Plano}" Background="#C4302B" Foreground="White" Padding="14,7"
                    FontWeight="SemiBold" Margin="0,12,0,0" HorizontalAlignment="Left" Content="2. Conectar con la cuenta del canal"/>
          </StackPanel>
        </Border>

        <Border x:Name="YTAviso" DockPanel.Dock="Top" Background="#2A1A1A" BorderBrush="#C4302B" BorderThickness="1" CornerRadius="12"
                Padding="14,12" Margin="0,0,0,12" Visibility="Collapsed">
          <StackPanel>
            <TextBlock x:Name="TxtYTAviso" TextWrapping="Wrap" LineHeight="21"/>
            <StackPanel x:Name="YTCodigoCaja" Orientation="Horizontal" Margin="0,10,0,0">
              <TextBox x:Name="TxtYTCodigo" IsReadOnly="True" FontFamily="Consolas" FontSize="24" FontWeight="Bold" Background="Transparent"
                       BorderThickness="0" Foreground="White" VerticalAlignment="Center" Margin="0,0,14,0"/>
              <Button x:Name="BtnYTCopiar" Style="{StaticResource Plano}" Background="#ECE8E1" Foreground="#14161A" Padding="12,6"
                      FontWeight="SemiBold" Content="Copiar código" VerticalAlignment="Center"/>
              <Button x:Name="BtnYTAbrirGoogle" Style="{StaticResource Plano}" Background="#C4302B" Foreground="White" Padding="12,6"
                      Margin="8,0,0,0" FontWeight="SemiBold" Content="Abrir la página de Google" VerticalAlignment="Center"/>
            </StackPanel>
          </StackPanel>
        </Border>

        <Grid DockPanel.Dock="Top" Margin="0,0,0,8">
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="Auto"/>
            <ColumnDefinition Width="Auto"/>
            <ColumnDefinition Width="Auto"/>
          </Grid.ColumnDefinitions>
          <Border Background="#181B20" CornerRadius="10" BorderBrush="#363C47" BorderThickness="1" Padding="10,2">
            <Grid>
              <TextBox x:Name="YTBuscar" Background="Transparent" BorderThickness="0" Foreground="#ECE8E1" CaretBrush="#ECE8E1" Padding="0,7"/>
              <TextBlock x:Name="YTBuscarPista" Text="Buscar por título o fecha" Foreground="#6A707B" IsHitTestVisible="False" VerticalAlignment="Center" Margin="2,0"/>
            </Grid>
          </Border>
          <ComboBox x:Name="YTPlaylist" Grid.Column="1" Margin="8,0,0,0" MinWidth="170" VerticalContentAlignment="Center"/>
          <ComboBox x:Name="YTTipo" Grid.Column="2" Margin="8,0,0,0" MinWidth="130" VerticalContentAlignment="Center">
            <ComboBoxItem Content="Vídeos y shorts" Tag="" IsSelected="True"/>
            <ComboBoxItem Content="Solo vídeos" Tag="Vídeo"/>
            <ComboBoxItem Content="Solo shorts" Tag="Short"/>
          </ComboBox>
          <ComboBox x:Name="YTEstado" Grid.Column="3" Margin="8,0,0,0" MinWidth="140" VerticalContentAlignment="Center">
            <ComboBoxItem Content="Cualquier estado" Tag="" IsSelected="True"/>
            <ComboBoxItem Content="Sin resubir" Tag="no"/>
            <ComboBoxItem Content="Ya resubidos" Tag="si"/>
            <ComboBoxItem Content="En la cola" Tag="cola"/>
          </ComboBox>
        </Grid>

        <Grid DockPanel.Dock="Top" Margin="0,0,0,8">
          <StackPanel Orientation="Horizontal">
            <TextBlock x:Name="TxtYTSel" Foreground="#CDCAC3" FontSize="13" VerticalAlignment="Center" Margin="2,0,10,0"/>
            <Button x:Name="BtnYTTodos" Style="{StaticResource Plano}" Foreground="#ACB1B9" Padding="8,5" FontSize="13" Content="Seleccionar los filtrados"/>
            <Button x:Name="BtnYTNinguno" Style="{StaticResource Plano}" Foreground="#ACB1B9" Padding="8,5" FontSize="13" Content="Quitar selección"/>
          </StackPanel>
          <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
            <ComboBox x:Name="YTPrivacidad" MinWidth="110" VerticalContentAlignment="Center" ToolTip="Cómo quedan los vídeos nuevos">
              <ComboBoxItem Content="Privados" Tag="private" IsSelected="True"/>
              <ComboBoxItem Content="Ocultos" Tag="unlisted"/>
              <ComboBoxItem Content="Públicos" Tag="public"/>
            </ComboBox>
            <CheckBox x:Name="ChkYTEntradaSalida" IsChecked="True" Foreground="#ECE8E1" VerticalAlignment="Center" Margin="12,0,0,0" Content="Con entrada y salida"
                      ToolTip="Antes de subirlo, cada vídeo se rehace con la entrada animada (fecha) y la salida (versículo y canal)"/>
            <Button x:Name="BtnYTResubir" Style="{StaticResource Plano}" Background="#C4302B" Foreground="White" Padding="14,6"
                    Margin="8,0,0,0" FontWeight="SemiBold" Content="Resubir seleccionados" IsEnabled="False"/>
          </StackPanel>
        </Grid>

        <TextBlock DockPanel.Dock="Bottom" Foreground="#6A707B" FontSize="11.5" Margin="2,6,0,0"
                   Text="Ctrl o Mayús + clic para elegir varios · doble clic abre el vídeo en YouTube"/>

        <Grid>
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="300"/>
          </Grid.ColumnDefinitions>
          <ListView x:Name="YTLista" Background="#181B20" BorderThickness="0" Foreground="#ECE8E1" SelectionMode="Extended"
                    ItemContainerStyle="{StaticResource FilaYT}" VirtualizingPanel.IsVirtualizing="True" VirtualizingPanel.VirtualizationMode="Recycling">
            <ListView.View>
              <GridView ColumnHeaderContainerStyle="{StaticResource CabeceraYT}">
                <GridViewColumn Header="Subido" Width="88" DisplayMemberBinding="{Binding Fecha}"/>
                <GridViewColumn Header="Título" Width="230" DisplayMemberBinding="{Binding Titulo}"/>
                <GridViewColumn Header="Playlist" Width="100" DisplayMemberBinding="{Binding Playlists}"/>
                <GridViewColumn Header="Tipo" Width="60" DisplayMemberBinding="{Binding Tipo}"/>
                <GridViewColumn Header="Vistas" Width="70" DisplayMemberBinding="{Binding Vistas}"/>
                <GridViewColumn Header="Estado" Width="130" DisplayMemberBinding="{Binding Estado}"/>
              </GridView>
            </ListView.View>
          </ListView>
          <Border Grid.Column="1" Background="#181B20" CornerRadius="12" Padding="14,12" Margin="12,0,0,0">
            <DockPanel>
              <TextBlock DockPanel.Dock="Top" Text="Cola de resubida" FontWeight="SemiBold" FontSize="15"/>
              <TextBlock x:Name="TxtYTCola" DockPanel.Dock="Top" Foreground="#8C929C" FontSize="12.5" Margin="0,4,0,8" TextWrapping="Wrap" Text="Vacía."/>
              <ScrollViewer VerticalScrollBarVisibility="Auto">
                <StackPanel x:Name="YTCola"/>
              </ScrollViewer>
            </DockPanel>
          </Border>
        </Grid>
      </DockPanel>

      <!-- Seguimiento de la última resubida: en qué paso va cada vídeo, su compilación y su enlace -->
      <Grid x:Name="YTResubida" Background="#CC0E1014" Visibility="Collapsed">
        <Border Width="640" MaxHeight="560" Background="#252930" CornerRadius="18" Padding="22,18" BorderBrush="#363C47" BorderThickness="1"
                VerticalAlignment="Center" HorizontalAlignment="Center">
          <DockPanel>
            <Grid DockPanel.Dock="Top" Margin="0,0,0,4">
              <TextBlock Text="Resubida" FontSize="20" FontWeight="SemiBold"/>
              <Button x:Name="BtnYTResubidaCerrar" Style="{StaticResource Plano}" Padding="6" HorizontalAlignment="Right" ToolTip="Cerrar (sigue trabajando por detrás)">
                <TextBlock FontFamily="Segoe MDL2 Assets" Text="&#xE711;" FontSize="11"/>
              </Button>
            </Grid>
            <TextBlock x:Name="TxtYTResubida" DockPanel.Dock="Top" Foreground="#8C929C" FontSize="13" Margin="0,0,0,6" TextWrapping="Wrap"/>
            <ProgressBar x:Name="BarraYTResubida" DockPanel.Dock="Top" Height="6" Minimum="0" Maximum="100" Margin="0,0,0,14"
                         Background="#363C47" Foreground="#C4302B" BorderThickness="0"/>
            <TextBlock DockPanel.Dock="Bottom" Foreground="#6A707B" FontSize="11.5" Margin="0,10,0,0" TextWrapping="Wrap"
                       Text="Se puede cerrar: la resubida sigue en el servidor y este panel se vuelve a abrir con «Ver resubida»."/>
            <ScrollViewer VerticalScrollBarVisibility="Auto">
              <StackPanel x:Name="YTResubidaLista"/>
            </ScrollViewer>
          </DockPanel>
        </Border>
      </Grid>
    </Grid>

    <!-- Cómo quiere el usuario que responda Valora -->
    <Grid x:Name="PanelEstilo" Grid.ColumnSpan="2" Background="#CC0E1014" Visibility="Collapsed" Panel.ZIndex="25">
      <Border Width="620" Background="#252930" CornerRadius="18" Padding="24,20" BorderBrush="#363C47" BorderThickness="1"
              VerticalAlignment="Center" HorizontalAlignment="Center">
        <StackPanel>
          <TextBlock Text="Cómo quieres que te responda" FontSize="20" FontWeight="SemiBold"/>
          <TextBlock Text="Se aplica a todas tus preguntas, en todas las conversaciones." Foreground="#8C929C" FontSize="13" Margin="0,4,0,12"/>
          <WrapPanel x:Name="AtajosEstilo" Margin="0,0,0,10">
            <Button Style="{StaticResource Chip}" Margin="0,0,6,6" Tag="Responde breve y al grano, sin introducciones ni despedidas." Content="Breve y directo"/>
            <Button Style="{StaticResource Chip}" Margin="0,0,6,6" Tag="Explica con detalle y razona cada conclusión." Content="Detallado"/>
            <Button Style="{StaticResource Chip}" Margin="0,0,6,6" Tag="Usa tablas cuando compares o enumeres datos." Content="Con tablas"/>
            <Button Style="{StaticResource Chip}" Margin="0,0,6,6" Tag="Usa un tono profesional y formal, de informe de tasación." Content="Tono formal"/>
            <Button Style="{StaticResource Chip}" Margin="0,0,6,6" Tag="Termina siempre con un precio estimado en euros (mínimo y máximo) y en qué te basas." Content="Siempre con precio"/>
          </WrapPanel>
          <Border Background="#181B20" CornerRadius="10" BorderBrush="#363C47" BorderThickness="1" Padding="10,4">
            <TextBox x:Name="TxtEstilo" Background="Transparent" BorderThickness="0" Foreground="#ECE8E1" CaretBrush="#ECE8E1" FontSize="14"
                     TextWrapping="Wrap" AcceptsReturn="True" MinHeight="140" MaxHeight="300" VerticalScrollBarVisibility="Auto" Padding="0,6"/>
          </Border>
          <Grid Margin="0,14,0,0">
            <Button x:Name="BtnEstiloBorrar" Style="{StaticResource Plano}" Foreground="#ACB1B9" Padding="10,8" HorizontalAlignment="Left" Content="Borrar indicaciones" ToolTip="Valora vuelve a responder como siempre"/>
            <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
              <Button x:Name="BtnEstiloCancelar" Style="{StaticResource Plano}" Foreground="#ECE8E1" Padding="14,8" Content="Cancelar"/>
              <Button x:Name="BtnEstiloGuardar" Style="{StaticResource Plano}" Background="#ECE8E1" Foreground="#14161A" Padding="16,8"
                      Margin="8,0,0,0" FontWeight="SemiBold" Content="Guardar"/>
            </StackPanel>
          </Grid>
        </StackPanel>
      </Border>
    </Grid>

    <!-- Fichas por tasar de Foticos Collection -->
    <Grid x:Name="PanelFC" Grid.ColumnSpan="2" Background="#CC0E1014" Visibility="Collapsed" Panel.ZIndex="20">
      <Border Width="760" MaxHeight="680" Background="#252930" CornerRadius="18" Padding="24,20" BorderBrush="#363C47" BorderThickness="1"
              VerticalAlignment="Center" HorizontalAlignment="Center">
        <DockPanel>
          <Grid DockPanel.Dock="Top" Margin="0,0,0,14">
            <StackPanel Orientation="Horizontal">
              <TextBlock Text="Fichas por tasar" FontSize="20" FontWeight="SemiBold" VerticalAlignment="Center"/>
              <Border x:Name="PanelEntorno" CornerRadius="6" Padding="8,2" Margin="12,0,0,0" Background="#8A5A12" VerticalAlignment="Center">
                <TextBlock x:Name="TxtPanelEntorno" Text="PRE" FontSize="12" FontWeight="Bold" Foreground="White"/>
              </Border>
            </StackPanel>
            <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
              <Button x:Name="BtnConexionFC" Style="{StaticResource Plano}" Foreground="#ACB1B9" Content="Conexión"/>
              <Button x:Name="BtnCerrarFC" Style="{StaticResource Plano}" Padding="8">
                <TextBlock FontFamily="Segoe MDL2 Assets" Text="&#xE711;" FontSize="12"/>
              </Button>
            </StackPanel>
          </Grid>

          <Border x:Name="ConexionFC" DockPanel.Dock="Top" Background="#1C1F25" CornerRadius="12" Padding="14,12" Margin="0,0,0,14" Visibility="Collapsed">
            <StackPanel>
              <TextBlock Text="Conexión con Foticos Collection" FontWeight="SemiBold" Margin="0,0,0,8"/>
              <StackPanel Orientation="Horizontal" Margin="0,0,0,8">
                <RadioButton x:Name="RadPRE" Content="PRE (stg.foticoscollection.com)" Foreground="#ECE8E1" Margin="0,0,18,0" GroupName="Entorno"/>
                <RadioButton x:Name="RadPRO" Content="PRO (foticoscollection.com)" Foreground="#ECE8E1" GroupName="Entorno"/>
              </StackPanel>
              <TextBlock Text="Clave de Valora (te la da el administrador; se guarda cifrada para tu usuario de Windows):" Foreground="#ACB1B9" FontSize="12.5" Margin="0,0,0,4"/>
              <Grid>
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="*"/>
                  <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <Border Background="#121418" CornerRadius="8" BorderBrush="#363C47" BorderThickness="1" Padding="8,2">
                  <PasswordBox x:Name="ClaveFC" Background="Transparent" BorderThickness="0" Foreground="#ECE8E1" CaretBrush="#ECE8E1" Padding="0,6"/>
                </Border>
                <Button x:Name="BtnGuardarConexion" Grid.Column="1" Style="{StaticResource Plano}" Background="#ECE8E1" Foreground="#14161A"
                        Padding="14,7" Margin="8,0,0,0" FontWeight="SemiBold" Content="Guardar y probar"/>
              </Grid>
            </StackPanel>
          </Border>

          <Grid DockPanel.Dock="Top" Margin="0,0,0,10">
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="*"/>
              <ColumnDefinition Width="Auto"/>
              <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <Border Background="#181B20" CornerRadius="10" BorderBrush="#363C47" BorderThickness="1" Padding="10,2">
              <TextBox x:Name="BuscarFC" Background="Transparent" BorderThickness="0" Foreground="#ECE8E1" CaretBrush="#ECE8E1" Padding="0,7"
                       ToolTip="Nombre, modelo, nº de serie o número de ficha"/>
            </Border>
            <ComboBox x:Name="EstadoFC" Grid.Column="1" Margin="8,0,0,0" MinWidth="150" VerticalContentAlignment="Center">
              <ComboBoxItem Content="Todos los estados" IsSelected="True"/>
              <ComboBoxItem Content="INGRESO"/>
              <ComboBoxItem Content="PREINGRESO"/>
              <ComboBoxItem Content="PRESUPUESTO"/>
            </ComboBox>
            <Button x:Name="BtnBuscarFC" Grid.Column="2" Style="{StaticResource Plano}" Background="#ECE8E1" Foreground="#14161A" Padding="14,7"
                    Margin="8,0,0,0" FontWeight="SemiBold" Content="Buscar"/>
          </Grid>

          <StackPanel DockPanel.Dock="Bottom" Orientation="Horizontal" Margin="0,10,0,0">
            <Button x:Name="BtnMasFC" Style="{StaticResource Plano}" Foreground="#ACB1B9" Content="Cargar más" Visibility="Collapsed"/>
            <TextBlock x:Name="EstadoPanelFC" Foreground="#8C929C" FontSize="12.5" VerticalAlignment="Center" Margin="10,0,0,0" TextWrapping="Wrap"/>
          </StackPanel>

          <ScrollViewer x:Name="ScrollFC" VerticalScrollBarVisibility="Auto">
            <StackPanel x:Name="ListaFC"/>
          </ScrollViewer>
        </DockPanel>
      </Border>
    </Grid>

    <!-- Confirmación de envío de la tasación -->
    <Grid x:Name="PanelConfirmar" Grid.ColumnSpan="2" Background="#D90E1014" Visibility="Collapsed" Panel.ZIndex="30">
      <Border Width="820" MaxHeight="700" Background="#252930" CornerRadius="18" Padding="26,22" BorderBrush="#363C47" BorderThickness="1"
              VerticalAlignment="Center" HorizontalAlignment="Center">
        <DockPanel>
          <StackPanel DockPanel.Dock="Top" Margin="0,0,0,12">
            <StackPanel Orientation="Horizontal">
              <TextBlock Text="Enviar tasación a Foticos Collection" FontSize="20" FontWeight="SemiBold" VerticalAlignment="Center"/>
              <Border x:Name="ConfEntorno" CornerRadius="6" Padding="8,2" Margin="12,0,0,0" Background="#8A5A12" VerticalAlignment="Center">
                <TextBlock x:Name="TxtConfEntorno" Text="PRE" FontSize="12" FontWeight="Bold" Foreground="White"/>
              </Border>
            </StackPanel>
            <TextBlock x:Name="TxtConfPieza" FontSize="15" Margin="0,8,0,0" TextWrapping="Wrap"/>
            <TextBlock x:Name="TxtConfAviso" Foreground="#E8A33D" FontSize="13" Margin="0,6,0,0" TextWrapping="Wrap"/>
          </StackPanel>

          <StackPanel DockPanel.Dock="Bottom" Margin="0,14,0,0">
            <TextBlock x:Name="TxtConfEstado" Foreground="#8C929C" FontSize="13" Margin="0,0,0,10" TextWrapping="Wrap"/>
            <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
              <Button x:Name="BtnConfCancelar" Style="{StaticResource Plano}" Foreground="#ECE8E1" Padding="16,9" Content="Cancelar"/>
              <Button x:Name="BtnConfEnviar" Style="{StaticResource Plano}" Background="#2E7D5A" Foreground="White" Padding="18,9"
                      Margin="10,0,0,0" FontWeight="SemiBold" Content="Sí, enviar tasación"/>
            </StackPanel>
          </StackPanel>

          <ScrollViewer VerticalScrollBarVisibility="Auto">
            <Grid x:Name="TablaCambios"/>
          </ScrollViewer>
        </DockPanel>
      </Border>
    </Grid>

    <!-- Inicio de sesión con Google -->
    <Grid x:Name="Login" Grid.ColumnSpan="2" Background="#E60E1014" Visibility="Collapsed">
      <Border Width="500" Background="#252930" CornerRadius="18" Padding="34,30" VerticalAlignment="Center" HorizontalAlignment="Center"
              BorderBrush="#363C47" BorderThickness="1">
        <StackPanel>
          <Border Width="52" Height="52" CornerRadius="14" Background="#2E7D5A" HorizontalAlignment="Left" Margin="0,0,0,18">
            <TextBlock Text="V" FontSize="28" FontWeight="Bold" Foreground="White" HorizontalAlignment="Center" VerticalAlignment="Center"/>
          </Border>
          <TextBlock Text="Conecta tu cuenta de Google" FontSize="22" FontWeight="SemiBold" Margin="0,0,0,8"/>
          <TextBlock x:Name="LoginTexto" TextWrapping="Wrap" Foreground="#ACB1B9" FontSize="14" LineHeight="21" Margin="0,0,0,22"
                     Text="Valora funciona con Google Antigravity. Para empezar, entra con tu cuenta de Google. Solo hace falta la primera vez."/>

          <Button x:Name="BtnLogin" Style="{StaticResource Plano}" Background="#ECE8E1" Foreground="#14161A" Padding="18,12"
                  HorizontalContentAlignment="Center" FontSize="15" FontWeight="SemiBold" Content="Iniciar sesión con Google"/>

          <StackPanel x:Name="LoginCodigo" Visibility="Collapsed">
            <TextBlock TextWrapping="Wrap" Foreground="#ECE8E1" FontSize="14" LineHeight="21" Margin="0,0,0,12"
                       Text="Tienes 1 minuto:&#x0a;1. En el navegador, elige tu cuenta de Google y acepta.&#x0a;2. Si al final Google te enseña un código, cópialo y pégalo aquí:"/>
            <Border Background="#181B20" CornerRadius="10" BorderBrush="#363C47" BorderThickness="1" Padding="10,4">
              <TextBox x:Name="CodigoLogin" Background="Transparent" BorderThickness="0" Foreground="#ECE8E1" CaretBrush="#ECE8E1"
                       FontSize="14" Padding="0,8" FontFamily="Consolas"/>
            </Border>
            <Grid Margin="0,14,0,0">
              <Button x:Name="BtnReabrir" Style="{StaticResource Plano}" Foreground="#ACB1B9" Padding="8,8" Content="Abrir otra vez el navegador" HorizontalAlignment="Left"/>
              <Button x:Name="BtnCodigo" Style="{StaticResource Plano}" Background="#ECE8E1" Foreground="#14161A" Padding="18,9"
                      FontWeight="SemiBold" Content="Continuar" HorizontalAlignment="Right"/>
            </Grid>
          </StackPanel>

          <TextBlock x:Name="LoginEstado" TextWrapping="Wrap" Foreground="#8C929C" FontSize="13" Margin="0,16,0,0"/>
          <Button x:Name="BtnLoginLuego" Style="{StaticResource Plano}" Foreground="#8C929C" Padding="8,6" FontSize="12.5"
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
               'TxtCuenta','BtnLogout','FilaWs','IconosWs','ListaConv','TxtNumConv','CajaBuscarConv','BuscarConv','BuscarConvPista','ScrollConv','AvisoVersion','BtnReiniciar','BtnReiniciarTitulo','TxtVersion',
               'BtnFichas','InsigniaEntorno','TxtInsigniaEntorno','BarraFicha','BarraEntorno','TxtBarraEntorno','TxtBarraFicha',
               'TxtBarraEstado','BtnAbrirFicha','BtnRevisarEnviar','PanelFC','PanelEntorno','TxtPanelEntorno','BtnConexionFC',
               'BtnCerrarFC','ConexionFC','RadPRE','RadPRO','ClaveFC','BtnGuardarConexion','BuscarFC','EstadoFC','BtnBuscarFC',
               'BtnMasFC','EstadoPanelFC','ListaFC','PanelConfirmar','ConfEntorno','TxtConfEntorno','TxtConfPieza','TxtConfAviso',
               'TxtConfEstado','BtnConfCancelar','BtnConfEnviar','TablaCambios',
               'BtnModoValora','BtnModoYT','PanelYT','TxtYTResumen','ChipYTCanal','TxtYTCanal','BtnYTConectar','BtnYTActualizar',
               'BtnYTServidor','ChipYTTrabajo','TxtYTTrabajo','YTServidor','YTUrl','YTUsuario','YTClave','BtnYTEntrar',
               'TxtYTServidorEstado','YTAviso','TxtYTAviso','YTCodigoCaja','TxtYTCodigo','BtnYTCopiar','BtnYTAbrirGoogle',
               'YTBuscar','YTBuscarPista','YTPlaylist','YTTipo','YTEstado','TxtYTSel','BtnYTTodos','BtnYTNinguno',
               'YTPrivacidad','ChkYTEntradaSalida','BtnYTResubir','YTLista','TxtYTCola','YTCola','LateralArriba','LateralMedio','LateralAbajo',
               'YTCred','BtnYTCredCerrar','TxtYTCredEstado','BtnYTPaso2','BtnYTPaso4','YTClientId',
               'YTClientSecret','BtnYTGuardarCred','BtnYTLoginGoogle','ChipYTServidor','TxtYTServidorChip',
               'Lateral','LogoFondo','LogoLetra','LogoTexto',
               'BtnYTVerResubida','BtnYTAbrirCanal','YTResubida','BtnYTResubidaCerrar','TxtYTResubida','YTResubidaLista','BarraYTResubida',
               'BtnEstilo','IcoEstilo','PanelEstilo','AtajosEstilo','TxtEstilo','BtnEstiloBorrar','BtnEstiloCancelar','BtnEstiloGuardar') {
    $ui[$n] = $win.FindName($n)
}
$icono = Join-Path $ConfigDir 'valora.ico'
# Se carga desde memoria para no dejar el fichero bloqueado: el actualizador tiene que poder sustituirlo.
function Set-IconoVentana {
    if (-not (Test-Path $icono)) { return }
    try {
        $ms = New-Object System.IO.MemoryStream(,[IO.File]::ReadAllBytes($icono))
        $win.Icon = [System.Windows.Media.Imaging.BitmapFrame]::Create($ms, 'None', 'OnLoad')
    } catch {}
}
Set-IconoVentana

$conversorColor = New-Object System.Windows.Media.BrushConverter
function Brush([string]$hex) { return $conversorColor.ConvertFromString($hex) }
$imagenes = @('.jpg','.jpeg','.png','.bmp','.gif','.tif','.tiff')

# ---------- Utilidades de interfaz ----------
function Set-Estado([string]$texto, [string]$color = '#8C929C') {
    $ui.TxtEstado.Text = $texto
    $ui.TxtEstado.Foreground = Brush $color
}

function Update-Inicio {
    $ui.Inicio.Visibility = if ($ui.Chat.Children.Count -eq 0) { 'Visible' } else { 'Collapsed' }
}

function New-Icono([string]$glifo, [double]$tam = 14, [string]$color = '#CDCAC3') {
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

# ---------- Respuestas con formato, como en la web de Gemini ----------
# agy contesta en Markdown. Se pinta en un FlowDocument: títulos, negritas, cursivas, listas,
# tablas, citas, enlaces y bloques de código con botón de copiar. Todo se puede seleccionar.
$PatronInlineMd = '(\*\*(?<b>.+?)\*\*|__(?<b2>.+?)__|`(?<c>[^`]+)`|\[(?<lt>[^\]]+)\]\((?<lu>[^)\s]+)\)|' +
    '(?<url>https?://[^\s<>()]+[^\s<>().,;:!?])|~~(?<s>.+?)~~|' +
    '(?<![\w*])\*(?<i>[^*\s](?:[^*]*?[^*\s])?)\*(?![\w*])|(?<![\w_])_(?<i2>[^_\s](?:[^_]*?[^_\s])?)_(?![\w_]))'

function Add-InlinesMd($destino, [string]$texto) {
    $pos = 0
    foreach ($m in [regex]::Matches($texto, $PatronInlineMd)) {
        if ($m.Index -gt $pos) { $destino.Add((New-Object System.Windows.Documents.Run($texto.Substring($pos, $m.Index - $pos)))) }
        $g = $m.Groups
        if ($g['b'].Success -or $g['b2'].Success) {
            $x = New-Object System.Windows.Documents.Bold
            Add-InlinesMd $x.Inlines $(if ($g['b'].Success) { $g['b'].Value } else { $g['b2'].Value })
            $destino.Add($x)
        } elseif ($g['i'].Success -or $g['i2'].Success) {
            $x = New-Object System.Windows.Documents.Italic
            Add-InlinesMd $x.Inlines $(if ($g['i'].Success) { $g['i'].Value } else { $g['i2'].Value })
            $destino.Add($x)
        } elseif ($g['s'].Success) {
            $x = New-Object System.Windows.Documents.Span
            $x.TextDecorations = [System.Windows.TextDecorations]::Strikethrough
            Add-InlinesMd $x.Inlines $g['s'].Value
            $destino.Add($x)
        } elseif ($g['c'].Success) {
            $r = New-Object System.Windows.Documents.Run(' ' + $g['c'].Value + ' ')
            $r.FontFamily = 'Consolas'; $r.Background = Brush '#2C313A'; $r.Foreground = Brush '#F0C987'
            $destino.Add($r)
        } else {
            $url = if ($g['lu'].Success) { $g['lu'].Value } else { $g['url'].Value }
            $h = New-Object System.Windows.Documents.Hyperlink
            [void]$h.Inlines.Add((New-Object System.Windows.Documents.Run($(if ($g['lt'].Success) { $g['lt'].Value } else { $url }))))
            $h.Foreground = Brush '#8AB4F8'; $h.ToolTip = $url; $h.Tag = $url; $h.Cursor = 'Hand'
            $h.Add_Click({ try { Start-Process ([string]$this.Tag) } catch {} })
            $destino.Add($h)
        }
        $pos = $m.Index + $m.Length
    }
    if ($pos -lt $texto.Length) { $destino.Add((New-Object System.Windows.Documents.Run($texto.Substring($pos)))) }
}

function New-ParrafoMd([string]$texto, [double]$tam = 15, [bool]$negrita = $false, [string]$margen = '0,0,0,12') {
    $p = New-Object System.Windows.Documents.Paragraph
    $p.Margin = $margen; $p.FontSize = $tam
    if ($negrita) { $p.FontWeight = 'SemiBold' }
    $lineas = $texto -split "`n"
    for ($k = 0; $k -lt $lineas.Count; $k++) {
        Add-InlinesMd $p.Inlines $lineas[$k]
        if ($k -lt $lineas.Count - 1) { $p.Inlines.Add((New-Object System.Windows.Documents.LineBreak)) }
    }
    return $p
}

# La rueda del ratón sobre una respuesta mueve la conversación, no se queda en la respuesta.
$PasarRueda = { $ui.Scroll.ScrollToVerticalOffset($ui.Scroll.VerticalOffset - $_.Delta); $_.Handled = $true }

function New-CodigoMd([string]$codigo, [string]$lenguaje) {
    $b = New-Object System.Windows.Controls.Border
    $b.Background = Brush '#14161A'; $b.CornerRadius = 10; $b.BorderBrush = Brush '#31363F'; $b.BorderThickness = 1
    $b.Margin = '0,2,0,12'
    $pila = New-Object System.Windows.Controls.DockPanel
    $cab = New-Object System.Windows.Controls.Border
    $cab.Background = Brush '#22262D'; $cab.CornerRadius = '10,10,0,0'; $cab.Padding = '12,2,4,2'
    [System.Windows.Controls.DockPanel]::SetDock($cab, 'Top')
    $g = New-Object System.Windows.Controls.DockPanel
    $copiar = New-Object System.Windows.Controls.Button
    $copiar.Style = $win.FindResource('Plano'); $copiar.Padding = '8,3'; $copiar.FontSize = 12; $copiar.Foreground = Brush '#ACB1B9'
    $copiar.Content = 'Copiar'; $copiar.Tag = $codigo
    $copiar.Add_Click({ [System.Windows.Clipboard]::SetText([string]$this.Tag); $this.Content = 'Copiado ✓' })
    [System.Windows.Controls.DockPanel]::SetDock($copiar, 'Right')
    $leng = New-Object System.Windows.Controls.TextBlock
    $leng.Text = if ($lenguaje) { $lenguaje } else { 'código' }; $leng.Foreground = Brush '#8C929C'; $leng.FontSize = 12
    $leng.VerticalAlignment = 'Center'
    [void]$g.Children.Add($copiar); [void]$g.Children.Add($leng)
    $cab.Child = $g
    $t = New-Object System.Windows.Controls.TextBox
    $t.Text = $codigo; $t.IsReadOnly = $true; $t.FontFamily = 'Consolas'; $t.FontSize = 13.5
    $t.Foreground = Brush '#E6E2DA'; $t.Background = Brush '#00000000'; $t.BorderThickness = 0; $t.Padding = '12,10'
    $t.TextWrapping = 'NoWrap'; $t.HorizontalScrollBarVisibility = 'Auto'; $t.VerticalScrollBarVisibility = 'Disabled'
    $t.Add_PreviewMouseWheel($PasarRueda)
    [void]$pila.Children.Add($cab); [void]$pila.Children.Add($t)
    $b.Child = $pila
    return (New-Object System.Windows.Documents.BlockUIContainer($b))
}

function Split-FilaMd([string]$linea) {
    $l = $linea.Trim()
    if ($l.StartsWith('|')) { $l = $l.Substring(1) }
    if ($l.EndsWith('|')) { $l = $l.Substring(0, $l.Length - 1) }
    return @($l -split '(?<!\\)\|' | ForEach-Object { $_.Trim() -replace '\\\|', '|' })
}

function New-TablaMd($filas) {
    $t = New-Object System.Windows.Documents.Table
    $t.CellSpacing = 0; $t.Margin = '0,2,0,14'; $t.BorderBrush = Brush '#363C47'; $t.BorderThickness = '1,1,0,0'
    $n = ($filas | ForEach-Object { $_.Count } | Measure-Object -Maximum).Maximum
    for ($c = 0; $c -lt $n; $c++) { $t.Columns.Add((New-Object System.Windows.Documents.TableColumn)) }
    $grupo = New-Object System.Windows.Documents.TableRowGroup
    $t.RowGroups.Add($grupo)
    for ($f = 0; $f -lt $filas.Count; $f++) {
        $fila = New-Object System.Windows.Documents.TableRow
        if ($f -eq 0) { $fila.Background = Brush '#2A2E36'; $fila.FontWeight = 'SemiBold' }
        for ($c = 0; $c -lt $n; $c++) {
            $celda = New-Object System.Windows.Documents.TableCell
            $celda.BorderBrush = Brush '#363C47'; $celda.BorderThickness = '0,0,1,1'; $celda.Padding = '8,4'
            $p = New-Object System.Windows.Documents.Paragraph
            $p.Margin = '0'; $p.FontSize = 14
            $texto = if ($c -lt $filas[$f].Count) { $filas[$f][$c] } else { '' }
            Add-InlinesMd $p.Inlines $texto
            $celda.Blocks.Add($p)
            $fila.Cells.Add($celda)
        }
        $grupo.Rows.Add($fila)
    }
    return $t
}

function New-ListaMd($items) {
    $raiz = $null
    $pila = New-Object System.Collections.ArrayList
    foreach ($it in $items) {
        while ($pila.Count -and $it.indent -lt $pila[$pila.Count - 1].indent) { $pila.RemoveAt($pila.Count - 1) }
        if (-not $pila.Count -or $it.indent -gt $pila[$pila.Count - 1].indent) {
            $lista = New-Object System.Windows.Documents.List
            $lista.MarkerStyle = if ($it.ordenada) { 'Decimal' } else { 'Disc' }
            $lista.Margin = '0,0,0,10'; $lista.Padding = '24,0,0,0'
            if ($it.ordenada -and $it.numero -gt 1) { $lista.StartIndex = $it.numero }
            $padre = if ($pila.Count) { $pila[$pila.Count - 1].lista.ListItems.LastListItem } else { $null }
            if ($padre) { $lista.Margin = '0,2,0,2'; $padre.Blocks.Add($lista) } elseif (-not $raiz) { $raiz = $lista }
            [void]$pila.Add(@{ indent = $it.indent; lista = $lista })
        }
        $li = New-Object System.Windows.Documents.ListItem
        $li.Blocks.Add((New-ParrafoMd $it.texto 15 $false '0,0,0,4'))
        $pila[$pila.Count - 1].lista.ListItems.Add($li)
    }
    return $raiz
}

function ConvertTo-DocumentoMd([string]$md) {
    $doc = New-Object System.Windows.Documents.FlowDocument
    $doc.PagePadding = '0'; $doc.FontFamily = 'Segoe UI'; $doc.FontSize = 15; $doc.Foreground = Brush '#ECE8E1'
    $doc.LineHeight = 24
    $lineas = ($md -replace "`r", '') -split "`n"
    $parrafo = New-Object 'System.Collections.Generic.List[string]'
    $i = 0
    while ($i -lt $lineas.Count) {
        $l = $lineas[$i]
        $esBloque = ($l -match '^\s*$') -or ($l -match '^\s*```') -or ($l -match '^#{1,6}\s') -or ($l -match '^\s*([-*_])(\s*\1){2,}\s*$') -or
            ($l -match '^\s*>') -or ($l -match '^\s*([-*+]|\d+[.)])\s+\S') -or
            ($l -match '^\s*\|' -and $i + 1 -lt $lineas.Count -and $lineas[$i + 1] -match '^\s*\|?\s*:?-{2,}')
        if (-not $esBloque) { $parrafo.Add($l.Trim()); $i++; continue }
        if ($parrafo.Count) { $doc.Blocks.Add((New-ParrafoMd ($parrafo -join "`n"))); $parrafo.Clear() }

        if ($l -match '^\s*$') { $i++; continue }
        if ($l -match '^\s*```\s*([^\s`]*)') {
            $leng = $Matches[1]; $codigo = New-Object 'System.Collections.Generic.List[string]'; $i++
            while ($i -lt $lineas.Count -and $lineas[$i] -notmatch '^\s*```\s*$') { $codigo.Add($lineas[$i]); $i++ }
            $i++
            $doc.Blocks.Add((New-CodigoMd ($codigo -join "`n") $leng))
            continue
        }
        if ($l -match '^(#{1,6})\s+(.*?)\s*#*\s*$') {
            $tam = @(15, 23, 20, 17.5, 16, 15, 15)[$Matches[1].Length]
            $doc.Blocks.Add((New-ParrafoMd $Matches[2] $tam $true '0,10,0,8'))
            $i++; continue
        }
        if ($l -match '^\s*([-*_])(\s*\1){2,}\s*$') {
            $sep = New-Object System.Windows.Controls.Border
            $sep.Height = 1; $sep.Background = Brush '#363C47'; $sep.Margin = '0,6,0,6'
            $doc.Blocks.Add((New-Object System.Windows.Documents.BlockUIContainer($sep)))
            $i++; continue
        }
        if ($l -match '^\s*>') {
            $cita = New-Object 'System.Collections.Generic.List[string]'
            while ($i -lt $lineas.Count -and $lineas[$i] -match '^\s*>\s?(.*)$') { $cita.Add($Matches[1]); $i++ }
            $sec = New-Object System.Windows.Documents.Section
            $sec.BorderBrush = Brush '#5A606B'; $sec.BorderThickness = '3,0,0,0'; $sec.Padding = '12,0,0,0'
            $sec.Margin = '0,0,0,12'; $sec.Foreground = Brush '#ACB1B9'
            $sec.Blocks.Add((New-ParrafoMd ($cita -join "`n") 15 $false '0'))
            $doc.Blocks.Add($sec)
            continue
        }
        if ($l -match '^\s*\|') {
            $filas = New-Object System.Collections.ArrayList
            [void]$filas.Add((Split-FilaMd $l)); $i += 2
            while ($i -lt $lineas.Count -and $lineas[$i] -match '^\s*\|') { [void]$filas.Add((Split-FilaMd $lineas[$i])); $i++ }
            $doc.Blocks.Add((New-TablaMd $filas))
            continue
        }
        # Lista: sigue mientras haya elementos, líneas que continúan el anterior o huecos entre ellos.
        $items = New-Object System.Collections.ArrayList
        while ($i -lt $lineas.Count) {
            $x = $lineas[$i]
            if ($x -match '^(\s*)([-*+]|\d+[.)])\s+(.*)$') {
                # Se copian los grupos antes de nada: otro -match pisaría $Matches.
                $sangria = $Matches[1]; $marca = $Matches[2]; $resto = $Matches[3]
                $ordenada = $marca -match '\d'
                # Una lista numerada justo después de una de puntos (o al revés) es otra lista.
                if ($items.Count -and $sangria.Length -le $items[0].indent -and $ordenada -ne $items[0].ordenada) { break }
                [void]$items.Add(@{ indent = $sangria.Replace("`t", '    ').Length; ordenada = $ordenada
                    numero = $(if ($ordenada) { [int]($marca -replace '\D', '') } else { 0 }); texto = $resto })
                $i++
            } elseif ($x -match '^\s{2,}\S' -and $items.Count) {
                $items[$items.Count - 1].texto += "`n" + $x.Trim(); $i++
            } elseif ($x -match '^\s*$' -and $i + 1 -lt $lineas.Count -and $lineas[$i + 1] -match '^\s*([-*+]|\d+[.)])\s+\S') {
                $i++
            } else { break }
        }
        $lista = New-ListaMd $items
        if ($lista) { $doc.Blocks.Add($lista) }
    }
    if ($parrafo.Count) { $doc.Blocks.Add((New-ParrafoMd ($parrafo -join "`n"))) }
    # Sin margen al final, para que la respuesta no deje hueco debajo.
    if ($doc.Blocks.LastBlock) { $doc.Blocks.LastBlock.Margin = New-Object System.Windows.Thickness(0) }
    return $doc
}

# Pinta en la caja de la respuesta el texto con formato (o tal cual, si es un aviso de otro color).
function Show-Respuesta {
    $r = $script:respuesta
    if (-not $r) { return }
    $r.Pintado = Get-Date
    if ($r.Color -ne '#ECE8E1') {
        $r.Caja.Content = New-TextoLectura $r.Text $r.Color
        return
    }
    try { $doc = ConvertTo-DocumentoMd $r.Text } catch { $r.Caja.Content = New-TextoLectura $r.Text $r.Color; return }
    $rtb = $r.Caja.Content
    if ($rtb -isnot [System.Windows.Controls.RichTextBox]) {
        $rtb = New-Object System.Windows.Controls.RichTextBox
        $rtb.IsReadOnly = $true; $rtb.IsDocumentEnabled = $true; $rtb.BorderThickness = 0
        $rtb.Background = Brush '#00000000'; $rtb.Foreground = Brush '#ECE8E1'; $rtb.Padding = '0'
        $rtb.VerticalScrollBarVisibility = 'Disabled'
        $rtb.Add_PreviewMouseWheel($PasarRueda)
        $r.Caja.Content = $rtb
    }
    $rtb.Document = $doc
}

# Mientras agy escribe, se repinta como mucho cada 250 ms; este temporizador pinta lo último.
$timerPintar = New-Object System.Windows.Threading.DispatcherTimer
$timerPintar.Interval = [TimeSpan]::FromMilliseconds(250)
$timerPintar.Add_Tick({ $timerPintar.Stop(); Show-Respuesta; $ui.Scroll.ScrollToEnd() })

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
    $b.Background = Brush '#2C313A'; $b.CornerRadius = 18; $b.Padding = '16,10'
    $b.HorizontalAlignment = 'Right'
    $b.Child = New-TextoLectura $texto '#ECE8E1'
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
    $av.Width = 28; $av.Height = 28; $av.CornerRadius = 8; $av.Background = Brush '#C8A15A'
    $av.VerticalAlignment = 'Top'; $av.Margin = '0,0,14,0'
    $l = New-Object System.Windows.Controls.TextBlock
    $l.Text = 'V'; $l.FontWeight = 'Bold'; $l.FontSize = 14; $l.Foreground = Brush '#14161A'
    $l.HorizontalAlignment = 'Center'; $l.VerticalAlignment = 'Center'
    $av.Child = $l
    $caja = New-Object System.Windows.Controls.ContentControl
    $caja.Content = New-TextoLectura 'Pensando…' '#8C929C'
    [System.Windows.Controls.Grid]::SetColumn($caja, 1)
    [void]$g.Children.Add($av); [void]$g.Children.Add($caja)
    [void]$ui.Chat.Children.Add($g)
    Update-Inicio
    # Text es el Markdown tal como llega de agy; Caja enseña su versión con formato.
    $script:respuesta = [pscustomobject]@{ Caja = $caja; Text = ''; Color = '#ECE8E1'; Pintado = [datetime]::MinValue }
    $script:pensando = $true
}

# En las conversaciones de una ficha, el bloque ```json de la tasación es para la
# máquina: en pantalla se sustituye por un aviso (se guarda y se envía completo).
function Format-TextoVisible([string]$texto) {
    if (-not $script:conv -or -not $script:conv.ficha) { return $texto }
    return [regex]::Replace($texto, '```(?:json)?\s*\{[\s\S]*?\}\s*```', {
        param($m)
        $n = ([regex]::Matches($m.Value, '"\w+"\s*:')).Count
        "[ Tasación preparada ($n campos). Revísala y envíala con el botón «Revisar y enviar tasación» de abajo. ]"
    })
}

function Add-MensajeAgyTexto([string]$texto) {
    # Pinta un mensaje guardado sin tocar la respuesta que pueda estar llegando de agy.
    $enCurso = $script:respuesta; $pensaba = $script:pensando
    Add-MensajeAgy
    $script:respuesta.Text = $texto
    Show-Respuesta
    $script:respuesta = $enCurso; $script:pensando = $pensaba
}

# ---------- Historial de conversaciones ----------
function Save-Conv { Save-ConvObj $script:conv }
function Save-ConvObj($c) {
    if (-not $c) { return }
    $c.actualizada = (Get-Date).ToString('o')
    $ruta = Join-Path $ConvDir ($c.id + '.json')
    $c | ConvertTo-Json -Depth 6 | Set-Content $ruta -Encoding UTF8
}

# Solo se lee cada archivo cuando cambia: con muchas conversaciones la lista se repinta a menudo.
$script:cacheConvs = @{}
function Get-Convs {
    $lista = @()
    $vistos = @{}
    foreach ($f in Get-ChildItem $ConvDir -Filter *.json -ErrorAction SilentlyContinue) {
        $vistos[$f.FullName] = $true
        $e = $script:cacheConvs[$f.FullName]
        if (-not $e -or $e.Escrito -ne $f.LastWriteTimeUtc) {
            try {
                $c = Get-Content $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
                if (-not $c.id) { continue }
                $e = [pscustomobject]@{ Escrito = $f.LastWriteTimeUtc; id = $c.id; titulo = [string]$c.titulo; actualizada = [datetime]$c.actualizada }
                $script:cacheConvs[$f.FullName] = $e
            } catch { continue }
        }
        $lista += $e
    }
    foreach ($k in @($script:cacheConvs.Keys)) { if (-not $vistos[$k]) { $script:cacheConvs.Remove($k) } }
    return @($lista | Sort-Object actualizada -Descending)
}

function Get-GrupoFecha([datetime]$d) {
    $hoy = (Get-Date).Date
    if ($d -ge $hoy) { return 'Hoy' }
    if ($d -ge $hoy.AddDays(-1)) { return 'Ayer' }
    if ($d -ge $hoy.AddDays(-7)) { return 'Últimos 7 días' }
    if ($d -ge $hoy.AddDays(-30)) { return 'Últimos 30 días' }
    return (Get-Culture).TextInfo.ToTitleCase($d.ToString('MMMM yyyy', [Globalization.CultureInfo]'es-ES'))
}

function Update-ListaConv {
    $ui.ListaConv.Children.Clear()
    $todas = Get-Convs
    $filtro = $ui.BuscarConv.Text.Trim()
    $ui.CajaBuscarConv.Visibility = if ($todas.Count -gt 6 -or $filtro) { 'Visible' } else { 'Collapsed' }
    $ui.TxtNumConv.Text = if ($todas.Count) { [string]$todas.Count } else { '' }
    $convs = if ($filtro) { @($todas | Where-Object { $_.titulo -like "*$filtro*" }) } else { $todas }
    if (-not $convs.Count) {
        $v = New-Object System.Windows.Controls.TextBlock
        $v.Text = if ($filtro) { 'Ninguna conversación coincide.' } else { 'Aún no hay conversaciones.' }
        $v.Foreground = Brush '#6A707B'; $v.FontSize = 12.5; $v.Margin = '12,4,12,0'; $v.TextWrapping = 'Wrap'
        [void]$ui.ListaConv.Children.Add($v)
        return
    }
    $grupo = $null
    foreach ($c in $convs) {
        $g0 = Get-GrupoFecha $c.actualizada
        if ($g0 -ne $grupo) {
            $grupo = $g0
            $h = New-Object System.Windows.Controls.TextBlock
            $h.Text = $grupo; $h.Foreground = Brush '#767C87'; $h.FontSize = 11.5; $h.FontWeight = 'SemiBold'
            $h.Margin = $(if ($ui.ListaConv.Children.Count) { '10,14,10,4' } else { '10,2,10,4' })
            [void]$ui.ListaConv.Children.Add($h)
        }
        $activa = $script:conv -and $script:conv.id -eq $c.id
        $trabajando = $script:proc -and $script:convTrabajo -and $script:convTrabajo.id -eq $c.id

        $g = New-Object System.Windows.Controls.Grid
        $g.Margin = '0,0,0,1'
        $btn = New-Object System.Windows.Controls.Button
        $btn.Style = $win.FindResource('Plano'); $btn.Padding = '10,8'; $btn.Tag = $c.id
        $btn.HorizontalContentAlignment = 'Stretch'
        if ($activa) { $btn.Background = Brush '#2C313A' }
        $fila = New-Object System.Windows.Controls.DockPanel
        $fila.LastChildFill = $true
        # A la derecha: la hora, «Respondiendo…» o, al pasar el ratón, la papelera.
        $hora = New-Object System.Windows.Controls.TextBlock
        $hora.FontSize = 11; $hora.VerticalAlignment = 'Center'; $hora.Margin = '8,0,24,0'
        if ($trabajando) { $hora.Text = '● Respondiendo'; $hora.Foreground = Brush '#E8A33D' }
        else {
            $hora.Text = if ($c.actualizada -ge (Get-Date).Date) { $c.actualizada.ToString('HH:mm') } else { $c.actualizada.ToString('d MMM', [Globalization.CultureInfo]'es-ES').TrimEnd('.') }
            $hora.Foreground = Brush '#6A707B'
        }
        [System.Windows.Controls.DockPanel]::SetDock($hora, 'Right')
        $t = New-Object System.Windows.Controls.TextBlock
        $t.Text = $c.titulo; $t.TextTrimming = 'CharacterEllipsis'; $t.FontSize = 13.5; $t.VerticalAlignment = 'Center'
        $t.Foreground = Brush $(if ($activa) { '#FFFFFF' } else { '#D4D1CA' })
        [void]$fila.Children.Add($hora); [void]$fila.Children.Add($t)
        $btn.Content = $fila
        $btn.ToolTip = $c.titulo + "`n" + $c.actualizada.ToString('dd/MM/yyyy HH:mm')
        $btn.Add_Click({ Set-Modo 'valora'; Open-Conv $this.Tag })

        $x = New-Object System.Windows.Controls.Button
        $x.Style = $win.FindResource('Plano'); $x.Padding = '6'; $x.Margin = '0,0,4,0'
        $x.HorizontalAlignment = 'Right'; $x.VerticalAlignment = 'Center'
        $x.Tag = $c.id; $x.ToolTip = 'Borrar conversación'
        [System.Windows.Automation.AutomationProperties]::SetName($x, 'Borrar: ' + $c.titulo)
        $x.Content = New-Icono ([string][char]0xE74D) 11 '#969CA6'
        $x.Add_Click({ Remove-Conv $this.Tag })
        $x.Visibility = $(if ($activa) { 'Visible' } else { 'Hidden' })
        $g.Tag = $x
        if (-not $activa) {
            $g.Add_MouseEnter({ $this.Tag.Visibility = 'Visible' })
            $g.Add_MouseLeave({ $this.Tag.Visibility = 'Hidden' })
        }
        [void]$g.Children.Add($btn); [void]$g.Children.Add($x)
        if ($activa) {
            $marca = New-Object System.Windows.Controls.Border
            $marca.Width = 3; $marca.CornerRadius = 2; $marca.Margin = '0,9,0,9'; $marca.HorizontalAlignment = 'Left'
            $marca.Background = Brush '#C8A15A'; $marca.IsHitTestVisible = $false
            [void]$g.Children.Add($marca)
        }
        [void]$ui.ListaConv.Children.Add($g)
    }
}

$ui.BuscarConv.Add_TextChanged({
    $ui.BuscarConvPista.Visibility = if ($ui.BuscarConv.Text) { 'Collapsed' } else { 'Visible' }
    Update-ListaConv
    $ui.ScrollConv.ScrollToTop()
})
$ui.BuscarConv.Add_PreviewKeyDown({
    if ($_.Key -eq 'Escape') { $ui.BuscarConv.Text = ''; $_.Handled = $true }
})

function New-ConvVacia {
    $script:conv = $null
    $ui.Chat.Children.Clear()
    Update-BotonEnviar
    Update-Inicio
    Update-ListaConv
    if (Get-Command Update-BarraFicha -ErrorAction SilentlyContinue) { Update-BarraFicha }
    if (Get-Command Start-SesionAgy -ErrorAction SilentlyContinue) { Start-SesionAgy }
}

function Open-Conv([string]$id) {
    $ruta = Join-Path $ConvDir ($id + '.json')
    if (-not (Test-Path $ruta)) { Update-ListaConv; return }
    $enCurso = $script:proc -and $script:convTrabajo -and $script:convTrabajo.id -eq $id
    if ($enCurso) { $c = $script:convTrabajo } else {
        $c = Get-Content $ruta -Raw -Encoding UTF8 | ConvertFrom-Json
        $c.mensajes = @($c.mensajes)
    }
    $script:conv = $c
    $ui.Chat.Children.Clear()
    foreach ($m in $c.mensajes) {
        if ($m.rol -eq 'usuario') { Add-MensajeUsuario $m.texto @($m.adjuntos | Where-Object { $_ }) }
        else { Add-MensajeAgyTexto (Format-TextoVisible $m.texto) }
    }
    if ($enCurso -and $script:filaTrabajo) { [void]$ui.Chat.Children.Add($script:filaTrabajo) }
    foreach ($q in @($script:colaPreguntas | Where-Object { $_.convId -eq $id })) { Show-PreguntaEnCola $q }
    Update-BotonEnviar
    Update-Inicio
    Update-ListaConv
    Update-BarraFicha
    $ui.Scroll.ScrollToEnd()
    Set-Estado 'Conversación abierta. Puedes seguir donde la dejaste.'
    Start-SesionAgy
    Send-SiguienteEnCola
    $ui.Prompt.Focus() | Out-Null
}

function Remove-Conv([string]$id) {
    if ($script:proc -and $script:convTrabajo -and $script:convTrabajo.id -eq $id) { Set-Estado 'No se puede borrar mientras está respondiendo.' '#F2C46D'; return }
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

function Write-Respuesta([string]$texto, [string]$color = '#ECE8E1') {
    if (-not $script:respuesta) { return }
    if ($script:pensando) {
        $script:respuesta.Text = ''
        $script:respuesta.Color = $color
        $script:pensando = $false
    }
    $script:respuesta.Text += $texto
    if (((Get-Date) - $script:respuesta.Pintado).TotalMilliseconds -ge 250) { $timerPintar.Stop(); Show-Respuesta } else { $timerPintar.Start() }
    $ui.Scroll.ScrollToEnd()
}

function New-Miniatura([string]$ruta, [int]$alto, [bool]$quitable) {
    $g = New-Object System.Windows.Controls.Grid
    $g.Margin = '0,0,8,8'
    $b = New-Object System.Windows.Controls.Border
    $b.CornerRadius = 10; $b.Background = Brush '#363C47'; $b.ToolTip = $ruta
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
        $n.Foreground = Brush '#ECE8E1'; $n.FontSize = 13; $n.VerticalAlignment = 'Center'
        [void]$sp.Children.Add($n)
        $b.Child = $sp
    }
    [void]$g.Children.Add($b)
    if ($quitable) {
        $x = New-Object System.Windows.Controls.Button
        $x.Style = $win.FindResource('Redondo'); $x.Width = 20; $x.Height = 20
        $x.Background = Brush '#ECE8E1'; $x.HorizontalAlignment = 'Right'; $x.VerticalAlignment = 'Top'
        $x.Margin = '0,-6,-6,0'; $x.ToolTip = 'Quitar'
        $x.Content = New-Icono ([string][char]0xE711) 8 '#14161A'
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
        $g.Margin = '0,0,0,1'
        $btn = New-Object System.Windows.Controls.Button
        $btn.Style = $win.FindResource('Plano'); $btn.Padding = '10,7'; $btn.ToolTip = $c; $btn.Tag = $c
        $sp = New-Object System.Windows.Controls.StackPanel; $sp.Orientation = 'Horizontal'
        [void]$sp.Children.Add((New-Icono ([string][char]0xE71B) 13 '#ACB1B9'))
        $t = New-Object System.Windows.Controls.TextBlock
        $t.Text = Split-Path $c -Leaf; $t.Margin = '10,0,24,0'; $t.TextTrimming = 'CharacterEllipsis'; $t.MaxWidth = 170
        [void]$sp.Children.Add($t)
        $btn.Content = $sp
        $btn.Add_Click({ Start-Process explorer.exe $this.Tag })
        $x = New-Object System.Windows.Controls.Button
        $x.Style = $win.FindResource('Plano'); $x.Padding = '6'; $x.HorizontalAlignment = 'Right'; $x.Tag = $c
        $x.ToolTip = 'Desconectar carpeta'
        $x.Content = New-Icono ([string][char]0xE711) 10 '#8C929C'
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

function Set-Ocupado([bool]$ocupado) { Update-BotonEnviar; Update-ListaConv }

# Mientras agy contesta se puede ir a otras conversaciones: el botón es «Parar» solo en la que
# está contestando.
function Update-BotonEnviar {
    $aqui = $script:proc -and (-not $script:convTrabajo -or ($script:conv -and $script:conv.id -eq $script:convTrabajo.id))
    if ($aqui -and -not $ui.Prompt.Text.Trim()) {
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
    Stop-SesionAgy -Todas
    [void](Clear-ColaPreguntas)
    & cmdkey.exe /delete:gemini:antigravity | Out-Null
    New-ConvVacia
    Update-Cuenta $false
    $script:loginIntentado = $false
    Show-Login 'Sesión cerrada.'
    $ui.LoginEstado.Foreground = Brush '#8C929C'
}

function Show-Login([string]$mensaje = '') {
    $ui.Login.Visibility = 'Visible'
    $ui.BtnLogin.Visibility = 'Visible'
    $ui.BtnLogin.IsEnabled = $true
    $ui.LoginCodigo.Visibility = 'Collapsed'
    $ui.LoginEstado.Text = $mensaje
    $ui.LoginEstado.Foreground = Brush $(if ($mensaje) { '#F28B82' } else { '#8C929C' })
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
            $ui.LoginEstado.Foreground = Brush $(if ($quedan -le 15) { '#E8A33D' } else { '#8C929C' })
            $ui.LoginEstado.Text = "Esperando a que termines en el navegador… (quedan $quedan s)"
        }
    }
    if ($terminado) {
        $timerLogin.Stop()
        $script:loginProc.Cerrar()
        $script:loginProc = $null
        $ui.LoginEstado.Foreground = Brush '#8C929C'
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
    $ui.LoginEstado.Foreground = Brush '#8C929C'
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
    $ui.LoginEstado.Foreground = Brush '#8C929C'
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
    'view_file_outline' = 'Leyendo un archivo'; 'view_code_item' = 'Leyendo un archivo'; 'command_status' = 'Esperando un comando'
}
# Qué está haciendo agy, en palabras de quien usa Valora: «Leyendo VALORA.md».
function Get-TextoPaso($su) {
    $herramienta = [string]$su.tool_name
    $nombre = $NombresPaso[$herramienta]
    if (-not $nombre) { $nombre = 'Trabajando' }
    $par = $null
    if ($su.tool_info -and $su.tool_info -isnot [string]) { $par = $su.tool_info.parameters }
    $detalle = ''
    if ($par) {
        foreach ($k in 'CommandLine', 'AbsolutePath', 'TargetFile', 'DirectoryPath', 'SearchPath', 'Query', 'Pattern', 'Url') {
            if ($par.$k) { $detalle = [string]$par.$k; break }
        }
        if ($detalle -and $k -in 'AbsolutePath', 'TargetFile', 'DirectoryPath', 'SearchPath') { $detalle = Split-Path $detalle -Leaf }
    }
    $detalle = ($detalle -replace '\s+', ' ').Trim()
    if ($detalle.Length -gt 70) { $detalle = $detalle.Substring(0, 70) + '…' }
    if ($detalle) { return "${nombre}: $detalle" }
    return $nombre
}

# Mientras no llega texto, la burbuja enseña cuánto lleva y los pasos que ha dado agy.
function Show-Pasos {
    if (-not $script:respuesta -or -not $script:pensando -or -not $script:proc) { return }
    $s = [int]((Get-Date) - $script:inicioTurno).TotalSeconds
    $lineas = @("Pensando… $s s")
    $n = $script:pasos.Count
    for ($i = [Math]::Max(0, $n - 6); $i -lt $n; $i++) {
        $marca = if ($i -eq $n - 1) { '›' } else { '✓' }
        $lineas += "$marca $($script:pasos[$i])"
    }
    $texto = $lineas -join "`n"
    $caja = $script:respuesta.Caja
    if ($caja.Content -is [System.Windows.Controls.TextBox]) {
        if ($caja.Content.Text -ne $texto) { $caja.Content.Text = $texto }
    } else {
        $caja.Content = New-TextoLectura $texto '#8C929C'
    }
}

# agy tarda unos segundos en arrancar. Para no pagarlos en cada pregunta, se deja abierto
# con --input-format stream-json: cada pregunta se le manda por la entrada como una línea JSON.
# Se abre al elegir o empezar una conversación, así que al preguntar ya está listo. Si cambian
# la conversación o las carpetas, se cierra y se abre otro.
function Get-ClaveSesion {
    $id = if ($script:conv -and $script:conv.agyId) { [string]$script:conv.agyId } else { '' }
    return $id + '|' + $script:workspace + '|' + (@($script:carpetas) -join '|')
}

function Close-ProcesoAgy($s) {
    if ($s -and $s.proc -and -not $s.proc.HasExited) {
        try { $s.proc.StandardInput.Close() } catch {}
        try { $s.proc.Kill() } catch {}
    }
}

# Cierra la sesión en uso, o todas (al cerrar Valora o la sesión de Google).
function Stop-SesionAgy([switch]$Todas) {
    $lista = if ($Todas) { @($script:sesiones) } else { @($script:sesion) }
    foreach ($s in $lista) {
        if (-not $s) { continue }
        Close-ProcesoAgy $s
        [void]$script:sesiones.Remove($s)
    }
    $script:sesion = $null
}

function Start-SesionAgy {
    # Con una respuesta en curso no se toca nada: la sesión es de esa pregunta.
    if ($script:proc) { return }
    if (-not $script:Agy) { $script:Agy = Find-Agy }
    if (-not $script:Agy) { return }
    $clave = Get-ClaveSesion
    if ($script:sesion -and -not $script:sesion.proc.HasExited -and $script:sesion.clave -eq $clave) { return }
    # La sesión que se deja guarda sus lecturas pendientes: sigue abierta por si se vuelve a ella.
    if ($script:sesion) { $script:sesion.outTask = $script:outTask; $script:sesion.errTask = $script:errTask }
    foreach ($s in @($script:sesiones)) { if ($s.proc.HasExited) { [void]$script:sesiones.Remove($s) } }
    $abierta = @($script:sesiones) | Where-Object { $_.clave -eq $clave } | Select-Object -First 1
    if ($abierta) {
        [void]$script:sesiones.Remove($abierta); [void]$script:sesiones.Add($abierta)
        $script:sesion = $abierta
        $script:outTask = $abierta.outTask
        $script:errTask = $abierta.errTask
        return
    }
    $ws = $script:workspace
    if (-not (Test-Path $ws)) { New-Item -ItemType Directory -Force $ws | Out-Null }
    $argumentos = @('--input-format', 'stream-json', '--output-format', 'stream-json', '--dangerously-skip-permissions', '-p=""')
    if ($script:conv -and $script:conv.agyId) { $argumentos += @('--conversation', $script:conv.agyId) }
    foreach ($c in @($script:carpetas)) { $argumentos += @('--add-dir', (Quote-Arg $c)) }
    # Sin esto, Windows pone una marca BOM al principio de la entrada y agy no la entiende.
    try { [Console]::InputEncoding = New-Object System.Text.UTF8Encoding $false } catch {}
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
    try { $proc = [System.Diagnostics.Process]::Start($psi) } catch { return }
    $agyId = if ($script:conv -and $script:conv.agyId) { [string]$script:conv.agyId } else { '' }
    $script:sesion = [pscustomobject]@{ proc = $proc; clave = $clave; agyId = $agyId; outTask = $null; errTask = $null }
    $script:outTask = $proc.StandardOutput.ReadLineAsync()
    $script:errTask = $proc.StandardError.ReadLineAsync()
    [void]$script:sesiones.Add($script:sesion)
    # Como mucho dos abiertas: la de la conversación actual y la anterior.
    while ($script:sesiones.Count -gt 2) {
        $vieja = $script:sesiones[0]
        Close-ProcesoAgy $vieja
        $script:sesiones.RemoveAt(0)
    }
}

function Send-PreguntaSesion([string]$mensaje) {
    $linea = (@{ event = 'user'; message = @{ role = 'user'; content = $mensaje } } | ConvertTo-Json -Compress -Depth 5) + "`n"
    $bytes = (New-Object System.Text.UTF8Encoding $false).GetBytes($linea)
    $entrada = $script:sesion.proc.StandardInput.BaseStream
    $entrada.Write($bytes, 0, $bytes.Length)
    $entrada.Flush()
}

# Cómo consultar Foticos Collection. Va delante de la primera pregunta de cada conversación
# (agy la recuerda para las siguientes). Con los campos exactos, agy lo resuelve con uno o dos
# comandos; sin ellos tanteaba con una docena y tardaba un minuto.
$GuiaFC = @'
Foticos Collection (la colección de fotografía de la empresa) tiene una API pública de solo lectura, rápida (menos de 0,5 s) y sin clave. Cuando pregunten por la colección, sus fichas, marcas, tipos o cifras, úsala con Invoke-RestMethod; no busques en internet ni en archivos. Resuélvelo con un solo comando que haga todas las llamadas y saque solo los campos necesarios; no tantees.
- https://foticoscollection.com/api/v1/stats -> .stats: total_items, total_brands, total_types, total_countries.
- https://foticoscollection.com/api/v1/items?q=TEXTO&brand_id=ID&type_id=ID&year_min=AÑO&year_max=AÑO&per_page=N&page=P -> .data[]: id, nombre, tipo, foto, descripcion; .meta.total = total encontrado. q busca en descripción y modelo; per_page hasta 200.
- https://foticoscollection.com/api/v1/items/ID -> id, nombre, marca, tipo, foto.
- https://foticoscollection.com/api/v1/brands y https://foticoscollection.com/api/v1/types -> .data[]: id, name, items_count.
foto es una ruta relativa: antepón https://foticoscollection.com.
run_command ya ejecuta PowerShell: escribe el comando tal cual, nunca dentro de powershell -Command. Ejemplo que funciona:
$b='https://foticoscollection.com/api/v1'; $s=(Invoke-RestMethod "$b/stats").stats; $r=Invoke-RestMethod "$b/items?q=leica&per_page=3"; "Fichas: $($s.total_items)"; $r.data | Select-Object id, nombre, tipo | Format-Table -AutoSize | Out-String -Width 200
Para una marca, búscala y cuenta sus fichas en el mismo comando:
$b='https://foticoscollection.com/api/v1'; $m=(Invoke-RestMethod "$b/brands").data | Where-Object name -match 'kodak'; $m | ForEach-Object { $t=(Invoke-RestMethod "$b/items?brand_id=$($_.id)&per_page=3"); "$($_.name) (id $($_.id)): $($t.meta.total) fichas"; $t.data | Select-Object id, nombre | Format-Table -AutoSize | Out-String -Width 200 }
'@

function Read-Evento([string]$linea) {
    $ev = $null
    try { $ev = $linea | ConvertFrom-Json } catch {}
    if (-not $ev -or -not $ev.event) {
        if ($linea.Trim()) { Write-Respuesta ((Limpiar-Ansi $linea) + "`n") }
        return
    }
    switch ($ev.event) {
        'init' {
            $c = $script:convTrabajo
            if ($script:sesion -and $ev.conversation_id) {
                $script:sesion.agyId = [string]$ev.conversation_id
                # La conversación nueva pasa a tener id: la sesión sigue valiendo para ella.
                if ($c) { $script:sesion.clave = [string]$ev.conversation_id + '|' + $script:workspace + '|' + (@($script:carpetas) -join '|') }
            }
            if ($c -and -not $c.agyId -and $ev.conversation_id) {
                $c | Add-Member -NotePropertyName agyId -NotePropertyValue $ev.conversation_id -Force
                Save-ConvObj $c
            }
        }
        'step_update' {
            $su = $ev.step_update
            if ($su.step_type -eq 'agent_response') {
                if ($su.text_delta) { Write-Respuesta $su.text_delta }
            } elseif ($su.step_type -eq 'tool' -and $su.state -eq 'ACTIVE') {
                $texto = Get-TextoPaso $su
                [void]$script:pasos.Add($texto)
                Set-Estado "$texto…" '#E8A33D'
                Show-Pasos
            }
        }
        'result' { $script:resultado = $ev.result; $script:finTurno = $true }
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
    if ($script:pensando) { Show-Pasos }
    $cerrado = -not $script:outTask -and -not $script:errTask -and $script:proc.HasExited
    if ($script:finTurno -or $cerrado) {
        $codigo = if ($script:proc.HasExited) { $script:proc.ExitCode } else { 0 }
        if ($script:proc.HasExited) { Stop-SesionAgy }
        $script:proc = $null
        $script:finTurno = $false
        $timer.Stop()
        Set-Ocupado $false
        $errorAgy = if ($script:resultado -and $script:resultado.status -and $script:resultado.status -ne 'SUCCESS') { [string]$script:resultado.error } else { '' }
        if ($script:avisoLogin) {
            Write-Respuesta 'Falta conectar tu cuenta de Google. Inicia sesión y vuelve a enviar la pregunta.' '#F28B82'
            Show-Login
        } elseif ($errorAgy) {
            Write-Respuesta ("`n" + $errorAgy) '#F28B82'
            Set-Estado 'agy terminó con error.' '#F28B82'
        } elseif ($codigo -eq 0) {
            Set-Estado ('Listo en ' + [int]((Get-Date) - $script:inicioTurno).TotalSeconds + ' s.')
        } else {
            Set-Estado "agy terminó con error (código $codigo)." '#F28B82'
        }
        if ($script:pensando) { Write-Respuesta '(sin respuesta)' '#8C929C' }
        if ($script:respuesta) {
            # La respuesta va a su conversación, aunque en pantalla se esté viendo otra.
            $actual = $script:conv
            if ($script:convTrabajo) { $script:conv = $script:convTrabajo }
            try {
                $completo = $script:respuesta.Text.TrimEnd()
                $script:respuesta.Text = Format-TextoVisible $completo
                $timerPintar.Stop(); Show-Respuesta
                if ($script:conv -and -not $script:avisoLogin) {
                    $script:conv.mensajes = @($script:conv.mensajes) + @([pscustomobject]@{ rol = 'agy'; texto = $completo; adjuntos = @() })
                    Save-Conv
                }
            } finally { $script:conv = $actual }
            $script:convTrabajo = $null; $script:filaTrabajo = $null
            Update-ListaConv
            Update-BarraFicha
            Update-BotonEnviar
        }
        $ui.Prompt.Focus() | Out-Null
        Send-SiguienteEnCola
    }
})

# Lo que se escribe mientras Valora responde en esa misma conversación no se pierde ni hay que
# esperar: queda en cola, se ve en el chat más claro, y se envía solo al acabar la respuesta.
function Show-PreguntaEnCola($item) {
    Add-MensajeUsuario $item.texto @($item.archivos)
    $fila = $ui.Chat.Children[$ui.Chat.Children.Count - 1]
    $fila.Opacity = 0.55
    $fila.ToolTip = 'En cola: se enviará en cuanto Valora termine la respuesta'
    $item | Add-Member -NotePropertyName fila -NotePropertyValue $fila -Force
}

function Add-PreguntaEnCola([string]$texto, [string]$instrucciones) {
    $item = [pscustomobject]@{ texto = $texto; instrucciones = $instrucciones; archivos = @($script:archivos); convId = $script:conv.id; fila = $null }
    [void]$script:colaPreguntas.Add($item)
    Show-PreguntaEnCola $item
    $ui.Prompt.Clear()
    $script:archivos.Clear(); Update-Adjuntos
    $ui.Scroll.ScrollToEnd()
    Update-BotonEnviar
    $n = $script:colaPreguntas.Count
    Set-Estado ("En cola: se enviará en cuanto Valora termine la respuesta" + $(if ($n -gt 1) { " ($n en cola)." } else { '.' })) '#F2C46D'
}

function Clear-ColaPreguntas {
    $n = $script:colaPreguntas.Count
    foreach ($item in @($script:colaPreguntas)) {
        if ($item.fila -and $ui.Chat.Children.Contains($item.fila)) { $ui.Chat.Children.Remove($item.fila) }
    }
    $script:colaPreguntas.Clear()
    return $n
}

function Send-SiguienteEnCola {
    if ($script:proc -or $script:colaPreguntas.Count -eq 0) { return }
    $item = $script:colaPreguntas[0]
    if (-not $script:conv -or $script:conv.id -ne $item.convId) {
        Set-Estado "Hay $($script:colaPreguntas.Count) preguntas en cola en otra conversación: se enviarán al volver a ella." '#F2C46D'
        return
    }
    $script:colaPreguntas.RemoveAt(0)
    Enviar $item.instrucciones $item
}

function Enviar([string]$instrucciones = '', $pendiente = $null) {
    if ($script:proc -and -not $pendiente) {
        $mismo = $script:conv -and $script:convTrabajo -and $script:conv.id -eq $script:convTrabajo.id
        $escrito = $ui.Prompt.Text.Trim()
        if ($mismo -and $escrito) { Add-PreguntaEnCola $escrito $instrucciones; return }
        $t = if ($script:convTrabajo) { $script:convTrabajo.titulo } else { 'otra conversación' }
        Set-Estado "Espera: Valora está respondiendo en «$t». Solo puede contestar una cosa a la vez." '#F2C46D'
        return
    }
    if (-not $script:Agy) { $script:Agy = Find-Agy }
    if (-not $script:Agy) {
        [System.Windows.MessageBox]::Show('No encuentro agy. Ejecuta el instalador (InstalarValora.exe).', 'Valora') | Out-Null
        return
    }
    $texto = if ($pendiente) { $pendiente.texto } else { $ui.Prompt.Text.Trim() }
    if (-not $texto) { return }
    $sueltos = if ($pendiente) { @($pendiente.archivos) } else { @($script:archivos) }
    $ws = $script:workspace
    New-Item -ItemType Directory -Force $ws | Out-Null

    # Los archivos sueltos se copian a <carpeta de trabajo>\entrada para que agy los vea.
    $entrada = Join-Path $ws 'entrada'
    $adjuntos = @()
    foreach ($f in $sueltos) {
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
    if ($instrucciones) { $mensaje = $instrucciones + "`n`n" + $texto }
    # El estilo y la guía de Foticos Collection son contexto, no la pregunta: si van pegados a ella
    # sin marcar, agy a veces contesta «Entendido, tomo nota» en vez de responder.
    $contexto = ''
    if ($script:estilo.Trim()) { $contexto += "Cómo quiere el usuario que le respondas (síguelo siempre):`n" + $script:estilo.Trim() + "`n`n" }
    if (-not $script:conv -or -not $script:conv.agyId) { $contexto += $GuiaFC + "`n" }
    if ($contexto) {
        $mensaje = "[Contexto. No lo comentes ni lo confirmes: síguelo y úsalo solo cuando haga falta.]`n" + $contexto +
            "[Fin del contexto]`n`nPregunta del usuario:`n" + $mensaje
    }
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
            ficha = $script:fichaPendiente; envios = @()
        }
        if ($script:fichaPendiente) {
            $script:conv.titulo = "Ficha #$($script:fichaPendiente.id) · $($script:fichaPendiente.nombre)"
            if ($script:conv.titulo.Length -gt 70) { $script:conv.titulo = $script:conv.titulo.Substring(0, 70) + '…' }
        }
        $script:fichaPendiente = $null
    }
    $script:conv.mensajes = @($script:conv.mensajes) + @([pscustomobject]@{ rol = 'usuario'; texto = $texto; adjuntos = @($adjuntos) })
    Save-Conv
    Update-ListaConv

    # La conversación nueva usa la sesión que ya estaba abierta esperando (y su id de agy).
    if (-not $script:conv.agyId -and $script:sesion -and $script:sesion.agyId -and -not $script:sesion.proc.HasExited -and
        $script:sesion.clave -eq ('|' + $script:workspace + '|' + (@($script:carpetas) -join '|'))) {
        $script:conv | Add-Member -NotePropertyName agyId -NotePropertyValue $script:sesion.agyId -Force
        $script:sesion.clave = Get-ClaveSesion
        Save-Conv
    }

    # Las preguntas que siguen en cola se quitan un momento para que la respuesta quede justo
    # debajo de su pregunta, y se vuelven a poner al final.
    $enCola = @($script:colaPreguntas | Where-Object { $_.convId -eq $script:conv.id -and $_.fila })
    foreach ($q in $enCola) { if ($ui.Chat.Children.Contains($q.fila)) { $ui.Chat.Children.Remove($q.fila) } }
    if ($pendiente -and $pendiente.fila -and $ui.Chat.Children.Contains($pendiente.fila)) { $ui.Chat.Children.Remove($pendiente.fila) }
    Add-MensajeUsuario $texto $adjuntos
    Add-MensajeAgy
    $script:convTrabajo = $script:conv
    $script:filaTrabajo = $ui.Chat.Children[$ui.Chat.Children.Count - 1]
    foreach ($q in $enCola) { [void]$ui.Chat.Children.Add($q.fila) }
    $ui.Scroll.ScrollToEnd()

    Start-SesionAgy
    if (-not $script:sesion) {
        Write-Respuesta 'No se pudo arrancar agy.' '#F28B82'
        return
    }
    $script:avisoLogin = $false
    $script:resultado = $null
    $script:finTurno = $false
    $script:pasos.Clear()
    $script:inicioTurno = Get-Date
    $script:proc = $script:sesion.proc
    try { Send-PreguntaSesion $mensaje } catch {
        # agy se ha cerrado mientras esperaba: el timer lo verá cerrado y terminará el turno.
    }

    # Si la pregunta salía de la cola, lo que se esté escribiendo ahora no se toca.
    if (-not $pendiente) {
        $ui.Prompt.Clear()
        $script:archivos.Clear(); Update-Adjuntos
    }
    Set-Ocupado $true
    $quedan = $script:colaPreguntas.Count
    Set-Estado ('Valora está trabajando…' + $(if ($quedan) { " ($quedan en cola)" } else { '' })) '#E8A33D'
    $timer.Start()
}

function Parar {
    if ($script:proc -and -not $script:proc.HasExited) {
        try { $script:proc.Kill() } catch {}
        Stop-SesionAgy
        $quitadas = Clear-ColaPreguntas
        Set-Estado ('Parado.' + $(if ($quitadas) { " Se han quitado las $quitadas preguntas que había en cola." } else { '' }))
    }
}

# ---------- Eventos ----------
$ui.BtnEnviar.Add_Click({ if ($ui.BtnEnviar.ToolTip -eq 'Parar') { Parar } else { Enviar } })

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
    $script:ultimaEscritura = Get-Date
    $ui.Placeholder.Visibility = if ($ui.Prompt.Text.Length -eq 0) { 'Visible' } else { 'Collapsed' }
    Update-BotonEnviar
})

foreach ($chip in $ui.Sugerencias.Children) {
    $chip.Add_Click({ $ui.Prompt.Text = $this.Tag; $ui.Prompt.CaretIndex = $ui.Prompt.Text.Length; $ui.Prompt.Focus() | Out-Null })
}

$ui.BtnNueva.Add_Click({
    Set-Modo 'valora'
    New-ConvVacia
    Set-Estado 'Conversación nueva. La anterior queda guardada en la lista.'
    $ui.Prompt.Focus() | Out-Null
})

# Ctrl+V en la caja de mensaje: una imagen (un recorte de la herramienta Recortes, una captura)
# se guarda como PNG y se adjunta; archivos copiados en el Explorador se adjuntan tal cual.
# Si lo copiado es texto, se pega como siempre.
$PegadosDir = Join-Path $ConfigDir 'pegados'
$ui.Prompt.Add_PreviewKeyDown({
    if ($_.Key -ne 'V' -or -not ([System.Windows.Input.Keyboard]::Modifiers -band [System.Windows.Input.ModifierKeys]::Control)) { return }
    try {
        if ([System.Windows.Clipboard]::ContainsFileDropList()) {
            Add-Rutas @([System.Windows.Clipboard]::GetFileDropList())
            Set-Estado 'Archivos pegados como adjuntos.' '#81C995'
            $_.Handled = $true
        } elseif ([System.Windows.Clipboard]::ContainsData('PNG') -or [System.Windows.Clipboard]::ContainsImage()) {
            New-Item -ItemType Directory -Force $PegadosDir | Out-Null
            $ruta = Join-Path $PegadosDir ('recorte-{0:yyyyMMdd-HHmmss}.png' -f (Get-Date))
            # Los navegadores copian la imagen también como PNG: se guarda tal cual, que conserva
            # la transparencia. Si no, se convierte el mapa de bits (Recortes, capturas).
            $datosPng = $null
            try { $datosPng = [System.Windows.Clipboard]::GetData('PNG') } catch {}
            if ($datosPng -is [IO.Stream]) {
                $fs = [IO.File]::Create($ruta)
                try { $datosPng.CopyTo($fs) } finally { $fs.Dispose(); $datosPng.Dispose() }
            } else {
                $png = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
                $png.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create([System.Windows.Clipboard]::GetImage()))
                $fs = [IO.File]::Create($ruta)
                try { $png.Save($fs) } finally { $fs.Dispose() }
            }
            Add-Rutas @($ruta)
            Set-Estado 'Imagen pegada como adjunto.' '#81C995'
            $_.Handled = $true
        }
    } catch { Set-Estado ('No se ha podido pegar: ' + $_.Exception.Message) '#F28B82' }
})

# ---------- Cómo quiere el usuario que responda ----------
function Update-IcoEstilo {
    $ui.IcoEstilo.Foreground = Brush $(if ($script:estilo.Trim()) { '#81C995' } else { '#8C929C' })
    $ui.BtnEstilo.ToolTip = if ($script:estilo.Trim()) { "Cómo te responde Valora:`n" + $script:estilo.Trim() } else { 'Cómo quieres que te responda Valora' }
}
$ui.BtnEstilo.Add_Click({
    $ui.TxtEstilo.Text = $script:estilo
    $ui.PanelEstilo.Visibility = 'Visible'
    $ui.TxtEstilo.Focus() | Out-Null
    $ui.TxtEstilo.CaretIndex = $ui.TxtEstilo.Text.Length
})
foreach ($b in $ui.AtajosEstilo.Children) {
    $b.Add_Click({
        $actual = $ui.TxtEstilo.Text.TrimEnd()
        if ($actual -notmatch [regex]::Escape([string]$this.Tag)) {
            $ui.TxtEstilo.Text = $(if ($actual) { $actual + "`n" } else { '' }) + $this.Tag
        }
        $ui.TxtEstilo.CaretIndex = $ui.TxtEstilo.Text.Length
    })
}
$ui.BtnEstiloCancelar.Add_Click({ $ui.PanelEstilo.Visibility = 'Collapsed' })
$ui.BtnEstiloBorrar.Add_Click({ $ui.TxtEstilo.Text = '' })
$ui.BtnEstiloGuardar.Add_Click({
    $script:estilo = $ui.TxtEstilo.Text.Trim()
    Save-Config
    Update-IcoEstilo
    $ui.PanelEstilo.Visibility = 'Collapsed'
    Set-Estado $(if ($script:estilo) { 'Guardado: las próximas respuestas seguirán tus indicaciones.' } else { 'Valora responderá como siempre.' }) '#81C995'
})
Update-IcoEstilo

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
        $ui.TxtWs.Text = Split-Path $script:workspace -Leaf; $ui.BtnAbrirWs.ToolTip = "Carpeta de trabajo (abrir en Explorador)`n" + $script:workspace
        New-ConvVacia
        Save-Config
        Set-Estado 'Carpeta cambiada. La conversación empieza de nuevo.'
    }
})

$ui.BtnAbrirWs.Add_Click({ Start-Process explorer.exe $script:workspace })

$ui.BtnTerminal.Add_Click({
    if (-not $script:Agy) { $script:Agy = Find-Agy }
    if (-not $script:Agy) {
        [System.Windows.MessageBox]::Show('No encuentro agy. Ejecuta el instalador (InstalarValora.exe).', 'Valora') | Out-Null
        return
    }
    $extra = ' --dangerously-skip-permissions'
    if ($script:conv -and $script:conv.agyId) { $extra += ' --conversation ' + $script:conv.agyId }
    foreach ($c in $script:carpetas) { $extra += " --add-dir '" + ($c -replace "'", "''") + "'" }
    $comando = "& '" + ($script:Agy -replace "'", "''") + "'" + $extra
    Start-Process powershell.exe -WorkingDirectory $script:workspace -ArgumentList @('-NoExit', '-NoProfile', '-Command', $comando)
})

# ---------- Foticos Collection ----------
# Valora habla con la API /api/valora de Foticos Collection: lista las fichas sin
# tasar, abre una conversación para tasar una ficha con las reglas de la web y,
# tras una confirmación explícita, envía la tasación (con la conversación).
$FCUrls = @{ PRE = 'https://stg.foticoscollection.com'; PRO = 'https://foticoscollection.com' }
$script:httpPend = New-Object System.Collections.ArrayList
$script:fcPagina = 1
$script:fcCargando = $false
$script:tasacionDetectada = $null
$script:simulacion = $null

function Get-UrlFC([string]$entorno) {
    if ($env:VALORA_FC_URL) { return $env:VALORA_FC_URL.TrimEnd('/') }   # pruebas contra un servidor local
    return $FCUrls[$entorno]
}

function Get-ClaveFC([string]$entorno = $script:fcEntorno) {
    $cifrada = $script:fcClaves[$entorno]
    if (-not $cifrada) { return $null }
    try {
        $seguro = ConvertTo-SecureString $cifrada -ErrorAction Stop
        $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($seguro)
        try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr) } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
    } catch { return $null }
}

function Set-ClaveFC([string]$clave, [string]$entorno = $script:fcEntorno) {
    $script:fcClaves[$entorno] = (ConvertTo-SecureString $clave -AsPlainText -Force | ConvertFrom-SecureString)
    Save-Config
}

function Set-Insignia($borde, $texto, [string]$entorno) {
    $borde.Background = Brush $(if ($entorno -eq 'PRO') { '#B3261E' } else { '#8A5A12' })
    $texto.Text = $entorno
}

function Update-Entorno {
    Set-Insignia $ui.InsigniaEntorno $ui.TxtInsigniaEntorno $script:fcEntorno
    Set-Insignia $ui.PanelEntorno $ui.TxtPanelEntorno $script:fcEntorno
    $ui.RadPRE.IsChecked = ($script:fcEntorno -eq 'PRE')
    $ui.RadPRO.IsChecked = ($script:fcEntorno -eq 'PRO')
}

# --- HTTP sin bloquear la ventana: cada petición es una tarea que revisa un temporizador.
function Read-ErrorHttp($tarea) {
    $ex = $tarea.Exception
    if ($ex) { $ex = $ex.GetBaseException() }
    $msg = if ($ex) { $ex.Message } else { 'petición cancelada' }
    if ($ex -is [System.Net.WebException] -and $ex.Response) {
        $script:httpCodigo = [int]$ex.Response.StatusCode
        try {
            $cuerpo = (New-Object System.IO.StreamReader($ex.Response.GetResponseStream(), [Text.Encoding]::UTF8)).ReadToEnd()
            $j = $cuerpo | ConvertFrom-Json
            if ($j.error) { $msg = $j.error } elseif ($j.message) { $msg = $j.message }
        } catch {}
    }
    return $msg
}

$timerHttp = New-Object System.Windows.Threading.DispatcherTimer
$timerHttp.Interval = [TimeSpan]::FromMilliseconds(120)
$timerHttp.Add_Tick({
    foreach ($p in @($script:httpPend)) {
        if (-not $p.tarea.IsCompleted) { continue }
        [void]$script:httpPend.Remove($p)
        $res = $null; $err = $null; $script:httpCodigo = 0
        if ($p.tarea.IsFaulted -or $p.tarea.IsCanceled) { $err = Read-ErrorHttp $p.tarea }
        elseif ($p.json) { try { $res = $p.tarea.Result | ConvertFrom-Json } catch { $err = 'Respuesta no válida del servidor.' } }
        else { $res = $true }
        try { & $p.alTerminar $res $err $p.ctx } catch { Set-Estado ('Error: ' + $_.Exception.Message) '#F28B82' }
    }
    if ($script:httpPend.Count -eq 0) { $timerHttp.Stop() }
})

function New-ClienteFC([string]$entorno) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072
    $wc = New-Object System.Net.WebClient
    $wc.Encoding = [System.Text.Encoding]::UTF8
    $wc.Headers['User-Agent'] = 'Valora'
    $wc.Headers['Accept'] = 'application/json'
    $clave = Get-ClaveFC $entorno
    if ($clave) { $wc.Headers['X-Valora-Key'] = $clave }
    return $wc
}

function Invoke-FC([string]$metodo, [string]$ruta, $cuerpo, [scriptblock]$alTerminar, $ctx = $null, [string]$entorno = $script:fcEntorno) {
    $wc = New-ClienteFC $entorno
    $url = (Get-UrlFC $entorno) + '/api/valora' + $ruta
    if ($metodo -eq 'GET') {
        $tarea = $wc.DownloadStringTaskAsync($url)
    } else {
        $wc.Headers['Content-Type'] = 'application/json; charset=utf-8'
        $tarea = $wc.UploadStringTaskAsync($url, $metodo, ($cuerpo | ConvertTo-Json -Depth 8 -Compress))
    }
    [void]$script:httpPend.Add(@{ tarea = $tarea; alTerminar = $alTerminar; ctx = $ctx; json = $true })
    $timerHttp.Start()
}

function Get-ArchivoFC([string]$url, [string]$destino, [scriptblock]$alTerminar, $ctx) {
    $wc = New-ClienteFC $script:fcEntorno
    $tarea = $wc.DownloadFileTaskAsync($url, $destino)
    [void]$script:httpPend.Add(@{ tarea = $tarea; alTerminar = $alTerminar; ctx = $ctx; json = $false })
    $timerHttp.Start()
}

# --- Panel de fichas por tasar
function Show-PanelFC {
    $ui.PanelFC.Visibility = 'Visible'
    Update-Entorno
    if (-not (Get-ClaveFC)) {
        $ui.ConexionFC.Visibility = 'Visible'
        $ui.EstadoPanelFC.Text = "Falta la clave de Valora para $($script:fcEntorno). Pídesela al administrador y pégala arriba."
        $ui.ListaFC.Children.Clear()
        return
    }
    if ($ui.ListaFC.Children.Count -eq 0) { Get-PendientesFC $true }
}

function New-FilaFicha($f) {
    $btn = New-Object System.Windows.Controls.Button
    $btn.Style = $win.FindResource('Plano'); $btn.Padding = '8,8'; $btn.Margin = '0,0,0,2'; $btn.Tag = $f.id
    $btn.HorizontalContentAlignment = 'Stretch'
    $g = New-Object System.Windows.Controls.Grid
    $c1 = New-Object System.Windows.Controls.ColumnDefinition; $c1.Width = 'Auto'
    $c2 = New-Object System.Windows.Controls.ColumnDefinition
    $g.ColumnDefinitions.Add($c1); $g.ColumnDefinitions.Add($c2)
    $foto = New-Object System.Windows.Controls.Border
    $foto.Width = 52; $foto.Height = 52; $foto.CornerRadius = 8; $foto.Background = Brush '#363C47'; $foto.Margin = '0,0,12,0'
    if ($f.foto) {
        try {
            $bmp = New-Object System.Windows.Media.Imaging.BitmapImage
            $bmp.BeginInit(); $bmp.UriSource = New-Object Uri($f.foto); $bmp.DecodePixelWidth = 104; $bmp.EndInit()
            $ib = New-Object System.Windows.Media.ImageBrush $bmp; $ib.Stretch = 'UniformToFill'
            $foto.Background = $ib
        } catch {}
    }
    $sp = New-Object System.Windows.Controls.StackPanel; $sp.VerticalAlignment = 'Center'
    $t = New-Object System.Windows.Controls.TextBlock
    $t.Text = "#$($f.id) · $($f.nombre)"; $t.TextTrimming = 'CharacterEllipsis'; $t.FontSize = 14.5
    $d = New-Object System.Windows.Controls.TextBlock
    $d.Text = (@($f.tipo, $f.marca, $f.modelo, $f.estado) | Where-Object { $_ }) -join ' · '
    $d.Foreground = Brush '#8C929C'; $d.FontSize = 12.5; $d.TextTrimming = 'CharacterEllipsis'
    [void]$sp.Children.Add($t); [void]$sp.Children.Add($d)
    [System.Windows.Controls.Grid]::SetColumn($sp, 1)
    [void]$g.Children.Add($foto); [void]$g.Children.Add($sp)
    $btn.Content = $g
    [System.Windows.Automation.AutomationProperties]::SetName($btn, "Ficha $($f.id)")
    $btn.Add_Click({ Open-FichaFC ([int]$this.Tag) })
    return $btn
}

function Get-PendientesFC([bool]$reiniciar) {
    if ($script:fcCargando) { return }
    if ($reiniciar) { $script:fcPagina = 1; $ui.ListaFC.Children.Clear() }
    $script:fcCargando = $true
    $ui.EstadoPanelFC.Foreground = Brush '#8C929C'
    $ui.EstadoPanelFC.Text = 'Cargando fichas…'
    $q = [Uri]::EscapeDataString($ui.BuscarFC.Text.Trim())
    $est = ''
    if ($ui.EstadoFC.SelectedIndex -gt 0) { $est = [Uri]::EscapeDataString([string]$ui.EstadoFC.SelectedItem.Content) }
    Invoke-FC 'GET' "/pendientes?per_page=30&page=$($script:fcPagina)&q=$q&estado=$est" $null {
        param($res, $err, $ctx)
        $script:fcCargando = $false
        if ($err) { $ui.EstadoPanelFC.Foreground = Brush '#F28B82'; $ui.EstadoPanelFC.Text = "No se pudo cargar la lista: $err"; return }
        foreach ($f in @($res.data)) { [void]$ui.ListaFC.Children.Add((New-FilaFicha $f)) }
        $ui.BtnMasFC.Visibility = if ($res.meta.pagina -lt $res.meta.paginas) { 'Visible' } else { 'Collapsed' }
        $ui.EstadoPanelFC.Text = "$($res.meta.total) fichas sin tasar con foto."
        if ($res.meta.total -eq 0) { $ui.EstadoPanelFC.Text = 'No hay fichas sin tasar con esos filtros.' }
    }
}

# --- Abrir una ficha: datos + reglas + fotos, y conversación nueva para tasarla.
function Open-FichaFC([int]$id) {
    if ($script:proc) { $ui.EstadoPanelFC.Text = 'Espera a que Valora termine la respuesta en curso.'; return }
    $ui.EstadoPanelFC.Foreground = Brush '#8C929C'
    $ui.EstadoPanelFC.Text = "Abriendo la ficha #$id…"
    $ctx = @{ id = $id; entorno = $script:fcEntorno }
    Invoke-FC 'GET' "/items/$id" $null {
        param($res, $err, $ctx)
        if ($err) { $ui.EstadoPanelFC.Foreground = Brush '#F28B82'; $ui.EstadoPanelFC.Text = "No se pudo abrir la ficha: $err"; return }
        $ctx.item = $res
        Invoke-FC 'GET' "/items/$($ctx.id)/contexto" $null {
            param($res, $err, $ctx)
            if ($err) { $ui.EstadoPanelFC.Foreground = Brush '#F28B82'; $ui.EstadoPanelFC.Text = "No se pudieron leer las reglas de tasación: $err"; return }
            $ctx.contexto = $res
            Get-FotosFC $ctx
        } $ctx $ctx.entorno
    } $ctx
}

function Get-FotosFC($ctx) {
    $carpeta = Join-Path $script:workspace ("fichas\" + $ctx.entorno + "-" + $ctx.id)
    New-Item -ItemType Directory -Force $carpeta | Out-Null
    $ctx.fotos = New-Object System.Collections.ArrayList
    $ctx.faltan = @($ctx.item.fotos).Count
    if ($ctx.faltan -eq 0) { Start-TasacionFC $ctx; return }
    $ui.EstadoPanelFC.Text = "Descargando $($ctx.faltan) fotos de la ficha #$($ctx.id)…"
    $n = 0
    foreach ($f in @($ctx.item.fotos)) {
        $n++
        $ext = [IO.Path]::GetExtension(([Uri]$f.url).AbsolutePath); if (-not $ext) { $ext = '.jpg' }
        $destino = Join-Path $carpeta ("foto{0:00}-{1}{2}" -f $n, $f.tipo, $ext)
        Get-ArchivoFC $f.url $destino {
            param($res, $err, $c)
            if (-not $err -and (Test-Path $c.destino)) { [void]$c.ctx.fotos.Add($c.destino) }
            $c.ctx.faltan--
            if ($c.ctx.faltan -le 0) { Start-TasacionFC $c.ctx }
        } @{ ctx = $ctx; destino = $destino }
    }
}

function Start-TasacionFC($ctx) {
    $it = $ctx.item
    $nombre = if ($it.ficha.description_es) { $it.ficha.description_es } else { "sin nombre" }
    $ui.PanelFC.Visibility = 'Collapsed'
    New-ConvVacia
    $script:fichaPendiente = [pscustomobject]@{
        id = $it.id; nombre = $nombre; entorno = $ctx.entorno; url_admin = $it.url_admin; ajuste_manual = [bool]$it.ajuste_manual
    }
    $script:archivos.Clear()
    foreach ($f in $ctx.fotos) { [void]$script:archivos.Add($f) }
    Update-Adjuntos

    $actuales = @()
    foreach ($pr in $it.ficha.PSObject.Properties) {
        if ($null -ne $pr.Value -and "$($pr.Value)" -ne '') { $actuales += "- $($pr.Name): $($pr.Value)" }
    }
    if ($it.textos.tipo) { $actuales += "- tipo (nombre): $($it.textos.tipo)" }
    if ($it.textos.marca) { $actuales += "- marca (nombre): $($it.textos.marca)" }
    if ($it.textos.made_in) { $actuales += "- made_in (ISO): $($it.textos.made_in)" }

    $c = $ctx.contexto
    $instr = "Vas a tasar la ficha #$($it.id) de Foticos Collection (entorno $($ctx.entorno)) a partir de sus fotos adjuntas. " +
        "Sigue EXACTAMENTE las reglas de tasación de la web, que son estas:`n`n=== REGLAS DE TASACIÓN ===`n$($c.system)`n`n" +
        "=== DATOS DE LA FICHA ===`n$($c.user)`nValores actuales de la ficha (pueden estar vacíos o venir de una tasación automática anterior):`n" + ($actuales -join "`n") + "`n`n" +
        "=== FORMATO DE ESTA CONVERSACIÓN (prevalece sobre la indicación de responder solo con JSON) ===`n" +
        "1. Primero explica en 3-6 líneas qué pieza es y en qué te basas para datarla y valorarla.`n" +
        "2. Después escribe la tasación en un bloque de código ``````json con este esquema:`n$($c.esquema)`n$($c.campos_extra)`n" +
        "3. Si más adelante en esta conversación cambia cualquier dato (porque te lo pido o porque lo corriges), vuelve a escribir el bloque ``````json COMPLETO con todos los campos actualizados.`n" +
        "4. No crees ni modifiques archivos: solo responde. El envío a Foticos Collection lo hace la persona desde Valora."
    if ($ctx.fotos.Count -eq 0) {
        $instr += "`n`nAVISO: no se ha podido descargar ninguna foto de esta ficha. Dilo claramente y tasa solo con los datos."
    }

    $ui.Prompt.Text = "Tasa la ficha #$($it.id) de Foticos Collection: $nombre."
    Enviar $instr
    Update-BarraFicha
    if ($ctx.fotos.Count -lt @($it.fotos).Count) {
        Set-Estado "Ojo: solo se descargaron $($ctx.fotos.Count) de $(@($it.fotos).Count) fotos de la ficha." '#E8A33D'
    }
}

# --- Barra de la ficha activa y detección de la tasación en la conversación.
function Get-UltimaTasacion {
    if (-not $script:conv) { return $null }
    $claves = @('description_es', 'actual_value', 'valor_max', 'status_piece', 'detail_es', 'richtext_description_es')
    $msgs = @($script:conv.mensajes)
    for ($i = $msgs.Count - 1; $i -ge 0; $i--) {
        if ($msgs[$i].rol -ne 'agy') { continue }
        $bloques = [regex]::Matches([string]$msgs[$i].texto, '```(?:json)?\s*(\{[\s\S]*?\})\s*```')
        for ($k = $bloques.Count - 1; $k -ge 0; $k--) {
            try {
                $obj = $bloques[$k].Groups[1].Value | ConvertFrom-Json -ErrorAction Stop
                $nombres = @($obj.PSObject.Properties.Name)
                if (@($claves | Where-Object { $nombres -contains $_ }).Count -gt 0) { return $obj }
            } catch {}
        }
    }
    return $null
}

function Update-BarraFicha {
    $f = if ($script:conv) { $script:conv.ficha } else { $script:fichaPendiente }
    if (-not $f) { $ui.BarraFicha.Visibility = 'Collapsed'; $script:tasacionDetectada = $null; return }
    $ui.BarraFicha.Visibility = 'Visible'
    Set-Insignia $ui.BarraEntorno $ui.TxtBarraEntorno $f.entorno
    $ui.TxtBarraFicha.Text = "Ficha #$($f.id) · $($f.nombre)"
    $script:tasacionDetectada = Get-UltimaTasacion
    $envios = @($script:conv.envios | Where-Object { $_ })
    $ui.BtnRevisarEnviar.IsEnabled = [bool]$script:tasacionDetectada -and -not $script:proc
    if ($envios.Count -gt 0) {
        $ultimo = $envios[-1]
        $ui.TxtBarraEstado.Text = 'Enviada ' + ([datetime]$ultimo.fecha).ToString('dd/MM HH:mm')
        $ui.BtnRevisarEnviar.Content = 'Revisar y volver a enviar'
    } else {
        $ui.TxtBarraEstado.Text = if ($script:tasacionDetectada) { 'Tasación lista para revisar' } else { 'Esperando la tasación…' }
        $ui.BtnRevisarEnviar.Content = 'Revisar y enviar tasación'
    }
}

# --- Confirmación: el servidor calcula el antes/después (simular) y solo se
#     guarda al pulsar "Sí, enviar tasación".
function Add-CeldaTabla([int]$fila, [int]$col, [string]$texto, [string]$color = '#ECE8E1', [bool]$negrita = $false) {
    $t = New-Object System.Windows.Controls.TextBox
    $t.Text = $texto; $t.IsReadOnly = $true; $t.BorderThickness = 0; $t.Background = 'Transparent'
    $t.Foreground = Brush $color; $t.TextWrapping = 'Wrap'; $t.FontSize = 13.5; $t.Margin = '0,6,12,6'
    if ($negrita) { $t.FontWeight = 'SemiBold' }
    [System.Windows.Controls.Grid]::SetRow($t, $fila); [System.Windows.Controls.Grid]::SetColumn($t, $col)
    [void]$ui.TablaCambios.Children.Add($t)
}

function ConvertTo-TextoVisible($v) {
    if ($null -eq $v -or "$v" -eq '') { return '—' }
    $s = [string]$v -replace '<li>', "`n• " -replace '</p>\s*<p>', "`n`n" -replace '<[^>]+>', ''
    $s = [System.Net.WebUtility]::HtmlDecode($s).Trim()
    if ($s.Length -gt 400) { $s = $s.Substring(0, 400) + '…' }
    return $s
}

function Show-Confirmar {
    if (-not $script:conv -or -not $script:conv.ficha -or -not $script:tasacionDetectada) { return }
    $f = $script:conv.ficha
    $script:simulacion = $null
    Set-Insignia $ui.ConfEntorno $ui.TxtConfEntorno $f.entorno
    $ui.TxtConfPieza.Text = "Ficha #$($f.id) · $($f.nombre)"
    $ui.TxtConfAviso.Text = ''
    $ui.TxtConfEstado.Foreground = Brush '#8C929C'
    $ui.TxtConfEstado.Text = 'Calculando qué cambiaría en la ficha…'
    $ui.TablaCambios.Children.Clear(); $ui.TablaCambios.RowDefinitions.Clear(); $ui.TablaCambios.ColumnDefinitions.Clear()
    $ui.BtnConfEnviar.IsEnabled = $false
    $ui.BtnConfEnviar.Content = "Sí, enviar tasación a Foticos Collection ($($f.entorno))"
    $ui.PanelConfirmar.Visibility = 'Visible'

    # Primero se mira si la clave de ese entorno puede escribir (en PRO, de
    # momento, las claves son de solo lectura): así el botón sale bloqueado.
    $script:puedeEscribir = $false
    Invoke-FC 'GET' '/estado' $null {
        param($res, $err, $ctx)
        $script:puedeEscribir = (-not $err) -and [bool]$res.puede_escribir
        Start-SimulacionFC $ctx
    } $f $f.entorno
}

function Start-SimulacionFC($f) {
    Invoke-FC 'POST' "/items/$($f.id)/tasacion" @{ simular = $true; datos = $script:tasacionDetectada } {
        param($res, $err, $ctx)
        if ($err) { $ui.TxtConfEstado.Foreground = Brush '#F28B82'; $ui.TxtConfEstado.Text = "No se pudo preparar el envío: $err"; return }
        $script:simulacion = $res
        foreach ($w in '170', '*', '*') {
            $cd = New-Object System.Windows.Controls.ColumnDefinition
            $cd.Width = if ($w -eq '*') { New-Object System.Windows.GridLength(1, 'Star') } else { New-Object System.Windows.GridLength([double]$w) }
            $ui.TablaCambios.ColumnDefinitions.Add($cd)
        }
        $filas = @($res.cambios)
        for ($i = 0; $i -le $filas.Count; $i++) { $ui.TablaCambios.RowDefinitions.Add((New-Object System.Windows.Controls.RowDefinition)) }
        Add-CeldaTabla 0 0 'Campo' '#8C929C' $true
        Add-CeldaTabla 0 1 'Ahora en Foticos Collection' '#8C929C' $true
        Add-CeldaTabla 0 2 'Se enviará' '#8C929C' $true
        $i = 1
        foreach ($c in $filas) {
            Add-CeldaTabla $i 0 $c.etiqueta '#CDCAC3' $true
            Add-CeldaTabla $i 1 (ConvertTo-TextoVisible $c.antes) $(if ($c.cambia) { '#F2A38B' } else { '#8C929C' })
            Add-CeldaTabla $i 2 (ConvertTo-TextoVisible $c.despues) $(if ($c.cambia) { '#81C995' } else { '#8C929C' })
            $i++
        }
        $avisos = @()
        if ($res.ajuste_manual -and @($res.protegidos).Count -gt 0) { $avisos += 'Ficha con ajuste manual: no se tocarán ' + (@($res.protegidos) -join ', ') + '.' }
        $avisos += @($res.avisos)
        $ui.TxtConfAviso.Text = ($avisos | Where-Object { $_ }) -join "`n"
        $nCambian = @($filas | Where-Object { $_.cambia }).Count
        if ($nCambian -eq 0) {
            $ui.TxtConfEstado.Text = 'La tasación no cambia nada de la ficha: no hay nada que enviar.'
        } elseif (-not $script:puedeEscribir) {
            $ui.TxtConfEstado.Foreground = Brush '#E8A33D'
            $ui.TxtConfEstado.Text = "Tu clave de $($script:conv.ficha.entorno) es de SOLO LECTURA: puedes ver qué cambiaría ($nCambian campos), pero no enviarlo. Cuando se active la escritura, este botón se habilitará solo."
            $ui.BtnConfEnviar.Content = "Solo lectura en $($script:conv.ficha.entorno): no se puede enviar"
        } else {
            $ui.TxtConfEstado.Text = "Se cambiarán $nCambian campos de la ficha #$($res.item_id) en $($script:conv.ficha.entorno). Revisa la tabla: al pulsar el botón verde se guarda en Foticos Collection junto con esta conversación."
            $ui.BtnConfEnviar.IsEnabled = $true
        }
    } $null $f.entorno
}

function Send-TasacionFC {
    if (-not $script:simulacion -or -not $script:conv.ficha) { return }
    $f = $script:conv.ficha
    $ui.BtnConfEnviar.IsEnabled = $false
    $ui.TxtConfEstado.Foreground = Brush '#8C929C'
    $ui.TxtConfEstado.Text = 'Enviando…'
    $mensajes = @($script:conv.mensajes | ForEach-Object {
        @{ rol = $_.rol; texto = $_.texto; adjuntos = @(@($_.adjuntos) | Where-Object { $_ } | ForEach-Object { Split-Path $_ -Leaf }) }
    })
    $verLocal = (Get-VersionLocal).sha

    $cuerpo = @{
        datos = $script:tasacionDetectada
        conversacion = $mensajes
        agy_conversacion_id = $script:conv.agyId
        valora_version = $(if ($verLocal) { $verLocal.Substring(0, 7) } else { 'local' })
    }
    Invoke-FC 'POST' "/items/$($f.id)/tasacion" $cuerpo {
        param($res, $err, $ctx)
        if ($err) {
            $ui.TxtConfEstado.Foreground = Brush '#F28B82'; $ui.TxtConfEstado.Text = "No se ha guardado. Motivo: $err"
            $ui.BtnConfEnviar.IsEnabled = $true
            return
        }
        $ui.PanelConfirmar.Visibility = 'Collapsed'
        $envio = [pscustomobject]@{ fecha = (Get-Date).ToString('o'); tasacion_id = $res.tasacion_id; url_conversacion = $res.url_conversacion; campos = @($res.cambios | ForEach-Object { $_.campo }) }
        $script:conv.envios = @($script:conv.envios | Where-Object { $_ }) + @($envio)
        $texto = "✓ Tasación enviada a Foticos Collection ($($script:conv.ficha.entorno)), ficha #$($res.item_id). " +
            "Campos guardados: " + (@($res.cambios | ForEach-Object { $_.etiqueta }) -join ', ') + ".`n" +
            "Ficha: $($res.url_admin)`nConversación guardada: $($res.url_conversacion)"
        Add-MensajeAgyTexto $texto
        $script:conv.mensajes = @($script:conv.mensajes) + @([pscustomobject]@{ rol = 'sistema'; texto = $texto; adjuntos = @() })
        Save-Conv
        Update-ListaConv
        Update-BarraFicha
        $ui.Scroll.ScrollToEnd()
        Set-Estado 'Tasación enviada a Foticos Collection.' '#81C995'
    } $null $f.entorno
}

# --- Eventos de Foticos Collection
$ui.BtnFichas.Add_Click({ Show-PanelFC })
$ui.BtnCerrarFC.Add_Click({ $ui.PanelFC.Visibility = 'Collapsed' })
$ui.BtnConexionFC.Add_Click({ $ui.ConexionFC.Visibility = if ($ui.ConexionFC.Visibility -eq 'Visible') { 'Collapsed' } else { 'Visible' } })
$ui.BtnBuscarFC.Add_Click({ Get-PendientesFC $true })
$ui.BuscarFC.Add_KeyDown({ if ($_.Key -eq 'Return') { Get-PendientesFC $true; $_.Handled = $true } })
$ui.BtnMasFC.Add_Click({ $script:fcPagina++; Get-PendientesFC $false })
$ui.RadPRE.Add_Click({ $script:fcEntorno = 'PRE'; Save-Config; Update-Entorno; $ui.ListaFC.Children.Clear(); Show-PanelFC })
$ui.RadPRO.Add_Click({ $script:fcEntorno = 'PRO'; Save-Config; Update-Entorno; $ui.ListaFC.Children.Clear(); Show-PanelFC })
$ui.BtnGuardarConexion.Add_Click({
    if ($ui.ClaveFC.Password) { Set-ClaveFC $ui.ClaveFC.Password.Trim(); $ui.ClaveFC.Clear() }
    if (-not (Get-ClaveFC)) { $ui.EstadoPanelFC.Text = 'Pega la clave antes de guardar.'; return }
    $ui.EstadoPanelFC.Foreground = Brush '#8C929C'; $ui.EstadoPanelFC.Text = 'Probando la conexión…'
    Invoke-FC 'GET' '/estado' $null {
        param($res, $err, $ctx)
        if ($err) { $ui.EstadoPanelFC.Foreground = Brush '#F28B82'; $ui.EstadoPanelFC.Text = "No conecta con $($script:fcEntorno): $err"; return }
        $ui.EstadoPanelFC.Foreground = Brush '#81C995'
        $ui.EstadoPanelFC.Text = "Conectado a $($script:fcEntorno) como $($res.nombre)" + $(if ($res.puede_escribir) { '.' } else { ' (solo lectura).' })
        $ui.ConexionFC.Visibility = 'Collapsed'
        Get-PendientesFC $true
    }
})
$ui.BtnAbrirFicha.Add_Click({ if ($script:conv -and $script:conv.ficha.url_admin) { Start-Process $script:conv.ficha.url_admin } })
$ui.BtnRevisarEnviar.Add_Click({ Show-Confirmar })
$ui.BtnConfCancelar.Add_Click({ $ui.PanelConfirmar.Visibility = 'Collapsed'; Set-Estado 'Envío cancelado: no se ha guardado nada.' })
$ui.BtnConfEnviar.Add_Click({ Send-TasacionFC })
$win.Add_PreviewKeyDown({
    if ($_.Key -eq 'Escape') {
        if ($ui.PanelConfirmar.Visibility -eq 'Visible') { $ui.PanelConfirmar.Visibility = 'Collapsed'; $_.Handled = $true }
        elseif ($ui.PanelFC.Visibility -eq 'Visible') { $ui.PanelFC.Visibility = 'Collapsed'; $_.Handled = $true }
    }
})

# ---------- Actualización automática ----------
# Valora mira en GitHub el último commit del repositorio. Si cambió, descarga Valora.ps1 de ese
# commit exacto (sin cachés), comprueba que se puede leer, se reemplaza y se reinicia.
# Además, una vez al día, actualiza agy con "agy update".
# --- YouTube: elegir vídeos del canal y volver a subirlos.
# El trabajo lo hace la web de Documents\youtube (web.py), que corre en el PC de Rubén con los
# vídeos descargados y el permiso de YouTube. Valora solo habla con su API: entra una vez con
# usuario y contraseña, guarda el token cifrado y desde ahí lista, encola y enseña la cola.
if (-not ('ValoraFilaYT' -as [type])) {
    Add-Type -TypeDefinition @'
public class ValoraFilaYT {
    public string Id { get; set; }
    public string Fecha { get; set; }
    public string Titulo { get; set; }
    public string Playlists { get; set; }
    public string Tipo { get; set; }
    public string Vistas { get; set; }
    public string Estado { get; set; }
    public string Url { get; set; }
    public bool Seleccionable { get; set; }
}
'@
}
$script:ytVideos = @()
$script:ytFiltrados = $null
$script:ytSel = New-Object 'System.Collections.Generic.HashSet[string]'
$script:ytPintando = $false
$script:ytCargando = $null
$script:ytPidiendoEstado = $null
$script:ytEstado = $null
$script:ytTicks = 0
$script:ytMensajeCredHasta = Get-Date

# Dónde está la web: la que se haya escrito a mano; si no, en el PC donde corre (el de Rubén)
# la local, y en los demás la dirección pública que la web deja en la rama «direccion» del
# repo de Valora cada vez que arranca (con trycloudflare cambia en cada arranque).
$script:ytUrlAuto = $null
$script:ytEsServidor = $script:ytServidorLocal -or (Test-Path (Join-Path $env:USERPROFILE 'Documents\youtube\web.py'))
$PuertoLocalYT = 8090

function Get-UrlYT {
    if ($script:ytServidorLocal) { return "http://127.0.0.1:$PuertoLocalYT" }
    if ($script:ytUrl -and $script:ytUrl -notmatch 'trycloudflare\.com') { return $script:ytUrl.TrimEnd('/') }
    if ($script:ytEsServidor) { return 'http://127.0.0.1:8080' }
    if ($script:ytUrlAuto) { return $script:ytUrlAuto }
    if ($script:ytUrl) { return $script:ytUrl.TrimEnd('/') }
    return 'http://127.0.0.1:8080'
}

function Update-UrlAutoYT {
    if ($script:ytEsServidor) { return }
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072
    $wc = New-Object System.Net.WebClient
    $wc.Encoding = [System.Text.Encoding]::UTF8
    $wc.Headers['User-Agent'] = 'Valora'
    $url = 'https://raw.githubusercontent.com/rubencandeal-a11y/valora/direccion/direccion.json?t=' + [DateTime]::UtcNow.Ticks
    [void]$script:httpPend.Add(@{ tarea = $wc.DownloadStringTaskAsync($url); json = $true; ctx = $null; alTerminar = {
        param($res, $err)
        if ($err -or -not $res.url) { return }
        $nueva = ([string]$res.url).TrimEnd('/')
        if ($nueva -ne $script:ytUrlAuto) {
            $script:ytUrlAuto = $nueva
            # Si al arrancar no llegaba (aún no había dirección), se quita el aviso y se reintenta.
            if ($ui.YTServidor.Visibility -eq 'Visible' -and (Get-TokenYT)) { $ui.YTServidor.Visibility = 'Collapsed' }
            $script:ytPidiendoEstado = $null; $script:ytCargando = $null
            if ($script:modo -eq 'youtube') { Get-EstadoYT; Get-VideosYT }
        }
    } })
    $timerHttp.Start()
}

# ---------- Resubida en este mismo PC (modo servidor, el PC del jefe) ----------
# Valora deja este PC listo para montar y subir él solo: comprueba qué programas faltan y los
# instala con winget (Python, ffmpeg, Node.js), baja de GitHub el programa de resubida y lo
# mantiene al día (solo el código: la configuración, el permiso de YouTube, la cola, lo subido
# y los vídeos se conservan), lo arranca en segundo plano y entra en él sola.
$ResubidaDir = Join-Path $ConfigDir 'resubida'
$script:srv = $null
$script:srvUltimaRevision = [DateTime]::MinValue

function Find-ProgramaYT([string]$nombre, [string[]]$rutas) {
    $c = Get-Command $nombre -ErrorAction SilentlyContinue | Where-Object { $_.Source -notmatch 'WindowsApps' } | Select-Object -First 1
    if ($c) { return $c.Source }
    foreach ($r in $rutas) {
        $f = Get-Item $r -ErrorAction SilentlyContinue | Sort-Object FullName -Descending | Select-Object -First 1
        if ($f) { return $f.FullName }
    }
    return $null
}

function Get-ProgramasYT {
    return [ordered]@{
        python = Find-ProgramaYT 'python.exe' @("$env:LOCALAPPDATA\Programs\Python\Python3*\python.exe", "$env:ProgramFiles\Python3*\python.exe")
        ffmpeg = Find-ProgramaYT 'ffmpeg.exe' @("$env:LOCALAPPDATA\Microsoft\WinGet\Links\ffmpeg.exe", "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\Gyan.FFmpeg*\*\bin\ffmpeg.exe")
        node   = Find-ProgramaYT 'node.exe' @("$env:ProgramFiles\nodejs\node.exe", "$env:LOCALAPPDATA\Programs\nodejs\node.exe")
    }
}

$WingetYT = @{ python = 'Python.Python.3.12'; ffmpeg = 'Gyan.FFmpeg'; node = 'OpenJS.NodeJS.LTS' }
$NombreYT = @{ python = 'Python'; ffmpeg = 'ffmpeg'; node = 'Node.js' }

function Start-ProcesoYT([string]$exe, [string]$argumentos, [string]$carpeta = $ResubidaDir, [hashtable]$entorno = @{}) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo $exe, $argumentos
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true; $psi.WorkingDirectory = $carpeta
    foreach ($k in $entorno.Keys) { $psi.EnvironmentVariables[$k] = $entorno[$k] }
    return [System.Diagnostics.Process]::Start($psi)
}

function Get-EntornoYT($prog) {
    # Lo recién instalado no está en el PATH de este proceso: se añade a mano para la web.
    $carpetas = @($prog.Values | Where-Object { $_ } | ForEach-Object { Split-Path $_ })
    return @{ PATH = (($carpetas + $env:PATH) -join ';'); RESUBIDA_PUERTO = "$PuertoLocalYT"; PYTHONIOENCODING = 'utf-8' }
}

function Test-WebLocalYT {
    try {
        $c = New-Object Net.Sockets.TcpClient
        $ok = $c.ConnectAsync('127.0.0.1', $PuertoLocalYT).Wait(300)
        $c.Close(); return $ok
    } catch { return $false }
}

# La web de este PC es la que escucha en su puerto.
function Stop-WebLocalYT {
    $conn = Get-NetTCPConnection -LocalPort $PuertoLocalYT -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($conn) { try { Stop-Process -Id $conn.OwningProcess -Force } catch {} }
}

function Set-EstadoSrvYT([string]$texto, [string]$color = '#F2C46D') {
    Set-Estado $texto $color
    if ($script:modo -eq 'youtube' -and $texto) { $ui.TxtYTResumen.Text = $texto }
}

# Máquina de pasos: cada tick mira si el paso en curso ha terminado y lanza el siguiente.
# Con -SoloActualizar solo mira si hay código nuevo (y si lo hay, sigue hasta reiniciar la web).
function Start-ServidorLocalYT([switch]$SoloActualizar) {
    if (-not $script:ytServidorLocal -or $script:srv) { return }
    $script:srvUltimaRevision = Get-Date
    try {
        $script:srv = @{ paso = 'sha'; soloActualizar = [bool]$SoloActualizar; tarea = (New-Cliente).DownloadStringTaskAsync("https://github.com/$RepoValora.git/info/refs?service=git-upload-pack") }
    } catch { $script:srv = @{ paso = 'programas' } }
    $timerSrv.Start()
}

$timerSrv = New-Object System.Windows.Threading.DispatcherTimer
$timerSrv.Interval = [TimeSpan]::FromMilliseconds(700)
$timerSrv.Add_Tick({
    $s = $script:srv
    if (-not $s) { $timerSrv.Stop(); return }
    try {
        switch ($s.paso) {
            'sha' {
                if (-not $s.tarea.IsCompleted) { return }
                $sha = if (-not $s.tarea.IsFaulted -and $s.tarea.Result -match '([0-9a-f]{40}) refs/heads/main') { $Matches[1] } else { '' }
                $v = Get-VersionLocal
                if ($sha -and ($sha -ne $v.resubidaSha -or -not (Test-Path (Join-Path $ResubidaDir 'web.py')))) {
                    Set-EstadoSrvYT 'Bajando el programa de resubida…'
                    $zip = Join-Path $env:TEMP "valora-resubida-$sha.zip"
                    $s.sha = $sha; $s.zip = $zip; $s.paso = 'zip'
                    $s.tarea = (New-Cliente).DownloadFileTaskAsync("https://codeload.github.com/$RepoValora/zip/$sha", $zip)
                } elseif ($s.soloActualizar -and (Test-WebLocalYT)) { $script:srv = $null }
                else { $s.paso = 'programas' }
            }
            'zip' {
                if (-not $s.tarea.IsCompleted) { return }
                if ($s.tarea.IsFaulted) { throw "no se ha podido bajar el programa de resubida: $($s.tarea.Exception.GetBaseException().Message)" }
                # Solo se escriben los ficheros que trae el programa; los datos de este PC no vienen en él.
                Add-Type -AssemblyName System.IO.Compression.FileSystem
                $z = [IO.Compression.ZipFile]::OpenRead($s.zip)
                try {
                    foreach ($e in $z.Entries) {
                        if ($e.FullName -notmatch '^[^/]+/resubida/(.+)$' -or $e.FullName.EndsWith('/')) { continue }
                        $destino = Join-Path $ResubidaDir ($Matches[1] -replace '/', '\')
                        [void](New-Item -ItemType Directory -Force (Split-Path $destino))
                        [IO.Compression.ZipFileExtensions]::ExtractToFile($e, $destino, $true)
                    }
                } finally { $z.Dispose(); Remove-Item $s.zip -Force -ErrorAction SilentlyContinue }
                if (-not (Test-Path (Join-Path $ResubidaDir 'web.py'))) { throw 'el programa de resubida no viene en esta versión de Valora.' }
                $v = Get-VersionLocal
                $v | Add-Member -NotePropertyName resubidaSha -NotePropertyValue $s.sha -Force
                Save-VersionLocal $v
                Write-LogUpd "programa de resubida actualizado a $($s.sha)"
                $s.reiniciar = $true
                $s.paso = 'programas'
            }
            'programas' {
                $prog = Get-ProgramasYT
                $falta = @($prog.Keys | Where-Object { -not $prog[$_] })
                if ($falta.Count) {
                    $n = $falta[0]
                    if ($s["intentado_$n"]) { throw "no se ha podido instalar $($NombreYT[$n]). Instálalo a mano y vuelve a abrir Valora." }
                    $s["intentado_$n"] = $true
                    Set-EstadoSrvYT "Instalando $($NombreYT[$n]), que falta en este PC (puede pedir permiso de administrador)…"
                    $alcance = if ($n -eq 'node') { '' } else { ' --scope user' }
                    $s.proc = Start-ProcesoYT 'winget' "install -e --id $($WingetYT[$n])$alcance --silent --accept-source-agreements --accept-package-agreements --disable-interactivity" $env:TEMP
                    $s.paso = 'instalando'
                    return
                }
                $s.prog = $prog
                Set-EstadoSrvYT 'Comprobando las librerías de Python…'
                $s.proc = Start-ProcesoYT $prog.python '-m pip install -q --disable-pip-version-check -r requirements.txt' $ResubidaDir (Get-EntornoYT $prog)
                $s.paso = 'pip'
            }
            'instalando' { if ($s.proc.HasExited) { $s.paso = 'programas' } }
            'pip' {
                if (-not $s.proc.HasExited) { return }
                if ($s.proc.ExitCode -ne 0) { throw 'no se han podido instalar las librerías de Python (pip).' }
                # Usuario propio de Valora en su web: la contraseña la inventa y la guarda cifrada.
                $clave = $null
                if ($script:ytClaveLocal) {
                    try { $clave = [Runtime.InteropServices.Marshal]::PtrToStringBSTR([Runtime.InteropServices.Marshal]::SecureStringToBSTR((ConvertTo-SecureString $script:ytClaveLocal))) } catch {}
                }
                if (-not $clave) {
                    $clave = -join ((48..57) + (65..90) + (97..122) | Get-Random -Count 24 | ForEach-Object { [char]$_ })
                    $script:ytClaveLocal = ConvertTo-SecureString $clave -AsPlainText -Force | ConvertFrom-SecureString
                    Save-Config
                }
                $s.clave = $clave
                $s.proc = Start-ProcesoYT $s.prog.python "web.py usuario valora $clave" $ResubidaDir (Get-EntornoYT $s.prog)
                $s.paso = 'usuario'
            }
            'usuario' {
                if (-not $s.proc.HasExited) { return }
                if ($s.reiniciar -and (Test-WebLocalYT)) {
                    # Código nuevo: se reinicia la web, salvo que esté trabajando (se espera a que acabe).
                    if ($script:ytEstado -and $script:ytEstado.trabajando) { return }
                    Stop-WebLocalYT
                    $s.reiniciar = $false
                    return
                }
                if (-not (Test-WebLocalYT)) {
                    Set-EstadoSrvYT 'Arrancando la resubida en este PC…'
                    [void](Start-ProcesoYT $s.prog.python 'web.py' $ResubidaDir (Get-EntornoYT $s.prog))
                }
                $s.hasta = (Get-Date).AddSeconds(60)
                $s.paso = 'esperar'
            }
            'esperar' {
                if (-not (Test-WebLocalYT)) {
                    if ((Get-Date) -gt $s.hasta) { throw 'la resubida no ha arrancado en 60 s.' }
                    return
                }
                $clave = $s.clave
                $script:srv = $null
                Invoke-YT 'POST' '/api/entrar' @{ usuario = 'valora'; 'contraseña' = $clave } {
                    param($res, $err)
                    if ($err) { Set-EstadoSrvYT "No se ha podido entrar en la resubida de este PC: $err" '#F28B82'; return }
                    Set-TokenYT $res.token
                    $script:ytUsuario = 'valora'
                    $ui.YTServidor.Visibility = 'Collapsed'
                    Set-EstadoSrvYT 'Resubida lista en este PC.' '#81C995'
                    $script:ytPidiendoEstado = $null; $script:ytCargando = $null
                    Get-EstadoYT; Get-VideosYT
                }
            }
        }
    } catch {
        $script:srv = $null
        Write-LogUpd ('resubida local: ' + $_.Exception.Message)
        Set-EstadoSrvYT ('Resubida: ' + $_.Exception.Message) '#F28B82'
    }
})

function Get-TokenYT {
    if (-not $script:ytToken) { return $null }
    try {
        $seguro = ConvertTo-SecureString $script:ytToken -ErrorAction Stop
        $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($seguro)
        try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr) } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
    } catch { return $null }
}

function Set-TokenYT([string]$token) {
    $script:ytToken = if ($token) { ConvertTo-SecureString $token -AsPlainText -Force | ConvertFrom-SecureString } else { $null }
    Save-Config
}

function Invoke-YT([string]$metodo, [string]$ruta, $cuerpo, [scriptblock]$alTerminar, $ctx = $null) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072
    $wc = New-Object System.Net.WebClient
    $wc.Encoding = [System.Text.Encoding]::UTF8
    $wc.Headers['User-Agent'] = 'Valora'
    $wc.Headers['Accept'] = 'application/json'
    $token = Get-TokenYT
    if ($token) { $wc.Headers['Authorization'] = 'Bearer ' + $token }
    $url = (Get-UrlYT) + $ruta
    try {
        if ($metodo -eq 'GET') {
            $tarea = $wc.DownloadStringTaskAsync($url)
        } else {
            $wc.Headers['Content-Type'] = 'application/json; charset=utf-8'
            $tarea = $wc.UploadStringTaskAsync($url, $metodo, ($cuerpo | ConvertTo-Json -Depth 4 -Compress))
        }
    } catch {
        & $alTerminar $null $_.Exception.Message $ctx
        return
    }
    [void]$script:httpPend.Add(@{ tarea = $tarea; alTerminar = $alTerminar; ctx = $ctx; json = $true })
    $timerHttp.Start()
}

function Show-ServidorYT([string]$mensaje = '', [string]$color = '#8C929C') {
    $ui.YTUrl.Text = $script:ytUrl
    if (-not $ui.YTUsuario.Text) { $ui.YTUsuario.Text = $script:ytUsuario }
    if ($mensaje) { $ui.TxtYTServidorEstado.Text = $mensaje; $ui.TxtYTServidorEstado.Foreground = Brush $color }
    $ui.YTServidor.Visibility = 'Visible'
}

# Un 401 es que la sesión ya no vale (caducó o cambió la contraseña): se vuelve a pedir.
function Test-CaducadoYT {
    if ($script:httpCodigo -ne 401) { return $false }
    Set-TokenYT $null
    Show-ServidorYT 'La sesión ha caducado o ha cambiado la contraseña. Vuelve a entrar.' '#F2C46D'
    return $true
}

function Show-ErrorRedYT([string]$err) {
    if (Test-CaducadoYT) { return }
    Show-ServidorYT ("No se llega a la web: $err. Comprueba que está arrancada en el PC de Rubén; " +
        'si la ha reiniciado, la dirección cambia y hay que pegar la nueva.') '#F28B82'
}

function Enter-YT {
    $url = $ui.YTUrl.Text.Trim().TrimEnd('/')
    if ($url -and $url -notmatch '^https?://') { $url = 'https://' + $url }
    $usuario = $ui.YTUsuario.Text.Trim()
    $clave = $ui.YTClave.Password
    if (-not $usuario -or -not $clave) { Show-ServidorYT 'Escribe el usuario y la contraseña de la web.' '#F2C46D'; return }
    $script:ytUrl = $url; $script:ytUsuario = $usuario
    $ui.YTUrl.Text = $url
    Set-TokenYT $null
    $ui.BtnYTEntrar.IsEnabled = $false
    Show-ServidorYT 'Entrando…'
    Invoke-YT 'POST' '/api/entrar' @{ usuario = $usuario; 'contraseña' = $clave } {
        param($res, $err)
        $ui.BtnYTEntrar.IsEnabled = $true
        if ($err) { Show-ServidorYT "No se ha podido entrar: $err" '#F28B82'; return }
        Set-TokenYT $res.token
        $ui.YTClave.Password = ''
        $ui.TxtYTServidorEstado.Text = ''
        $ui.YTServidor.Visibility = 'Collapsed'
        Get-VideosYT
        Get-EstadoYT
    }
}

function Get-ValorCombo($combo) {
    if ($combo.SelectedItem -and $null -ne $combo.SelectedItem.Tag) { return [string]$combo.SelectedItem.Tag }
    return ''
}

function Get-VideosYT {
    if (($script:ytCargando -and ((Get-Date) - $script:ytCargando).TotalSeconds -lt 60) -or -not (Get-TokenYT)) { return }
    $script:ytCargando = Get-Date
    if (-not $script:ytVideos.Count) { $ui.TxtYTResumen.Text = 'Cargando el listado…' }
    Invoke-YT 'GET' '/api/videos' $null {
        param($res, $err)
        $script:ytCargando = $null
        if ($err) { Show-ErrorRedYT $err; return }
        $script:ytVideos = @($res.videos)
        $actual = Get-ValorCombo $ui.YTPlaylist
        $ui.YTPlaylist.Items.Clear()
        foreach ($p in @(@('Todas las playlists', ''), @('Sin playlist', '-')) + @($res.playlists | ForEach-Object { , @($_, $_) })) {
            $item = New-Object System.Windows.Controls.ComboBoxItem
            $item.Content = $p[0]; $item.Tag = $p[1]
            [void]$ui.YTPlaylist.Items.Add($item)
            if ($p[1] -eq $actual) { $ui.YTPlaylist.SelectedItem = $item }
        }
        if ($ui.YTPlaylist.SelectedIndex -lt 0) { $ui.YTPlaylist.SelectedIndex = 0 }
        $resubidos = @($script:ytVideos | Where-Object { $_.resubido }).Count
        $ui.TxtYTResumen.Text = "$($script:ytVideos.Count) vídeos · $resubidos resubidos · listado del $($res.generado)"
        Update-ListaYT
    }
}

function Get-EstadoVideoYT($v) {
    if ($v.resubido) { return 'Resubido' }
    if ($v.cola) { return "En cola: $($v.cola)" }
    if ($v.descargado) { return 'Descargado' }
    return ''
}

function Update-ListaYT {
    if ($script:ytPintando) { return }
    $texto = $ui.YTBuscar.Text.Trim().ToLower()
    $playlist = Get-ValorCombo $ui.YTPlaylist
    $tipo = Get-ValorCombo $ui.YTTipo
    $est = Get-ValorCombo $ui.YTEstado
    $es = [Globalization.CultureInfo]::GetCultureInfo('es-ES')
    $filas = New-Object 'System.Collections.ObjectModel.ObservableCollection[object]'
    foreach ($v in $script:ytVideos) {
        $listas = @($v.playlists)
        if ($texto -and -not ($v.titulo.ToLower().Contains($texto) -or ([string]$v.fecha).Contains($texto))) { continue }
        if ($playlist -eq '-' -and $listas.Count) { continue }
        if ($playlist -and $playlist -ne '-' -and $listas -notcontains $playlist) { continue }
        if ($tipo -and $v.tipo -ne $tipo) { continue }
        if (($est -eq 'si' -and -not $v.resubido) -or ($est -eq 'no' -and $v.resubido) -or ($est -eq 'cola' -and -not $v.cola)) { continue }
        $f = New-Object ValoraFilaYT
        $f.Id = $v.id; $f.Titulo = $v.titulo; $f.Tipo = $v.tipo
        $f.Fecha = if ($v.fecha) { $v.fecha } else { '—' }
        $f.Playlists = if ($listas.Count) { $listas -join ', ' } else { 'Sin playlist' }
        $f.Vistas = ([long]$v.vistas).ToString('N0', $es)
        $f.Estado = Get-EstadoVideoYT $v
        $f.Url = if ($v.resubido) { "https://www.youtube.com/watch?v=$($v.resubido)" } else { $v.url }
        $f.Seleccionable = (-not $v.resubido) -and (-not $v.cola -or $v.cola -eq 'error')
        if (-not $f.Seleccionable) { [void]$script:ytSel.Remove($f.Id) }
        $filas.Add($f)
    }
    $script:ytFiltrados = $filas
    $script:ytPintando = $true
    try {
        $ui.YTLista.ItemsSource = $filas
        foreach ($f in $filas) { if ($script:ytSel.Contains($f.Id)) { [void]$ui.YTLista.SelectedItems.Add($f) } }
    } finally { $script:ytPintando = $false }
    Update-SeleccionYT
}

function Update-SeleccionYT {
    $total = if ($script:ytFiltrados) { $script:ytFiltrados.Count } else { 0 }
    $ui.TxtYTSel.Text = "$($script:ytSel.Count) seleccionados · $total en el filtro"
    $ui.BtnYTResubir.IsEnabled = $script:ytSel.Count -gt 0
}

function Send-ResubirYT {
    $ids = @($script:ytSel)
    if (-not $ids.Count) { return }
    $item = $ui.YTPrivacidad.SelectedItem
    $canal = if ($script:ytEstado -and $script:ytEstado.youtube_conectado) { $script:ytEstado.canal } else { $null }
    $aviso = if ($canal) { "al canal `"$canal`"" } else { "(YouTube todavía no está conectado: se subirán al canal que se conecte)" }
    $entradaSalida = [bool]$ui.ChkYTEntradaSalida.IsChecked
    $con = if ($entradaSalida) { ', con entrada y salida,' } else { '' }
    $r = [System.Windows.MessageBox]::Show($win, "Se van a volver a subir $($ids.Count) vídeos$con $aviso como $(([string]$item.Content).ToLower()).`n`n¿Seguir?",
        'Resubir vídeos', 'YesNo', 'Question')
    if ($r -ne 'Yes') { return }
    $ui.BtnYTResubir.IsEnabled = $false
    Invoke-YT 'POST' '/api/cola' @{ ids = $ids; privacidad = [string]$item.Tag; entrada_salida = $entradaSalida } {
        param($res, $err, $ids)
        if ($err) { Update-SeleccionYT; Show-ErrorRedYT $err; return }
        # Sin ventanas modales aquí: esto corre dentro del temporizador que atiende las peticiones.
        $script:ytSel.Clear()
        $script:ytLote = @($ids)
        $script:ytLoteAvisado = $false
        $ui.YTResubida.Visibility = 'Visible'
        Set-Estado "$($res.añadidos) vídeos añadidos a la cola." '#81C995'
        Get-VideosYT
        Get-EstadoYT
    } $ids
}

function Get-EstadoYT {
    # Si una petición se quedó sin respuesta, a los 30 s se deja pedir otra.
    if (($script:ytPidiendoEstado -and ((Get-Date) - $script:ytPidiendoEstado).TotalSeconds -lt 30) -or -not (Get-TokenYT)) { return }
    $script:ytPidiendoEstado = Get-Date
    Invoke-YT 'GET' '/api/estado' $null {
        param($res, $err)
        $script:ytPidiendoEstado = $null
        if ($err) {
            if (Test-CaducadoYT) { return }
            Set-ChipServidorYT $false $err
            return
        }
        Set-ChipServidorYT $true
        $script:ytEstado = $res
        # Al abrir Valora se pide releer el canal, para que salgan los vídeos subidos desde la última vez.
        if (-not $script:ytListadoPedido) {
            $script:ytListadoPedido = $true
            Invoke-YT 'POST' '/api/actualizar' @{} { param($r, $err) $script:ytUltimoListado = (Get-Date).AddSeconds(-30) }
        }
        Update-EstadoYT $res
    }
}

function Set-ChipServidorYT([bool]$ok, [string]$err = '') {
    $ui.TxtYTServidorChip.Text = if ($ok) { 'Servidor conectado' } else { 'Servidor sin conexión' }
    $ui.ChipYTServidor.Background = Brush $(if ($ok) { '#1F4A35' } else { '#4A2323' })
    $ui.ChipYTServidor.ToolTip = (Get-UrlYT) + $(if ($err) { "`n$err" } else { '' })
}

function Update-CredYT($e) {
    if (-not $e) { $ui.TxtYTCredEstado.Text = ''; return }
    if ($e.credenciales) {
        $ui.TxtYTCredEstado.Text = "Credenciales guardadas ($($e.client_id)). Falta el paso 2."
        $ui.TxtYTCredEstado.Foreground = Brush '#81C995'
    } else {
        $ui.TxtYTCredEstado.Text = 'Faltan las credenciales (paso 1). Cópialas en Google con su botón de copiar: se rellenan solas.'
        $ui.TxtYTCredEstado.Foreground = Brush '#F2C46D'
    }
}

function Save-CredYT {
    $id = $ui.YTClientId.Text.Trim()
    $secreto = $ui.YTClientSecret.Password.Trim()
    if ($id.StartsWith('{')) {
        # Se ha pegado el JSON que descarga Google: se sacan de ahí los dos datos.
        try {
            $j = $id | ConvertFrom-Json
            $c = if ($j.installed) { $j.installed } elseif ($j.web) { $j.web } else { $j }
            $id = [string]$c.client_id; $secreto = [string]$c.client_secret
        } catch { $ui.TxtYTCredEstado.Text = 'El JSON pegado no es válido.'; $ui.TxtYTCredEstado.Foreground = Brush '#F28B82'; return }
    }
    $ui.BtnYTGuardarCred.IsEnabled = $false
    $script:ytMensajeCredHasta = (Get-Date).AddSeconds(20)
    Invoke-YT 'POST' '/api/credenciales' @{ client_id = $id; client_secret = $secreto } {
        param($res, $err)
        $ui.BtnYTGuardarCred.IsEnabled = $true
        if ($err) {
            if (Test-CaducadoYT) { return }
            $ui.TxtYTCredEstado.Text = "No se han guardado: $err"; $ui.TxtYTCredEstado.Foreground = Brush '#F28B82'; return
        }
        $ui.YTClientId.Text = ''; $ui.YTClientSecret.Password = ''
        $ui.TxtYTCredEstado.Text = "Guardadas ($($res.client_id)). Ahora el paso 2."
        $ui.TxtYTCredEstado.Foreground = Brush '#81C995'
        Get-EstadoYT
    }
}

function New-TextoYT([string]$texto, [string]$color = '#ECE8E1', [double]$tam = 13) {
    $t = New-Object System.Windows.Controls.TextBlock
    $t.Text = $texto; $t.Foreground = Brush $color; $t.FontSize = $tam; $t.TextWrapping = 'Wrap'
    return $t
}

function Update-EstadoYT($e) {
    $ui.BtnYTAbrirCanal.Visibility = if ($e.youtube_conectado -and $e.canal_id) { 'Visible' } else { 'Collapsed' }
    if ($e.youtube_conectado) {
        $ui.TxtYTCanal.Text = 'Sube al canal: ' + $(if ($e.canal) { $e.canal } else { 'conectado' })
        $ui.ChipYTCanal.Background = Brush '#1F4A35'
    } elseif ($e.conectando) {
        $ui.TxtYTCanal.Text = 'Esperando login de Google…'; $ui.ChipYTCanal.Background = Brush '#5A4512'
    } else {
        $ui.TxtYTCanal.Text = 'YouTube sin conectar'; $ui.ChipYTCanal.Background = Brush '#4A2323'
    }
    $ui.BtnYTConectar.Visibility = if ($e.conectando) { 'Collapsed' } else { 'Visible' }
    # Un mensaje recién puesto por «Guardar» se deja leer 20 s antes de refrescarlo.
    if ($ui.YTCred.Visibility -eq 'Visible' -and -not $ui.YTClientId.IsKeyboardFocusWithin -and (Get-Date) -gt $script:ytMensajeCredHasta) { Update-CredYT $e }
    $ui.BtnYTConectar.Content = if ($e.youtube_conectado) { 'Cambiar cuenta' } else { 'Conectar YouTube' }

    if ($e.codigo) {
        $ui.TxtYTAviso.Text = "1. Pulsa «Abrir la página de Google» (o entra en $($e.url_verificacion) desde el móvil).`n" +
            "2. Pega el código con Ctrl+V (ya está copiado).`n3. Entra con la cuenta de Google dueña del canal y acepta. Esto se actualiza solo."
        $ui.TxtYTAviso.Foreground = Brush '#ECE8E1'
        if ($ui.TxtYTCodigo.Text -ne $e.codigo) { $ui.TxtYTCodigo.Text = $e.codigo }
        # Si la conexión la ha pedido este PC, el código va al portapapeles y se abre la página
        # de Google: solo hay que pegarlo con Ctrl+V. Si la pidió otro PC, aquí no se abre nada.
        if ($script:ytPidioCodigo) {
            $script:ytPidioCodigo = $false
            try { [System.Windows.Clipboard]::SetText($e.codigo) } catch {}
            if ($e.url_verificacion) { Start-Process ([string]$e.url_verificacion) }
            Set-Estado 'Código copiado. En la página de Google, pégalo con Ctrl+V.' '#81C995'
        }
        $ui.BtnYTAbrirGoogle.Tag = $e.url_verificacion
        $ui.YTCodigoCaja.Visibility = 'Visible'
        $ui.YTAviso.Visibility = 'Visible'
    } elseif ($e.error_conexion -and -not $e.youtube_conectado -and $ui.YTCred.Visibility -ne 'Visible') {
        $ui.TxtYTAviso.Text = if ($e.credenciales) { "No se ha podido conectar con YouTube: $($e.error_conexion)" } else {
            'Faltan las credenciales de la API: pulsa «Conectar YouTube».' }
        $ui.TxtYTAviso.Foreground = Brush '#F28B82'
        $ui.YTCodigoCaja.Visibility = 'Collapsed'
        $ui.YTAviso.Visibility = 'Visible'
    } elseif (-not $e.credenciales -and $ui.YTCred.Visibility -ne 'Visible') {
        $ui.TxtYTAviso.Text = 'Faltan las credenciales de la API: pulsa «Conectar YouTube».'
        $ui.TxtYTAviso.Foreground = Brush '#F2C46D'
        $ui.YTCodigoCaja.Visibility = 'Collapsed'
        $ui.YTAviso.Visibility = 'Visible'
    } else {
        $ui.YTAviso.Visibility = 'Collapsed'
    }

    if ($e.pausa_hasta) {
        $ui.TxtYTTrabajo.Text = "En pausa hasta las $($e.pausa_hasta): $($e.motivo_pausa)"; $ui.ChipYTTrabajo.Background = Brush '#3A2E12'
        $ui.ChipYTTrabajo.Visibility = 'Visible'
    } elseif ($e.trabajando) {
        $ui.TxtYTTrabajo.Text = "Trabajando en $($e.trabajando)"; $ui.ChipYTTrabajo.Background = Brush '#1E2A24'
        $ui.ChipYTTrabajo.Visibility = 'Visible'
    } else { $ui.ChipYTTrabajo.Visibility = 'Collapsed' }
    $ui.BtnYTActualizar.IsEnabled = -not $e.actualizando
    $ui.BtnYTActualizar.Content = if ($e.actualizando) { 'Actualizando…' } else { 'Actualizar listado' }

    $partes = @($e.cuenta.PSObject.Properties | ForEach-Object { "$($_.Value) $($_.Name)" })
    $ui.TxtYTCola.Text = if ($partes.Count) { $partes -join ' · ' } else { 'Vacía.' }
    $ui.YTCola.Children.Clear()
    $cola = @($e.cola)
    [array]::Reverse($cola)
    foreach ($item in ($cola | Select-Object -First 150)) {
        $b = New-Object System.Windows.Controls.Border
        $b.BorderBrush = Brush '#2A2E36'; $b.BorderThickness = '0,0,0,1'; $b.Padding = '0,6'
        $g = New-Object System.Windows.Controls.DockPanel
        $der = New-Object System.Windows.Controls.StackPanel
        $der.Orientation = 'Horizontal'; $der.VerticalAlignment = 'Top'
        [System.Windows.Controls.DockPanel]::SetDock($der, 'Right')
        if ($item.estado -eq 'hecho' -and $item.nuevo) {
            $l = New-Object System.Windows.Controls.Button
            $l.Style = $win.FindResource('Plano'); $l.Padding = '6,2'; $l.Foreground = Brush '#81C995'; $l.FontSize = 12.5
            $l.Content = 'hecho ↗'; $l.Tag = "https://www.youtube.com/watch?v=$($item.nuevo)"; $l.ToolTip = 'Abrir el vídeo nuevo'
            $l.Add_Click({ Start-Process $this.Tag })
            [void]$der.Children.Add($l)
        } else {
            $color = switch ($item.estado) { 'error' { '#F28B82' } 'pendiente' { '#8C929C' } default { '#F2C46D' } }
            $t = New-TextoYT $item.estado $color 12.5; $t.Margin = '6,2'
            [void]$der.Children.Add($t)
        }
        if ($item.estado -eq 'pendiente' -or $item.estado -eq 'error') {
            $q = New-Object System.Windows.Controls.Button
            $q.Style = $win.FindResource('Plano'); $q.Padding = '6,2'; $q.Foreground = Brush '#ACB1B9'; $q.FontSize = 12
            $q.Content = 'Quitar'; $q.Tag = $item.id
            $q.Add_Click({
                Invoke-YT 'POST' '/api/cola/quitar' @{ ids = @($this.Tag) } {
                    param($res, $err)
                    if ($err) { Show-ErrorRedYT $err; return }
                    Get-EstadoYT; Get-VideosYT
                }
            })
            [void]$der.Children.Add($q)
        }
        $izq = New-Object System.Windows.Controls.StackPanel
        [void]$izq.Children.Add((New-TextoYT $item.titulo '#ECE8E1' 13))
        if ($item.entrada_salida) { [void]$izq.Children.Add((New-TextoYT 'con entrada y salida' '#C8A15A' 11.5)) }
        if ($item.error) { [void]$izq.Children.Add((New-TextoYT $item.error '#F28B82' 12)) }
        [void]$g.Children.Add($der); [void]$g.Children.Add($izq)
        $b.Child = $g
        [void]$ui.YTCola.Children.Add($b)
    }
    Update-ResubidaYT $e
}

# --- Panel de la última resubida: un vídeo por fila con sus pasos, la compilación (el vídeo ya
# rehecho con entrada y salida, que se baja del servidor) y el enlace del vídeo nuevo en YouTube.
$script:ytLote = @()
$script:ytLoteAvisado = $true

function New-BotonYT([string]$texto, [string]$color, $tag, [string]$ayuda) {
    $l = New-Object System.Windows.Controls.Button
    $l.Style = $win.FindResource('Plano'); $l.Padding = '8,3'; $l.Margin = '6,0,0,0'; $l.FontSize = 12.5
    $l.Foreground = Brush $color; $l.Content = $texto; $l.Tag = $tag; $l.ToolTip = $ayuda
    return $l
}

function Open-CompilacionYT($boton) {
    $id = [string]$boton.Tag
    $carpeta = Join-Path $env:TEMP 'Valora\compilaciones'
    [void](New-Item -ItemType Directory -Force $carpeta)
    $destino = Join-Path $carpeta "$id.editado.mp4"
    if (Test-Path $destino) { Start-Process $destino; return }
    $boton.IsEnabled = $false; $boton.Content = 'Bajando…'
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072
    $wc = New-Object System.Net.WebClient
    $wc.Headers['User-Agent'] = 'Valora'
    $token = Get-TokenYT
    if ($token) { $wc.Headers['Authorization'] = 'Bearer ' + $token }
    $parcial = "$destino.parcial"
    $tarea = $wc.DownloadFileTaskAsync((Get-UrlYT) + "/api/editado/$id", $parcial)
    [void]$script:httpPend.Add(@{ tarea = $tarea; json = $false; ctx = @{ boton = $boton; parcial = $parcial; destino = $destino }; alTerminar = {
        param($res, $err, $ctx)
        $ctx.boton.IsEnabled = $true; $ctx.boton.Content = 'Ver compilación'
        if ($err) {
            Remove-Item $ctx.parcial -ErrorAction SilentlyContinue
            if (Test-CaducadoYT) { return }
            Set-Estado "No se ha podido bajar la compilación: $err" '#F28B82'; return
        }
        Move-Item $ctx.parcial $ctx.destino -Force
        Start-Process $ctx.destino
    } })
    $timerHttp.Start()
}

function Get-ResumenYT($items) {
    $hechos = @($items | Where-Object { $_.estado -eq 'hecho' })
    $errores = @($items | Where-Object { $_.estado -eq 'error' })
    $lineas = @("Resubida: $($hechos.Count) subidos" + $(if ($errores.Count) { ", $($errores.Count) con error" } else { '' }), '')
    foreach ($i in $hechos) { $lineas += "$($i.titulo): https://www.youtube.com/watch?v=$($i.nuevo)" }
    foreach ($i in $errores) { $lineas += "$($i.titulo): error ($($i.error))" }
    return ($lineas -join "`r`n")
}

# Cuánto lleva un vídeo (0 a 1): cada paso pesa lo que suele tardar, y el paso en curso
# suma su porcentaje según lo que cuenta el servidor.
function Get-AvanceYT($item, $prog) {
    if ($item.estado -in 'hecho', 'error') { return 1.0 }
    $pesos = if ($item.entrada_salida) { [ordered]@{ descargando = 0.2; editando = 0.45; subiendo = 0.3; limpiando = 0.05 } } else { [ordered]@{ descargando = 0.3; subiendo = 0.65; limpiando = 0.05 } }
    if (-not $pesos.Contains([string]$item.estado)) { return 0.0 }
    $avance = 0.0
    foreach ($paso in $pesos.Keys) {
        if ($paso -eq $item.estado) {
            if ($prog -and [string]$prog.id -eq [string]$item.id) { $avance += $pesos[$paso] * [double]$prog.porcentaje / 100 }
            break
        }
        $avance += $pesos[$paso]
    }
    return $avance
}

# Abre el canal donde se ve lo último subido: la pestaña Shorts o Vídeos de la página pública
# (ya ordenadas por más recientes), o YouTube Studio si lo subido es privado, que en la página
# pública no aparece.
# El canal se abre en un perfil de Chrome propio, con la sesión de la cuenta dueña del canal
# iniciada (la primera vez hay que entrar en él). Sin Chrome, en el navegador por defecto.
function Open-WebCanalYT([string]$url) {
    $chrome = @("$env:ProgramFiles\Google\Chrome\Application\chrome.exe", "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
        "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $chrome) { Start-Process $url; return }
    if (-not (Test-Path "$env:LOCALAPPDATA\Google\Chrome\User Data\Valora YouTube\Cookies") -and
        -not (Test-Path "$env:LOCALAPPDATA\Google\Chrome\User Data\Valora YouTube\Network\Cookies")) {
        Set-Estado 'Primera vez: en la ventana de Chrome que se abre, entra con la cuenta de Google del canal. Luego ya no hace falta.' '#F2C46D'
    }
    Start-Process $chrome -ArgumentList '--profile-directory="Valora YouTube"', $url
}

function Open-CanalYT($items = @()) {
    $id = if ($script:ytEstado) { [string]$script:ytEstado.canal_id } else { '' }
    if (-not $id) { return }
    $hechos = @($items | Where-Object { $_.estado -eq 'hecho' })
    if (-not $hechos.Count -or @($hechos | Where-Object { $_.privacidad -eq 'private' }).Count) {
        Open-WebCanalYT "https://studio.youtube.com/channel/$id/videos/upload"; return
    }
    $ids = @($hechos | ForEach-Object { [string]$_.id })
    $shorts = @($script:ytVideos | Where-Object { $ids -contains [string]$_.id -and $_.tipo -eq 'Short' }).Count
    $pestaña = if ($shorts -ge ($hechos.Count / 2)) { 'shorts' } else { 'videos' }
    Open-WebCanalYT "https://www.youtube.com/channel/$id/$pestaña"
}

function Update-ResubidaYT($e) {
    $porId = @{}
    foreach ($i in @($e.cola)) { $porId[[string]$i.id] = $i }
    # Sin resubida lanzada desde aquí, el panel sigue lo que haya en marcha en el servidor.
    $ids = @($script:ytLote | Where-Object { $porId.ContainsKey([string]$_) })
    if (-not $ids.Count) { $ids = @($e.cola | Where-Object { $_.estado -notin 'hecho', 'error' } | ForEach-Object { [string]$_.id }) }
    $ui.BtnYTVerResubida.Visibility = if ($ids.Count) { 'Visible' } else { 'Collapsed' }
    if (-not $ids.Count) { $ui.YTResubida.Visibility = 'Collapsed'; return }
    $items = @($ids | ForEach-Object { $porId[[string]$_] })
    $terminados = @($items | Where-Object { $_.estado -in 'hecho', 'error' }).Count
    $acabado = $terminados -eq $items.Count
    if ($acabado -and -not $script:ytLoteAvisado) {
        $script:ytLoteAvisado = $true
        $ui.YTResubida.Visibility = 'Visible'
        Set-Estado 'Resubida terminada. Abriendo el canal con los últimos vídeos.' '#81C995'
        if (@($items | Where-Object { $_.estado -eq 'hecho' }).Count) { Open-CanalYT $items }
    }
    $timerYT.Interval = [TimeSpan]::FromSeconds($(if ($ui.YTResubida.Visibility -eq 'Visible' -and -not $acabado) { 1.5 } else { 5 }))
    if ($ui.YTResubida.Visibility -ne 'Visible') { return }

    $hechos = @($items | Where-Object { $_.estado -eq 'hecho' }).Count
    $errores = @($items | Where-Object { $_.estado -eq 'error' }).Count
    $total = 0.0
    foreach ($i in $items) { $total += Get-AvanceYT $i $e.progreso }
    $porcentaje = [math]::Floor(100 * $total / $items.Count)
    $ui.BarraYTResubida.Value = $porcentaje
    $ui.BarraYTResubida.Foreground = Brush $(if ($acabado -and -not $errores) { '#81C995' } elseif ($acabado) { '#F2C46D' } else { '#C4302B' })
    $ui.TxtYTResubida.Text = if ($acabado) {
        "Terminada: $hechos subidos" + $(if ($errores) { ", $errores con error" } else { '' }) + '.'
    } elseif ($e.pausa_hasta) { "$terminados de $($items.Count) · $porcentaje % · en pausa hasta las $($e.pausa_hasta): $($e.motivo_pausa)" } else { "$terminados de $($items.Count) terminados · $porcentaje %" }
    $ui.TxtYTResubida.Foreground = Brush $(if ($acabado -and -not $errores) { '#81C995' } elseif ($acabado) { '#F2C46D' } else { '#8C929C' })

    $ui.YTResubidaLista.Children.Clear()
    if ($acabado) {
        $copiar = New-BotonYT 'Copiar resumen' '#14161A' (Get-ResumenYT $items) 'Copia los títulos con su enlace de YouTube'
        $copiar.Background = Brush '#ECE8E1'; $copiar.FontWeight = 'SemiBold'; $copiar.Margin = '0,0,0,10'; $copiar.HorizontalAlignment = 'Left'
        $copiar.Add_Click({ try { [System.Windows.Clipboard]::SetText([string]$this.Tag); Set-Estado 'Resumen copiado.' '#81C995' } catch {} })
        $canal = New-BotonYT 'Abrir el canal ↗' '#FFFFFF' $items 'Lo último subido: Shorts o Vídeos del canal (YouTube Studio si es privado)'
        $canal.Background = Brush '#C4302B'; $canal.FontWeight = 'SemiBold'; $canal.Margin = '8,0,0,0'
        $canal.Add_Click({ Open-CanalYT $this.Tag })
        $botones = New-Object System.Windows.Controls.StackPanel
        $botones.Orientation = 'Horizontal'; $botones.Margin = '0,0,0,10'
        $copiar.Margin = '0'
        [void]$botones.Children.Add($copiar); [void]$botones.Children.Add($canal)
        [void]$ui.YTResubidaLista.Children.Add($botones)
    }
    $pasos = @(@('descargando', 'Bajar'), @('editando', 'Editar'), @('subiendo', 'Subir'), @('limpiando', 'Limpiar'))
    foreach ($item in $items) {
        $b = New-Object System.Windows.Controls.Border
        $b.BorderBrush = Brush '#363C47'; $b.BorderThickness = '0,0,0,1'; $b.Padding = '0,8'
        $g = New-Object System.Windows.Controls.DockPanel
        $der = New-Object System.Windows.Controls.StackPanel
        $der.Orientation = 'Horizontal'; $der.VerticalAlignment = 'Center'
        [System.Windows.Controls.DockPanel]::SetDock($der, 'Right')
        # Una vez subido, la compilación se borra del servidor: el vídeo de YouTube es esa misma compilación.
        if ($item.entrada_salida -and ($item.editado -or $item.estado -eq 'subiendo') -and $item.estado -notin 'limpiando', 'hecho', 'error') {
            $c = New-BotonYT 'Ver compilación' '#C8A15A' ([string]$item.id) 'El vídeo con la entrada y la salida, tal como se sube'
            $c.Add_Click({ Open-CompilacionYT $this })
            [void]$der.Children.Add($c)
        }
        if ($item.estado -eq 'hecho' -and $item.nuevo) {
            $l = New-BotonYT 'YouTube ↗' '#81C995' "https://www.youtube.com/watch?v=$($item.nuevo)" 'Abrir el vídeo nuevo'
            $l.Add_Click({ Start-Process $this.Tag })
            [void]$der.Children.Add($l)
        }
        $izq = New-Object System.Windows.Controls.StackPanel
        [void]$izq.Children.Add((New-TextoYT $item.titulo '#ECE8E1' 13.5))
        $linea = New-Object System.Windows.Controls.TextBlock
        $linea.FontSize = 12; $linea.Margin = '0,3,0,0'
        if ($item.estado -eq 'hecho') {
            $linea.Inlines.Add((New-Object System.Windows.Documents.Run ("Subido · youtu.be/$($item.nuevo)" + $(if ($item.entrada_salida) { ' · compilación borrada del PC' } else { '' })))); $linea.Foreground = Brush '#81C995'
        } elseif ($item.estado -eq 'error') {
            $linea.Inlines.Add((New-Object System.Windows.Documents.Run "Error: $($item.error)")); $linea.Foreground = Brush '#F28B82'; $linea.TextWrapping = 'Wrap'
        } else {
            # Bajar › Editar › Subir, con el paso en curso resaltado y los ya hechos en verde.
            $actual = [array]::IndexOf(@($pasos | ForEach-Object { $_[0] }), [string]$item.estado)
            $lista = if ($item.entrada_salida) { $pasos } else { @($pasos[0], $pasos[2], $pasos[3]) }
            $primero = $true
            foreach ($p in $lista) {
                if (-not $primero) { $s = New-Object System.Windows.Documents.Run '  ›  '; $s.Foreground = Brush '#4A505B'; $linea.Inlines.Add($s) }
                $primero = $false
                $n = [array]::IndexOf(@($pasos | ForEach-Object { $_[0] }), $p[0])
                $r = New-Object System.Windows.Documents.Run $(if ($n -eq $actual) { "$($p[1])…" } else { $p[1] })
                $r.Foreground = Brush $(if ($actual -lt 0) { '#8C929C' } elseif ($n -lt $actual) { '#81C995' } elseif ($n -eq $actual) { '#F2C46D' } else { '#6A707B' })
                if ($n -eq $actual) { $r.FontWeight = 'SemiBold' }
                $linea.Inlines.Add($r)
            }
            if ($actual -lt 0) { $r = New-Object System.Windows.Documents.Run '   (en espera)'; $r.Foreground = Brush '#6A707B'; $linea.Inlines.Add($r) }
        }
        [void]$izq.Children.Add($linea)
        $prog = $e.progreso
        if ($prog -and [string]$prog.id -eq [string]$item.id -and $item.estado -notin 'hecho', 'error') {
            # Lo que está haciendo ahora mismo, con su barra y su porcentaje.
            $barra = New-Object System.Windows.Controls.ProgressBar
            $barra.Height = 4; $barra.Minimum = 0; $barra.Maximum = 100; $barra.Value = [double]$prog.porcentaje
            $barra.Margin = '0,6,0,3'; $barra.BorderThickness = 0
            $barra.Background = Brush '#363C47'; $barra.Foreground = Brush '#F2C46D'
            [void]$izq.Children.Add($barra)
            [void]$izq.Children.Add((New-TextoYT "$($prog.texto) · $([math]::Floor([double]$prog.porcentaje)) %" '#CDCAC3' 12))
        }
        [void]$g.Children.Add($der); [void]$g.Children.Add($izq)
        $b.Child = $g
        [void]$ui.YTResubidaLista.Children.Add($b)
    }
}

function Set-Modo([string]$modo) {
    $yt = $modo -eq 'youtube'
    $script:modo = if ($yt) { 'youtube' } else { 'valora' }
    $ui.PanelYT.Visibility = if ($yt) { 'Visible' } else { 'Collapsed' }
    # En modo YouTube, lo del lateral que es de Valora (conversaciones, carpetas, fichas, agy) no pinta nada.
    foreach ($n in 'LateralArriba', 'LateralMedio', 'LateralAbajo') { $ui[$n].Visibility = if ($yt) { 'Collapsed' } else { 'Visible' } }
    # Cada modo con su cara: en YouTube el logo, el título y el color pasan a rojo.
    $ui.LogoTexto.Text = if ($yt) { 'YouTube' } else { 'Valora' }
    $ui.BtnEstilo.Visibility = if ($yt) { 'Collapsed' } else { 'Visible' }
    $ui.LogoFondo.Background = Brush $(if ($yt) { '#E62117' } else { '#C8A15A' })
    $ui.LogoLetra.FontFamily = if ($yt) { 'Segoe MDL2 Assets' } else { 'Segoe UI' }
    $ui.LogoLetra.Text = if ($yt) { [string][char]0xE768 } else { 'V' }
    $ui.LogoLetra.FontSize = if ($yt) { 13 } else { 17 }
    $ui.LogoLetra.Foreground = Brush $(if ($yt) { '#FFFFFF' } else { '#14161A' })
    $ui.Lateral.Background = Brush $(if ($yt) { '#1A1414' } else { '#14161A' })
    $win.Title = if ($yt) { 'Valora · YouTube' } else { 'Valora' }
    $ui.BtnModoYT.Background = Brush $(if ($yt) { '#C4302B' } else { '#00000000' })
    $ui.BtnModoValora.Background = Brush $(if ($yt) { '#00000000' } else { '#363C47' })
    if ($yt) {
        if (-not (Get-TokenYT)) {
            Show-ServidorYT 'Entra con el usuario y la contraseña de la web de resubida.'
            $ui.TxtYTResumen.Text = 'Sin conectar con la web.'
        } else {
            if (-not $script:ytVideos.Count) { Get-VideosYT }
            Get-EstadoYT
        }
        $timerYT.Start()
    } else {
        $timerYT.Stop()
    }
    Save-Config
}

# Mientras se ve el panel: la cola cada 5 s y el listado cada minuto (si no hay nada elegido,
# para no mover la lista mientras se selecciona).
$timerYT = New-Object System.Windows.Threading.DispatcherTimer
$timerYT.Interval = [TimeSpan]::FromSeconds(5)
$script:ytUltimoListado = Get-Date
$timerYT.Add_Tick({
    Get-EstadoYT
    if (((Get-Date) - $script:ytUltimoListado).TotalSeconds -ge 60) {
        $script:ytUltimoListado = Get-Date
        Update-UrlAutoYT
        if ($script:ytServidorLocal -and -not $script:srv -and
            (((Get-Date) - $script:srvUltimaRevision).TotalMinutes -ge 10 -or -not (Test-WebLocalYT))) { Start-ServidorLocalYT -SoloActualizar }
        if ($script:ytSel.Count -eq 0) { Get-VideosYT }
    }
})

$ui.BtnModoValora.Add_Click({ Set-Modo 'valora' })
$ui.BtnModoYT.Add_Click({ Set-Modo 'youtube' })
$ui.BtnYTServidor.Add_Click({
    if ($ui.YTServidor.Visibility -eq 'Visible') { $ui.YTServidor.Visibility = 'Collapsed' } else { Show-ServidorYT }
})
$ui.BtnYTEntrar.Add_Click({ Enter-YT })
$ui.YTClave.Add_KeyDown({ if ($_.Key -eq 'Return') { Enter-YT } })
$ui.BtnYTActualizar.Add_Click({
    Invoke-YT 'POST' '/api/actualizar' @{} { param($res, $err) if ($err) { Show-ErrorRedYT $err } else { Get-EstadoYT } }
})
$script:ytPidioCodigo = $false
function Start-ConexionYT($boton) {
    $boton.IsEnabled = $false
    $script:ytPidioCodigo = $true
    Invoke-YT 'POST' '/api/conectar' @{} {
        param($res, $err, $boton)
        $boton.IsEnabled = $true
        if ($err) { $script:ytPidioCodigo = $false; Show-ErrorRedYT $err; return }
        if ($res.ok) { $ui.YTCred.Visibility = 'Collapsed' }
        else {
            $script:ytPidioCodigo = $false
            $ui.TxtYTCredEstado.Text = "Google no deja conectar: $($res.error)"; $ui.TxtYTCredEstado.Foreground = Brush '#F28B82'
            $ui.YTCred.Visibility = 'Visible'
        }
        Get-EstadoYT
    } $boton
}

$ui.BtnYTConectar.Add_Click({
    if ($ui.YTCred.Visibility -eq 'Visible') { $ui.YTCred.Visibility = 'Collapsed'; return }
    # Con las credenciales ya puestas en la web, se pide el código directamente.
    if ($script:ytEstado -and $script:ytEstado.credenciales) { Start-ConexionYT $ui.BtnYTConectar; return }
    Update-CredYT $script:ytEstado
    $ui.YTCred.Visibility = 'Visible'
    # Sin credenciales, se abre directamente la página de Google Cloud donde están.
    if (-not ($script:ytEstado -and $script:ytEstado.credenciales)) { Start-Process ([string]$ui.BtnYTPaso4.Tag) }
})
$ui.BtnYTCredCerrar.Add_Click({ $ui.YTCred.Visibility = 'Collapsed' })

# Con el panel abierto se mira el portapapeles: lo que se copie en Google Cloud con su botón de
# copiar (el ID, el secreto o el JSON entero) se rellena solo, y con los dos datos se guarda.
$script:ytUltimoPortapapeles = ''
$timerPortapapeles = New-Object System.Windows.Threading.DispatcherTimer
$timerPortapapeles.Interval = [TimeSpan]::FromMilliseconds(700)
$timerPortapapeles.Add_Tick({
    if ($ui.YTCred.Visibility -ne 'Visible' -or $script:modo -ne 'youtube') { return }
    $t = ''
    try { if ([System.Windows.Clipboard]::ContainsText()) { $t = [System.Windows.Clipboard]::GetText().Trim() } } catch { return }
    if (-not $t -or $t -eq $script:ytUltimoPortapapeles) { return }
    $script:ytUltimoPortapapeles = $t
    $cambio = $false
    if ($t -match '^\{' -and $t -match 'client_id') { $ui.YTClientId.Text = $t; $cambio = $true }
    elseif ($t -match '^[\w.-]+\.apps\.googleusercontent\.com$') { $ui.YTClientId.Text = $t; $cambio = $true }
    elseif ($t -match '^GOCSPX-[\w-]+$') { $ui.YTClientSecret.Password = $t; $cambio = $true }
    if (-not $cambio) { return }
    $listo = $ui.YTClientId.Text.StartsWith('{') -or ($ui.YTClientId.Text -and $ui.YTClientSecret.Password)
    if ($listo) { Save-CredYT }
    else {
        $falta = if ($ui.YTClientId.Text) { 'el secreto' } else { 'el ID de cliente' }
        $ui.TxtYTCredEstado.Text = "Copiado. Ahora copia $falta en Google Cloud."
        $ui.TxtYTCredEstado.Foreground = Brush '#81C995'
        $script:ytMensajeCredHasta = (Get-Date).AddSeconds(60)
    }
})
$timerPortapapeles.Start()
foreach ($n in 'BtnYTPaso2', 'BtnYTPaso4') { $ui[$n].Add_Click({ Start-Process ([string]$this.Tag) }) }
$ui.BtnYTGuardarCred.Add_Click({ Save-CredYT })
$ui.BtnYTLoginGoogle.Add_Click({ Start-ConexionYT $ui.BtnYTLoginGoogle })
$ui.BtnYTCopiar.Add_Click({ if ($ui.TxtYTCodigo.Text) { [System.Windows.Clipboard]::SetText($ui.TxtYTCodigo.Text); Set-Estado 'Código copiado.' '#81C995' } })
$ui.BtnYTAbrirGoogle.Add_Click({
    if ($ui.TxtYTCodigo.Text) { try { [System.Windows.Clipboard]::SetText($ui.TxtYTCodigo.Text) } catch {} }
    if ($ui.BtnYTAbrirGoogle.Tag) { Start-Process ([string]$ui.BtnYTAbrirGoogle.Tag) }
    Set-Estado 'Código copiado. En la página de Google, pégalo con Ctrl+V.' '#81C995'
})
$ui.YTBuscar.Add_TextChanged({
    $ui.YTBuscarPista.Visibility = if ($ui.YTBuscar.Text) { 'Collapsed' } else { 'Visible' }
    Update-ListaYT
})
foreach ($c in 'YTPlaylist', 'YTTipo', 'YTEstado') { $ui[$c].Add_SelectionChanged({ Update-ListaYT }) }
$ui.YTLista.Add_SelectionChanged({
    if ($script:ytPintando) { return }
    foreach ($f in $_.RemovedItems) { [void]$script:ytSel.Remove($f.Id) }
    foreach ($f in $_.AddedItems) { if ($f.Seleccionable) { [void]$script:ytSel.Add($f.Id) } }
    Update-SeleccionYT
})
$ui.YTLista.Add_MouseDoubleClick({
    $f = $ui.YTLista.SelectedItem
    if ($f -and $f.Url) { Start-Process $f.Url }
})
$ui.BtnYTTodos.Add_Click({
    if (-not $script:ytFiltrados) { return }
    foreach ($f in $script:ytFiltrados) { if ($f.Seleccionable) { [void]$script:ytSel.Add($f.Id) } }
    $script:ytPintando = $true
    try { $ui.YTLista.SelectAll() } finally { $script:ytPintando = $false }
    Update-SeleccionYT
})
$ui.BtnYTNinguno.Add_Click({
    $script:ytSel.Clear()
    $script:ytPintando = $true
    try { $ui.YTLista.UnselectAll() } finally { $script:ytPintando = $false }
    Update-SeleccionYT
})
$ui.BtnYTResubir.Add_Click({ Send-ResubirYT })
$ui.BtnYTVerResubida.Add_Click({ $ui.YTResubida.Visibility = 'Visible'; if ($script:ytEstado) { Update-ResubidaYT $script:ytEstado } })
$ui.BtnYTAbrirCanal.Add_Click({ Open-CanalYT })
$ui.BtnYTResubidaCerrar.Add_Click({ $ui.YTResubida.Visibility = 'Collapsed' })

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

# El icono va con cada versión publicada. Se baja aparte (en segundo plano) cuando la versión
# instalada todavía no tiene el suyo, y luego se avisa a Windows para que refresque la caché de
# iconos; si no, los accesos directos siguen enseñando el viejo.
function Start-ActualizarIcono {
    $v = Get-VersionLocal
    if (-not $v.sha -or $v.iconoSha -eq $v.sha -or $script:updIcono -or $RepoValora -eq '__REPO__') { return }
    try {
        $script:updIcono = @{ sha = $v.sha; tarea = (New-Cliente).DownloadDataTaskAsync("https://raw.githubusercontent.com/$RepoValora/$($v.sha)/src/valora.ico") }
        $timerIcono.Start()
    } catch { $script:updIcono = $null; Write-LogUpd ('no se pudo bajar el icono: ' + $_.Exception.Message) }
}

$timerIcono = New-Object System.Windows.Threading.DispatcherTimer
$timerIcono.Interval = [TimeSpan]::FromMilliseconds(500)
$timerIcono.Add_Tick({
    if (-not $script:updIcono) { $timerIcono.Stop(); return }
    if (-not $script:updIcono.tarea.IsCompleted) { return }
    $u = $script:updIcono; $script:updIcono = $null; $timerIcono.Stop()
    if ($u.tarea.IsFaulted -or $u.tarea.IsCanceled) { Write-LogUpd 'no se pudo bajar el icono'; return }
    try {
        $datos = $u.tarea.Result
        if ($datos.Length -lt 6 -or $datos[0] -ne 0 -or $datos[2] -ne 1) { Write-LogUpd 'el icono descargado no es un .ico'; return }
        $cambia = -not (Test-Path $icono) -or ((Get-FileHash $icono -Algorithm SHA256).Hash -ne
            [BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash($datos)).Replace('-', ''))
        if ($cambia) {
            [IO.File]::WriteAllBytes($icono, $datos)
            Set-IconoVentana
            if (-not ('Valora.Shell' -as [type])) {
                Add-Type -Namespace Valora -Name Shell -MemberDefinition '[DllImport("shell32.dll")] public static extern void SHChangeNotify(int eventId, uint flags, IntPtr item1, IntPtr item2);'
            }
            [Valora.Shell]::SHChangeNotify(0x08000000, 0, [IntPtr]::Zero, [IntPtr]::Zero)
            $ie4 = Join-Path $env:WINDIR 'System32\ie4uinit.exe'
            if (Test-Path $ie4) { Start-Process $ie4 -ArgumentList '-show' -WindowStyle Hidden }
            Write-LogUpd "icono nuevo de la versión $($u.sha) instalado y caché de iconos refrescada"
        }
        $v = Get-VersionLocal
        $v | Add-Member -NotePropertyName iconoSha -NotePropertyValue $u.sha -Force
        Save-VersionLocal $v
    } catch { Write-LogUpd ('no se pudo instalar el icono: ' + $_.Exception.Message) }
})

# Solo se actualiza la Valora instalada. Una copia que se ejecute desde otra carpeta (pruebas)
# no se toca ni apunta versiones en version.json: si no, la instalada se quedaría con el
# fichero viejo creyendo que ya tiene la versión nueva.
$RutaInstalada = Join-Path $ConfigDir 'Valora.ps1'
$script:esInstalada = [string]::Equals([IO.Path]::GetFullPath($RutaValora), [IO.Path]::GetFullPath($RutaInstalada), [StringComparison]::OrdinalIgnoreCase)

function Get-HuellaCodigo { try { return (Get-FileHash $RutaValora -Algorithm SHA256).Hash } catch { return '' } }

function Start-BuscarActualizacion {
    if ($RepoValora -eq '__REPO__' -or $script:upd -or -not $script:esInstalada) { return }
    try {
        # Se lee la rama main por el protocolo de git: refleja un push al instante y no gasta el
        # límite de consultas de la API (60 por hora y por IP), así que se puede mirar cada 20 s.
        $script:upd = @{ paso = 'sha'; tarea = (New-Cliente).DownloadStringTaskAsync("https://github.com/$RepoValora.git/info/refs?service=git-upload-pack") }
        $timerUpd.Start()
    } catch { $script:upd = $null; Write-LogUpd ('no se pudo consultar GitHub: ' + $_.Exception.Message) }
}

# Reinicio sin que se note: se guarda lo que hay en pantalla (conversación abierta, texto escrito,
# adjuntos, ficha elegida y posición de la ventana), la versión nueva lo recupera al arrancar y
# esta ventana no se cierra hasta que la nueva ya se ve (o pasan 20 s).
$ReanudarFile = Join-Path $ConfigDir 'reanudar.json'
function Restart-Valora {
    Save-Config
    $marca = [guid]::NewGuid().ToString('N')
    $rb = $win.RestoreBounds
    $estado = [ordered]@{
        marca = $marca; fecha = (Get-Date).ToString('o')
        conv = if ($script:conv) { $script:conv.id } else { $null }
        texto = $ui.Prompt.Text; archivos = @($script:archivos)
        ficha = $script:fichaPendiente
        ventana = @{ left = $rb.Left; top = $rb.Top; width = $rb.Width; height = $rb.Height; max = ($win.WindowState -eq 'Maximized') }
    }
    try { $estado | ConvertTo-Json -Depth 6 | Set-Content $ReanudarFile -Encoding UTF8 } catch {}
    Start-Process powershell.exe -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', $RutaValora)
    $win.IsEnabled = $false
    Set-Estado 'Aplicando la versión nueva…' '#81C995'
    $script:esperaRelevo = @{ archivo = (Join-Path $ConfigDir "relevo-$marca"); hasta = (Get-Date).AddSeconds(20) }
    $timerRelevo.Start()
}
$timerRelevo = New-Object System.Windows.Threading.DispatcherTimer
$timerRelevo.Interval = [TimeSpan]::FromMilliseconds(200)
$timerRelevo.Add_Tick({
    $e = $script:esperaRelevo
    if ((Test-Path $e.archivo) -or (Get-Date) -gt $e.hasta) {
        $timerRelevo.Stop()
        try { Remove-Item $e.archivo -Force -ErrorAction SilentlyContinue } catch {}
        $win.Close()
    }
})

# Con una versión nueva pendiente, se aplica en cuanto Valora está tranquila: agy sin responder,
# sin el login ni paneles abiertos y sin escribir desde hace 15 s.
$script:ultimaEscritura = Get-Date
$timerAplicar = New-Object System.Windows.Threading.DispatcherTimer
$timerAplicar.Interval = [TimeSpan]::FromSeconds(2)
$timerAplicar.Add_Tick({
    if (-not $script:pendienteReinicio) { $timerAplicar.Stop(); return }
    if ($script:proc -or $script:colaPreguntas.Count -gt 0 -or $script:loginProc -or $ui.Login.Visibility -eq 'Visible' -or
        $ui.PanelConfirmar.Visibility -eq 'Visible' -or $ui.PanelFC.Visibility -eq 'Visible' -or $ui.PanelEstilo.Visibility -eq 'Visible' -or
        $script:ytSel.Count -gt 0 -or ($ui.YTAviso.Visibility -eq 'Visible' -and $ui.YTCodigoCaja.Visibility -eq 'Visible') -or $ui.YTClave.Password -or $ui.YTCred.Visibility -eq 'Visible' -or
        ((Get-Date) - $script:ultimaEscritura).TotalSeconds -lt 15) { return }
    $timerAplicar.Stop()
    Restart-Valora
})

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
        $sha = if ($u.tarea.Result -match '([0-9a-f]{40}) refs/heads/main') { $Matches[1] } else { '' }
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
            $v = Get-VersionLocal
            $v | Add-Member -NotePropertyName sha -NotePropertyValue $u.sha -Force
            $v | Add-Member -NotePropertyName huella -NotePropertyValue (Get-HuellaCodigo) -Force
            Save-VersionLocal $v
        } catch { Write-LogUpd ('no se pudo escribir la versión nueva: ' + $_.Exception.Message); return }
        Write-LogUpd "aplicada la versión $($u.sha)"
        Start-ActualizarIcono
        # Se aplica sola en cuanto Valora esté tranquila (ver $timerAplicar). Mientras tanto,
        # el botón junto al nombre permite aplicarla ya.
        $script:pendienteReinicio = $true
        $ui.BtnReiniciarTitulo.Visibility = 'Visible'
        if ($ui.TxtVersion.Text -notmatch 'nueva') { $ui.TxtVersion.Text = $ui.TxtVersion.Text + ' · se aplica sola' }
        $timerAplicar.Start()
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
$ui.BtnReiniciarTitulo.Add_Click({
    if ($script:proc) { Set-Estado 'Se aplicará sola en cuanto termine la respuesta.' '#F2C46D'; return }
    $timerAplicar.Stop()
    Restart-Valora
})
$timerRevisar = New-Object System.Windows.Threading.DispatcherTimer
$timerRevisar.Interval = [TimeSpan]::FromSeconds(20)
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
    Stop-SesionAgy -Todas
    if ($script:loginProc) { try { $script:loginProc.Matar(); $script:loginProc.Cerrar() } catch {} }
})

# ---------- Arranque ----------
# Si el fichero no es el que se apuntó al actualizar (lo cambió otra cosa), se olvida la versión
# apuntada para que se vuelva a bajar la buena.
if ($script:esInstalada) {
    $vh = Get-VersionLocal
    if ($vh.huella -and $vh.huella -ne (Get-HuellaCodigo)) {
        Write-LogUpd "el fichero no coincide con la versión $($vh.sha) apuntada; se volverá a bajar"
        $vh | Add-Member -NotePropertyName sha -NotePropertyValue '' -Force
        Save-VersionLocal $vh
    }
}
$ui.TxtWs.Text = Split-Path $script:workspace -Leaf; $ui.BtnAbrirWs.ToolTip = "Carpeta de trabajo (abrir en Explorador)`n" + $script:workspace
if (-not $script:permisosAgy) {
    $r = [System.Windows.MessageBox]::Show(
        "Para responder rápido, Valora deja que agy trabaje con todos los permisos: lee y crea archivos, " +
        "ejecuta comandos y consulta internet sin pedir confirmación cada vez.`n`n" +
        "¿Aceptas darle todos los permisos?`n`nSin ellos Valora no puede funcionar.",
        'Valora: permisos de agy', 'YesNo', 'Warning')
    if ($r -ne 'Yes') { $win.Close(); exit }
    $script:permisosAgy = $true
    Save-Config
}
if (-not (Set-PermisosAgy)) {
    [System.Windows.MessageBox]::Show(
        "No he podido dar los permisos a agy (no se puede escribir en $env:USERPROFILE\.gemini\antigravity-cli\settings.json). " +
        'agy funcionará, pero puede ir más lento.', 'Valora', 'OK', 'Warning') | Out-Null
}
Update-Adjuntos; Update-Carpetas; Update-Inicio; Update-ListaConv
Update-Entorno; Update-BarraFicha
$verLocal = (Get-VersionLocal).sha
$script:relevo = $null
if (Test-Path $ReanudarFile) {
    try {
        $r = Get-Content $ReanudarFile -Raw -Encoding UTF8 | ConvertFrom-Json
        Remove-Item $ReanudarFile -Force
        if (((Get-Date) - [datetime]$r.fecha).TotalMinutes -lt 2) {
            $script:relevo = $r.marca
            $v = $r.ventana
            if ($v -and $v.width -gt 0) {
                $win.WindowStartupLocation = 'Manual'
                $win.Left = $v.left; $win.Top = $v.top; $win.Width = $v.width; $win.Height = $v.height
                if ($v.max) { $win.WindowState = 'Maximized' }
            }
            if ($r.conv) { Open-Conv $r.conv }
            if ($r.ficha) { $script:fichaPendiente = $r.ficha; Update-BarraFicha }
            Add-Rutas @($r.archivos | Where-Object { $_ })
            if ($r.texto) { $ui.Prompt.Text = $r.texto; $ui.Prompt.CaretIndex = $ui.Prompt.Text.Length }
        }
    } catch {}
}
Update-UrlAutoYT
Start-ServidorLocalYT
if ($cfg.modo -eq 'youtube') { Set-Modo 'youtube' }
$ui.TxtVersion.Text = 'Versión ' + $(if (-not $script:esInstalada) { 'de pruebas (no se actualiza)' } elseif ($verLocal) { $verLocal.Substring(0, 7) } else { 'local' })
if ($script:relevo) { $ui.TxtVersion.Text += ' · recién actualizada ✓'; $ui.TxtVersion.Foreground = Brush '#81C995' }
$ui.TxtCuenta.Text = 'Comprobando…'; $ui.BtnLogout.Visibility = 'Collapsed'
if ($script:Agy) {
    Set-Estado 'Comprobando la sesión de Google…'
    Start-Comprobacion
} else {
    Set-Estado 'agy no está instalado. Ejecuta InstalarValora.exe.' '#F28B82'
}
$win.Add_ContentRendered({
    $ui.Prompt.Focus() | Out-Null
    if ($script:relevo) {
        try { Set-Content (Join-Path $ConfigDir "relevo-$($script:relevo)") '' } catch {}
        $win.Activate() | Out-Null
    }
    Start-BuscarActualizacion
    Start-ActualizarIcono
    Start-ActualizarAgy
    $timerRevisar.Start()
})
[void]$win.ShowDialog()
