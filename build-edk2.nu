#!/usr/bin/env nu
const rootdir = path self .
use std/dirs

def allowed-release-types []: nothing -> list<string> {[DEBUG RELEASE]}

def allowed-devices []: nothing -> list<string> {
  ls ([$rootdir configs] | path join)
  | where {|entry| (($entry.name | path parse).extension | default "") == "yaml" }
  | get name
  | path basename
  | path parse
  | get stem
}

def require-path [path: path, label: string] {
  if not ($path | path exists) {
    error make $"Required ($label) not found: ($path)"
  }
}

def rm-glob [pattern: string] {
  let matches = (glob $pattern)
  if ($matches | length) > 0 {
    rm --force ...$matches
  }
}

def ini-value [ini_path: path, key: string] {
  let line = (
    open $ini_path
    | lines
    | where {|entry| $entry | str starts-with $"($key)="}
    | first
  )

  $line | split row "=" | skip 1 | str join "=" | str trim
}

def ini-regex-value [ini_path: path, pattern: string] {
  let line = (
    open $ini_path
    | lines
    | where {|entry| $entry =~ $pattern}
    | first
  )

  $line | split row "=" | skip 1 | str join "=" | str trim
}

def apply-patchset [patches_dir: path, target_dir: path, skip_patchsets: bool] {
  if $skip_patchsets {
    return
  }

  if not ($patches_dir | path exists) {
    return
  }

  if not ($target_dir | path exists) {
    error make $"Patchset target directory does not exist: ($target_dir)"
  }

  let patch_files = (
    ls $patches_dir
    | where {|entry|
        ($entry.type == "file") and ((($entry.name | path parse).extension | default "") == "patch")
    }
    | sort-by name
  )

  if ($patch_files | length) == 0 {
    return
  }

  print $"Checking patchset ($patches_dir) for ($target_dir)"

  let patchset_name = $patches_dir | path basename
  let patchset_marker = [$target_dir $".patchset_($patchset_name)"] | path join
  let marker_exists = $patchset_marker | path exists

  let needs_apply = if not $marker_exists {
    true
  } else {
    let marker_mtime = ls $patchset_marker | get modified | first
    $patch_files | get modified | any {|mtime| $mtime > $marker_mtime}
  }

  if not $needs_apply {
    print "Patchset already applied - skipping"
    return
  }

  print "Patchset needs to be (re)applied"
  git -C $target_dir reset --hard
  git -C $target_dir clean -xfd

  let patch_results = $patch_files
  | each {|patch_file|
    patch -p1 -d $target_dir -i $patch_file.name
    | complete
    | tee {
      match $in.exit_code {
        0 => (print $"Succesfully applied: ($patch_file.name | path basename)")
        1 => (error make $"Failed to apply ($patch_file.name | path basename)")
      }
    }
  }
  touch $patchset_marker
  print $"Patchset summary: ($patch_results | length) applied"
}

def build-idblock [ctx: record, soc_cfg: record] {
  print " => Building idblock.bin"

  let rkboot_ini = [$ctx.rootdir "misc" "rkbin" "RKBOOT" $soc_cfg.miniall_ini] | path join
  let ddrbin_rkbin = (ini-value $rkboot_ini "FlashData")
  let ddrbin = [$ctx.rootdir "misc" "rkbin" $ddrbin_rkbin] | path join
  let spl = [$ctx.rootdir "misc" "rk3588_spl_v1.12.bin"] | path join
  let mkimage = [$ctx.rootdir "misc" "tools" $ctx.machine_type "mkimage"] | path join

  dirs add $ctx.workspace
  rm-glob "rk35*_spl_loader_*.bin"
  rm-glob "rk35*_ddr_*.bin"
  rm-glob "rk35*_usbplug*.bin"
  rm-glob "FlashHead.bin"
  rm-glob "FlashData.bin"
  rm-glob "FlashBoot.bin"
  rm-glob "UsbHead.bin"
  rm-glob "idblock.bin"

  (^$mkimage -n rk3588 -T rksd -d $"($ddrbin):($spl)" idblock.bin)
  dirs drop

  print " => idblock.bin build done"
}

