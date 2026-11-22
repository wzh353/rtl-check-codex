function New-RtlEfinityInvocation($Project, [string]$Work, [string]$ArtifactRelative) {
    $settings = $Project.Synthesis
    $artifactDirectory = [IO.Path]::GetFullPath($ArtifactRelative, $Work)
    $outputDirectory = Join-Path $artifactDirectory 'outflow'
    $workDirectory = Join-Path $artifactDirectory 'work'
    $projectName = 'rtlcheck_efinity'
    $projectPath = Join-Path $artifactDirectory "$projectName.xml"

    # The project structure and synthesis parameters follow Efinix's 2026.1.132 TinyML project.
    # https://github.com/Efinix-Inc/tinyml/blob/main/tinyml_hello_world/Ti60F225_tinyml_hello_world/tinyml_soc.xml
    [xml]$document = @'
<?xml version="1.0" encoding="UTF-8"?>
<efx:project xmlns:efx="http://www.efinixinc.com/enf_proj"
             xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
             xsi:schemaLocation="http://www.efinixinc.com/enf_proj enf_proj.xsd"
             name="" description="" sw_version="2026.1.132">
    <efx:device_info>
        <efx:family name="" />
        <efx:device name="" />
        <efx:timing_model name="" />
    </efx:device_info>
    <efx:design_info def_veri_version="verilog_2k" def_vhdl_version="vhdl_2008" unified_flow="false">
        <efx:top_module name="" />
    </efx:design_info>
    <efx:interface_info />
    <efx:constraint_info />
    <efx:sim_info />
    <efx:misc_info />
    <efx:ooc_info />
    <efx:ip_info />
    <efx:synthesis tool_name="efx_map">
        <efx:param name="work_dir" value="work_syn" value_type="e_string" />
        <efx:param name="write_efx_verilog" value="on" value_type="e_bool" />
        <efx:param name="blackbox-error" value="1" value_type="e_option" />
    </efx:synthesis>
    <efx:place_and_route tool_name="efx_pnr" />
    <efx:bitstream_generation tool_name="efx_pgm" />
    <efx:debugger />
    <efx:security />
</efx:project>
'@
    $root = $document.DocumentElement
    $namespace = $root.NamespaceURI
    $root.SetAttribute('name', $projectName)
    $root['efx:device_info']['efx:family'].SetAttribute('name', $settings.family)
    $root['efx:device_info']['efx:device'].SetAttribute('name', $settings.device)
    $root['efx:device_info']['efx:timing_model'].SetAttribute('name', $settings.timingModel)
    $design = $root['efx:design_info']
    $design['efx:top_module'].SetAttribute('name', $settings.top)
    foreach ($source in $Project.Sources) {
        $stagedPath = [IO.Path]::GetFullPath($source, $Work)
        $relative = [IO.Path]::GetRelativePath($artifactDirectory, $stagedPath).Replace('\', '/')
        $version = switch ([IO.Path]::GetExtension($source).ToLowerInvariant()) {
            '.v' { 'verilog_2k' }
            '.sv' { 'sv_09' }
            default { 'default' }
        }
        $file = $document.CreateElement('efx', 'design_file', $namespace)
        $file.SetAttribute('name', $relative)
        $file.SetAttribute('version', $version)
        $file.SetAttribute('library', 'default')
        $null = $design.AppendChild($file)
    }

    $synthesis = $root['efx:synthesis']
    foreach ($directory in $Project.IncludeDirs) {
        $stagedPath = [IO.Path]::GetFullPath($directory, $Work)
        $entry = $document.CreateElement('efx', 'param', $namespace)
        $entry.SetAttribute('name', 'include')
        $entry.SetAttribute('value', [IO.Path]::GetRelativePath($artifactDirectory, $stagedPath).Replace('\', '/'))
        $entry.SetAttribute('value_type', 'e_string')
        $null = $synthesis.AppendChild($entry)
    }
    $document.Save($projectPath)

    $setupBatch = if ($IsWindows -and $settings.executable) {
        $launcherDirectory = [IO.Path]::GetDirectoryName($settings.executable)
        $setupPath = [IO.Path]::GetFullPath('../bin/setup.bat', $launcherDirectory)
        if ([IO.File]::Exists($setupPath)) { $setupPath }
    }
    return @{
        arguments = [string[]]@(
            [IO.Path]::GetRelativePath($Work, $projectPath).Replace('\', '/')
            '--flow', 'map', '--output_dir', $outputDirectory, '--work_dir', $workDirectory
        )
        netlists = [string[]]@(
            (Join-Path $outputDirectory "$projectName.map.v")
            (Join-Path $outputDirectory "$projectName.map.core.v")
        )
        reportPath = Join-Path $outputDirectory "$projectName.map.rpt"
        setupBatch = $setupBatch
    }
}