def build-fit [
  ctx: record
  device: string
  release_type: string@allowed-release-types
  toolchain: string
  open_tfa: bool
  platform_name: string
  soc_cfg: record
] {
  print " => Building FIT"

  let trust_ini = $soc_cfg.trust_ini
  let tfa_plat = $soc_cfg.tfa_plat
  let trust_path = [$ctx.rootdir "misc" "rkbin" "RKTRUST" $trust_ini] | path join
  let soc_l = $ctx.soc | str downcase
  let bl31_rkbin = (ini-regex-value $trust_path '^PATH=.*_bl31_')
  let bl32_rkbin = (ini-regex-value $trust_path '^PATH=.*_bl32_')
  let bl32 = [$ctx.rootdir "misc" "rkbin" $bl32_rkbin] | path join
  let bl31 = if $open_tfa {
    (
      [
          $ctx.rootdir
          "arm-trusted-firmware"
          "build"
          $tfa_plat
          ($release_type | str downcase)
          "bl31"
          "bl31.elf"
      ]
      | path join
    )
  } else {
    ([$ctx.rootdir "misc" "rkbin" $bl31_rkbin] | path join)
  }

  let build_dir = (
    [$ctx.workspace "Build" $platform_name $"($release_type)_($toolchain)" "FV"]
    | path join
  )
  let fv_path = [$build_dir "BL33_AP_UEFI.Fv"] | path join
  let its_template = [$ctx.rootdir "misc" $"uefi_($soc_l).its"] | path join
  let its_path = [$ctx.workspace $"($soc_l)_($device)_EFI.its"] | path join
  let itb_path = [$ctx.workspace $"($device)_EFI.itb"] | path join
  let dtb_source = [$ctx.rootdir "misc" $"($soc_l)_spl.dtb"] | path join
  let dtb_path = [$ctx.workspace $"($device).dtb"] | path join
  let mkimage = [$ctx.rootdir "misc" "tools" $ctx.machine_type "mkimage"] | path join
  let extractbl31 = [$ctx.rootdir "misc" "extractbl31.py"] | path join

  dirs add $ctx.workspace
  rm-glob "bl31_0x*.bin"
  if ("BL33_AP_UEFI.Fv" | path exists) {
    rm --force "BL33_AP_UEFI.Fv"
  }
  if ($its_path | path exists) {
    rm --force $its_path
  }

  python3 $extractbl31 $bl31
  if not ("bl31_0x000f0000.bin" | path exists) {
    touch "bl31_0x000f0000.bin"
  }

  cp $bl32 "bl32.bin"
  cp $dtb_source $dtb_path
  cp $fv_path "BL33_AP_UEFI.Fv"
  open $its_template | str replace -a "@DEVICE@" $device | save --force $its_path
  ^$mkimage -f $its_path -E $itb_path
  dirs drop

  print " => FIT build done"
}

def pack-image [
  ctx: record
  device: string
  release_type: string
  toolchain: string
  open_tfa: bool
  platform_name: string
  soc_cfg: record
] {
  build-idblock $ctx $soc_cfg
  (build-fit
    $ctx
    $device
    $release_type
    $toolchain
    $open_tfa
    $platform_name
    $soc_cfg
  )

  print " => Building 8MB NOR FLASH IMAGE"

  let build_dir = (
    [$ctx.workspace "Build" $platform_name $"($release_type)_($toolchain)" "FV"]
    | path join
  )
  let flash_fd = [$build_dir "NOR_FLASH_IMAGE.fd"] | path join
  let flash_img = [$ctx.workspace "RK3588_NOR_FLASH.img"] | path join
  let gpt_img = [$ctx.rootdir "misc" "rk3588_spi_nor_gpt.img"] | path join
  let idblock = [$ctx.workspace "idblock.bin"] | path join
  let fit_image = [$ctx.workspace $"($device)_EFI.itb"] | path join

  ^cp $flash_fd $flash_img
  ^dd $"if=($gpt_img)" $"of=($flash_img)"
  ^dd $"if=($idblock)" $"of=($flash_img)" bs=1K seek=32
  ^dd $"if=($fit_image)" $"of=($flash_img)" bs=1K seek=1024
  ^cp $flash_img $ctx.rootdir
}

def build-device [
  ctx: record
  device: string
  release_type: string
  toolchain: string
  open_tfa: bool
  tfa_flags: list<string>
  edk2_flags: list<string>
  skip_patchsets: bool
  git_commit: string
] {
  let device_cfg = open ([$ctx.rootdir "configs" $"($device).yaml"] | path join)
  let soc_cfg = open ([$ctx.rootdir "configs" $"($device_cfg.soc).yaml"] | path join)
  let platform_name = $device_cfg.platform_name
  let dsc_file = $device_cfg.dsc_file
  let tfa_plat = $soc_cfg.tfa_plat

  let ctx = $ctx | upsert soc $device_cfg.soc

  rm-glob ([$ctx.outdir "RK35*_NOR_FLASH.img"] | path join)

  if $open_tfa {
    (apply-patchset
      ([$ctx.rootdir "arm-trusted-firmware-patches"] | path join)
      ([$ctx.rootdir "arm-trusted-firmware"] | path join)
      $skip_patchsets
    )

    let debug = if $release_type == "DEBUG" { "1" } else { "0" }
    dirs add ([$ctx.rootdir "arm-trusted-firmware"] | path join)
    let tfa_result  = make $"PLAT=($tfa_plat)" $"DEBUG=($debug)" all ...$tfa_flags | complete
    dirs drop
    if $tfa_result.exit_code != 0 { error make $tfa_result.stderr}
  }

  require-path ([$ctx.rootdir "edk2"] | path join) "EDK2 source tree"
  require-path ([$ctx.rootdir "devicetree" "mainline" "upstream"] | path join) "mainline device tree source tree"
  apply-patchset ([$ctx.rootdir "edk2-patches"] | path join) ([$ctx.rootdir "edk2"] | path join) $skip_patchsets
  apply-patchset ([$ctx.rootdir "devicetree" "mainline" "patches"] | path join) ([$ctx.rootdir "devicetree" "mainline" "upstream"] | path join) $skip_patchsets

  let conf_dir = [$ctx.workspace "Conf"] | path join
  if not ($conf_dir | path exists) {
    mkdir $conf_dir
  }

  let packages_path = (
    [
      $ctx.rootdir
      ([$ctx.rootdir "devicetree"] | path join)
      ([$ctx.rootdir "edk2"] | path join)
      ([$ctx.rootdir "edk2-non-osi"] | path join)
      ([$ctx.rootdir "edk2-platforms"] | path join)
      ([$ctx.rootdir "edk2-rockchip"] | path join)
      ([$ctx.rootdir "edk2-rockchip-non-osi"] | path join)
    ]
    | str join (char esep)
  )
  let edk_tools_path = [$ctx.rootdir "edk2" "BaseTools"] | path join
  let conf_path = $conf_dir
  let path_dirs = $env.PATH
  | prepend ([$edk_tools_path "BinWrappers" "PosixLike"] | path join)
  | where {|entry| $entry != "" }
  let build_tool = [$edk_tools_path "BinWrappers" "PosixLike" "build"] | path join

  with-env {
    WORKSPACE: $ctx.workspace
    PACKAGES_PATH: $packages_path
    EDK_TOOLS_PATH: $edk_tools_path
    CONF_PATH: $conf_path
    PATH: $path_dirs
    GCC_AARCH64_PREFIX: $ctx.cross_compile
    CLANG38_AARCH64_PREFIX: $ctx.cross_compile
  } {
    make -C ([$ctx.rootdir "edk2" "BaseTools"] | path join)

    let dsc_path = [$ctx.rootdir $dsc_file] | path join
    dirs add $ctx.rootdir
    ^$build_tool -s -n 0 -a AARCH64 -t $toolchain -p $dsc_path -b $release_type -D $"FIRMWARE_VER=($git_commit)" -D NETWORK_ALLOW_HTTP_CONNECTIONS=TRUE -D NETWORK_ISCSI_ENABLE=TRUE -D INCLUDE_TFTP_COMMAND=TRUE --pcd gRockchipTokenSpaceGuid.PcdFitImageFlashAddress=0x100000 ...$edk2_flags
    dirs drop
  }

  pack-image $ctx $device $release_type $toolchain $open_tfa $platform_name $soc_cfg
  print "Build done: RK3588_NOR_FLASH.img"
}

# Remove the workspace and generated flash images from the current output dir.
export def clean [outdir: path] {
  let workspace = [$outdir "workspace"] | path join
  if ($workspace | path exists) {
    rm --recursive --force $workspace
  }

  for img in (glob ([$outdir "RK3588_*.img"] | path join)) {
    rm --force $img
  }
}

# Run `git clean -xdf` from the repo root when available.
export def distclean [rootdir: path, outdir: path] {
  if (([$rootdir ".git"] | path join) | path exists) {
    dirs add $rootdir
    git clean -xdf
    dirs drop
  } else {
    clean $outdir
  }
}

# Build EDK2 firmware for Rockchip RK3588 platforms.
export def main [
  ...devices: string@allowed-devices                     # Build for this device, or `all` for every board config.
  --release(-r): string@allowed-release-types = "DEBUG"  # Build profile passed to TF-A and EDK2: `DEBUG` or `RELEASE`.
  --toolchain(-t): string = "GCC"                        # EDK2 toolchain tag, for example `GCC`.
  --vendor-tfa                                           # Use BL31 from `misc/rkbin` instead of building `arm-trusted-firmware`.
  --tfa-flags: list<string> = []                         # Extra arguments appended to the TF-A `make` command.
  --edk2-flags: list<string> = []                        # Extra arguments appended to the EDK2 `build` command.
  --skip-patchsets                                       # Skip reapplying local patchsets to upstream submodules.
] {
  let allowed_devices = allowed-devices
  if ($devices | any {|dev| not ($dev in $allowed_devices)}) {
    error make -u $"Unknown device in: ($devices)\t\nAllowed ones: ($allowed_devices)"
  }

  if not (($release | str upcase) in (allowed-release-types)) {
    error make -u $"Unknown release type: ($release)\t\nAllowed ones \(automatically upcased\): (allowed-release-types)"
  }

  let machine_type = (uname | get machine)
  $env.CROSS_COMPILE = if ($machine_type != "aarch64") and (($env.CROSS_COMPILE? | default "") == "") {
    if (sys host | get name | $in =~ SUSE ) {
      "aarch64-suse-linux-"
    } else {
      "aarch64-linux-gnu-"
    }  
  } else {
    $env.CROSS_COMPILE
  }
  

  dirs add $rootdir
  let git_commit = git describe --tags --always | complete
  | match $in {
    {exit_code: 0 stdout: $out} => ($out | str trim)
    _                           => "unknown"
  }

  let outdir = $env.PWD | path expand
  let workspace = [$outdir "workspace"] | path join
  mkdir $workspace

  let ctx = {
    rootdir: $rootdir
    outdir: $outdir
    workspace: $workspace
    machine_type: $machine_type
    cross_compile: ($env.CROSS_COMPILE? | default "")
    soc: ""
  }

  let open_tfa = (not $vendor_tfa)

  for dev in ($devices | default -e $allowed_devices) {
    print $"Building ($dev)"
    build-device $ctx $dev ($release | str upcase) $toolchain $open_tfa $tfa_flags $edk2_flags $skip_patchsets $git_commit
  }
}
